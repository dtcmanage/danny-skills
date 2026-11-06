# Dispatch guard: staged release

Status: staged, inactive. Framework state: provisional. No global settings or
Codex configuration were changed by this build. Fixture tests establish guard
decisions; they do not establish production hook coverage. Coordinator live
`-Mode guard` evidence is required before activation claims.

## Activation order

Danny applies or approves these release actions, in order:

1. Merge the reviewed build to main. Confirm both `dispatch.ps1` and
   `dispatch-guard.py` exist under the primary repo path below.
2. Apply the staged out-of-repo edits in `dispatch-guard-staged-edits.md` (M06).
   Review M06's collateral inventory before enabling the hook.
3. Danny pastes the separate PreToolUse entry into `D:/Claude/settings.json`.
   Session edits of that live settings file are outside this build's authority.
4. Re-trust a Codex hook only if a future probe proves a Codex guard. This build
   measures Codex only and supplies no Codex deny or configuration change.

Only after these release actions does the word **enforced** apply, and then only
to surfaces whose real hook firing and denial were measured. Over the first full
week after activation, inspect routed share, native attempts denied, native calls
executed, direct launches, and delegated productive work per category and vendor.
Zero violations with low routed share does not establish success.

## Install and rollback

The staged entry is independent of the read-guard entry; `ensure_hook.py` must
continue to repair only the read guard. The matcher deliberately excludes Workflow.

```json
{
  "matcher": "^(Agent|Task|Bash|PowerShell)$",
  "hooks": [{
    "type": "command",
    "command": "\"C:/Users/Danny/AppData/Local/Python/pythoncore-3.14-64/python.exe\" -I \"D:/Claude/_Claude-Workspace/Skill Creation/danny-skills/scripts/model-router/dispatch-guard.py\"",
    "timeout": 10
  }]
}
```

Exercise the installer against a temporary settings copy, never the live file in
a test. The path in the installed command always names the post-merge primary
repo, even when this installer runs from a worktree.

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills"
pwsh -NoProfile -File "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills/scripts/model-router/guard-settings.ps1" -SettingsPath "$env:TEMP/router-settings-copy.json" -Action install
```

Use `-Action status` with the same path to inspect the entry and backup. Repeated
install does not append entries or overwrite the backup. `-Action rollback`
restores the original bytes, including BOM and line endings, and consumes the
`.router-guard.backup` sidecar; repeated rollback is harmless. Rollback restores
the entire original file, so preserve any later unrelated settings edits before
using it. Keep the sidecar until the staged exercise or release is accepted.

For emergency relief, set `ROUTER_GUARD_OFF=1` before starting a session, or remove
only this hook entry. The guard fails open on malformed input and runtime errors.
It reads no roster and uses no ticket or authorization store. Every deny begins
`ROUTER_GUARD_DENY:`, suggests category `routine-coding`, and gives an exact
`dispatch.ps1` invocation. The operator writes the task prompt first and chooses
the appropriate category if the suggested starting point does not match the task.

## Measured surfaces and retained limitations

| Surface | Rule after activation | Measured label at build time |
| --- | --- | --- |
| Claude Agent/Task, all types and model values, parent, subagent, headless | Deny each form that reaches the hook, including agent_id, fork, Explore, custom and omitted fields | Real M02 fixtures captured for general-purpose, untyped, fork, Explore, Sonnet and frontier alias; guard fixture decisions verified. Production guard deny awaits coordinator probe. Context inheritance beyond measured cases remains unverified. |
| Claude Bash/PowerShell literal `claude -p` or `codex exec` in command position | Deny best effort using the collector's shared lexer; mentions, arguments and file-writing bodies pass | Offline literal, call-operator, `.cmd`, heredoc and here-string coverage. Real guard worker-shell deny awaits coordinator probe. Deliberate evasion is out of scope. |
| Claude Workflow | Allow entry; deny an inner Agent/Task only if it reaches the hook | Unsupported: M02 entry fired, but no inner Agent/Task reached the hook. Collector counts Workflow later. |
| Codex shell and spawn_agent | No deny without a captured payload proving coverage | Measured only, not prevented; no Codex configuration or hook trust changes. Collector counts from existing rollouts. |
| Delegation outside tool calls, hosted tools, sessions without hook | No prevention | Unsupported and unmeasured. |
| Outside-pack bundled or plugin commands that call Agent | Same deny as any Agent call reaching the hook | Affected in principle; M06 inventory below identifies callers before release. |

Launches hidden behind other wrappers (`env`, `xargs`, `nohup`, a script file) are not seen by the shell rule, and a pasted install has no automatic rollback (remove the hook entry by hand).

Scripts that launch children internally are unaffected: their contents are not a
shell-tool command. The lexer is a bounded literal recognizer, not a shell
evaluator. Runtime failures allow calls; missing hook installation allows calls.
A read-guard allow through unattended exemptions does not prove a dispatch deny.
Execution success and output presence do not prove independent task acceptance.

## Coordinator guard probe

Run serially as an authorized live probe job; workers and tests never invoke it
with `-Live`:

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills"
pwsh -NoProfile -File "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills/scripts/model-router/tests/probe-native-hooks.ps1" -Live -Mode guard -OutDir "D:/Claude/_Claude-Workspace/Skill Creation/model-router/dispatch-repair/probes/m05-guard"
```

The bounded haiku sessions attempt an opus Agent, a fork, and a literal shell
launch inside a headless worker with no Agent tool. Temporary settings call the
real guard and record its deny prefix. Each session then attempts the supplied
dispatch command through a shell tool. The probe requires a matching real deny,
a subsequent allowed dispatch call, output presence, successful dispatch execution
in its provenance, and a successful outer CLI exit. It records these separately,
preserves an unknown actual model, and leaves independent acceptance null. It
does not strip timestamps. Raw prompts and raw guard reasons containing paths
are not persisted. The temporary hooks and settings are removed afterward.

## M06 collateral inventory (reserved)

Pending M06: list every outside-pack Agent caller, its measured or expected
effect, and its release disposition. Do not activate while this inventory and
the staged out-of-repo edits remain pending.
