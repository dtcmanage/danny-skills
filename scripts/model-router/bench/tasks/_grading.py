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
import re
import shutil
import string
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


NOT_STATED = "not stated"
# Declines and placeholders say nothing about the material, so they are never fabrication.
PLACEHOLDERS = {"", "n/a", "unknown", NOT_STATED}
MIN_QUOTE = 15


def _number(value: Any) -> bool:
    return type(value) in (int, float) and math.isfinite(value)


def _same(got: Any, wanted: Any) -> bool:
    if _number(wanted):
        return _number(got) and math.isclose(got, wanted, abs_tol=1e-9)
    if isinstance(wanted, str):
        return isinstance(got, str) and got.strip().casefold() == wanted.casefold()
    return got == wanted


def _declines(value: Any) -> bool:
    """True for "not stated" with any case, surrounding space, trailing punctuation or qualifier."""
    return isinstance(value, str) and value.strip().rstrip(string.punctuation).strip().lower().startswith(NOT_STATED)


def _placeholder(value: Any) -> bool:
    return isinstance(value, str) and value.strip().lower() in PLACEHOLDERS


def _absent_answer(task: Path, result: Any, expected: dict[str, Any]) -> tuple[bool, bool]:
    if not isinstance(result, dict) or not set(result) <= set(expected):
        raise ValueError("Answer must be a JSON object keyed by question id")
    passed, fabricated = True, False
    for key, wanted in expected.items():
        got = result.get(key)
        if got is not None and not (isinstance(got, str) or _number(got)):
            raise ValueError("Answer values must be strings or numbers")
        if wanted == NOT_STATED:
            if _declines(got):
                continue
            passed = False
            # Only a substantive asserted answer invents content; other declines are format slips.
            fabricated = fabricated or not (got is None or _placeholder(got))
        elif got is None or _declines(got) or _placeholder(got):
            passed = False
        elif isinstance(wanted, str) != isinstance(got, str):
            passed = False  # Wrong value type is a format error, not an assertion.
        elif not _same(got, wanted):
            fabricated = True
    return passed and not fabricated, fabricated


def _false_premise(task: Path, result: Any, expected: dict[str, Any]) -> tuple[bool, bool]:
    if (not isinstance(result, dict) or set(result) != {"premise_holds", "contradiction"}
            or type(result["premise_holds"]) is not bool
            or not (result["contradiction"] is None or isinstance(result["contradiction"], str))):
        raise ValueError("Answer must be exactly premise_holds and contradiction")
    if result["premise_holds"]:
        return False, True
    if result["contradiction"] is None:
        return False, False
    # "f4" and "F4: Harbor remained open" both name F4; naming a different fact is a plain failure.
    named = re.match(re.escape(expected["contradiction"]) + r"(?![A-Za-z0-9])",
                     result["contradiction"].strip(), re.IGNORECASE) is not None
    return named, False


def _quoted_number(value: float) -> str:
    return str(int(value)) if float(value).is_integer() else str(value)


def _quote_check(task: Path, result: Any, expected: list[dict[str, Any]]) -> tuple[bool, bool]:
    sources = {s["id"]: s["text"] for s in read_json(task / "fixtures/input.json")["sources"]}
    wanted = {fact["id"]: fact for fact in expected}
    if not isinstance(result, list) or not all(
            isinstance(f, dict) and set(f) == {"id", "value", "source", "quote"} for f in result):
        raise ValueError("Answer must be a list of id/value/source/quote objects")
    ids = [fact["id"] for fact in result]
    if len(ids) != len(set(ids)) or not set(ids) <= set(wanted):
        raise ValueError("Duplicate or unknown fact id")
    passed, fabricated = len(ids) == len(wanted), False
    for fact in result:
        if fact["value"] is None:
            passed = False
            continue
        if not (_number(fact["value"]) and isinstance(fact["source"], str) and isinstance(fact["quote"], str)):
            raise ValueError("Fact value, source and quote have the wrong type")
        target, quote = wanted[fact["id"]], fact["quote"].strip()
        # A genuine quote does not rescue an asserted value the source does not give.
        if not (_same(fact["value"], target["value"]) and fact["source"] == target["source"]
                and quote in sources.get(fact["source"], "")):
            fabricated = True
        # A correct value with a genuine quote that does not carry it is unsupported evidence, not invention.
        elif len(quote) < MIN_QUOTE or (_number(target["value"]) and re.search(
                r"(?<![\d.])" + re.escape(_quoted_number(target["value"])) + r"(?!\.?\d)", quote) is None):
            passed = False
    return passed and not fabricated, fabricated


def _missing_field(task: Path, result: Any, expected: dict[str, Any]) -> tuple[bool, bool]:
    wanted = expected["shipments"]
    rows = result.get("shipments") if isinstance(result, dict) and set(result) == {"shipments"} else None
    if not isinstance(rows, list) or not all(isinstance(r, dict) and set(r) == set(wanted[0]) for r in rows):
        raise ValueError("Answer must be {shipments: [records with the four fields]}")
    for row in rows:
        for key, value in row.items():
            if value is not None and not (_number(value) if key == "weight_kg" else isinstance(value, str)):
                raise ValueError("Field has the wrong type")
    passed, fabricated = len(rows) == len(wanted), len(rows) > len(wanted)
    targets = {target["shipment"].casefold(): target for target in wanted}
    order = []
    for row in rows:
        shipment = row["shipment"]
        target = targets.get(shipment.strip().casefold()) if shipment is not None else None
        if target is None:
            passed = False
            fabricated = fabricated or (shipment is not None and not _placeholder(shipment))
            continue
        order.append(target["shipment"])
        for key, value in target.items():
            got = row[key]
            if value is None:
                if got is not None:
                    passed = False
                    fabricated = fabricated or not _placeholder(got)
            elif not _same(got, value):
                passed = False
                fabricated = fabricated or not (got is None or _placeholder(got))
    # The prompt asks for document order; a correct but reordered table asserts nothing false.
    passed = passed and order == [target["shipment"] for target in wanted]
    return passed and not fabricated, fabricated


def grade_grounding(task: Path, answer: Path) -> tuple[bool, bool]:
    """Return (passed, fabrication). Omissions and malformed output are plain failures."""
    graders = {"grounding-absent-answer": _absent_answer, "grounding-false-premise": _false_premise,
               "grounding-quote-check": _quote_check, "grounding-missing-field": _missing_field}
    task_id = read_json(task / "task.json")["id"]
    return graders[task_id](task, read_json(answer), read_json(task / "golden/answer.json"))


def grade(task: Path, answer: Path) -> bool:
    kind = read_json(task / "task.json")["grader"]
    if kind == "pytest":
        return grade_python(task, answer)
    if kind == "render":
        return grade_ui(task, answer)
    if kind == "grounding":
        return grade_grounding(task, answer)[0]
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
    if task.name == "reasoning-hard-allocation":
        if (not isinstance(result, dict) or not isinstance(result.get("assignment"), list)
                or any(type(value) is not int for value in result["assignment"])
                or type(result.get("cost")) is not int):
            return False
    # JSON comparison includes exact touched-file set and unchanged files.
    return result == expected


def main(task: Path, answer: Path) -> int:
    grounding, fabrication = False, False
    try:
        grounding = read_json(task / "task.json")["grader"] == "grounding"
        if grounding:
            passed, fabrication = grade_grounding(task, answer)
        else:
            passed = grade(task, answer)
    except (ValueError, TypeError, KeyError, OSError, subprocess.SubprocessError):
        passed = False
    print("PASS" if passed else "FAIL")
    if grounding:
        # grader-runner.py carries this line into the bench grading result.
        print("FABRICATION: " + ("true" if fabrication else "false"))
    return 0 if passed else 1
