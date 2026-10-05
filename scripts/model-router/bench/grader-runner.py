"""Repo-owned grader entry point, run only by the outer bench subprocess."""
from __future__ import annotations

import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import runpy
import re
import socket
import subprocess
import sys
import shutil
import tempfile
import xml.etree.ElementTree as ET


class GraderEnvironment(BaseException):
    pass


def main() -> int:
    task, answer = (Path(value).resolve() for value in sys.argv[1:3])
    original_run = subprocess.run

    def run(*args: object, **kwargs: object) -> subprocess.CompletedProcess:
        # Extend the existing task-local socket guard before pytest imports the
        # executable answer. Keep its Windows asyncio socketpair allowance.
        work = Path(str(kwargs.get('cwd', '.')))
        conftest = work / 'conftest.py'
        if 'pytest' in str(args[0]) and conftest.exists():
            if kind == 'pytest' and task.parent.name == 'bench-private-bank':
                shutil.copyfile(work / 'answer.py', work / metadata['solution_file'])
            with conftest.open('a', encoding='utf-8') as guard:
                guard.write('\nsocket.socket.sendto = deny\n')
        private_pytest = kind == 'pytest' and task.parent.name == 'bench-private-bank'
        if private_pytest and 'pytest' in str(args[0]):
            # The candidate's cwd contains no result path. Require evidence from
            # pytest, rather than accepting os._exit(0) during collection.
            with tempfile.TemporaryDirectory(prefix='router-pytest-result-') as directory:
                report = Path(directory) / 'results.xml'
                # pytest gets the result path through its API; the imported
                # answer's sys.argv and environment do not reveal it.
                pytest_args = [*args[0][3:], '--junitxml=' + str(report)]
                command = [args[0][0], '-c', 'import pytest; raise SystemExit(pytest.main('
                           + repr(pytest_args) + '))']
                kwargs['timeout'] = max(60, float(os.environ.get('BENCH_OUTER_TIMEOUT', '30')) * 2 + 30)
                result = original_run(command, **kwargs)
                try:
                    root = ET.parse(report).getroot()
                    cases = list(root.iter('testcase'))
                    passed = (result.returncode == 0 and bool(cases)
                              and not any(list(case.iter(tag)) for case in cases
                                          for tag in ('failure', 'error')))
                except (OSError, ET.ParseError):
                    passed = False
                return subprocess.CompletedProcess(result.args, 0 if passed else 1, result.stdout, result.stderr)
        try:
            result = original_run(*args, **kwargs)
        except (OSError, subprocess.SubprocessError) as error:
            raise GraderEnvironment(str(error)) from error
        # pytest assertion/collection failures are candidate failures. Internal
        # pytest errors and missing repo harness packages are infrastructure.
        output = ''.join(value.decode('utf-8', errors='replace') if isinstance(value, bytes) else value
                         for value in (result.stdout or '', result.stderr or ''))
        command = str(args[0])
        if ('pytest' in command and result.returncode >= 3) or (
            'node' in command and re.search(r"Cannot find module '(?:jsdom|esbuild|postcss|tailwindcss|react|react-dom/client)'", output)
            and str(task / 'harness' / 'render.cjs') in output
        ):
            raise GraderEnvironment(output)
        return result

    def deny(*args: object, **kwargs: object) -> None:
        raise RuntimeError('network disabled')

    subprocess.run = run
    socket.socket.connect = deny
    socket.socket.connect_ex = deny
    socket.create_connection = deny
    socket.socket.sendto = deny
    sys.argv = [str(task / 'grader.py'), str(answer)]
    buffer = io.StringIO()
    status, detail, kind = 'fail', '', None
    try:
        metadata_path = task / 'task.json'
        if metadata_path.exists():
            kind = json.loads(metadata_path.read_text(encoding='utf-8'))['grader']
        if kind == 'pytest':
            dependencies = ('pytest', 'fastapi', 'pydantic') if task.name == 'routine-coding-endpoint' else ('pytest',)
            for dependency in dependencies:
                if importlib.util.find_spec(dependency) is None:
                    raise GraderEnvironment('Missing repo harness dependency: ' + dependency)
        with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(buffer):
            if (task / 'grader.py').exists():
                runpy.run_path(str(task / 'grader.py'), run_name='__main__')
            elif kind in {'pytest', 'nodetest'} and task.parent.name == 'bench-private-bank':
                metadata = json.loads(metadata_path.read_text(encoding='utf-8'))
                filename = metadata['solution_file']
                if Path(filename).name != filename:
                    raise GraderEnvironment('Invalid solution filename')
                with tempfile.TemporaryDirectory(prefix='router-bench-code-') as directory:
                    work = Path(directory)
                    if kind == 'pytest':
                        # Reuse the existing pytest primitive and its socket guard.
                        primitives = runpy.run_path(str(Path(__file__).resolve().parent / 'tasks/_grading.py'))
                        (work / 'fixtures').mkdir()
                        (work / 'fixtures/input.json').write_text('{}', encoding='utf-8')
                        shutil.copyfile(task / 'hidden_tests.py', work / 'hidden_tests.py')
                        raise SystemExit(0 if primitives['grade_python'](work, answer) else 1)
                    runner = Path(__file__).resolve().parent / 'node_test_runner.mjs'
                    if not runner.is_file() or not (task / 'hidden_tests.mjs').is_file():
                        raise GraderEnvironment('Missing Node harness file')
                    shutil.copyfile(answer, work / filename)
                    shutil.copyfile(task / 'hidden_tests.mjs', work / 'hidden_tests.mjs')
                    nonce = os.environ['BENCH_NODE_NONCE']
                    command = ['node', '--permission', '--allow-fs-read=' + str(work),
                               '--allow-fs-read=' + str(runner), str(runner),
                               str(work / 'hidden_tests.mjs'), str(work / filename)]
                    try:
                        process = subprocess.Popen(command, cwd=work, stdout=subprocess.PIPE,
                                                   stderr=subprocess.STDOUT, text=True)
                    except OSError as error:
                        raise GraderEnvironment(str(error)) from error
                    lines = []
                    loaded = nonce + ' loaded'
                    for line in process.stdout:
                        lines.append(line.rstrip('\r\n'))
                        if lines[-1] == loaded:
                            # Let the outer timeout boundary see that candidate
                            # loading began, even if this process is killed.
                            sys.__stdout__.write(loaded + '\n')
                            sys.__stdout__.flush()
                    code = process.wait()
                    if loaded not in lines:
                        raise GraderEnvironment('Node runner failed before loading: ' + '\n'.join(lines))
                    prefix = nonce + ' verdict '
                    if code or not lines or not lines[-1].startswith(prefix):
                        print('Node candidate exited without a valid final verdict')
                        raise SystemExit(1)
                    try:
                        verdict = json.loads(lines[-1][len(prefix):])
                        valid = (type(verdict['passed']) is int and type(verdict['failed']) is int
                                 and verdict['passed'] > 0 and verdict['failed'] == 0
                                 and verdict.get('skipped') == 0)
                    except (ValueError, KeyError, TypeError):
                        raise SystemExit(1)
                    print(json.dumps(verdict))
                    raise SystemExit(0 if valid else 1)
            elif kind in {'exact', 'numeric'} and task.parent.name == 'bench-private-bank' and not task.is_relative_to(Path(__file__).resolve().parent / 'tasks'):
                # Intake tasks reuse the existing JSON graders without a copied
                # harness. Plain text exact answers use whitespace-trimmed equality.
                if kind == 'exact' and (task / 'golden/answer.txt').exists():
                    raise SystemExit(0 if answer.read_text(encoding='utf-8').strip() ==
                                     (task / 'golden/answer.txt').read_text(encoding='utf-8').strip() else 1)
                primitives = runpy.run_path(str(Path(__file__).resolve().parent / 'tasks/_grading.py'))
                raise SystemExit(primitives['main'](task, answer))
            else:
                raise GraderEnvironment('Missing task grader')
        status = 'pass'
    except SystemExit as error:
        status = 'pass' if error.code in (None, 0) else 'fail'
    except GraderEnvironment as error:
        status, detail = 'unknown', str(error)
    except BaseException as error:
        status, detail = 'unknown', repr(error)
    # Grounding graders mark failures caused by invented content; others never do.
    fabrication = (kind == 'grounding' and status == 'fail'
                   and re.search(r'(?m)^FABRICATION: true$', buffer.getvalue()) is not None)
    print(json.dumps({'status': status, 'failure_category':
                      'environment' if status == 'unknown' else
                      ('implementation' if status == 'fail' else None),
                      'fabrication': fabrication,
                      'detail': detail, 'grader_output': buffer.getvalue()}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
