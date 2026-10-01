"""M10 routing contract tests; pinned transcripts, temporary roots, no vendor state."""
from __future__ import annotations

import importlib.util
import json
import shutil
from datetime import date
from pathlib import Path

import pytest

FIXTURES = Path(__file__).resolve().parent / "fixtures"
COLLECTOR = Path(__file__).resolve().parents[3] / "skills/dt-build/scripts/collect-usage.py"
spec = importlib.util.spec_from_file_location("routing_collector", COLLECTOR)
cu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cu)


def transcript(tmp_path: Path, fixture: str, project: str = "D--Claude--Claude-Workspace-Skill-Creation-model-router-observability") -> Path:
    target = tmp_path / project / "session.jsonl"
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(FIXTURES / fixture, target)
    return target


def routing(path: Path) -> list[dict]:
    return [r for r in cu.all_sessions_claude_rows(path) if r["kind"] == "routing"]


def test_ten_calls_claim_one_selection_and_exact_row_shape(tmp_path: Path) -> None:
    path = transcript(tmp_path, "routing-pairing.jsonl")
    assert routing(path) == [{
        "kind": "routing", "host": "claude", "session_id": "session",
        "project": path.parent.name, "workstation": "Skill Creation",
        "date_et": "2026-09-27", "delegations": 10, "routed": 1, "unrouted": 9,
        "by_category": {"routine-coding": 1}, "by_job": {"coder": 1},
    }]


def test_week_boundary_uses_tool_timestamp_and_keeps_pending_selection(tmp_path: Path) -> None:
    rows = routing(transcript(tmp_path, "routing-week-boundary.jsonl"))
    assert [r["date_et"] for r in rows] == ["2026-09-27", "2026-09-28"]
    assert [date.fromisoformat(r["date_et"]).isocalendar().week for r in rows] == [39, 40]
    assert [r["by_category"] for r in rows] == [{"planning": 1}, {"mechanical": 1}]
    assert [r["by_job"] for r in rows] == [{"deep-thinker": 1}, {"fast": 1}]
    assert all(r["delegations"] == r["routed"] == 1 for r in rows)


def test_dispatch_types_nearest_pairing_and_preflight_exclusion(tmp_path: Path) -> None:
    row, = routing(transcript(tmp_path, "routing-dispatch-kinds.jsonl"))
    assert (row["delegations"], row["routed"], row["unrouted"]) == (6, 3, 3)
    assert row["by_category"] == {"analysis": 1, "complex-coding": 1, "mechanical": 1}
    assert row["by_job"] == {"deep-thinker": 1, "coder": 1, "fast": 1}


def test_missing_model_consumes_selection_before_explicit_model(tmp_path: Path) -> None:
    path = transcript(tmp_path, "routing-dispatch-kinds.jsonl")
    row = json.loads(path.read_text(encoding="utf-8"))
    blocks = row["message"]["content"]
    row["message"]["role"] = "assistant"
    row["message"]["content"] = blocks[1:4]
    path.write_text(json.dumps(row) + "\n", encoding="utf-8")
    result, = routing(path)
    assert (result["delegations"], result["routed"], result["unrouted"]) == (2, 0, 2)
    assert result["by_category"] == result["by_job"] == {}


@pytest.mark.parametrize("row_type", ["user", "assistant"])
def test_user_selection_and_artifact_tools_are_ignored(tmp_path: Path, row_type: str) -> None:
    path = transcript(tmp_path, "routing-dispatch-kinds.jsonl")
    row = json.loads(path.read_text(encoding="utf-8"))
    blocks = row["message"]["content"]
    user = {**row, "type": row_type, "message": {
        "id": "user-artifact", "role": "user", "content": [blocks[0], blocks[3]],
    }}
    assistant = {**row, "message": {**row["message"], "role": "assistant", "content": [blocks[3]]}}
    path.write_text(json.dumps(user) + "\n" + json.dumps(assistant) + "\n", encoding="utf-8")
    result, = routing(path)
    assert (result["delegations"], result["routed"], result["unrouted"]) == (1, 0, 1)
    assert result["by_category"] == result["by_job"] == {}
    pending: list[tuple[str, str] | None] = []
    buckets: dict[str, dict] = {}
    cu.tally_routing_message(user, pending, buckets, {})
    assert pending == []
    assert buckets == {}


@pytest.mark.parametrize(("project", "expected"), [
    ("D--Claude--Claude-Workspace-Finance-HQ-Tax-2026", "Finance HQ"),
    ("D--Claude--Claude-Workspace-Skill-Creation-danny-skills-feature", "Skill Creation"),
    ("D--Claude--Claude-Workspace-TCM-Website-thai-capital-website--claude-worktrees-build-run", "TCM Website"),
    ("D--Claude--Claude-Workspace-Valheim-modpack-feature", "Valheim"),
    ("D--Claude", "workspace root"),
    ("D--Claude-Temp-build", "other"),
    ("C--Temp-build", "other"),
    ("E--Claude--Claude-Workspace-Finance-HQ", "other"),
])
def test_workstation_parent_and_buckets(tmp_path: Path, project: str, expected: str) -> None:
    row, = routing(transcript(tmp_path, "routing-pairing.jsonl", project))
    assert row["workstation"] == expected
    assert row["project"] == project


@pytest.mark.parametrize("version", [None, 0, 1])
def test_old_cache_rebuilt_once_for_unchanged_claude_and_codex(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, version: int | None) -> None:
    claude = tmp_path / "projects"
    codex = tmp_path / "sessions"
    transcript(claude, "routing-pairing.jsonl")
    codex.mkdir()
    (codex / "rollout-test.jsonl").write_text(json.dumps({"type": "event_msg", "timestamp": "2026-09-27T23:00:00Z", "payload": {"type": "token_count", "info": {"last_token_usage": {"input_tokens": 10}}}}) + "\n", encoding="utf-8")
    _, cache = cu.sweep_all_sessions(claude, codex, {})
    for entry in cache["files"].values():
        entry["rows"] = [{"kind": "stale"}]
    if version is None:
        del cache["cache_version"]
    else:
        cache["cache_version"] = version
    rows, rebuilt = cu.sweep_all_sessions(claude, codex, cache)
    assert rebuilt["cache_version"] == 2
    assert not any(r["kind"] == "stale" for r in rows)
    assert any(r["kind"] == "routing" for r in rows)
    assert any(r["host"] == "codex" for r in rows)
    def unexpected_parse(*args: object) -> None:
        pytest.fail("unchanged v2 transcript reparsed")
    monkeypatch.setattr(cu, "all_sessions_claude_rows", unexpected_parse)
    monkeypatch.setattr(cu, "all_sessions_codex_rows", unexpected_parse)
    assert cu.sweep_all_sessions(claude, codex, rebuilt) == (rows, rebuilt)


def test_week_without_parseable_agent_blocks_retains_usage_not_zero_compliance(tmp_path: Path) -> None:
    rows = cu.all_sessions_claude_rows(transcript(tmp_path, "routing-no-agent-blocks.jsonl"))
    assert len(rows) == 1
    assert rows[0]["kind"] == "usage"
    assert rows[0]["date_et"] == "2026-09-27"


def test_subagents_do_not_add_delegations_and_repeated_tool_is_counted_once(tmp_path: Path) -> None:
    path = transcript(tmp_path, "routing-pairing.jsonl")
    original = path.read_text(encoding="utf-8")
    path.write_text(original * 2, encoding="utf-8")
    subs = path.with_suffix("") / "subagents"
    subs.mkdir(parents=True)
    shutil.copyfile(FIXTURES / "routing-pairing.jsonl", subs / "agent.jsonl")
    row, = routing(path)
    assert (row["delegations"], row["routed"]) == (10, 1)


def test_unparseable_selection_still_credits_explicit_model(tmp_path: Path) -> None:
    path = transcript(tmp_path, "routing-pairing.jsonl")
    path.write_text(path.read_text(encoding="utf-8").replace(
        "(routine-coding, protected, effort high)", "legacy reason without category"), encoding="utf-8")
    row, = routing(path)
    assert (row["delegations"], row["routed"], row["unrouted"]) == (10, 1, 9)
    assert row["by_category"] == row["by_job"] == {}


def test_streamed_blocks_sharing_message_id_keep_selections_and_tools(tmp_path: Path) -> None:
    path = transcript(tmp_path, "routing-week-boundary.jsonl")
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
    for row in rows:
        row["message"]["id"] = "streamed-message"
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
    assert sum(row["routed"] for row in routing(path)) == 2


@pytest.mark.parametrize("command", [
    "rg -n invoke-codex-chunk.ps1 .",
    'echo "codex exec -m gpt-6.1-sol"',
    "rg -n 'codex exec -m gpt-6.1-sol' .",
    'printf "%s\\n" "invoke-claude-chunk.ps1"',
    '# codex exec -m gpt-6.1-sol\necho done',
    'cat > example.sh <<\'EOF\'\ncodex exec -m gpt-6.1-sol prompt\nEOF\n',
    'cat > example.ps1 << EOF\npwsh -File invoke-codex-chunk.ps1\nEOF\n',
    'cat <<-"EOF" > example.sh\n\tcodex exec -m gpt-6.1-sol prompt\n\tEOF\n',
    '$example = @"\ncodex exec -m gpt-6.1-sol prompt\n"@\nSet-Content example.sh $example',
    "$example = @'\n& 'invoke-claude-chunk.ps1'\n'@\nSet-Content example.ps1 $example",
    "pwsh -Command \"Write-Output 'codex exec -m gpt-6.1-sol'\"",
    'echo "example; codex exec -m gpt-6.1-sol"',
    "pwsh -File invoke-codex-chunk.ps1 -Preflight",
    "& './invoke-claude-chunk.ps1' -Preflight:$true",
])
def test_command_mentions_do_not_count_or_consume_selection(command: str) -> None:
    pending: list[tuple[str, str] | None] = [("routine-coding", "medium")]
    buckets: dict[str, dict] = {}
    row = {"timestamp": "2026-10-01T16:00:00Z", "message": {
        "role": "assistant", "content": [{"type": "tool_use", "name": "Bash",
                                            "input": {"command": command}}]}}
    cu.tally_routing_message(row, pending, buckets, {})
    assert buckets == {}
    assert pending == [("routine-coding", "medium")]


@pytest.mark.parametrize(("command", "explicit"), [
    ("codex exec -m gpt-6.1-sol prompt", True),
    ("codex exec prompt", False),
    ('codex exec "example -m gpt-6.1-sol"', False),
    ("cd /repo && codex exec -m 'gpt-6.1-sol' prompt", True),
    ("MODEL_ENV=test codex exec -m gpt-6.1-sol prompt", True),
    ("pwsh -NoProfile -File './skills/dt-build/scripts/invoke-codex-chunk.ps1'", True),
    ("powershell.exe -File .\\invoke-claude-chunk.ps1", True),
    ("& 'D:\\repo folder\\invoke-codex-chunk.ps1' -BundlePath bundle.txt", True),
    ("./invoke-claude-chunk.ps1 -BundlePath bundle.txt", True),
    ('pwsh -NoProfile -Command "& \'./invoke-codex-chunk.ps1\' -BundlePath bundle.txt"', True),
    ("echo done; codex exec -m gpt-6.1-sol prompt", True),
    ("cat <<'EOF' > example.sh\ncodex exec example\nEOF\ncodex exec -m gpt-6.1-sol prompt", True),
    ("pwsh -File invoke-codex-chunk.ps1 -Prompt 'codex exec -m gpt-6.1-sol'", True),
    ("pwsh -File invoke-codex-chunk.ps1 -Preflight; codex exec -m gpt-6.1-sol prompt", True),
])
def test_real_commands_count_once_with_their_model_status(command: str, explicit: bool) -> None:
    pending: list[tuple[str, str] | None] = [("routine-coding", "medium")]
    buckets: dict[str, dict] = {}
    row = {"timestamp": "2026-10-01T16:00:00Z", "message": {
        "role": "assistant", "content": [{"type": "tool_use", "name": "Bash",
                                            "input": {"command": command}}]}}
    cu.tally_routing_message(row, pending, buckets, {"routine-coding": "coder"})
    bucket = buckets["2026-10-01"]
    assert (bucket["delegations"], bucket["routed"], bucket["unrouted"]) == (1, int(explicit), int(not explicit))
    assert pending == []
