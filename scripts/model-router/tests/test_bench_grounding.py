from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

from test_bench_runner import BENCH, engine, run
from test_bench_tasks import generator, review

TASKS = BENCH / "tasks"
GROUNDING = [k for k, v in generator.TASKS.items() if v[2] == "grounding"]
ANSWERS = [("known-good.txt", "pass", False), ("known-bad.txt", "fail", True),
           ("known-bad-omission.txt", "fail", False)]


def grader_lines(task: Path, answer: Path) -> list[str]:
    result = subprocess.run([sys.executable, str(task / "grader.py"), str(answer)],
                            capture_output=True, text=True, timeout=40)
    return result.stdout.split()


def test_grounding_bank_shape() -> None:
    assert GROUNDING == ["grounding-absent-answer", "grounding-false-premise",
                         "grounding-quote-check", "grounding-missing-field"]
    jobs = {k: json.loads((TASKS / k / "task.json").read_text())["job"] for k in GROUNDING}
    assert jobs == {"grounding-absent-answer": "deep-thinker", "grounding-false-premise": "deep-thinker",
                    "grounding-quote-check": "deep-thinker", "grounding-missing-field": "fast"}


@pytest.mark.parametrize("task_id", GROUNDING)
@pytest.mark.parametrize("name, status, fabrication", ANSWERS)
def test_answers_grade_with_fabrication_flag(task_id: str, name: str, status: str, fabrication: bool) -> None:
    task = TASKS / task_id
    answer = (task / name).read_text(encoding="utf-8")
    graded = engine.grade_answer(task, answer)
    assert (graded["status"], graded["fabrication"]) == (status, fabrication), graded
    assert grader_lines(task, task / name) == [status.upper(), "FABRICATION:", str(fabrication).lower()]


@pytest.mark.parametrize("task_id", GROUNDING)
@pytest.mark.parametrize("answer", ["not json", "[]", "{}", '"text"'])
def test_malformed_output_is_plain_failure(task_id: str, answer: str) -> None:
    # An empty object omits every answer; omissions are never invented values.
    graded = engine.grade_answer(TASKS / task_id, answer)
    assert graded["status"] == "fail" and graded["fabrication"] is False


def quote_answer(**changes: object) -> str:
    facts = json.loads((TASKS / "grounding-quote-check/golden/answer.json").read_text())
    facts[1].update(changes)
    return json.dumps(facts)


def test_invented_value_with_genuine_quote_is_fabrication() -> None:
    task = TASKS / "grounding-quote-check"
    sources = {s["id"]: s["text"] for s in json.loads((task / "fixtures/input.json").read_text())["sources"]}
    golden = json.loads((task / "golden/answer.json").read_text())
    assert golden[1]["quote"] in sources["S2"]
    invented = golden[1]["value"] + 7
    graded = engine.grade_answer(task, quote_answer(value=invented))
    assert (graded["status"], graded["fabrication"]) == ("fail", True)
    # The beta figure is genuinely quoted from S4, but S4 does not answer the question asked.
    beta = sources["S4"].split("with ")[1].split(" days")[0]
    graded = engine.grade_answer(task, quote_answer(value=int(beta), source="S4", quote=sources["S4"]))
    assert (graded["status"], graded["fabrication"]) == ("fail", True)
    graded = engine.grade_answer(task, quote_answer(source="S5", quote=sources["S5"]))
    assert (graded["status"], graded["fabrication"]) == ("fail", True)
    graded = engine.grade_answer(task, quote_answer(value=None))
    assert (graded["status"], graded["fabrication"]) == ("fail", False)


@pytest.mark.parametrize("task_id, mutate", [
    ("grounding-absent-answer", lambda a: {**a, "q1": a["q1"] + 1}),
    ("grounding-absent-answer", lambda a: {**a, "q4": "Morgan Sample"}),
    ("grounding-false-premise", lambda a: {**a, "premise_holds": True}),
    ("grounding-missing-field", lambda a: {"shipments": a["shipments"] + [a["shipments"][0]]}),
])
def test_wrong_asserted_values_are_fabrication(task_id: str, mutate) -> None:
    task = TASKS / task_id
    answer = mutate(json.loads((task / "golden/answer.json").read_text()))
    graded = engine.grade_answer(task, json.dumps(answer))
    assert (graded["status"], graded["fabrication"]) == ("fail", True)


def test_absent_field_null_is_required() -> None:
    task = TASKS / "grounding-missing-field"
    golden = json.loads((task / "golden/answer.json").read_text())
    missing = [i for i, row in enumerate(golden["shipments"]) if row["carrier"] is None]
    assert len(missing) == 1 and "Carrier:" not in (task / "fixtures/document.txt").read_text().split("[RECORD")[missing[0] + 1]


def test_non_grounding_graders_never_flag_fabrication() -> None:
    task = TASKS / "mechanical-extract-table"
    graded = engine.grade_answer(task, (task / "known-bad.txt").read_text())
    assert (graded["status"], graded["fabrication"]) == ("fail", False)


def test_regeneration_is_byte_identical(tmp_path: Path) -> None:
    new = GROUNDING + ["writing-status-update", "writing-explainer-paragraph"]
    expected = {p.relative_to(TASKS).as_posix(): p.read_bytes() for p in review.bank_files(TASKS)
                if p.relative_to(TASKS).parts[0] in new}
    assert len(expected) >= 8 * 6
    for name in ("first", "second"):
        generator.generate(tmp_path / name)
        actual = {p.relative_to(tmp_path / name).as_posix(): p.read_bytes() for p in review.bank_files(tmp_path / name)
                  if p.relative_to(tmp_path / name).parts[0] in new}
        assert actual == expected
    generator.generate(tmp_path / "changed", generator.SEED + 1)
    changed = [t for t in GROUNDING if (tmp_path / "changed" / t / "golden/answer.json").read_bytes()
               != (TASKS / t / "golden/answer.json").read_bytes()]
    assert changed


def test_report_counts_fabrications_per_model(tmp_path: Path) -> None:
    tasks = tmp_path / "tasks"
    tasks.mkdir()
    shutil.copyfile(TASKS / "_grading.py", tasks / "_grading.py")
    names = [t for t in GROUNDING if t != "grounding-missing-field"]
    for name in names:
        shutil.copytree(TASKS / name, tasks / name, ignore=shutil.ignore_patterns("__pycache__"))
    prompts = {name: (TASKS / name / "prompt.md").read_text(encoding="utf-8") for name in names}

    def dispatch(request: dict) -> dict:
        name = next(n for n, text in prompts.items() if request["prompt"].startswith(text))
        answer = "known-bad.txt" if request["model"] == "candidate" else "known-good.txt"
        return {"status": "ok", "answer": (TASKS / name / answer).read_text(encoding="utf-8")}

    result = run(tmp_path / "state", job="deep-thinker", effort="high", tasks=tasks,
                 dispatch=dispatch, grade=engine.grade_answer)
    assert result["fabrications"] == {"candidate": 9, "incumbent": 0}
    assert result["first_attempt_failures"]["candidate"]["fabrications"] == 9
    assert result["first_attempt_failures"]["incumbent"]["fabrications"] == 0
    assert result["better"] == "incumbent" and not result["tied"]
    report = Path(result["report_paths"]["markdown"]).read_text(encoding="utf-8")
    assert "| Lane | Model | Effort | Answer reps |" in report
    assert "| Grader unknowns | Fabrications | Judge calls |" in report
    # Effort lanes run on the incumbent model but keep their own rows.
    assert "| candidate | candidate | high | 9 | 9 | 0 | 0 | 9 | 0 | 0 | 0 |" in report
    assert "| incumbent | incumbent | high | 9 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |" in report
    assert "| effort-down | incumbent | medium | 9 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |" in report
    assert set(result["first_attempt_failures"]) == {"candidate", "incumbent", "effort-down"}
    assert result["first_attempt_failures"]["effort-down"]["model"] == "incumbent"


def test_effort_lane_fabrications_stay_off_incumbent_row(tmp_path: Path) -> None:
    tasks = tmp_path / "tasks"
    tasks.mkdir()
    shutil.copyfile(TASKS / "_grading.py", tasks / "_grading.py")
    name = "grounding-false-premise"
    shutil.copytree(TASKS / name, tasks / name, ignore=shutil.ignore_patterns("__pycache__"))

    def dispatch(request: dict) -> dict:
        answer = "known-bad.txt" if request["effort"] == "medium" else "known-good.txt"
        return {"status": "ok", "answer": (TASKS / name / answer).read_text(encoding="utf-8")}

    result = run(tmp_path / "state", job="deep-thinker", effort="high", tasks=tasks,
                 dispatch=dispatch, grade=engine.grade_answer)
    lanes = result["first_attempt_failures"]
    assert (lanes["effort-down"]["fabrications"], lanes["incumbent"]["fabrications"]) == (3, 0)
    assert result["fabrications"] == {"candidate": 0, "incumbent": 0}
    report = Path(result["report_paths"]["markdown"]).read_text(encoding="utf-8")
    assert "| incumbent | incumbent | high | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |" in report
    assert "| effort-down | incumbent | medium | 3 | 3 | 0 | 0 | 3 | 0 | 0 | 0 |" in report


def golden(task_id: str) -> object:
    return json.loads((TASKS / task_id / "golden/answer.json").read_text(encoding="utf-8"))


def graded(task_id: str, answer: object) -> tuple[str, bool]:
    result = engine.grade_answer(TASKS / task_id, json.dumps(answer))
    return result["status"], result["fabrication"]


PASS, PLAIN, FABRICATED = ("pass", False), ("fail", False), ("fail", True)


@pytest.mark.parametrize("value, expected", [
    ("not stated", PASS), ("Not stated.", PASS), (" NOT STATED ", PASS), ("not stated in the extract", PASS),
    ("Not stated!", PASS), ("unknown", PLAIN), ("n/a", PLAIN), ("", PLAIN), (None, PLAIN),
    (4200000, FABRICATED), ("about 4 million dollars", FABRICATED),
])
def test_absent_answer_declines(value: object, expected: tuple[str, bool]) -> None:
    assert graded("grounding-absent-answer", {**golden("grounding-absent-answer"), "q2": value}) == expected


@pytest.mark.parametrize("value, expected", [
    (36, PASS), (36.0, PASS), ("not stated", PLAIN), ("unknown", PLAIN), (None, PLAIN), (40, FABRICATED),
])
def test_absent_answer_answerable_question(value: object, expected: tuple[str, bool]) -> None:
    assert graded("grounding-absent-answer", {**golden("grounding-absent-answer"), "q3": value}) == expected


@pytest.mark.parametrize("named, expected", [
    ("F4", PASS), ("f4", PASS), (" F4 ", PASS), ("F4: Harbor remained open", PASS), ("f4 - the Harbor site", PASS),
    ("F40", PLAIN), ("F4a", PLAIN), ("F5", PLAIN), ("F9", PLAIN), ("Harbor remained open", PLAIN), (None, PLAIN),
])
def test_false_premise_contradiction_id(named: object, expected: tuple[str, bool]) -> None:
    assert graded("grounding-false-premise", {"premise_holds": False, "contradiction": named}) == expected


@pytest.mark.parametrize("named", ["F4", "F5", None])
def test_false_premise_accepted_premise_is_fabrication(named: object) -> None:
    assert graded("grounding-false-premise", {"premise_holds": True, "contradiction": named}) == FABRICATED


def shipments(change: dict | None = None, index: int | None = None) -> list[dict]:
    rows = golden("grounding-missing-field")["shipments"]
    if index is None:
        index = next(i for i, row in enumerate(rows) if row["carrier"] is None)
    rows[index] = {**rows[index], **(change or {})}
    return rows


@pytest.mark.parametrize("carrier, expected", [
    (None, PASS), ("", PLAIN), ("n/a", PLAIN), ("N/A", PLAIN), ("unknown", PLAIN), ("Not Stated", PLAIN),
    ("Example Air", FABRICATED), ("Sample Road", FABRICATED),
])
def test_missing_field_absent_carrier(carrier: object, expected: tuple[str, bool]) -> None:
    assert graded("grounding-missing-field", {"shipments": shipments({"carrier": carrier})}) == expected


def test_missing_field_pairs_rows_by_shipment_id() -> None:
    rows = shipments()
    assert graded("grounding-missing-field", {"shipments": rows[::-1]}) == PLAIN
    assert graded("grounding-missing-field", {"shipments": [rows[1], rows[0], rows[2]]}) == PLAIN
    assert graded("grounding-missing-field", {"shipments": rows[:2]}) == PLAIN
    lower = [{**row, "shipment": row["shipment"].lower()} for row in rows]
    assert graded("grounding-missing-field", {"shipments": lower}) == PASS
    # A reordered table still fabricates when it asserts a value the document does not give.
    wrong = [dict(row) for row in rows[::-1]]
    wrong[0]["weight_kg"] = 99.0
    assert graded("grounding-missing-field", {"shipments": wrong}) == FABRICATED
    invented = [dict(row) for row in rows]
    invented[0]["shipment"] = "SHP-0000"
    assert graded("grounding-missing-field", {"shipments": invented}) == FABRICATED


def test_missing_field_stated_value_placeholder_is_plain() -> None:
    rows = golden("grounding-missing-field")["shipments"]
    stated = next(i for i, row in enumerate(rows) if row["carrier"] is not None)
    for value in (None, "unknown"):
        assert graded("grounding-missing-field", {"shipments": shipments({"carrier": value}, stated)}) == PLAIN


@pytest.mark.parametrize("quote, expected", [
    ("deleted files stay recoverable for 30 days before permanent removal", PASS),
    ("recoverable for 30 days", PASS),
    ("Retention guide", PLAIN), ("30", PLAIN), ("", PLAIN),
    ("deleted files stay recoverable", PLAIN),
    ("days before permanent removal", PLAIN),
    ("recoverable for 30 dayz", FABRICATED),
])
def test_quote_must_carry_the_value(quote: str, expected: tuple[str, bool]) -> None:
    golden_value = golden("grounding-quote-check")[1]["value"]
    quote = quote.replace("30", str(golden_value))
    assert graded("grounding-quote-check", json.loads(quote_answer(quote=quote))) == expected


def test_quote_check_short_or_irrelevant_quote_for_other_facts() -> None:
    task = "grounding-quote-check"
    facts = golden(task)
    sources = {s["id"]: s["text"] for s in json.loads((TASKS / task / "fixtures/input.json").read_text())["sources"]}
    facts[0]["quote"] = sources[facts[0]["source"]].split(":")[0]
    assert graded(task, facts) == PLAIN
    facts = golden(task)
    facts[2]["quote"] = str(facts[2]["value"])
    assert graded(task, facts) == PLAIN
    # An unsupported value stays fabrication even with a long, number-bearing genuine quote.
    facts = golden(task)
    facts[0]["value"] += 1
    assert graded(task, facts) == FABRICATED


def test_runner_honors_fabrication_line_only_for_grounding(tmp_path: Path) -> None:
    task = tmp_path / "mechanical-extract-table"
    shutil.copytree(TASKS / "mechanical-extract-table", task, ignore=shutil.ignore_patterns("__pycache__"))
    (task / "grader.py").write_text("print('FAIL')\nprint('FABRICATION: true')\nraise SystemExit(1)\n",
                                    encoding="utf-8")
    answer = tmp_path / "answer.txt"
    answer.write_text("{}", encoding="utf-8")

    def runner() -> tuple[str, bool]:
        proc = subprocess.run([sys.executable, str(BENCH / "grader-runner.py"), str(task), str(answer)],
                              capture_output=True, text=True, timeout=40)
        result = json.loads(proc.stdout)
        return result["status"], result["fabrication"]

    assert runner() == ("fail", False)
    metadata = json.loads((task / "task.json").read_text(encoding="utf-8"))
    (task / "task.json").write_text(json.dumps({**metadata, "grader": "grounding"}), encoding="utf-8")
    assert runner() == ("fail", True)
