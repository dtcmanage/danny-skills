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
import threading

HELPER = Path(__file__).resolve().parents[1] / 'pytest-lock.py'
spec = importlib.util.spec_from_file_location('pytest_lock', HELPER)
lock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lock)


class LockTests(unittest.TestCase):
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
        child = subprocess.Popen([sys.executable, str(HELPER), '--', sys.executable, '-c', code],
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

    def caller(self, timeout=15, code='pass', env=None, ready=None):
        args = ['--ready-file', str(ready)] if ready is not None else []
        return subprocess.Popen([sys.executable, str(HELPER), '--timeout', str(timeout), *args, '--',
                                 sys.executable, '-c', code], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, env=env)

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
        for entry in ([sys.executable, str(HELPER), '--timeout', '1', '--'],
                      ['pwsh', '-NoProfile', '-File', str(HELPER.with_suffix('.ps1')), '-TimeoutSec', '1'],
                      ['pwsh', '-NoProfile', '-CommandWithArgs',
                       '& $args[0] @($args | Select-Object -Skip 1); exit $LASTEXITCODE',
                       str(HELPER.with_suffix('.ps1')), '-TimeoutSec', '1']):
            argv = Path(self.temp.name) / 'argv.json'
            command = entry + [sys.executable, '-c',
                              f'import sys,json; from pathlib import Path; Path({str(argv)!r}).write_text(json.dumps(sys.argv[1:]))',
                              '-v', '-q']
            code = f'import subprocess; raise SystemExit(subprocess.call({command!r}))'
            child = self.caller(code=code); self.children.append(child)
            self.assertEqual(child.wait(timeout=20), 0)
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

    def grade_behind_holder(self, task, answer, timeout=8):
        self.holder()
        bench = HELPER.parent / 'model-router/bench'
        ready = Path(self.temp.name) / 'grading-ready'
        code = (f'import sys,json; from pathlib import Path; sys.path.insert(0,{str(bench)!r}); '
                f'import bench_engine; Path({str(ready)!r}).touch(); '
                f'print(json.dumps(bench_engine.grade_answer(Path({str(task)!r}),{answer!r},timeout={timeout})))')
        child = subprocess.Popen([sys.executable, '-c', code], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
        self.children.append(child)
        deadline = time.monotonic() + 15
        while not ready.exists() and child.poll() is None and time.monotonic() < deadline:
            time.sleep(.05)
        self.assertTrue(ready.exists(), 'grading child must reach engine before the delayed release')
        # Waiting exceeds the candidate's entire execution budget.
        started = time.monotonic()
        release = threading.Timer(timeout + 4, self.release.touch)
        release.start()
        try:
            # Admission has its own bounded 1800s wait; it is not candidate
            # execution. An unrelated legacy suite may start after preflight.
            stdout, stderr = child.communicate(timeout=1800 + timeout + 15)
        except subprocess.TimeoutExpired as error:
            print('CONTENTION_TIMEOUT_DIAGNOSTICS:', repr(error.stdout), repr(error.stderr), flush=True)
            raise
        finally:
            release.cancel()
            self.release.touch()
        self.assertEqual(child.returncode, 0, stderr)
        outcome = json.loads(stdout.splitlines()[-1])
        print('CONTENTION_OUTCOME:', json.dumps(dict(outcome=outcome, diagnostics=stderr,
              elapsed_seconds=round(time.monotonic() - started, 2))), flush=True)
        self.assertIn('PYTEST_LOCK waiting:', stderr)
        self.assertGreaterEqual(time.monotonic() - started, timeout + 4)
        return outcome

    def test_grader_budget_starts_after_lock_release(self):
        # Isolate admission timing from variable FastAPI/golden suite startup.
        task = Path(self.temp.name) / 'bench-private-bank/quick-candidate'
        task.mkdir(parents=True)
        (task / 'task.json').write_text(json.dumps(dict(grader='pytest', solution_file='solution.py')))
        (task / 'hidden_tests.py').write_text('import solution\ndef test_fixture(): assert solution.value == 42\n')
        outcome = self.grade_behind_holder(task, 'value = 42\n')
        self.assertEqual(outcome['status'], 'pass', outcome)

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

    def test_private_candidate_timeout_after_lock_release(self):
        task = Path(self.temp.name) / 'bench-private-bank/delayed-candidate'
        task.mkdir(parents=True)
        (task / 'task.json').write_text(json.dumps(dict(grader='pytest', solution_file='solution.py')))
        (task / 'hidden_tests.py').write_text('import solution\ndef test_fixture(): assert True\n')
        outcome = self.grade_behind_holder(task, 'import time\ntime.sleep(60)\n')
        self.assertEqual(outcome['status'], 'fail', outcome)
        self.assertEqual(outcome['detail'], 'Candidate timed out', outcome)


if __name__ == '__main__':
    # Do not begin contention fixtures while somebody else's actual pytest runs.
    with lock.pytest_lock():
        pass
    unittest.main()
