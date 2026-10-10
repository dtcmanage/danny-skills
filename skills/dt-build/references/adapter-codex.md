# dt-build host adapter: Codex

Load this file only when the coordinator runs in Codex (interactive Codex CLI or `codex exec`). Other rules live in `SKILL.md`. `dt-job` below means `pwsh -NoProfile -File scripts/dt-job.ps1 -Verb <verb> -RunFolder <run-folder>`. Pass `-CoordinatorId <id>` on every `dt-job` call except `approve` and `resume`; the id checks context and renews the lease.

## Dispatch

- Resolve the worker per `SKILL.md` "Model routing" and dispatch on the returned `vendor`, either vendor.
- Launch every worker as a job: `dt-job start -CoordinatorId <id> -Kind worker -Category <category> -Vendor <vendor> -Model <model> -Mutates <worktree key> -Command "<wrapper call>"`, where the wrapper call is `scripts/invoke-codex-chunk.ps1` or `scripts/invoke-claude-chunk.ps1` with the arguments `SKILL.md` names. Add `-DependsOn <job ids>` when it must wait for other jobs. `start` returns a `job_id` at once; record it in `_build-state.md` in-flight work.
- Run long tests, builds, and browser or screenshot checks as `-Kind test` or `-Kind command` jobs too. Never run them in the coordinator's foreground.
- Never hand-roll `codex exec` or `claude -p`, and never use Codex's own subagents for chunk work.

## Waiting and completion

- Codex has no in-session completion notice. Wait in the foreground with one command: `dt-job wait -CoordinatorId <id> -JobId <job ids, comma-separated> -Any|-All -TimeoutSec <n> -Json`, with `-TimeoutSec` below the shell command timeout (for example 540 under a 600-second limit).
- On `wait_timeout`, run `dt-job reconcile -CoordinatorId <id>`, then call `dt-job wait` again for the jobs still running. Do no other work between waits.
- Never poll with repeated `status` calls, `sleep` loops, or log tails.
- A run that will wait for hours uses managed mode (below) rather than a long interactive wait.
- The ledger is the truth: run `dt-job reconcile -CoordinatorId <id>` at every coordinator start and resume, and after any `wait_timeout`.
- `wait` and `status` carry `last_event_seq` and `last_consumed_event_seq`. Consume only from run-level `dt-job status -CoordinatorId <id> -Json` after handling every job state shown; never from job-scoped wait or status envelopes. Run `dt-job consume -CoordinatorId <id> -Seq <last_event_seq>`.

## Bootstrap and context

- Do the mandatory reads (CLAUDE.md chain, MEMORY.md, governing references) first, in full.
- Register first: `dt-job register-run -CoordinatorId <id> -BuildStatePath <_build-state.md> -RunId <RUN_ID> -PinnedHost codex`. Add `-Managed` when requested.
- Then, before dispatch: `dt-job mark-bootstrap -CoordinatorId <id> -Host codex`. Use one session id, e.g. `<RUN_ID>-codex-<yyyyMMddHHmm>`. Use the starting directory or add `-TranscriptPath <this session's rollout file>`.
- An unmanaged interactive coordinator takes the lease after marking: `dt-job lease -Action acquire -CoordinatorId <id> -Host codex`. Each later call with your id, a running wait included, renews it through long waits. A watcher-launched coordinator already holds it.
- Every `dt-job` call with your id prints a `context:` line. States: `ok` continue; `checkpoint` finish the current decision and rewrite `_build-state.md`; `rotate` rotate now.
- `ROTATE_REQUIRED` from `dt-job start` means rotate now. Do not retry the dispatch.
- Rotation steps, in order: rewrite `_build-state.md` (keep the `run_status` and `last_consumed_event_seq` lines as they are), write a coordinator handoff note in the run folder, `dt-job request-continuation -CoordinatorId <id> -Reason context_rotation`, `dt-job lease -Action release -CoordinatorId <id>`, then end. Interactive: tell Danny the one command to continue in a fresh session, `$dt-build <RUN_ID>`.
- Jobs survive rotation. Before an irreversible step run `dt-job irreversible -CoordinatorId <id> -Action begin -Operation <op>`, and `-Action end` after it; rotation waits while it is open.

## Hooks

- None. Codex has no per-tool hooks, and `codex exec` runs no hooks at all.
- Interactive Codex: the context limit is advisory, except that `dt-job start` refuses with `ROTATE_REQUIRED` past the hard limit. Follow the advisory rules in `SKILL.md` "Context discipline" and rotate yourself.
- Managed Codex: the limit is enforced by the watcher. Past the hard limit it ends the headless coordinator within one tick, unless an irreversible step is open, and relaunches it per the managed rules. `dt-job start` also refuses new dispatches with `ROTATE_REQUIRED`.

## Managed mode and relaunch

- For managed starts, the interactive session registers with `-Managed`, runs `dt-job request-continuation -CoordinatorId <id> -Reason managed_start`, takes no lease, and ends; the watcher continues.

- On starts and relaunches: `dt-job register-run -CoordinatorId <id> -BuildStatePath <_build-state.md> -RunId <RUN_ID> -PinnedHost codex`. Add `-Managed` when requested. Use managed mode for long Codex runs. `dt-job finish -CoordinatorId <id>` at COMPLETE unregisters it.
- The watcher (`scripts/dt-build-watcher.ps1`, every 2 minutes) reconciles, starts queued jobs, and launches a headless coordinator when no lease exists, a managed lease is released, or its watcher-launched coordinator is gone and an unconsumed event waits. Unconsumed triggers retry at 2, 10, and 30 minutes, then stop with one DM.
- A managed coordinator's prompt reads `$dt-build resume <RUN_ID> (managed coordinator <id>)`. Continue as `<id>` (reconcile, read `_build-state.md`, carry on); never run `dt-job resume`.
- Before ending each headless turn, run `dt-job consume -CoordinatorId <id> -Seq <last_event_seq>`, from run-level `dt-job status -CoordinatorId <id> -Json` after handling every job state it shows. An unconsumed trigger counts as a failed launch.
- The launcher alone sets `DT_BUILD_COORDINATOR_ID`, for managed coordinators. Never export it in an interactive shell; pass `-CoordinatorId <id>` instead.
- At approval boundaries (merge, push, deploy, prod write, irreversible step): `dt-job await-danny -CoordinatorId <id> -Operation <op> -Message "<one line>"`, then end. Never run `dt-job approve` or `dt-job resume`; they are Danny's alone.
- Danny's commands: `/dt-build approve <RUN_ID> <operation>` records his approval and makes the run runnable; `/dt-build resume <RUN_ID>` re-arms a stopped run (`$dt-build` in place of `/dt-build` when typed in Codex). When Danny types either, run the matching `dt-job approve -Operation <operation>` or `dt-job resume`.

## Evidence

- Read job results only from `dt-job status` and `dt-job wait` envelopes (`-Json`). They cap output and name evidence paths.
- For a deeper look use `pwsh -NoProfile -File scripts/read-evidence.ps1 -RunFolder <run-folder> -Path <file> -Lines a-b` or `-Grep <pattern>`. Calls cap at 16 KB and are logged.
- Never read/tail/cat a job's output or stream log directly. Load screenshots deliberately.
