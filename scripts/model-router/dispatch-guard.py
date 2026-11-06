"""Fail-open Claude PreToolUse guard; no state, roster or authorization reads."""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import uuid
from pathlib import Path


def guard_decision(payload: object) -> dict | None:
    """Return a native deny only for a recognized Claude tool payload."""
    if os.environ.get("ROUTER_GUARD_OFF") or not isinstance(payload, dict):
        return None
    if payload.get("hook_event_name") != "PreToolUse":
        return None
    tool = payload.get("tool_name")
    inputs = payload.get("tool_input")
    if not isinstance(inputs, dict):
        return None
    if tool not in ("Agent", "Task"):
        if tool not in ("Bash", "PowerShell") or not isinstance(inputs.get("command"), str):
            return None
        source = Path(__file__).resolve().parents[2] / "skills/dt-build/scripts/collect-usage.py"
        spec = importlib.util.spec_from_file_location("router_usage_lexer", source)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        calls = module.executed_dispatch_details(inputs["command"])
        if not any(not call["wrapper"] for call in calls):
            return None
    # A suggested category is a retry starting point, never inferred approval.
    # Single-quoted PowerShell arguments preserve literal path characters.
    project = payload.get("cwd")
    if not isinstance(project, str) or not project or any(c in project for c in "\r\n\x00"):
        project = "."
    quoted_project = "'" + project.replace("'", "''") + "'"
    read_only = tool in ("Agent", "Task") and inputs.get("subagent_type") in ("Explore", "Plan")
    # The read-only check skips only the output's own folder, so a read-only report needs a subfolder.
    # Ad hoc task identity comes from the prompt path, so each denial gets its own names; a retry reuses them.
    task = "task-" + uuid.uuid4().hex[:8]
    output = f"_dispatch/{task}-output.md" if read_only else f"{task}-output.md"
    command = (
        'pwsh -NoProfile -File "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills/'
        'scripts/model-router/dispatch.ps1" -ProjectPath ' + quoted_project +
        ' -Category routine-coding -PromptPath "' + task + '-prompt.md" -OutputPath "' + output + '"'
        ' -SelectionReason "Route native delegation through the category resolver" -AdHoc -AllowOutputInProject -Live'
    )
    if read_only:
        command += " -ReadOnly"
    reason = f"ROUTER_GUARD_DENY: category routine-coding; save the task in {task}-prompt.md, then run: " + command
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                   "permissionDecisionReason": reason}}


def main() -> None:
    """Errors, including unavailable lexer dependencies, leave the tool unchanged."""
    try:
        decision = guard_decision(json.load(sys.stdin))
        if decision:
            print(json.dumps(decision))
    except Exception:
        pass


if __name__ == "__main__":
    main()
