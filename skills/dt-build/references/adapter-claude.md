# dt-build host adapter: Claude Code

Load this file only when the coordinator runs in Claude Code (interactive CLI, Cowork, or `claude -p`). Other rules live in `SKILL.md`. `dt-job` below means `pwsh -NoProfile -File scripts/dt-job.ps1 -Verb <verb> -RunFolder <run-folder>`. Pass `-CoordinatorId <id>` on every `dt-job` call except `approve` and `resume`; the id checks context and renews the lease.

## Dispatch

- Resolve unpinned workers per `SKILL.md` "Model routing"; dt-job and wrappers enforce run pins: dispatch without `-Model` and never restate pins in handoffs.
- Launch every worker as a job: `dt-job start -CoordinatorId <id> -Kind worker -Category <category> -Vendor <vendor> -Mutates <worktree key> -Command "<wrapper call>"`, using `scripts/invoke-claude-chunk.ps1` or `scripts/invoke-codex-chunk.ps1` with `SKILL.md` arguments. Add `-DependsOn <job ids>` for prerequisites. Record `job_id` in `_build-state.md` in-flight work.
- Run long tests, builds and browser checks as `-Kind test|command` jobs.
- A Claude pick at the session's own effort may still use the Agent tool with the returned `agent_alias`. Any other effort goes through the wrapper as a job.

## Waiting and completion

- Wait with one command: `dt-job wait -CoordinatorId <id> -JobId <job ids, comma-separated> -Any|-All -TimeoutSec 600 -Json`, run through the Bash tool with `run_in_background: true` and a longer Bash `timeout`. Claude Code notifies on exit. End the turn after starting it.
- Each `wait_timeout` is a check-in listing each running job's `progress`. Jobs have no time limit; for a `STALLED` job (20 silent minutes), check its output, then cancel and retry or keep waiting.
- Never use CronCreate, Monitor heartbeats, `sleep` loops, or repeated `status` calls.
- The ledger is the truth, not the notification: run `dt-job reconcile -CoordinatorId <id>` at every coordinator start and resume, and on `wait_timeout`, then start one new background wait for the jobs still running.
- `wait` and `status` carry `last_event_seq` and `last_consumed_event_seq`. Consume only from run-level `dt-job status -CoordinatorId <id> -Json` after handling every job state shown; never from job-scoped wait or status envelopes. Run `dt-job consume -CoordinatorId <id> -Seq <last_event_seq>`.

## Bootstrap and context

- Managed resumes follow `managed-resume.md`: verified digest above budget, current authority in full, then bootstrap; governing originals in full before actions. New starts do the mandatory CLAUDE.md chain, MEMORY.md and governing reads first. Load other references only at their step.
- No `_build-state.md` yet? Copy `skills/dt-pipeline/templates/build-state-template.md` (runnable, cursor 0).
- New starts register first: `dt-job register-run -CoordinatorId <id> -BuildStatePath <_build-state.md> -RunId <RUN_ID> -PinnedHost claude`. Add `-Managed` when requested.
- Then, before dispatch: `dt-job mark-bootstrap -CoordinatorId <id> -Host claude`. Use one id, e.g. `<RUN_ID>-claude-<yyyyMMddHHmm>`, from the starting directory or with `-TranscriptPath <transcript>`.
- An unmanaged interactive coordinator takes the lease after marking: `dt-job lease -Action acquire -CoordinatorId <id> -Host claude`. Any call with your id renews it through long waits. A watcher-launched coordinator already holds it.
- Every `dt-job` call with your id prints a `context:` line. States: `ok` continue; `checkpoint` reach a safe stopping point, then rotate; `rotate` rotate now.
- Past the hard limit `dt-job start` refuses with `ROTATE_REQUIRED` and the PreToolUse hook denies it: rotate now; do not retry the dispatch.
- Rotation steps, in order: consume handled events, rewrite `_build-state.md` (keep the `run_status` and `last_consumed_event_seq` lines as they are), write a coordinator handoff note in the run folder, `dt-job request-continuation -CoordinatorId <id> -Reason context_rotation`, `dt-job lease -Action release -CoordinatorId <id>`, then end. Interactive: give Danny `/dt-build <RUN_ID>` to continue fresh.
- Jobs survive rotation. Before an irreversible step run `dt-job irreversible -CoordinatorId <id> -Action begin -Operation <op>`, and `-Action end` after it; rotation waits while it is open.

## Hooks

- In a coordinator session the PreToolUse hook denies a Read of a file over 400 lines without a range, image Reads, and CronCreate. Past the hard context limit it also denies direct reads, searches, web tools, Agent, `dt-job start`, and every shell command except the dt-build state scripts and `git status|log|rev-parse`. Follow the deny reason's next step.
- The PostToolUse hook surfaces the `context:` line at `checkpoint` and `rotate`.
- Managed Claude coordinators get both hooks through the `--settings` file the launcher writes.

## Managed mode and relaunch

- For managed starts, the interactive session registers with `-Managed`, runs `dt-job request-continuation -CoordinatorId <id> -Reason managed_start`, takes no lease, and ends; the watcher continues.

- Managed relaunches verify the existing registration through `read-resume-record.ps1`. `dt-job finish -CoordinatorId <id>` at COMPLETE unregisters the run.
- The watcher (`scripts/dt-build-watcher.ps1`, every 2 minutes) reconciles, starts queued jobs, and relaunches when unconsumed events wait without a live coordinator. Unconsumed triggers retry after 2/10/30 minutes, then stop; two consecutive thrash launches on unchanged checkpoints pause with one DM.
- Legacy managed coordinator prompts read `/dt-build resume <RUN_ID> (managed coordinator <id>)`. Continue as `<id>` (reconcile, read `_build-state.md`, carry on); never run `dt-job resume`.
- Before ending each headless turn, run `dt-job consume -CoordinatorId <id> -Seq <last_event_seq>`, from run-level `dt-job status -CoordinatorId <id> -Json` after handling every job state it shows. An unconsumed trigger counts as a failed launch.
- The launcher alone sets `DT_BUILD_COORDINATOR_ID`, for managed coordinators. Never export it in an interactive shell; pass `-CoordinatorId <id>` instead.
- At approval boundaries (merge, push, deploy, prod write, irreversible): `dt-job await-danny -CoordinatorId <id> -Operation <op> -Message "<one line>"`, then end; add `-AlwaysNotify` for production, Azure or irreversible. Never run `dt-job approve`, `resume`, `delegate` or `hold`; they are Danny's.
- Interactive approve/resume refusal is instruction-only (no env var), a known residual.
- Danny's commands: `/dt-build approve <RUN_ID> <operation>` records his approval; `/dt-build resume <RUN_ID>` re-arms a stopped run; `/dt-build delegate <RUN_ID> <session>` (`-Clear` undoes) routes routine stops there; a delegate deliberately holding one runs the `hold` verb (`-Operation <op> -Reason "<why>"`) so the 15-minute DM says why. Run the matching `dt-job` verb. Follow `operator_notes` in status and wait envelopes; only operators add them (`note` verb).

## Evidence

- Read only `status|wait -Json` envelopes, checking `report_verdict` and `failure_category`.
- Use `pwsh -NoProfile -File scripts/read-evidence.ps1 -RunFolder <run-folder> -JobId <id> -File <name>` or `-Path <file>`, with `-Lines a-b` or `-Grep <pattern>`, capped at 16 KB.
- Never Read/tail/cat job output or stream logs directly. Load screenshots deliberately.
