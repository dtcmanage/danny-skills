# dt-job test exclusivity

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
was tried first. SNOWWHITE supports parallel work; machine-wide serialization
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
Missing or whitespace-only reasons exit 2 with `EXCLUSIVE_REASON_REQUIRED`.
Waiting diagnostics identify the caller's reason and the holder (including the
holder's recorded reason). Only opted-in commands delay their execution budget
until admission; the lock wait has its own timeout.
