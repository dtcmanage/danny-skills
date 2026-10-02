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
        "writing-letter-section": "long-form-writing", "pelican": "image-generation"}
    metadata = {p.parent.name: json.loads(p.read_text()) for p in TASKS.glob("*/task.json")}
    assert len(metadata) == 12
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


def test_retained_sources():
    # SHA256 captured from the original primary-tree canary (base 356e7ae).
    # Portable, independent proof: generator copies alone cannot bless changes.
    expected = {
        "code-review-planted/grader.py": "f0783465411a2f9623d33362001750f17812061f562296151836562c4e057655",
        "code-review-planted/prompt.md": "be4af7059561222e212da85dc766d9d9101bc12bd500dd86c55a45bd648210b8",
        "code-review-planted/known-good.txt": "77882ae88216ea2fa1c9c4ac52946fe9ff5f916390d7344466f41dc8ce0d2fb4",
        "code-review-planted/known-bad.txt": "bf48225b6dc59f2827c73906b77f1a32c7b7d85c73589795bd0e02361a82d1ed",
        "code-review-planted/known-bad-2.txt": "543b85acac41b9561c2f8caf5c9351a906e8b6c6066ee54c5b429308d2f468e1",
        "code-review-planted/known-bad-3.txt": "4881952491b2743580cdb5341e6debf2f63096d1f1a85bba5e78f0b2141b7822",
        "code-review-planted/known-bad-4.txt": "247b1604b98ca473f700d6536c9bc1a1a3953ed3261ba32470ed2d4804ac49e6",
        "code-review-planted/known-bad-5.txt": "62a660c558517abd78e7e3ef7a2abc7e93bf0857b1518464c6d5c1386ea803c3",
        "code-review-planted/known-bad-6.txt": "d527908fa3f539dce9b8d53856b414706400af89c7317f6e325f7eabd49fe300",
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
