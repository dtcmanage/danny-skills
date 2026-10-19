# dt-build host adapter: Codex

Load this file only when the coordinator runs in Codex (interactive Codex CLI or `codex exec`). Other rules live in `SKILL.md`. `dt-job` below means `pwsh -NoProfile -File "<skill>/scripts/dt-job.ps1" -Verb <verb> -RunFolder <run-folder>`. Pass `-CoordinatorId <id>` on every `dt-job` call except `approve` and `resume`.

## Dispatch

- Follow `SKILL.md` routing; dispatch pinned runs without `-Model`; omit pins from handoffs.
- Launch every worker as a job: `dt-job start -CoordinatorId <id> -Kind worker -Category <category> -Vendor <vendor> -Mutates <worktree key> -Command "<wrapper call>"`, using `<skill>/scripts/invoke-codex-chunk.ps1` or `<skill>/scripts/invoke-claude-chunk.ps1`. Add `-DependsOn <job ids>` for prerequisites. Record `job_id` in `_build-state.md`.
- Run tests/builds/browser checks as `-Kind test|command` jobs.
- Never hand-roll `codex exec` or `claude -p` or use Codex subagents for chunks.

## Waiting and completion

- Watchdogs: use `dt-job status -CoordinatorId <id> -Json`, `stalled` and heartbeat/activity age; checkpoint age must never be used alone (`_build-state.md`).
- Codex has no in-session completion notice. Wait in the foreground: `dt-job wait -CoordinatorId <id> -JobId <job ids, comma-separated> -Any|-All -TimeoutSec <n> -Json`, with `-TimeoutSec` (at most 600) below the shell timeout.
- On `wait_timeout`, run `dt-job reconcile -CoordinatorId <id>`, then call `dt-job wait` again; nothing else between waits.
- Coordinators never poll with `status`, `sleep` loops, or log tails; delegate watches are separate.
- `wait_timeout` lists running jobs' `progress`. Jobs have no time limit; after 20 silent minutes (`STALLED`), check output, then cancel/retry or wait.
- Waits of hours use managed mode (below).
- The ledger is the truth: run `dt-job reconcile -CoordinatorId <id>` at every coordinator start and resume, and after any `wait_timeout`.
- `wait` and `status` carry `last_event_seq` and `last_consumed_event_seq`. Consume only from run-level `dt-job status -CoordinatorId <id> -Json` after handling every job state shown; never from job-scoped wait or status envelopes. Run `dt-job consume -CoordinatorId <id> -Seq <last_event_seq>`.

## Bootstrap and context

- Managed resumes follow `managed-resume.md`: compact rulebook and the managed-resume authority read contract first, then mark bootstrap at once. A `dt-build-lean` bridge defers canonical-chain reads to their actions. New starts read the mandatory CLAUDE.md chain, MEMORY.md and governing references first.
- No `_build-state.md` yet? Copy `skills/dt-pipeline/templates/build-state-template.md` (runnable, cursor 0).
- Register: `dt-job register-run -CoordinatorId <id> -BuildStatePath <_build-state.md> -RunId <RUN_ID> -PinnedHost codex`. Add `-Managed` when requested. Interactive launch/monitor sessions pass `-Delegate <own session name>`; headless runs omit it.
- On taking delegation (registration or `delegate`), immediately arm a persistent run-level watch: `dt-job status` with `-Json` (`run_status`, `awaiting`, `stalled`), surviving turns. When `awaiting.awaiting_owner=danny`, tell Danny the decision in your chat (`operation` and `message`), even if `alerted_danny=true`; `delegated_to` names the delegate.
- Before dispatch: `dt-job mark-bootstrap -CoordinatorId <id> -Host codex`. Use one id; optionally `-TranscriptPath <rollout>`.
- An unmanaged interactive coordinator takes the lease after marking: `dt-job lease -Action acquire -CoordinatorId <id> -Host codex`. Each call renews it through long waits; watcher-launched coordinators already hold it.
- Every `dt-job` call with your id prints a `context:` line. States: `ok` continue; `checkpoint` reach a safe stopping point, then rotate; `rotate` rotate now.
- `ROTATE_REQUIRED` from `dt-job start` means rotate now. Do not retry the dispatch.
- Rotation: consume handled events, rewrite `_build-state.md` (keep the `run_status` and `last_consumed_event_seq` lines), write the run-folder handoff, `dt-job request-continuation -CoordinatorId <id> -Reason context_rotation`, `dt-job lease -Action release -CoordinatorId <id>`, then end. Interactive: tell Danny the one command to continue in a fresh session, `$dt-build <RUN_ID>`.
- Jobs survive rotation. Before an irreversible step run `dt-job irreversible -CoordinatorId <id> -Action begin -Operation <op>`, and `-Action end` after it; rotation waits while it is open.

## Hooks

- Managed Codex: the launcher runs Sol at full window and adds the dt-build hooks as trusted session flags. Past the soft limit each step says: hand off at the next safe point. Past the hard limit, only handoff steps. The watcher kills only as a backstop, never during an open irreversible step.
- Interactive Codex: no hooks; the limit is advisory, except that `dt-job start` refuses with `ROTATE_REQUIRED` past the hard limit. Rotate yourself per `SKILL.md` "Context discipline".
- The SessionStart bridge's lean mode changes eager reads, never authorization.

## Managed mode and relaunch

- For managed starts, the interactive session registers with `-Managed`, runs `dt-job request-continuation -CoordinatorId <id> -Reason managed_start`, takes no lease, and ends; the watcher continues.

- Managed relaunches verify the existing registration through `read-resume-record.ps1`. Use managed mode for long Codex runs. `dt-job finish -CoordinatorId <id>` at COMPLETE unregisters the run.
- The watcher (`<skill>/scripts/dt-build-watcher.ps1`, every 2 minutes) reconciles, starts queued jobs, and relaunches when unconsumed events wait without a live coordinator. Unconsumed triggers retry after 2/10/30 minutes, then stop; two consecutive thrash launches on unchanged checkpoints pause with one DM.
- Legacy managed coordinator prompts read `$dt-build resume <RUN_ID> (managed coordinator <id>)`. Continue as `<id>` (reconcile, read `_build-state.md`, carry on); never run `dt-job resume`.
- Before ending each headless turn, run `dt-job consume -CoordinatorId <id> -Seq <last_event_seq>`, from run-level `dt-job status -CoordinatorId <id> -Json` after handling every job state it shows. An unconsumed trigger counts as a failed launch.
- The launcher alone sets `DT_BUILD_COORDINATOR_ID`, for managed coordinators. Never export it in an interactive shell; pass `-CoordinatorId <id>` instead.
- At approval boundaries (merge, push, deploy, prod write, irreversible): `dt-job await-danny -CoordinatorId <id> -Operation <op> -Message "<one line>"`, then end; add `-AlwaysNotify` for production, Azure or irreversible. Never run `dt-job approve`, `resume`, `delegate` or `hold`; they are Danny's.
- Danny's commands: `/dt-build approve <RUN_ID> <operation>` approves; `/dt-build resume <RUN_ID>` re-arms; `/dt-build delegate <RUN_ID> <session>` (`-Clear` undoes) routes routine stops there; a holding delegate runs `hold` (`-Operation <op> -Reason "<why>"`) so the 15-minute DM says why (`$dt-build` in place of `/dt-build` when typed in Codex). Use matching `dt-job` verbs. Follow `operator_notes`; operators add them (`note`).

## Evidence

- Read only `status|wait -Json` envelopes, checking `report_verdict` and `failure_category`.
- Use `pwsh -NoProfile -File "<skill>/scripts/read-evidence.ps1" -RunFolder <run-folder> -JobId <id> -File <name>` or `-Path <file>`, with `-Lines a-b` or `-Grep <pattern>`, capped at 16 KB.
- Never read/tail/cat job output or stream logs directly. Load screenshots deliberately.
