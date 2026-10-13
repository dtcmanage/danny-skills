"""Stdlib fixture driver. Child pytest gets guard env only for these fixtures."""
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

SCRIPTS = Path(__file__).resolve().parents[1]
HELPER = SCRIPTS / 'pytest-lock.py'
GUARD = SCRIPTS / 'pytest-guard'
spec = importlib.util.spec_from_file_location('fixture_lock', HELPER)
lock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lock)


class GuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix='pytest-guard-fixture-')
        self.work = Path(self.temp.name)
        self.children = []
        self.files = []
        self.release = self.work / 'release'
        self.base = lock.sealed_environment(dict(os.environ))
        self.base.pop('DANNY_PYTEST_OWNER', None)
        self.base['PYTEST_DISABLE_PLUGIN_AUTOLOAD'] = '1'
        self.base['PYTHONDONTWRITEBYTECODE'] = '1'
        self.guarded = dict(self.base, DANNY_PYTEST_GUARD='1', DANNY_PYTEST_GUARD_DIR=str(GUARD))
        self.guarded['PYTEST_PLUGINS'] = ','.join(filter(None, [self.base.get('PYTEST_PLUGINS'), lock.GUARD_MODULE]))
        self.guarded['PYTHONPATH'] = os.pathsep.join(filter(None, [self.base.get('PYTHONPATH'), str(GUARD)]))
        (self.work / 'test_fixture.py').write_text('def test_fixture(): assert True\n', encoding='utf-8')
        (self.work / 'conftest.py').write_text(
            'import json,os,sys\nfrom pathlib import Path\n'
            'def pytest_collection_finish(session):\n'
            '    if os.environ.get("FIXTURE_SNAPSHOT"):\n'
            '        Path(os.environ["FIXTURE_SNAPSHOT"]).write_text(json.dumps({\n'
            '            "path":sys.path,"plugins":sorted(n for n,p in session.config.pluginmanager.list_name_plugin() if p is not None and not n.isdecimal()),\n'
            '            "items":[i.nodeid for i in session.items]}))\n', encoding='utf-8')

    def tearDown(self) -> None:
        self.release.touch()
        for child in self.children:
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                child.kill()  # Only this fixture's own child.
                child.wait(timeout=10)
        for file in self.files:
            file.close()
        self.temp.cleanup()

    def run_pytest(self, env: dict[str, str], *, explicit: bool = False, command: list[str] | None = None) -> subprocess.CompletedProcess[str]:
        args = command or [sys.executable, '-m', 'pytest', '-q', '--color=no', '-p', 'no:cacheprovider', 'test_fixture.py']
        if explicit:
            args = [sys.executable, str(HELPER), '--', *args]
        return subprocess.run(args, cwd=self.work, env=env, capture_output=True, text=True, timeout=90)

    def test_sealed_gate_is_byte_identical(self) -> None:
        baseline = self.work / 'baseline.json'
        sealed = self.work / 'sealed.json'
        # A fixture-owned output plugin removes only nondeterministic timing,
        # so the retained child stdout/stderr themselves can be compared.
        (self.work / 'conftest.py').write_text((self.work / 'conftest.py').read_text() +
            'def pytest_sessionstart(session):\n'
            '    reporter=session.config.pluginmanager.getplugin("terminalreporter")\n'
            '    reporter.summary_stats=lambda: None\n', encoding='utf-8')
        plain = self.run_pytest(dict(self.base, FIXTURE_SNAPSHOT=str(baseline)))
        wrapped = self.run_pytest(dict(self.guarded, FIXTURE_SNAPSHOT=str(sealed)), explicit=True)
        self.assertEqual(plain.returncode, 0, plain.stderr)
        self.assertEqual(wrapped.returncode, 0, wrapped.stderr)
        self.assertEqual(plain.stdout, wrapped.stdout)
        self.assertEqual(plain.stderr, wrapped.stderr)
        self.assertEqual(baseline.read_bytes(), sealed.read_bytes())

    def test_guard_owns_lock_without_output(self) -> None:
        (self.work / 'test_fixture.py').write_text(
            'import importlib.util\nfrom pathlib import Path\n'
            f's=importlib.util.spec_from_file_location("probe",{str(HELPER)!r})\n'
            'm=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n'
            'def test_fixture():\n'
            '    with m.LOCK.open("a+b") as handle:\n'
            '        try: m.acquire(handle)\n'
            '        except OSError: return\n'
            '        raise AssertionError("guard did not acquire OS lock")\n', encoding='utf-8')
        result = self.run_pytest(self.guarded)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, '')
        self.assertNotIn('PYTEST_LOCK', result.stdout)

    def test_zero_is_complete_noop(self) -> None:
        before = lock.STATUS.read_bytes() if lock.STATUS.exists() else None
        (self.work / 'test_fixture.py').write_text(
            'import os\ndef test_fixture(): assert "DANNY_PYTEST_OWNER" not in os.environ\n')
        result = self.run_pytest(dict(self.guarded, DANNY_PYTEST_GUARD='0'))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, '')
        after = lock.STATUS.read_bytes() if lock.STATUS.exists() else None
        self.assertEqual(before, after)

    def test_verified_ancestor_reused(self) -> None:
        code = (f'import importlib.util,subprocess,os; s=importlib.util.spec_from_file_location("parent",{str(HELPER)!r}); '
                'm=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n'
                'with m.pytest_lock():\n'
                '    raise SystemExit(subprocess.call([__import__("sys").executable,"-m","pytest","-q","test_fixture.py"]))\n')
        result = self.run_pytest(self.guarded, command=[sys.executable, '-c', code])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, '')

    def test_nonpytest_python_only_sees_path_and_env(self) -> None:
        code = 'import sys,json,os; print(json.dumps({"loaded":"danny_pytest_guard" in sys.modules,"path":sys.path,"plugins":os.environ["PYTEST_PLUGINS"]}))'
        result = subprocess.run([sys.executable, '-c', code], env=self.guarded, capture_output=True, text=True, timeout=10)
        data = json.loads(result.stdout)
        self.assertFalse(data['loaded'])
        self.assertIn(str(GUARD), data['path'])
        self.assertIn(lock.GUARD_MODULE, data['plugins'])
        self.assertEqual(result.stderr, '')

    def test_failure_and_collection_error_release(self) -> None:
        for source, expected in [('def test_fixture(): assert False\n', 1), ('raise ValueError("collection fixture")\n', 2)]:
            (self.work / 'test_fixture.py').write_text(source)
            result = self.run_pytest(self.guarded)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            self.assertEqual(json.loads(lock.STATUS.read_text())['state'], 'released')
            (self.work / 'test_fixture.py').write_text('def test_fixture(): assert True\n')
            result = self.run_pytest(self.base, explicit=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_two_guarded_processes_serialize(self) -> None:
        # Both are visible as actual pytest before configure. Neither may treat
        # the other's verified waiting guard as an unguarded running suite.
        (self.work / 'test_fixture.py').write_text(
            'import os,time\nfrom pathlib import Path\n'
            'def test_fixture():\n'
            '    Path(os.environ["FIXTURE_MARKER"]).touch()\n'
            '    if os.environ.get("FIXTURE_HOLD"):\n'
            '        deadline=time.monotonic()+60\n'
            f'        while not Path({str(self.release)!r}).exists() and time.monotonic()<deadline: time.sleep(.05)\n')
        first_marker, second_marker = self.work / 'first', self.work / 'second'
        first = self.spawn(dict(self.guarded, FIXTURE_MARKER=str(first_marker), FIXTURE_HOLD='1'), 'first')
        self.wait_marker(first_marker, first)
        second = self.spawn(dict(self.guarded, FIXTURE_MARKER=str(second_marker)), 'second')
        time.sleep(3)
        self.assertIsNone(second.poll())
        self.assertFalse(second_marker.exists())
        self.release.touch()
        self.assertEqual(first.wait(timeout=30), 0)
        self.assertEqual(second.wait(timeout=45), 0)
        self.assertTrue(second_marker.exists())
        self.assertIn('PYTEST_LOCK waiting:', (self.work / 'second.stderr').read_text())
        self.assertNotIn('PYTEST_LOCK', (self.work / 'second.stdout').read_text())

    def spawn(self, env: dict[str, str], name: str) -> subprocess.Popen:
        out, err = (self.work / (name + '.stdout')).open('w'), (self.work / (name + '.stderr')).open('w')
        self.files.extend([out, err])
        child = subprocess.Popen([sys.executable, '-m', 'pytest', '-q', 'test_fixture.py'], cwd=self.work, env=env, stdout=out, stderr=err)
        self.children.append(child)
        return child

    def wait_marker(self, marker: Path, child: subprocess.Popen) -> None:
        deadline = time.monotonic() + 45
        while not marker.exists() and child.poll() is None and time.monotonic() < deadline:
            time.sleep(.1)
        self.assertTrue(marker.exists(), 'guarded holder never reached its test')
        self.assertIsNone(child.poll(), 'guarded holder exited after marker')


if __name__ == '__main__':
    # The fixture driver itself launches no concurrent suites except the one
    # focused contention case. Never run it concurrently with other own suites.
    with lock.pytest_lock():
        pass
    unittest.main()
