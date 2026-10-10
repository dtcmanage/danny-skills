#Requires -Version 7.0
param(
    [ValidateSet('start', 'status', 'cancel', 'reconcile')]
    [string]$Verb,

    [string]$RunFolder,

    [string]$JobId,

    [string]$Command,

    [string]$ScriptPath,

    [string[]]$ArgumentList = @(),

    [ValidateSet('worker', 'test', 'command')]
    [string]$Kind = 'command',

    [string[]]$DependsOn = @(),

    [string[]]$Mutates = @(),

    [string]$Category,

    [string]$Vendor,

    [string]$Model,

    [int]$TimeoutSec = 0,

    [string]$RunId,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DtJobStatuses = @('queued', 'running', 'succeeded', 'failed', 'timeout', 'orphaned', 'cancelled', 'blocked')
$script:DtJobActive = @('queued', 'running')
$script:DtJobEnvelopeMaxBytes = 8192
$script:DtJobLineMaxChars = 400
$script:DtJobExcerptLines = 40
$script:DtJobLaunchGraceSec = 60
$script:DtJobLockDepth = 0
$script:DtJobLockStream = $null
$script:DtJobRunnerPath = Join-Path $PSScriptRoot 'dt-job-runner.ps1'

function Get-DtJobPaths {
    param([Parameter(Mandatory)][string]$RunFolder)
    $root = [System.IO.Path]::GetFullPath($RunFolder).TrimEnd('\', '/')
    $jobs = Join-Path $root 'jobs'
    [pscustomobject]@{
        Root   = $root
        Jobs   = $jobs
        Locks  = Join-Path $jobs 'locks'
        Events = Join-Path $jobs 'events.jsonl'
        RunLock = Join-Path (Join-Path $jobs 'locks') 'run.lock'
    }
}

function Test-DtJobTerminal {
    param([string]$Status)
    return ($script:DtJobActive -notcontains $Status)
}

function Write-DtJobAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $directory = Split-Path -Parent $Path
    if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($tempPath, $Content, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($tempPath, $Path, $true)
}

function Invoke-DtJobLocked {
    # One writer at a time: every ledger transition runs inside this per-run lock.
    # The OS releases the handle if the holder dies, so the run lock never goes stale.
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][scriptblock]$Action, [int]$LockTimeoutSec = 120)
    $paths = Get-DtJobPaths -RunFolder $RunFolder
    if ($script:DtJobLockDepth -eq 0) {
        New-Item -ItemType Directory -Path $paths.Locks -Force | Out-Null
        $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSec)
        while ($true) {
            try {
                $script:DtJobLockStream = [System.IO.File]::Open($paths.RunLock, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                break
            }
            catch [System.IO.IOException] {
                if ([DateTime]::UtcNow -gt $deadline) { throw "DT_JOB_LOCK_TIMEOUT: $($paths.RunLock)" }
                Start-Sleep -Milliseconds (Get-Random -Minimum 20 -Maximum 80)
            }
        }
    }
    $script:DtJobLockDepth++
    try {
        & $Action
    }
    finally {
        $script:DtJobLockDepth--
        if ($script:DtJobLockDepth -eq 0 -and $null -ne $script:DtJobLockStream) {
            $script:DtJobLockStream.Dispose()
            $script:DtJobLockStream = $null
        }
    }
}

function Get-DtJobRecord {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$JobId)
    $path = Join-Path (Get-DtJobPaths -RunFolder $RunFolder).Jobs "$JobId.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
}

function Get-DtJobRecords {
    param([Parameter(Mandatory)][string]$RunFolder)
    $jobsDir = (Get-DtJobPaths -RunFolder $RunFolder).Jobs
    if (-not (Test-Path -LiteralPath $jobsDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $jobsDir -File -Filter 'j-*.json' | Sort-Object Name | ForEach-Object {
        Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json
    })
}

function Save-DtJobRecord {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)]$Record)
    $path = Join-Path (Get-DtJobPaths -RunFolder $RunFolder).Jobs "$($Record.job_id).json"
    Write-DtJobAtomic -Path $path -Content ($Record | ConvertTo-Json -Depth 8)
}

function Add-DtJobEvent {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$JobId, [Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)][string]$Status, [string]$Reason)
    $eventsPath = (Get-DtJobPaths -RunFolder $RunFolder).Events
    $seq = 1
    if (Test-Path -LiteralPath $eventsPath) {
        $last = @([System.IO.File]::ReadAllLines($eventsPath) | Where-Object { $_.Trim() }) | Select-Object -Last 1
        if ($last) { $seq = [int64](($last | ConvertFrom-Json).seq) + 1 }
    }
    $evt = [ordered]@{ seq = $seq; job_id = $JobId; ts_utc = [DateTime]::UtcNow.ToString('o'); type = $Type; status = $Status }
    if ($Reason) { $evt.reason = $Reason }
    [System.IO.File]::AppendAllText($eventsPath, (($evt | ConvertTo-Json -Compress) + "`n"), [System.Text.UTF8Encoding]::new($false))
}

function Set-DtJobState {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)]$Record, [Parameter(Mandatory)][string]$Status, [Parameter(Mandatory)][string]$EventType, [string]$Reason)
    $Record.status = $Status
    if ($PSBoundParameters.ContainsKey('Reason')) { $Record.status_reason = $Reason }
    if ((Test-DtJobTerminal $Status) -and -not $Record.ended) { $Record.ended = [DateTime]::UtcNow.ToString('o') }
    Save-DtJobRecord -RunFolder $RunFolder -Record $Record
    Add-DtJobEvent -RunFolder $RunFolder -JobId $Record.job_id -Type $EventType -Status $Status -Reason $Reason
}

function Get-DtJobKeyLockPath {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$Key)
    $safe = ($Key -replace '[^A-Za-z0-9._-]', '_')
    if ($safe.Length -gt 48) { $safe = $safe.Substring(0, 48) }
    $hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Key))).Substring(0, 12).ToLowerInvariant()
    return (Join-Path (Get-DtJobPaths -RunFolder $RunFolder).Locks "key-$safe-$hash.lock")
}

function Get-DtJobKeyHolder {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$Key)
    $path = Get-DtJobKeyLockPath -RunFolder $RunFolder -Key $Key
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json).job_id
}

function Remove-DtJobKeyLocks {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)]$Record)
    foreach ($key in @($Record.mutates)) {
        $path = Get-DtJobKeyLockPath -RunFolder $RunFolder -Key $key
        if ((Test-Path -LiteralPath $path) -and (Get-DtJobKeyHolder -RunFolder $RunFolder -Key $key) -eq $Record.job_id) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

function Get-DtJobProcessStartUtc {
    param([int]$ProcessId)
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return $process.StartTime.ToUniversalTime().ToString('o')
    }
    catch { return $null }
}

function ConvertTo-DtJobUtc {
    # ConvertFrom-Json turns ISO strings into DateTime; normalize either form to UTC.
    param($Value)
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    return [DateTime]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Test-DtJobProcessIdentity {
    # A PID counts only when its start time matches the recorded one; this defeats PID reuse.
    param($ProcessId, $StartUtc)
    if (-not $ProcessId -or -not $StartUtc) { return $false }
    $actual = Get-DtJobProcessStartUtc -ProcessId ([int]$ProcessId)
    return ($null -ne $actual -and (ConvertTo-DtJobUtc $actual).Ticks -eq (ConvertTo-DtJobUtc $StartUtc).Ticks)
}

function Test-DtJobAlive {
    param([Parameter(Mandatory)]$Record)
    if (Test-DtJobProcessIdentity $Record.pid $Record.process_start_utc) { return $true }
    if (Test-DtJobProcessIdentity $Record.runner_pid $Record.runner_start_utc) { return $true }
    if (-not $Record.pid -and -not $Record.runner_start_utc -and $Record.started) {
        $age = ([DateTime]::UtcNow - (ConvertTo-DtJobUtc $Record.started)).TotalSeconds
        return ($age -lt $script:DtJobLaunchGraceSec)
    }
    return $false
}

function Stop-DtJobProcesses {
    param([Parameter(Mandatory)]$Record)
    foreach ($pair in @(@($Record.runner_pid, $Record.runner_start_utc), @($Record.pid, $Record.process_start_utc))) {
        if (Test-DtJobProcessIdentity $pair[0] $pair[1]) {
            try { (Get-Process -Id ([int]$pair[0]) -ErrorAction Stop).Kill($true) } catch { }
        }
    }
}

function Start-DtJobRunner {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)]$Record)
    $paths = Get-DtJobPaths -RunFolder $RunFolder
    $pwsh = [System.Environment]::ProcessPath
    $workDir = [string]$Record.working_directory
    if ($IsWindows) {
        # Win32_Process.Create starts the runner outside the caller's process tree and job object,
        # hidden, so the job outlives the coordinator and never flashes a console.
        $commandLine = "`"$pwsh`" -NoProfile -NonInteractive -WindowStyle Hidden -File `"$($script:DtJobRunnerPath)`" -RunFolder `"$($paths.Root)`" -JobId $($Record.job_id)"
        $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $workDir; ProcessStartupInformation = $startup }
        if ($result.ReturnValue -ne 0) { throw "DT_JOB_LAUNCH_FAILED: Win32_Process.Create returned $($result.ReturnValue)" }
        $runnerPid = [int]$result.ProcessId
    }
    else {
        $process = Start-Process -FilePath $pwsh -WorkingDirectory $workDir -PassThru -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $script:DtJobRunnerPath, '-RunFolder', $paths.Root, '-JobId', $Record.job_id)
        $runnerPid = $process.Id
    }
    return [pscustomobject]@{ pid = $runnerPid; start_utc = (Get-DtJobProcessStartUtc -ProcessId $runnerPid) }
}

function Invoke-DtJobSchedule {
    # Under the run lock: propagate blocked to a fixed point, then launch every eligible queued job in id order.
    param([Parameter(Mandatory)][string]$RunFolder)
    Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $changed = $true
        while ($changed) {
            $changed = $false
            $byId = @{}
            foreach ($r in (Get-DtJobRecords -RunFolder $RunFolder)) { $byId[$r.job_id] = $r }
            foreach ($r in $byId.Values | Sort-Object job_id) {
                if ($r.status -ne 'queued') { continue }
                foreach ($dep in @($r.depends_on)) {
                    $d = $byId[$dep]
                    if ($null -eq $d) { continue }
                    if ((Test-DtJobTerminal $d.status) -and $d.status -ne 'succeeded') {
                        Set-DtJobState -RunFolder $RunFolder -Record $r -Status 'blocked' -EventType 'blocked' -Reason "dependency $dep $($d.status)"
                        $changed = $true
                        break
                    }
                }
            }
        }
        $records = @(Get-DtJobRecords -RunFolder $RunFolder)
        $byId = @{}
        foreach ($r in $records) { $byId[$r.job_id] = $r }
        foreach ($r in $records) {
            if ($r.status -ne 'queued') { continue }
            $depsDone = $true
            foreach ($dep in @($r.depends_on)) {
                if ($null -eq $byId[$dep] -or $byId[$dep].status -ne 'succeeded') { $depsDone = $false; break }
            }
            if (-not $depsDone) { continue }
            $keysFree = $true
            foreach ($key in @($r.mutates)) {
                $holder = Get-DtJobKeyHolder -RunFolder $RunFolder -Key $key
                if ($holder -and $holder -ne $r.job_id) { $keysFree = $false; break }
            }
            if (-not $keysFree) { continue }
            foreach ($key in @($r.mutates)) {
                Write-DtJobAtomic -Path (Get-DtJobKeyLockPath -RunFolder $RunFolder -Key $key) -Content ([ordered]@{ key = $key; job_id = $r.job_id; acquired_utc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress)
            }
            $r.started = [DateTime]::UtcNow.ToString('o')
            $r.last_progress = $r.started
            try {
                $runner = Start-DtJobRunner -RunFolder $RunFolder -Record $r
                $r.runner_pid = $runner.pid
                $r.runner_start_utc = $runner.start_utc
                Set-DtJobState -RunFolder $RunFolder -Record $r -Status 'running' -EventType 'launched'
            }
            catch {
                Remove-DtJobKeyLocks -RunFolder $RunFolder -Record $r
                Set-DtJobState -RunFolder $RunFolder -Record $r -Status 'failed' -EventType 'launch_failed' -Reason ([string]$_.Exception.Message)
            }
        }
    }
}

function Limit-DtJobLine {
    param([AllowNull()][string]$Text, [ref]$Truncated)
    if ($null -eq $Text) { return $null }
    if ($Text.Length -le $script:DtJobLineMaxChars) { return $Text }
    $Truncated.Value = $true
    return $Text.Substring(0, $script:DtJobLineMaxChars - 15) + ' ...[truncated]'
}

function Read-DtJobTail {
    param([Parameter(Mandatory)][string]$Path, [int]$MaxLines, [int]$MaxBytes = 65536)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ lines = @(); more = $false } }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $start = [Math]::Max(0, $stream.Length - $MaxBytes)
        [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin)
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
    }
    finally { $stream.Dispose() }
    $lines = @($text -split "\r?\n")
    if ($start -gt 0 -and $lines.Count -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
    while ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines | Select-Object -SkipLast 1) }
    $more = ($start -gt 0) -or ($lines.Count -gt $MaxLines)
    return [pscustomobject]@{ lines = @($lines | Select-Object -Last $MaxLines); more = $more }
}

function Read-DtJobListFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @([System.IO.File]::ReadAllLines($Path) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-DtJobEnvelopeBytes {
    param($Envelope)
    return [System.Text.Encoding]::UTF8.GetByteCount(($Envelope | ConvertTo-Json -Depth 8 -Compress))
}

function New-DtJobEnvelope {
    # Bounded result: at most 8 KB in total, every line at most 400 characters, and a
    # truncation marker plus the full-file evidence path whenever anything is cut.
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)]$Record)
    $paths = Get-DtJobPaths -RunFolder $RunFolder
    $jobDir = Join-Path $paths.Jobs $Record.job_id
    $stdout = Join-Path $jobDir 'stdout.log'
    $stderr = Join-Path $jobDir 'stderr.log'
    $changedPath = Join-Path $jobDir 'changed-files.txt'
    $blockersPath = Join-Path $jobDir 'blockers.txt'
    $cut = $false
    $cutPaths = [System.Collections.Generic.List[string]]::new()

    $verdict = switch ($Record.status) { 'succeeded' { 'pass' } 'queued' { 'pending' } 'running' { 'pending' } default { 'fail' } }
    $blockers = [System.Collections.Generic.List[string]]::new()
    if ($Record.status_reason -and $verdict -eq 'fail') { $blockers.Add((Limit-DtJobLine ([string]$Record.status_reason) ([ref]$cut))) }
    foreach ($line in (Read-DtJobListFile $blockersPath)) {
        $before = $cut; $blockers.Add((Limit-DtJobLine $line ([ref]$cut))); if ($cut -and -not $before) { $cutPaths.Add($blockersPath) }
    }
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Read-DtJobListFile $changedPath)) {
        $before = $cut; $changed.Add((Limit-DtJobLine $line ([ref]$cut))); if ($cut -and -not $before) { $cutPaths.Add($changedPath) }
    }
    $tail = Read-DtJobTail -Path $stdout -MaxLines $script:DtJobExcerptLines
    $excerpt = [System.Collections.Generic.List[string]]::new()
    $excerptCut = [bool]$tail.more
    foreach ($line in $tail.lines) { $excerpt.Add((Limit-DtJobLine $line ([ref]$excerptCut))) }

    $evidence = [ordered]@{ job_file = (Join-Path $paths.Jobs "$($Record.job_id).json"); stdout = $stdout; stderr = $stderr }
    if (Test-Path -LiteralPath $changedPath) { $evidence.changed_files = $changedPath }
    if (Test-Path -LiteralPath $blockersPath) { $evidence.blockers = $blockersPath }

    $envelope = [ordered]@{
        job_id        = $Record.job_id
        status        = $Record.status
        verdict       = $verdict
        exit_code     = $Record.exit_code
        status_reason = (Limit-DtJobLine ([string]$Record.status_reason) ([ref]$cut))
        changed_files = $changed
        blockers      = $blockers
        evidence      = $evidence
        excerpt       = $excerpt
        truncated     = $false
        truncated_evidence = $cutPaths
    }
    if ($excerptCut) { $cutPaths.Add($stdout) }
    while ((Get-DtJobEnvelopeBytes $envelope) -gt $script:DtJobEnvelopeMaxBytes -and $excerpt.Count -gt 0) {
        $excerpt.RemoveAt(0)
        if (-not $cutPaths.Contains($stdout)) { $cutPaths.Add($stdout) }
    }
    while ((Get-DtJobEnvelopeBytes $envelope) -gt $script:DtJobEnvelopeMaxBytes -and $changed.Count -gt 0) {
        $changed.RemoveAt($changed.Count - 1)
        if (-not $cutPaths.Contains($changedPath)) { $cutPaths.Add($changedPath) }
    }
    while ((Get-DtJobEnvelopeBytes $envelope) -gt $script:DtJobEnvelopeMaxBytes -and $blockers.Count -gt 0) {
        $blockers.RemoveAt($blockers.Count - 1)
        if (-not $cutPaths.Contains($blockersPath)) { $cutPaths.Add($blockersPath) }
    }
    $envelope.truncated = ($cut -or $cutPaths.Count -gt 0)
    return [pscustomobject]$envelope
}

function New-DtJobRunEnvelope {
    param([Parameter(Mandatory)][string]$RunFolder)
    $paths = Get-DtJobPaths -RunFolder $RunFolder
    $cut = $false
    $jobs = [System.Collections.Generic.List[object]]::new()
    foreach ($r in (Get-DtJobRecords -RunFolder $RunFolder)) {
        $jobs.Add([ordered]@{ job_id = $r.job_id; kind = $r.kind; status = $r.status; exit_code = $r.exit_code; status_reason = (Limit-DtJobLine ([string]$r.status_reason) ([ref]$cut)) })
    }
    $envelope = [ordered]@{ run_folder = $paths.Root; job_count = $jobs.Count; jobs = $jobs; evidence = [ordered]@{ jobs_dir = $paths.Jobs; events = $paths.Events }; truncated = $false }
    while ((Get-DtJobEnvelopeBytes $envelope) -gt $script:DtJobEnvelopeMaxBytes -and $jobs.Count -gt 0) {
        $jobs.RemoveAt($jobs.Count - 1)
        $cut = $true
    }
    $envelope.truncated = $cut
    return [pscustomobject]$envelope
}

function Write-DtJobOutput {
    param($Object, [switch]$AsJson)
    if ($AsJson) { $Object | ConvertTo-Json -Depth 8 -Compress }
    else { $Object }
}

function Invoke-DtJobStart {
    $paths = Get-DtJobPaths -RunFolder $RunFolder
    if ([string]::IsNullOrWhiteSpace($Command) -eq [string]::IsNullOrWhiteSpace($ScriptPath)) {
        throw 'DT_JOB_USAGE: start takes exactly one of -Command or -ScriptPath.'
    }
    $spec = [ordered]@{ command = $null; script_path = $null; argument_list = @($ArgumentList); timeout_sec = $TimeoutSec }
    if ($Command) { $spec.command = $Command; $identity = $Command }
    else {
        $spec.script_path = [System.IO.Path]::GetFullPath($ScriptPath)
        $identity = (@($spec.script_path) + @($ArgumentList)) -join "`n"
    }
    $commandSha = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
    $resolvedRunId = if ($RunId) { $RunId } else { Split-Path -Leaf $paths.Root }
    New-Item -ItemType Directory -Path $paths.Locks -Force | Out-Null

    $id = Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $existing = @(Get-DtJobRecords -RunFolder $RunFolder)
        foreach ($dep in $DependsOn) {
            if (-not ($existing | Where-Object { $_.job_id -eq $dep })) { throw "DT_JOB_UNKNOWN_DEPENDENCY: $dep" }
        }
        $max = 0
        foreach ($r in $existing) { $n = [int]($r.job_id -replace '^j-', ''); if ($n -gt $max) { $max = $n } }
        $newId = 'j-{0:D4}' -f ($max + 1)
        $jobDir = Join-Path $paths.Jobs $newId
        New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
        Write-DtJobAtomic -Path (Join-Path $jobDir 'spec.json') -Content ($spec | ConvertTo-Json -Depth 4)
        $record = [ordered]@{
            job_id            = $newId
            run_id            = $resolvedRunId
            kind              = $Kind
            category          = $Category
            vendor            = $Vendor
            model             = $Model
            pid               = $null
            process_start_utc = $null
            runner_pid        = $null
            runner_start_utc  = $null
            command_sha256    = $commandSha
            depends_on        = @($DependsOn)
            mutates           = @($Mutates)
            status            = 'queued'
            status_reason     = $null
            exit_code         = $null
            timeout_sec       = $TimeoutSec
            working_directory = (Get-Location).ProviderPath
            output_path       = (Join-Path $jobDir 'stdout.log')
            stderr_path       = (Join-Path $jobDir 'stderr.log')
            summary_path      = (Join-Path $jobDir 'summary.json')
            queued            = [DateTime]::UtcNow.ToString('o')
            started           = $null
            ended             = $null
            last_progress     = $null
        }
        $obj = [pscustomobject]$record
        Save-DtJobRecord -RunFolder $RunFolder -Record $obj
        Add-DtJobEvent -RunFolder $RunFolder -JobId $newId -Type 'recorded' -Status 'queued'
        Invoke-DtJobSchedule -RunFolder $RunFolder
        $newId
    }
    $record = Get-DtJobRecord -RunFolder $RunFolder -JobId $id
    Write-DtJobOutput -Object ([pscustomobject][ordered]@{ job_id = $id; status = $record.status; status_reason = $record.status_reason; job_file = (Join-Path $paths.Jobs "$id.json") }) -AsJson:$Json
}

function Invoke-DtJobStatus {
    if ($JobId) {
        $record = Get-DtJobRecord -RunFolder $RunFolder -JobId $JobId
        if ($null -eq $record) { throw "DT_JOB_UNKNOWN: $JobId" }
        Write-DtJobOutput -Object (New-DtJobEnvelope -RunFolder $RunFolder -Record $record) -AsJson:$Json
    }
    else {
        Write-DtJobOutput -Object (New-DtJobRunEnvelope -RunFolder $RunFolder) -AsJson:$Json
    }
}

function Invoke-DtJobCancel {
    if (-not $JobId) { throw 'DT_JOB_USAGE: cancel requires -JobId.' }
    Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $record = Get-DtJobRecord -RunFolder $RunFolder -JobId $JobId
        if ($null -eq $record) { throw "DT_JOB_UNKNOWN: $JobId" }
        if ($record.status -eq 'queued') {
            Set-DtJobState -RunFolder $RunFolder -Record $record -Status 'cancelled' -EventType 'cancelled' -Reason 'cancelled while queued'
        }
        elseif ($record.status -eq 'running') {
            Stop-DtJobProcesses -Record $record
            Remove-DtJobKeyLocks -RunFolder $RunFolder -Record $record
            Set-DtJobState -RunFolder $RunFolder -Record $record -Status 'cancelled' -EventType 'cancelled' -Reason 'cancelled while running'
        }
        Invoke-DtJobSchedule -RunFolder $RunFolder
    }
    $record = Get-DtJobRecord -RunFolder $RunFolder -JobId $JobId
    Write-DtJobOutput -Object (New-DtJobEnvelope -RunFolder $RunFolder -Record $record) -AsJson:$Json
}

function Invoke-DtJobReconcile {
    $paths = Get-DtJobPaths -RunFolder $RunFolder
    $orphaned = [System.Collections.Generic.List[string]]::new()
    $freed = [System.Collections.Generic.List[string]]::new()
    Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        foreach ($r in (Get-DtJobRecords -RunFolder $RunFolder)) {
            if ($r.status -ne 'running') { continue }
            if (Test-DtJobAlive -Record $r) { continue }
            # Re-read under the lock: a terminal record written by the runner always wins.
            $fresh = Get-DtJobRecord -RunFolder $RunFolder -JobId $r.job_id
            if ($fresh.status -ne 'running') { continue }
            Set-DtJobState -RunFolder $RunFolder -Record $fresh -Status 'orphaned' -EventType 'orphaned' -Reason 'process gone without a terminal record'
            $orphaned.Add($fresh.job_id)
        }
        if (Test-Path -LiteralPath $paths.Locks) {
            foreach ($lock in Get-ChildItem -LiteralPath $paths.Locks -File -Filter 'key-*.lock') {
                $holderId = (Get-Content -Raw -LiteralPath $lock.FullName | ConvertFrom-Json).job_id
                $holder = Get-DtJobRecord -RunFolder $RunFolder -JobId $holderId
                if ($null -eq $holder -or (Test-DtJobTerminal $holder.status)) {
                    Remove-Item -LiteralPath $lock.FullName -Force
                    $freed.Add($lock.Name)
                }
            }
        }
        Invoke-DtJobSchedule -RunFolder $RunFolder
    }
    $summary = New-DtJobRunEnvelope -RunFolder $RunFolder
    $summary | Add-Member -NotePropertyName orphaned -NotePropertyValue @($orphaned)
    $summary | Add-Member -NotePropertyName freed_locks -NotePropertyValue @($freed)
    Write-DtJobOutput -Object $summary -AsJson:$Json
}

# Dot-sourcing (the runner does) loads the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

if (-not $Verb) { throw 'DT_JOB_USAGE: -Verb start|status|cancel|reconcile is required.' }
if (-not $RunFolder) { throw 'DT_JOB_USAGE: -RunFolder is required.' }

switch ($Verb) {
    'start' { Invoke-DtJobStart }
    'status' { Invoke-DtJobStatus }
    'cancel' { Invoke-DtJobCancel }
    'reconcile' { Invoke-DtJobReconcile }
}
