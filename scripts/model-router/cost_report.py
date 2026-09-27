"""Weekly API-equivalent cost report for the model router (design: "Dollar cost
(API-equivalent) and the subscription-vs-API question").

Reads `<router state dir>/usage-all-sessions.jsonl` (written by
`skills/dt-build/scripts/collect-usage.py --all-sessions`) and
`references/model-router/api-prices.json`, and writes, per ET week (Monday-Sunday):

  <state>/cost-reports/weekly-<yyyy>-W<ww>.md
  <state>/cost-reports/weekly-<yyyy>-W<ww>.html
  <state>/cost-reports/latest.md   (copy of the most recent week's .md)

Deterministic, no network calls, no model calls. Read-only against the usage ledger.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import subprocess
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

ET_ZONE = ZoneInfo("America/New_York")
UTC = timezone.utc

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PRICES_PATH = REPO_ROOT / "references" / "model-router" / "api-prices.json"

# host (as recorded by collect-usage.py) -> report vendor label and the pricing-vendor tag
# used in api-prices.json.
VENDOR_INFO = {
    "claude": {"label": "Claude", "price_vendor": "anthropic", "subscription_key": "claude_max"},
    "codex": {"label": "Codex", "price_vendor": "openai", "subscription_key": "chatgpt_pro"},
}


def ensure_state_gitignore(state: Path) -> Path:
    """Mirror Get-RouterStateDir: runtime state is per machine and never synced by git."""
    state.mkdir(parents=True, exist_ok=True)
    ignore = state / ".gitignore"
    if not ignore.exists():
        try:
            with ignore.open("x", encoding="utf-8", newline="\n") as fh:
                fh.write("*\n")
        except FileExistsError:
            pass
    return state


def get_router_state_dir() -> Path:
    """Mirror Get-RouterStateDir in scripts/model-router/router-common.ps1."""
    env = os.environ.get("DT_MODEL_ROUTER_STATE")
    if env:
        return Path(env).resolve()
    script_dir = Path(__file__).resolve().parent
    try:
        proc = subprocess.run(
            ["git", "-C", str(script_dir), "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, check=True,
        )
    except (OSError, subprocess.CalledProcessError) as err:
        raise RuntimeError("ROUTER_GIT_COMMON_DIR: Cannot locate main checkout.") from err
    common = proc.stdout.strip()
    if not common:
        raise RuntimeError("ROUTER_GIT_COMMON_DIR: Cannot locate main checkout.")
    main_checkout = Path(common).parent
    return (main_checkout.parent / "model-router" / "state").resolve()


def parse_ts(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed


def load_prices(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def load_usage_all_sessions(path: Path) -> tuple[list[dict], list[dict]]:
    """Split usage-all-sessions.jsonl into (usage rows, codex_rate_limit rows)."""
    usage: list[dict] = []
    rate: list[dict] = []
    if not path.is_file():
        return usage, rate
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("kind") == "usage":
            usage.append(row)
        elif row.get("kind") == "codex_rate_limit":
            rate.append(row)
    return usage, rate


def resolve_price_key(model: str | None, models: dict) -> str | None:
    """Longest-prefix match: a logged model id often carries a date/version suffix
    (e.g. a snapshot tag) that the published price-table key does not. Never guess a
    price for a model that doesn't match a known key at all."""
    if not model:
        return None
    for key in sorted(models.keys(), key=len, reverse=True):
        if model == key or model.startswith(key + "-"):
            return key
    return None


def price_usage_row(row: dict, prices: dict) -> tuple[float | None, dict]:
    """Return (cost_usd or None if unpriced, the token dict actually priced/unpriced)."""
    models = prices.get("models", {})
    key = resolve_price_key(row.get("model"), models)
    tokens = row.get("tokens") or {}
    if key is None:
        return None, tokens
    entry = models[key]
    vendor = entry.get("vendor")
    expected_vendor = VENDOR_INFO.get(row.get("host"), {}).get("price_vendor")
    if expected_vendor and vendor != expected_vendor:
        # A price-table entry exists under this name but for the wrong vendor: treat as
        # unmatched rather than silently pricing with the wrong rate card.
        return None, tokens
    rates = entry.get("prices_usd_per_mtok") or {}
    inp = tokens.get("input", 0) or 0
    cw = tokens.get("cache_write", 0) or 0
    cr = tokens.get("cache_read", 0) or 0
    out = tokens.get("output", 0) or 0
    if vendor == "anthropic":
        needed = ("input", "cache_write", "cache_read", "output")
        if any(rates.get(k) is None for k in needed):
            return None, tokens
        cost = (inp * rates["input"] + cw * rates["cache_write"] + cr * rates["cache_read"]
                + out * rates["output"]) / 1_000_000.0
        return cost, tokens
    if vendor == "openai":
        # OpenAI publishes input / cached_input / output only; a cache-write token is a
        # regular (uncached) input token from a billing standpoint, so it prices at the
        # standard input rate, not a separate cache-write rate.
        needed = ("input", "cached_input", "output")
        if any(rates.get(k) is None for k in needed):
            return None, tokens
        cost = ((inp + cw) * rates["input"] + cr * rates["cached_input"] + out * rates["output"]) / 1_000_000.0
        return cost, tokens
    return None, tokens


def iso_week_of(date_str: str) -> tuple[int, int]:
    d = date.fromisoformat(date_str)
    iso_year, iso_week, _ = d.isocalendar()
    return iso_year, iso_week


def week_label(iso_year: int, iso_week: int) -> str:
    return f"{iso_year}-W{iso_week:02d}"


def week_bounds_et(iso_year: int, iso_week: int) -> tuple[date, date]:
    """(Monday, Sunday) as ET calendar dates for this ISO week."""
    monday = date.fromisocalendar(iso_year, iso_week, 1)
    sunday = date.fromisocalendar(iso_year, iso_week, 7)
    return monday, sunday


def week_bounds_utc(iso_year: int, iso_week: int) -> tuple[datetime, datetime]:
    """[start, end) in UTC covering Monday 00:00 ET through the following Monday 00:00 ET."""
    monday, _ = week_bounds_et(iso_year, iso_week)
    start_et = datetime(monday.year, monday.month, monday.day, 0, 0, tzinfo=ET_ZONE)
    end_et = start_et + timedelta(days=7)
    return start_et.astimezone(UTC), end_et.astimezone(UTC)


def compute_blocked_intervals(readings: list[dict]) -> list[tuple[datetime, datetime]]:
    """Codex-only. From rate_limits.primary readings (used_percent, resets_at), build
    intervals where the weekly quota sat at 100% until either resets_at or the next
    reading below 100%, whichever is earlier. No dollar figure is ever attached to
    blocked time; this is elapsed time only."""
    parsed = []
    for r in readings:
        ts = parse_ts(r.get("ts"))
        pct = r.get("used_percent")
        if ts is None or pct is None:
            continue
        parsed.append((ts, float(pct), r.get("resets_at")))
    parsed.sort(key=lambda t: t[0])
    intervals: list[tuple[datetime, datetime]] = []
    blocked_start: datetime | None = None
    blocked_reset: float | None = None
    for ts, pct, resets_at in parsed:
        if pct >= 100:
            if blocked_start is None:
                blocked_start = ts
                blocked_reset = resets_at
            elif resets_at is not None:
                blocked_reset = resets_at if blocked_reset is None else min(blocked_reset, resets_at)
        else:
            if blocked_start is not None:
                end = ts
                if blocked_reset is not None:
                    reset_dt = datetime.fromtimestamp(blocked_reset, tz=UTC)
                    end = min(end, reset_dt) if reset_dt > blocked_start else end
                intervals.append((blocked_start, end))
                blocked_start = None
                blocked_reset = None
    if blocked_start is not None:
        end = datetime.fromtimestamp(blocked_reset, tz=UTC) if blocked_reset is not None else parsed[-1][0]
        if end < blocked_start:
            end = blocked_start
        intervals.append((blocked_start, end))
    return intervals


def overlap_minutes(intervals: list[tuple[datetime, datetime]], start: datetime, end: datetime) -> float:
    total = 0.0
    for a, b in intervals:
        lo = max(a, start)
        hi = min(b, end)
        if hi > lo:
            total += (hi - lo).total_seconds() / 60.0
    return total


@dataclass
class VendorWeek:
    host: str
    label: str
    subscription_usd: float
    api_equivalent_usd: float
    priced_totals: dict = field(default_factory=dict)
    unpriced_tokens_by_model: dict = field(default_factory=dict)
    sessions_seen: int = 0
    dates_seen: list = field(default_factory=list)
    gap_dates: list = field(default_factory=list)
    coverage_complete: bool = True
    blocked_minutes: float | None = None  # None = "no limit data available" (Claude)


def _dates_between(start: date, end: date) -> list[str]:
    out = []
    d = start
    while d <= end:
        out.append(d.isoformat())
        d += timedelta(days=1)
    return out


def build_vendor_week(host: str, iso_year: int, iso_week: int, rows: list[dict],
                       rate_rows: list[dict], prices: dict, today_et: date) -> VendorWeek:
    info = VENDOR_INFO[host]
    label = info["label"]
    sub = prices.get("subscriptions", {}).get(info["subscription_key"], {})
    subscription_usd = float(sub.get("weekly_usd") or 0.0)

    api_equivalent = 0.0
    priced_totals: dict[str, float] = {"input": 0.0, "cache_write": 0.0, "cache_read": 0.0, "output": 0.0}
    unpriced: dict[str, dict] = {}
    sessions: set[str] = set()
    dates_seen: set[str] = set()
    for row in rows:
        sessions.add(row.get("session_id") or "")
        dates_seen.add(row.get("date_et") or "")
        cost, tokens = price_usage_row(row, prices)
        if cost is None:
            bucket = unpriced.setdefault(row.get("model") or "unset", {"input": 0, "cache_write": 0, "cache_read": 0, "output": 0})
            for k in ("input", "cache_write", "cache_read", "output"):
                bucket[k] += tokens.get(k, 0) or 0
        else:
            api_equivalent += cost
            for k in ("input", "cache_write", "cache_read", "output"):
                priced_totals[k] += tokens.get(k, 0) or 0

    monday, sunday = week_bounds_et(iso_year, iso_week)
    week_end_clamp = min(sunday, today_et)
    expected = [d for d in _dates_between(monday, week_end_clamp)]
    gap_dates = [d for d in expected if d not in dates_seen] if dates_seen else []
    coverage_complete = len(gap_dates) == 0

    blocked_minutes = None
    if host == "codex":
        start_utc, end_utc = week_bounds_utc(iso_year, iso_week)
        intervals = compute_blocked_intervals(rate_rows)
        blocked_minutes = overlap_minutes(intervals, start_utc, end_utc)

    return VendorWeek(
        host=host, label=label, subscription_usd=subscription_usd, api_equivalent_usd=api_equivalent,
        priced_totals=priced_totals, unpriced_tokens_by_model=unpriced, sessions_seen=len(sessions),
        dates_seen=sorted(d for d in dates_seen if d), gap_dates=gap_dates,
        coverage_complete=coverage_complete, blocked_minutes=blocked_minutes,
    )


def build_weekly_reports(usage_rows: list[dict], rate_rows: list[dict], prices: dict,
                          today_et: date | None = None) -> list[dict]:
    """One report dict per ISO week seen in either the usage rows or the codex rate-limit
    readings, each holding a VendorWeek per vendor that had any signal that week."""
    today_et = today_et or datetime.now(tz=ET_ZONE).date()
    week_keys: set[tuple[int, int]] = set()
    rows_by_week_host: dict[tuple[int, int, str], list[dict]] = {}
    for row in usage_rows:
        d = row.get("date_et")
        if not d:
            continue
        wk = iso_week_of(d)
        week_keys.add(wk)
        rows_by_week_host.setdefault((*wk, row.get("host")), []).append(row)

    rate_by_week: dict[tuple[int, int], list[dict]] = {}
    for r in rate_rows:
        ts = parse_ts(r.get("ts"))
        if ts is None:
            continue
        d_et = ts.astimezone(ET_ZONE).date()
        wk = (d_et.isocalendar()[0], d_et.isocalendar()[1])
        week_keys.add(wk)
        rate_by_week.setdefault(wk, []).append(r)

    reports = []
    for (iso_year, iso_week) in sorted(week_keys):
        vendors = {}
        for host in ("claude", "codex"):
            rows = rows_by_week_host.get((iso_year, iso_week, host), [])
            rate_rows_for_week = rate_by_week.get((iso_year, iso_week), []) if host == "codex" else []
            if not rows and not rate_rows_for_week:
                continue
            vendors[host] = build_vendor_week(host, iso_year, iso_week, rows, rate_rows_for_week, prices, today_et)
        if not vendors:
            continue
        reports.append({"iso_year": iso_year, "iso_week": iso_week, "label": week_label(iso_year, iso_week), "vendors": vendors})
    return reports


def fmt_usd(v: float) -> str:
    return f"${v:,.2f}"


def fmt_tok(n: float) -> str:
    n = int(n)
    if n >= 1_000_000:
        return f"{n / 1_000_000:.2f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}K"
    return str(n)


def render_markdown(report: dict) -> str:
    lines = [f"# Model-router weekly cost report - {report['label']}", ""]
    lines.append("Subscription vs API-equivalent cost of observed usage, priced at published vendor list rates. "
                  "This total reflects only the sessions found in the swept logs; it is never presented as a "
                  "certified full-account spend figure.")
    lines.append("")
    for host in ("claude", "codex"):
        vw = report["vendors"].get(host)
        if not vw:
            continue
        lines.append(f"## {vw.label}")
        lines.append("")
        lines.append(f"- Subscription cost this week: {fmt_usd(vw.subscription_usd)}")
        lines.append(f"- API-equivalent cost of observed usage: {fmt_usd(vw.api_equivalent_usd)}")
        diff = vw.subscription_usd - vw.api_equivalent_usd
        verdict = "subscription ahead" if diff >= 0 else "API-equivalent exceeds subscription"
        lines.append(f"- Delta: {fmt_usd(abs(diff))} ({verdict})")
        if vw.unpriced_tokens_by_model:
            lines.append("- Unpriced usage (no confirmed vendor price; excluded from the total above):")
            for model, tok in sorted(vw.unpriced_tokens_by_model.items()):
                total_tok = sum(tok.values())
                lines.append(f"  - {model}: {fmt_tok(total_tok)} tokens")
        else:
            lines.append("- Unpriced usage: none")
        cov = f"{len(vw.dates_seen)} of {len(vw.dates_seen) + len(vw.gap_dates)} expected ET day(s) covered"
        lines.append(f"- Coverage: sessions={vw.sessions_seen}; {cov}; sources=usage-all-sessions.jsonl ({host})")
        if vw.gap_dates:
            lines.append(f"  - Gap: no sessions recorded for {', '.join(vw.gap_dates)} (incomplete week; total above is partial, not full spend)")
        if host == "codex":
            if vw.blocked_minutes is None:
                lines.append("- Blocked time (quota at 100%): no limit data available")
            else:
                lines.append(f"- Blocked time (quota at 100%): {vw.blocked_minutes:.1f} minutes; no dollar figure is invented for blocked work")
        else:
            lines.append("- Blocked time (quota at 100%): no limit data available (Claude session logs expose no account-level quota-used field)")
        lines.append("")
    return "\n".join(lines) + "\n"


def render_html(report: dict) -> str:
    top = max([1.0] + [vw.subscription_usd for vw in report["vendors"].values()]
              + [vw.api_equivalent_usd for vw in report["vendors"].values()])

    def bar(v: float, cls: str) -> str:
        pct = 0 if top <= 0 else max(1, int(100 * v / top))
        return f"<div class='bar'><i class='{cls}' style='width:{pct}%'></i><span>{html.escape(fmt_usd(v))}</span></div>"

    cards = []
    for host in ("claude", "codex"):
        vw = report["vendors"].get(host)
        if not vw:
            continue
        unpriced_html = "".join(
            f"<li>{html.escape(m)}: {fmt_tok(sum(t.values()))} tokens</li>"
            for m, t in sorted(vw.unpriced_tokens_by_model.items())
        ) or "<li>none</li>"
        gap_html = (f"<p class='gap'>Gap: no sessions for {html.escape(', '.join(vw.gap_dates))} "
                    f"(partial week, not full spend)</p>") if vw.gap_dates else ""
        if host == "codex":
            blocked_html = (f"<p>Blocked time (quota at 100%): {vw.blocked_minutes:.1f} min; no dollar figure invented</p>"
                             if vw.blocked_minutes is not None else "<p>Blocked time: no limit data available</p>")
        else:
            blocked_html = "<p>Blocked time: no limit data available (no Claude account-level quota field exists)</p>"
        cards.append(f"""<div class="card"><h2>{html.escape(vw.label)}</h2>
{bar(vw.subscription_usd, 'sub')}<div class='label'>Subscription (this week)</div>
{bar(vw.api_equivalent_usd, 'api')}<div class='label'>API-equivalent (observed usage)</div>
<p>Coverage: sessions={vw.sessions_seen}; {len(vw.dates_seen)} of {len(vw.dates_seen) + len(vw.gap_dates)} expected ET day(s)</p>
{gap_html}
{blocked_html}
<p>Unpriced usage (excluded from total):</p><ul>{unpriced_html}</ul>
</div>""")

    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>Model-router cost report {html.escape(report['label'])}</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root {{ --bg:#fff; --fg:#1b2430; --muted:#5b6775; --card:#f6f8fa; --sub:#2d5d8a; --api:#8a2a21; --border:#d9dee5; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#14181d; --fg:#e7ebf0; --muted:#9aa5b1; --card:#1d2329; --border:#2b333b; }} }}
body{{font:14px/1.5 "Myriad Pro","Segoe UI",system-ui,sans-serif;margin:24px;color:var(--fg);background:var(--bg)}}
h1{{font-size:20px;margin:0 0 12px}} h2{{font-size:16px;margin:0 0 10px}}
.card{{background:var(--card);border:1px solid var(--border);border-radius:4px;padding:16px;margin-bottom:16px;max-width:640px}}
.bar{{background:var(--border);height:16px;border-radius:2px;position:relative;margin:4px 0}}
.bar i{{display:block;height:16px;border-radius:2px}} .bar i.sub{{background:var(--sub)}} .bar i.api{{background:var(--api)}}
.bar span{{position:absolute;left:6px;top:0;font-size:12px;line-height:16px;color:var(--fg)}}
.label{{color:var(--muted);font-size:12px;margin-bottom:8px}} .gap{{color:var(--api)}}
p{{margin:6px 0}} ul{{margin:4px 0 8px 18px;padding:0}}
</style></head><body>
<h1>Model-router weekly cost report - {html.escape(report['label'])}</h1>
<p class='label'>Subscription vs API-equivalent cost, priced at published vendor list rates. Reflects only sessions found in the swept logs -- never a certified full-account total.</p>
{''.join(cards)}
</body></html>"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=None)
    parser.add_argument("--prices", type=Path, default=DEFAULT_PRICES_PATH)
    args = parser.parse_args()

    state_dir = ensure_state_gitignore(Path(args.state_dir) if args.state_dir else get_router_state_dir())
    usage_path = state_dir / "usage-all-sessions.jsonl"
    out_dir = state_dir / "cost-reports"
    out_dir.mkdir(parents=True, exist_ok=True)

    prices = load_prices(args.prices)
    usage_rows, rate_rows = load_usage_all_sessions(usage_path)
    reports = build_weekly_reports(usage_rows, rate_rows, prices)

    if not reports:
        print("DT_MODEL_ROUTER_COST_REPORT: no usage data found; nothing written.")
        return

    latest_md = None
    for report in sorted(reports, key=lambda r: (r["iso_year"], r["iso_week"])):
        md = render_markdown(report)
        out_html = render_html(report)
        (out_dir / f"weekly-{report['label']}.md").write_text(md, encoding="utf-8")
        (out_dir / f"weekly-{report['label']}.html").write_text(out_html, encoding="utf-8")
        latest_md = md
    if latest_md is not None:
        (out_dir / "latest.md").write_text(latest_md, encoding="utf-8")

    last = reports[-1]
    lines = [f"DT_MODEL_ROUTER_COST_REPORT: {len(reports)} week(s) written; latest {last['label']}:"]
    for host in ("claude", "codex"):
        vw = last["vendors"].get(host)
        if vw:
            lines.append(f"  {vw.label}: subscription {fmt_usd(vw.subscription_usd)} vs "
                         f"API-equivalent {fmt_usd(vw.api_equivalent_usd)} "
                         f"({len(vw.dates_seen)} of {len(vw.dates_seen) + len(vw.gap_dates)} ET days covered)")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
