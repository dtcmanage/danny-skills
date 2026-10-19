# dt-build host adapter: Claude Code

Claude Code coordinators; shared rules: `SKILL.md`. `dt-job`: `pwsh -NoProfile -File "<skill>/scripts/dt-job.ps1" -Verb <verb> -RunFolder <run-folder>`. Pass `-CoordinatorId <id>` on every `dt-job` call except `approve` and `resume`.

## Dispatch

- Follow `SKILL.md` routing; dispatch pinned runs without `-Model`; omit pins from handoffs.
- Launch every worker as a job: `dt-job start -CoordinatorId <id> -Kind worker -Category <category> -Vendor <vendor> -Mutates <worktree key> -Command "<wrapper call>"`, using `<skill>/scripts/invoke-claude-chunk.ps1` or `<skill>/scripts/invoke-codex-chunk.ps1`. Add `-DependsOn <job ids>` for prerequisites. Record `job_id` in `_build-state.md`.
- Run tests/builds/browser checks as `-Kind test|command` jobs.
- Commands run as PowerShell: never nest `pwsh -Command "...$..."`; run directly or use `-File`.
- A Claude pick at the session's own effort may still use the Agent tool with the returned `agent_alias`. Any other effort goes through the wrapper as a job.

## Waiting and completion

- Watchdogs: use `dt-job status -CoordinatorId <id> -Json`, `stalled` and heartbeat/activity age; checkpoint age must never be used alone (`_build-state.md`).
- Top-level coordinators: `dt-job wait -CoordinatorId <id> -JobId <job ids, comma-separated> -Any|-All -TimeoutSec 600 -Json`, Bash `run_in_background: true`, longer Bash `timeout`; end the turn and await notification.
- Subagent/teammate coordinators (Agent-tool launched, or no direct user turn): foreground wait with `dt-job wait -CoordinatorId <id> -JobId <job ids, comma-separated> -Any|-All -TimeoutSec 540 -Json`, Bash `run_in_background: false`, `timeout: 600000`. Repeat after every `wait_timeout` check-in; never end the turn while jobs run.
- `wait_timeout` lists running jobs' `progress`. Jobs have no time limit; after 20 silent minutes (`STALLED`), check output, then cancel/retry or wait.
- Coordinators never use CronCreate, Monitor heartbeats, `sleep` loops, or repeated `status` calls; delegate watches are separate.
- Run `dt-job reconcile -CoordinatorId <id>` at start, resume and `wait_timeout`, then repeat the appropriate wait for remaining jobs.
- `wait` and `status` carry `last_event_seq` and `last_consumed_event_seq`. Consume only from run-level `dt-job status -CoordinatorId <id> -Json` after handling every job state shown; never from job-scoped wait or status envelopes. Run `dt-job consume -CoordinatorId <id> -Seq <last_event_seq>`.

## Bootstrap and context

- Managed resumes follow `managed-resume.md`: verified digest above budget, current authority in full, then bootstrap; governing originals in full before actions. New starts do the mandatory CLAUDE.md chain, MEMORY.md and governing reads first. Load other references only at their step.
- No `_build-state.md` yet? Copy `skills/dt-pipeline/templates/build-state-template.md` (runnable, cursor 0).
- Register: `dt-job register-run -CoordinatorId <id> -BuildStatePath <_build-state.md> -RunId <RUN_ID> -PinnedHost claude`. Add `-Managed` when requested. Interactive launch/monitor sessions pass `-Delegate <own session name>`; headless runs omit it.
- On taking delegation (registration or `delegate`), immediately arm a persistent run-level watch: `dt-job status` with `-Json` (`run_status`, `awaiting`, `stalled`), surviving turns. When `awaiting.awaiting_owner=danny`, tell Danny the decision in your chat (`operation` and `message`), even if `alerted_danny=true`; `delegated_to` names the delegate.
- Before dispatch: `dt-job mark-bootstrap -CoordinatorId <id> -Host claude`. Use one id; optionally `-TranscriptPath <transcript>`.
- An unmanaged interactive coordinator takes the lease after marking: `dt-job lease -Action acquire -CoordinatorId <id> -Host claude`. Each call renews it through long waits; watcher-launched coordinators already hold it.
- Every `dt-job` call with your id prints a `context:` line. States: `ok` continue; `checkpoint` reach a safe stopping point, then rotate; `rotate` rotate now.
- Past the hard limit `dt-job start` refuses with `ROTATE_REQUIRED` and the PreToolUse hook denies it: rotate now; do not retry the dispatch.
- Rotation: consume handled events, rewrite `_build-state.md` (keep the `run_status` and `last_consumed_event_seq` lines), write the run-folder handoff, `dt-job request-continuation -CoordinatorId <id> -Reason context_rotation`, `dt-job lease -Action release -CoordinatorId <id>`, then end. Interactive: give Danny `/dt-build <RUN_ID>` to continue fresh.
- Jobs survive rotation. Before an irreversible step run `dt-job irreversible -CoordinatorId <id> -Action begin -Operation <op>`, and `-Action end` after it; rotation waits while it is open.

## Hooks

- In a coordinator session the PreToolUse hook denies a Read of a file over 400 lines without a range, image Reads, and CronCreate. Past the hard context limit it also denies direct reads, searches, web tools, Agent, `dt-job start`, and every shell command except the dt-build state scripts and `git status|log|rev-parse`. Follow the deny reason's next step.
- The PostToolUse hook surfaces the `context:` line at `checkpoint` and `rotate`.
- Managed Claude coordinators get both hooks through the `--settings` file the launcher writes.

## Managed mode and relaunch

- Managed starts: register with `-Managed`, run `dt-job request-continuation -CoordinatorId <id> -Reason managed_start`; the interactive session takes no lease, and ends; the watcher continues.

- Managed relaunches verify the existing registration through `read-resume-record.ps1`. `dt-job finish -CoordinatorId <id>` at COMPLETE unregisters the run.
- The watcher (`<skill>/scripts/dt-build-watcher.ps1`, every 2 minutes) reconciles, starts jobs and relaunches for unconsumed events without a coordinator. Retries: 2/10/30 minutes; two thrash launches on unchanged checkpoints pause with one DM.
- Legacy managed coordinator prompts read `/dt-build resume <RUN_ID> (managed coordinator <id>)`. Continue as `<id>` (reconcile, read `_build-state.md`, carry on); never run `dt-job resume`.
- Before ending each headless turn: `dt-job consume -CoordinatorId <id> -Seq <last_event_seq>` after handling `dt-job status -CoordinatorId <id> -Json`; an unconsumed trigger fails the launch.
- `DT_BUILD_COORDINATOR_ID` is launcher-only. Never export it in an interactive shell; pass `-CoordinatorId <id>` instead.
- Before power-off/reboot stops, check `dt-job status` across runs; name other builds' running jobs and finish times.
- At approval boundaries (merge, push, deploy, prod write, irreversible): `dt-job await-danny -CoordinatorId <id> -Operation <op> -Message "<one line>"`, then end; add `-AlwaysNotify` for production, Azure or irreversible. Never run `dt-job approve`, `resume`, `delegate` or `hold`; they are Danny's.
- Interactive approve/resume refusal is instruction-only (no env var), a known residual.
- Danny's commands: `/dt-build approve <RUN_ID> <operation>` approves; `/dt-build resume <RUN_ID>` re-arms; `/dt-build delegate <RUN_ID> <session>` (`-Clear` undoes) routes routine stops there; a holding delegate runs `hold` (`-Operation <op> -Reason "<why>"`) so the 15-minute DM says why. Use matching `dt-job` verbs. Follow `operator_notes`; operators add them (`note`).

## Evidence

- Read only `status|wait -Json` envelopes, checking `report_verdict` and `failure_category`.
- Use `pwsh -NoProfile -File "<skill>/scripts/read-evidence.ps1" -RunFolder <run-folder> -JobId <id> -File <name>` or `-Path <file>`, with `-Lines a-b` or `-Grep <pattern>`, capped at 16 KB.
- Never Read/tail/cat job output or stream logs directly. Load screenshots deliberately.
