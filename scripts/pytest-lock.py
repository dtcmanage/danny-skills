"""Machine-wide pytest serialization. Callable from Python, PowerShell or Bash.

Use: python scripts/pytest-lock.py -- python -m pytest ...
Nested graders reuse only a verified ancestor's OS-held lock, never env alone.
"""
from __future__ import annotations

import argparse
import ctypes
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

ROOT = Path('C:/ProgramData/DannyPytest') if os.name == 'nt' else Path('/tmp/danny-pytest-machine')
LOCK = ROOT / 'exclusive.lock'
STATUS = ROOT / 'holder.json'
GUARD_MODULE = 'danny_pytest_guard'


def eastern_time(now: datetime | None = None) -> str:
    """ET without a tzdata dependency; fallback uses US DST rules since 2007."""
    now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    try:
        eastern = now.astimezone(ZoneInfo('America/New_York'))
    except ZoneInfoNotFoundError:
        if now.year < 2007:
            raise ValueError('stdlib ET fallback supports dates from 2007 onward')
        march = datetime(now.year, 3, 8, 7, tzinfo=timezone.utc)
        november = datetime(now.year, 11, 1, 6, tzinfo=timezone.utc)
        start = march + timedelta(days=(6 - march.weekday()) % 7)
        end = november + timedelta(days=(6 - november.weekday()) % 7)
        offset = -4 if start <= now < end else -5
        eastern = now.astimezone(timezone(timedelta(hours=offset)))
    return eastern.isoformat() + ' ET'


def write_json(path: Path, value: dict) -> None:
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        temporary.write_text(json.dumps(value), encoding='utf-8')
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def sealed_environment(source: dict[str, str]) -> dict[str, str]:
    """Remove only the installer-owned plugin/path from an explicit gate child."""
    env = dict(source)
    plugins = source.get('PYTEST_PLUGINS', '').split(',')
    if GUARD_MODULE in plugins:
        remaining = [p for p in plugins if p != GUARD_MODULE]
        if remaining:
            env['PYTEST_PLUGINS'] = ','.join(remaining)
        else:
            env.pop('PYTEST_PLUGINS', None)
    directory = source.get('DANNY_PYTEST_GUARD_DIR')
    if directory and 'PYTHONPATH' in source:
        normalized = os.path.normcase(os.path.abspath(directory))
        remaining = [p for p in source['PYTHONPATH'].split(os.pathsep)
                     if os.path.normcase(os.path.abspath(p)) != normalized]
        if remaining:
            env['PYTHONPATH'] = os.pathsep.join(remaining)
        else:
            env.pop('PYTHONPATH', None)
    return env


def processes() -> list[dict]:
    if os.name == 'nt':
        result = subprocess.run(['pwsh', '-NoProfile', '-Command',
            'Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,CommandLine,CreationDate | ConvertTo-Json -Compress'],
            capture_output=True, text=True, check=True, timeout=10)
        rows = json.loads(result.stdout) or []
        return [rows] if isinstance(rows, dict) else rows
    result = subprocess.run(['ps', '-eo', 'pid=,ppid=,lstart=,args='],
                            capture_output=True, text=True, check=True, timeout=10)
    return [dict(ProcessId=int(parts[0]), ParentProcessId=int(parts[1]),
                 CreationDate=' '.join(parts[2:7]), CommandLine=parts[7])
            for line in result.stdout.splitlines() for parts in [line.strip().split(None, 7)]
            if len(parts) == 8]


def _windows_kernel():
    from ctypes import wintypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.GetProcessTimes.argtypes = [wintypes.HANDLE, *([ctypes.POINTER(wintypes.FILETIME)] * 4)]
    kernel.GetProcessTimes.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    return kernel


def _posix_process(pid: int) -> tuple[int, int] | None:
    """Parent and start identity without ps, including macOS (no /proc)."""
    if sys.platform == 'darwin':
        class BsdInfo(ctypes.Structure):
            # xnu sys/proc_info.h: struct proc_bsdinfo, PROC_PIDTBSDINFO = 3.
            _fields_ = [(name, ctypes.c_uint32) for name in (
                'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid',
                'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
            _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
            _fields_ += [(name, ctypes.c_uint32) for name in (
                'nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
            _fields_ += [('nice', ctypes.c_int32), ('start_sec', ctypes.c_uint64),
                        ('start_usec', ctypes.c_uint64)]
        library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                        ctypes.c_void_p, ctypes.c_int]
        library.proc_pidinfo.restype = ctypes.c_int
        info = BsdInfo()
        size = ctypes.sizeof(info)
        if library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size) != size or info.pid != pid:
            return None
        return info.ppid, info.start_sec * 1_000_000 + info.start_usec
    # Linux proc(5): field 4 is ppid; field 22 is starttime. A comm may contain
    # spaces or parentheses, so split only after its final closing parenthesis.
    try:
        fields = (Path('/proc') / str(pid) / 'stat').read_text().rsplit(')', 1)[1].split()
        return int(fields[1]), int(fields[19])
    except (OSError, ValueError, IndexError):
        return None


def process_identity(pid: int) -> int | None:
    """Native creation identity shared by explicit helpers and silent guards."""
    if os.name != 'nt':
        info = _posix_process(pid)
        return info[1] if info is not None else None
    from ctypes import wintypes
    kernel = _windows_kernel()
    handle = kernel.OpenProcess(0x1000, False, pid)  # QUERY_LIMITED_INFORMATION
    if not handle:
        return None
    try:
        creation, exited, system, user = (wintypes.FILETIME() for _ in range(4))
        if not kernel.GetProcessTimes(handle, ctypes.byref(creation), ctypes.byref(exited),
                                      ctypes.byref(system), ctypes.byref(user)):
            return None
        return (creation.dwHighDateTime << 32) | creation.dwLowDateTime
    finally:
        kernel.CloseHandle(handle)


def family_processes() -> list[dict]:
    """Only identity/ancestry for guard reuse. Never launch a child process."""
    parents = {}
    if os.name == 'nt':
        from ctypes import wintypes
        class ProcessEntry(ctypes.Structure):
            _fields_ = [('size', wintypes.DWORD), ('usage', wintypes.DWORD),
                        ('pid', wintypes.DWORD), ('heap', ctypes.c_size_t),
                        ('module', wintypes.DWORD), ('threads', wintypes.DWORD),
                        ('ppid', wintypes.DWORD), ('priority', wintypes.LONG),
                        ('flags', wintypes.DWORD), ('exe', wintypes.WCHAR * 260)]
        kernel = _windows_kernel()
        kernel.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
        kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
        for name in ('Process32FirstW', 'Process32NextW'):
            function = getattr(kernel, name)
            function.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry)]
            function.restype = wintypes.BOOL
        snapshot = kernel.CreateToolhelp32Snapshot(2, 0)  # SNAP_PROCESS
        if snapshot == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            entry = ProcessEntry()
            entry.size = ctypes.sizeof(entry)
            if not kernel.Process32FirstW(snapshot, ctypes.byref(entry)):
                raise ctypes.WinError(ctypes.get_last_error())
            while True:
                parents[entry.pid] = entry.ppid
                if not kernel.Process32NextW(snapshot, ctypes.byref(entry)):
                    if ctypes.get_last_error() != 18:  # NO_MORE_FILES
                        raise ctypes.WinError(ctypes.get_last_error())
                    break
        finally:
            kernel.CloseHandle(snapshot)
    rows = []
    pid = os.getpid()
    seen = set()
    child_start = None
    while pid and pid not in seen:
        seen.add(pid)
        if os.name == 'nt':
            ppid, start = parents.get(pid, 0), process_identity(pid)
        else:
            info = _posix_process(pid)
            if info is None:
                break
            ppid, start = info
        # A dead parent's PID may now belong to a younger, unrelated process.
        if start is None or (child_start is not None and start > child_start):
            break
        rows.append(dict(ProcessId=pid, ParentProcessId=ppid))
        child_start, pid = start, ppid
    return rows


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
    command = row.get('CommandLine') or ''
    executable = row.get('Name') or command.split(' ', 1)[0].rsplit('/', 1)[-1]
    if not re.match(r'(?i)^(?:python(?:w|3(?:\.\d+)?)?|pytest)(?:\.exe)?$', executable):
        return False
    # Introspection and launchers that merely mention pytest are not test processes.
    return bool(re.search(r'(?i)(?:^|[\\/\s"\x27])pytest(?:\.exe)?["\x27]?(?:\s|$)|\s-m\s+pytest\b|import pytest;.*pytest\.main', command)) and not bool(
        re.search(r'(?i)Get-CimInstance|pytest-lock\.(?:py|ps1)', command))


def waiting_pytest_pids(rows: list[dict], waiting: set[tuple[int, str]]) -> set[int]:
    """Exclude verified guard waiters and a Python manager forwarding that suite."""
    by_id = {row['ProcessId']: row for row in rows}
    result = {row['ProcessId'] for row in rows
              if (row['ProcessId'], row.get('CreationDate')) in waiting}
    for pid in tuple(result):
        child = by_id[pid]
        # Windows' Python manager can keep a second python.exe visible while
        # its real interpreter waits in configure. Match the exact pytest
        # argument tail, not just any ancestor that happens to run tests.
        pattern = r'\s(?:-m\s+pytest\b|-c\s+.*\bpytest\s*\.\s*main\s*\().*$'
        tail = re.search(pattern, child.get('CommandLine') or '')
        if tail is None or not actual_pytest(child):
            continue
        parent = by_id.get(child['ParentProcessId'])
        while parent and parent['ProcessId'] not in result and actual_pytest(parent):
            parent_tail = re.search(pattern, parent.get('CommandLine') or '')
            if parent_tail is None or parent_tail.group() != tail.group():
                break
            result.add(parent['ProcessId'])
            parent = by_id.get(parent['ParentProcessId'])
    return result


@contextmanager
def pytest_lock(timeout: float = 1800, *, inventory: bool = True):
    if timeout < 0 or not math.isfinite(timeout):
        raise ValueError('lock timeout must be finite and nonnegative')
    ROOT.mkdir(parents=True, exist_ok=True)
    handle = LOCK.open('a+b')
    if LOCK.stat().st_size == 0:
        handle.write(b'0'); handle.flush()
    deadline = time.monotonic() + timeout
    inherited = False
    owned = False
    last_notice = float("-inf")
    old_token = os.environ.get('DANNY_PYTEST_OWNER')
    waiter = ROOT / f'waiting-{os.getpid()}-{uuid.uuid4().hex}.json'
    try:
        # The auto-loaded guard must never call subprocess, even for inventory.
        query = processes if inventory else family_processes
        rows = query() if inventory or old_token else []
        identity = process_identity(os.getpid())
        if identity is None:
            raise RuntimeError('PYTEST_LOCK_IDENTITY: cannot verify current process')
        # A configuring pytest is already visible in the process inventory.
        # Verified waiters must not be mistaken for running legacy test suites.
        write_json(waiter, dict(pid=os.getpid(), process_start=identity))
        while True:
            try:
                acquire(handle)
                owned = True
                break
            except OSError:
                holder = None
                try:
                    holder = json.loads(STATUS.read_text())
                    owner = next((r for r in rows if r['ProcessId'] == holder['pid']), None)
                    if (holder.get('state') == 'held' and holder.get('admitted') is True and old_token and old_token == holder['token'] and holder['pid'] in ancestors(rows)
                            and owner and process_identity(holder['pid']) == holder.get('process_start')):
                        inherited = True
                        break
                except (OSError, ValueError, KeyError):
                    pass
                if time.monotonic() - last_notice >= 30:
                    print('PYTEST_LOCK waiting: ' + json.dumps(holder or {'holder': 'unavailable'}), file=sys.stderr, flush=True)
                    last_notice = time.monotonic()
                if time.monotonic() >= deadline:
                    raise TimeoutError('PYTEST_LOCK_TIMEOUT: holder ' +
                                       json.dumps(holder or {'holder': 'unavailable'}))
                time.sleep(min(1, max(0, deadline - time.monotonic())))
                if old_token:
                    rows = query()
        if not inherited:
            token = uuid.uuid4().hex
            write_json(STATUS, dict(state='held', admitted=False, pid=os.getpid(), command=' '.join(sys.argv)[:800],
                start_et=eastern_time(), process_start=identity, token=token))
            os.environ['DANNY_PYTEST_OWNER'] = token
        # Before ANY pytest, inspect actual test processes. Verified family ancestors
        # are the outer pytest grader, not a competing run. Never terminate a caller.
        while inventory and not inherited:
            rows = processes()
            family = ancestors(rows)
            waiting = set()
            for path in ROOT.glob('waiting-*.json'):
                try:
                    row = json.loads(path.read_text(encoding='utf-8'))
                    # Native identities also verify guard waiters whose path
                    # cannot invoke the explicit helper's CIM/ps inventory.
                    if process_identity(row['pid']) == row['process_start']:
                        process = next((r for r in rows if r['ProcessId'] == row['pid']), None)
                        if process is not None:
                            waiting.add((row['pid'], process.get('CreationDate')))
                except (OSError, ValueError, KeyError):
                    pass
            waiters = waiting_pytest_pids(rows, waiting)
            live = [r for r in rows if r['ProcessId'] not in family
                    and r['ProcessId'] not in waiters and actual_pytest(r)]
            if not live:
                break
            print('PYTEST_LOCK live pytest; recheck in 30 sec: ' + json.dumps(live), file=sys.stderr, flush=True)
            if time.monotonic() >= deadline:
                raise TimeoutError('PYTEST_LOCK_TIMEOUT: live pytest ' + json.dumps(live))
            time.sleep(min(30, max(0, deadline - time.monotonic())))
        if owned:
            holder = json.loads(STATUS.read_text(encoding='utf-8'))
            holder['admitted'] = True
            write_json(STATUS, holder)
        waiter.unlink(missing_ok=True)
        yield
    finally:
        try:
            if owned:
                try:
                    holder = json.loads(STATUS.read_text())
                    if holder['pid'] == os.getpid():
                        holder['state'] = 'released'
                        write_json(STATUS, holder)
                except (OSError, ValueError, KeyError):
                    pass
        finally:
            # Close releases the OS lock even after errors; crash release is automatic.
            handle.close()
            waiter.unlink(missing_ok=True)
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
        return subprocess.call(command, env=sealed_environment(dict(os.environ)))


if __name__ == '__main__':
    raise SystemExit(main())
