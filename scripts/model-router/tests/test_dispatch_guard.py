"""Real captured Claude shapes and shell-position regressions, no live CLIs."""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

for key in ("DT_JOB_ID", "DT_JOB_DIR", "DT_BUILD_COORDINATOR_ID"):
    os.environ.pop(key, None)
os.environ.pop("ROUTER_GUARD_OFF", None)
ROOT = Path(__file__).resolve().parents[3]
GUARD = ROOT / "scripts/model-router/dispatch-guard.py"
spec = importlib.util.spec_from_file_location("dispatch_guard", GUARD)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def decision(payload: object) -> dict | None:
    return guard.guard_decision(payload)


def assert_deny(payload: object) -> None:
    result = decision(payload)["hookSpecificOutput"]
    assert result["hookEventName"] == "PreToolUse"
    assert result["permissionDecision"] == "deny"
    reason = result["permissionDecisionReason"]
    assert reason.startswith("ROUTER_GUARD_DENY:")
    assert "-Category routine-coding" in reason
    assert "dispatch.ps1\" -ProjectPath" in reason
    for flag in ("-PromptPath", "-OutputPath", "-SelectionReason"):
        assert flag in reason


@pytest.mark.parametrize("fixture", ["general-purpose", "untyped", "fork", "Explore", "sonnet", "frontier-alias"])
def test_captured_shapes(fixture: str) -> None:
    payloads = json.loads((Path(__file__).parent / "fixtures/hook-payloads" / (fixture + ".json")).read_text(encoding="utf-8-sig"))
    for payload in payloads:
        assert_deny(payload)


@pytest.mark.parametrize("tool", ["Agent", "Task"])
@pytest.mark.parametrize("inputs", [
    {"model": "opus", "prompt": "Write code"},
    {"model": "opus", "prompt": "Extract data"},
    {"subagent_type": "fork"}, {"subagent_type": "Explore", "model": "haiku"},
    {"subagent_type": "general-purpose"}, {}, {"model": "sonnet"},
    {"model": "frontier"}, {"agent_id": "existing"}, {"subagent_type": "custom"},
])
def test_all_native_forms(tool: str, inputs: dict) -> None:
    assert_deny({"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": inputs})


@pytest.mark.parametrize("command", [
    "claude -p hi", "& claude -p hi", "claude.cmd -p hi", "claude.exe --print hi",
    "codex exec hi", "& codex.cmd exec hi", 'pwsh -Command "claude -p hi"',
    'echo done; claude -p hi', 'C:/tools/claude.cmd -p hi',
])
@pytest.mark.parametrize("tool", ["Bash", "PowerShell"])
def test_shell_launch_denied(command: str, tool: str) -> None:
    assert_deny({"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": {"command": command}})


@pytest.mark.parametrize("command", [
    'pwsh -File invoke-claude-chunk.ps1 -Category routine-coding',
    'pwsh -File dispatch.ps1 -Category routine-coding', 'echo "claude -p hi"',
    'rg "codex exec" README.md', '# claude -p hi', 'printf "%s" claude -p',
    "cat <<'EOF'\nclaude -p hi\nEOF\n",
    "$text = @'\ncodex exec hi\n'@\nSet-Content file $text",
    'git commit -m @"\ncodex exec hi\n"@',
])
def test_shell_data_allowed(command: str) -> None:
    assert decision({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": command}}) is None


@pytest.mark.parametrize("payload", [None, [], {}, {"tool_input": []},
    {"hook_event_name": "PostToolUse", "tool_name": "Agent", "tool_input": {}},
    {"hook_event_name": "PreToolUse", "tool_name": "spawn_agent", "tool_input": {}},
    {"hook_event_name": "PreToolUse", "tool_name": "Workflow", "tool_input": {}},
    {"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": 2}},
])
def test_unknown_malformed_and_unproved_surfaces_allowed(payload: object) -> None:
    assert decision(payload) is None


def test_off_switch(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ROUTER_GUARD_OFF", "1")
    assert decision({"hook_event_name": "PreToolUse", "tool_name": "Agent", "tool_input": {}}) is None


@pytest.mark.parametrize("raw", ["broken", "null", '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{}}'])
def test_entrypoint(raw: str) -> None:
    run = subprocess.run([sys.executable, str(GUARD)], input=raw, capture_output=True, text=True, timeout=15)
    assert run.returncode == 0
    assert not run.stderr
    if raw.startswith('{'):
        assert json.loads(run.stdout)["hookSpecificOutput"]["permissionDecision"] == "deny"
    else:
        assert not run.stdout


def test_dependency_error_fails_open(tmp_path: Path) -> None:
    # A relocated guard cannot import the shared lexer, so the hook must allow.
    target = tmp_path / 'scripts/model-router/dispatch-guard.py'
    target.parent.mkdir(parents=True)
    target.write_bytes(GUARD.read_bytes())
    payload = {"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "claude -p hi"}}
    run = subprocess.run([sys.executable, str(target)], input=json.dumps(payload), capture_output=True, text=True, timeout=15)
    assert run.returncode == 0 and not run.stdout and not run.stderr


@pytest.mark.parametrize("command", [
    'timeout 600 claude -p', 'timeout 600s codex exec',
    'timeout -k 5 600 claude -p', 'timeout --kill-after=5 600 claude -p',
    'timeout -s TERM 600 codex exec',
    '$out = claude -p "hi"', '$r = codex exec "hi"', '$out=claude -p "hi"',
    'do claude -p hi', 'then codex exec hi', 'else claude -p hi', '! claude -p hi',
])
@pytest.mark.parametrize("tool", ["Bash", "PowerShell"])
def test_prefixed_literal_launch_denied(command: str, tool: str) -> None:
    assert_deny({"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": {"command": command}})


@pytest.mark.parametrize("command", [
    '$out = "claude -p"',
    'timeout 600 pwsh -File invoke-claude-chunk.ps1 -Category routine-coding',
    '$out=pwsh -File invoke-codex-chunk.ps1 -Category routine-coding',
    'do pwsh -File invoke-claude-chunk.ps1 -Category routine-coding',
])
def test_prefixed_wrapper_and_quoted_mention_allowed(command: str) -> None:
    assert decision({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": command}}) is None


def test_unterminated_double_quote_with_backticks_finishes_promptly() -> None:
    start = time.perf_counter()
    assert decision({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                     "tool_input": {"command": 'echo "' + '`' * 200}}) is None
    assert time.perf_counter() - start < 1


@pytest.mark.parametrize("quoted", ['"before `echo hi` after"', '"before `"hi`" after"'])
def test_double_quoted_token_end_preserved(quoted: str) -> None:
    spec = importlib.util.spec_from_file_location("usage_quote_test", ROOT / "skills/dt-build/scripts/collect-usage.py")
    lexer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lexer)
    command = 'echo ' + quoted + '; claude -p hi'
    tokens = list(lexer.COMMAND_TOKEN_RE.finditer(command))
    assert tokens[1].group() == quoted
    assert tokens[1].end() == len('echo ' + quoted)
    assert_deny({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": command}})


@pytest.mark.parametrize("tool", ["Agent", "Task"])
@pytest.mark.parametrize("agent_type", ["Explore", "Plan"])
def test_read_only_agent_suggestion(tool: str, agent_type: str) -> None:
    payload = {"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": {"subagent_type": agent_type}}
    assert_deny(payload)
    reason = decision(payload)["hookSpecificOutput"]["permissionDecisionReason"]
    assert " -ReadOnly" in reason
    assert '-OutputPath "_dispatch/task-output.md"' in reason


def test_isolated_interpreter_imports_shared_lexer() -> None:
    payload = {"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "timeout 600 claude -p hi"}}
    run = subprocess.run(["C:/Users/Danny/AppData/Local/Python/pythoncore-3.14-64/python.exe", "-I", str(GUARD)],
                         input=json.dumps(payload), capture_output=True, text=True, timeout=15)
    assert run.returncode == 0 and not run.stderr
    assert json.loads(run.stdout)["hookSpecificOutput"]["permissionDecision"] == "deny"
