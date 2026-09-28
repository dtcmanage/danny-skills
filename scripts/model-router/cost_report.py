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
from fnmatch import fnmatchcase
import html
import json
import os
import re
import subprocess
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

ET_ZONE = ZoneInfo("America/New_York")
UTC = timezone.utc

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PRICES_PATH = REPO_ROOT / "references" / "model-router" / "api-prices.json"
FRONTIER_MODELS_PATH = REPO_ROOT / "references" / "model-router" / "frontier-models.json"

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
                          today_et: date | None = None,
                          frontier_path: Path = FRONTIER_MODELS_PATH) -> list[dict]:
    """One report dict per ISO week seen in either the usage rows or the codex rate-limit
    readings, each holding a VendorWeek per vendor that had any signal that week."""
    today_et = today_et or datetime.now(tz=ET_ZONE).date()
    frontier_models = json.loads(frontier_path.read_text(encoding="utf-8"))
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
        work: dict[str, dict] = {}
        frontier_sessions: set[tuple[str, str]] = set()
        frontier_ids: set[str] = set()
        frontier_cost = 0.0
        for host in ("claude", "codex"):
            for row in rows_by_week_host.get((iso_year, iso_week, host), []):
                model = row.get("model") or "unset"
                session = (host, row.get("session_id") or "")
                item = work.setdefault(model, {"model": model, "sessions": set(), "calls": 0,
                                               "api_equivalent_usd": 0.0, "priced": False})
                item["sessions"].add(session)
                item["calls"] += row.get("calls") or 0
                cost, _ = price_usage_row(row, prices)
                if cost is not None:
                    item["api_equivalent_usd"] += cost
                    item["priced"] = True
                is_frontier = (model in frontier_models.get("codex_models", []) if host == "codex"
                               else any(fnmatchcase(model, pattern) for pattern in frontier_models.get("claude_patterns", [])))
                if is_frontier:
                    frontier_ids.add(model)
                    frontier_sessions.add(session)
                    if cost is not None:
                        frontier_cost += cost
        priced_total = sum(item["api_equivalent_usd"] for item in work.values() if item["priced"])
        work_by_model = [
            {"model": item["model"], "sessions": len(item["sessions"]), "calls": item["calls"],
             "api_equivalent_usd": item["api_equivalent_usd"] if item["priced"] else None,
             "share_pct": 100 * item["api_equivalent_usd"] / priced_total if item["priced"] and priced_total else None}
            for item in work.values()
        ]
        work_by_model.sort(key=lambda item: (item["api_equivalent_usd"] is None,
                                              -(item["api_equivalent_usd"] or 0), item["model"]))
        reports.append({"iso_year": iso_year, "iso_week": iso_week, "label": week_label(iso_year, iso_week),
                        "vendors": vendors, "work_by_model": work_by_model,
                        "frontier": {"api_equivalent_usd": frontier_cost, "sessions": len(frontier_sessions),
                                     "model_ids": sorted(frontier_ids)}})
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
    lines.extend(["## Work by model", ""])
    for item in report["work_by_model"]:
        cost = fmt_usd(item["api_equivalent_usd"]) if item["api_equivalent_usd"] is not None else "unpriced"
        share = f"{item['share_pct']:.1f}%" if item["share_pct"] is not None else "n/a"
        lines.append(f"- {item['model']}: {item['sessions']} sessions, {item['calls']} calls, "
                     f"{cost} API-equivalent, {share} of priced cost")
    frontier = report["frontier"]
    if frontier["model_ids"]:
        lines.append(f"Frontier models used: {', '.join(frontier['model_ids'])}, "
                     f"{fmt_usd(frontier['api_equivalent_usd'])} API-equivalent across {frontier['sessions']} sessions")
    else:
        lines.append("Frontier models: none this week")
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

    model_rows = []
    for item in report["work_by_model"]:
        cost = fmt_usd(item["api_equivalent_usd"]) if item["api_equivalent_usd"] is not None else "unpriced"
        share = f"{item['share_pct']:.1f}%" if item["share_pct"] is not None else "n/a"
        model_rows.append(f"<li>{html.escape(item['model'])}: {item['sessions']} sessions, {item['calls']} calls, "
                          f"{cost} API-equivalent, {share} of priced cost</li>")
    frontier = report["frontier"]
    if frontier["model_ids"]:
        ids = html.escape(", ".join(frontier["model_ids"]))
        frontier_line = (f"Frontier models used: {ids}, {fmt_usd(frontier['api_equivalent_usd'])} "
                         f"API-equivalent across {frontier['sessions']} sessions")
    else:
        frontier_line = "Frontier models: none this week"

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
<section><h2>Work by model</h2><ul>{''.join(model_rows)}</ul><p>{frontier_line}</p></section>
</body></html>"""


FRIENDLY_MODEL_NAMES = {
    "gpt-6-sol": "GPT-6 Sol",
    "gpt-6-luna": "GPT-6 Luna",
    "gpt-6-astra": "GPT-6 Astra",
    "gpt-image-2": "gpt-image-2",
    "claude-opus-5-5": "Opus 5.5",
    "claude-sonnet-5": "Sonnet 5",
    "claude-haiku-4-5-20251001": "Haiku 4.5",
    "claude-fable-5-1": "Fable 5.1",
}

ROUTER_JOBS = ("fast", "coder", "deep-thinker", "writer", "illustrator")
DEFAULT_ROSTER_PATH = REPO_ROOT / "references" / "model-router" / "default-roster.json"


def friendly_model_name(model_id: str | None) -> str:
    """Friendly display name for a router model id. Explicit map first, then a small
    generic transform for unmapped claude-* ids (strip the vendor prefix and a trailing
    -YYYYMMDD snapshot date, turn a trailing "name-N-M" version pair into "Name N.M"),
    otherwise the raw id is returned unchanged -- never guessed."""
    if not model_id:
        return ""
    if model_id in FRIENDLY_MODEL_NAMES:
        return FRIENDLY_MODEL_NAMES[model_id]
    if not model_id.startswith("claude-"):
        return model_id
    name = re.sub(r"-\d{8}$", "", model_id[len("claude-"):])
    m = re.match(r"^([a-zA-Z]+)-(\d+)-(\d+)$", name)
    if m:
        return f"{m.group(1).capitalize()} {m.group(2)}.{m.group(3)}"
    m2 = re.match(r"^([a-zA-Z]+)-(\d+)$", name)
    if m2:
        return f"{m2.group(1).capitalize()} {m2.group(2)}"
    return name.replace("-", " ").title()


def _frontier_nickname_from_claude_pattern(pattern: str) -> str:
    base = pattern
    if base.startswith("claude-"):
        base = base[len("claude-"):]
    base = base.rstrip("*").rstrip("-")
    m = re.match(r"^([a-zA-Z]+)", base)
    return m.group(1).capitalize() if m else base


def _frontier_nickname_from_codex_model(model_id: str) -> str:
    friendly = friendly_model_name(model_id)
    parts = friendly.split()
    return parts[-1] if parts else friendly


def format_week_range(monday: date, sunday: date) -> str:
    if monday.month == sunday.month:
        return f"{monday.strftime('%b')} {monday.day}-{sunday.day}"
    return f"{monday.strftime('%b')} {monday.day}-{sunday.strftime('%b')} {sunday.day}"


def previous_complete_iso_week(today_et: date) -> tuple[int, int]:
    """The most recent complete ISO week (Mon-Sun, ET), strictly before the week
    containing today_et."""
    iso_year, iso_week, iso_weekday = today_et.isocalendar()
    monday_this_week = today_et - timedelta(days=iso_weekday - 1)
    prev_monday = monday_this_week - timedelta(days=7)
    y, w, _ = prev_monday.isocalendar()
    return y, w


def _load_json_object(path: Path):
    try:
        if not path.is_file():
            return None
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def _live_roster_jobs(state_dir: Path) -> dict:
    roster_path = state_dir / "roster.json"
    candidate = _load_json_object(roster_path)
    if isinstance(candidate, dict) and isinstance(candidate.get("jobs"), dict):
        return candidate["jobs"]
    default = _load_json_object(DEFAULT_ROSTER_PATH)
    if isinstance(default, dict) and isinstance(default.get("jobs"), dict):
        return default["jobs"]
    return {}


def compute_pending_roster_proposal(state_dir: Path) -> bool:
    """Mirrors approve-router-table.ps1 -Roster: a proposal file's own `approved` field is
    never mutated by -Approve (only <state>/roster.json is), so pending-ness is decided by
    comparing the proposal's job picks against the live, approved roster -- covering a
    partial -Jobs approval, where only some jobs match."""
    try:
        latest = _load_json_object(state_dir / "roster-proposals" / "latest.json")
        if not isinstance(latest, dict) or not latest.get("proposal"):
            return False
        proposal = _load_json_object(Path(str(latest["proposal"])))
        if not isinstance(proposal, dict):
            return False
        roster_path = state_dir / "roster.json"
        live = _load_json_object(roster_path)
        if not isinstance(live, dict) or live.get("approved") is not True:
            # Never approved (or invalid) live state: any proposal on file is pending.
            return True
        proposal_jobs = proposal.get("jobs") or {}
        live_jobs = live.get("jobs") or {}
        for job in ROUTER_JOBS:
            p = proposal_jobs.get(job) or {}
            entry = live_jobs.get(job) or {}
            if p.get("first") != entry.get("first") or p.get("backup") != entry.get("backup"):
                return True
        return False
    except Exception:
        return False


def compute_active_drift_marks(state_dir: Path) -> list[dict]:
    """Active drift marks: entries in drift-marks.json not matched by a drift-declines.json
    entry for the same job/model (approve-router-table.ps1 -DeclineDrift normally removes the
    mark outright; the decline-list cross-check is a defensive extra)."""
    try:
        marks = _load_json_object(state_dir / "drift-marks.json")
        if not isinstance(marks, list):
            return []
        declines = _load_json_object(state_dir / "drift-declines.json")
        declined_pairs = {
            (d.get("job"), d.get("model")) for d in declines if isinstance(d, dict)
        } if isinstance(declines, list) else set()
        active = []
        for m in marks:
            if not isinstance(m, dict):
                continue
            job = m.get("job")
            model = m.get("model")
            if not job or not model:
                continue
            if (job, model) in declined_pairs:
                continue
            active.append(m)
        return active
    except Exception:
        return []


def compute_needs_you_lines(state_dir: Path, repo_root: Path = REPO_ROOT) -> list[str]:
    lines: list[str] = []
    approve_script = repo_root / "scripts" / "model-router" / "approve-router-table.ps1"
    if compute_pending_roster_proposal(state_dir):
        cmd = f'pwsh -NoProfile -File "{approve_script}" -Roster -Show'
        lines.append(f"a proposed change to the model list is waiting for your OK. Review it: `{cmd}`")
    jobs = _live_roster_jobs(state_dir)
    for mark in compute_active_drift_marks(state_dir):
        job = mark.get("job")
        first = mark.get("model")
        backup = (jobs.get(job) or {}).get("backup")
        if not backup:
            continue
        cmd = f'pwsh -NoProfile -File "{approve_script}" -Roster -DeclineDrift -Job {job}'
        lines.append(
            f"the {job} job is on its backup ({friendly_model_name(backup)}) because "
            f"{friendly_model_name(first)} has been underperforming. Decide: `{cmd}`"
        )
    return lines


def render_needs_you(lines: list[str]) -> str:
    if not lines:
        return "Needs you: nothing"
    return "\n".join(["Needs you:"] + [f"- {line}" for line in lines])


def top_models(work_by_model: list[dict], n: int = 3) -> list[dict]:
    priced = [
        m for m in work_by_model
        if m.get("api_equivalent_usd") is not None and m.get("model") not in (None, "unset")
    ]
    return sorted(priced, key=lambda m: -(m.get("share_pct") or 0))[:n]


def render_headline(report: dict) -> str:
    total_api = sum(vw.api_equivalent_usd for vw in report["vendors"].values())
    total_sub = sum(vw.subscription_usd for vw in report["vendors"].values())
    line = f"Your plans covered ${round(total_api):,} of work for ${round(total_sub):,} in subscription cost"
    if total_api < total_sub:
        line += " (API pricing would have been cheaper this week)"
    return line + "."


def render_vendor_lines(vendors: dict) -> list[str]:
    labels = {"claude": "Claude", "codex": "Codex"}
    lines = []
    for host in ("claude", "codex"):
        vw = vendors.get(host)
        if not vw:
            continue
        lines.append(
            f"- {labels[host]}: ${round(vw.api_equivalent_usd):,} of work (at API prices) "
            f"on a ${round(vw.subscription_usd):,}/wk plan"
        )
    return lines


def render_codex_limit_line(vendors: dict) -> str | None:
    vw = vendors.get("codex")
    if not vw:
        return None
    if vw.blocked_minutes is None:
        return "Codex usage limit: no data"
    if vw.blocked_minutes <= 0:
        return "Codex usage limit: never hit"
    minutes = int(round(vw.blocked_minutes))
    hours, mins = divmod(minutes, 60)
    if hours > 0:
        duration = f"{hours}h {mins}m" if mins else f"{hours}h"
    else:
        duration = f"{mins}m"
    return f"Codex usage limit: maxed out for about {duration}"


def render_frontier_line(report: dict, frontier_models: dict) -> str:
    nicknames: list[str] = []
    for pattern in frontier_models.get("claude_patterns", []):
        nick = _frontier_nickname_from_claude_pattern(pattern)
        if nick and nick not in nicknames:
            nicknames.append(nick)
    for model in frontier_models.get("codex_models", []):
        nick = _frontier_nickname_from_codex_model(model)
        if nick and nick not in nicknames:
            nicknames.append(nick)
    label = f"Frontier models ({'/'.join(nicknames)})" if nicknames else "Frontier models"
    frontier = report["frontier"]
    if frontier["model_ids"]:
        names = ", ".join(friendly_model_name(m) for m in frontier["model_ids"])
        return f"{label}: used - {names}, ${round(frontier['api_equivalent_usd']):,} of work at API prices"
    return f"{label}: not used"


def _cap_message(message: str, limit: int = 1500) -> str:
    if len(message) <= limit:
        return message
    return message[: limit - 1].rstrip() + "…"


def render_discord_summary(reports: list[dict], today_et: date, state_dir: Path,
                            repo_root: Path = REPO_ROOT,
                            frontier_path: Path = FRONTIER_MODELS_PATH) -> tuple[str, str]:
    """Build the weekly plain-language Discord DM for the last complete ET week.
    Returns (week_label, message). Never touches state files that must not exist yet;
    read-only against roster/proposal/drift state, all of which may be missing or corrupt."""
    iso_year, iso_week = previous_complete_iso_week(today_et)
    label = week_label(iso_year, iso_week)
    monday, sunday = week_bounds_et(iso_year, iso_week)
    header = f"**Model router - week of {format_week_range(monday, sunday)}**"
    needs_you_text = render_needs_you(compute_needs_you_lines(state_dir, repo_root))

    report = next(
        (r for r in reports if (r["iso_year"], r["iso_week"]) == (iso_year, iso_week)), None
    )
    if report is None:
        message = "\n".join([header, "No model usage was recorded last week.", needs_you_text])
        return label, _cap_message(message)

    frontier_models = json.loads(frontier_path.read_text(encoding="utf-8"))
    lines = [header, render_headline(report)]
    lines.extend(render_vendor_lines(report["vendors"]))
    top = top_models(report["work_by_model"])
    if top:
        most_used = " - ".join(
            f"{friendly_model_name(m['model'])} {round(m['share_pct'])}%" for m in top
        )
        lines.append(f"Most used: {most_used}")
    lines.append(render_frontier_line(report, frontier_models))
    codex_line = render_codex_limit_line(report["vendors"])
    if codex_line:
        lines.append(codex_line)
    lines.append(needs_you_text)
    html_path = state_dir / "cost-reports" / f"weekly-{label}.html"
    lines.append(f"Full report: `{html_path}`")
    return label, _cap_message("\n".join(lines))


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
    else:
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

    label, message = render_discord_summary(reports, datetime.now(tz=ET_ZONE).date(), state_dir)
    discord_path = out_dir / "discord-summary.json"
    discord_path.write_text(
        json.dumps({"key": f"weekly-report:{label}", "message": message}, ensure_ascii=False),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
