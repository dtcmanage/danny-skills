# dt-build host adapter: Claude Code

Claude Code coordinators; shared rules: `SKILL.md`. `dt-job`: `pwsh -NoProfile -File "<skill>/scripts/dt-job.ps1" -Verb <verb> -RunFolder <run-folder>`. For coordinator calls, pass `-CoordinatorId <id>` on every `dt-job` call except `approve` and `resume`.

## Dispatch

Transcript discovery for `mark-bootstrap`: `resume-bootstrap-measurement.md`.

- Follow `SKILL.md` routing; dispatch pinned runs without `-Model`; omit pins from handoffs.
- Lane health: only `invoke-claude-chunk.ps1 -Preflight` or `invoke-codex-chunk.ps1 -Preflight`, never a bare CLI from your shell; failure never skips required reviews (`managed-resume.md` § Lane health).
- Launch every worker as a job: `dt-job start -CoordinatorId <id> -Kind worker -Category <category> -Vendor <vendor> -Mutates <worktree key> -Command "<wrapper call>"`, using `<skill>/scripts/invoke-claude-chunk.ps1` or `<skill>/scripts/invoke-codex-chunk.ps1`. Add `-DependsOn <job ids>` for prerequisites. Record `job_id` in `_build-state.md`.
- Run tests/builds/browser checks as `-Kind test|command` jobs.
- Commands run as PowerShell: never nest `pwsh -Command "...$..."`; run directly or use `-File`.

## Waiting and completion

- Watchdogs: use `dt-job status -CoordinatorId <id> -Json`, `stalled` and heartbeat/activity age; checkpoint age must never be used alone.
- Top-level coordinators: `dt-job wait -CoordinatorId <id> -JobId <job ids, comma-separated> -Any|-All -TimeoutSec 600 -Json`, Bash `run_in_background: true`, longer Bash `timeout`; end the turn and await notification.
- Subagent/teammate coordinators (no direct user turn): foreground wait with `dt-job wait -CoordinatorId <id> -JobId <job ids, comma-separated> -Any|-All -TimeoutSec 540 -Json`, Bash `run_in_background: false`, `timeout: 600000`. Repeat after every `wait_timeout` check-in; never end the turn while jobs run.
- On `result=stalled`, inspect command/output/process tree this turn; cancel/fix or `dt-job stall-ack -CoordinatorId <id> -JobId <job> -Reason "<dependency; why keep>" -Until <minutes>`. Never re-wait without action. Expiry re-escalates.
- Coordinators never use CronCreate, Monitor heartbeats, `sleep` loops, or repeated `status` calls; delegate watches are separate.
- Run `dt-job reconcile -CoordinatorId <id>` at start, resume and `wait_timeout`, then repeat the appropriate wait for remaining jobs.
- `wait` and `status` carry `last_event_seq` and `last_consumed_event_seq`. Consume only from run-level `dt-job status -CoordinatorId <id> -Json` after handling every job state shown; never from job-scoped wait or status envelopes. Run `dt-job consume -CoordinatorId <id> -Seq <last_event_seq>`.

## Bootstrap and context

- Managed resumes follow `managed-resume.md`: verified digest above budget, current authority in full, then bootstrap; governing originals in full before actions. New starts do the mandatory CLAUDE.md chain, MEMORY.md and governing reads first. Load other references only at their step.
- No `_build-state.md` yet? Copy `skills/dt-pipeline/templates/build-state-template.md` (runnable, cursor 0).
- Register: `dt-job register-run -CoordinatorId <id> -BuildStatePath <_build-state.md> -RunId <RUN_ID> -PinnedHost claude`. Add `-Managed` when requested. Directors register without `-CoordinatorId`; optional `-Delegate` requires a live identity.
- Director watch: record provider session identity; only that session retakes a dead director. Other sessions explicitly `delegate`. Keep a persistent run-level `dt-job status -Json` watch on `run_status`, `awaiting`, `stalled`; re-arm on expiry. When `awaiting_owner=director`, approve within authority. Raise reserved decisions in your chat per `managed-resume.md`; `delegated_to` names the director.
- Before dispatch: `dt-job mark-bootstrap -CoordinatorId <id> -Host claude`. One id; optionally `-TranscriptPath <transcript>`.
- An unmanaged interactive coordinator takes the lease after marking: `dt-job lease -Action acquire -CoordinatorId <id> -Host claude`. Each call renews it through long waits; watcher-launched coordinators already hold it.
- Every `dt-job` call with your id prints a `context:` line. States: `ok` continue; `checkpoint` reach a safe stopping point, then rotate; `rotate` rotate now.
- Past the hard limit `dt-job start` refuses with `ROTATE_REQUIRED` and the PreToolUse hook denies it: rotate now; do not retry the dispatch.
- Rotation: consume handled events, rewrite `_build-state.md` (keep the `run_status` and `last_consumed_event_seq` lines), write the run-folder handoff, `dt-job request-continuation -CoordinatorId <id> -Reason context_rotation`, `dt-job lease -Action release -CoordinatorId <id>`, then end. The watcher relaunches every rotation.
- Jobs survive rotation. Before an irreversible step run `dt-job irreversible -CoordinatorId <id> -Action begin -Operation <op>`, and `-Action end` after it; rotation waits while it is open.

## Hooks

- In a coordinator session the PreToolUse hook denies a Read of a file over 400 lines without a range, image Reads, and CronCreate. Past the hard context limit it also denies direct reads, searches, web tools, Agent, `dt-job start`, and every shell command except the dt-build state scripts and `git status|log|rev-parse`. Follow the deny reason's next step.
- The PostToolUse hook surfaces the `context:` line at `checkpoint` and `rotate`.
- Managed Claude coordinators get both hooks through the `--settings` file the launcher writes.

## Managed mode and relaunch

- Managed starts: register with `-Managed`, run `dt-job request-continuation -CoordinatorId <id> -Reason managed_start`; the interactive session takes no lease, and ends coordinating, then confirms the start and arms a watch (`managed-resume.md` § Launch watch).

- Relaunches verify the registration (`read-resume-record.ps1`); `dt-job finish -CoordinatorId <id>` at COMPLETE unregisters the run.
- The watcher (`<skill>/scripts/dt-build-watcher.ps1`, every 2 minutes) reconciles, starts jobs and relaunches for unconsumed events without a coordinator. Retries: 2/10/30 minutes; two thrash launches on unchanged checkpoints pause with one DM.
- Legacy prompts `/dt-build resume <RUN_ID> (managed coordinator <id>)`: continue as `<id>`; never run `dt-job resume`.
- Before ending each headless turn: `dt-job consume -CoordinatorId <id> -Seq <last_event_seq>` after handling `dt-job status -CoordinatorId <id> -Json`; an unconsumed trigger fails the launch.
- `DT_BUILD_COORDINATOR_ID` is launcher-only. Never export it in an interactive shell; pass `-CoordinatorId <id>` instead.
- Before power-off/reboot stops, name other builds' running jobs and finish times (`dt-job status`).
- At approval boundaries: `dt-job await-danny -CoordinatorId <id> -Operation <op> -Message "<decision>" -WaitMinutes 7.5 -CallStartedUtc <call-start-utc> -Json`, foreground tool timeout `600000`. For live directors, block with lease renewal. On `decision=approved`, read the receipt and continue in this SAME coordinator; otherwise checkpoint/end. Never re-wait or self-approve. No director returns immediately; `-AlwaysNotify` follows routing.
- Interactive approve/resume refusal is instruction-only (no env var), a known residual.
- Director commands: `/dt-build approve <RUN_ID> <operation>`, `/dt-build resume <RUN_ID>`. Approve promptly within authority. `approve -Decline`/`hold -Reason "<why>"` wake without approval; escalate in your chat. Follow `operator_notes`; details: `managed-resume.md`.

## Evidence

- Read only `status|wait -Json` envelopes, checking `report_verdict` and `failure_category`.
- Use `pwsh -NoProfile -File "<skill>/scripts/read-evidence.ps1" -RunFolder <run-folder> -JobId <id> -File <name>` or `-Path <file>`, with `-Lines a-b` or `-Grep <pattern>`, capped at 16 KB.
- Never Read/tail/cat job output or stream logs directly. Load screenshots deliberately.
