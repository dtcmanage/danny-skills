"""Read-only bench history analysis; unknown/ungraded rows never enter pass rates.

python bench_outcomes.py --state <router-state> --quota-blocked
python bench_outcomes.py --state <router-state> --summary
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import json
from pathlib import Path
from typing import Any, Iterable


def quota_blocked(row: dict[str, Any]) -> bool:
    response = row.get('response') or {}
    return (row.get('source') == 'bench' and row.get('status') == 'unknown'
            and response.get('failure_category') == 'environment'
            and response.get('detail') == 'quota blocked')


def score_counts(rows: Iterable[dict[str, Any]]) -> dict[str, Any]:
    statuses = [row.get('status') for row in rows]
    passed, failed = statuses.count('pass'), statuses.count('fail')
    return {'passed': passed, 'failed': failed, 'scored': passed + failed,
            'excluded': len(statuses) - passed - failed,
            'pass_rate': passed / (passed + failed) if passed + failed else None}


def read_rows(path: Path) -> Iterable[tuple[int, dict[str, Any]]]:
    with path.open(encoding='utf-8-sig') as stream:
        for number, line in enumerate(stream, 1):
            if line.strip():
                yield number, json.loads(line)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--state', type=Path, required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--quota-blocked', action='store_true', help='JSONL line numbers and complete matching historical rows')
    mode.add_argument('--summary', action='store_true', help='pass/fail-only rates grouped by job, tier, model and effort')
    args = parser.parse_args()
    groups: dict[tuple, list[dict[str, Any]]] = defaultdict(list)
    for number, row in read_rows(args.state / 'outcomes.jsonl'):
        if args.quota_blocked:
            if quota_blocked(row):
                print(json.dumps({'line': number, 'row': row}, ensure_ascii=False))
        elif row.get('source') == 'bench':
            groups[tuple(row.get(key) for key in ('job', 'tier', 'model', 'effort'))].append(row)
    for key, rows in groups.items():
        print(json.dumps(dict(zip(('job', 'tier', 'model', 'effort'), key)) | score_counts(rows)))


if __name__ == '__main__':
    main()
