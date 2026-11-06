"""Quota selection, routing evidence and collector counts; temp roots and synthetic fixtures only."""
from __future__ import annotations

import importlib.util
import json
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest

TESTS = Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS.parent))
import cost_report as cr  # noqa: E402

spec = importlib.util.spec_from_file_location("reporting_collector", TESTS.parents[2] / "skills/dt-build/scripts/collect-usage.py")
cu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cu)

NOW = datetime(2026, 11, 5, 18, 0, tzinfo=timezone.utc)
PRICES = {"models": {}, "subscriptions": {}}


@pytest.fixture(autouse=True)
def clear_job_identity(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in ("DT_JOB_ID", "DT_JOB_DIR", "DT_BUILD_COORDINATOR_ID"):
        monkeypatch.delenv(name, raising=False)


def reading(hours_old: float = 1.0, resets_in_hours: float = 72.0, used: float = 40.0, **extra: object) -> dict:
    return {"used_percent": used, "observed_at_utc": (NOW - timedelta(hours=hours_old)).isoformat(),
            "resets_at_utc": (NOW + timedelta(hours=resets_in_hours)).isoformat(), "source": "fixture-source", **extra}


def write_codex(state: Path, live: object = None, weekly: object = None) -> None:
    (state / "readings").mkdir(exist_ok=True)
    if live is not None:
        (state / "readings" / "codex-live.json").write_text(json.dumps(live), encoding="utf-8")
    if weekly is not None:
        (state / "readings" / "codex-appserver.json").write_text(json.dumps(weekly), encoding="utf-8")


def codex(state: Path, **kwargs: object) -> dict:
    return cr.load_codex_usage(state, now=NOW, stale_hours=6, **kwargs)


def test_newest_valid_reading_is_chosen(tmp_path: Path) -> None:
    write_codex(tmp_path, live=reading(hours_old=3, used=11), weekly=reading(hours_old=1, used=22))
    assert codex(tmp_path)["used_percent"] == 22
    write_codex(tmp_path, live=reading(hours_old=0.5, used=33))
    assert codex(tmp_path)["used_percent"] == 33


@pytest.mark.parametrize(("bad", "reason"), [
    (reading(resets_in_hours=-1), "already reset"),
    (reading(hours_old=-2), "future"),
    (reading(window_minutes=300), "wrong window"),
    (reading(resets_in_hours=24 * 8), "wrong window"),
    ({"used_percent": 5, "observed_at_utc": "unknown", "resets_at_utc": (NOW + timedelta(days=1)).isoformat()}, "timestamp"),
    ({"used_percent": 5, "resets_at_utc": (NOW + timedelta(days=1)).isoformat()}, "timestamp"),
    ({"session_percent": 5, "observed_at_utc": NOW.isoformat(), "resets_at_utc": (NOW + timedelta(days=1)).isoformat()}, "percent"),
    ({"used_percent": "many", "observed_at_utc": NOW.isoformat(), "resets_at_utc": (NOW + timedelta(days=1)).isoformat()}, "percent"),
    ([1, 2], "malformed"),
])
def test_invalid_reading_is_rejected_with_its_reason_for_both_vendors(tmp_path: Path, bad: object, reason: str) -> None:
    write_codex(tmp_path, weekly=bad)
    (tmp_path / "claude-usage.json").write_text(json.dumps(bad), encoding="utf-8")
    claude = cr.load_claude_usage(tmp_path, now=NOW, stale_hours=6)
    for result, render in ((codex(tmp_path), cr.render_codex_usage), (claude, cr.render_claude_usage)):
        assert result["status"] == "unavailable" and reason in result["reason"]
        assert "unavailable" in render(result) and "% used" not in render(result)


def test_invalid_newer_reading_leaves_the_older_valid_one(tmp_path: Path) -> None:
    write_codex(tmp_path, live=reading(hours_old=-5, used=99), weekly=reading(hours_old=2, used=20))
    assert codex(tmp_path)["used_percent"] == 20


def test_five_hour_live_reading_is_not_shown_as_weekly(tmp_path: Path) -> None:
    write_codex(tmp_path, live=reading(hours_old=0.1, resets_in_hours=3, used=88), weekly=reading(hours_old=4, used=20))
    chosen = codex(tmp_path)
    assert chosen["used_percent"] == 20
    write_codex(tmp_path, weekly=reading(hours_old=0.1, resets_in_hours=3, used=88))
    assert codex(tmp_path)["used_percent"] == 88  # Near a weekly reset, the snapshot confirms the window.
    (tmp_path / "readings" / "codex-appserver.json").unlink()
    alone = codex(tmp_path)
    assert alone["status"] == "unavailable" and "five-hour" in alone["reason"]


def test_claude_five_hour_percent_never_replaces_weekly(tmp_path: Path) -> None:
    (tmp_path / "claude-usage.json").write_text(json.dumps(reading(used=12, session_percent=95)), encoding="utf-8")
    line = cr.render_claude_usage(cr.load_claude_usage(tmp_path, now=NOW, stale_hours=6))
    assert "Claude weekly usage: 12% used" in line and "5-hour window 95% used" in line


def test_source_and_observed_time_shown_in_et_per_vendor(tmp_path: Path) -> None:
    write_codex(tmp_path, weekly=reading(hours_old=2))
    (tmp_path / "claude-usage.json").write_text(json.dumps(reading(hours_old=2)), encoding="utf-8")
    for line in (cr.render_codex_usage(codex(tmp_path)),
                 cr.render_claude_usage(cr.load_claude_usage(tmp_path, now=NOW, stale_hours=6))):
        assert "Nov 5, 11:00 AM ET" in line and "source fixture-source" in line and "2.0 hours old" in line
        assert "STALE" not in line and "UTC" not in line


def test_old_or_failed_refresh_reading_is_labeled_stale_with_age(tmp_path: Path) -> None:
    write_codex(tmp_path, weekly=reading(hours_old=30))
    old = cr.render_codex_usage(codex(tmp_path))
    assert old.startswith("STALE (30.0 hours old): Codex weekly usage")
    write_codex(tmp_path, weekly=reading(hours_old=1))
    failed = cr.render_codex_usage(codex(tmp_path, refresh_failed=True))
    assert failed.startswith("STALE (1.0 hours old, refresh failed): Codex weekly usage")


def dispatch(task: str, dispatch_id: str, **extra: object) -> dict:
    row = dict(key=f"dispatch:{dispatch_id}", source="dispatch", dispatch_id=dispatch_id, logical_task_id=task, attempt=1,
               category="routine-coding", requested_model=extra.get("resolved_model", "gpt-6-sol"),  # dispatch.ps1 writes the pick to both.
               resolved_model="gpt-6-sol", actual_model="gpt-6-sol",
               override_reason=None, fallback_reason=None, started_utc="2026-11-03T15:00:00Z", duration_ms=2000,
               execution_result="success", failure_category=None, usage=None, independent_acceptance=None)
    return {**row, **extra}


def summarize(rows: list[dict], transcripts: list[dict] | None = None) -> dict:
    return cr.routing_by_task(rows, transcripts or [], 2026, 45)


def test_failed_first_attempt_then_accepted_is_zero_of_one_with_one_retry() -> None:
    summary = summarize([
        dispatch("t", "a", independent_acceptance=False),
        dispatch("t", "b", attempt=2, prior_dispatch_id="a", independent_acceptance=True),
    ])
    assert (summary["first_attempt_accepted"], summary["verified_tasks"], summary["later_attempts"]) == (0, 1, 1)
    assert summary["unverified_tasks"] == 0 and summary["quality_failures"] == 1


def test_execution_success_without_verifier_stays_outside_the_denominator() -> None:
    summary = summarize([dispatch("adhoc", "a"), dispatch("verified", "b", independent_acceptance=True)])
    assert (summary["first_attempt_accepted"], summary["verified_tasks"], summary["unverified_tasks"]) == (1, 1, 1)
    assert summary["execution_success"] == 2


def test_failure_kinds_stay_separate_and_unknown_stays_unknown() -> None:
    summary = summarize([
        dispatch("a", "1", execution_result="failure", failure_category="model-output"),
        dispatch("b", "2", execution_result="failure", failure_category="environment"),
        dispatch("c", "3", independent_acceptance=False),
        dispatch("d", "4", execution_result=None, actual_model=None, duration_ms=None),
    ])
    assert (summary["execution_failures"], summary["infrastructure_failures"], summary["quality_failures"], summary["unknown_results"]) == (1, 1, 1, 1)
    assert summary["actual_unknown"] == 1 and summary["mismatched"] == 0
    row = next(item for item in summary["tasks"] if item[0] == "d")
    assert row[3] == "unknown (unknown)" and row[6] == "unknown" and row[7] == "unknown"


def test_routing_classes_and_null_fallback_on_lane_refusal_is_no_fallback() -> None:
    summary = summarize([
        dispatch("ok", "1", actual_model="gpt-6-sol"),
        dispatch("wrong", "2", actual_model="gpt-6-luna"),
        dispatch("alias", "3", resolved_model="opus", actual_model="claude-opus-5-5-20260101"),
        dispatch("override", "4", requested_model="gpt-6-luna"),
        dispatch("explained", "5", requested_model="gpt-6-luna", override_reason="fixture"),
        dispatch("inherit", "6", resolved_model=None),
        dispatch("fellback", "7", requested_model="gpt-6-sol", resolved_model="claude-opus-5-5",
                 actual_model="claude-opus-5-5", fallback_reason="quota"),
        dispatch("model-wait", "8", requested_model="gpt-6-sol", resolved_model=None, actual_model=None, execution_result=None),
        dispatch("router-wait", "9", requested_model=None, resolved_model=None, actual_model=None, execution_result=None),
    ])
    assert (summary["mismatched"], summary["unexplained_overrides"], summary["inherited"], summary["fallbacks"]) == (1, 1, 1, 1)
    assert (summary["routed"], summary["refused"], summary["actual_unknown"]) == (5, 2, 0)


def test_selected_and_actual_vendor_shown_for_a_cross_vendor_fallback() -> None:
    row, = summarize([dispatch("t", "1", requested_model="gpt-6-sol", resolved_model="claude-opus-5-5",
                              actual_model="claude-opus-5-5", fallback_reason="quota")])["tasks"]
    assert row[2] == "gpt-6-sol (codex)" and row[3] == "claude-opus-5-5 (claude)"


def test_failed_preflight_canary_and_event_are_one_logical_dispatch() -> None:
    at = "2026-11-03T15:00:00Z"
    summary = summarize([
        {"key": "abc:preflight", "source": "canary", "at": at, "pass": False, "failure_category": "environment"},
        {"key": "abc:0011", "source": "dispatch-event", "at": at, "pass": False, "failure_category": "environment"},
    ])
    assert summary["failed_preflights"] == 1 and summary["tasks"] == [] and summary["routed"] == 0


def test_bench_and_legacy_rows_stay_out_of_routed_and_task_counts() -> None:
    summary = summarize([
        dispatch("b", "1", source="bench", usage={"input_tokens": 5, "output_tokens": 5}),
        {"key": "legacy-1", "source": "dt-build", "at": "2026-11-03T15:00:00Z", "pass": True},
    ])
    assert (summary["routed"], summary["tasks"], summary["verified_tasks"]) == (0, [], 0)
    assert (summary["legacy_rows"], summary["bench_rows"], summary["bench_tokens"], summary["delegated_tokens"]) == (1, 1, 10, 0)


@pytest.mark.parametrize(("usage", "tokens", "unknown"), [
    ({"input_tokens": 3, "cached_input_tokens": 1, "output_tokens": 4}, 7, 0),
    ({"inputTokens": 3, "outputTokens": 4}, 7, 0),
    ([{"model": "a", "input_tokens": 1, "output_tokens": 2}, {"model": "b", "inputTokens": 3, "outputTokens": 4}], 10, 0),
    (None, 0, 1),
    ({"output_tokens": 4}, 0, 1),
    ([{"input_tokens": 1, "output_tokens": 2}, {"model": "b"}], 0, 1),
])
def test_usage_shapes_normalize_and_missing_usage_is_never_zero(usage: object, tokens: int, unknown: int) -> None:
    summary = summarize([dispatch("t", "1", usage=usage)])
    assert (summary["delegated_tokens"], summary["delegated_usage_unknown"]) == (tokens, unknown)


def report_for(transcripts: list[dict], outcomes: list[dict]) -> dict:
    return cr.build_weekly_reports([], [], PRICES, today_et=date(2026, 11, 20), routing_rows=transcripts, outcome_rows=outcomes)[0]


def transcript_row(host: str = "claude", **counts: int) -> dict:
    return {"kind": "routing", "host": host, "session_id": "s", "project": "p", "workstation": "w",
            "date_et": "2026-11-03", "by_category": {}, "by_job": {},
            **{"delegations": 0, "routed": 0, "unrouted": 0, **counts}}


def test_zero_violations_with_no_routed_dispatches_does_not_read_as_success() -> None:
    report = report_for([transcript_row()], [])
    verdict = cr.routing_headline_lines(report)[0]
    assert "not evidence of success" in verdict
    for text in (cr.render_markdown(report), cr.render_html(report)):
        assert "not evidence of success" in text and "Routing by task" in text


def test_zero_violations_with_low_routed_share_is_not_success() -> None:
    verdict = cr.routing_verdict(summarize([], [transcript_row(delegations=10, routed=1, unrouted=9)]))
    assert "only 1 of 10" in verdict and "not success" in verdict


def test_dispatch_rows_never_lift_the_transcript_routed_share_in_rendered_text() -> None:
    rows = [dispatch(f"t{index}", str(index)) for index in range(10)]
    report = report_for([transcript_row(delegations=10, routed=2, unrouted=8, native_denied=8)], rows)
    for text in (cr.render_markdown(report), cr.render_html(report)):
        assert "All 10" not in text and "only 2 of 10" in text
        assert "Dispatch evidence: 10 routed" in text
        assert "2 routed of 10 delegations" in text and "native attempts denied 8" in text


def test_zero_transcript_routed_count_is_a_lower_bound_with_dispatch_evidence() -> None:
    report = report_for([transcript_row()], [dispatch("task", "dispatch")])
    for text in (cr.render_markdown(report), cr.render_html(report)):
        assert "Transcript routed delegation count: 0 (a lower bound)" in text
        assert "see the Dispatch evidence line below" in text
        assert "Dispatch evidence: 1 routed" in text
        assert "No routed" not in text
        assert "launches holding the command in shell variables" in text


def test_executed_native_call_is_named_and_never_routed() -> None:
    report = report_for([transcript_row(delegations=2, unrouted=2, native_denied=1, native_executed=1)], [])
    lines = cr.routing_headline_lines(report)
    assert "ran outside dispatch.ps1" in lines[0]
    assert "0 routed of 2 delegations" in lines[2] and "native attempts denied 1, native calls executed 1" in lines[2]


def test_transcript_counts_stay_labeled_partial_with_host_gaps() -> None:
    usage = [{"kind": "usage", "host": "codex", "session_id": "s", "model": "m", "date_et": "2026-11-03",
              "calls": 1, "tokens": {"input": 1}}]
    report = cr.build_weekly_reports(usage, [], PRICES, today_et=date(2026, 11, 20),
                                     routing_rows=[transcript_row(host="codex")])[0]
    coverage = cr.routing_headline_lines(report)[-1]
    assert "partial observed coverage" in coverage and "Codex missing 2026-11-02" in coverage


def test_past_week_labels_current_quota_and_current_week_does_not(tmp_path: Path) -> None:
    write_codex(tmp_path, weekly=reading())
    report = report_for([transcript_row(host="codex")], [])
    report["codex_usage"] = codex(tmp_path)
    assert report["historical"] is True
    report["vendors"]["codex"] = cr.VendorWeek(host="codex", label="Codex", subscription_usd=0, api_equivalent_usd=0)
    assert "Current reading, not from this past week: Codex weekly usage" in cr.render_markdown(report)
    current = cr.build_weekly_reports([], [], PRICES, today_et=date(2026, 11, 3), routing_rows=[transcript_row()])[0]
    assert current["historical"] is False


def claude_transcript(tmp_path: Path, rows: list[dict]) -> list[dict]:
    path = tmp_path / "D--Claude--Claude-Workspace-Skill-Creation" / "session.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
    return [row for row in cu.all_sessions_claude_rows(path) if row["kind"] == "routing"]


def tool(tool_id: str, name: str, **inputs: object) -> dict:
    return {"type": "assistant", "timestamp": "2026-11-03T15:00:00Z", "message": {
        "id": tool_id, "role": "assistant", "content": [{"type": "tool_use", "id": tool_id, "name": name, "input": inputs}]}}


def result(tool_id: str, text: str, is_error: bool = False) -> dict:
    return {"type": "user", "timestamp": "2026-11-03T15:00:01Z", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tool_id, "content": text, "is_error": is_error}]}}


DENY = "Hook PreToolUse:Agent denied this tool call: ROUTER_GUARD_DENY: category routine-coding; dispatch.ps1"


def test_claude_transcript_routed_denied_native_workflow_counts(tmp_path: Path) -> None:
    row, = claude_transcript(tmp_path, [
        tool("r1", "Bash", command='pwsh -NoProfile -File "D:/x y/scripts/model-router/dispatch.ps1" -Category analysis -Live'),
        result("r1", "ok"),
        tool("r2", "PowerShell", command="& ./dispatch.ps1 -Category mechanical -Model gpt-6-luna -OverrideReason x -Live"),
        result("r2", "ok"),
        tool("n1", "Agent", model="opus"), result("n1", DENY, True),
        tool("n2", "Agent", model="opus"), result("n2", "subagent finished"),
        tool("n3", "Task"),
        tool("d1", "Bash", command="timeout 60 claude -p hi"), result("d1", DENY.replace("Agent", "Bash"), True),
        tool("d2", "Bash", command="claude -p hi"), result("d2", "hi"),
        tool("w1", "Workflow", script="fixture"), result("w1", "done"),
    ])
    assert (row["delegations"], row["routed"], row["unrouted"]) == (7, 2, 5)
    assert (row["native_denied"], row["native_executed"], row["native_unknown"]) == (1, 1, 1)
    assert (row["direct_denied"], row["direct_executed"], row["direct_unknown"]) == (1, 1, 0)
    assert row["workflow_calls"] == 1
    assert row["by_category"] == {"analysis": 1, "mechanical": 1}


def test_native_call_with_a_selection_line_is_still_not_routed(tmp_path: Path) -> None:
    row, = claude_transcript(tmp_path, [
        {"type": "assistant", "timestamp": "2026-11-03T15:00:00Z", "message": {"id": "m", "role": "assistant", "content": [
            {"type": "text", "text": "MODEL_SELECTION: task -> model (analysis, protected, effort high): fixture"},
            {"type": "tool_use", "id": "n", "name": "Agent", "input": {"model": "opus"}}]}},
        result("n", "subagent finished"),
    ])
    assert (row["routed"], row["unrouted"], row["native_executed"]) == (0, 1, 1)


def test_guard_text_in_ordinary_output_does_not_mark_a_denial(tmp_path: Path) -> None:
    row, = claude_transcript(tmp_path, [
        tool("n", "Agent", model="opus"),
        result("n", "x" * 400 + "ROUTER_GUARD_DENY: quoted from a file"),
    ])
    assert (row["native_denied"], row["native_executed"]) == (0, 1)


@pytest.mark.parametrize("command", ["claude -p hi", "claude.cmd -p hi", "& claude -p hi", "timeout 60 claude -p hi",
                                     "$out = claude -p hi", "codex exec task"])
def test_literal_launches_count_as_the_guard_sees_them(command: str) -> None:
    assert cu.executed_dispatch_details(command) == [{"wrapper": False, "explicit": False}]
    assert cu.executed_dispatch(command) is False


def test_dispatch_mention_and_argument_are_not_delegations() -> None:
    assert cu.executed_dispatch_details("echo dispatch.ps1") == []
    assert cu.executed_dispatch_details("cat <<'EOF'\npwsh -File dispatch.ps1\nEOF") == []
    assert cu.executed_dispatch_details("pwsh -File dispatch.ps1 -Preflight -Category analysis") == []


def test_codex_exec_shape_is_measured_and_unreadable_commands_stay_unmeasured() -> None:
    row, = cu.codex_routing_rows(TESTS / "fixtures" / "codex-rollout-exec-shape.jsonl", {"analysis": "deep-thinker"})
    assert (row["host"], row["date_et"], row["session_id"]) == ("codex", "2026-11-05", "fixture-exec-shape")
    assert row["workstation"] == "Skill Creation"
    assert (row["routed"], row["by_category"], row["by_job"]) == (1, {"analysis": 1}, {"deep-thinker": 1})
    assert (row["spawn_agent"], row["native_executed"]) == (2, 2)
    assert (row["direct_executed"], row["direct_denied"], row["direct_unknown"]) == (1, 1, 0)
    assert (row["delegations"], row["unrouted"]) == (5, 4)
    assert (row["shell_calls_read"], row["shell_calls_unmeasured"]) == (4, 1)


def test_codex_fixture_holds_no_real_session_identifiers() -> None:
    text = (TESTS / "fixtures" / "codex-rollout-exec-shape.jsonl").read_text(encoding="utf-8")
    assert "rollout-" not in text and "fixture" in text and "Danny" not in text


def test_unreadable_only_rollout_reports_unmeasured_not_zero(tmp_path: Path) -> None:
    path = tmp_path / "rollout-unreadable.jsonl"
    path.write_text(json.dumps({"timestamp": "2026-11-05T15:00:00Z", "type": "response_item", "payload": {
        "type": "custom_tool_call", "call_id": "c", "name": "exec", "input": "await tools.exec_command({cmd: line});"}}) + "\n", encoding="utf-8")
    row, = cu.codex_routing_rows(path, {})
    assert row["shell_calls_unmeasured"] == 1
    report = report_for([{**row, "date_et": "2026-11-03"}], [])
    assert "unmeasured 1" in cr.routing_headline_lines(report)[2]
