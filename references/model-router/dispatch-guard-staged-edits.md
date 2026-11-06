# Dispatch guard: staged out-of-repo edits

Status: staged, not applied. These edits are release step 2 in
`dispatch-guard-release.md`. The guard is not active. Apply them after the build
merges and before the settings entry is pasted. Text below says "denied" because
it describes the state after release; do not apply it without continuing to the
hook step, and do not apply the `model-routing.md` guard paragraph until the
coordinator's guard probe has passed.

Each edit replaces the one occurrence of its find text. Keep the target file's
line endings. `test-dispatch-migration.ps1` checks that each find text, or its
replacement once applied, is in the live file.

M04 named no read-guard change: its smoke
(`dispatch-repair/.dt-build/router-dispatch-repair-20261105/probes/read-guard-smoke/smoke-result.md`)
showed workers started outside `dt-job` already read past the limit. The only
read-guard edits below are the worker guidance text.

## model-routing.md

### Edit: D:/Claude/_Claude-Workspace/00_Resources/model-routing.md

~~~~find
Read this before the first time a session hands work to another model: an Agent subagent, a `codex exec` call, or one of the chunk wrappers. It applies to every session, not only dt-build.
~~~~

~~~~replace
Read this before the first time a session hands work to another model. Generic work goes through `dispatch.ps1`; fixed lanes keep their own scripts (step 3). It applies to every session, not only dt-build.
~~~~

### Edit: D:/Claude/_Claude-Workspace/00_Resources/model-routing.md

~~~~find
3. **Dispatch on the answer.** `vendor = claude`: set the Agent tool's `model` to the returned `agent_alias` (`haiku`, `sonnet`, or `opus`). When the resolved `effort` differs from the session's own effort, dispatch through `skills\dt-build\scripts\invoke-claude-chunk.ps1 -Category <category> -Effort <effort>` instead of the Agent tool so `--effort` is pinned. `vendor = codex`: call `skills\dt-build\scripts\invoke-codex-chunk.ps1 -Category <category> -Effort <effort>` (the resolver's `effort` field; both wrappers refuse a substantive call without `-Effort`, 2026-10-13) or `codex exec -m <model> -c model_reasoning_effort=<effort>`. For one-off work outside a dt-build run, prefer either wrapper with `-AdHoc -ProjectPath <dir> -PromptPath <file> -OutputPath <file> -SelectionReason "<one line>"` over raw `codex exec`: it skips dt-build's prompt and report envelope but keeps routing, usage accounting and error classification. Start it as a `dt-job` job (any folder can be its `-RunFolder`) to get its 10-minute check-ins and stall reports. `status = wait`: the result carries `resume_after_et`; tell Danny that line and stop; never fall back to a weaker model or to the session model.
~~~~

~~~~replace
3. **Dispatch through the command.** Put the task and its context in a prompt file, then run:

   ```powershell
   cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
   pwsh -NoProfile -File scripts\model-router\dispatch.ps1 -ProjectPath "<dir>" -Category <category> -PromptPath "<file>" -OutputPath "<file outside the project>" -SelectionReason "<one line>" -AdHoc -Live
   ```

   The command picks the lane and effort from the roster and records the evidence. Add `-ReadOnly` for a worker that must not change files and `-Difficulty hard -DifficultyReason "<one line>"` when hard is earned. Start long work, or several pieces at once, as `dt-job` jobs (any folder can be `-RunFolder`) to get 10-minute check-ins and stall reports. On `ROUTER_WAIT`, tell Danny the resume time and stop; never fall back to a weaker model or to the session model. The command handles quota fallback and diagnosis through its wrappers, so steps 6 and 7 apply only to a script calling the resolver directly.

   Fixed lanes keep their own scripts: dt-review invokers, `request-frontier.ps1`, dt-build's managed attempts through its wrappers, and dt-image-gen.

   Worker capabilities: ad hoc Claude workers have `WebSearch` and `WebFetch`. Pass context in the prompt file, because a worker does not see this conversation. **Work that needs an MCP server or the live conversation stays in the parent session;** no worker can do it.
~~~~

### Edit: D:/Claude/_Claude-Workspace/00_Resources/model-routing.md

~~~~find
4. **Never inherit.** A bare Agent call, or one whose `model` is the session's own model "because it is already running," is the failure this file exists to prevent. Fable and GPT-6 Astra run
~~~~

~~~~replace
4. **Never inherit.** Do not delegate with the Agent or Task tool, or a literal `claude -p` or `codex exec`: an inherited or hand-picked model is the failure this file exists to prevent. To use a named model on a task, pass `-Model <model>` to the command; its selection reason is recorded as an override. Fable and GPT-6 Astra run
~~~~

### Edit: D:/Claude/_Claude-Workspace/00_Resources/model-routing.md

~~~~find
The weekly routing-compliance line measures routed delegations divided by all observed delegations in Claude session transcripts, with workstation counts and category/job distributions. It is advisory measurement, not a dispatch gate; it does not claim coverage of Codex-host session delegations.
~~~~

~~~~replace
The dispatch guard (`scripts\model-router\dispatch-guard.py`, its own PreToolUse entry in `D:\Claude\settings.json`) enforces this rule as follows:

| Surface | Rule | Status |
| :-- | :-- | :-- |
| Claude `Agent`/`Task`, every type and model, in parent, subagent and headless contexts | Deny; the reason gives the exact `dispatch.ps1` command | Enforced, for each form a probe showed firing the hook |
| Claude Bash/PowerShell literal `claude -p` or `codex exec` at command position | Deny | Enforced, best effort; deliberate evasion is out of scope |
| Claude `Workflow` | No deny | Unsupported: no inner Agent call reached the hook when probed |
| Codex shell and `spawn_agent` | No deny | Measured, not prevented |
| Delegation outside a tool call, hosted tools, sessions without the hook | None | Unsupported and unmeasured |
| Commands and skills outside the pack that call Agent, bundled or plugin | Denied like any other call | Inventoried in `dispatch-guard-release.md`; set `ROUTER_GUARD_OFF=1` before starting a session, or remove the hook entry, to reverse it |

The weekly routing-compliance line measures routed delegations divided by all observed delegations in Claude session transcripts, with workstation counts and category/job distributions. Zero violations with low routed share does not read as success.
~~~~

### Edit: D:/Claude/_Claude-Workspace/00_Resources/model-routing.md

~~~~find
`grep`, `jq`, a ten-line Python script, or the Explore agent on `haiku` beats any model for collection.
~~~~

~~~~replace
`grep`, `jq`, or a ten-line Python script beats any model for collection.
~~~~

### Edit: D:/Claude/_Claude-Workspace/00_Resources/model-routing.md

~~~~find
| Find where a setting is configured across a repo | `mechanical` (Explore agent) | Haiku |
~~~~

~~~~replace
| Find where a setting is configured across a repo | No model: `grep`. If a search needs judgment, `mechanical` | GPT-6 Luna or Haiku |
~~~~

## read-delegation.md

### Edit: D:/Claude/_Claude-Workspace/00_Resources/read-delegation.md

~~~~find
Codex has no Agent tool, so a refused Codex read is pointed at `model-routing.md` step 3: a chunk wrapper with `-AdHoc`.
~~~~

~~~~replace
A refused read on either host is pointed at `model-routing.md` step 3: `dispatch.ps1` with `-AdHoc`.
~~~~

### Edit: D:/Claude/_Claude-Workspace/00_Resources/read-delegation.md

~~~~find
1. Pick the model through the model router (`model-routing.md`). Pulling facts out
~~~~

~~~~replace
1. Name the category (`model-routing.md`). Pulling facts out
~~~~

### Edit: D:/Claude/_Claude-Workspace/00_Resources/read-delegation.md

~~~~find
2. Dispatch an Agent with that model. Tell it the file, the question this task needs answered, and where to write the extract (a scratch or workstation working folder).
~~~~

~~~~replace
2. Run `dispatch.ps1 -AdHoc` with that category (the command in `model-routing.md` step 3). The prompt file names the file, the question this task needs answered, and where to write the extract (a scratch or workstation working folder).
~~~~

## read_guard.py

### Edit: D:/Claude/_system-tools/read-guard/read_guard.py

~~~~find
    "Send it to a worker: dispatch an Agent (model from the model router; extraction is `mechanical`) told to "
~~~~

~~~~replace
    "Send it to a worker: run dispatch.ps1 -AdHoc per _Claude-Workspace/00_Resources/model-routing.md step 3 (extraction is `mechanical`), told to "
~~~~

### Edit: D:/Claude/_system-tools/read-guard/read_guard.py

~~~~find
# Codex has no Agent tool: its workers are the chunk wrappers in ad-hoc mode.
~~~~

~~~~replace
# Codex reads are refused as shell commands, so its how-to names printed ranges; workers use the same dispatch command.
~~~~

### Edit: D:/Claude/_system-tools/read-guard/read_guard.py

~~~~find
    "Send it to a worker: follow _Claude-Workspace/00_Resources/model-routing.md step 3 and run a chunk wrapper "
    "with -AdHoc (invoke-claude-chunk.ps1 or invoke-codex-chunk.ps1, model from the router; extraction is "
~~~~

~~~~replace
    "Send it to a worker: follow _Claude-Workspace/00_Resources/model-routing.md step 3 and run dispatch.ps1 "
    "with -AdHoc (extraction is "
~~~~

### Edit: D:/Claude/_system-tools/read-guard/read_guard.py

~~~~find
                "reading to a subagent or a chunk wrapper -AdHoc, see read-delegation.md")
~~~~

~~~~replace
                "reading to a worker with dispatch.ps1 -AdHoc, see read-delegation.md")
~~~~

### Edit: D:/Claude/_system-tools/read-guard/test_read_guard.py

~~~~find
"Codex is pointed at the chunk wrappers, not the Agent tool"
~~~~

~~~~replace
"Codex is pointed at dispatch.ps1 with -AdHoc"
~~~~

## Root CLAUDE.md

### Edit: D:/Claude/CLAUDE.md

~~~~find
About to delegate work to another model in any session — Agent subagents, `codex exec`, chunk wrappers.
~~~~

~~~~replace
About to delegate work to another model in any session: `dispatch.ps1`, dt-job workers, or a fixed-lane script.
~~~~

## codex-cli-usage.md

### Edit: D:/Claude/_Claude-Workspace/00_Resources/codex-cli-usage.md

~~~~find
Read this before invoking `codex exec` from any skill or ad-hoc bash call. Source:
~~~~

~~~~replace
Read this before configuring Codex or maintaining a script that launches it. Sessions do not run `codex exec` themselves: generic work goes through `dispatch.ps1` (`model-routing.md`). Source:
~~~~

### Edit: D:/Claude/_Claude-Workspace/00_Resources/codex-cli-usage.md

~~~~find
exits with status code. This is the only mode Claude uses.
~~~~

~~~~replace
exits with status code. Only the wrappers and fixed-lane scripts use this mode.
~~~~

### Edit: D:/Claude/_Claude-Workspace/00_Resources/codex-cli-usage.md

~~~~find
## Headless invocation pattern
~~~~

~~~~replace
## Headless invocation pattern

Everything from here to "Canonical Claude context bridge" documents what the wrappers and fixed-lane scripts run, for anyone maintaining them. A session never runs these commands through a shell tool: a literal `codex exec` at command position is denied. Use `dispatch.ps1`.
~~~~

## Stale delegation guidance the greps found beyond the design's list

### Edit: D:/Claude/_Claude-Workspace/00_Resources/build-process.md

~~~~find
When a subagent reports it is waiting on a background run
~~~~

~~~~replace
When a worker reports it is waiting on a background run
~~~~

### Edit: D:/Claude/_Claude-Workspace/00_Resources/build-process.md

~~~~find
When driving a build subagent (or parallel session) through one,
~~~~

~~~~replace
When driving a build worker (or parallel session) through one,
~~~~

### Edit: D:/Claude/_Claude-Workspace/00_Resources/build-process.md

~~~~find
To change a running agent's instructions at any other time, stop it first, then send one consolidated message (the send resumes it with its context); never queue
~~~~

~~~~replace
To change a running worker's instructions at any other time, stop it first, then start a fresh worker with one consolidated prompt; never queue
~~~~

### Edit: D:/Claude/_Claude-Workspace/00_Resources/build-process.md

~~~~find
**Delegate bulk work to subagents sized to the task.** The main session orchestrates; subagents fetch
~~~~

~~~~replace
**Delegate bulk work to workers sized to the task, through `dispatch.ps1`.** The main session orchestrates; workers fetch
~~~~

### Edit: D:/Claude/_Claude-Workspace/00_Resources/build-process.md

~~~~find
When Danny says to stop or pause a running agent, stop it outright (TaskStop) and only then resume it with a report-only instruction; a polite "please stop" message waits in the agent's inbox until its next step.
~~~~

~~~~replace
When Danny says to stop or pause a running worker, stop it outright (`dt-job cancel`) and only then start a fresh worker with a report-only prompt if a report is still needed; a polite "please stop" message to a parallel session waits until its next step.
~~~~

### Edit: D:/Claude/_Claude-Workspace/00_Resources/git-workflow.md

~~~~find
- an **agent** (Claude, Codex, a sub-agent) is doing the work,
~~~~

~~~~replace
- an **agent** (Claude, Codex, a worker) is doing the work,
~~~~

### Edit: D:/Claude/_Claude-Workspace/Trading Terminal/CLAUDE.md

~~~~find
sequential subagent dispatch, not parallel.** One orchestrator dispatches subagents one at a time,
~~~~

~~~~replace
sequential worker dispatch, not parallel.** One orchestrator dispatches dt-job workers through `dispatch.ps1` one at a time,
~~~~

### Edit: D:/Claude/_Claude-Workspace/Trading Terminal/MEMORY.md

~~~~find
| Sequential subagent dispatch is the build default | Orchestrator dispatches subagents one at a time,
~~~~

~~~~replace
| Sequential worker dispatch is the build default | Orchestrator dispatches dt-job workers through `dispatch.ps1` one at a time,
~~~~

## Repo list under Superseded guidance

| Item | Result |
| :-- | :-- |
| dt-build `SKILL.md` lines 86, 92, 115 | Changed. Also removed the Agent-tool sentence in the selection line, both TaskStop instructions and `Agent` from allowed-tools. |
| `adapter-claude.md` line 11 | Changed; native branch removed. |
| `subagent-prompts.md` line 66 | Changed. |
| dt-pipeline `SKILL.md` steps 2-3 and description | Changed, plus steps 4 and 6, guardrails and allowed-tools. The frontmatter trigger names no subagent and is unchanged; the intro paragraph that described subagent delivery changed. The metadata changelog entry stays until M08, which owns version and changelog edits. |
| dt-review `SKILL.md` subagent contract | Changed to writing `decision-needed.md` and returning; `SendMessage` removed from allowed-tools. |
| dt-handoff `SKILL.md` line 112 | Changed. |
| dt-writing-draft and dt-writing-edit routing lines | Changed to `dispatch.ps1`. |
| `test-host-adapters.ps1` assertions | Changed to assert the wrapper path and the absence of the native branch. |
| `references/model-router/README.md` | Changed. |
| `skills/dt-build/hooks/README.md` "no hooks key" line | Changed; verified against `D:/Claude/settings.json`, which has a `hooks` key. |

## Grep dispositions: repo

Commands, rerun by `test-dispatch-migration.ps1`:

```text
git grep -nIE --untracked "\bAgent\b|subagent|sub-agent|\bExplore\b|spawn_agent|Task tool|TaskStop|SendMessage|agent_alias|spawned agent"
git grep -nIE --untracked "codex exec|claude(\.cmd)? +-p\b"
```

The first matching row disposes each hit. Path is relative to `<danny-skills>`; `*` in Path matches any characters, and Contains is a literal case-sensitive filter (`*` means every line). Every row stays as is; guidance that had to change was changed above, so no hit below instructs a session to delegate natively or launch directly.

<!-- dispositions:start -->
| Path | Contains | Reason it stays |
| :-- | :-- | :-- |
| `<danny-skills>/.claude-plugin/plugin.json` | * | Release history; M08 owns it. |
| `*/CHANGELOG.md` | * | Release history. |
| `*/_log.md` | * | Dated friction history. |
| `<danny-skills>/_planning/*` | * | Finished dt-image-gen planning records. dt-image-gen is a fixed lane. |
| `<danny-skills>/references/conventions.md` | Agent-SDK | Product name. |
| `<danny-skills>/references/model-router/dispatch-guard-*.md` | * | The guard's own release and migration records. |
| `<danny-skills>/references/model-router/README.md` | * | States the dispatch rule and the guard's staged status. |
| `<danny-skills>/scripts/claude-cli-result.ps1` | * | Parser for a wrapper's output; error text only. |
| `<danny-skills>/scripts/model-router/bench/appserver-control-source-evidence.txt` | * | Captured vendor source evidence. |
| `<danny-skills>/scripts/model-router/dispatch-guard.py` | * | The guard's matching logic. |
| `<danny-skills>/scripts/model-router/guard-settings.ps1` | * | The guard's matcher. |
| `<danny-skills>/scripts/model-router/register-mac-router-schedules.ps1` | * | macOS LaunchAgent plist names, unrelated to agents. |
| `<danny-skills>/scripts/model-router/resolve-model.ps1` | * | `Get-RouterAgentAlias` and the `agent_alias` field remain for dt-review's Claude invoker. |
| `<danny-skills>/scripts/model-router/send-router-alert.ps1` | User-Agent | HTTP header. |
| `<danny-skills>/scripts/model-router/tests/*` | * | Tests, probes and fixtures that exercise the guard, collector and alias field. No guidance. |
| `<danny-skills>/scripts/verify-skill-junctions.ps1` | Agent SDK | Product name. |
| `<danny-skills>/skills/dt-build/SKILL.md` | Never hand-roll | Forbids direct launches. |
| `<danny-skills>/skills/dt-build/SKILL.md` | or `claude -p` | Names the Claude Code host for adapter loading; not a launch instruction. |
| `<danny-skills>/skills/dt-build/SKILL.md` | -RetryAtHardFrom | Same forbidding of direct launches in the lane step. |
| `<danny-skills>/skills/dt-build/SKILL.md` | ubagent | Worker terminology; the file name `subagent-prompts.md` and the asserted heading stay. |
| `<danny-skills>/skills/dt-build/hooks/README.md` | * | Describes the coordinator hook's denial list and the managed launcher's flags. |
| `<danny-skills>/skills/dt-build/hooks/coordinator-pretooluse.ps1` | * | Past-limit denial list. |
| `<danny-skills>/skills/dt-build/references/adapter-claude.md` | * | The coordinator hook's denial list. |
| `<danny-skills>/skills/dt-build/references/adapter-codex.md` | * | Host description and a ban on direct launches and Codex subagents. |
| `<danny-skills>/skills/dt-build/scripts/assemble-codex-prompt.ps1` | * | Standing rule forbidding nested agents. |
| `<danny-skills>/skills/dt-build/scripts/collect-usage.py` | * | The collector measures native and direct delegation. |
| `<danny-skills>/scripts/model-router/cost_report.py` | * | The report prints the collector's measured counts. No guidance. |
| `<danny-skills>/skills/dt-build/scripts/context-guard.ps1` | * | Excludes subagent transcripts when measuring coordinator context. |
| `<danny-skills>/skills/dt-build/scripts/invoke-claude-chunk.ps1` | * | The wrapper's own launch, error text and tool restriction. |
| `<danny-skills>/skills/dt-build/scripts/invoke-codex-chunk.ps1` | * | The wrapper's own launch and error text. |
| `<danny-skills>/skills/dt-build/scripts/launch-managed-coordinator.ps1` | * | Managed launcher; scripts that launch children are not shell-tool calls. |
| `<danny-skills>/skills/dt-build/scripts/test-*` | * | Tests. |
| `<danny-skills>/skills/dt-build/scripts/tests/*` | * | Tests. |
| `<danny-skills>/skills/dt-image-gen/scripts/gen-image.sh` | * | Fixed lane. |
| `<danny-skills>/skills/dt-pipeline/SKILL.md` | changelog: | Historical metadata; M08 owns version and changelog edits. |
| `<danny-skills>/skills/dt-pipeline/SKILL.md` | spawned subagent | Says not to spawn one. |
| `<danny-skills>/skills/dt-review/SKILL.md` | Never hand-roll | Forbids direct launches. |
| `<danny-skills>/skills/dt-review/references/codex-prompt-template.md` | * | Describes what the fixed-lane invoker runs. |
| `<danny-skills>/skills/dt-review/scripts/invoke-claude-round.ps1` | * | Fixed lane reads the family alias. |
| `<danny-skills>/skills/dt-session-context/SKILL.md` | * | Describes which sessions the digest covers. |
| `<danny-skills>/skills/start-work/SKILL.md` | Agent-neutral | Means vendor-neutral. |
<!-- dispositions:end -->

## Grep dispositions: scaffolding

Read-only search of `D:/Claude` for root, workspace, workstation and repo `CLAUDE.md`, `MEMORY.md`, `CONTEXT.md`, `glossary.md` and `ARCHIVE.md`, plus `00_Resources/*.md` and this repo's auto-memory, run 2026-11-06 at 12:51 AM ET. Auto-memory had no hits. Line numbers are as of that search. The rows for `read_guard.py`, `build-process.md:42` and the missed hits were reread in the live files on 2026-11-06 at 1:30 AM ET.

| Hit | Disposition |
| :-- | :-- |
| `CLAUDE.md:220` | Staged above. |
| `00_Resources/model-routing.md:3, 21, 22, 42, 67, 106` | Staged above. |
| `00_Resources/model-routing.md:7` | Stays: it explains the failure the rule prevents. |
| `00_Resources/read-delegation.md:23, 37` | Staged above, with line 36. |
| `00_Resources/read-delegation.md:21` | Stays: it accurately lists who the read guard exempts. |
| `00_Resources/codex-cli-usage.md:3, 9` | Staged above. |
| `00_Resources/codex-cli-usage.md:18, 27, 47, 94, 105, 108, 121, 145` | Stay under the staged "what the wrappers run" note at the section start; line 18 and 145 only describe the CLI. |
| `00_Resources/build-process.md:37, 38, 39, 42` | Staged above; these told sessions to drive, message and force-stop subagents. |
| `00_Resources/git-workflow.md:39` | Staged above: same "sub-agent" wording changed in `start-work/SKILL.md`. |
| `00_Resources/toolchain-integration.md:7, 9` | Stay: "Agent SDK" is a product name. |
| `_system-tools/read-guard/read_guard.py:557-558` | Staged above: the character warning pointed at a subagent or chunk wrapper. |
| `CLAUDE.md:238` | Stays: section heading naming the Claude and Codex workflow; no delegation instruction. |
| `MEMORY.md:66` | Stays: dated note on auto-mode permission limits, unrelated to delegation. |
| `00_Resources/calibration-log.md:63, 65` | Stay: dated failure history. |
| `_Claude-Workspace/CLAUDE.md:24` | Stays: records how Trading Terminal phases 5-7 were built. |
| `Trading Terminal/CLAUDE.md:54`, `Trading Terminal/MEMORY.md:38` | Staged above: a live build default that names subagents. |
| `Trading Terminal/CLAUDE.md:52` | Stays: heading of the section whose line 54 is staged. |
| `Trading Terminal/ARCHIVE.md:21, 37` | Stay: archive. |
| `Trading Terminal/tcm-trading-terminal/CLAUDE.md:200`, `TCM Website/thai-capital-website/CLAUDE.md:171`, `TCM Website/thai-capital-website-share-class-terms/CLAUDE.md:170` | Stay: "Agent skills" heading over issue-tracker settings; no delegation instruction. |
| `ECKS/MEMORY.md:19, 24` | Stay: "Registered Agent" is a legal role. |
| `Finance HQ/MEMORY.md:39` | Stays: heading on how agents write dashboard data; no delegation instruction. |
| `OneDrive Migration/File Sorter/personal-expansion/CONTEXT.md:45` | Stays: term name for the `fs.ps1` session command. |
| `Skill Creation/MEMORY.md:55, 119` | Stay: line 55 is the same release-history sentence as line 56; line 119 records a deferred decision. |
| `Home Server/session-context-hub/CONTEXT.md:12, 13` | Stay: scope of that project's digest. |
| `Email HQ/MEMORY.md:49` | Stays: a scheduled script launching its own classifier, which the shell rule does not touch. |
| `Skill Creation/MEMORY.md:56, 70, 113` | Stay: dated release history and bench facts; `dt-session-audit` can refresh them at release. |
| `Skill Creation/audit-skill/CONTEXT.md:9`, `parallel-build-redesign/CONTEXT.md:7, 16` | Stay: term records of finished projects. |
| `model-router/observability/CONTEXT.md:7, 9`, `internal-bench/CONTEXT.md:49` | Stay: definitions of what the collector and bench measure. |
| `model-router/dispatch-repair/CONTEXT.md:11, 13` | Stay: this project's definition of native delegation. |
| `OneDrive Migration/File Sorter/evidence/**/CLAUDE.md` (12 hits in 8 folders) | Stay: frozen copies retained as audit evidence. |
