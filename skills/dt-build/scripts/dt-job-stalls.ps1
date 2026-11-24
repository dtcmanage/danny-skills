# Stall episodes are sidecars: runner record updates cannot overwrite acknowledgement or dedupe.
# All writes and decisions use the existing run lock. A stall never changes a job's lifecycle status.
function Test-DtJobCpuActivity {
    param($Cpu, $LastCpu, [double]$ElapsedSec)
    $percent = Get-DtJobSettingSec -Name 'DT_JOB_ACTIVE_CPU_PERCENT' -Default 10
    return ($null -ne $Cpu -and $null -ne $LastCpu -and ($Cpu - $LastCpu) -ge [Math]::Max(0.1, $ElapsedSec * $percent / 100))
}

function Get-DtJobStallPath {
    param([string]$RunFolder, [string]$JobId)
    Join-Path (Join-Path (Get-DtJobPaths -RunFolder $RunFolder).Jobs $JobId) 'stall.json'
}

function Get-DtJobStall {
    param([string]$RunFolder, [string]$JobId)
    $path = Get-DtJobStallPath -RunFolder $RunFolder -JobId $JobId
    if (Test-Path -LiteralPath $path) { return (Read-DtJobText -Path $path | ConvertFrom-Json) }
    return $null
}

function Save-DtJobStall {
    param([string]$RunFolder, [string]$JobId, $Stall)
    Write-DtJobAtomic -Path (Get-DtJobStallPath -RunFolder $RunFolder -JobId $JobId) -Content ($Stall | ConvertTo-Json -Depth 8)
}

function Update-DtJobStalls {
    # Caller holds run lock. Last-activity time identifies an episode, even if activity resumed
    # and stalled again between watcher ticks. An ack never moves that activity time.
    param([string]$RunFolder)
    $refresh = $false
    foreach ($record in @(Get-DtJobRecords -RunFolder $RunFolder)) {
        $stall = Get-DtJobStall -RunFolder $RunFolder -JobId $record.job_id
        $activity = if ($record.status -eq 'running') { Get-DtJobActivity -RunFolder $RunFolder -Record $record } else { $null }
        if ($stall -and (-not $activity -or -not $activity.stalled -or -not (Test-DtJobSameInstant $stall.last_activity_utc $activity.last_activity_utc))) {
            Remove-Item -LiteralPath (Get-DtJobStallPath -RunFolder $RunFolder -JobId $record.job_id)
            Add-DtJobEvent -RunFolder $RunFolder -JobId $record.job_id -Type 'job_stall_cleared' -Status $record.status -Reason 'activity resumed or job ended'
            $stall = $null; $refresh = $true
        }
        if (-not $activity -or -not $activity.stalled) { continue }
        if (-not $stall) {
            Add-DtJobEvent -RunFolder $RunFolder -JobId $record.job_id -Type 'job_stalled' -Status 'stalled' -Reason $activity.line
            $stall = [pscustomobject]@{ last_activity_utc = $activity.last_activity_utc; detected_utc = [DateTime]::UtcNow.ToString('o'); event_seq = (Get-DtJobLastEventSeq -RunFolder $RunFolder); ack = $null; ack_count = 0; stop_seq = $null }
            Save-DtJobStall -RunFolder $RunFolder -JobId $record.job_id -Stall $stall
        }
        $refresh = $true
    }
    if ($refresh) { Update-DtJobStatusLine -RunFolder $RunFolder }
}

function Get-DtJobStallFacts {
    param([string]$RunFolder, $Record)
    $activity = Get-DtJobActivity -RunFolder $RunFolder -Record $Record
    $dir = Join-Path (Get-DtJobPaths -RunFolder $RunFolder).Jobs $Record.job_id
    $spec = Read-DtJobText -Path (Join-Path $dir 'spec.json') | ConvertFrom-Json
    $cut = $false
    $command = if ($spec.command) { [string]$spec.command } else { (@($spec.script_path) + @($spec.argument_list)) -join ' ' }
    $tree = [Collections.Generic.List[object]]::new()
    $all = if ($IsWindows) { @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ id=$_.ProcessId; parent=$_.ParentProcessId } }) }
        else { @(Get-Process | ForEach-Object { try { [pscustomobject]@{ id=$_.Id; parent=$_.Parent.Id } } catch { } }) }
    # Walk only from identity-checked roots, never by a command-line substring match.
    foreach ($root in @(@{ id=$Record.pid; start=$Record.process_start_utc }, @{ id=$Record.runner_pid; start=$Record.runner_start_utc })) {
        if (-not (Test-DtJobProcessIdentity $root.id $root.start)) { continue }
        $queue = [Collections.Generic.Queue[int]]::new(); $queue.Enqueue([int]$root.id)
        $seen = [Collections.Generic.HashSet[int]]::new()
        while ($queue.Count -and $tree.Count -lt 4) {
            $id = $queue.Dequeue()
            if (-not $seen.Add($id) -or @($tree | Where-Object pid -eq $id).Count) { continue }
            try {
                $process = Get-Process -Id $id -ErrorAction Stop
                $tree.Add([ordered]@{ pid=$id; name=$process.ProcessName; command=(Limit-DtJobLine ((@(Get-DtJobProcessArguments -ProcessId $id)) -join ' ') ([ref]$cut)) })
                foreach ($child in @($all | Where-Object parent -eq $id)) { $queue.Enqueue($child.id) }
            } catch { }
        }
    }
    $stall = Get-DtJobStall -RunFolder $RunFolder -JobId $Record.job_id
    return [ordered]@{ job_id=$Record.job_id; idle_sec=$activity.idle_sec; last_activity_utc=$activity.last_activity_utc; line=$activity.line; command=(Limit-DtJobLine (Invoke-SecretRedaction -Text $command) ([ref]$cut)); last_output=(Limit-DtJobLine (((Read-DtJobTail -Path $Record.output_path -MaxLines 3).lines) -join ' | ') ([ref]$cut)); last_error=(Limit-DtJobLine (((Read-DtJobTail -Path $Record.stderr_path -MaxLines 2).lines) -join ' | ') ([ref]$cut)); process_tree=@($tree); evidence=(Join-Path $dir 'spec.json'); ack=$(if ($stall) { $stall.ack } else { $null }) }
}

function Invoke-DtJobStallAck {
    if (-not $JobId -or [string]::IsNullOrWhiteSpace($Reason)) { throw 'DT_JOB_USAGE: stall-ack requires -JobId -Reason <why> -Until <minutes>.' }
    if ($Reason.Length -gt 2000) { throw 'DT_JOB_USAGE: stall acknowledgement reason is at most 2000 characters.' }
    if ($env:DT_JOB_ID) { throw 'DT_JOB_OPERATOR_ONLY: a job cannot acknowledge its own stall.' }
    $receipt = Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        Update-DtJobStalls -RunFolder $RunFolder
        $stall = Get-DtJobStall -RunFolder $RunFolder -JobId $JobId
        if (-not $stall) { throw "DT_JOB_NOT_STALLED: $JobId" }
        $alreadyEscalated = $null -ne $stall.stop_seq
        $count = if ($stall.PSObject.Properties['ack_count']) { [int]$stall.ack_count } elseif ($stall.ack) { 1 } else { 0 }
        $stall | Add-Member -NotePropertyName ack_count -NotePropertyValue ($count + 1) -Force
        $deadline = Get-DtJobStallDeadline -Stall $stall -RequestedUtc ([DateTime]::UtcNow.AddMinutes($Until))
        $stall.ack = [pscustomobject]@{ reason=$Reason.Trim(); recorded_utc=[DateTime]::UtcNow.ToString('o'); until_utc=$deadline.ToString('o'); requested_minutes=$Until; coordinator_id=$script:DtJobCoordinator }
        Save-DtJobStall -RunFolder $RunFolder -JobId $JobId -Stall $stall
        Add-DtJobEvent -RunFolder $RunFolder -JobId $JobId -Type 'job_stall_acknowledged' -Status 'stalled' -Reason "$($stall.ack.reason); until $($stall.ack.until_utc)"
        [pscustomobject]@{ job_id=$JobId; ack=$stall.ack; already_escalated=$alreadyEscalated }
    }
    Write-DtJobOutput -Object $receipt -AsJson:$Json
}

function Get-DtJobStallDeadline {
    param($Stall, [DateTime]$RequestedUtc)
    $start = ConvertTo-DtJobUtc $Stall.last_activity_utc
    $default = $start.AddSeconds(2 * (Get-DtJobSettingSec -Name 'DT_JOB_STALL_SEC' -Default $script:DtJobStallSec))
    # Leave ten minutes for watcher cadence and run-lock latency before two hours.
    $cap = @($default.AddMinutes(70), $start.AddMinutes(110)) | Sort-Object | Select-Object -First 1
    if ($Stall.PSObject.Properties['director_limit_utc']) { $cap = ConvertTo-DtJobUtc $Stall.director_limit_utc }
    return @($RequestedUtc, $cap) | Sort-Object | Select-Object -First 1
}

function Complete-DtJobStallApproval {
    # Caller holds the run lock. Approval consumes renewals covered by this exact stop.
    param([string]$RunFolder, $Pending, [DateTime]$ApprovedUtc)
    if (-not $Pending.PSObject.Properties['stalled_jobs']) { return }
    foreach ($fact in $Pending.stalled_jobs) {
        $stall = Get-DtJobStall -RunFolder $RunFolder -JobId $fact.job_id
        if (-not $stall -or $stall.stop_seq -ne $Pending.seq -or -not $stall.ack) { continue }
        $count = if ($stall.PSObject.Properties['ack_count']) { [int]$stall.ack_count } else { 1 }
        $covered = if ($stall.PSObject.Properties['stop_ack_count']) { [int]$stall.stop_ack_count } else { $count }
        $approved = if ($stall.PSObject.Properties['approved_ack_count']) { [int]$stall.approved_ack_count } else { 0 }
        # An expired acknowledgement alone is not a keep decision. A new ack at the
        # stop, or the renewal which caused it, is explicit and may receive a new cap.
        if ($count -gt $covered -or ($count -ge 2 -and $count -gt $approved)) {
            if ((Get-DtJobStallDeadline -Stall $stall -RequestedUtc $ApprovedUtc.AddDays(1)) -le $ApprovedUtc) {
                $limit = $ApprovedUtc.AddHours(2)
                $stall | Add-Member -NotePropertyName director_limit_utc -NotePropertyValue ($limit.ToString('o')) -Force
                $minutes = if ($stall.ack.PSObject.Properties['requested_minutes']) { [double]$stall.ack.requested_minutes } else { 120 }
                $stall.ack.until_utc = (Get-DtJobStallDeadline -Stall $stall -RequestedUtc $ApprovedUtc.AddMinutes($minutes)).ToString('o')
            }
            $stall | Add-Member -NotePropertyName approved_ack_count -NotePropertyValue $count -Force
        }
        $stall | Add-Member -NotePropertyName escalated_ack_count -NotePropertyValue $count -Force
        Save-DtJobStall -RunFolder $RunFolder -JobId $fact.job_id -Stall $stall
    }
}

function Invoke-DtJobStallEscalation {
    # Independent watcher path; never needs the coordinator lock, lease or event consumption.
    param([string]$RunFolder, [string]$RunId, [string]$BuildStatePath)
    Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        Update-DtJobStalls -RunFolder $RunFolder
        if ((Get-DtJobRunState -BuildStatePath $BuildStatePath).run_status -eq 'finished') { return }
        $approvals = Get-DtJobApprovals -RunFolder $RunFolder
        $due = @()
        foreach ($record in @(Get-DtJobRecords -RunFolder $RunFolder | Where-Object status -eq 'running')) {
            $stall = Get-DtJobStall -RunFolder $RunFolder -JobId $record.job_id
            if (-not $stall) { continue }
            if ($null -ne $stall.stop_seq -and $approvals.awaiting -and $approvals.awaiting.seq -eq $stall.stop_seq) { continue }
            $requested = if ($stall.ack) { ConvertTo-DtJobUtc $stall.ack.until_utc } else { (ConvertTo-DtJobUtc $stall.last_activity_utc).AddSeconds(2 * (Get-DtJobSettingSec -Name 'DT_JOB_STALL_SEC' -Default $script:DtJobStallSec)) }
            $deadline = Get-DtJobStallDeadline -Stall $stall -RequestedUtc $requested
            $covered = if ($stall.PSObject.Properties['escalated_ack_count']) { [int]$stall.escalated_ack_count } else { 0 }
            $renewed = $stall.PSObject.Properties['ack_count'] -and [int]$stall.ack_count -ge 2 -and [int]$stall.ack_count -gt $covered
            if ($renewed -or [DateTime]::UtcNow -ge $deadline) { $due += @{ record=$record; stall=$stall } }
        }
        if (-not $due.Count) { return }
        $facts = @($due | ForEach-Object { Get-DtJobStallFacts -RunFolder $RunFolder -Record $_.record })
        $message = "Build $RunId has stalled work. " + (($facts | ForEach-Object { "$($_.line). Stuck on: $($_.command). Last output: $($_.last_output)." }) -join ' ') + ' Inspect what it waits on, then decide: cancel/fix or keep with a reason and a new deadline.'
        $pending = $approvals.awaiting
        if (-not $pending) {
            Set-DtJobRunState -BuildStatePath $BuildStatePath -RunStatus 'awaiting_danny'
            Add-DtJobEvent -RunFolder $RunFolder -JobId 'run' -Type 'awaiting_danny' -Status 'awaiting_danny' -Reason 'stalled jobs require cancel or keep decision'
            $pending = [pscustomobject]@{ operation='stalled-jobs'; message=$message; since_utc=[DateTime]::UtcNow.ToString('o'); seq=(Get-DtJobLastEventSeq -RunFolder $RunFolder) }
            $director = Get-DtJobDirector -RunFolder $RunFolder
            if (Test-DtJobDirectorAlive $director) { $pending | Add-Member -NotePropertyName delegated_to -NotePropertyValue $director.name }
            $approvals.awaiting = $pending
        } else {
            # Preserve an existing approval boundary and its authority; attach the new stop facts.
            Add-DtJobEvent -RunFolder $RunFolder -JobId 'run' -Type 'job_stall_escalated' -Status 'awaiting_danny' -Reason $message
            # A fresh delivery key exposes the new episodes even if this stop was already sent.
            $pending | Add-Member -NotePropertyName stall_notice_seq -NotePropertyValue (Get-DtJobLastEventSeq -RunFolder $RunFolder) -Force
        }
        $previous = @(if ($pending.PSObject.Properties['stalled_jobs']) { $pending.stalled_jobs })
        $jobs = [ordered]@{}
        foreach ($fact in @($previous) + $facts) { $jobs[$fact.job_id] = $fact }
        if (-not $pending.PSObject.Properties['stall_base_message']) {
            $base = if ($pending.operation -eq 'stalled-jobs') { '' } else { $pending.message }
            $pending | Add-Member -NotePropertyName stall_base_message -NotePropertyValue $base
        }
        $pending | Add-Member -NotePropertyName stalled_jobs -NotePropertyValue @($jobs.Values) -Force
        $pending.message = $pending.stall_base_message + " Build $RunId has stalled work. " + (($jobs.Values | ForEach-Object { "$($_.line). Stuck on: $($_.command). Last output: $($_.last_output)." }) -join ' ') + ' Inspect what it waits on, then decide: cancel/fix or keep with a reason and a new deadline.'
        Save-DtJobApprovals -RunFolder $RunFolder -Approvals $approvals
        foreach ($item in $due) {
            $item.stall.stop_seq = $pending.seq
            $count = if ($item.stall.PSObject.Properties['ack_count']) { [int]$item.stall.ack_count } else { 0 }
            $item.stall | Add-Member -NotePropertyName stop_ack_count -NotePropertyValue $count -Force
            $item.stall | Add-Member -NotePropertyName escalated_ack_count -NotePropertyValue $count -Force
            Save-DtJobStall -RunFolder $RunFolder -JobId $item.record.job_id -Stall $item.stall
        }
    }
    # Same route and delivery key as await, including retry and dead-director fallback.
    $null = Send-DtJobDelegateEscalation -RunFolder $RunFolder -RunId $RunId
}
