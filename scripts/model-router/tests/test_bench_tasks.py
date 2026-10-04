from __future__ import annotations

import importlib.util
import hashlib
import json
from pathlib import Path
import subprocess
import sys

import pytest

BENCH = Path(__file__).resolve().parents[1] / "bench"
TASKS = BENCH / "tasks"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


generator = load("fixture_generator", BENCH / "generate-fixtures.py")
grading = load("bench_grading", TASKS / "_grading.py")
review = load("review_tasks", BENCH / "review.py")
sys.path.insert(0, str(BENCH))
import bench_engine as engine  # noqa: E402


def test_seed_byte_parity(tmp_path: Path):
    first, second = tmp_path / "first", tmp_path / "second"
    generator.generate(first)
    generator.generate(second)
    expected = {p.relative_to(TASKS).as_posix(): p.read_bytes() for p in review.bank_files(TASKS)}
    for root in (first, second):
        assert {p.relative_to(root).as_posix(): p.read_bytes() for p in review.bank_files(root)} == expected
    changed = tmp_path / "changed"
    generator.generate(changed, generator.SEED + 1)
    assert (first / "math-return-series/fixtures/input.json").read_bytes() != (changed / "math-return-series/fixtures/input.json").read_bytes()


def test_ids_categories_and_layout():
    expected = {
        "mechanical-extract-table": "mechanical", "mechanical-rename-sweep": "mechanical",
        "routine-coding-endpoint": "routine-coding", "complex-coding-ledger": "complex-coding",
        "ui-frontend-card": "ui-frontend", "code-review-planted": "code-review",
        "math-return-series": "math", "analysis-ddq-gaps": "analysis",
        "planning-migration": "planning", "deep-research-vendor": "deep-research",
        "writing-letter-section": "long-form-writing", "pelican": "image-generation",
        "grounding-absent-answer": "analysis", "grounding-false-premise": "analysis",
        "grounding-quote-check": "deep-research", "grounding-missing-field": "mechanical",
        "writing-status-update": "long-form-writing", "writing-explainer-paragraph": "long-form-writing"}
    metadata = {p.parent.name: json.loads(p.read_text()) for p in TASKS.glob("*/task.json")}
    assert len(metadata) == 18 == len(generator.TASKS)
    assert {key: value["category"] for key, value in metadata.items()} == expected
    for key, value in metadata.items():
        assert value["id"] == key and value["dimension_framework"] == "provisional"
        task = TASKS / key
        for name in ("prompt.md", "grader.py", "fixtures/input.json"):
            assert (task / name).is_file()
        assert list((task / "golden").iterdir())


@pytest.mark.parametrize("task_id", [k for k, v in generator.TASKS.items() if v[2] not in {"rubric", "artifact"}])
def test_deterministic_positive_negative(task_id: str):
    task = TASKS / task_id
    for path, expected in [(task / "known-good.txt", 0)] + [(p, 1) for p in sorted(task.glob("known-bad*.txt"))]:
        result = subprocess.run([sys.executable, str(task / "grader.py"), str(path)],
                                capture_output=True, text=True, timeout=40)
        assert result.returncode == expected, (task_id, path.name, result.stdout[-1000:], result.stderr[-1000:])


@pytest.mark.parametrize("variant, expected", [
    ("controlled", True), ("reset", False), ("remount", False)])
def test_ui_typed_notes_fidelity(tmp_path: Path, variant: str, expected: bool):
    task = TASKS / "ui-frontend-card"
    source = (task / "golden/answer.jsx").read_text(encoding="utf-8")
    # Start from the retained uncontrolled golden; isolate each actual defect.
    if variant in {"controlled", "reset"}:
        source = source.replace("const item =", "const [notes, setNotes] = useState('');\n  const item =")
        source = source.replace('<input aria-label="Notes" />',
                                '<input aria-label="Notes" value={notes} onChange={e => setNotes(e.target.value)} />')
    if variant == "reset":
        source = source.replace("setSelected(i.id)", "(setSelected(i.id), setNotes(''))")
    elif variant == "remount":
        source = source.replace('<section data-testid="workspace">',
                                '<section key={selected} data-testid="workspace">')
    answer = tmp_path / f"{variant}.jsx"
    answer.write_text(source, encoding="utf-8")
    assert grading.grade_ui(task, answer) is expected


@pytest.mark.parametrize("task_id", [k for k, v in generator.TASKS.items() if v[2] == "rubric"])
def test_rubric_schema_and_binary_grading(task_id: str):
    task = TASKS / task_id
    rubric = json.loads((task / "golden/rubric.json").read_text())
    assert rubric["threshold"] == 0.8 and rubric["score_values"] == [0, 1]
    ids = [line["id"] for line in rubric["lines"]]
    assert len(ids) == len(set(ids)) and ids
    assert all(line["criterion"].strip() for line in rubric["lines"])
    assert (task / "judge-prompt.md").is_file()
    assert grading.grade(task, task / "fixtures/judge-positive.json")
    assert not grading.grade(task, task / "fixtures/judge-negative.json")
    for scores in ({}, {key: True for key in ids}, {key: 0.5 for key in ids}, {**dict.fromkeys(ids, 1), "extra": 1}):
        with pytest.raises(ValueError):
            grading.rubric_score(rubric, {"scores": scores})


def test_writer_tasks_load_with_rubric_and_judge_prompt():
    config = json.loads((BENCH / "bench-config.json").read_text())
    writers = sorted(p.parent.name for p in TASKS.glob("*/task.json")
                     if json.loads(p.read_text())["job"] == "writer")
    assert writers == ["writing-explainer-paragraph", "writing-letter-section", "writing-status-update"]
    for task_id in ("writing-status-update", "writing-explainer-paragraph"):
        task = TASKS / task_id
        metadata = json.loads((task / "task.json").read_text())
        assert (metadata["category"], metadata["grader"]) == ("long-form-writing", "rubric")
        assert "difficulty" not in metadata
        rubric = json.loads((task / "golden/rubric.json").read_text())
        assert rubric["threshold"] == config["rubric_threshold"] and len(rubric["lines"]) == 5
        assert sum("No invented facts" in line["criterion"] for line in rubric["lines"]) == 1
        for name in ("prompt.md", "judge-prompt.md", "golden/answer.md", "known-bad.txt", "fixtures/input.json"):
            assert (task / name).read_text(encoding="utf-8").strip(), name
        assert engine.candidate_prompt(task).startswith((task / "prompt.md").read_text(encoding="utf-8"))
    assert 120 <= len((TASKS / "writing-status-update/golden/answer.md").read_text().split()) <= 160
    explainer = (TASKS / "writing-explainer-paragraph/golden/answer.md").read_text()
    assert 90 <= len(explainer.split()) <= 130 and "\n\n" not in explainer.strip()


def test_retained_sources():
    # SHA256 captured from the original primary-tree canary (base 356e7ae).
    # The corrected structured-review task is covered by behavioral tests below.
    # Portable, independent proof of the unchanged pelican prompt.
    expected = {
        "pelican/prompt.md": "2cc61ef0770f69e75ee8c44bff9b94ee7b5701026c763f42d0413d8176d043a7"}
    for relative, digest in expected.items():
        assert hashlib.sha256((TASKS / relative).read_bytes()).hexdigest() == digest


def test_pelican_remains_ungraded(tmp_path: Path):
    answer, artifact = tmp_path / "answer.svg", tmp_path / "artifact.svg"
    answer.write_bytes(b"<svg>synthetic pelican</svg>")
    result = subprocess.run([sys.executable, str(TASKS / "pelican/grader.py"), str(answer), "--artifact", str(artifact)],
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 0 and result.stdout.strip() == "UNGRADED"
    assert artifact.read_bytes() == answer.read_bytes()


def test_socket_guard_allows_event_loop_only(tmp_path: Path):
    task = tmp_path / "task"
    (task / "fixtures").mkdir(parents=True)
    (task / "fixtures/input.json").write_text("{}")
    answer = tmp_path / "answer.py"
    answer.write_text("# synthetic candidate\n")
    (task / "hidden_tests.py").write_text(
        'import asyncio, socket, pytest\n'
        'def test_event_loop_and_guard():\n'
        '    loop = asyncio.new_event_loop()\n'
        '    loop.close()\n'
        '    for method in ("connect", "connect_ex"):\n'
        '        with socket.socket() as sock:\n'
        '            with pytest.raises(RuntimeError, match="network disabled"):\n'
        '                getattr(sock, method)(("127.0.0.1", 9))\n'
        '    with pytest.raises(RuntimeError, match="network disabled"):\n'
        '        socket.create_connection(("127.0.0.1", 9))\n')
    assert grading.grade_python(task, answer)


@pytest.mark.parametrize("expression", [
    "user.is_active and not user.is_banned",
    "not (not user.is_active or user.is_banned)",
    "(user.is_banned == False) and (user.is_active is True)",
    "False or (user.is_active and not user.is_banned)",
])
def test_review_equivalent_corrections(expression: str) -> None:
    module = load("structured_review", TASKS / "code-review-planted/grader.py")
    assert module.grade("LINE: 13\nFIX: " + expression)


@pytest.mark.parametrize("answer", [
    "LINE: 11\nFIX: user.is_active and not user.is_banned",
    "LINE: 13\nFIX: user.is_active or user.is_banned",
    "LINE: 13\nFIX: user.is_active and user.is_banned",
    "LINE: 13\nFIX: not user.is_banned",
    "LINE: 13\nFIX: return user.is_active and not user.is_banned",
    "LINE: 13\nFIX: user.is_active and not user.is_banned\nExtra explanation",
    "Line 13 should use and not user.is_banned.",
    "LINE: 13\nFIX: False and __import__('os').system('unsafe')",
    "LINE: 13\nFIX: user.is_active and not user.is_banned or (False and user.other)",
    "LINE: 13\nFIX: user.is_active and not user.is_banned # hidden comment",
    "LINE: 13\nFIX: [user.is_active][0] and not user.is_banned",
    "LINE: 13\nFIX: (lambda: True)()",
    "LINE: 13\nFIX: user.is_active and (",
])
def test_review_rejects_wrong_malformed_unsafe(answer: str) -> None:
    module = load("structured_review", TASKS / "code-review-planted/grader.py")
    assert not module.grade(answer)


def test_endpoint_handler_name_is_not_contract(tmp_path: Path) -> None:
    task = TASKS / "routine-coding-endpoint"
    golden = (task / "golden/answer.py").read_text()
    answer = tmp_path / "renamed.py"
    answer.write_text(golden.replace("get_item", "read_item"))
    assert grading.grade_python(task, answer)
    answer.write_text(golden.replace("get_item", "read_item").replace(" -> Item", ""))
    assert not grading.grade_python(task, answer)


@pytest.mark.parametrize("wrong_peak", ["ignore-start", "global-maximum"])
def test_math_rejects_wrong_peak_algorithms(tmp_path: Path, wrong_peak: str) -> None:
    task = TASKS / "math-return-series"
    fixture = json.loads((task / "fixtures/input.json").read_text())
    expected = json.loads((task / "golden/answer.json").read_text())
    wealth = expected["wealth"]
    peaks = ([max(wealth[:i + 1]) for i in range(len(wealth))] if wrong_peak == "ignore-start"
             else [max([1, *wealth])] * len(wealth))
    draws = [level / peak - 1 for level, peak in zip(wealth, peaks)]
    answer = tmp_path / "math.json"
    answer.write_text(json.dumps(dict(wealth=wealth, peaks=peaks, drawdowns=draws, max_drawdown=min(draws))))
    assert fixture["returns"][0] < 0 and max(wealth) > 1
    assert not grading.grade(task, answer)


def test_math_decimal_oracle_and_month_only_arrays(tmp_path: Path) -> None:
    from decimal import Decimal
    task = TASKS / "math-return-series"
    fixture = json.loads((task / "fixtures/input.json").read_text(), parse_float=Decimal)
    level = peak = Decimal(1)
    wealth, peaks, drawdowns = [], [], []
    for change in fixture["returns"]:
        level *= 1 + change
        peak = max(peak, level)
        wealth.append(float(level)); peaks.append(float(peak)); drawdowns.append(float(level / peak - 1))
    oracle = dict(wealth=wealth, peaks=peaks, drawdowns=drawdowns, max_drawdown=min(drawdowns))
    answer = tmp_path / "math.json"
    answer.write_text(json.dumps(oracle))
    assert grading.grade(task, answer)
    for key, start in (("wealth", 1), ("peaks", 1), ("drawdowns", 0)):
        oracle[key].insert(0, start)
    answer.write_text(json.dumps(oracle))
    assert not grading.grade(task, answer)
    assert "one entry per month excluding the start" in (task / "prompt.md").read_text()


def test_rubric_prompt_and_golden_alignment() -> None:
    planning = (TASKS / "planning-migration/prompt.md").read_text()
    assert "batched resumable backfill" in planning
    research = (TASKS / "deep-research-vendor/prompt.md").read_text()
    assert "fictional vendor SyntheticVault-Example" in research
    assert "all copies stay in the EU and are deleted within 30 days" in research
    writing = (TASKS / "writing-letter-section/golden/answer.md").read_text()
    assert 230 <= len(writing.split()) <= 270
    assert len(writing.strip().split("\n\n")) >= 3


@pytest.mark.parametrize("newline", ["\n", "\r\n", "\r"])
def test_review_accepts_platform_line_endings(newline: str) -> None:
    module = load("structured_review", TASKS / "code-review-planted/grader.py")
    assert module.grade("LINE: 13" + newline + "FIX: user.is_active and not user.is_banned" + newline)
