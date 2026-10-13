"""Fixture-scoped dry run: compare collection and output without installing.

python scripts/compare-pytest-guard.py -- <pytest selection and arguments>
Runs each collection/selection twice, sequentially, under the explicit lock.
"""
from __future__ import annotations

import difflib
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys

SCRIPTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('dryrun_pytest_lock', SCRIPTS / 'pytest-lock.py')
lock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lock)


def normalized(output: str) -> str:
    # Remove only pytest timing summaries/durations; retain warnings and results.
    lines = []
    for line in output.splitlines():
        if re.match(r'^=+ .* in [\d.]+s.* =+$', line):
            # pytest centers the summary based on the duration's digit count.
            lines.append(re.sub(r' in [\d.]+s(?: \([^)]*\))?', '', line.strip('= ')))
        elif re.match(r'^\d+(?: tests?)? (?:passed|failed|collected|deselected|skipped|warnings?)', line):
            lines.append(re.sub(r' in [\d.]+s(?: \([^)]*\))?', '', line))
        elif not re.match(r'^\d+\.\d+s (?:setup|call|teardown)\s', line):
            lines.append(line)
    return '\n'.join(lines) + '\n'


def main() -> int:
    selection = sys.argv[1:]
    if selection[:1] == ['--']:
        selection = selection[1:]
    if not selection:
        raise SystemExit('Supply a pytest selection after --')
    baseline = lock.sealed_environment(dict(os.environ))
    baseline['DANNY_PYTEST_GUARD'] = '0'
    guarded = dict(baseline, DANNY_PYTEST_GUARD='1', DANNY_PYTEST_GUARD_DIR=str(SCRIPTS / 'pytest-guard'))
    guarded['PYTEST_PLUGINS'] = ','.join(filter(None, [baseline.get('PYTEST_PLUGINS'), lock.GUARD_MODULE]))
    guarded['PYTHONPATH'] = os.pathsep.join(filter(None, [baseline.get('PYTHONPATH'), guarded['DANNY_PYTEST_GUARD_DIR']]))
    failed = False
    for phase, extra in [('collection', ['--collect-only']), ('selection', [])]:
        outputs = []
        for label, env in [('without', baseline), ('with', guarded)]:
            # Direct context preserves the guard in the trial child; the guard
            # verifies and reuses this ancestor instead of taking a second lock.
            with lock.pytest_lock():
                child_env = dict(env, DANNY_PYTEST_OWNER=os.environ['DANNY_PYTEST_OWNER'])
                result = subprocess.run([sys.executable, '-m', 'pytest', *selection, *extra],
                                        env=child_env, capture_output=True, text=True)
            outputs.append((result.returncode, normalized(result.stdout), normalized(result.stderr)))
            count = re.findall(r'\bcollected \d+ items?\b|\b\d+ (?:tests? collected|collected|selected|deselected)\b', result.stdout)
            print(f'{phase} {label}: exit={result.returncode}; counts={count}')
        for stream in (1, 2):
            diff = ''.join(difflib.unified_diff(outputs[0][stream].splitlines(True), outputs[1][stream].splitlines(True),
                                              fromfile=f'{phase}-without', tofile=f'{phase}-with'))
            if diff:
                print(diff, end='')
                failed = True
        if outputs[0][0] != outputs[1][0] or outputs[0][0] != 0:
            failed = True
    print('PASS: identical collection/output (timing excluded)' if not failed else 'FAIL: review differences above')
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())
