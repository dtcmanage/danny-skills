#Requires -Version 7.0
# Confirms that a launched coordinator actually started. The session that launched a run (managed start,
# resume, or a relaunch it asked for) runs this instead of judging the launch from one quick look
# (mst-20261122: both coordinators exited 1, the watcher stopped the run, and nobody looked for 2 hours).
#
# Reads only run-folder records: launches.jsonl (the watcher's launch rows), context-baseline.json (the
# bootstrap mark), coordinator-<id>.exit.json and coordinator-<id>.log. Polls until one result:
#   started  - a coordinator launched after -SinceUtc marked bootstrap                  (exit 0)
#   exited   - a coordinator launched after -SinceUtc ended, or its launcher failed,
#              before marking bootstrap; carries the exit code and the log tail       (exit 1)
#   stopped  - the watcher stopped the run, or the run left runnable, before a start  (exit 1)
#   timeout  - none of these within -TimeoutSec                                       (exit 2)
# It changes nothing and grants nothing.
param(
    [Parameter(Mandatory)][string]$RunFolder,
    # Launches before this instant are ignored. Default: the newest run-level continuation request.
    [string]$SinceUtc,
    # Wait for this coordinator only.
    [string]$CoordinatorId,
    [int]$TimeoutSec = 600,
    [int]$PollSec = 10,
    [int]$LogTailLines = 30,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# dt-job.ps1 declares parameters with the same names; dot-sourcing it rebinds them, so keep ours.
$__RunFolder = $RunFolder
$__SinceUtc = $SinceUtc
$__CoordinatorId = $CoordinatorId
$__TimeoutSec = $TimeoutSec
$__PollSec = $PollSec
$__LogTailLines = $LogTailLines
$__Json = $Json
. (Join-Path $PSScriptRoot 'dt-job.ps1')
$RunFolder = $__RunFolder
$SinceUtc = $__SinceUtc
$CoordinatorId = $__CoordinatorId
$TimeoutSec = $__TimeoutSec
$PollSec = $__PollSec
$LogTailLines = $__LogTailLines
$Json = $__Json

$paths = Get-DtJobPaths -RunFolder $RunFolder
if (-not (Test-Path -LiteralPath $paths.Root -PathType Container)) { throw "AWAIT_USAGE: run folder not found: $RunFolder" }

function Get-AwaitSince {
    if ($SinceUtc) { return (ConvertTo-DtJobUtc $SinceUtc) }
    $request = @(Get-DtJobEvents -RunFolder $paths.Root | Where-Object { $_.job_id -eq 'run' -and $_.type -eq 'continuation_requested' } | Sort-Object { [int64]$_.seq } | Select-Object -Last 1)
    if ($request.Count -gt 0) { return (ConvertTo-DtJobUtc $request[0].ts_utc) }
    return [DateTime]::UtcNow
}

function Read-AwaitJsonLines {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(foreach ($line in ((Read-DtJobText -Path $Path) -split '\r?\n')) {
        if (-not $line.Trim()) { continue }
        try { $line | ConvertFrom-Json -ErrorAction Stop } catch { }
    })
}

function Get-AwaitLogTail {
    param([string]$Id)
    $log = Join-Path $paths.Root "coordinator-$Id.log"
    if (-not (Test-Path -LiteralPath $log)) { return [pscustomobject]@{ path = $log; tail = '' } }
    $lines = @((ConvertTo-DtJobReadableText -Text (Read-DtJobText -Path $log)) -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last $LogTailLines)
    $text = $lines -join "`n"
    if ($text.Length -gt 4000) { $text = $text.Substring($text.Length - 4000) }
    return [pscustomobject]@{ path = $log; tail = $text }
}

function Get-AwaitExit {
    param([string]$Id)
    $receipt = Join-Path $paths.Root "coordinator-$Id.exit.json"
    if (-not (Test-Path -LiteralPath $receipt)) { return $null }
    try {
        $record = Read-DtJobText -Path $receipt | ConvertFrom-Json -ErrorAction Stop
        if ($record.PSObject.Properties['coordinator_id'] -and $record.coordinator_id -cne $Id) { return $null }
        return $record
    }
    catch { return $null }
}

function Get-AwaitState {
    param([DateTime]$Since)
    $rows = @(Read-AwaitJsonLines -Path $paths.Launches)
    $launches = @($rows | Where-Object { $_.type -eq 'launch' -and $_.PSObject.Properties['launched_utc'] -and (ConvertTo-DtJobUtc $_.launched_utc) -ge $Since })
    if ($CoordinatorId) { $launches = @($launches | Where-Object { [string]$_.coordinator_id -ceq $CoordinatorId }) }
    $marks = (Get-DtJobContextBaselines -RunFolder $paths.Root).coordinators
    foreach ($launch in @($launches | Sort-Object { ConvertTo-DtJobUtc $_.launched_utc } -Descending)) {
        $id = [string]$launch.coordinator_id
        $mark = $marks.PSObject.Properties[$id]
        if ($null -ne $mark) {
            return [pscustomobject][ordered]@{ result = 'started'; coordinator_id = $id; marked_utc = $mark.Value.marked_utc; baseline_tokens = $mark.Value.baseline_tokens; detail = "coordinator $id marked bootstrap" }
        }
    }
    # No start yet: the newest failure (a launcher that failed, or a coordinator that ended unmarked) is the answer.
    foreach ($launch in @($launches | Sort-Object { ConvertTo-DtJobUtc $_.launched_utc } -Descending)) {
        $id = [string]$launch.coordinator_id
        $exit = Get-AwaitExit -Id $id
        $launcherExit = if ($launch.PSObject.Properties['launcher_exit']) { $launch.launcher_exit } else { $null }
        if ($null -ne $exit -or ($null -ne $launcherExit -and [int]$launcherExit -ne 0)) {
            $log = Get-AwaitLogTail -Id $id
            $code = if ($null -ne $exit -and $exit.PSObject.Properties['exit_code']) { $exit.exit_code } else { $null }
            $category = if ($null -ne $exit -and $exit.PSObject.Properties['failure_category']) { $exit.failure_category } else { $null }
            $why = if ($null -ne $code) { "coordinator $id exited $code before marking bootstrap" } else { "launcher for $id exited $launcherExit; no coordinator started" }
            return [pscustomobject][ordered]@{ result = 'exited'; coordinator_id = $id; exit_code = $code; launcher_exit = $launcherExit; failure_category = $category; log_path = $log.path; log_tail = $log.tail; launches_since = $launches.Count; detail = $why }
        }
    }
    $stops = @($rows | Where-Object { $_.type -eq 'stopped' -and $_.PSObject.Properties['stopped_utc'] -and (ConvertTo-DtJobUtc $_.stopped_utc) -ge $Since })
    if ($stops.Count -gt 0) {
        return [pscustomobject][ordered]@{ result = 'stopped'; coordinator_id = $null; stop_reason = [string]$stops[-1].reason; detail = "the watcher stopped the run ($($stops[-1].reason)); evidence in launches.jsonl" }
    }
    $entry = Get-DtJobRegistryEntry -RunFolder $paths.Root
    if ($null -ne $entry -and (Test-Path -LiteralPath ([string]$entry.build_state_path))) {
        $status = (Get-DtJobRunState -BuildStatePath ([string]$entry.build_state_path)).run_status
        if ($status -ne 'runnable') { return [pscustomobject][ordered]@{ result = 'stopped'; coordinator_id = $null; run_status = $status; detail = "run_status is $status" } }
    }
    $latest = @($launches | Sort-Object { ConvertTo-DtJobUtc $_.launched_utc } | Select-Object -Last 1)
    $pending = if ($latest.Count -gt 0) { "coordinator $($latest[0].coordinator_id) launched, bootstrap not marked yet" } else { 'no launch since the request yet (the watcher ticks every 2 minutes)' }
    return [pscustomobject][ordered]@{ result = 'pending'; coordinator_id = $(if ($latest.Count -gt 0) { [string]$latest[0].coordinator_id } else { $null }); detail = $pending }
}

$since = Get-AwaitSince
$started = [DateTime]::UtcNow
$deadline = $started.AddSeconds([math]::Max(0, $TimeoutSec))
while ($true) {
    $state = Get-AwaitState -Since $since
    if ($state.result -ne 'pending' -or [DateTime]::UtcNow -ge $deadline) { break }
    Start-Sleep -Seconds ([math]::Max(1, [math]::Min($PollSec, [int][math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds))))
}
if ($state.result -eq 'pending') {
    $state.result = 'timeout'
    if ($state.coordinator_id) {
        $log = Get-AwaitLogTail -Id ([string]$state.coordinator_id)
        $state | Add-Member -NotePropertyName log_path -NotePropertyValue $log.path
        $state | Add-Member -NotePropertyName log_tail -NotePropertyValue $log.tail
    }
}
$state | Add-Member -NotePropertyName run_folder -NotePropertyValue $paths.Root
$state | Add-Member -NotePropertyName since_utc -NotePropertyValue $since.ToString('o')
$state | Add-Member -NotePropertyName waited_sec -NotePropertyValue ([int]([DateTime]::UtcNow - $started).TotalSeconds)
if ($Json) { $state | ConvertTo-Json -Compress -Depth 4 }
else {
    "$($state.result): $($state.detail)"
    if ($state.PSObject.Properties['log_tail'] -and $state.log_tail) { "log $($state.log_path):"; $state.log_tail }
}
exit $(switch ($state.result) { 'started' { 0 } 'timeout' { 2 } default { 1 } })
