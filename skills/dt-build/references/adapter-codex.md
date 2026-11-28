# dt-build host adapter: Codex

For Codex coordinators (interactive Codex CLI, `codex exec`). Shared rules: `SKILL.md`. Coordinator verbs use `pwsh -NoProfile -File "<skill>/scripts/dt-job.ps1" -Verb <verb> -RunFolder <run-folder> -CoordinatorId <id>`. Operator approve/decline/hold/note/delegate/resume use `invoke-dt-job-control.ps1` as required below.

## Dispatch

Transcript discovery for `mark-bootstrap`: `resume-bootstrap-measurement.md`.

- Follow `SKILL.md` routing; dispatch pinned runs without `-Model`; omit pins from handoffs.
- Lane health: only `invoke-claude-chunk.ps1 -Preflight` or `invoke-codex-chunk.ps1 -Preflight`, never a bare CLI from your shell; failure never skips required reviews (`managed-resume.md` § Lane health).
- Launch every worker as a job: `dt-job start -CoordinatorId <id> -Kind worker -Category <category> -Vendor <vendor> -Mutates <worktree key> -Command "<wrapper call>"`, using `<skill>/scripts/invoke-codex-chunk.ps1` or `<skill>/scripts/invoke-claude-chunk.ps1`. Add `-DependsOn <job ids>` for prerequisites. Record `job_id` in `_build-state.md`.
- Run tests/builds/browser checks as `-Kind test|command` jobs.
- Commands run as PowerShell: never nest `pwsh -Command "...$..."`; run directly or use `-File`.
- Never hand-roll `codex exec` or `claude -p` or use Codex subagents for chunks.

## Waiting and completion

- Watchdogs: use `dt-job status -CoordinatorId <id> -Json`, `stalled` and heartbeat/activity age; checkpoint age must never be used alone.
- Codex has no in-session completion notice. Wait in the foreground: `dt-job wait -CoordinatorId <id> -JobId <job ids, comma-separated> -Any|-All -TimeoutSec <n> -Json`, with `-TimeoutSec` (at most 600) below the shell timeout.
- Only on `wait_timeout`, run `dt-job reconcile -CoordinatorId <id>`, then call `dt-job wait` again; nothing else between waits.
- Coordinators never poll with `status`, `sleep` loops or log tails; delegate watches are separate.
- On `result=stalled`, inspect command/output/process tree this turn; cancel/fix or `dt-job stall-ack -CoordinatorId <id> -JobId <job> -Reason "<dependency; why keep>" -Until <minutes>`. Never re-wait without action. Expiry re-escalates.
- Hours-long waits use managed mode (below).
- The ledger is the truth: run `dt-job reconcile -CoordinatorId <id>` at every start and resume.
- `wait` and `status` carry `last_event_seq` and `last_consumed_event_seq`. Consume only from run-level `dt-job status -CoordinatorId <id> -Json` after handling every job state shown; never from job-scoped wait or status envelopes. Run `dt-job consume -CoordinatorId <id> -Seq <last_event_seq>`.

## Bootstrap and context

- Managed resumes follow `managed-resume.md`: compact rulebook and the managed-resume authority read contract first, then mark bootstrap at once. A `dt-build-lean` bridge defers canonical-chain reads to their actions. New starts read the mandatory CLAUDE.md chain, MEMORY.md and governing references first.
- No `_build-state.md` yet? Copy `skills/dt-pipeline/templates/build-state-template.md` (runnable, cursor 0).
- Register: `dt-job register-run -CoordinatorId <id> -BuildStatePath <_build-state.md> -RunId <RUN_ID> -PinnedHost codex`. Add `-Managed` when requested. Directors register without `-CoordinatorId`; optional `-Delegate` requires a live identity.
- Director watch: record provider session identity; only that session retakes a dead director. Other sessions explicitly `delegate`. Keep a persistent run-level `dt-job status -Json` watch on `run_status`, `awaiting`, `stalled`; re-arm on expiry. When `awaiting_owner=director`, approve within authority. Raise reserved decisions in your chat per `managed-resume.md`; `delegated_to` names the director.
- Before dispatch: `dt-job mark-bootstrap -CoordinatorId <id> -Host codex`. One id; optionally `-TranscriptPath <rollout>`.
- An unmanaged interactive coordinator takes the lease after marking: `dt-job lease -Action acquire -CoordinatorId <id> -Host codex`. Each call renews it through long waits; watcher-launched coordinators already hold it.
- Every `dt-job` call with your id prints a `context:` line. States: `ok` continue; `checkpoint` reach a safe stopping point, then rotate; `rotate` rotate now.
- `ROTATE_REQUIRED` from `dt-job start` means rotate now; never retry the dispatch.
- Rotation: consume handled events, rewrite `_build-state.md` (keep the `run_status` and `last_consumed_event_seq` lines), write the run-folder handoff, `dt-job request-continuation -CoordinatorId <id> -Reason context_rotation`, `dt-job lease -Action release -CoordinatorId <id>`, then end. The watcher relaunches every rotation.
- Jobs survive rotation. Before an irreversible step run `dt-job irreversible -CoordinatorId <id> -Action begin -Operation <op>`, and `-Action end` after it; rotation waits while it is open.

## Hooks

- Managed Codex: the launcher runs Sol at full window and adds the dt-build hooks as trusted session flags. Past the soft limit each step says: hand off at the next safe point. Past the hard limit, only handoff steps. The watcher kills only as a backstop, never during an open irreversible step.
- Interactive Codex: no hooks; the limit is advisory, except that `dt-job start` refuses with `ROTATE_REQUIRED` past the hard limit. Rotate yourself per `SKILL.md` "Context discipline".
- The SessionStart bridge's lean mode changes eager reads, never authorization.

## Managed mode and relaunch

- Managed starts: register with `-Managed`, run `dt-job request-continuation -CoordinatorId <id> -Reason managed_start`; the interactive session takes no lease, and ends coordinating, then confirms the start and arms a watch (`managed-resume.md` § Launch watch).

- Relaunches verify the registration (`read-resume-record.ps1`); `dt-job finish -CoordinatorId <id>` at COMPLETE unregisters the run.
- The watcher (`<skill>/scripts/dt-build-watcher.ps1`, every 2 minutes) reconciles, starts queued jobs, and relaunches when unconsumed events wait without a live coordinator. Unconsumed triggers retry after 2/10/30 minutes, then stop; two consecutive thrash launches on unchanged checkpoints pause with one DM.
- Legacy prompts `$dt-build resume <RUN_ID> (managed coordinator <id>)`: continue as `<id>`; never run `dt-job resume`.
- Before ending each headless turn: `dt-job consume -CoordinatorId <id> -Seq <last_event_seq>` after handling `dt-job status -CoordinatorId <id> -Json`; an unconsumed trigger fails the launch.
- `DT_BUILD_COORDINATOR_ID` is launcher-only. Never export it in an interactive shell; pass `-CoordinatorId <id>` instead.
- Before power-off/reboot stops, name other builds' running jobs and finish times (`dt-job status`).
- At approval boundaries: `dt-job await-danny -CoordinatorId <id> -Operation <op> -Message "<decision>" -WaitMinutes 7.5 -CallStartedUtc <call-start-utc> -Json`, foreground tool timeout `600000`. For live directors, block with lease renewal. On `decision=approved`, read the receipt and continue in this SAME coordinator; otherwise checkpoint/end. Never re-wait or self-approve. No director returns immediately; `-AlwaysNotify` follows routing.
- Director commands: `/dt-build approve <RUN_ID> <operation>`, `/dt-build resume <RUN_ID>`. Approve promptly within authority. `approve -Decline`/`hold -Reason "<why>"` wake without approval; escalate in your chat. All operator approve/decline/hold/note/delegate/resume calls MUST use `<skill>/scripts/invoke-dt-job-control.ps1` from the loaded canonical skill link; it automatically validates target capabilities, resolved path and hash on every call. Never invoke operator controls directly on dt-job or a plugin snapshot (`scripts/dt-job-usage.md`). Follow `operator_notes`; details: `managed-resume.md`.

## Evidence

- Read only `status|wait -Json` envelopes, checking `report_verdict` and `failure_category`.
- Use `pwsh -NoProfile -File "<skill>/scripts/read-evidence.ps1" -RunFolder <run-folder> -JobId <id> -File <name>` or `-Path <file>`, with `-Lines a-b` or `-Grep <pattern>`, capped at 16 KB.
- Never read/tail/cat job output or stream logs directly. Load screenshots deliberately.
