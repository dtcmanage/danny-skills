#Requires -Version 7.0
# Background status watch for the session that launched or delegates a dt-build run (build-process.md,
# "Watch a dt-build run with a background wait"). Run it with Bash run_in_background: true; it polls the
# run's records quietly and exits only when something needs that session:
#   run_status     - run_status changed (awaiting Danny, finished, back to runnable)       (exit 0)
#   awaiting       - a stop or approval boundary appeared or changed                       (exit 0)
#   job_failed     - a job ended failed, timed out, orphaned (worker death) or blocked     (exit 0)
#   stalled        - a running job newly went 20 minutes without output                    (exit 0)
#   coordinator    - the coordinator died holding the run, overran its starting window,
#                    or the runnable run has had no coordinator for -NoCoordinatorSec       (exit 0)
#   finished       - the run left the registry                                             (exit 0)
#   quiet          - nothing changed within -TimeoutSec: re-arm the watch                  (exit 2)
# A normal rotation (released, then a new coordinator starting) is not a change. Read-only.
param(
    [Parameter(Mandatory)][string]$RunFolder,
    [int]$TimeoutSec = 3300,
    [int]$PollSec = 30,
    # A runnable run whose coordinator is missing or released longer than this wakes the watch.
    [int]$NoCoordinatorSec = 600,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# dt-job.ps1 declares parameters with the same names; dot-sourcing it rebinds them, so keep ours.
$__RunFolder = $RunFolder
$__TimeoutSec = $TimeoutSec
$__PollSec = $PollSec
$__NoCoordinatorSec = $NoCoordinatorSec
$__Json = $Json
. (Join-Path $PSScriptRoot 'dt-job.ps1')
$RunFolder = $__RunFolder
$TimeoutSec = $__TimeoutSec
$PollSec = $__PollSec
$NoCoordinatorSec = $__NoCoordinatorSec
$Json = $__Json

$paths = Get-DtJobPaths -RunFolder $RunFolder
if (-not (Test-Path -LiteralPath $paths.Root -PathType Container)) { throw "WATCH_USAGE: run folder not found: $RunFolder" }

function Get-WatchSnapshot {
    $entry = Get-DtJobRegistryEntry -RunFolder $paths.Root
    $status = $null
    $awaiting = $null
    if ($null -ne $entry -and (Test-Path -LiteralPath ([string]$entry.build_state_path))) {
        $status = (Get-DtJobRunState -BuildStatePath ([string]$entry.build_state_path)).run_status
        if ($status -eq 'awaiting_danny') {
            $pending = (Get-DtJobApprovals -RunFolder $paths.Root).awaiting
            if ($null -ne $pending) { $awaiting = "$($pending.operation)#$(if ($pending.PSObject.Properties['seq']) { $pending.seq })" }
        }
    }
    $jobs = @{}
    $stalled = [System.Collections.Generic.List[string]]::new()
    foreach ($record in @(Get-DtJobRecords -RunFolder $paths.Root)) {
        $jobs[[string]$record.job_id] = [string]$record.status
        if ($record.status -eq 'running') {
            try { if ((Get-DtJobActivity -RunFolder $paths.Root -Record $record).stalled) { $stalled.Add([string]$record.job_id) } } catch { }
        }
    }
    return [pscustomobject]@{ registered = ($null -ne $entry); run_status = $status; awaiting = $awaiting; jobs = $jobs; stalled = @($stalled); coordinator = (Get-DtJobCoordinatorSummary -RunFolder $paths.Root) }
}

function Get-WatchChange {
    param($Before, $Now, $NoCoordinatorSince)
    if ($Before.registered -and -not $Now.registered) { return [pscustomobject]@{ reason = 'finished'; detail = 'the run is no longer registered (finished or unregistered)' } }
    if ($Before.run_status -ne $Now.run_status) { return [pscustomobject]@{ reason = 'run_status'; detail = "run_status $($Before.run_status) -> $($Now.run_status)" } }
    if ($Now.awaiting -and $Before.awaiting -ne $Now.awaiting) { return [pscustomobject]@{ reason = 'awaiting'; detail = "awaiting $($Now.awaiting)" } }
    foreach ($id in $Now.jobs.Keys) {
        $was = if ($Before.jobs.ContainsKey($id)) { $Before.jobs[$id] } else { $null }
        $is = $Now.jobs[$id]
        if ($was -ne $is -and $is -in @('failed', 'timeout', 'orphaned', 'blocked')) { return [pscustomobject]@{ reason = 'job_failed'; detail = "job $id is $is" } }
    }
    $newStalled = @($Now.stalled | Where-Object { $Before.stalled -notcontains $_ })
    if ($newStalled.Count -gt 0) { return [pscustomobject]@{ reason = 'stalled'; detail = "job(s) stalled: $($newStalled -join ', ')" } }
    $c = $Now.coordinator
    if ($c.state -in @('gone', 'boot_overdue') -and ($Before.coordinator.state -ne $c.state -or $Before.coordinator.coordinator_id -ne $c.coordinator_id)) {
        return [pscustomobject]@{ reason = 'coordinator'; detail = "coordinator $($c.coordinator_id) is $($c.state)" }
    }
    if ($Now.run_status -eq 'runnable' -and $null -ne $NoCoordinatorSince -and ([DateTime]::UtcNow - $NoCoordinatorSince).TotalSeconds -ge $NoCoordinatorSec) {
        return [pscustomobject]@{ reason = 'coordinator'; detail = "runnable run has had no live coordinator ($($c.state)) for $([int]([DateTime]::UtcNow - $NoCoordinatorSince).TotalMinutes) minutes" }
    }
    return $null
}

$started = [DateTime]::UtcNow
$deadline = $started.AddSeconds([math]::Max(0, $TimeoutSec))
$baseline = Get-WatchSnapshot
$noCoordinatorSince = $null
$change = $null
while ($true) {
    $now = Get-WatchSnapshot
    if ($now.coordinator.state -in @('none', 'released', 'expired')) { if ($null -eq $noCoordinatorSince) { $noCoordinatorSince = [DateTime]::UtcNow } }
    else { $noCoordinatorSince = $null }
    $change = Get-WatchChange -Before $baseline -Now $now -NoCoordinatorSince $noCoordinatorSince
    if ($null -ne $change -or [DateTime]::UtcNow -ge $deadline) { break }
    Start-Sleep -Seconds ([math]::Max(1, [math]::Min($PollSec, [int][math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds))))
}
if ($null -eq $change) { $change = [pscustomobject]@{ reason = 'quiet'; detail = "no change in $TimeoutSec seconds; re-arm the watch" } }
$out = [pscustomobject][ordered]@{
    reason = $change.reason
    detail = $change.detail
    run_folder = $paths.Root
    run_status = $now.run_status
    awaiting = $now.awaiting
    coordinator = $now.coordinator
    stalled = @($now.stalled)
    waited_sec = [int]([DateTime]::UtcNow - $started).TotalSeconds
}
if ($Json) { $out | ConvertTo-Json -Compress -Depth 4 } else { "$($out.reason): $($out.detail)" }
exit $(if ($out.reason -eq 'quiet') { 2 } else { 0 })
