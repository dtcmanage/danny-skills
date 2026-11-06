"""Read-only installed-guard smoke, based on M04 verifier-a1 guard-smoke.py."""
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest


@pytest.mark.parametrize(
    ("name", "codex", "settings", "denied"),
    [
        ("claude worker outside dt-job", False, {"CLAUDE_CODE_SESSION_ATTENDED": "0"}, False),
        ("attended Claude", False, {"CLAUDE_CODE_SESSION_ATTENDED": "1"}, True),
        ("codex exec outside dt-job", True, {"READ_GUARD_TEST_CODEX_ARGS": "codex.exe --ask-for-approval never exec --ignore-user-config --model x -"}, False),
        ("codex exec with attended parent", True, {"CLAUDE_CODE_SESSION_ATTENDED": "1", "READ_GUARD_TEST_CODEX_ARGS": "codex.exe --ask-for-approval never exec -"}, False),
        ("interactive codex resume", True, {"READ_GUARD_TEST_CODEX_ARGS": "codex.exe resume"}, True),
    ],
)
def test_installed_guard(name: str, codex: bool, settings: dict[str, str], denied: bool, tmp_path: Path) -> None:
    guard = Path("D:/Claude/_system-tools/read-guard/read_guard.py")
    if not guard.is_file():
        reason = f"installed read guard absent: {guard}; {name} not exercised"
        print(reason)
        pytest.skip(reason)
    big = tmp_path / "big.txt"
    big.write_text("x\n" * 30000, encoding="utf-8")
    env = {key: value for key, value in os.environ.items() if key not in (
        "DT_JOB_ID", "DT_JOB_DIR", "DT_BUILD_COORDINATOR_ID", "READ_GUARD_OFF",
        "CLAUDE_CODE_SESSION_ATTENDED", "READ_GUARD_TEST_CODEX_ARGS",
    )}
    env.update(settings)
    env["READ_GUARD_STATE_DIR"] = str(tmp_path / "guard-state")
    payload = {"session_id": name, "hook_event_name": "PreToolUse", "tool_name": "Read",
               "tool_input": {"file_path": str(big)}, "cwd": str(tmp_path),
               "transcript_path": str(tmp_path / "transcript.jsonl")}
    if codex:
        payload.update(turn_id="t1", tool_name="Bash", tool_input={"command": "cat " + str(big)})
    result = subprocess.run([sys.executable, "-B", str(guard)], input=json.dumps(payload),
                            capture_output=True, text=True, env=env, timeout=60)
    assert result.returncode == 0, (name, result.stderr)
    assert ("deny" in result.stdout) == denied, (name, result.stdout, result.stderr)
