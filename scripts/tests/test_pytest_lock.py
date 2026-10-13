"""Fixtures only: run directly with Python (these tests exercise the lock itself)."""
from __future__ import annotations
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

HELPER = Path(__file__).resolve().parents[1] / 'pytest-lock.py'
spec = importlib.util.spec_from_file_location('pytest_lock', HELPER)
lock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lock)


class LockTests(unittest.TestCase):
    def test_reason_required(self):
        for args in ([], ['--reason'], ['--reason', ''], ['--reason', '   ']):
            result = subprocess.run([sys.executable, str(HELPER), *args, '--',
                                     sys.executable, '-c', "raise AssertionError('must not run')"],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertIn('EXCLUSIVE_REASON_REQUIRED', result.stderr)
        with self.assertRaisesRegex(ValueError, 'EXCLUSIVE_REASON_REQUIRED'):
            with lock.pytest_lock():
                self.fail('must not acquire')

    def test_wait_reports_reason_and_holder(self):
        self.holder()
        with self.assertRaises(TimeoutError), mock.patch.object(lock.sys, 'stderr') as error:
            with lock.pytest_lock(timeout=0, reason='caller suite: fixture contention; workaround tested'):
                self.fail('must wait')
        diagnostic = ''.join(str(call.args[0]) for call in error.write.call_args_list)
        self.assertIn('caller suite', diagnostic)
        self.assertIn('holder=', diagnostic)
        self.assertIn('exclusive_reason', diagnostic)
        self.assertIn('lock fixtures', diagnostic)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.marker = Path(self.temp.name) / 'held'
        self.release = Path(self.temp.name) / 'release'
        self.children = []
        self.holder_identity = None
        self.stderr_files = []

    def tearDown(self):
        self.release.touch()
        for child in self.children:
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()  # Only our own fixture process.
        if self.holder_identity is not None:
            deadline = time.monotonic() + 10
            while any((row['ProcessId'], row.get('CreationDate')) == self.holder_identity
                      for row in lock.processes()):
                if time.monotonic() >= deadline:
                    self.fail('own holder descendant did not exit after release')
                time.sleep(.1)
        for handle in self.stderr_files:
            handle.close()
        self.temp.cleanup()

    def holder(self):
        code = ('from pathlib import Path\nimport time,os\n'
                f'Path({str(self.marker)!r}).write_text(str(os.getpid()))\n'
                f'while not Path({str(self.release)!r}).exists():\n    time.sleep(.05)\n')
        error_path = Path(self.temp.name) / 'holder.stderr.log'
        error = error_path.open('w')
        self.stderr_files.append(error)
        child = subprocess.Popen([sys.executable, str(HELPER), '--reason', 'lock fixtures: deliberate contention; separate temp paths cannot test shared ownership', '--', sys.executable, '-c', code],
                                 stdout=subprocess.DEVNULL, stderr=error)
        self.children.append(child)
        deadline = time.monotonic() + 20
        while not self.marker.exists() and child.poll() is None and time.monotonic() < deadline:
            time.sleep(.05)
        diagnostics = error_path.read_text()
        self.assertTrue(self.marker.exists(), diagnostics)
        time.sleep(.1)
        self.assertIsNone(child.poll(), 'fixture holder exited after its marker: ' + diagnostics)
        pid = int(self.marker.read_text())
        owner = next(row for row in lock.processes() if row['ProcessId'] == pid)
        self.holder_identity = (pid, owner.get('CreationDate'))
        return child

    def caller(self, timeout=15, code='pass', env=None, ready=None, stderr=subprocess.DEVNULL):
        args = ['--ready-file', str(ready)] if ready is not None else []
        return subprocess.Popen([sys.executable, str(HELPER), '--reason', 'lock fixtures: deliberate contention; separate temp paths cannot test shared ownership', '--timeout', str(timeout), *args, '--',
                                 sys.executable, '-c', code], stdout=subprocess.DEVNULL,
                                stderr=stderr, env=env)

    def test_second_caller_waits(self):
        self.holder()
        ready = Path(self.temp.name) / 'ready'
        child = self.caller(ready=ready); self.children.append(child)
        time.sleep(2)
        self.assertIsNone(child.poll())
        self.assertFalse(ready.exists())
        self.release.touch()
        self.assertEqual(child.wait(timeout=20), 0)
        self.assertEqual(ready.read_text(), 'acquired')

    def test_abandoned_recovery(self):
        holder = self.holder(); holder.kill(); holder.wait()
        child = self.caller(); self.children.append(child)
        self.assertEqual(child.wait(timeout=20), 0)

    def test_failure_releases(self):
        child = self.caller(code='raise SystemExit(7)'); self.children.append(child)
        self.assertEqual(child.wait(timeout=20), 7)
        child = self.caller(); self.children.append(child)
        self.assertEqual(child.wait(timeout=20), 0)

    def test_timeout_and_spoofed_env(self):
        self.holder()
        holder = json.loads(lock.STATUS.read_text())
        env = dict(os.environ, DANNY_PYTEST_OWNER=holder['token'])
        child = self.caller(timeout=1, env=env); self.children.append(child)
        self.assertNotEqual(child.wait(timeout=15), 0)

    def test_verified_nested_owner(self):
        self.assertTrue(lock.actual_pytest(dict(Name='pytest.exe', CommandLine='"C:/tools/pytest.exe"')))
        self.assertFalse(lock.actual_pytest(dict(Name='pwsh.exe', CommandLine='Get-CimInstance Win32_Process pytest')))
        self.assertFalse(lock.actual_pytest(dict(Name='python.exe', CommandLine='python scripts/pytest-lock.py -- python -m pytest')))
        for entry in ([sys.executable, str(HELPER), '--reason', 'lock fixtures: deliberate contention; separate temp paths cannot test shared ownership', '--timeout', '1', '--'],
                      ['pwsh', '-NoProfile', '-File', str(HELPER.with_suffix('.ps1')), '-Reason', 'nested argv fixture: inherited ownership must avoid deadlock; isolated locks cannot test reuse', '-TimeoutSec', '1'],
                      ['pwsh', '-NoProfile', '-CommandWithArgs',
                       '& $args[0] @($args | Select-Object -Skip 1); exit $LASTEXITCODE',
                       str(HELPER.with_suffix('.ps1')), '-Reason', 'nested argv fixture: inherited ownership must avoid deadlock; isolated locks cannot test reuse', '-TimeoutSec', '1']):
            argv = Path(self.temp.name) / 'argv.json'
            command = entry + [sys.executable, '-c',
                              f'import sys,json; from pathlib import Path; Path({str(argv)!r}).write_text(json.dumps(sys.argv[1:]))',
                              '-v', '-q']
            code = f'import subprocess; raise SystemExit(subprocess.call({command!r}))'
            with self.subTest(entry=entry):
                child = self.caller(code=code, stderr=subprocess.PIPE); self.children.append(child)
                _, diagnostics = child.communicate(timeout=20)
                self.assertEqual(child.returncode, 0, diagnostics.decode(errors='replace'))
                self.assertEqual(json.loads(argv.read_text()), ['-v', '-q'])

    def test_process_inventory_is_bounded(self):
        with mock.patch.object(lock.subprocess, 'run', side_effect=subprocess.TimeoutExpired('inventory', 10)) as run:
            with self.assertRaises(subprocess.TimeoutExpired):
                lock.processes()
            self.assertEqual(run.call_args.kwargs['timeout'], 10)

    def test_waiter_identity_and_python_manager(self):
        rows = [dict(ProcessId=1, ParentProcessId=0, CreationDate='parent', Name='python.exe', CommandLine='python -m pytest same.py'),
                dict(ProcessId=2, ParentProcessId=1, CreationDate='child', Name='python.exe', CommandLine='runtime -m pytest same.py'),
                dict(ProcessId=3, ParentProcessId=0, CreationDate='other', Name='python.exe', CommandLine='python -m pytest other.py')]
        self.assertEqual(lock.waiting_pytest_pids(rows, {(2, 'child')}), {1, 2})
        self.assertEqual(lock.waiting_pytest_pids(rows, {(2, 'stale')}), set())
        rows[0]['CommandLine'] = 'python -m pytest parent.py'
        self.assertEqual(lock.waiting_pytest_pids(rows, {(2, 'child')}), {2})

    def test_stdlib_eastern_fallback(self):
        from datetime import datetime, timezone
        with mock.patch.object(lock, 'ZoneInfo', side_effect=lock.ZoneInfoNotFoundError('no tzdata')):
            for date, expected in [('2026-01-01T12:00:00', '07:00:00-05:00'),
                                   ('2026-07-01T12:00:00', '08:00:00-04:00'),
                                   ('2026-03-08T06:59:59', '01:59:59-05:00'),
                                   ('2026-03-08T07:00:00', '03:00:00-04:00'),
                                   ('2026-11-01T05:59:59', '01:59:59-04:00'),
                                   ('2026-11-01T06:00:00', '01:00:00-05:00')]:
                self.assertTrue(lock.eastern_time(datetime.fromisoformat(date).replace(tzinfo=timezone.utc)).endswith(expected + ' ET'))



if __name__ == '__main__':
    unittest.main()
