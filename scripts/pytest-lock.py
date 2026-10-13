"""Machine-wide pytest serialization. Callable from Python, PowerShell or Bash.

Use: python scripts/pytest-lock.py -- python -m pytest ...
Nested graders reuse only a verified ancestor's OS-held lock, never env alone.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid
from zoneinfo import ZoneInfo

ROOT = Path('C:/ProgramData/DannyPytest') if os.name == 'nt' else Path('/tmp/danny-pytest-machine')
LOCK = ROOT / 'exclusive.lock'
STATUS = ROOT / 'holder.json'


def processes() -> list[dict]:
    if os.name == 'nt':
        result = subprocess.run(['pwsh', '-NoProfile', '-Command',
            'Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,CommandLine,CreationDate | ConvertTo-Json -Compress'],
            capture_output=True, text=True, check=True, timeout=10)
        return json.loads(result.stdout) or []
    result = subprocess.run(['ps', '-eo', 'pid=,ppid=,lstart=,args='],
                            capture_output=True, text=True, check=True, timeout=10)
    return [dict(ProcessId=int(parts[0]), ParentProcessId=int(parts[1]),
                 CreationDate=' '.join(parts[2:7]), CommandLine=parts[7])
            for line in result.stdout.splitlines() for parts in [line.strip().split(None, 7)]]


def ancestors(rows: list[dict]) -> set[int]:
    parents = {r['ProcessId']: r['ParentProcessId'] for r in rows}
    found: set[int] = set()
    pid = os.getpid()
    while pid and pid not in found:
        found.add(pid)
        pid = parents.get(pid, 0)
    return found


def acquire(handle) -> None:
    handle.seek(0)
    if os.name == 'nt':
        import msvcrt
        msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
    else:
        import fcntl
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)


def actual_pytest(row: dict) -> bool:
    import re
    command = row.get('CommandLine') or ''
    executable = row.get('Name') or command.split(' ', 1)[0].rsplit('/', 1)[-1]
    if not re.match(r'(?i)^(?:python(?:w|3(?:\.\d+)?)?|pytest)(?:\.exe)?$', executable):
        return False
    # Introspection and launchers that merely mention pytest are not test processes.
    return bool(re.search(r'(?i)(?:^|[\\/\s"\x27])pytest(?:\.exe)?["\x27]?(?:\s|$)|\s-m\s+pytest\b|import pytest;.*pytest\.main', command)) and not bool(
        re.search(r'(?i)Get-CimInstance|pytest-lock\.(?:py|ps1)', command))


@contextmanager
def pytest_lock(timeout: float = 1800):
    ROOT.mkdir(parents=True, exist_ok=True)
    handle = LOCK.open('a+b')
    if LOCK.stat().st_size == 0:
        handle.write(b'0'); handle.flush()
    deadline = time.monotonic() + timeout
    inherited = False
    owned = False
    last_notice = float("-inf")
    old_token = os.environ.get('DANNY_PYTEST_OWNER')
    try:
        while True:
            try:
                acquire(handle)
                owned = True
                break
            except OSError:
                try:
                    holder = json.loads(STATUS.read_text())
                    rows = processes() if old_token else []
                    owner = next((r for r in rows if r['ProcessId'] == holder['pid']), None)
                    if (holder.get('state') == 'held' and old_token and old_token == holder['token'] and holder['pid'] in ancestors(rows)
                            and owner and owner.get('CreationDate') == holder.get('process_start')):
                        inherited = True
                        break
                    if time.monotonic() - last_notice >= 30:
                        print('PYTEST_LOCK waiting: ' + json.dumps(holder), file=sys.stderr, flush=True)
                        last_notice = time.monotonic()
                except (OSError, ValueError, KeyError):
                    pass
                if time.monotonic() >= deadline:
                    raise TimeoutError('PYTEST_LOCK_TIMEOUT: holder ' +
                                       (json.dumps(holder) if 'holder' in locals() else 'unavailable'))
                time.sleep(min(1, max(0, deadline - time.monotonic())))
        if not inherited:
            rows = processes()
            owner = next(r for r in rows if r['ProcessId'] == os.getpid())
            token = uuid.uuid4().hex
            STATUS.write_text(json.dumps(dict(state='held', pid=os.getpid(), command=' '.join(sys.argv)[:800],
                start_et=datetime.now(ZoneInfo('America/New_York')).isoformat() + ' ET',
                process_start=owner.get('CreationDate'), token=token)))
            os.environ['DANNY_PYTEST_OWNER'] = token
        # Before ANY pytest, inspect actual test processes. Verified family ancestors
        # are the outer pytest grader, not a competing run. Never terminate a caller.
        while True:
            rows = processes()
            family = ancestors(rows) if inherited else {os.getpid()}
            live = [r for r in rows if r['ProcessId'] not in family and actual_pytest(r)]
            if not live:
                break
            print('PYTEST_LOCK live pytest; recheck in 30 sec: ' + json.dumps(live), file=sys.stderr, flush=True)
            if time.monotonic() >= deadline:
                raise TimeoutError('PYTEST_LOCK_TIMEOUT: live pytest ' + json.dumps(live))
            time.sleep(min(30, max(0, deadline - time.monotonic())))
        yield
    finally:
        try:
            if owned:
                try:
                    holder = json.loads(STATUS.read_text())
                    if holder['pid'] == os.getpid():
                        holder['state'] = 'released'
                        STATUS.write_text(json.dumps(holder))
                except (OSError, ValueError, KeyError):
                    pass
        finally:
            # Close releases the OS lock even after errors; crash release is automatic.
            handle.close()
        if old_token is None:
            os.environ.pop('DANNY_PYTEST_OWNER', None)
        else:
            os.environ['DANNY_PYTEST_OWNER'] = old_token


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--timeout', type=float, default=1800)
    parser.add_argument('--ready-file', type=Path)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('a command is required after --')
    with pytest_lock(args.timeout):
        if args.ready_file is not None:
            args.ready_file.write_text('acquired', encoding='utf-8')
        return subprocess.call(command)


if __name__ == '__main__':
    raise SystemExit(main())
