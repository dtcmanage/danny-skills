#Requires -Version 7.0
# Model-free dt-build watcher. The dt-build-watcher scheduled task runs it every 2 minutes through
# run-hidden.vbs. For each registered run it reconciles the ledger, retries undelivered stop and approval
# DMs, then relaunches a managed coordinator only when the run is runnable, has an event past its cursor,
# and has no coordinator: none ever started, or its watcher-launched coordinator is provably gone. It never
# grants approvals and never changes run_status except to awaiting_danny after repeated failed launches.
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
# Whatever the trigger, a run gets at most this many launches in any rolling window before it stops for Danny.
$script:WatcherRunLaunchCap = 6
$script:WatcherRunLaunchWindowMin = 60
# One retry of a failed registry read, this long after the first attempt, before it counts as an error.
$script:WatcherRegistryRetryMs = 500

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

function Get-WatcherInteractiveDmSeq {
    # The trigger seq of the last delivered interactive DM, or $null when none was delivered.
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$RunId)
    $prefix = "dt-build:${RunId}:interactive:"
    $last = $null
    foreach ($row in (Get-DtJobNotifications -RunFolder $RunFolder)) {
        $key = [string]$row.key
        if (-not $key.StartsWith($prefix, [System.StringComparison]::Ordinal) -or -not (Test-DtJobNotificationDelivered $row)) { continue }
        $seq = [int64]0
        if ([int64]::TryParse($key.Substring($prefix.Length), [ref]$seq) -and ($null -eq $last -or $seq -gt $last)) { $last = $seq }
    }
    return $last
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
    $managed = [bool]$Entry.managed
    $lease = Get-DtJobLease -RunFolder $folder
    if ($null -eq $lease) {
        # A managed run with no lease file has no coordinator at all, so it goes on to a launch.
        if (-not $managed) { return [pscustomobject]@{ action = 'none'; detail = 'no coordinator lease' } }
    }
    elseif ($lease.launched_by -eq 'interactive') {
        if (-not (Test-DtJobLeaseExpired $lease $NowUtc)) { return [pscustomobject]@{ action = 'none'; detail = 'coordinator lease live' } }
        # One DM per waiting period: the next one only after the cursor passes the event behind the last one.
        $dmSeq = Get-WatcherInteractiveDmSeq -RunFolder $folder -RunId ([string]$Entry.run_id)
        if ($null -ne $dmSeq -and $state.last_consumed_event_seq -lt $dmSeq) { return [pscustomobject]@{ action = 'none'; detail = "interactive coordinator already told about event $dmSeq" } }
        return [pscustomobject]@{ action = 'notify_interactive'; trigger_seq = $trigger; detail = 'interactive coordinator idle' }
    }
    elseif ($lease.launched_by -ne 'watcher') { return [pscustomobject]@{ action = 'none'; detail = 'unknown coordinator kind' } }
    else {
        if (-not $managed) { return [pscustomobject]@{ action = 'none'; detail = 'run is not managed' } }
        $pidStart = if ($lease.PSObject.Properties['pid_start_utc']) { $lease.pid_start_utc } else { $null }
        if (Test-DtJobProcessIdentity $lease.pid $pidStart) { return [pscustomobject]@{ action = 'none'; detail = 'coordinator process alive' } }
        # A provably dead watcher-launched coordinator is not waited out to its lease expiry.
        if (-not (Test-DtJobLeaseHolderGone $lease) -and -not (Test-DtJobLeaseExpired $lease $NowUtc)) { return [pscustomobject]@{ action = 'none'; detail = 'coordinator lease live' } }
    }

    $rows = @(Get-WatcherLaunches -RunFolder $folder)
    $history = @($rows | Where-Object { [int64]$_.trigger_seq -eq $trigger })
    $attempts = @($history | Where-Object { $_.type -eq 'launch' })
    if ($attempts.Count -ge $script:WatcherMaxAttempts) {
        if (@($history | Where-Object { $_.type -eq 'stopped' }).Count -gt 0) { return [pscustomobject]@{ action = 'none'; detail = 'stopped after failed launches' } }
        return [pscustomobject]@{ action = 'stop'; stop_kind = 'retries'; trigger_seq = $trigger; detail = "$($attempts.Count) launches did not consume trigger $trigger" }
    }
    if ($attempts.Count -gt 0) {
        $delayMin = $script:WatcherRetryDelaysMin[$attempts.Count - 1]
        $due = (ConvertTo-DtJobUtc $attempts[-1].launched_utc).AddMinutes($delayMin)
        if ($NowUtc -lt $due) { return [pscustomobject]@{ action = 'none'; detail = "retry due $($due.ToString('o'))" } }
    }
    $deferred = @($rows | Where-Object { $_.type -eq 'deferred' } | Select-Object -Last 1)
    if ($deferred.Count -gt 0 -and $deferred[0].resume_after_utc -and $NowUtc -lt (ConvertTo-DtJobUtc $deferred[0].resume_after_utc)) {
        return [pscustomobject]@{ action = 'none'; detail = "both vendors blocked until $((ConvertTo-DtJobUtc $deferred[0].resume_after_utc).ToString('o'))" }
    }
    # Run-wide cap, counted from the last stop (or the re-arm a resume left when it beat a cap stop),
    # so that resume re-arms the run.
    $lastStop = -1
    for ($i = 0; $i -lt $rows.Count; $i++) { if (@('stopped', 'rearmed') -contains $rows[$i].type) { $lastStop = $i } }
    $windowStart = $NowUtc.AddMinutes(-$script:WatcherRunLaunchWindowMin)
    $recent = @($rows | Select-Object -Skip ($lastStop + 1) | Where-Object { $_.type -eq 'launch' -and (ConvertTo-DtJobUtc $_.launched_utc) -gt $windowStart })
    if ($recent.Count -ge $script:WatcherRunLaunchCap) {
        return [pscustomobject]@{ action = 'stop'; stop_kind = 'cap'; trigger_seq = $trigger; detail = "$($recent.Count) launches in the last $($script:WatcherRunLaunchWindowMin) minutes" }
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
            $resumeAfter = if ($resets.Count -gt 0) { $resets[0] } else { $null }
            $reason = "$pinned and $other blocked"
            # Record the block once; a new row only when the resume time or the reason changes.
            $last = @(Get-WatcherLaunches -RunFolder $folder | Where-Object { $_.type -eq 'deferred' } | Select-Object -Last 1)
            $lastResume = if ($last.Count -gt 0 -and $last[0].resume_after_utc) { (ConvertTo-DtJobUtc $last[0].resume_after_utc).Ticks } else { $null }
            $nextResume = if ($null -ne $resumeAfter) { $resumeAfter.Ticks } else { $null }
            if ($last.Count -eq 0 -or $lastResume -ne $nextResume -or [string]$last[0].reason -cne $reason) {
                Add-WatcherLaunch -RunFolder $folder -Record ([ordered]@{ type = 'deferred'; trigger_seq = $Decision.trigger_seq; resume_after_utc = $(if ($null -ne $resumeAfter) { $resumeAfter.ToString('o') } else { $null }); recorded_utc = $NowUtc.ToString('o'); reason = $reason })
            }
            if ($null -eq $resumeAfter) { return 'deferred: both vendors blocked, no reset time reported' }
            return "deferred until $($resumeAfter.ToString('o'))"
        }
        $chosen = $other
    }
    $coordinatorId = 'mc-{0}-{1}' -f $NowUtc.ToString('yyyyMMddHHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $launcherExit = $null
    # The launcher runs under this tick's coordinator.lock, so its lease acquire must not wait on that lock.
    $env:DT_BUILD_COORDINATOR_LOCK_HELD = $folder
    try {
        & pwsh -NoProfile -NonInteractive -File $script:WatcherLauncher -Host $chosen -RunId ([string]$Entry.run_id) -RunFolder $folder -BuildStatePath ([string]$Entry.build_state_path) -CoordinatorId $coordinatorId *> $null
        $launcherExit = $LASTEXITCODE
    }
    catch { $launcherExit = -1 }
    finally { Remove-Item Env:DT_BUILD_COORDINATOR_LOCK_HELD -ErrorAction SilentlyContinue }
    $lease = Get-DtJobLease -RunFolder $folder
    $launchedPid = if ($null -ne $lease -and $lease.coordinator_id -eq $coordinatorId) { $lease.pid } else { $null }
    # Every attempt counts toward the retry schedule, including one whose launcher failed.
    Add-WatcherLaunch -RunFolder $folder -Record ([ordered]@{ type = 'launch'; trigger_seq = $Decision.trigger_seq; host = $chosen; attempt = $Decision.attempt; launched_utc = $NowUtc.ToString('o'); pid = $launchedPid; coordinator_id = $coordinatorId; launcher_exit = $launcherExit })
    return "launched $chosen attempt $($Decision.attempt) as $coordinatorId"
}

function Invoke-WatcherStop {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)]$Decision, [Parameter(Mandatory)][DateTime]$NowUtc)
    $folder = [string]$Entry.run_folder
    # Recheck under the run lock: a resume or consume since the coordinator.lock recheck wins over the stop.
    $blocker = Invoke-DtJobLocked -RunFolder $folder -Action {
        $state = Get-DtJobRunState -BuildStatePath ([string]$Entry.build_state_path)
        if ($state.run_status -ne 'runnable') { return "run_status $($state.run_status)" }
        $last = Get-DtJobLastEventSeq -RunFolder $folder
        if ($last -ne $Decision.trigger_seq -or $state.last_consumed_event_seq -ge $Decision.trigger_seq) {
            # Danny's resume beat a cap stop: restart the cap window so the next tick does not stop the run again.
            $resumed = @(Get-DtJobEvents -RunFolder $folder | Where-Object { [int64]$_.seq -gt [int64]$Decision.trigger_seq -and $_.type -eq 'continuation_requested' -and $_.PSObject.Properties['reason'] -and $_.reason -eq 'resume' })
            if ($Decision.stop_kind -eq 'cap' -and $resumed.Count -gt 0) {
                Add-WatcherLaunch -RunFolder $folder -Record ([ordered]@{ type = 'rearmed'; trigger_seq = $Decision.trigger_seq; rearmed_utc = $NowUtc.ToString('o'); reason = "resume at event $($resumed[-1].seq) beat the cap stop" })
            }
            return "event $last, cursor $($state.last_consumed_event_seq)"
        }
        Set-DtJobRunState -BuildStatePath ([string]$Entry.build_state_path) -RunStatus 'awaiting_danny'
        return $null
    }
    if ($blocker) { return "changed under run lock: $blocker" }
    Add-WatcherLaunch -RunFolder $folder -Record ([ordered]@{ type = 'stopped'; trigger_seq = $Decision.trigger_seq; stopped_utc = $NowUtc.ToString('o'); reason = $Decision.stop_kind })
    $runId = [string]$Entry.run_id
    if ($Decision.stop_kind -eq 'cap') {
        $text = "dt-build run $runId is paused: the watcher started $($script:WatcherRunLaunchCap) coordinators within $($script:WatcherRunLaunchWindowMin) minutes and the run still has unhandled work. Evidence is in $folder (launches.jsonl). After checking, restart it with: /dt-build resume $runId"
        $key = "dt-build:${runId}:launch-cap:$($Decision.trigger_seq)"
    }
    else {
        $text = "dt-build run $runId is paused: the watcher started a fresh coordinator $($script:WatcherMaxAttempts) times and none picked up the work. Evidence is in $folder (launches.jsonl). After checking, restart it with: /dt-build resume $runId"
        $key = "dt-build:${runId}:launch-failed:$($Decision.trigger_seq)"
    }
    # A failed delivery stays pending and is retried on later ticks until it lands.
    $alert = Send-DtJobRunAlert -RunFolder $folder -Key $key -Message $text -RetryUntilDelivered
    return "stopped ($($Decision.stop_kind)); alert $alert"
}

function Invoke-WatcherContextRotation {
    # Codex runs no hooks, so a managed Codex coordinator past its hard limit is ended here, within one
    # tick: kill its process tree, release its lease, and request a continuation so the relaunch rules
    # start a fresh one. Its jobs are detached and keep running. Claude coordinators are left to their
    # hooks, and an irreversible step this coordinator opened defers the kill. A kill that leaves the
    # process running changes nothing and tells Danny once. Returns a detail string, or $null when idle.
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][DateTime]$NowUtc)
    $folder = [string]$Entry.run_folder
    $lease = Get-DtJobLease -RunFolder $folder
    if ($null -eq $lease -or $lease.launched_by -ne 'watcher' -or -not $lease.PSObject.Properties['host'] -or $lease.host -ne 'codex') { return $null }
    if ($lease.PSObject.Properties['released_utc'] -and $lease.released_utc) { return $null }
    $pidStart = if ($lease.PSObject.Properties['pid_start_utc']) { $lease.pid_start_utc } else { $null }
    if (-not (Test-DtJobProcessIdentity $lease.pid $pidStart)) { return $null }
    $coordinatorId = [string]$lease.coordinator_id
    $entryBaseline = Get-DtJobContextBaseline -RunFolder $folder -CoordinatorId $coordinatorId
    if ($null -eq $entryBaseline) { return $null }
    try { $tokens = Get-DtCtxTokens -TranscriptHost 'codex' -TranscriptPath ([string]$entryBaseline.transcript_path) }
    catch { return "context unreadable for $coordinatorId" }
    $report = Get-DtCtxState -Tokens $tokens -Baseline ([long]$entryBaseline.baseline_tokens)
    if ($report.state -ne 'rotate') { return $null }
    $open = @((Split-DtCtxIrreversibleSteps -Open @(Get-DtJobIrreversibleOpen -RunFolder $folder) -Lease $lease).deferring)
    if ($open.Count -gt 0) { return "rotation deferred: $coordinatorId at $tokens past hard $($report.hard), irreversible $($open[0].operation) open" }
    # The coordinator's descendants (the codex process under the wrapper), snapshotted before the kill so
    # each one's exit can be confirmed by pid and start time.
    $descendants = @(Get-WatcherDescendantProcesses -ProcessId ([int]$lease.pid))
    $killError = $null
    try { Stop-WatcherProcessTree -ProcessId ([int]$lease.pid) }
    catch { $killError = [string]$_.Exception.Message }
    # The lease is released only once the old coordinator and every descendant are provably gone;
    # otherwise the relaunch rules would start a second coordinator beside a survivor.
    $survivors = @(@(if (Test-DtJobProcessIdentity $lease.pid $pidStart) { [int]$lease.pid }) + @($descendants | Where-Object { Test-DtJobProcessIdentity $_.pid $_.start_utc } | ForEach-Object { [int]$_.pid }))
    if ($survivors.Count -gt 0) {
        $runId = [string]$Entry.run_id
        $why = if ($killError) { " ($killError)" } else { '' }
        $pids = $survivors -join ', '
        $text = "dt-build run $runId could not be handed to a fresh coordinator: its coordinator reached its context limit and the watcher could not stop it$why. It is still running as process $pids, and the run stays with it so no second coordinator starts. Stop it with: Stop-Process -Id $pids -Force"
        $alert = Send-DtJobRunAlert -RunFolder $folder -Key "dt-build:${runId}:rotation-kill-failed:$coordinatorId" -Message $text
        return "rotation kill failed: $coordinatorId pid $pids still running$why; alert $alert"
    }
    Invoke-DtJobLocked -RunFolder $folder -Action {
        $current = Get-DtJobLease -RunFolder $folder
        if ($null -ne $current -and $current.coordinator_id -eq $coordinatorId) {
            if (-not $current.PSObject.Properties['released_utc']) { $current | Add-Member -NotePropertyName released_utc -NotePropertyValue $null }
            $current.expires_utc = $NowUtc.ToString('o')
            $current.released_utc = $NowUtc.ToString('o')
            Save-DtJobLease -RunFolder $folder -Lease $current
        }
        $state = Get-DtJobRunState -BuildStatePath ([string]$Entry.build_state_path)
        Add-DtJobEvent -RunFolder $folder -JobId 'run' -Type 'continuation_requested' -Status $state.run_status -Reason 'context_rotation'
    }
    $row = [ordered]@{ coordinator_id = $coordinatorId; tokens_at_kill = [long]$tokens; hard_limit = [long]$report.hard; overshoot = ([long]$tokens - [long]$report.hard); killed_utc = $NowUtc.ToString('o') }
    [System.IO.File]::AppendAllText((Get-DtJobPaths -RunFolder $folder).Rotations, (($row | ConvertTo-Json -Compress) + "`n"), [System.Text.UTF8Encoding]::new($false))
    return "rotated $coordinatorId at $tokens (hard $($report.hard), overshoot $($row.overshoot))"
}

function Get-WatcherDescendantProcesses {
    # Every live descendant of a process, each with its start time for an identity check later.
    param([Parameter(Mandatory)][int]$ProcessId)
    $rootStart = Get-DtJobProcessStartUtc -ProcessId $ProcessId
    if (-not $rootStart) { return @() }
    $all = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId -ErrorAction Stop)
    $found = [System.Collections.Generic.List[object]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($ProcessId)
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    [void]$seen.Add($ProcessId)
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        $parentStart = Get-DtJobProcessStartUtc -ProcessId $parent
        foreach ($child in @($all | Where-Object { [int]$_.ParentProcessId -eq $parent })) {
            $childPid = [int]$child.ProcessId
            if (-not $seen.Add($childPid)) { continue }
            $start = Get-DtJobProcessStartUtc -ProcessId $childPid
            # A child older than its parent belongs to an earlier holder of a reused pid.
            if (-not $start -or ($parentStart -and (ConvertTo-DtJobUtc $start) -lt (ConvertTo-DtJobUtc $parentStart))) { continue }
            $found.Add([pscustomobject]@{ pid = $childPid; start_utc = $start })
            $queue.Enqueue($childPid)
        }
    }
    return @($found)
}

function Stop-WatcherProcessTree {
    # Kills the process and its children and waits briefly for the exit; throws when the kill fails.
    param([Parameter(Mandatory)][int]$ProcessId)
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $process.Kill($true)
    [void]$process.WaitForExit(10000)
}

function Send-WatcherStaleIrreversibleAlerts {
    # One DM per stale irreversible step: a step left open by a coordinator that no longer holds the lease
    # defers nothing, so Danny is told once to confirm the step and clear it.
    param([Parameter(Mandatory)]$Entry)
    $folder = [string]$Entry.run_folder
    $runId = [string]$Entry.run_id
    $split = Split-DtCtxIrreversibleSteps -Open @(Get-DtJobIrreversibleOpen -RunFolder $folder) -Lease (Get-DtJobLease -RunFolder $folder)
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($step in $split.stale) {
        $operation = [string]$step.operation
        $openedUtc = if ($step.PSObject.Properties['began_utc'] -and $step.began_utc) { ConvertTo-DtJobUtc $step.began_utc } else { $null }
        $openedKey = if ($null -ne $openedUtc) { $openedUtc.ToString('o') } else { 'unknown' }
        $openedText = if ($null -ne $openedUtc) { ' opened ' + [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($openedUtc, 'Eastern Standard Time').ToString('yyyy-MM-dd HH:mm') + ' ET' } else { '' }
        $owner = if ($step.PSObject.Properties['coordinator_id'] -and $step.coordinator_id) { "coordinator $($step.coordinator_id)" } else { 'an unnamed coordinator' }
        $text = "dt-build run $runId has an irreversible step `"$operation`"$openedText by $owner, which no longer holds the run. It is still marked open but no longer holds off context limits. Check whether `"$operation`" finished, then clear it with: pwsh -NoProfile -File `"$($script:WatcherDtJob)`" irreversible -RunFolder `"$folder`" -Action end -Operation `"$operation`""
        $alert = Send-DtJobRunAlert -RunFolder $folder -Key "dt-build:${runId}:stale-irreversible:${operation}:$openedKey" -Message $text
        $results.Add([pscustomobject][ordered]@{ operation = $operation; opened_utc = $openedKey; alert = $alert })
    }
    return @($results)
}

function Invoke-WatcherRun {
    param([Parameter(Mandatory)]$Entry)
    $folder = [string]$Entry.run_folder
    if (Test-Path -LiteralPath $folder) {
        # A corrupt irreversible.json or context-baseline.json fails only its own step: the run's relaunch,
        # stop, and DM logic still runs, and the error rides on the result.
        $stepErrors = [System.Collections.Generic.List[string]]::new()
        $stale = @()
        $rotation = $null
        try { $stale = @(Send-WatcherStaleIrreversibleAlerts -Entry $Entry) }
        catch { $stepErrors.Add("stale irreversible check failed: $([string]$_.Exception.Message)") }
        try { $rotation = Invoke-WatcherContextRotation -Entry $Entry -NowUtc (Get-WatcherNow) }
        catch { $stepErrors.Add("context rotation failed: $([string]$_.Exception.Message)") }
        $result = Invoke-WatcherRunTick -Entry $Entry
        if ($null -ne $rotation) { $result | Add-Member -NotePropertyName rotation -NotePropertyValue $rotation -Force }
        if ($stale.Count -gt 0) { $result | Add-Member -NotePropertyName stale_irreversible -NotePropertyValue $stale -Force }
        if ($stepErrors.Count -gt 0) { $result | Add-Member -NotePropertyName step_errors -NotePropertyValue @($stepErrors) -Force }
        return $result
    }
    return (Invoke-WatcherRunTick -Entry $Entry)
}

function Invoke-WatcherRunTick {
    param([Parameter(Mandatory)]$Entry)
    $folder = [string]$Entry.run_folder
    $runId = [string]$Entry.run_id
    if (-not (Test-Path -LiteralPath $folder)) { return [pscustomobject]@{ run_id = $runId; action = 'none'; detail = 'run folder missing' } }
    & pwsh -NoProfile -NonInteractive -File $script:WatcherDtJob reconcile -RunFolder $folder -Json *> $null
    $reconcileExit = $LASTEXITCODE
    # Stop and approval DMs that failed to send are retried while the run still waits on Danny.
    $statePath = [string]$Entry.build_state_path
    $retried = @()
    if ((Test-Path -LiteralPath $statePath) -and (Get-DtJobRunState -BuildStatePath $statePath).run_status -eq 'awaiting_danny') {
        $retried = @(Send-DtJobPendingAlerts -RunFolder $folder)
    }
    $now = Get-WatcherNow
    $decision = Get-WatcherDecision -Entry $Entry -NowUtc $now
    if ($decision.action -eq 'none') { return [pscustomobject]@{ run_id = $runId; action = 'none'; detail = $decision.detail; reconcile_exit = $reconcileExit; pending_alerts = $retried } }
    if ($decision.action -eq 'notify_interactive') {
        # Never replace an interactive coordinator; tell Danny once per waiting period.
        $text = "dt-build run $runId has new results waiting (event $($decision.trigger_seq)) and its interactive session is idle. Reopen that session or run: /dt-build resume $runId"
        $alert = Send-DtJobRunAlert -RunFolder $folder -Key "dt-build:${runId}:interactive:$($decision.trigger_seq)" -Message $text
        return [pscustomobject]@{ run_id = $runId; action = 'notify_interactive'; detail = "alert $alert"; reconcile_exit = $reconcileExit; pending_alerts = $retried }
    }
    $lockPath = (Get-DtJobPaths -RunFolder $folder).CoordinatorLock
    try { $lock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
    catch [System.IO.IOException] { return [pscustomobject]@{ run_id = $runId; action = 'none'; detail = 'coordinator lock busy'; reconcile_exit = $reconcileExit; pending_alerts = $retried } }
    try {
        $recheck = Get-WatcherDecision -Entry $Entry -NowUtc $now
        $recheckSeq = if ($recheck.PSObject.Properties['trigger_seq']) { $recheck.trigger_seq } else { $null }
        if ($recheck.action -ne $decision.action -or $recheckSeq -ne $decision.trigger_seq) {
            return [pscustomobject]@{ run_id = $runId; action = 'none'; detail = "changed under lock: $($recheck.detail)"; reconcile_exit = $reconcileExit; pending_alerts = $retried }
        }
        $detail = if ($recheck.action -eq 'stop') { Invoke-WatcherStop -Entry $Entry -Decision $recheck -NowUtc $now } else { Invoke-WatcherLaunch -Entry $Entry -Decision $recheck -NowUtc $now }
        $action = if ($detail -like 'changed under run lock*') { 'none' } else { $recheck.action }
        return [pscustomobject]@{ run_id = $runId; action = $action; detail = $detail; reconcile_exit = $reconcileExit; pending_alerts = $retried }
    }
    finally { $lock.Dispose() }
}

function Send-WatcherRegistryAlert {
    # One DM per registry error until the registry parses again. The marker beside the registry holds the
    # error's key; a parse that succeeds deletes it, so a later failure is a new episode with a new key.
    param([Parameter(Mandatory)][string]$ErrorText, [Parameter(Mandatory)][DateTime]$NowUtc)
    $registry = Get-DtJobRegistryPath
    $marker = "$registry.error.json"
    $hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($ErrorText))).Substring(0, 12).ToLowerInvariant()
    $current = $null
    if (Test-Path -LiteralPath $marker) { try { $current = Read-DtJobText -Path $marker | ConvertFrom-Json -ErrorAction Stop } catch { $current = $null } }
    if ($null -eq $current -or [string]$current.error_hash -cne $hash) {
        $current = [pscustomobject][ordered]@{ key = "dt-build:registry-error:${hash}:$($NowUtc.ToString('yyyyMMddHHmmssfff'))"; error_hash = $hash; delivered = $false }
    }
    if ([bool]$current.delivered) { return 'already_sent' }
    $text = "dt-build watcher cannot read its run registry $registry, so no run is being watched. Error: $ErrorText. Fix or restore the file; the watcher resumes on the next tick after it parses."
    $sent = $false
    try {
        $raw = & pwsh -NoProfile -NonInteractive -File $script:DtJobAlertScript -Key ([string]$current.key) -Message $text -Json 2>$null
        $sent = [bool]((@($raw) | Where-Object { $_ } | Select-Object -Last 1) | ConvertFrom-Json).sent
    }
    catch { $sent = $false }
    $current.delivered = $sent
    Write-DtJobAtomic -Path $marker -Content ($current | ConvertTo-Json)
    if ($sent) { return 'sent' }
    return 'failed'
}

function Read-WatcherRegistry {
    # A failed registry read (a writer mid-replace, a transient lock) is retried once within the tick
    # before it counts as an error.
    try { return @(Get-DtJobRegistryRuns) }
    catch {
        Start-Sleep -Milliseconds $script:WatcherRegistryRetryMs
        return @(Get-DtJobRegistryRuns)
    }
}

# Dot-sourcing (the tests do) loads the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

try { $runs = @(Read-WatcherRegistry) }
catch {
    $registryError = [string]$_.Exception.Message
    $alert = Send-WatcherRegistryAlert -ErrorText $registryError -NowUtc (Get-WatcherNow)
    [pscustomobject]@{ run_id = $null; action = 'error'; detail = "registry unreadable: $registryError"; alert = $alert } | ConvertTo-Json -Compress
    exit 2
}
Remove-Item -LiteralPath "$(Get-DtJobRegistryPath).error.json" -Force -ErrorAction SilentlyContinue

$exitCode = 0
foreach ($entry in $runs) {
    try { $result = Invoke-WatcherRun -Entry $entry }
    catch {
        $exitCode = 1
        $result = [pscustomobject]@{ run_id = [string]$entry.run_id; action = 'error'; detail = [string]$_.Exception.Message }
    }
    $result | ConvertTo-Json -Compress
}
exit $exitCode
