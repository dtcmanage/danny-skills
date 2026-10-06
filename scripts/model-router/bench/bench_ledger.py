"""Bench ledger: one row per finished comparison tier, appended automatically by the engine.

The ledger (`<state>/bench/ledger.jsonl`) is the long-run statistics record for the internal
benchmark: what was compared, how it went, how long it took, what it cost, and how much weekly
quota it moved. Reports stay the evidence; the ledger is the thing to chart over time.

    python bench_ledger.py --state <state> --summary            # table of rows, newest last
    python bench_ledger.py --state <state> --backfill <report.json> [...]
"""
from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _percent(reading: Any) -> float | None:
    if not isinstance(reading, dict):
        return None
    usage = reading.get('usage', reading)
    value = usage.get('used_percent') if isinstance(usage, dict) else None
    return float(value) if isinstance(value, (int, float)) else None


def _lane(result: dict[str, Any], vendor: str) -> dict[str, Any]:
    data = (result.get('telemetry') or {}).get(vendor) or {}
    calls = [c for c in result.get('calls', []) if c.get('vendor') == vendor]
    timed = sorted(c['duration_ms'] for c in calls if isinstance(c.get('duration_ms'), int))
    before, after = _percent(data.get('quota_before')), _percent(data.get('quota_after'))
    return {
        'calls': len(calls),
        'answer_calls': sum(c.get('purpose') == 'answer' for c in calls),
        'judge_calls': sum(c.get('purpose') != 'answer' for c in calls),
        'dispatch_failures': sum(c.get('status') != 'ok' for c in calls),
        'measured_calls': data.get('measured_calls'),
        'tokens': data.get('tokens') or {},
        'priced_subtotal_usd': round(float(data.get('priced_subtotal_usd') or 0.0), 4),
        'unpriced_calls': data.get('unpriced_calls'),
        'duration_ms_total': sum(timed) if timed else None,
        'duration_ms_p50': timed[len(timed) // 2] if timed else None,
        'duration_ms_max': timed[-1] if timed else None,
        'quota_before_percent': before,
        'quota_after_percent': after,
        'quota_points_moved': round(after - before, 2) if before is not None and after is not None else None,
    }


def ledger_row(result: dict[str, Any]) -> dict[str, Any]:
    """Flatten one tier result (or a single-tier job result) into a ledger row."""
    configurations = result.get('configurations') or {}
    tables = {name: result.get(name) for name in ('candidate', 'incumbent', 'effort_down', 'effort_up')}
    quality = result.get('quality_verdict') or {}
    rows = result.get('outcomes', [])
    return {
        'at_utc': result.get('finished_at_utc') or datetime.now(timezone.utc).isoformat(),
        'run_id': Path(result['report_paths']['json']).parent.name if result.get('report_paths') else None,
        'job': result.get('job'), 'tier': result.get('tier', 'standard'), 'trigger': result.get('trigger'),
        'candidate': configurations.get('candidate'), 'incumbent': configurations.get('incumbent'),
        'bank_sha256': result.get('task_bank_sha256'),
        'judges': result.get('judge_pair'), 'judge_effort': result.get('judge_effort'),
        'shadow': result.get('shadow'), 'halted': bool(result.get('halted')),
        'gate': result.get('gate'), 'raw_gate': result.get('raw_gate'),
        'tied': result.get('tied'), 'better': result.get('better'),
        'shortfall_tasks': result.get('shortfall_tasks'),
        'effort_down_qualified': result.get('effort_down_qualified'),
        'effort_up_qualified': result.get('effort_up_qualified'),
        'quality_verdict': quality.get('verdict') if isinstance(quality, dict) else None,
        'tasks': {name: {'passed': table.get('passed'), 'unknown': table.get('unknown'), 'count': len(table.get('tasks', []))}
                  for name, table in tables.items() if isinstance(table, dict)},
        'answer_reps': len(rows),
        'private_reps': sum(bool(r.get('private')) for r in rows),
        'fabrications': result.get('fabrications'),
        'started_at_utc': result.get('started_at_utc'),
        'wall_seconds': result.get('wall_seconds'),
        'claude': _lane(result, 'claude'), 'codex': _lane(result, 'codex'),
        'spend_rules': [r.get('rule') for r in (result.get('spend') or {}).get('rules_in_force', [])],
    }


def append_ledger(bench_state: Path, result: dict[str, Any]) -> list[dict[str, Any]]:
    """Append a row per tier (or one row for a single-tier job). Never raises into the engine."""
    rows = [ledger_row(tier) for tier in result.get('tiers') or [result]]
    try:
        bench_state.mkdir(parents=True, exist_ok=True)
        with (bench_state / 'ledger.jsonl').open('a', encoding='utf-8') as stream:
            for row in rows:
                stream.write(json.dumps(row, ensure_ascii=False) + '\n')
    except OSError:
        pass
    return rows


def read_ledger(bench_state: Path) -> list[dict[str, Any]]:
    path = bench_state / 'ledger.jsonl'
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]


def summary_lines(rows: list[dict[str, Any]]) -> list[str]:
    lines = ['| Finished (UTC) | Job/tier | Candidate vs incumbent | Gate | Verdict | Wall | Calls C/X | USD (priced) | Quota moved C/X |',
             '| --- | --- | --- | --- | --- | --- | --- | --- | --- |']
    for row in rows:
        c, x = row.get('claude', {}), row.get('codex', {})
        verdict = 'tied' if row.get('tied') else (row.get('better') or ('halted' if row.get('halted') else '-'))
        cfg = lambda k: f"{(row.get(k) or {}).get('model')}/{(row.get(k) or {}).get('effort')}"
        wall = row.get('wall_seconds')
        lines.append(f"| {str(row.get('at_utc', ''))[:16]} | {row.get('job')}/{row.get('tier')} | {cfg('candidate')} vs {cfg('incumbent')} | "
                     f"{row.get('gate')} | {verdict} | {f'{wall / 60:.0f} min' if isinstance(wall, (int, float)) else '-'} | "
                     f"{c.get('calls')}/{x.get('calls')} | {c.get('priced_subtotal_usd', 0) + x.get('priced_subtotal_usd', 0):.2f} | "
                     f"{c.get('quota_points_moved')}/{x.get('quota_points_moved')} |")
    return lines


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--state', required=True, help='router state directory')
    parser.add_argument('--backfill', nargs='*', default=[], help='report.json files to append (skips run ids already present)')
    parser.add_argument('--summary', action='store_true')
    arguments = parser.parse_args()
    bench_state = Path(arguments.state) / 'bench'
    if arguments.backfill:
        present = {(row.get('run_id'), row.get('tier')) for row in read_ledger(bench_state)}
        for report in arguments.backfill:
            result = json.loads(Path(report).read_text(encoding='utf-8'))
            tiers = result.get('tiers') or [result]
            fresh = [t for t in tiers if (Path(t['report_paths']['json']).parent.name, t.get('tier', 'standard')) not in present]
            if fresh:
                present.update((row['run_id'], row['tier']) for row in append_ledger(bench_state, {'tiers': fresh}))
            print(f'{report}: {len(fresh)} row(s) appended')
    if arguments.summary:
        print('\n'.join(summary_lines(read_ledger(bench_state))))


if __name__ == '__main__':
    main()
