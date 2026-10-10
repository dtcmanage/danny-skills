# dt-build host adapter: Claude Code

Load this file only when the coordinator runs in Claude Code (interactive CLI, Cowork, or `claude -p`). Other rules live in `SKILL.md`. `dt-job` below means `pwsh -NoProfile -File scripts/dt-job.ps1 -Verb <verb> -RunFolder <run-folder>`. Pass `-CoordinatorId <id>` on every `dt-job` call except `approve` and `resume`; the id checks context and renews the lease.

## Dispatch

- Resolve the worker per `SKILL.md` "Model routing" and dispatch on the returned `vendor`, either vendor.
- Launch every worker as a job: `dt-job start -CoordinatorId <id> -Kind worker -Category <category> -Vendor <vendor> -Model <model> -Mutates <worktree key> -Command "<wrapper call>"`, where the wrapper call is `scripts/invoke-claude-chunk.ps1` or `scripts/invoke-codex-chunk.ps1` with the arguments `SKILL.md` names. Add `-DependsOn <job ids>` when it must wait for other jobs. `start` returns a `job_id` at once; record it in `_build-state.md` in-flight work.
- Run long tests, builds, and browser or screenshot checks as `-Kind test` or `-Kind command` jobs too, never in the foreground.
- A Claude pick at the session's own effort may still use the Agent tool with the returned `agent_alias`. Any other effort goes through the wrapper as a job.

## Waiting and completion

- Wait with one command: `dt-job wait -CoordinatorId <id> -JobId <job ids, comma-separated> -Any|-All -TimeoutSec <n> -Json`, run through the Bash tool with `run_in_background: true` and a Bash `timeout` longer than `-TimeoutSec`. Claude Code notifies once when it exits, whatever the outcome. End the turn after starting it.
- Never use CronCreate (forbidden in a dt-build coordinator), Monitor heartbeats, `sleep` loops, repeated `status` calls, or any self-scheduled check.
- The ledger is the truth, not the notification: run `dt-job reconcile -CoordinatorId <id>` at every coordinator start and resume, and on `wait_timeout`, then start one new background wait for the jobs still running.
- `wait` and `status` carry `last_event_seq` and `last_consumed_event_seq`. Consume only from run-level `dt-job status -CoordinatorId <id> -Json` after handling every job state shown; never from job-scoped wait or status envelopes. Run `dt-job consume -CoordinatorId <id> -Seq <last_event_seq>`.

## Bootstrap and context

- Do the mandatory reads (CLAUDE.md chain, MEMORY.md, governing references) first, in full.
- Register first: `dt-job register-run -CoordinatorId <id> -BuildStatePath <_build-state.md> -RunId <RUN_ID> -PinnedHost claude`. Add `-Managed` when requested.
- Then, before dispatch: `dt-job mark-bootstrap -CoordinatorId <id> -Host claude`. Use one session id, e.g. `<RUN_ID>-claude-<yyyyMMddHHmm>`. Use the starting directory or add `-TranscriptPath <this session's transcript>`.
- An unmanaged interactive coordinator takes the lease after marking: `dt-job lease -Action acquire -CoordinatorId <id> -Host claude`. Each later call with your id, a running wait included, renews it through long waits. A watcher-launched coordinator already holds it.
- Every `dt-job` call with your id prints a `context:` line. States: `ok` continue; `checkpoint` finish the current decision and rewrite `_build-state.md`; `rotate` rotate now.
- Past the hard limit `dt-job start` refuses with `ROTATE_REQUIRED` and the PreToolUse hook denies it: rotate now; do not retry the dispatch.
- Rotation steps, in order: rewrite `_build-state.md` (keep the `run_status` and `last_consumed_event_seq` lines as they are), write a coordinator handoff note in the run folder, `dt-job request-continuation -CoordinatorId <id> -Reason context_rotation`, `dt-job lease -Action release -CoordinatorId <id>`, then end. Interactive: tell Danny the one command to continue in a fresh session, `/dt-build <RUN_ID>`.
- Jobs survive rotation. Before an irreversible step run `dt-job irreversible -CoordinatorId <id> -Action begin -Operation <op>`, and `-Action end` after it; rotation waits while it is open.

## Hooks

- Two hooks ship in `hooks/`; adoption installs them into the live settings file `hooks/README.md` names.
- In a coordinator session the PreToolUse hook denies a Read of a file over 400 lines without a range, image Reads, and CronCreate. Past the hard context limit it also denies direct reads, searches, web tools, Agent, `dt-job start`, and every shell command except the dt-build state scripts and `git status|log|rev-parse`. The deny reason names the next step: follow it.
- The PostToolUse hook surfaces the `context:` line at `checkpoint` and `rotate`.
- Managed Claude coordinators get both hooks through the `--settings` file the launcher writes.

## Managed mode and relaunch

- For managed starts, the interactive session registers with `-Managed`, runs `dt-job request-continuation -CoordinatorId <id> -Reason managed_start`, takes no lease, and ends; the watcher continues.

- On starts and relaunches: `dt-job register-run -CoordinatorId <id> -BuildStatePath <_build-state.md> -RunId <RUN_ID> -PinnedHost claude`. Add `-Managed` when requested. `dt-job finish -CoordinatorId <id>` at COMPLETE unregisters it.
- The watcher (`scripts/dt-build-watcher.ps1`, every 2 minutes) reconciles, starts queued jobs, and launches a headless coordinator when no lease exists, a managed lease is released, or its watcher-launched coordinator is gone and an unconsumed event waits. Unconsumed triggers retry at 2, 10, and 30 minutes, then stop with one DM.
- A managed coordinator's prompt reads `/dt-build resume <RUN_ID> (managed coordinator <id>)`. Continue as `<id>` (reconcile, read `_build-state.md`, carry on); never run `dt-job resume`.
- Before ending each headless turn, run `dt-job consume -CoordinatorId <id> -Seq <last_event_seq>`, from run-level `dt-job status -CoordinatorId <id> -Json` after handling every job state it shows. An unconsumed trigger counts as a failed launch.
- The launcher alone sets `DT_BUILD_COORDINATOR_ID`, for managed coordinators. Never export it in an interactive shell; pass `-CoordinatorId <id>` instead.
- At approval boundaries (merge, push, deploy, prod write, irreversible step): `dt-job await-danny -CoordinatorId <id> -Operation <op> -Message "<one line>"`, then end. Never run `dt-job approve` or `dt-job resume`; they are Danny's alone.
- Interactive approve/resume refusal is instruction-only (no env var), a known residual.
- Danny's commands: `/dt-build approve <RUN_ID> <operation>` records his approval and makes the run runnable; `/dt-build resume <RUN_ID>` re-arms a stopped run. When Danny types either, run the matching `dt-job approve -Operation <operation>` or `dt-job resume`.

## Evidence

- Read job results only from `dt-job status` and `dt-job wait` envelopes (`-Json`). They cap output and name evidence paths.
- For a deeper look use `pwsh -NoProfile -File scripts/read-evidence.ps1 -RunFolder <run-folder> -Path <file> -Lines a-b` or `-Grep <pattern>`. Calls cap at 16 KB and are logged.
- Never Read/tail/cat a job's output or stream log directly. Load screenshots deliberately.
