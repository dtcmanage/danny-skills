# Dispatch guard: staged release

Status: staged, inactive. Framework state: provisional. No global settings or
Codex configuration were changed by this build. Fixture tests establish guard
decisions. The live `-Mode guard` probe denied all three forms (`opus`, `fork`,
`worker-shell`) and each retry through `dispatch.ps1` succeeded, but its hook is
a pwsh wrapper around bare `python`, not the installed form. The installed form
is unproved until the live check in step 4.

## Activation order

Danny applies or approves these release actions, in order:

1. Merge the reviewed build to main. Confirm both `dispatch.ps1` and
   `dispatch-guard.py` exist under the primary repo path below.
2. Apply the staged out-of-repo edits in `dispatch-guard-staged-edits.md` (M06).
   Review M06's collateral inventory before enabling the hook.
3. Danny pastes the separate PreToolUse entry into `D:/Claude/settings.json`.
   Session edits of that live settings file are outside this build's authority.
4. Live check of the installed hook: start a fresh Claude session and make one
   native Agent call and one `claude -p --version` shell attempt. Expect each to
   receive a deny starting `ROUTER_GUARD_DENY`. The guard is
   fail-open, so if the call runs instead the hook is not working: remove the
   entry and investigate, do not count it as enforced.
5. Re-trust a Codex hook only if a future probe proves a Codex guard. This build
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
| Claude Agent/Task, all types and model values, parent, subagent, headless | Deny each form that reaches the hook, including agent_id, fork, Explore, custom and omitted fields | Real M02 fixtures captured for general-purpose, untyped, fork, Explore, Sonnet and frontier alias; guard fixture decisions verified. Live guard probe denied the `opus` and `fork` forms; installed form checked in activation step 4. Context inheritance beyond measured cases remains unverified. |
| Claude Bash/PowerShell literal `claude -p` or `codex exec` in command position | Deny best effort using the collector's shared lexer; mentions, arguments and file-writing bodies pass | Offline literal, call-operator, `.cmd`, heredoc and here-string coverage. Live guard probe denied a real worker's `claude -p` shell launch; installed form checked in activation step 4. Deliberate evasion is out of scope. |
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

## M06 collateral inventory

Read-only inventory, 2026-11-06 at 12:46 AM ET, Claude Code 2.1.319. Effects are
expected from the text, not measured: nothing here was run. Plugin paths are under
`D:/Claude/plugins/cache/claude-plugins-official/`. There is no special bypass for
any of them: once the hook is installed, each Agent call below is denied like any
other, and the deny reason names `dispatch.ps1`.

| Caller | Path | How it calls Agent | Expected effect | Disposition |
| :-- | :-- | :-- | :-- | :-- |
| code-review plugin command (enabled) | `code-review/1.0.1/commands/code-review.md` | Prompt text tells the session to launch haiku, sonnet and opus agents, in parallel at steps 4-5 | Cannot run its review | Use dt-review, or `dispatch.ps1 -Category code-review`, for reviews. Five older cached copies of this command are not the installed version. |
| skill-creator plugin skill (enabled) | `skill-creator/1aa4a4b10e6c/skills/skill-creator/SKILL.md` lines 60, 171, 225 | Prompt text tells the session to spawn test-case and grader subagents | Its eval loop cannot run | Accept: danny-skills is not routed through this harness. |
| code-simplifier plugin agent (enabled) | `code-simplifier/1.0.0/agents/code-simplifier.md` | An agent definition, reachable only through an Agent call | Cannot be started | Accept. |
| claude-code-setup plugin skill (enabled) | `claude-code-setup/1.0.0/skills/claude-automation-recommender/` | Recommends subagents as output; no launch instruction found | None expected | Accept. |
| claude-md-management, commit-commands, frontend-design (enabled); zoharbabin message-timestamps (enabled) | Their install folders | No launch instruction found | None expected | Accept. |
| security-guidance, ralph-loop (disabled) | Their install folders | security-guidance mentions subagents in its own hook code; ralph-loop has no launch instruction | None while disabled | Recheck if enabled. |
| `/batch` (bundled) | `C:/Users/Danny/.local/bin/claude.exe`, string scan | Its prompt launches research subagents and background worker agents | Cannot run | Accept; use dt-build for large changes. |
| `/fork`, `/subtask` (bundled) | Same binary | Spawn a background agent or a subagent with the full conversation. A second `/fork` entry copies the conversation into a new session | Spawning forms denied if they pass the hook; not measured beyond the M02 fork payload | Accept. |
| Plan mode's exploration prompt (bundled) | Same binary | Tells the session to launch Explore agents in parallel | Each launch denied; plan mode continues with direct reads | Accept. |
| An unattributed prompt listing `Task` in its allowed tools, and one saying "Use the Task tool to spawn parallel agents" (bundled) | Same binary | Prompt text; the scan could not tie these to a command name. `security-review` is one unconfirmed candidate | Those launches denied | Accept; reports as a denied call if met. |
| deep-research workflow (bundled) | Same binary | A Workflow that fans out agents | Workflow entry is allowed; M02 saw no inner Agent reach the hook, so it stays unsupported, not enforced | Measured by the collector's Workflow count. |
| `/ultrareview` (bundled) | Same binary | Runs in a cloud session | Local hook does not apply | None. |

The scan found no bundled `/simplify`, `/review` or `/code-review` command by name in
this build; a later Claude Code update can add callers, and a denied call says so
when it happens.

**Capability lost.** A native Agent can use MCP servers and inherit the live
conversation. Dispatch workers cannot. Ad hoc Claude workers keep `WebSearch` and
`WebFetch`, and context passes in the prompt file, but work that needs an MCP server
or the live conversation stays in the parent session, with no worker option.

**To reverse it.** Set `ROUTER_GUARD_OFF=1` before a session starts, for that
session, or remove the hook entry from `D:/Claude/settings.json`, for all of them.
Setting the variable inside a running session does not help.

Staged out-of-repo text, the repo item checklist and every grep disposition are in
`dispatch-guard-staged-edits.md`.

## Live smoke and retained limitations

The coordinator runs the smoke once, serially, as an authorized live job. Workers
and tests never pass `-Live`.

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills"
pwsh -NoProfile -File "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills/scripts/model-router/tests/live-smoke.ps1" -Live -OutDir "D:/Claude/_Claude-Workspace/Skill Creation/model-router/dispatch-repair/.dt-build/router-dispatch-repair-20261105/live-smoke"
```

Each vendor gets one tiny no-tools prompt through the bench transport and one
through `dispatch.ps1`, four non-frontier calls in all, because the two paths cannot
share a call. The dispatch prompt asks for a date-shaped string, and the saved answer
must match it byte for byte. `live-smoke-result.json` records the saved status per
vendor and path, with each event as `seen` or `not-exercised`. A non-ok saved result
exits nonzero, whatever the child process exit was. Normal quota guards apply, and a
blocked vendor makes no call. The run works on a copy of router state inside the
audit folder, regenerates one dry report there, refuses every alert request and writes
no live roster. It starts no full benchmark and makes no frontier call.

`tie-follow-up.md` appears only when both vendors and the report pass. It approves
nothing, and old tie approvals stay invalid until fresh evidence exists and Danny
approves it. A pass shows execution only, not independent acceptance.

Limitations this release keeps:

- The collector does not interpret shells: the 107 launches holding commands in
  shell variables and 17 other unrecognized forms remain outside its coverage.
- Each denied delegation leaves its individual task files in the project root.
- The guard probe hook differs from the installed form until the post-activation
  check in step 4 proves the installed form.
- The Codex host declares `exec` and `wait` as disabled tools on every turn, so "no
  tools" on that lane means none usable, not none declared.
- Workflow inner agents are unsupported. The Workflow entry fires the hook, but no
  inner Agent or Task call was seen reaching it.
- The Codex guard is measured only. Nothing denies a Codex shell or `spawn_agent` call.
- The schema methods `thread/prediction/updated` and `thread/readState/changed` stay
  rejected until a captured payload justifies accepting them.
- The ten retained prefix failures all come from one run on 2026-10-07. They remain
  on record and are not evidence of a current failure.
