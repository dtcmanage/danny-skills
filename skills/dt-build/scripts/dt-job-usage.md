# dt-job test exclusivity

The examples below are PowerShell blocks: on the Linux session host start `pwsh -NoProfile` first, then paste them.

## Durable run folders

For ad-hoc jobs outside a dt-build run, use `<project root>/.dt-build/adhoc/`
as `-RunFolder`, and gitignore `.dt-build/` in the project. New run folders
under the OS temp root, `TEMP`, or `TMP` are refused with
`DT_JOB_TEMP_RUN_FOLDER`. `-AllowTempRunFolder` explicitly opts into temporary
storage, for example for test fixtures. Existing temp run folders remain usable;
`start` prints one stderr warning unless the switch is passed. Other verbs,
including status, wait, reconcile, cancel, notes and evidence reads, keep working.
The creation guard also applies to other verbs that create a run folder.

To migrate an existing temp run, wait until no jobs are running; do not stop
running jobs for the move. Copy the whole run folder to the project's
`.dt-build/adhoc/` folder, preserving every file and subfolder, then use that
destination as `-RunFolder`. Ledger-owned stdout, stderr and summary paths follow
the copied run folder. Job execution references in the spec/command retain their
absolute paths; those paths stay valid after the copy. Keep any external
prompt, script and output files at their referenced paths.

## After a crash or reboot

Reconcile the saved ledger, then relaunch the interrupted job from its stored
spec. The new job has a new ID; its spec, start event and JSON status record
`relaunched_from` with the old ID. A job that is still running is refused with
`DT_JOB_FROMJOB_RUNNING`.

```powershell
cd "<project root>"
$dtJob = "<repo>/skills/dt-build/scripts/dt-job.ps1"
$run = Join-Path (Get-Location) '.dt-build/adhoc'
pwsh -NoProfile -File $dtJob reconcile -RunFolder $run -Json
pwsh -NoProfile -File $dtJob start -RunFolder $run -FromJob j-0001 -Json
```

`-FromJob` reads `spec.json` from the same run folder and preserves the command
or script arguments, environment, working directory, dependencies and job metadata.
Explicit start parameters override copied values. Optional `-PromptPath` and
`-OutputPath` replace the corresponding exact arguments in the command, including
quoted values. An override with no matching argument fails with
`DT_JOB_FROMJOB_NO_ARG`; it never appends an argument or alters a similarly named
argument. For example:

```powershell
cd "<project root>"
pwsh -NoProfile -File $dtJob start -RunFolder $run -FromJob j-0001 -PromptPath "<new prompt path>" -OutputPath "<new output path>" -Json
```

## Dependency chains and requeue

`start -DependsOn <job-id>` records a queued job. It starts when every dependency
succeeds; any other terminal dependency state marks it blocked. Multiple IDs may
be supplied as a comma-separated list.

Copy-paste example, from the project checkout (replace the two paths):

```powershell
cd "<project path>"
$dtJob = "<repo>/skills/dt-build/scripts/dt-job.ps1"
$run = "<run folder>"
$upstream = pwsh -NoProfile -File $dtJob start -RunFolder $run -Kind command -Command 'Write-Output upstream' -Json | ConvertFrom-Json
$downstream = pwsh -NoProfile -File $dtJob start -RunFolder $run -Kind command -Command 'Write-Output downstream' -DependsOn $upstream.job_id -Json | ConvertFrom-Json
pwsh -NoProfile -File $dtJob wait -RunFolder $run -JobId $downstream.job_id -TimeoutSec 3600 -Json
```

`requeue -JobId <id>` accepts only blocked or cancelled jobs. It creates a new
queued job with the original spec, working directory, metadata and dependencies;
the original record remains terminal. Creation and scheduling hold the run lock.
Pass `-DependsOn` to replace dependencies, including an empty list to clear them
when invoking the script in-process. A satisfied dependency may launch the new
job immediately. To restart a blocked chain after rerunning its upstream:

```powershell
cd "<project path>"
$retryUpstream = pwsh -NoProfile -File $dtJob start -RunFolder $run -Kind command -Command 'Write-Output upstream-retry' -Json | ConvertFrom-Json
$retryDownstream = pwsh -NoProfile -File $dtJob requeue -RunFolder $run -JobId $downstream.job_id -DependsOn $retryUpstream.job_id -Json | ConvertFrom-Json
pwsh -NoProfile -File $dtJob wait -RunFolder $run -JobId $retryDownstream.job_id -TimeoutSec 3600 -Json
```

For further links, requeue each blocked job against the newly returned predecessor
ID. Failed jobs are rerun with `start`; `requeue` preserves the blocked/cancelled
consumer's spec rather than reconstructing it from chat.

## Test exclusivity

Jobs run directly by default, including pytest jobs. `start -ExclusiveReason "<text>"`
sets the optional string `exclusive_reason` in `spec.json`, the job record and
the start/status receipt. Only a nonempty, non-whitespace string opts into
`scripts/pytest-lock.py`; omitted, empty and whitespace values run directly.

Use exclusivity only for a named suite with a documented reason: state what
breaks under overlap, cite observed evidence, and describe the workaround that
was tried first. The build host (CT202 on mothership, which grows cores and memory on demand) supports parallel work; machine-wide serialization
is never a standing rule.

Example (replace the illustrative reason with actual suite evidence):

```powershell
cd "<project path>"
pwsh -NoProfile -File "<repo>/skills/dt-build/scripts/dt-job.ps1" start -RunFolder "<run folder>" -Kind test -Command 'python -m pytest tests/device_suite' -ExclusiveReason 'device_suite: both runs overwrite device slot 1 (log evidence); separate temp directories did not isolate the device' -Json
```

Acceptance verification entries may carry the optional `exclusive_reason`
column in the roadmap verification table. It applies to the commands in that
entry, uses the same policy, and is retained in each command result. Leave the
column absent for ordinary parallel-safe suites. Blank cells must be preserved
when parsing a table containing this optional column.

For direct use, `pytest-lock.py --reason "<text>" -- <command>` or
`pytest-lock.ps1 -Reason "<text>" <command>` requires the same reason.
The PowerShell adapter uses the shared test-Python resolver: `DANNY_SKILLS_TEST_PYTHON`, then the host's standard build-test venv (automatically provisioned with uv), then PATH. It prepends the selected interpreter's directory to PATH for child commands; it never installs into system Python.
Missing or whitespace-only reasons exit 2 with `EXCLUSIVE_REASON_REQUIRED`.
Waiting diagnostics identify the caller's reason and the holder (including the
holder's recorded reason). Only opted-in commands delay their execution budget
until admission; the lock wait has its own timeout.

## Evidence notes

Use `note -Evidence` for facts that grant no authority. Status and wait show these
separately with the label "Evidence only: records facts, grants no authority."
Authorization language is refused; changes to what the run may do belong in a
normal operator note without `-Evidence`. Only operators may add or clear either
class. Each note is capped at 2,000 characters.

```powershell
cd "<project path>"
$dtJob = "<repo>/skills/dt-build/scripts/dt-job.ps1"
$run = "<run folder>"
pwsh -NoProfile -File $dtJob note -RunFolder $run -Evidence -Message 'The fixture test recorded 42 passing checks.' -Json
pwsh -NoProfile -File $dtJob status -RunFolder $run -Json
pwsh -NoProfile -File $dtJob note -RunFolder $run -Evidence -Clear -NoteId e-001 -Json
pwsh -NoProfile -File $dtJob note -RunFolder $run -Evidence -Clear -Json
```

Clearing evidence notes leaves operator notes intact.

# Worktree ownership and activity

Declare `-Writes` to reserve a job's Git worktree across run folders. Reservations are opt-in: existing parallel shards keep running without extra flags. A second declared writer stays queued until the holder finishes or is cancelled/reconciled; every status, wait poll and reconcile pass retries its own run's queue. Completion releases the reservation, and missing/archived holder records count as released. Guard timeout leaves the waiter queued with a reason. A dead running holder keeps the waiter queued until its holder run is reconciled. A queued holder with a dead/expired coordinator lease is released after a locked recheck, with a recovery event identifying the holder and run. Unreadable reservations still fail with `DT_JOB_WORKTREE_STALE` and require investigation. Reservations live under `DT_BUILD_STATE_DIR/worktrees`, or `~/.local/state/dt-job/worktrees`. Use `-WorkingTree <path>` when the target differs from the launch directory. `-ReadOnly` and `-Writes` are mutually exclusive. Explicit `-Mutates` keys still apply to every job. Retries preserve these declarations. Heartbeats count process-tree CPU and job output for all jobs, and worktree changes only for declared writers.

Heartbeats watch the resolved worktree, excluding the run folder's own ledger writes. Linux CPU activity includes descendants from `/proc`, including CPU of waited-for children.

Lifecycle events automatically refresh checkpoint `status_line` under the run lock, showing running jobs, waiting count, and the latest event. Checkpoint writes derive that line again from the latest ledger event so an older coordinator snapshot cannot restore stale job status. Keep milestone intent and next steps in the checkpoint body.

## Waiting at an approval boundary

Coordinators call `await-danny -CoordinatorId <id> -Operation <op> -Message "<decision>" -WaitMinutes 7.5 -CallStartedUtc <call-start-utc> -Json` with tool timeout `600000`. Default/max wait is 7.5 minutes from caller start (0 disables it; fractional minutes are supported). Only the current unreleased lease holder with a live director waits. The blocking call polls without model turns and renews its lease. A matching live waiter lets operator `approve` apply immediately; `decision=approved` means continue in the same coordinator after reading the receipt and reason. No continuation request or relaunch is emitted for that approval. Other live coordinators retain queued approval until exit.

Operator `approve -Decline -Reason "<why>"` returns `decision=declined` to the waiter and leaves the boundary stopped. `hold -Reason "<decision awaiting Danny>"` wakes it with `decision=held`; raise the reserved decision in the director chat. Neither grants permission. No live director, its death, timeout (`decision=unanswered`), or replacement boundary (`superseded`) means checkpoint and end as before. Do not re-wait a boundary. A later approval uses the normal relaunch flow; no timeout escalates a live director. Waiter identity, boundary sequence, process start time and deadline fence immediate approval. Coordinator/job self-approval guards still apply.

Capture `CallStartedUtc` before launching PowerShell (bash: `-CallStartedUtc "$(date -u +%FT%TZ)"`; PowerShell: `-CallStartedUtc ([DateTime]::UtcNow)`). Startup and lock waits consume this budget; run-lock acquisition is capped at caller start + 7.75 minutes, leaving return margin below eight minutes. A missing argument uses PowerShell process start time for compatibility. Dead coordinator identity invalidates its helper immediately; approval then requests continuation.

## Stalls and escalation

`DT_JOB_STALL_SEC` defaults to 1200 (20 minutes); `DT_JOB_HEARTBEAT_SEC` remains 30. Progress requires novel output, declared-writer file changes or CPU averaging 10% of one core (`DT_JOB_ACTIVE_CPU_PERCENT`) across 80% of a five-minute window. Novel lines cover 90 seconds; timestamps, retry numbers, IDs and durations do not disguise repeats. Changing N/M, N of M and N% counters count as progress. Recent normalized lines expire after two hours, capped oldest-first at 10,000. Brief bursts preserve the confirmed progress clock, first stall and acknowledgements, so periodic chatter still escalates at 40 minutes, within two hours. Sampling never kills jobs.

A stalled job retains its running lifecycle record and appears in the envelope's `stalled` list and checkpoint `status_line`. One `job_stalled` event is appended per episode. Sustained progress clears the episode, acknowledgement, and dedupe; another stall emits another event. `wait` returns `result=stalled` immediately for any watched unacknowledged or expired stall, with capped command, output/error tails, activity time, and process tree in `stalled`. Full evidence remains under the job directory.

Inspect its dependency and cancel/fix, or run `stall-ack -JobId <id> -Reason "<dependency and reason to keep>" -Until <minutes>` (minutes from now, 0.01–1440, default 20). Coordinators include `-CoordinatorId`. Jobs cannot acknowledge themselves. Cap the deadline at the default stop plus 70 minutes and at 110 minutes since activity, allowing watcher/lock latency. Each renewal forces one stop; approval covers it until its deadline. An explicit keep after the cap grants the requested duration, at most two hours from approval. Expiry escalates again. Acknowledgement suppresses wait interruption until its deadline, never hiding the stall.

The two-minute watcher independently raises `stalled-jobs` through the normal director route at twice the stall period, acknowledgement expiry or renewal. Existing boundaries retain their authority and receive deduplicated facts and a fresh delivery key per escalation. No coordinator action or coordinator lock is required. Acknowledging does not approve a stop; the director decides cancel/fix or keep and approves. Sustained progress clears the episode without approving an existing stop.

Quiet I/O-bound work (under 10% CPU with little output), such as a database wait or `docker pull`, receives a director stop at 40 minutes by default and needs one acknowledgement to keep waiting. This stops the run for a decision; it never kills the job. The acknowledgement remains bounded as above.

Retry/wait words anywhere in a line cause all numbers outside explicit N/M, N of M or N% counters to normalize as repeats. This includes attempt numbers in `waiting for db (attempt 37)`. Bare `waiting 3 jobs remaining` or `waiting 3 left` may repeat; report a total as `waiting 3 of 40 remaining` or `waiting 3/40 left` to retain progress. Long decimal byte/row counts remain progress outside retry/wait lines; hexadecimal IDs require a `0x` prefix or an a-f letter.

The output-copy helper reuses its type when already loaded in the runner process; a fresh PowerShell process still compiles it once.

A hung loop can evade detection by burning enough CPU to satisfy the recovery window: roughly 4.5 minutes of qualifying CPU every 15 minutes can reset the confirmed clock before escalation. CPU measures work, not useful progress; investigate such loops independently.
