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
