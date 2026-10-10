#Requires -Version 7.0
# Model-free dt-build watcher. The dt-build-watcher scheduled task runs it every 2 minutes through
# run-hidden.vbs. For each registered run it reconciles the ledger, then relaunches a managed
# coordinator only when the run is runnable, has an event past its cursor, and its watcher-launched
# coordinator is provably gone. It never grants approvals and never changes run_status except to
# awaiting_danny after repeated failed launches.
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'dt-job.ps1')

$script:WatcherDtJob = Join-Path $PSScriptRoot 'dt-job.ps1'
$script:WatcherLauncher = if ($env:DT_BUILD_COORDINATOR_LAUNCHER) { $env:DT_BUILD_COORDINATOR_LAUNCHER } else { Join-Path $PSScriptRoot 'launch-managed-coordinator.ps1' }
$script:WatcherVendorLimits = if ($env:DT_BUILD_VENDOR_LIMITS_SCRIPT) { $env:DT_BUILD_VENDOR_LIMITS_SCRIPT } else { Join-Path $PSScriptRoot '..\..\..\scripts\model-router\vendor-limits.ps1' }
# A launch that exits without consuming its trigger is retried 2, 10, then 30 minutes after the
# previous attempt; when the last retry also fails, the run stops for Danny.
$script:WatcherRetryDelaysMin = @(2, 10, 30)
$script:WatcherMaxAttempts = $script:WatcherRetryDelaysMin.Count + 1

function Get-WatcherNow {
    if ($env:DT_BUILD_WATCHER_NOW_UTC) { return (ConvertTo-DtJobUtc $env:DT_BUILD_WATCHER_NOW_UTC) }
    return [DateTime]::UtcNow
}

function Get-WatcherLaunches {
    param([Parameter(Mandatory)][string]$RunFolder)
    $path = (Get-DtJobPaths -RunFolder $RunFolder).Launches
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ((Read-DtJobText -Path $path) -split "\r?\n")) {
        if (-not $line.Trim()) { continue }
        try { $rows.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { }
    }
    return @($rows)
}

function Add-WatcherLaunch {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)]$Record)
    $path = (Get-DtJobPaths -RunFolder $RunFolder).Launches
    [System.IO.File]::AppendAllText($path, (($Record | ConvertTo-Json -Compress) + "`n"), [System.Text.UTF8Encoding]::new($false))
}

function Get-WatcherDecision {
    # Pure read: what this tick should do for one run. Called once unlocked and again under the coordinator lock.
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][DateTime]$NowUtc)
    $folder = [string]$Entry.run_folder
    $statePath = [string]$Entry.build_state_path
    if (-not (Test-Path -LiteralPath $statePath)) { return [pscustomobject]@{ action = 'none'; detail = 'build state missing' } }
    $state = Get-DtJobRunState -BuildStatePath $statePath
    if ($state.run_status -ne 'runnable') { return [pscustomobject]@{ action = 'none'; detail = "run_status $($state.run_status)" } }
    $trigger = Get-DtJobLastEventSeq -RunFolder $folder
    if ($trigger -le $state.last_consumed_event_seq) { return [pscustomobject]@{ action = 'none'; detail = 'no unconsumed event' } }
    $lease = Get-DtJobLease -RunFolder $folder
    if ($null -eq $lease) { return [pscustomobject]@{ action = 'none'; detail = 'no coordinator lease' } }
    if (-not (Test-DtJobLeaseExpired $lease $NowUtc)) { return [pscustomobject]@{ action = 'none'; detail = 'coordinator lease live' } }
    if ($lease.launched_by -eq 'interactive') { return [pscustomobject]@{ action = 'notify_interactive'; trigger_seq = $trigger; detail = 'interactive coordinator idle' } }
    if ($lease.launched_by -ne 'watcher') { return [pscustomobject]@{ action = 'none'; detail = 'unknown coordinator kind' } }
    if (-not [bool]$Entry.managed) { return [pscustomobject]@{ action = 'none'; detail = 'run is not managed' } }
    if (-not $lease.pid) { return [pscustomobject]@{ action = 'none'; detail = 'watcher lease has no pid' } }
    $pidStart = if ($lease.PSObject.Properties['pid_start_utc']) { $lease.pid_start_utc } else { $null }
    if (Test-DtJobProcessIdentity $lease.pid $pidStart) { return [pscustomobject]@{ action = 'none'; detail = 'coordinator process alive' } }

    $history = @(Get-WatcherLaunches -RunFolder $folder | Where-Object { [int64]$_.trigger_seq -eq $trigger })
    $attempts = @($history | Where-Object { $_.type -eq 'launch' })
    if ($attempts.Count -ge $script:WatcherMaxAttempts) {
        if (@($history | Where-Object { $_.type -eq 'stopped' }).Count -gt 0) { return [pscustomobject]@{ action = 'none'; detail = 'stopped after failed launches' } }
        return [pscustomobject]@{ action = 'stop'; trigger_seq = $trigger; detail = "$($attempts.Count) launches did not consume trigger $trigger" }
    }
    if ($attempts.Count -gt 0) {
        $delayMin = $script:WatcherRetryDelaysMin[$attempts.Count - 1]
        $due = (ConvertTo-DtJobUtc $attempts[-1].launched_utc).AddMinutes($delayMin)
        if ($NowUtc -lt $due) { return [pscustomobject]@{ action = 'none'; detail = "retry due $($due.ToString('o'))" } }
    }
    $deferred = @($history | Where-Object { $_.type -eq 'deferred' } | Select-Object -Last 1)
    if ($deferred.Count -gt 0 -and $NowUtc -lt (ConvertTo-DtJobUtc $deferred[0].resume_after_utc)) {
        return [pscustomobject]@{ action = 'none'; detail = "both vendors blocked until $((ConvertTo-DtJobUtc $deferred[0].resume_after_utc).ToString('o'))" }
    }
    return [pscustomobject]@{ action = 'launch'; trigger_seq = $trigger; attempt = $attempts.Count + 1; detail = "trigger $trigger" }
}

function Get-WatcherVendorState {
    # A failed limits read counts as not blocked: the pinned host is tried rather than stalling the run.
    param([Parameter(Mandatory)][string]$Vendor)
    try {
        $raw = & pwsh -NoProfile -NonInteractive -File $script:WatcherVendorLimits -Vendor $Vendor -Json 2>$null
        $parsed = (@($raw) | Where-Object { $_ } | Select-Object -Last 1) | ConvertFrom-Json
        return [pscustomobject]@{ blocked = [bool]$parsed.blocked; resets_at_utc = $parsed.resets_at_utc }
    }
    catch { return [pscustomobject]@{ blocked = $false; resets_at_utc = $null } }
}

function Invoke-WatcherLaunch {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)]$Decision, [Parameter(Mandatory)][DateTime]$NowUtc)
    $folder = [string]$Entry.run_folder
    $pinned = [string]$Entry.pinned_host
    $other = if ($pinned -eq 'claude') { 'codex' } else { 'claude' }
    $chosen = $pinned
    $pinnedState = Get-WatcherVendorState -Vendor $pinned
    if ($pinnedState.blocked) {
        $otherState = Get-WatcherVendorState -Vendor $other
        if ($otherState.blocked) {
            $resets = @(@($pinnedState.resets_at_utc, $otherState.resets_at_utc) | Where-Object { $_ } | ForEach-Object { ConvertTo-DtJobUtc $_ } | Sort-Object)
            $resumeAfter = if ($resets.Count -gt 0) { $resets[0] } else { $NowUtc.AddMinutes($script:WatcherRetryDelaysMin[0]) }
            Add-WatcherLaunch -RunFolder $folder -Record ([ordered]@{ type = 'deferred'; trigger_seq = $Decision.trigger_seq; resume_after_utc = $resumeAfter.ToString('o'); recorded_utc = $NowUtc.ToString('o'); reason = "$pinned and $other blocked" })
            return "deferred until $($resumeAfter.ToString('o'))"
        }
        $chosen = $other
    }
    $coordinatorId = 'mc-{0}-{1}' -f $NowUtc.ToString('yyyyMMddHHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $launcherExit = $null
    try {
        & pwsh -NoProfile -NonInteractive -File $script:WatcherLauncher -Host $chosen -RunId ([string]$Entry.run_id) -RunFolder $folder -BuildStatePath ([string]$Entry.build_state_path) -CoordinatorId $coordinatorId *> $null
        $launcherExit = $LASTEXITCODE
    }
    catch { $launcherExit = -1 }
    $lease = Get-DtJobLease -RunFolder $folder
    $launchedPid = if ($null -ne $lease -and $lease.coordinator_id -eq $coordinatorId) { $lease.pid } else { $null }
    # Every attempt counts toward the retry schedule, including one whose launcher failed.
    Add-WatcherLaunch -RunFolder $folder -Record ([ordered]@{ type = 'launch'; trigger_seq = $Decision.trigger_seq; host = $chosen; attempt = $Decision.attempt; launched_utc = $NowUtc.ToString('o'); pid = $launchedPid; coordinator_id = $coordinatorId; launcher_exit = $launcherExit })
    return "launched $chosen attempt $($Decision.attempt) as $coordinatorId"
}

function Invoke-WatcherStop {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)]$Decision, [Parameter(Mandatory)][DateTime]$NowUtc)
    $folder = [string]$Entry.run_folder
    Invoke-DtJobLocked -RunFolder $folder -Action {
        Set-DtJobRunState -BuildStatePath ([string]$Entry.build_state_path) -RunStatus 'awaiting_danny'
    }
    Add-WatcherLaunch -RunFolder $folder -Record ([ordered]@{ type = 'stopped'; trigger_seq = $Decision.trigger_seq; stopped_utc = $NowUtc.ToString('o') })
    $runId = [string]$Entry.run_id
    $text = "dt-build run $runId is paused: the watcher started a fresh coordinator $($script:WatcherMaxAttempts) times and none picked up the work. Evidence is in $folder (launches.jsonl). After checking, restart it with: /dt-build resume $runId"
    $alert = Send-DtJobRunAlert -RunFolder $folder -Key "dt-build:${runId}:launch-failed:$($Decision.trigger_seq)" -Message $text
    return "stopped after failed launches; alert $alert"
}

function Invoke-WatcherRun {
    param([Parameter(Mandatory)]$Entry)
    $folder = [string]$Entry.run_folder
    $runId = [string]$Entry.run_id
    if (-not (Test-Path -LiteralPath $folder)) { return [pscustomobject]@{ run_id = $runId; action = 'none'; detail = 'run folder missing' } }
    & pwsh -NoProfile -NonInteractive -File $script:WatcherDtJob reconcile -RunFolder $folder -Json *> $null
    $reconcileExit = $LASTEXITCODE
    $now = Get-WatcherNow
    $decision = Get-WatcherDecision -Entry $Entry -NowUtc $now
    if ($decision.action -eq 'none') { return [pscustomobject]@{ run_id = $runId; action = 'none'; detail = $decision.detail; reconcile_exit = $reconcileExit } }
    if ($decision.action -eq 'notify_interactive') {
        # Never replace an interactive coordinator; tell Danny once per trigger.
        $text = "dt-build run $runId has new results waiting (event $($decision.trigger_seq)) and its interactive session is idle. Reopen that session or run: /dt-build resume $runId"
        $alert = Send-DtJobRunAlert -RunFolder $folder -Key "dt-build:${runId}:interactive:$($decision.trigger_seq)" -Message $text
        return [pscustomobject]@{ run_id = $runId; action = 'notify_interactive'; detail = "alert $alert"; reconcile_exit = $reconcileExit }
    }
    $lockPath = (Get-DtJobPaths -RunFolder $folder).CoordinatorLock
    try { $lock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
    catch [System.IO.IOException] { return [pscustomobject]@{ run_id = $runId; action = 'none'; detail = 'coordinator lock busy'; reconcile_exit = $reconcileExit } }
    try {
        $recheck = Get-WatcherDecision -Entry $Entry -NowUtc $now
        if ($recheck.action -ne $decision.action -or $recheck.trigger_seq -ne $decision.trigger_seq) {
            return [pscustomobject]@{ run_id = $runId; action = 'none'; detail = "changed under lock: $($recheck.detail)"; reconcile_exit = $reconcileExit }
        }
        $detail = if ($recheck.action -eq 'stop') { Invoke-WatcherStop -Entry $Entry -Decision $recheck -NowUtc $now } else { Invoke-WatcherLaunch -Entry $Entry -Decision $recheck -NowUtc $now }
        return [pscustomobject]@{ run_id = $runId; action = $recheck.action; detail = $detail; reconcile_exit = $reconcileExit }
    }
    finally { $lock.Dispose() }
}

$exitCode = 0
foreach ($entry in (Get-DtJobRegistryRuns)) {
    try { $result = Invoke-WatcherRun -Entry $entry }
    catch {
        $exitCode = 1
        $result = [pscustomobject]@{ run_id = [string]$entry.run_id; action = 'error'; detail = [string]$_.Exception.Message }
    }
    $result | ConvertTo-Json -Compress
}
exit $exitCode
