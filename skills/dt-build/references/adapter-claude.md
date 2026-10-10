# dt-build host adapter: Claude Code

Load this file only when the coordinator runs in Claude Code (interactive CLI, Cowork, or `claude -p`). It covers host mechanics only; everything else is in `SKILL.md`. `dt-job` below means `pwsh -NoProfile -File scripts/dt-job.ps1 -Verb <verb> -RunFolder <run-folder>`.

## Dispatch

- Resolve the worker per `SKILL.md` "Model routing" and dispatch on the returned `vendor`, either vendor.
- Launch every worker as a job: `dt-job start -Kind worker -Category <category> -Vendor <vendor> -Model <model> -Mutates <worktree key> -Command "<wrapper call>"`, where the wrapper call is `scripts/invoke-claude-chunk.ps1` or `scripts/invoke-codex-chunk.ps1` with the arguments `SKILL.md` names. Add `-DependsOn <job ids>` when it must wait for other jobs. `start` returns a `job_id` at once; record it in `_build-state.md` in-flight work.
- Run long tests, builds, and browser or screenshot checks as `-Kind test` or `-Kind command` jobs too. Never run them in the foreground of the coordinator.
- A Claude pick at the session's own effort may still use the Agent tool with the returned `agent_alias`, per `SKILL.md` "Model routing". Any other effort goes through the wrapper as a job.

## Waiting and completion

- Wait with one command: `dt-job wait -JobId <ids> -Any|-All -TimeoutSec <n> -Json`, run through the Bash tool with `run_in_background: true` and a Bash `timeout` longer than `-TimeoutSec`. Claude Code sends one notification when it exits, for every terminal state. End the turn after starting it.
- Never use CronCreate (forbidden in a dt-build coordinator), Monitor heartbeats, `sleep` loops, repeated `status` calls, or any self-scheduled check.
- On `wait_timeout`, run `dt-job reconcile`, then start one new background wait for the jobs still running.
- The ledger is the truth, not the notification: run `dt-job reconcile` at every coordinator start and resume, and after any `wait_timeout`.

## Bootstrap and context

- Do the mandatory reads (CLAUDE.md chain, MEMORY.md, governing references) first, in full.
- Then, once and before any dispatch: `dt-job mark-bootstrap -CoordinatorId <id> -Host claude`. Pick `<id>` once per session, for example `<RUN_ID>-claude-<yyyyMMddHHmm>`, and reuse it. Run it from the directory the session started in; if you changed directory, add `-TranscriptPath <this session's transcript>`.
- An interactive coordinator takes the lease after marking: `dt-job lease -Action acquire -CoordinatorId <id> -Host claude`. A managed coordinator already holds it.
- Managed coordinators see a `context:` line on every `dt-job` call. Interactive sessions see it from the PostToolUse hook once the hooks are installed. States: `ok` continue; `checkpoint` finish the current decision and rewrite `_build-state.md`; `rotate` rotate now.
- `ROTATE_REQUIRED` from `dt-job start` means rotate now. Do not retry the dispatch.
- Rotation steps, in order: rewrite `_build-state.md` (keep the `run_status` and `last_consumed_event_seq` lines as they are), write a coordinator handoff note in the run folder, `dt-job request-continuation -Reason context_rotation`, `dt-job lease -Action release -CoordinatorId <id>`, then end. Interactive: tell Danny the one command to continue in a fresh session, `/dt-build <RUN_ID>`.
- Jobs keep running across rotation. Before an irreversible step run `dt-job irreversible -Action begin -Operation <op>`, and `-Action end` after it; rotation waits while it is open.

## Hooks

- Two hooks ship in `hooks/` and are installed only at adoption, into the live settings file named in `hooks/README.md`.
- In a coordinator session the PreToolUse hook denies a Read of a file over 400 lines without a range, image Reads, and CronCreate. Past the hard context limit it also denies direct reads, searches, web tools, Agent, and every shell command except the dt-build state scripts and `git status|log|rev-parse`. The deny reason names the next step: follow it.
- The PostToolUse hook surfaces the `context:` line at `checkpoint` and `rotate`.
- Managed Claude coordinators get both hooks through the `--settings` file the launcher writes.

## Managed mode and relaunch

- Register every run at start: `dt-job register-run -BuildStatePath <_build-state.md> -RunId <RUN_ID> -PinnedHost claude`, adding `-Managed` only when Danny asked for a managed run. `dt-job finish` at COMPLETE unregisters it.
- In managed mode the watcher (`scripts/dt-build-watcher.ps1`, every 2 minutes) reconciles jobs, starts queued ones, and relaunches a headless coordinator it launched once that one is gone and an unconsumed event waits. A launch that leaves its trigger unconsumed is retried at 2, 10, and 30 minutes, then the run stops with one DM.
- A managed coordinator's prompt reads `/dt-build resume <RUN_ID> (managed coordinator <id>)`. It means: continue the run as coordinator `<id>` (reconcile, read `_build-state.md`, carry on), never run `dt-job resume`.
- Only the launcher sets `DT_BUILD_COORDINATOR_ID`, for managed coordinators. Never export it in an interactive shell.
- At an approval boundary (merge, push, deploy, prod write, irreversible step): `dt-job await-danny -Operation <op> -Message "<one line>"`, then end. Never run `dt-job approve` or `dt-job resume`; they are operator-only and refuse a coordinator.
- Danny's commands: `/dt-build approve <RUN_ID> <operation>` records his approval and makes the run runnable; `/dt-build resume <RUN_ID>` re-arms a stopped run. When Danny types either, run the matching `dt-job approve -Operation <operation>` or `dt-job resume`.

## Evidence

- Read job results only from `dt-job status -JobId <id> -Json` and `dt-job wait ... -Json`. Envelopes are capped and name their evidence paths.
- For a deeper look use `pwsh -NoProfile -File scripts/read-evidence.ps1 -RunFolder <run-folder> -Path <file> -Lines a-b` or `-Grep <pattern>`. Each call is capped at 16 KB and logged.
- Never Read, tail, or cat a job's output or stream log directly. Load a screenshot only when you deliberately need it.
