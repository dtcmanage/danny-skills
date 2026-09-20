"""Collect dt-build token usage from Claude Code and Codex session logs.

Sweeps every session log on this machine, keeps the ones that ran dt-build (as
orchestrator or as a wrapper-launched chunk), and writes:

  usage-ledger-<machine>.jsonl   one row per session, rewritten atomically
  (machine-local) collector-state.json: incremental parse cache + already-alerted flags
  usage-dashboard.html           all machines' ledgers, grouped by run

Read-only against the session logs. Incremental: unchanged files are not re-parsed.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import socket
import statistics
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

ORCH_MARKERS = (b"verify-milestone-acceptance.ps1", b"write-build-state.ps1")
ORCH_CALL_RE = re.compile(r"(?:verify-milestone-acceptance|write-build-state)\.ps1[\\\"']*\s+-[A-Za-z]")
CHUNK_MARKER = b"bundle_sha256:"
RUN_ID_RE = re.compile(r"\.dt-build[\\/]+([A-Za-z0-9][A-Za-z0-9._-]{2,80})")
VERSION_RE = re.compile(r"name:\s*dt-build[\s\S]{0,1500}?version:\s*(\d+\.\d+\.\d+)")
CTX_FLAG = 300_000          # peak context above this is flagged
RESUME_FLAG = 5             # follow-up messages to live agents above this is flagged
IDLE_MINUTES = 5            # cache TTL; a big re-write after this gap is an idle loss
BIG_REWRITE = 50_000


def weighted(inp: int, cache_write: int, cache_read: int, out: int) -> int:
    """Approximate input-equivalent tokens; ratios only, not dollars."""
    return int(inp + 1.25 * cache_write + 0.1 * cache_read + 5 * out)


def parse_ts(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def family(model: str | None) -> str:
    m = (model or "unset").lower()
    for key in ("opus", "sonnet", "haiku", "fable", "sol", "terra", "luna"):
        if key in m:
            return key
    return m


def tally_claude(path: Path) -> dict:
    """Token and dispatch tally for one Claude Code transcript (main or subagent)."""
    seen: set[str] = set()
    models: dict[str, Counter] = defaultdict(Counter)
    sizes: list[int] = []
    agent_models: Counter = Counter()
    idle_n = idle_tokens = 0
    codex_wrapper = claude_wrapper = send_message = orch_cmds = 0
    run_ids: Counter = Counter()
    first_user = version = None
    started = ended = prev = None
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            msg = row.get("message") or {}
            content = msg.get("content")
            stamp = row.get("timestamp")
            if stamp:
                started = started or stamp
                ended = stamp
            if row.get("type") == "user":
                text = content if isinstance(content, str) else json.dumps(content, ensure_ascii=False)
                if first_user is None:
                    first_user = text[:4000]
                if version is None and "dt-build" in text:
                    found = VERSION_RE.search(text)
                    if found:
                        version = found.group(1)
                continue
            if row.get("type") != "assistant":
                continue
            for block in content or []:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                inp = block.get("input") or {}
                name = block.get("name")
                if name in ("Agent", "Task"):
                    agent_models[family(inp.get("model"))] += 1
                elif name == "SendMessage":
                    send_message += 1
                cmd = str(inp.get("command") or "")
                if cmd:
                    for hit in RUN_ID_RE.findall(cmd):
                        run_ids[hit] += 1
                    # Only an executed dt-build gate marks an orchestrator; a session that
                    # merely reads or discusses the scripts is not a build run.
                    # A heredoc that merely contains the script name (skill authoring) is not a gate run.
                    orch_cmds += bool(ORCH_CALL_RE.search(cmd)) and "<<" not in cmd
                    if "-Preflight" not in cmd:
                        codex_wrapper += "invoke-codex-chunk" in cmd
                        claude_wrapper += "invoke-claude-chunk" in cmd
            mid = msg.get("id")
            if not mid or mid in seen:
                continue
            seen.add(mid)
            usage = msg.get("usage") or {}
            cw = usage.get("cache_creation_input_tokens") or 0
            cr = usage.get("cache_read_input_tokens") or 0
            inp_t = usage.get("input_tokens") or 0
            bucket = models[msg.get("model") or "?"]
            bucket["calls"] += 1
            bucket["in"] += inp_t
            bucket["cw"] += cw
            bucket["cr"] += cr
            bucket["out"] += usage.get("output_tokens") or 0
            if inp_t + cw + cr:
                sizes.append(inp_t + cw + cr)
            now = parse_ts(stamp)
            if cw > BIG_REWRITE and prev and now and (now - prev).total_seconds() > IDLE_MINUTES * 60:
                idle_n += 1
                idle_tokens += cw
            prev = now or prev
    models.pop("<synthetic>", None)
    return {
        "models": {k: dict(v) for k, v in models.items()},
        "calls": len(sizes),
        "ctx_median": int(statistics.median(sizes)) if sizes else 0,
        "ctx_max": max(sizes) if sizes else 0,
        "idle_rewrites": idle_n,
        "idle_rewrite_tokens": idle_tokens,
        "agent_dispatch": dict(agent_models),
        "codex_wrapper": int(codex_wrapper),
        "claude_wrapper": int(claude_wrapper),
        "send_message": send_message,
        "orch_cmds": int(orch_cmds),
        "run_ids": run_ids,
        "first_user": first_user or "",
        "version": version,
        "started": started,
        "ended": ended,
    }


def claude_row(path: Path, raw: bytes) -> dict | None:
    is_orch = any(marker in raw for marker in ORCH_MARKERS)
    is_chunk = CHUNK_MARKER in raw
    if not (is_orch or is_chunk):
        return None
    main = tally_claude(path)
    header = main["first_user"].lstrip().lstrip('"').lstrip()
    role = "chunk" if header.startswith("RUN_ID:") else ("orchestrator" if main["orch_cmds"] else None)
    if role is None:
        return None
    run_id = None
    if role == "chunk":
        found = re.search(r"RUN_ID:\s*([^\s\\\"]+)", header)
        run_id = found.group(1) if found else None
        chunk = re.search(r"chunk_id:\s*([^\s\\\"]+)", header)
    elif main["run_ids"]:
        run_id = main["run_ids"].most_common(1)[0][0]
    subagents = []
    nested = 0
    sub_dir = path.with_suffix("") / "subagents"
    if sub_dir.is_dir():
        for sub in sorted(sub_dir.glob("*.jsonl")):
            t = tally_claude(sub)
            spawned = sum(t["agent_dispatch"].values())
            nested += spawned
            top = max(t["models"].items(), key=lambda kv: kv[1].get("calls", 0))[0] if t["models"] else "?"
            subagents.append({
                "name": sub.stem[:60], "model": top, "calls": t["calls"], "ctx_max": t["ctx_max"],
                "idle_rewrites": t["idle_rewrites"], "idle_rewrite_tokens": t["idle_rewrite_tokens"],
                "spawned_agents": spawned, "models": t["models"],
            })
    totals: Counter = Counter()
    by_family: Counter = Counter()
    for source in [main] + subagents:
        for model, m in source["models"].items():
            for key in ("in", "cw", "cr", "out"):
                totals[key] += m.get(key, 0)
            by_family[family(model)] += weighted(m.get("in", 0), m.get("cw", 0), m.get("cr", 0), m.get("out", 0))
    row = {
        "session_id": path.stem, "host": "claude", "role": role, "run_id": run_id,
        "chunk_id": chunk.group(1) if role == "chunk" and chunk else None,
        "project": path.parent.name[-60:], "skill_version": main["version"],
        "started": main["started"], "ended": main["ended"],
        "orchestrator_model": max(main["models"].items(), key=lambda kv: kv[1].get("calls", 0))[0] if main["models"] else None,
        "calls": main["calls"], "ctx_median": main["ctx_median"], "ctx_max": main["ctx_max"],
        "idle_rewrites": main["idle_rewrites"] + sum(s["idle_rewrites"] for s in subagents),
        "idle_rewrite_tokens": main["idle_rewrite_tokens"] + sum(s["idle_rewrite_tokens"] for s in subagents),
        "agent_dispatch": main["agent_dispatch"], "codex_wrapper": main["codex_wrapper"],
        "claude_wrapper": main["claude_wrapper"], "send_message": main["send_message"],
        "nested_agents": nested,
        "subagent_ctx_max": max((s["ctx_max"] for s in subagents), default=0),
        "subagents": [{k: v for k, v in s.items() if k != "models"} for s in subagents],
        "tokens": dict(totals), "weighted_by_family": dict(by_family),
        "weighted_total": sum(by_family.values()),
    }
    return row


def codex_row(path: Path, raw: bytes) -> dict | None:
    is_orch = any(marker in raw for marker in ORCH_MARKERS)
    is_chunk = CHUNK_MARKER in raw
    if not (is_orch or is_chunk):
        return None
    meta: dict = {}
    total: dict = {}
    ctx: list[int] = []
    run_ids: Counter = Counter()
    claude_wrapper = codex_wrapper = orch_cmds = 0
    first_user = None
    started = ended = None
    limit_pct = None
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            stamp = row.get("timestamp")
            if stamp:
                started = started or stamp
                ended = stamp
            payload = row.get("payload") or {}
            kind = payload.get("type")
            if row.get("type") == "session_meta":
                meta.update(cwd=payload.get("cwd"), cli=payload.get("cli_version"), sid=payload.get("id"))
            elif row.get("type") == "turn_context":
                meta.setdefault("model", payload.get("model"))
                meta.setdefault("effort", payload.get("effort"))
            elif kind == "token_count":
                info = payload.get("info") or {}
                total = info.get("total_token_usage") or total
                last = (info.get("last_token_usage") or {}).get("input_tokens")
                if last:
                    ctx.append(last)
                primary = (payload.get("rate_limits") or {}).get("primary") or {}
                limit_pct = primary.get("used_percent", limit_pct)
            elif kind == "message" and payload.get("role") == "user" and first_user is None:
                first_user = json.dumps(payload.get("content"), ensure_ascii=False)[:4000]
            elif kind in ("custom_tool_call", "function_call", "local_shell_call"):
                text = json.dumps(payload, ensure_ascii=False)
                for hit in RUN_ID_RE.findall(text):
                    run_ids[hit] += 1
                orch_cmds += bool(ORCH_CALL_RE.search(text))
                if "-Preflight" not in text:
                    claude_wrapper += "invoke-claude-chunk" in text
                    codex_wrapper += "invoke-codex-chunk" in text
    header = first_user or ""
    chunk_header = re.search(r"RUN_ID:\s*([^\s\\\"]+)[\s\S]{0,200}?chunk_id:\s*([^\s\\\"]+)", header)
    role = "chunk" if chunk_header and "bundle_sha256" in header else ("orchestrator" if orch_cmds else None)
    if role is None:
        return None
    inp = total.get("input_tokens", 0)
    cached = total.get("cached_input_tokens", 0)
    out = total.get("output_tokens", 0)
    score = weighted(inp - cached, total.get("cache_write_input_tokens", 0), cached, out)
    return {
        "session_id": meta.get("sid") or path.stem, "host": "codex", "role": role,
        "run_id": chunk_header.group(1) if role == "chunk" else (run_ids.most_common(1)[0][0] if run_ids else None),
        "chunk_id": chunk_header.group(2) if role == "chunk" else None,
        "project": Path(str(meta.get("cwd") or "")).name[-60:], "skill_version": None,
        "started": started, "ended": ended, "orchestrator_model": meta.get("model"),
        "effort": meta.get("effort"), "calls": len(ctx),
        "ctx_median": int(statistics.median(ctx)) if ctx else 0, "ctx_max": max(ctx, default=0),
        "idle_rewrites": 0, "idle_rewrite_tokens": 0, "agent_dispatch": {},
        "codex_wrapper": int(codex_wrapper), "claude_wrapper": int(claude_wrapper),
        "send_message": 0, "nested_agents": 0, "subagent_ctx_max": 0, "subagents": [],
        "tokens": {"in": inp - cached, "cw": total.get("cache_write_input_tokens", 0), "cr": cached, "out": out},
        "weighted_by_family": {family(meta.get("model")): score}, "weighted_total": score,
        "codex_limit_used_pct": limit_pct,
    }


def flags_for(row: dict) -> list[str]:
    found = []
    peak = max(row.get("ctx_max", 0), row.get("subagent_ctx_max", 0))
    if peak > CTX_FLAG:
        found.append(f"context peaked at {peak // 1000}K")
    if row.get("nested_agents"):
        found.append(f"{row['nested_agents']} nested agents")
    if row.get("send_message", 0) > RESUME_FLAG:
        found.append(f"{row['send_message']} resume messages")
    if row.get("idle_rewrite_tokens", 0) > 1_000_000:
        found.append(f"{row['idle_rewrite_tokens'] // 1_000_000}M tokens lost to idle cache expiry")
    dispatch = row.get("agent_dispatch") or {}
    total = sum(dispatch.values())
    if total >= 4 and dispatch.get("opus", 0) / total > 0.5:
        found.append(f"Opus on {dispatch.get('opus', 0)} of {total} dispatches")
    if dispatch.get("unset"):
        found.append(f"{dispatch['unset']} dispatches with no model set")
    if row.get("host") == "codex" and row.get("claude_wrapper", 0) > 3:
        found.append(f"Codex host called Claude {row['claude_wrapper']} times")
    return found


def sweep(roots: list[tuple[str, Path]], state: dict) -> tuple[list[dict], dict]:
    rows, new_cache = [], {}
    cache = state.get("files", {})
    for host, root in roots:
        if not root.is_dir():
            continue
        pattern = "*/*.jsonl" if host == "claude" else "**/rollout-*.jsonl"
        for path in root.glob(pattern):
            try:
                stat = path.stat()
            except OSError:
                continue
            sub_dir = path.with_suffix("") / "subagents"
            sub_sig = sum(int(p.stat().st_mtime) for p in sub_dir.glob("*.jsonl")) if sub_dir.is_dir() else 0
            sig = [int(stat.st_mtime), stat.st_size, sub_sig]
            key = str(path)
            cached = cache.get(key)
            if cached and cached["sig"] == sig:
                new_cache[key] = cached
                if cached.get("row"):
                    rows.append(cached["row"])
                continue
            try:
                raw = path.read_bytes()
                row = claude_row(path, raw) if host == "claude" else codex_row(path, raw)
            except (OSError, ValueError, KeyError) as err:
                row = None
                print(f"collect-usage: skipped {path.name}: {err}")
            if row:
                row["machine"] = socket.gethostname()
                row["flags"] = flags_for(row)
                rows.append(row)
            new_cache[key] = {"sig": sig, "row": row}
    return rows, new_cache


def merge_flags(flags: list[str]) -> list[str]:
    """One flag per kind for a run; for context peaks keep only the largest."""
    peaks = [f for f in flags if f.startswith("context peaked")]
    rest = sorted({f for f in flags if not f.startswith("context peaked")})
    top = max(peaks, key=lambda f: int(re.search(r"(\d+)K", f).group(1))) if peaks else None
    return ([top] if top else []) + rest


def group_runs(rows: list[dict]) -> list[dict]:
    runs: dict[str, dict] = {}
    for row in rows:
        key = f"{row.get('run_id') or row['session_id'][:8]}"
        run = runs.setdefault(key, {"run": key, "rows": [], "weighted": Counter(), "flags": []})
        run["rows"].append(row)
        run["weighted"].update(row.get("weighted_by_family") or {})
        run["flags"].extend(row.get("flags") or [])
    out = []
    for run in runs.values():
        orch = [r for r in run["rows"] if r["role"] == "orchestrator"]
        lead = (orch or run["rows"])[0]
        out.append({
            "run": run["run"], "project": lead.get("project"), "host": lead.get("host") if orch else f"{lead.get('host')} chunks only",
            "version": next((r.get("skill_version") for r in orch if r.get("skill_version")), None),
            "started": min((r.get("started") or "9") for r in run["rows"]),
            "ended": max((r.get("ended") or "") for r in run["rows"]),
            "sessions": len(run["rows"]), "weighted": dict(run["weighted"]),
            "weighted_total": sum(run["weighted"].values()),
            "peak_ctx": max(max(r.get("ctx_max", 0), r.get("subagent_ctx_max", 0)) for r in run["rows"]),
            "nested": sum(r.get("nested_agents", 0) for r in run["rows"]),
            "resumes": sum(r.get("send_message", 0) for r in run["rows"]),
            "flags": merge_flags(run["flags"]),
        })
    return sorted(out, key=lambda r: r["started"], reverse=True)


def fmt(n: int) -> str:
    if n >= 1_000_000_000:
        return f"{n / 1_000_000_000:.2f}B"
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}K"
    return str(n)


def render(runs: list[dict], out_path: Path, baseline: str) -> None:
    since = [r for r in runs if (r["started"] or "") >= baseline]
    tiles = [
        ("Runs since 2.12.0", str(len(since))),
        ("Runs with nested agents (since 2.12.0)", str(sum(1 for r in since if r["nested"]))),
        ("Median peak context (since 2.12.0)", fmt(int(statistics.median([r["peak_ctx"] for r in since]))) if since else "n/a"),
        ("Median peak context (before)", fmt(int(statistics.median([r["peak_ctx"] for r in runs if r not in since] or [0])))),
        ("Flagged runs (since 2.12.0)", str(sum(1 for r in since if r["flags"]))),
    ]
    top = max((r["weighted_total"] for r in runs), default=1) or 1
    body = []
    for r in runs:
        fam = ", ".join(f"{html.escape(k)} {fmt(v)}" for k, v in sorted(r["weighted"].items(), key=lambda kv: -kv[1]))
        flags = "".join(f"<span class='flag'>{html.escape(f)}</span>" for f in r["flags"]) or "<span class='ok'>clean</span>"
        bar = int(100 * r["weighted_total"] / top)
        new = " class='new'" if (r["started"] or "") >= baseline else ""
        body.append(
            f"<tr{new}><td>{html.escape((r['started'] or '')[:10])}</td><td><b>{html.escape(r['run'])}</b><br>"
            f"<small>{html.escape(r['project'] or '')}</small></td><td>{html.escape(str(r['host']))}<br><small>{html.escape(r['version'] or '')}</small></td>"
            f"<td>{r['sessions']}</td><td><div class='bar'><i style='width:{bar}%'></i></div>{fmt(r['weighted_total'])}<br><small>{fam}</small></td>"
            f"<td>{fmt(r['peak_ctx'])}</td><td>{r['nested']}</td><td>{r['resumes']}</td><td>{flags}</td></tr>")
    tile_html = "".join(f"<div class='tile'><div class='v'>{html.escape(v)}</div><div class='l'>{html.escape(l)}</div></div>" for l, v in tiles)
    page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><title>dt-build usage</title>
<meta name="viewport" content="width=device-width,initial-scale=1"><style>
body{{font:14px/1.45 "Myriad Pro","Segoe UI",system-ui,sans-serif;margin:24px;color:#1b2430;background:#fff}}
h1{{font-size:20px;margin:0 0 4px}} p{{color:#5b6775;margin:0 0 16px}}
.tiles{{display:flex;flex-wrap:wrap;gap:12px;margin:0 0 20px}} .tile{{border:1px solid #d9dee5;border-radius:3px;padding:10px 14px;min-width:150px}}
.v{{font-size:22px;font-weight:600}} .l{{color:#5b6775;font-size:12px}}
table{{border-collapse:collapse;width:100%}} th,td{{text-align:left;padding:7px 9px;border-bottom:1px solid #e6e9ee;vertical-align:top}}
th{{font-size:12px;color:#5b6775;position:sticky;top:0;background:#fff}} small{{color:#7a8594}} tr.new td:first-child{{border-left:3px solid #2f6f4f}}
.bar{{background:#eef1f5;height:6px;border-radius:2px;margin-bottom:3px;width:160px}} .bar i{{display:block;height:6px;background:#2d5d8a;border-radius:2px}}
.flag{{display:inline-block;background:#fdecea;color:#8a2a21;border-radius:2px;padding:1px 6px;margin:1px 3px 1px 0;font-size:12px}} .ok{{color:#2f6f4f;font-size:12px}}
</style></head><body><h1>dt-build usage</h1>
<p>One row per build run, newest first. Green edge = run started on or after {html.escape(baseline)} (dt-build 2.12.0).
Weighted tokens = input + 1.25 x cache writes + 0.1 x cache reads + 5 x output: a rough cost ratio, not dollars.
Generated {datetime.now().strftime('%Y-%m-%d %H:%M')}.</p><div class="tiles">{tile_html}</div>
<table><thead><tr><th>Date</th><th>Run</th><th>Host</th><th>Sessions</th><th>Weighted tokens</th><th>Peak context</th><th>Nested agents</th><th>Resume msgs</th><th>Flags</th></tr></thead>
<tbody>{''.join(body)}</tbody></table></body></html>"""
    out_path.write_text(page, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=None, help="output folder")
    parser.add_argument("--baseline", default="2026-09-20", help="ISO date the current policy took effect")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parents[3]
    out_dir = args.out or repo_root.parent / "dt-build-token-efficiency" / "usage"
    out_dir.mkdir(parents=True, exist_ok=True)
    machine = socket.gethostname()
    # The parse cache is machine-local scratch; keep it out of the synced workspace.
    cache_home = Path(os.environ.get("DT_BUILD_USAGE_CACHE")
                      or Path(os.environ.get("LOCALAPPDATA") or Path.home() / ".cache") / "dt-build-usage")
    cache_home.mkdir(parents=True, exist_ok=True)
    state_path = cache_home / "collector-state.json"
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        state = {}
    claude_home = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    codex_home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    rows, cache = sweep([("claude", claude_home / "projects"), ("codex", codex_home / "sessions")], state)
    rows.sort(key=lambda r: r.get("started") or "")
    ledger = out_dir / f"usage-ledger-{machine}.jsonl"
    tmp = ledger.with_suffix(".tmp")
    tmp.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    tmp.replace(ledger)
    all_rows = []
    for other in out_dir.glob("usage-ledger-*.jsonl"):
        all_rows += [json.loads(line) for line in other.read_text(encoding="utf-8").splitlines() if line.strip()]
    runs = group_runs(all_rows)
    dashboard = out_dir / "usage-dashboard.html"
    render(runs, dashboard, args.baseline)
    alerted = set(state.get("alerted", []))
    fresh = [r for r in rows if r.get("flags") and (r.get("started") or "") >= args.baseline and r["session_id"] not in alerted]
    state_path.write_text(json.dumps({"files": cache, "alerted": sorted(alerted | {r["session_id"] for r in fresh})}), encoding="utf-8")
    since = [r for r in runs if (r["started"] or "") >= args.baseline]
    print(f"DT_BUILD_USAGE: {len(runs)} runs tracked, {len(since)} since {args.baseline}; dashboard {dashboard}")
    for row in fresh:
        print(f"DT_BUILD_USAGE_ALERT: {row.get('run_id') or row['session_id'][:8]} ({row['host']} {row['role']}): {'; '.join(row['flags'])}")
    if not args.quiet and not fresh and since:
        print("DT_BUILD_USAGE: no new flags.")


if __name__ == "__main__":
    main()
