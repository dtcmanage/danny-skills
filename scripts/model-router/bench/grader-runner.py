"""Repo-owned grader entry point, run only by the outer bench subprocess."""
from __future__ import annotations

import contextlib
import io
import importlib.util
import json
from pathlib import Path
import runpy
import re
import socket
import subprocess
import sys


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
            with conftest.open('a', encoding='utf-8') as guard:
                guard.write('\nsocket.socket.sendto = deny\n')
        try:
            result = original_run(*args, **kwargs)
        except (OSError, subprocess.SubprocessError) as error:
            raise GraderEnvironment(str(error)) from error
        # pytest assertion/collection failures are candidate failures. Internal
        # pytest errors and missing repo harness packages are infrastructure.
        output = (result.stdout or b'') + (result.stderr or b'')
        if isinstance(output, bytes):
            output = output.decode('utf-8', errors='replace')
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
            runpy.run_path(str(task / 'grader.py'), run_name='__main__')
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
