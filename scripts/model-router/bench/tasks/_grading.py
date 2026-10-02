"""Task-local grading primitives; no candidate installers or downloads are run.

CLI answers arrive after Get-CanaryAnswerBody in the runner. Executable answers
use the canary's temporary-directory, socket-blocking and 30 second boundary.
This is an accident guard, not filesystem containment under the local account.
"""
from __future__ import annotations

import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Any


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def rubric_score(rubric: dict[str, Any], result: dict[str, Any]) -> float:
    """Require exactly one binary integer score for every declared rubric line."""
    scores = result["scores"]
    ids = {line["id"] for line in rubric["lines"]}
    if not isinstance(scores, dict) or set(scores) != ids:
        raise ValueError("Missing or unexpected rubric scores")
    if any(type(v) is not int or v not in (0, 1) for v in scores.values()):
        raise ValueError("Rubric scores must be integer 0 or 1")
    return sum(scores.values()) / len(ids)


def grade_python(task: Path, answer: Path) -> bool:
    with tempfile.TemporaryDirectory(prefix="router-bench-") as name:
        work = Path(name)
        shutil.copyfile(answer, work / "answer.py")
        shutil.copyfile(task / "hidden_tests.py", work / "test_hidden.py")
        shutil.copyfile(task / "fixtures/input.json", work / "input.json")
        (work / "conftest.py").write_text(
            'import socket, threading\n'
            '_pair_context = threading.local()\n'
            '_connect, _socketpair = socket.socket.connect, socket.socketpair\n'
            'def blocked(sock, address):\n'
            '    if getattr(_pair_context, "active", False):\n'
            '        return _connect(sock, address)\n'
            '    raise RuntimeError("network disabled")\n'
            'def local_pair(*args, **kwargs):\n'
            '    # Windows implements the asyncio self-pipe with a loopback pair.\n'
            '    _pair_context.active = True\n'
            '    try: return _socketpair(*args, **kwargs)\n'
            '    finally: _pair_context.active = False\n'
            'socket.socketpair = local_pair\n'
            'socket.socket.connect = blocked\n'
            'def deny(*args, **kwargs): raise RuntimeError("network disabled")\n'
            'socket.socket.connect_ex = deny\n'
            'socket.create_connection = deny\n', encoding="utf-8")
        env = {k: v for k, v in os.environ.items() if k.upper() not in
               {"OPENAI_API_KEY", "ANTHROPIC_API_KEY", "CLAUDE_CONFIG_DIR"}}
        env["PYTEST_DISABLE_PLUGIN_AUTOLOAD"] = "1"
        proc = subprocess.run([sys.executable, "-m", "pytest", "-q", "test_hidden.py"],
                              cwd=work, env=env, capture_output=True, timeout=30)
        return proc.returncode == 0


def grade_ui(task: Path, answer: Path) -> bool:
    env = {k: v for k, v in os.environ.items() if k.upper() not in
           {"OPENAI_API_KEY", "ANTHROPIC_API_KEY", "CLAUDE_CONFIG_DIR"}}
    with tempfile.TemporaryDirectory(prefix="router-bench-ui-") as name:
        work = Path(name)
        shutil.copyfile(answer, work / "answer.jsx")
        proc = subprocess.run(["node", str(task / "harness/render.cjs"),
                               str(work / "answer.jsx"), str(task / "fixtures/input.json")],
                              cwd=work, env=env, capture_output=True, timeout=30)
        return proc.returncode == 0


def grade(task: Path, answer: Path) -> bool:
    kind = read_json(task / "task.json")["grader"]
    if kind == "pytest":
        return grade_python(task, answer)
    if kind == "render":
        return grade_ui(task, answer)
    result = read_json(answer)
    if kind == "rubric":
        rubric = read_json(task / "golden/rubric.json")
        return rubric_score(rubric, result) >= rubric["threshold"]
    expected = read_json(task / "golden/answer.json")
    if kind == "numeric":
        if not isinstance(result, dict) or set(result) != set(expected):
            return False
        for key, wanted in expected.items():
            values = result[key] if isinstance(wanted, list) else [result[key]]
            target = wanted if isinstance(wanted, list) else [wanted]
            if not isinstance(values, list) or len(values) != len(target):
                return False
            if any(type(a) not in (float, int) or not math.isfinite(a)
                   or not math.isclose(a, b, abs_tol=1e-8, rel_tol=1e-8)
                   for a, b in zip(values, target)):
                return False
        return True
    # JSON comparison includes exact touched-file set and unchanged files.
    return result == expected


def main(task: Path, answer: Path) -> int:
    try:
        passed = grade(task, answer)
    except (ValueError, TypeError, KeyError, OSError, subprocess.SubprocessError):
        passed = False
    print("PASS" if passed else "FAIL")
    return 0 if passed else 1
