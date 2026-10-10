#Requires -Version 7.0
param(
    [ValidateSet('start', 'status', 'wait', 'cancel', 'reconcile', 'lease', 'register-run', 'unregister-run', 'consume', 'request-continuation', 'await-danny', 'approve', 'resume', 'finish', 'mark-bootstrap', 'irreversible', 'tree-hash', 'can-reuse')]
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

    [string[]]$PassEnv = @(),

    [switch]$Any,

    [switch]$All,

    [ValidateSet('acquire', 'renew', 'release', 'begin', 'end')]
    [string]$Action,

    [string]$CoordinatorId,

    # $Host and $PID are automatic variables, so these bind through aliases.
    [Alias('Host')]
    [ValidateSet('claude', 'codex')]
    [string]$CoordinatorHost,

    [string]$SessionId,

    [Alias('Pid')]
    [int]$CoordinatorPid = 0,

    [ValidateSet('watcher', 'interactive')]
    [string]$LaunchedBy = 'interactive',

    [int]$TtlSec = 0,

    [string]$BuildStatePath,

    [ValidateSet('claude', 'codex')]
    [string]$PinnedHost,

    [switch]$Managed,

    [long]$Seq = -1,

    [string]$Reason,

    [string]$Operation,

    [string]$Message,

    [string]$TranscriptPath,

    [string]$WorkingTree,

    [string]$Record,

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
$script:DtJobExpiryGraceSec = 30
$script:DtJobMoveRetryMs = 2000
$script:DtJobStderrExcerptLines = 10
$script:DtJobEnvAllow = @('CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'PATH')
$script:DtJobEnvSensitive = @('*TOKEN*', '*SECRET*', '*KEY*', '*PASSWORD*')
# Coordinator identity never reaches a job: a job's dt-job calls must not renew a dead coordinator's lease.
$script:DtJobEnvExclude = @('DT_BUILD_COORDINATOR_ID', 'DT_BUILD_COORDINATOR_LOCK_HELD')
$script:DtJobLockDepth = 0
$script:DtJobLockStream = $null
$script:DtJobRunnerPath = Join-Path $PSScriptRoot 'dt-job-runner.ps1'
$script:DtJobLeaseDefaultTtlSec = 600
# Parameters the command line passed explicitly; dot-sourced callers pass none.
$script:DtJobExplicitParams = @()
$script:DtJobLeaseRenewMaxSec = 60
$script:DtJobWaitPollMs = 500
$script:DtJobRunStatuses = @('runnable', 'awaiting_danny', 'finished')
$script:DtJobAlertScript = Join-Path $PSScriptRoot '..\..\..\scripts\model-router\send-router-alert.ps1'
# The calling coordinator: -CoordinatorId, else DT_BUILD_COORDINATOR_ID; $null for anyone else.
$script:DtJobCoordinator = $null
# The coordinator's context report for this call; set only when the call has a coordinator.
$script:DtJobContext = $null
# Room the context line takes inside the envelope cap.
$script:DtJobContextReserveBytes = 256

. (Join-Path $PSScriptRoot 'context-guard.ps1')
. (Join-Path $PSScriptRoot 'report-contract.ps1')

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
        Lease  = Join-Path $root 'coordinator.lease'
        CoordinatorLock = Join-Path $root 'coordinator.lock'
        Approvals = Join-Path $root 'approvals.json'
        Launches = Join-Path $root 'launches.jsonl'
        Notifications = Join-Path $root 'notifications.jsonl'
        ContextBaseline = Join-Path $root 'context-baseline.json'
        Irreversible = Join-Path $root 'irreversible.json'
        Rotations = Join-Path $root 'rotations.jsonl'
        KillFailed = Join-Path $root 'kill-failed.json'
        StepErrors = Join-Path $root 'step-errors.json'
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
    try {
        [System.IO.File]::WriteAllText($tempPath, $Content, [System.Text.UTF8Encoding]::new($false))
        # The replace fails while any reader holds the target open; retry briefly, bounded at about 2 s.
        $deadline = [DateTime]::UtcNow.AddMilliseconds($script:DtJobMoveRetryMs)
        $delayMs = 10
        while ($true) {
            try {
                [System.IO.File]::Move($tempPath, $Path, $true)
                break
            }
            catch [System.IO.IOException], [System.UnauthorizedAccessException] {
                if ([DateTime]::UtcNow -gt $deadline) { throw }
                Start-Sleep -Milliseconds $delayMs
                $delayMs = [Math]::Min(100, $delayMs * 2)
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
}

function Read-DtJobText {
    # Unlocked readers share read, write, and delete so they never block a writer's replace.
    param([Parameter(Mandatory)][string]$Path)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    }
    finally { $stream.Dispose() }
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
    return (Read-DtJobText -Path $path | ConvertFrom-Json)
}

function Get-DtJobRecords {
    param([Parameter(Mandatory)][string]$RunFolder)
    $jobsDir = (Get-DtJobPaths -RunFolder $RunFolder).Jobs
    if (-not (Test-Path -LiteralPath $jobsDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $jobsDir -File -Filter 'j-*.json' | Sort-Object Name | ForEach-Object {
        Read-DtJobText -Path $_.FullName | ConvertFrom-Json
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
    $prefix = ''
    if (Test-Path -LiteralPath $eventsPath) {
        $text = Read-DtJobText -Path $eventsPath
        # A partial last line (a writer killed mid-append) is skipped, and the next event starts on a fresh line.
        if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $prefix = "`n" }
        $lines = @($text -split "\r?\n" | Where-Object { $_.Trim() })
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            try { $parsed = $lines[$i] | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($null -ne $parsed -and $parsed.PSObject.Properties['seq']) { $seq = [int64]$parsed.seq + 1; break }
        }
    }
    $evt = [ordered]@{ seq = $seq; job_id = $JobId; ts_utc = [DateTime]::UtcNow.ToString('o'); type = $Type; status = $Status }
    if ($Reason) { $evt.reason = $Reason }
    [System.IO.File]::AppendAllText($eventsPath, ($prefix + ($evt | ConvertTo-Json -Compress) + "`n"), [System.Text.UTF8Encoding]::new($false))
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
    return (Read-DtJobText -Path $path | ConvertFrom-Json).job_id
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

function Test-DtJobExpired {
    param([Parameter(Mandatory)]$Record)
    if ([int]$Record.timeout_sec -le 0 -or -not $Record.started) { return $false }
    $age = ([DateTime]::UtcNow - (ConvertTo-DtJobUtc $Record.started)).TotalSeconds
    return ($age -gt ([int]$Record.timeout_sec + $script:DtJobExpiryGraceSec))
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
            }
            catch {
                Remove-DtJobKeyLocks -RunFolder $RunFolder -Record $r
                Set-DtJobState -RunFolder $RunFolder -Record $r -Status 'failed' -EventType 'launch_failed' -Reason ([string]$_.Exception.Message)
                continue
            }
            # The runner waits on this lock and proceeds only if it then reads 'running'.
            $r.runner_pid = $runner.pid
            $r.runner_start_utc = $runner.start_utc
            Set-DtJobState -RunFolder $RunFolder -Record $r -Status 'running' -EventType 'launched'
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
    return @((Read-DtJobText -Path $Path) -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-DtJobEnvelopeBytes {
    param($Envelope)
    return [System.Text.Encoding]::UTF8.GetByteCount(($Envelope | ConvertTo-Json -Depth 8 -Compress))
}

function New-DtJobEnvelope {
    # Bounded result: at most 8 KB in total, every line at most 400 characters, and a
    # truncation marker plus the full-file evidence path whenever anything is cut.
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)]$Record, $Cursor = $null)
    $paths = Get-DtJobPaths -RunFolder $RunFolder
    $jobDir = Join-Path $paths.Jobs $Record.job_id
    $stdout = Join-Path $jobDir 'stdout.log'
    $stderr = Join-Path $jobDir 'stderr.log'
    $changedPath = Join-Path $jobDir 'changed-files.txt'
    $blockersPath = Join-Path $jobDir 'blockers.txt'
    $cut = $false
    $cutPaths = [System.Collections.Generic.List[string]]::new()

    $jobFile = Join-Path $paths.Jobs "$($Record.job_id).json"
    $verdict = switch ($Record.status) { 'succeeded' { 'pass' } 'queued' { 'pending' } 'running' { 'pending' } default { 'fail' } }
    $reasonCut = $false
    $reason = Limit-DtJobLine ([string]$Record.status_reason) ([ref]$reasonCut)
    if ($reasonCut) { $cut = $true; $cutPaths.Add($jobFile) }
    $blockers = [System.Collections.Generic.List[string]]::new()
    if ($Record.status_reason -and $verdict -eq 'fail') { $blockers.Add($reason) }
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
    # Failed jobs often explain themselves on stderr; carry a short tail of it too.
    $stderrExcerpt = [System.Collections.Generic.List[string]]::new()
    $stderrCut = $false
    if ($verdict -eq 'fail') {
        $errTail = Read-DtJobTail -Path $stderr -MaxLines $script:DtJobStderrExcerptLines
        $stderrCut = [bool]$errTail.more
        foreach ($line in $errTail.lines) { $stderrExcerpt.Add((Limit-DtJobLine $line ([ref]$stderrCut))) }
    }

    $evidence = [ordered]@{ job_file = $jobFile; stdout = $stdout; stderr = $stderr }
    if (Test-Path -LiteralPath $changedPath) { $evidence.changed_files = $changedPath }
    if (Test-Path -LiteralPath $blockersPath) { $evidence.blockers = $blockersPath }

    $envelope = [ordered]@{
        job_id        = $Record.job_id
        status        = $Record.status
        verdict       = $verdict
        exit_code     = $Record.exit_code
        status_reason = $reason
        changed_files = $changed
        blockers      = $blockers
        evidence      = $evidence
        excerpt       = $excerpt
        stderr_excerpt = $stderrExcerpt
        truncated     = $false
        truncated_evidence = $cutPaths
    }
    if ($null -ne $Cursor) { $envelope.last_event_seq = $Cursor.last_event_seq; $envelope.last_consumed_event_seq = $Cursor.last_consumed_event_seq }
    if ($excerptCut) { $cutPaths.Add($stdout) }
    if ($stderrCut) { $cutPaths.Add($stderr) }
    while ((Get-DtJobEnvelopeBytes $envelope) -gt $script:DtJobEnvelopeMaxBytes -and $excerpt.Count -gt 0) {
        $excerpt.RemoveAt(0)
        if (-not $cutPaths.Contains($stdout)) { $cutPaths.Add($stdout) }
    }
    while ((Get-DtJobEnvelopeBytes $envelope) -gt $script:DtJobEnvelopeMaxBytes -and $stderrExcerpt.Count -gt 0) {
        $stderrExcerpt.RemoveAt(0)
        if (-not $cutPaths.Contains($stderr)) { $cutPaths.Add($stderr) }
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
    param([Parameter(Mandatory)][string]$RunFolder, $Cursor = $null, $Records = $null)
    $paths = Get-DtJobPaths -RunFolder $RunFolder
    $cut = $false
    $jobs = [System.Collections.Generic.List[object]]::new()
    $source = if ($null -ne $Records) { @($Records) } else { @(Get-DtJobRecords -RunFolder $RunFolder) }
    foreach ($r in $source) {
        $jobs.Add([ordered]@{ job_id = $r.job_id; kind = $r.kind; status = $r.status; exit_code = $r.exit_code; status_reason = (Limit-DtJobLine ([string]$r.status_reason) ([ref]$cut)) })
    }
    $envelope = [ordered]@{ run_folder = $paths.Root; job_count = $jobs.Count; jobs = $jobs; evidence = [ordered]@{ jobs_dir = $paths.Jobs; events = $paths.Events }; truncated = $false }
    if ($null -ne $Cursor) { $envelope.last_event_seq = $Cursor.last_event_seq; $envelope.last_consumed_event_seq = $Cursor.last_consumed_event_seq }
    while ((Get-DtJobEnvelopeBytes $envelope) -gt $script:DtJobEnvelopeMaxBytes -and $jobs.Count -gt 0) {
        $jobs.RemoveAt($jobs.Count - 1)
        $cut = $true
    }
    $envelope.truncated = $cut
    return [pscustomobject]$envelope
}

function Split-DtJobList {
    param([AllowNull()][string[]]$Values)
    return @(@($Values) | ForEach-Object { ([string]$_) -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-DtJobEnvironment {
    # Allow-listed caller environment for the job: DT_* (never the coordinator identity), CODEX_HOME,
    # CLAUDE_CONFIG_DIR, PATH, and -PassEnv names.
    # Secret-looking names are skipped silently unless named in -PassEnv; values are never logged.
    param([string[]]$Extra = @())
    $snapshot = [ordered]@{}
    foreach ($item in Get-ChildItem Env: | Sort-Object Name) {
        $name = [string]$item.Name
        if (@($script:DtJobEnvExclude | Where-Object { $_ -ieq $name }).Count -gt 0) { continue }
        $named = @($Extra | Where-Object { $_ -ieq $name }).Count -gt 0
        $allowed = $named -or $name -like 'DT_*' -or @($script:DtJobEnvAllow | Where-Object { $_ -ieq $name }).Count -gt 0
        if (-not $allowed) { continue }
        $sensitive = @($script:DtJobEnvSensitive | Where-Object { $name -like $_ }).Count -gt 0
        if ($sensitive -and -not $named) { continue }
        $snapshot[$name] = [string]$item.Value
    }
    return $snapshot
}

function Write-DtJobOutput {
    # A coordinator's call carries its context line: a field in JSON output, a trailing line otherwise.
    param($Object, [switch]$AsJson)
    if ($AsJson) {
        if ($null -ne $script:DtJobContext -and $null -ne $Object) { $Object | Add-Member -NotePropertyName context -NotePropertyValue $script:DtJobContext.line -Force }
        $Object | ConvertTo-Json -Depth 8 -Compress
    }
    else { $Object }
}

function Invoke-DtJobStart {
    $paths = Get-DtJobPaths -RunFolder $RunFolder
    $ctx = $script:DtJobContext
    if ($null -ne $ctx -and $ctx.state -eq 'rotate' -and -not $ctx.deferred) {
        throw "ROTATE_REQUIRED: $($ctx.line). No new dispatch at the context limit: write _build-state.md and a coordinator handoff, run dt-job request-continuation -RunFolder `"$($paths.Root)`" -Reason context_rotation, release the lease, and end the turn."
    }
    if ([string]::IsNullOrWhiteSpace($Command) -eq [string]::IsNullOrWhiteSpace($ScriptPath)) {
        throw 'DT_JOB_USAGE: start takes exactly one of -Command or -ScriptPath.'
    }
    $spec = [ordered]@{ command = $null; script_path = $null; argument_list = @($ArgumentList); timeout_sec = $TimeoutSec; environment = (Get-DtJobEnvironment -Extra $PassEnv) }
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

function Get-DtJobConsumedSeq {
    # The run's consumed-event cursor, or $null when neither the registry nor -BuildStatePath names its state file.
    param([Parameter(Mandatory)][string]$RunFolder)
    try { $ctx = Resolve-DtJobRunContext -RunFolder $RunFolder -BuildStatePath $BuildStatePath -RunId $RunId } catch { return $null }
    return (Get-DtJobRunState -BuildStatePath $ctx.build_state_path).last_consumed_event_seq
}

function Get-DtJobSnapshot {
    # Records and the last event seq read together under the run lock, so the seq a coordinator consumes
    # covers exactly the events behind the states it was shown.
    param([Parameter(Mandatory)][string]$RunFolder, [string[]]$Ids = $null)
    $snap = Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $records = if ($null -ne $Ids) { @($Ids | ForEach-Object { Get-DtJobRecord -RunFolder $RunFolder -JobId $_ }) } else { @(Get-DtJobRecords -RunFolder $RunFolder) }
        [pscustomobject]@{ records = $records; last_event_seq = (Get-DtJobLastEventSeq -RunFolder $RunFolder) }
    }
    $snap | Add-Member -NotePropertyName last_consumed_event_seq -NotePropertyValue (Get-DtJobConsumedSeq -RunFolder $RunFolder)
    return $snap
}

function Invoke-DtJobStatus {
    if ($JobId) {
        $snap = Get-DtJobSnapshot -RunFolder $RunFolder -Ids @($JobId)
        $record = @($snap.records)[0]
        if ($null -eq $record) { throw "DT_JOB_UNKNOWN: $JobId" }
        Write-DtJobOutput -Object (New-DtJobEnvelope -RunFolder $RunFolder -Record $record -Cursor $snap) -AsJson:$Json
    }
    else {
        $snap = Get-DtJobSnapshot -RunFolder $RunFolder
        Write-DtJobOutput -Object (New-DtJobRunEnvelope -RunFolder $RunFolder -Cursor $snap -Records $snap.records) -AsJson:$Json
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
            if (Test-DtJobExpired -Record $r) {
                # Past its timeout plus grace: the runner that enforces it is gone or stuck.
                Stop-DtJobProcesses -Record $r
                Remove-DtJobKeyLocks -RunFolder $RunFolder -Record $r
                Set-DtJobState -RunFolder $RunFolder -Record $r -Status 'timeout' -EventType 'expired' -Reason "expired: running past timeout $($r.timeout_sec) s plus $($script:DtJobExpiryGraceSec) s grace"
                continue
            }
            if (Test-DtJobAlive -Record $r) { continue }
            # Re-read under the lock: a terminal record written by the runner always wins.
            $fresh = Get-DtJobRecord -RunFolder $RunFolder -JobId $r.job_id
            if ($fresh.status -ne 'running') { continue }
            Set-DtJobState -RunFolder $RunFolder -Record $fresh -Status 'orphaned' -EventType 'orphaned' -Reason 'process gone without a terminal record'
            $orphaned.Add($fresh.job_id)
        }
        if (Test-Path -LiteralPath $paths.Locks) {
            foreach ($lock in Get-ChildItem -LiteralPath $paths.Locks -File -Filter 'key-*.lock') {
                $holderId = (Read-DtJobText -Path $lock.FullName | ConvertFrom-Json).job_id
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

function Get-DtJobEvents {
    # Parsed events in file order; a partial or unparsable line is skipped.
    param([Parameter(Mandatory)][string]$RunFolder)
    $eventsPath = (Get-DtJobPaths -RunFolder $RunFolder).Events
    if (-not (Test-Path -LiteralPath $eventsPath)) { return @() }
    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ((Read-DtJobText -Path $eventsPath) -split "\r?\n")) {
        if (-not $line.Trim()) { continue }
        try { $parsed = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -ne $parsed -and $parsed.PSObject.Properties['seq']) { $events.Add($parsed) }
    }
    return @($events)
}

function Get-DtJobLastEventSeq {
    param([Parameter(Mandatory)][string]$RunFolder)
    $max = [int64]0
    foreach ($evt in (Get-DtJobEvents -RunFolder $RunFolder)) { if ([int64]$evt.seq -gt $max) { $max = [int64]$evt.seq } }
    return $max
}

function Get-DtJobLease {
    param([Parameter(Mandatory)][string]$RunFolder)
    $path = (Get-DtJobPaths -RunFolder $RunFolder).Lease
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Read-DtJobText -Path $path | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Save-DtJobLease {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)]$Lease)
    Write-DtJobAtomic -Path (Get-DtJobPaths -RunFolder $RunFolder).Lease -Content ($Lease | ConvertTo-Json -Depth 4)
}

function Test-DtJobLeaseExpired {
    param($Lease, [DateTime]$NowUtc = [DateTime]::UtcNow)
    if ($null -eq $Lease -or -not $Lease.expires_utc) { return $true }
    return ((ConvertTo-DtJobUtc $Lease.expires_utc) -le $NowUtc)
}

function Test-DtJobLeaseHolderGone {
    # Provably gone: no process has the lease pid, or the recorded start time no longer matches it.
    param([Parameter(Mandatory)]$Lease)
    if (-not $Lease.pid) { return $false }
    $pidStart = if ($Lease.PSObject.Properties['pid_start_utc']) { $Lease.pid_start_utc } else { $null }
    if (Test-DtJobProcessIdentity $Lease.pid $pidStart) { return $false }
    if ($pidStart) { return $true }
    return ($null -eq (Get-DtJobProcessStartUtc -ProcessId ([int]$Lease.pid)))
}

function Get-DtJobLeaseTtl {
    param($Lease)
    if ($null -ne $Lease -and $Lease.PSObject.Properties['ttl_sec'] -and [int]$Lease.ttl_sec -gt 0) { return [int]$Lease.ttl_sec }
    return $script:DtJobLeaseDefaultTtlSec
}

function Update-DtJobLeaseIfHolder {
    # Renews only the holder's own, unreleased lease; anyone else's lease is left alone.
    param([Parameter(Mandatory)][string]$RunFolder, [string]$CoordinatorId)
    if (-not $CoordinatorId) { return $false }
    if (-not (Test-Path -LiteralPath (Get-DtJobPaths -RunFolder $RunFolder).Lease)) { return $false }
    return (Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $lease = Get-DtJobLease -RunFolder $RunFolder
        if ($null -eq $lease -or $lease.coordinator_id -ne $CoordinatorId) { return $false }
        if ($lease.PSObject.Properties['released_utc'] -and $lease.released_utc) { return $false }
        $lease.expires_utc = [DateTime]::UtcNow.AddSeconds((Get-DtJobLeaseTtl $lease)).ToString('o')
        Save-DtJobLease -RunFolder $RunFolder -Lease $lease
        return $true
    })
}

function Get-DtJobRunState {
    # Missing or placeholder values read as runnable with cursor 0. Only the first line of each field
    # counts: the same line Set-DtJobRunState rewrites.
    param([Parameter(Mandatory)][string]$BuildStatePath)
    $status = 'runnable'
    $cursor = [int64]0
    $statusSeen = $false
    $cursorSeen = $false
    foreach ($line in ((Read-DtJobText -Path $BuildStatePath) -split "\r?\n")) {
        if (-not $statusSeen -and $line -match '^run_status:') {
            $statusSeen = $true
            if ($line -match '^run_status:\s*(\S+)\s*$' -and $script:DtJobRunStatuses -contains $Matches[1]) { $status = $Matches[1] }
        }
        elseif (-not $cursorSeen -and $line -match '^last_consumed_event_seq:') {
            $cursorSeen = $true
            if ($line -match '^last_consumed_event_seq:\s*(\d+)\s*$') { $cursor = [int64]$Matches[1] }
        }
        if ($statusSeen -and $cursorSeen) { break }
    }
    return [pscustomobject]@{ run_status = $status; last_consumed_event_seq = $cursor }
}

function Set-DtJobRunState {
    # Atomic full-file rewrite that changes only the run_status and last_consumed_event_seq lines,
    # inserting them directly under updated_utc when absent. Callers hold the run lock.
    param([Parameter(Mandatory)][string]$BuildStatePath, [string]$RunStatus, [Nullable[long]]$Cursor)
    $bytes = [System.IO.File]::ReadAllBytes($BuildStatePath)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = Read-DtJobText -Path $BuildStatePath
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $current = Get-DtJobRunState -BuildStatePath $BuildStatePath
    $status = if ($RunStatus) { $RunStatus } else { $current.run_status }
    $seq = if ($null -ne $Cursor) { [int64]$Cursor } else { $current.last_consumed_event_seq }
    $statusLine = "run_status: $status"
    $cursorLine = "last_consumed_event_seq: $seq"
    $lines = [System.Collections.Generic.List[string]]::new([string[]]($text -split "\r?\n"))
    $statusIndex = -1; $cursorIndex = -1; $updatedIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($statusIndex -lt 0 -and $lines[$i] -match '^run_status:') { $statusIndex = $i }
        elseif ($cursorIndex -lt 0 -and $lines[$i] -match '^last_consumed_event_seq:') { $cursorIndex = $i }
        elseif ($updatedIndex -lt 0 -and $lines[$i] -match '^updated_utc:') { $updatedIndex = $i }
    }
    if ($statusIndex -ge 0 -and $cursorIndex -ge 0) {
        $lines[$statusIndex] = $statusLine
        $lines[$cursorIndex] = $cursorLine
    }
    elseif ($statusIndex -ge 0) {
        $lines[$statusIndex] = $statusLine
        $lines.Insert($statusIndex + 1, $cursorLine)
    }
    elseif ($cursorIndex -ge 0) {
        $lines[$cursorIndex] = $cursorLine
        $lines.Insert($cursorIndex, $statusLine)
    }
    else {
        if ($updatedIndex -lt 0) { throw "DT_JOB_BUILD_STATE_SHAPE: no updated_utc line in $BuildStatePath" }
        $lines.Insert($updatedIndex + 1, $statusLine)
        $lines.Insert($updatedIndex + 2, $cursorLine)
    }
    $newText = $lines -join $newline
    if ($newText -ceq $text) { return }
    if ($hasBom) { $newText = [string][char]0xFEFF + $newText }
    Write-DtJobAtomic -Path $BuildStatePath -Content $newText
}

function Get-DtJobRegistryPath {
    $dir = if ($env:DT_BUILD_STATE_DIR) { $env:DT_BUILD_STATE_DIR } else { Join-Path $env:LOCALAPPDATA 'dt-build' }
    return (Join-Path ([System.IO.Path]::GetFullPath($dir)) 'active-runs.json')
}

function Invoke-DtJobRegistryLocked {
    param([Parameter(Mandatory)][scriptblock]$Body, [int]$LockTimeoutSec = 60)
    $registry = Get-DtJobRegistryPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $registry) -Force | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSec)
    while ($true) {
        try {
            $stream = [System.IO.File]::Open("$registry.lock", [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            break
        }
        catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -gt $deadline) { throw "DT_JOB_LOCK_TIMEOUT: $registry.lock" }
            Start-Sleep -Milliseconds (Get-Random -Minimum 20 -Maximum 80)
        }
    }
    try { & $Body }
    finally { $stream.Dispose() }
}

function Get-DtJobRegistryRuns {
    $registry = Get-DtJobRegistryPath
    if (-not (Test-Path -LiteralPath $registry)) { return @() }
    $parsed = Read-DtJobText -Path $registry | ConvertFrom-Json
    if ($null -eq $parsed -or -not $parsed.PSObject.Properties['runs']) { return @() }
    return @($parsed.runs | Where-Object { $null -ne $_ })
}

function Save-DtJobRegistryRuns {
    param([AllowEmptyCollection()][object[]]$Runs = @())
    Write-DtJobAtomic -Path (Get-DtJobRegistryPath) -Content ([ordered]@{ runs = @($Runs) } | ConvertTo-Json -Depth 6)
}

function Get-DtJobRegistryEntry {
    param([Parameter(Mandatory)][string]$RunFolder)
    $root = (Get-DtJobPaths -RunFolder $RunFolder).Root
    return (Get-DtJobRegistryRuns | Where-Object { [string]$_.run_folder -ieq $root } | Select-Object -First 1)
}

function Resolve-DtJobRunContext {
    param([Parameter(Mandatory)][string]$RunFolder, [string]$BuildStatePath, [string]$RunId)
    $entry = Get-DtJobRegistryEntry -RunFolder $RunFolder
    $statePath = if ($BuildStatePath) { $BuildStatePath } elseif ($null -ne $entry) { [string]$entry.build_state_path } else { $null }
    if (-not $statePath) { throw 'DT_JOB_USAGE: the run is not registered; pass -BuildStatePath.' }
    $statePath = [System.IO.Path]::GetFullPath($statePath)
    if (-not (Test-Path -LiteralPath $statePath)) { throw "DT_JOB_BUILD_STATE_MISSING: $statePath" }
    $resolvedRunId = if ($RunId) { $RunId } elseif ($null -ne $entry) { [string]$entry.run_id } else { Split-Path -Leaf (Get-DtJobPaths -RunFolder $RunFolder).Root }
    return [pscustomobject]@{ run_id = $resolvedRunId; build_state_path = $statePath; entry = $entry }
}

function Get-DtJobApprovals {
    param([Parameter(Mandatory)][string]$RunFolder)
    $path = (Get-DtJobPaths -RunFolder $RunFolder).Approvals
    if (Test-Path -LiteralPath $path) {
        $parsed = Read-DtJobText -Path $path | ConvertFrom-Json
        return [pscustomobject]@{ awaiting = $parsed.awaiting; approvals = @($parsed.approvals | Where-Object { $null -ne $_ }) }
    }
    return [pscustomobject]@{ awaiting = $null; approvals = @() }
}

function Save-DtJobApprovals {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)]$Approvals)
    $content = [ordered]@{ awaiting = $Approvals.awaiting; approvals = @($Approvals.approvals) } | ConvertTo-Json -Depth 5
    Write-DtJobAtomic -Path (Get-DtJobPaths -RunFolder $RunFolder).Approvals -Content $content
}

function Get-DtJobNotifications {
    param([Parameter(Mandatory)][string]$RunFolder)
    $log = (Get-DtJobPaths -RunFolder $RunFolder).Notifications
    if (-not (Test-Path -LiteralPath $log)) { return @() }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ((Read-DtJobText -Path $log) -split "\r?\n")) {
        if (-not $line.Trim()) { continue }
        try { $rows.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { }
    }
    return @($rows)
}

function Test-DtJobNotificationDelivered {
    # Rows written before the pending/delivered split carry no status and were all delivered.
    param($Row)
    return (-not $Row.PSObject.Properties['status'] -or $Row.status -eq 'delivered')
}

function Add-DtJobNotification {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)]$Row)
    [System.IO.File]::AppendAllText((Get-DtJobPaths -RunFolder $RunFolder).Notifications, (($Row | ConvertTo-Json -Compress) + "`n"), [System.Text.UTF8Encoding]::new($false))
}

function Send-DtJobRunAlert {
    # One delivered DM per key per run: a key already delivered from this run folder is never sent again.
    # With -RetryUntilDelivered a failed send is recorded as pending, and Send-DtJobPendingAlerts retries it.
    # Delivery and cross-process dedupe belong to send-router-alert.ps1.
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Message, [switch]$RetryUntilDelivered)
    $rows = @(Get-DtJobNotifications -RunFolder $RunFolder | Where-Object { [string]$_.key -ceq $Key })
    if (@($rows | Where-Object { Test-DtJobNotificationDelivered $_ }).Count -gt 0) { return 'already_sent' }
    $result = $null
    try {
        $raw = & pwsh -NoProfile -NonInteractive -File $script:DtJobAlertScript -Key $Key -Message $Message -Json 2>$null
        $result = (@($raw) | Where-Object { $_ } | Select-Object -Last 1) | ConvertFrom-Json
    }
    catch { $result = $null }
    if ($null -eq $result -or -not $result.sent) {
        if ($RetryUntilDelivered -and $rows.Count -eq 0) {
            Add-DtJobNotification -RunFolder $RunFolder -Row ([ordered]@{ key = $Key; status = 'pending'; message = $Message; recorded_utc = [DateTime]::UtcNow.ToString('o') })
        }
        return 'failed'
    }
    Add-DtJobNotification -RunFolder $RunFolder -Row ([ordered]@{ key = $Key; status = 'delivered'; channel = $result.channel; sent_utc = [DateTime]::UtcNow.ToString('o') })
    return 'sent'
}

function Send-DtJobPendingAlerts {
    # Retries every pending DM that has not been delivered yet, oldest first.
    param([Parameter(Mandatory)][string]$RunFolder)
    $rows = @(Get-DtJobNotifications -RunFolder $RunFolder)
    $delivered = @($rows | Where-Object { Test-DtJobNotificationDelivered $_ } | ForEach-Object { [string]$_.key })
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($rows | Where-Object { -not (Test-DtJobNotificationDelivered $_) -and $_.status -eq 'pending' })) {
        if ($delivered -ccontains [string]$row.key) { continue }
        $results.Add([pscustomobject][ordered]@{ key = [string]$row.key; alert = (Send-DtJobRunAlert -RunFolder $RunFolder -Key ([string]$row.key) -Message ([string]$row.message)) })
        $delivered += [string]$row.key
    }
    return @($results)
}

function Get-DtJobWaitRenewSec {
    # A blocked wait renews at least every min(60 s, ttl/2), never more often than once a second.
    param($Lease)
    return [int][Math]::Max(1, [Math]::Min($script:DtJobLeaseRenewMaxSec, [Math]::Floor((Get-DtJobLeaseTtl $Lease) / 2)))
}

function Invoke-DtJobWait {
    $ids = @($script:DtJobIds)
    if ($ids.Count -eq 0) { throw 'DT_JOB_USAGE: wait requires -JobId.' }
    if ($Any -eq $All) { throw 'DT_JOB_USAGE: wait takes exactly one of -Any or -All.' }
    if ($TimeoutSec -le 0) { throw 'DT_JOB_USAGE: wait requires -TimeoutSec greater than 0.' }
    foreach ($id in $ids) { if ($null -eq (Get-DtJobRecord -RunFolder $RunFolder -JobId $id)) { throw "DT_JOB_UNKNOWN: $id" } }
    $coordinator = $script:DtJobCoordinator
    $renewEverySec = Get-DtJobWaitRenewSec (Get-DtJobLease -RunFolder $RunFolder)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $lastRenew = [DateTime]::UtcNow
    while ($true) {
        $records = @($ids | ForEach-Object { Get-DtJobRecord -RunFolder $RunFolder -JobId $_ })
        $done = @($records | Where-Object { Test-DtJobTerminal $_.status })
        if (($Any -and $done.Count -gt 0) -or ($All -and $done.Count -eq $ids.Count)) { $result = 'finished'; break }
        if ([DateTime]::UtcNow -ge $deadline) { $result = 'wait_timeout'; break }
        if ($coordinator -and ([DateTime]::UtcNow - $lastRenew).TotalSeconds -ge $renewEverySec) {
            try { [void](Update-DtJobLeaseIfHolder -RunFolder $RunFolder -CoordinatorId $coordinator) } catch { }
            $lastRenew = [DateTime]::UtcNow
        }
        Start-Sleep -Milliseconds $script:DtJobWaitPollMs
    }
    # Terminal states never revert, so the locked re-read only adds finished jobs.
    $snap = Get-DtJobSnapshot -RunFolder $RunFolder -Ids $ids
    $records = @($snap.records)
    $done = @($records | Where-Object { Test-DtJobTerminal $_.status })
    $cut = $false
    $lines = [System.Collections.Generic.List[string]]::new()
    $jobs = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $done) {
        $evidence = Limit-DtJobLine ([string]$r.output_path) ([ref]$cut)
        $jobs.Add([ordered]@{ job_id = $r.job_id; status = $r.status; exit_code = $r.exit_code; evidence = $evidence })
        $lines.Add((Limit-DtJobLine "$($r.job_id) $($r.status) exit=$($r.exit_code) evidence=$($r.output_path)" ([ref]$cut)))
    }
    $running = @($records | Where-Object { -not (Test-DtJobTerminal $_.status) } | ForEach-Object { $_.job_id })
    $envelope = [ordered]@{ result = $result; jobs = $jobs; still_running = @($running); omitted = 0; truncated = $false; last_event_seq = $snap.last_event_seq; last_consumed_event_seq = $snap.last_consumed_event_seq }
    if ($Json -and $null -ne $script:DtJobContext) { $envelope.context = $script:DtJobContext.line }
    while ((Get-DtJobEnvelopeBytes $envelope) -gt $script:DtJobEnvelopeMaxBytes -and $jobs.Count -gt 0) {
        $jobs.RemoveAt($jobs.Count - 1)
        $lines.RemoveAt($lines.Count - 1)
        $envelope.omitted++
        $cut = $true
    }
    $envelope.truncated = $cut
    if ($Json) { return ($envelope | ConvertTo-Json -Depth 6 -Compress) }
    if ($envelope.omitted -gt 0) { $lines.Add("...[truncated] $($envelope.omitted) finished job(s) omitted; dt-job status -RunFolder lists all") }
    if ($result -eq 'wait_timeout') { $lines.Add((Limit-DtJobLine "wait_timeout still_running=$($running -join ',')" ([ref]$cut))) }
    return $lines
}

function Invoke-DtJobCoordinatorLocked {
    # Serializes coordinator takeover with the watcher's launches: the watcher holds coordinator.lock from
    # its eligibility recheck until its launcher returns, so an interactive acquire cannot slip in between.
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][scriptblock]$Action, [int]$LockTimeoutSec = 120)
    $paths = Get-DtJobPaths -RunFolder $RunFolder
    New-Item -ItemType Directory -Path $paths.Root -Force | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSec)
    while ($true) {
        try {
            $stream = [System.IO.File]::Open($paths.CoordinatorLock, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            break
        }
        catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -gt $deadline) { throw "DT_JOB_LOCK_TIMEOUT: $($paths.CoordinatorLock)" }
            Start-Sleep -Milliseconds (Get-Random -Minimum 20 -Maximum 80)
        }
    }
    try { & $Action }
    finally { $stream.Dispose() }
}

function Test-DtJobCoordinatorLockHeldByCaller {
    # The watcher sets DT_BUILD_COORDINATOR_LOCK_HELD to the run folder for its launcher, which already runs under that lock.
    param([Parameter(Mandatory)][string]$RunFolder)
    $held = $env:DT_BUILD_COORDINATOR_LOCK_HELD
    if (-not $held) { return $false }
    return ([System.IO.Path]::GetFullPath($held).TrimEnd('\', '/') -ieq (Get-DtJobPaths -RunFolder $RunFolder).Root)
}

function Invoke-DtJobLease {
    if (@('acquire', 'renew', 'release') -notcontains $Action) { throw 'DT_JOB_USAGE: lease requires -Action acquire|renew|release.' }
    if (-not $CoordinatorId) { throw 'DT_JOB_USAGE: lease requires -CoordinatorId.' }
    $leaseAction = $Action
    $body = { Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $now = [DateTime]::UtcNow
        $current = Get-DtJobLease -RunFolder $RunFolder
        $isHolder = ($null -ne $current -and $current.coordinator_id -eq $CoordinatorId)
        if ($leaseAction -eq 'acquire' -and $null -ne $current -and -not $isHolder) {
            # A watcher-launched coordinator is judged by its process: alive keeps the run even past lease
            # expiry; provably gone frees it before expiry. Any other holder is judged by expiry alone.
            $watcherHolder = ($current.launched_by -eq 'watcher')
            $holderStart = if ($current.PSObject.Properties['pid_start_utc']) { $current.pid_start_utc } else { $null }
            if ($watcherHolder -and (Test-DtJobProcessIdentity $current.pid $holderStart)) {
                throw "DT_JOB_LEASE_HELD: $($current.coordinator_id) is a watcher-launched coordinator still running as pid $($current.pid)"
            }
            if (-not (Test-DtJobLeaseExpired $current $now) -and -not ($watcherHolder -and (Test-DtJobLeaseHolderGone $current))) {
                throw "DT_JOB_LEASE_HELD: $($current.coordinator_id) holds the lease until $((ConvertTo-DtJobUtc $current.expires_utc).ToString('o'))"
            }
        }
        if ($leaseAction -eq 'acquire') {
            $ttl = if ($TtlSec -gt 0) { $TtlSec } else { $script:DtJobLeaseDefaultTtlSec }
            # The holder's own re-acquire keeps who launched it and its process unless the call names new ones,
            # so a managed coordinator that re-acquires stays watcher-launched and can still be relaunched.
            # A released lease keeps none of it: its process is no longer the coordinator.
            $holderLive = ($isHolder -and -not ($current.PSObject.Properties['released_utc'] -and $current.released_utc))
            $keepLaunchedBy = ($holderLive -and $script:DtJobExplicitParams -notcontains 'LaunchedBy' -and $current.PSObject.Properties['launched_by'] -and $current.launched_by)
            $keepPid = ($holderLive -and $CoordinatorPid -le 0 -and $current.PSObject.Properties['pid'] -and $current.pid)
            $leasePid = if ($CoordinatorPid -gt 0) { $CoordinatorPid } elseif ($keepPid) { $current.pid } else { $null }
            $leasePidStart = if ($keepPid) { $(if ($current.PSObject.Properties['pid_start_utc']) { $current.pid_start_utc } else { $null }) } elseif ($leasePid) { Get-DtJobProcessStartUtc -ProcessId $leasePid } else { $null }
            $next = [pscustomobject][ordered]@{
                coordinator_id = $CoordinatorId
                host           = $(if ($CoordinatorHost) { $CoordinatorHost } else { $null })
                session_id     = $(if ($SessionId) { $SessionId } else { $null })
                pid            = $leasePid
                pid_start_utc  = $leasePidStart
                launched_by    = $(if ($keepLaunchedBy) { [string]$current.launched_by } else { $LaunchedBy })
                ttl_sec        = $ttl
                acquired_utc   = $now.ToString('o')
                expires_utc    = $now.AddSeconds($ttl).ToString('o')
                released_utc   = $null
            }
        }
        else {
            if (-not $isHolder) { throw "DT_JOB_LEASE_NOT_HOLDER: $CoordinatorId does not hold the lease" }
            $next = $current
            if (-not $next.PSObject.Properties['released_utc']) { $next | Add-Member -NotePropertyName released_utc -NotePropertyValue $null }
            if ($leaseAction -eq 'renew') {
                if ($TtlSec -gt 0) { $next.ttl_sec = $TtlSec }
                $next.expires_utc = $now.AddSeconds((Get-DtJobLeaseTtl $next)).ToString('o')
                $next.released_utc = $null
                # The launcher takes the lease before it starts the child, then records the child here.
                if ($CoordinatorPid -gt 0) {
                    $next | Add-Member -NotePropertyName pid -NotePropertyValue $CoordinatorPid -Force
                    $next | Add-Member -NotePropertyName pid_start_utc -NotePropertyValue (Get-DtJobProcessStartUtc -ProcessId $CoordinatorPid) -Force
                }
            }
            else {
                # Release expires the lease but keeps its identity, so the watcher can still tell who held it.
                $next.expires_utc = $now.ToString('o')
                $next.released_utc = $now.ToString('o')
            }
        }
        Save-DtJobLease -RunFolder $RunFolder -Lease $next
        $next
    } }
    # Acquire takes coordinator.lock first unless the caller is the watcher's launcher, which runs under it.
    if ($leaseAction -eq 'acquire' -and -not (Test-DtJobCoordinatorLockHeldByCaller -RunFolder $RunFolder)) {
        $lease = Invoke-DtJobCoordinatorLocked -RunFolder $RunFolder -Action $body
    }
    else { $lease = & $body }
    Write-DtJobOutput -Object $lease -AsJson:$Json
}

function Invoke-DtJobRegisterRun {
    if (-not $BuildStatePath -or -not $RunId -or -not $PinnedHost) { throw 'DT_JOB_USAGE: register-run requires -BuildStatePath, -RunId, and -PinnedHost.' }
    $root = (Get-DtJobPaths -RunFolder $RunFolder).Root
    $entry = [ordered]@{
        run_id           = $RunId
        run_folder       = $root
        build_state_path = [System.IO.Path]::GetFullPath($BuildStatePath)
        pinned_host      = $PinnedHost
        managed          = [bool]$Managed
        registered_utc   = [DateTime]::UtcNow.ToString('o')
    }
    Invoke-DtJobRegistryLocked -Body {
        $runs = @(Get-DtJobRegistryRuns | Where-Object { [string]$_.run_folder -ine $root -and [string]$_.run_id -cne $RunId })
        Save-DtJobRegistryRuns -Runs (@($runs) + @([pscustomobject]$entry))
    }
    Write-DtJobOutput -Object ([pscustomobject]$entry) -AsJson:$Json
}

function Remove-DtJobRegistryEntry {
    param([Parameter(Mandatory)][string]$RunFolder)
    $root = (Get-DtJobPaths -RunFolder $RunFolder).Root
    return (Invoke-DtJobRegistryLocked -Body {
        $runs = @(Get-DtJobRegistryRuns)
        $kept = @($runs | Where-Object { [string]$_.run_folder -ine $root })
        if ($kept.Count -ne $runs.Count) { Save-DtJobRegistryRuns -Runs $kept }
        ($runs.Count - $kept.Count)
    })
}

function Invoke-DtJobUnregisterRun {
    $removed = Remove-DtJobRegistryEntry -RunFolder $RunFolder
    Write-DtJobOutput -Object ([pscustomobject][ordered]@{ run_folder = (Get-DtJobPaths -RunFolder $RunFolder).Root; removed = [int]$removed }) -AsJson:$Json
}

function Get-DtJobRunSummary {
    param([Parameter(Mandatory)]$Context, [hashtable]$Extra = @{})
    $state = Get-DtJobRunState -BuildStatePath $Context.build_state_path
    $summary = [ordered]@{ run_id = $Context.run_id; run_status = $state.run_status; last_consumed_event_seq = $state.last_consumed_event_seq; last_event_seq = (Get-DtJobLastEventSeq -RunFolder $RunFolder) }
    foreach ($key in $Extra.Keys) { $summary[$key] = $Extra[$key] }
    return [pscustomobject]$summary
}

function Invoke-DtJobConsume {
    if ($Seq -lt 0) { throw 'DT_JOB_USAGE: consume requires -Seq <n>.' }
    $ctx = Resolve-DtJobRunContext -RunFolder $RunFolder -BuildStatePath $BuildStatePath -RunId $RunId
    Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $last = Get-DtJobLastEventSeq -RunFolder $RunFolder
        if ($Seq -gt $last) { throw "DT_JOB_CONSUME_AHEAD: seq $Seq is past the last event $last" }
        # The cursor never moves backwards; an older seq is a no-op.
        if ($Seq -gt (Get-DtJobRunState -BuildStatePath $ctx.build_state_path).last_consumed_event_seq) {
            Set-DtJobRunState -BuildStatePath $ctx.build_state_path -Cursor $Seq
        }
    }
    Write-DtJobOutput -Object (Get-DtJobRunSummary -Context $ctx) -AsJson:$Json
}

function Invoke-DtJobRequestContinuation {
    $ctx = Resolve-DtJobRunContext -RunFolder $RunFolder -BuildStatePath $BuildStatePath -RunId $RunId
    Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $state = Get-DtJobRunState -BuildStatePath $ctx.build_state_path
        Add-DtJobEvent -RunFolder $RunFolder -JobId 'run' -Type 'continuation_requested' -Status $state.run_status -Reason $(if ($Reason) { $Reason } else { 'continuation requested' })
    }
    Write-DtJobOutput -Object (Get-DtJobRunSummary -Context $ctx) -AsJson:$Json
}

function Invoke-DtJobAwaitDanny {
    if (-not $Operation -or -not $Message) { throw 'DT_JOB_USAGE: await-danny requires -Operation and -Message.' }
    $ctx = Resolve-DtJobRunContext -RunFolder $RunFolder -BuildStatePath $BuildStatePath -RunId $RunId
    $awaitSeq = Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $approvals = Get-DtJobApprovals -RunFolder $RunFolder
        $pending = $approvals.awaiting
        $state = Get-DtJobRunState -BuildStatePath $ctx.build_state_path
        if ($null -ne $pending -and [string]$pending.operation -ceq $Operation -and $pending.PSObject.Properties['seq'] -and $state.run_status -eq 'awaiting_danny') {
            # The same boundary asked again keeps its event, so its DM key (and its one DM) stay the same.
            [int64]$pending.seq
        }
        else {
            Set-DtJobRunState -BuildStatePath $ctx.build_state_path -RunStatus 'awaiting_danny'
            Add-DtJobEvent -RunFolder $RunFolder -JobId 'run' -Type 'awaiting_danny' -Status 'awaiting_danny' -Reason "operation $Operation"
            $seq = Get-DtJobLastEventSeq -RunFolder $RunFolder
            $approvals.awaiting = [ordered]@{ operation = $Operation; message = $Message; since_utc = [DateTime]::UtcNow.ToString('o'); seq = $seq }
            Save-DtJobApprovals -RunFolder $RunFolder -Approvals $approvals
            $seq
        }
    }
    $text = "dt-build run $($ctx.run_id) is paused for your approval before: $Operation. $Message To approve, run: /dt-build approve $($ctx.run_id) $Operation"
    # Every boundary gets its own key (the await event's seq), so a later boundary for the same operation DMs again.
    $alert = Send-DtJobRunAlert -RunFolder $RunFolder -Key "dt-build:$($ctx.run_id):awaiting:${Operation}:$awaitSeq" -Message $text -RetryUntilDelivered
    Write-DtJobOutput -Object (Get-DtJobRunSummary -Context $ctx -Extra @{ operation = $Operation; alert = $alert; await_seq = $awaitSeq }) -AsJson:$Json
}

function Assert-DtJobOperator {
    # approve and resume are Danny's commands: a coordinator or a job can never release its own boundary.
    param([Parameter(Mandatory)][string]$VerbName, [Parameter(Mandatory)][string]$RunFolder)
    if ($env:DT_BUILD_COORDINATOR_ID) { throw "DT_JOB_OPERATOR_ONLY: $VerbName is Danny's command; coordinator $env:DT_BUILD_COORDINATOR_ID cannot run it" }
    if ($env:DT_JOB_ID) { throw "DT_JOB_OPERATOR_ONLY: $VerbName is Danny's command; it cannot run inside dt-job job $env:DT_JOB_ID" }
    # The env checks can be bypassed by clearing a variable; a live watcher-launched coordinator cannot hide its process.
    $lease = Get-DtJobLease -RunFolder $RunFolder
    if ($null -ne $lease -and $lease.launched_by -eq 'watcher') {
        $leaseStart = if ($lease.PSObject.Properties['pid_start_utc']) { $lease.pid_start_utc } else { $null }
        if (Test-DtJobProcessIdentity $lease.pid $leaseStart) { throw "DT_JOB_OPERATOR_ONLY: $VerbName is Danny's command; watcher-launched coordinator $($lease.coordinator_id) is still running as pid $($lease.pid)" }
    }
}

function Invoke-DtJobApprove {
    if (-not $Operation) { throw 'DT_JOB_USAGE: approve requires -Operation.' }
    Assert-DtJobOperator -VerbName 'approve' -RunFolder $RunFolder
    $ctx = Resolve-DtJobRunContext -RunFolder $RunFolder -BuildStatePath $BuildStatePath -RunId $RunId
    Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $approvals = Get-DtJobApprovals -RunFolder $RunFolder
        if ($null -eq $approvals.awaiting) { throw "DT_JOB_NOT_AWAITING: run $($ctx.run_id) is not waiting on an approval" }
        if ([string]$approvals.awaiting.operation -cne $Operation) {
            throw "DT_JOB_APPROVE_MISMATCH: run $($ctx.run_id) waits on '$($approvals.awaiting.operation)', not '$Operation'; nothing recorded"
        }
        $approvals.approvals = @($approvals.approvals) + @([pscustomobject][ordered]@{ operation = $Operation; approved_utc = [DateTime]::UtcNow.ToString('o') })
        $approvals.awaiting = $null
        Save-DtJobApprovals -RunFolder $RunFolder -Approvals $approvals
        Set-DtJobRunState -BuildStatePath $ctx.build_state_path -RunStatus 'runnable'
        Add-DtJobEvent -RunFolder $RunFolder -JobId 'run' -Type 'continuation_requested' -Status 'runnable' -Reason "approved $Operation"
    }
    Write-DtJobOutput -Object (Get-DtJobRunSummary -Context $ctx -Extra @{ approved = $Operation }) -AsJson:$Json
}

function Invoke-DtJobResume {
    Assert-DtJobOperator -VerbName 'resume' -RunFolder $RunFolder
    $ctx = Resolve-DtJobRunContext -RunFolder $RunFolder -BuildStatePath $BuildStatePath -RunId $RunId
    Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $pending = (Get-DtJobApprovals -RunFolder $RunFolder).awaiting
        if ($null -ne $pending) { throw "DT_JOB_RESUME_AWAITING_APPROVAL: run $($ctx.run_id) waits on '$($pending.operation)'; use approve" }
        if ((Get-DtJobRunState -BuildStatePath $ctx.build_state_path).run_status -eq 'finished') { throw "DT_JOB_RUN_FINISHED: run $($ctx.run_id) is finished" }
        Set-DtJobRunState -BuildStatePath $ctx.build_state_path -RunStatus 'runnable'
        Add-DtJobEvent -RunFolder $RunFolder -JobId 'run' -Type 'continuation_requested' -Status 'runnable' -Reason 'resume'
    }
    Write-DtJobOutput -Object (Get-DtJobRunSummary -Context $ctx) -AsJson:$Json
}

function Invoke-DtJobFinish {
    $ctx = Resolve-DtJobRunContext -RunFolder $RunFolder -BuildStatePath $BuildStatePath -RunId $RunId
    Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        Set-DtJobRunState -BuildStatePath $ctx.build_state_path -RunStatus 'finished'
        Add-DtJobEvent -RunFolder $RunFolder -JobId 'run' -Type 'finished' -Status 'finished'
    }
    $removed = Remove-DtJobRegistryEntry -RunFolder $RunFolder
    Write-DtJobOutput -Object (Get-DtJobRunSummary -Context $ctx -Extra @{ unregistered = [int]$removed }) -AsJson:$Json
}

function Get-DtJobContextBaselines {
    param([Parameter(Mandatory)][string]$RunFolder)
    $path = (Get-DtJobPaths -RunFolder $RunFolder).ContextBaseline
    $empty = [pscustomobject]@{ coordinators = [pscustomobject]@{} }
    if (-not (Test-Path -LiteralPath $path)) { return $empty }
    $parsed = Read-DtJobText -Path $path | ConvertFrom-Json
    if ($null -eq $parsed -or -not $parsed.PSObject.Properties['coordinators'] -or $null -eq $parsed.coordinators) { return $empty }
    return $parsed
}

function Get-DtJobContextBaseline {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$CoordinatorId)
    $prop = (Get-DtJobContextBaselines -RunFolder $RunFolder).coordinators.PSObject.Properties[$CoordinatorId]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-DtJobIrreversibleOpen {
    # Open irreversible steps, oldest first; while any is open, rotation and watcher termination wait.
    param([Parameter(Mandatory)][string]$RunFolder)
    $path = (Get-DtJobPaths -RunFolder $RunFolder).Irreversible
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $parsed = Read-DtJobText -Path $path | ConvertFrom-Json
    if ($null -eq $parsed -or -not $parsed.PSObject.Properties['open']) { return @() }
    return @($parsed.open | Where-Object { $null -ne $_ })
}

function Resolve-DtJobContextHost {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$CoordinatorId, [string]$RequestedHost)
    if ($RequestedHost) { return $RequestedHost }
    $lease = Get-DtJobLease -RunFolder $RunFolder
    if ($null -ne $lease -and $lease.coordinator_id -eq $CoordinatorId -and $lease.PSObject.Properties['host'] -and $lease.host) { return [string]$lease.host }
    return $null
}

function Get-DtJobContextReport {
    # The coordinator's context state: with a bootstrap marker, its recorded transcript and baseline;
    # before one, the transcript discovered for this cwd against the absolute ceiling.
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$CoordinatorId, [string]$RequestedHost)
    try {
        $open = @((Split-DtCtxIrreversibleSteps -Open @(Get-DtJobIrreversibleOpen -RunFolder $RunFolder) -Lease (Get-DtJobLease -RunFolder $RunFolder)).deferring)
        $entry = Get-DtJobContextBaseline -RunFolder $RunFolder -CoordinatorId $CoordinatorId
        if ($null -ne $entry) {
            $tokens = Get-DtCtxTokens -TranscriptHost ([string]$entry.host) -TranscriptPath ([string]$entry.transcript_path)
            $report = Get-DtCtxState -Tokens $tokens -Baseline ([long]$entry.baseline_tokens)
        }
        else {
            $ctxHost = Resolve-DtJobContextHost -RunFolder $RunFolder -CoordinatorId $CoordinatorId -RequestedHost $RequestedHost
            if (-not $ctxHost) { throw 'host unknown before mark-bootstrap' }
            $transcript = Find-DtCtxTranscript -TranscriptHost $ctxHost
            $report = Get-DtCtxState -Tokens (Get-DtCtxTokens -TranscriptHost $ctxHost -TranscriptPath $transcript) -Baseline $null
        }
    }
    catch {
        # An unreadable context never breaks a verb; it is reported, and nothing is refused on it.
        $line = Limit-DtJobContextLine "context: unavailable ($([string]$_.Exception.Message))"
        return [pscustomobject][ordered]@{ tokens = $null; state = 'unknown'; deferred = $false; line = $line }
    }
    # Only a step the current lease holder opened defers rotation; a stale one is the watcher's to report.
    $deferred = ($report.state -eq 'rotate' -and $open.Count -gt 0)
    $line = $report.line
    if ($deferred) { $line = "$line; rotation deferred: irreversible $($open[0].operation) open" }
    $report | Add-Member -NotePropertyName deferred -NotePropertyValue $deferred
    $report.line = Limit-DtJobContextLine $line
    return $report
}

function Limit-DtJobContextLine {
    # The context line fits the bytes reserved for it inside the envelope cap, newline included.
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }
    $max = $script:DtJobContextReserveBytes - 2
    $utf8 = [System.Text.Encoding]::UTF8
    if ($utf8.GetByteCount($Text) -le $max) { return $Text }
    $marker = ' ...[truncated]'
    $keep = [Math]::Min($Text.Length, $max - $marker.Length)
    while ($keep -gt 0 -and $utf8.GetByteCount($Text.Substring(0, $keep)) -gt $max - $marker.Length) { $keep-- }
    # Never end on half a surrogate pair.
    if ($keep -gt 0 -and [char]::IsHighSurrogate($Text[$keep - 1])) { $keep-- }
    return $Text.Substring(0, $keep) + $marker
}

function Invoke-DtJobMarkBootstrap {
    $coordinator = if ($CoordinatorId) { $CoordinatorId } else { $env:DT_BUILD_COORDINATOR_ID }
    if (-not $coordinator) { throw 'DT_JOB_USAGE: mark-bootstrap requires -CoordinatorId.' }
    $paths = Get-DtJobPaths -RunFolder $RunFolder
    $result = Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        # Once per coordinator session: a second call returns the stored baseline unchanged.
        $existing = Get-DtJobContextBaseline -RunFolder $RunFolder -CoordinatorId $coordinator
        if ($null -ne $existing) { return [pscustomobject]@{ entry = $existing; marked = $false } }
        $ctxHost = Resolve-DtJobContextHost -RunFolder $RunFolder -CoordinatorId $coordinator -RequestedHost $CoordinatorHost
        if (-not $ctxHost) { throw 'DT_JOB_USAGE: mark-bootstrap requires -Host claude|codex.' }
        # A discovered transcript is a guess: its session is not recorded, so the hooks never treat that
        # session as this coordinator. The Claude PostToolUse hook later records the caller's own session.
        $source = if ($TranscriptPath) { 'explicit' } else { 'discovered' }
        $transcript = if ($TranscriptPath) { [System.IO.Path]::GetFullPath($TranscriptPath) } else { Find-DtCtxTranscript -TranscriptHost $ctxHost }
        $tokens = Get-DtCtxTokens -TranscriptHost $ctxHost -TranscriptPath $transcript
        if ($null -eq $tokens) { throw "DT_JOB_CONTEXT_UNREADABLE: no $ctxHost token usage in $transcript yet; nothing marked" }
        $new = [pscustomobject][ordered]@{
            coordinator_id  = $coordinator
            host            = $ctxHost
            transcript_path = $transcript
            session_id      = $(if ($source -eq 'explicit') { Get-DtCtxSessionId -TranscriptHost $ctxHost -TranscriptPath $transcript } else { $null })
            transcript_source = $source
            baseline_tokens = [long]$tokens
            marked_utc      = [DateTime]::UtcNow.ToString('o')
        }
        $all = Get-DtJobContextBaselines -RunFolder $RunFolder
        $all.coordinators | Add-Member -NotePropertyName $coordinator -NotePropertyValue $new -Force
        Write-DtJobAtomic -Path $paths.ContextBaseline -Content ($all | ConvertTo-Json -Depth 6)
        return [pscustomobject]@{ entry = $new; marked = $true }
    }
    $script:DtJobContext = Get-DtJobContextReport -RunFolder $RunFolder -CoordinatorId $coordinator
    $out = [pscustomobject][ordered]@{
        coordinator_id  = $result.entry.coordinator_id
        host            = $result.entry.host
        transcript_path = $result.entry.transcript_path
        baseline_tokens = $result.entry.baseline_tokens
        marked_utc      = $result.entry.marked_utc
        newly_marked    = $result.marked
    }
    Write-DtJobOutput -Object $out -AsJson:$Json
}

function Invoke-DtJobIrreversible {
    if (@('begin', 'end') -notcontains $Action) { throw 'DT_JOB_USAGE: irreversible requires -Action begin|end.' }
    if (-not $Operation) { throw 'DT_JOB_USAGE: irreversible requires -Operation.' }
    # An unowned step would never defer rotation and would draw a false stale alert.
    if ($Action -eq 'begin' -and -not $CoordinatorId -and -not $env:DT_BUILD_COORDINATOR_ID) { throw 'DT_JOB_USAGE: irreversible -Action begin requires -CoordinatorId or DT_BUILD_COORDINATOR_ID.' }
    $paths = Get-DtJobPaths -RunFolder $RunFolder
    # Invoke-DtJobLocked's own -Action shadows $Action inside the block.
    $stepAction = $Action
    $open = Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $steps = @(Get-DtJobIrreversibleOpen -RunFolder $RunFolder)
        if ($stepAction -eq 'begin') {
            if (@($steps | Where-Object { [string]$_.operation -ceq $Operation }).Count -eq 0) {
                $who = if ($CoordinatorId) { $CoordinatorId } elseif ($env:DT_BUILD_COORDINATOR_ID) { $env:DT_BUILD_COORDINATOR_ID } else { $null }
                $steps = @($steps) + @([pscustomobject][ordered]@{ operation = $Operation; coordinator_id = $who; began_utc = [DateTime]::UtcNow.ToString('o') })
            }
        }
        else { $steps = @($steps | Where-Object { [string]$_.operation -cne $Operation }) }
        Write-DtJobAtomic -Path $paths.Irreversible -Content ([ordered]@{ open = @($steps) } | ConvertTo-Json -Depth 4)
        , @($steps | ForEach-Object { [string]$_.operation })
    }
    Write-DtJobOutput -Object ([pscustomobject][ordered]@{ action = $Action; operation = $Operation; open = @($open) }) -AsJson:$Json
}

function Get-DtJobTreeHash {
    # The working-state tree hash: everything, tracked (including files force-added despite .gitignore),
    # untracked (respecting .gitignore), and binary, staged into a temporary index and written as a tree.
    # The continuation record (-ExcludePath, and the default .dt-build-continuation.md at the root) is
    # left out, so writing it never changes the hash. The real index is never touched.
    param([Parameter(Mandatory)][string]$WorkingTree, [string[]]$ExcludePath = @())
    if (-not (Test-Path -LiteralPath $WorkingTree -PathType Container)) { throw "DT_JOB_TREE_HASH: working tree not found: $WorkingTree" }
    $root = @(& git -C $WorkingTree rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $root) { throw "DT_JOB_TREE_HASH: not a git working tree: $WorkingTree" }
    $top = [System.IO.Path]::GetFullPath([string]$root[0])
    # Tracked files the real index holds that .gitignore matches; `git add -A` alone skips them. ls-files only reads.
    $listed = (@(& git -C $top ls-files -ci --exclude-standard -z 2>$null) -join '')
    if ($LASTEXITCODE -ne 0) { throw 'DT_JOB_TREE_HASH: git ls-files failed' }
    $ignoredTracked = @($listed -split "`0" | Where-Object { $_ } | Select-Object -Unique)
    $excluded = [System.Collections.Generic.List[string]]::new()
    $excluded.Add('.dt-build-continuation.md')
    foreach ($path in @($ExcludePath | Where-Object { $_ })) {
        $full = [System.IO.Path]::GetFullPath($path, $top)
        $relative = [System.IO.Path]::GetRelativePath($top, $full)
        if ($relative -ne '.' -and -not $relative.StartsWith('..') -and -not [System.IO.Path]::IsPathRooted($relative)) { $excluded.Add($relative.Replace('\', '/')) }
    }
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dt-job-tree-hash-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $priorIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = Join-Path $tempDir 'index'
        # Seed from HEAD so tracked files stay in the set; a repository with no commit yet starts empty.
        & git -C $top rev-parse --verify --quiet HEAD *> $null
        if ($LASTEXITCODE -eq 0) {
            $seedOutput = @(& git -C $top read-tree HEAD 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "DT_JOB_TREE_HASH: git read-tree HEAD failed: $(($seedOutput | Select-Object -Last 3) -join ' ')" }
        }
        $addOutput = @(& git -C $top add -A 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "DT_JOB_TREE_HASH: git add -A failed: $(($addOutput | Select-Object -Last 3) -join ' ')" }
        $present = @($ignoredTracked | Where-Object { Test-Path -LiteralPath (Join-Path $top $_) -PathType Leaf })
        if ($present.Count -gt 0) {
            $forceOutput = @(& git --literal-pathspecs -C $top add -f -- @present 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "DT_JOB_TREE_HASH: git add -f failed: $(($forceOutput | Select-Object -Last 3) -join ' ')" }
        }
        $dropOutput = @(& git --literal-pathspecs -C $top rm --cached -q -r --ignore-unmatch -- @excluded 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "DT_JOB_TREE_HASH: git rm --cached failed: $(($dropOutput | Select-Object -Last 3) -join ' ')" }
        $tree = @(& git -C $top write-tree 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $tree -or [string]$tree[0] -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') { throw 'DT_JOB_TREE_HASH: git write-tree failed' }
        return [string]$tree[0]
    }
    finally {
        if ($null -eq $priorIndex) { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue } else { $env:GIT_INDEX_FILE = $priorIndex }
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-DtJobCanReuse {
    # Whether a recorded test result may stand in for a rerun: the record validates, holds a test with this
    # exact command and exit_code 0, and its tree hash equals the current one. Any failure means rerun.
    param([string]$RecordPath, [string]$TestCommand, [string]$WorkingTree)
    $no = { param($why) [pscustomobject][ordered]@{ reuse = $false; reason = $why } }
    if (-not $RecordPath -or -not $TestCommand -or -not $WorkingTree) { return (& $no 'can-reuse requires -Record, -Command, and -WorkingTree') }
    try {
        $checked = Get-DtContinuationRecord -Path $RecordPath
        if (@($checked.errors).Count -gt 0) { return (& $no ("record invalid: " + (@($checked.errors) -join '; '))) }
        $matching = @($checked.record['tests'] | Where-Object { [string]$_['command'] -ceq $TestCommand })
        if ($matching.Count -eq 0) { return (& $no 'no recorded test with this exact command') }
        $passing = @($matching | Where-Object { [long]$_['exit_code'] -eq 0 })
        if ($passing.Count -eq 0) { return (& $no 'the recorded test did not pass') }
        $current = Get-DtJobTreeHash -WorkingTree $WorkingTree -ExcludePath @($RecordPath)
        $hit = @($passing | Where-Object { [string]$_['tree_hash'] -ceq $current }) | Select-Object -First 1
        if ($null -eq $hit) { return (& $no "tree hash changed: current $current") }
        return [pscustomobject][ordered]@{ reuse = $true; reason = "tree hash $current matches"; evidence_path = [string]$hit['evidence_path'] }
    }
    catch { return (& $no ("cannot decide: " + $_.Exception.Message)) }
}

# Dot-sourcing (the runner does) loads the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

# Worker-side verbs: no run folder, lease, or context line.
if ($Verb -eq 'tree-hash') {
    if (-not $WorkingTree) { throw 'DT_JOB_USAGE: tree-hash requires -WorkingTree.' }
    $hash = Get-DtJobTreeHash -WorkingTree $WorkingTree -ExcludePath @($Record)
    if ($Json) { [pscustomobject][ordered]@{ working_tree = $WorkingTree; tree_hash = $hash } | ConvertTo-Json -Compress } else { $hash }
    exit 0
}
if ($Verb -eq 'can-reuse') {
    $decision = Test-DtJobCanReuse -RecordPath $Record -TestCommand $Command -WorkingTree $WorkingTree
    if ($Json) { $decision | ConvertTo-Json -Compress } elseif ($decision.reuse) { 'true' } else { "false: $($decision.reason)" }
    exit 0
}

if (-not $Verb) { throw 'DT_JOB_USAGE: -Verb is required (start, status, wait, cancel, reconcile, lease, register-run, unregister-run, consume, request-continuation, await-danny, approve, resume, finish, mark-bootstrap, irreversible, tree-hash, can-reuse).' }
if (-not $RunFolder) { throw 'DT_JOB_USAGE: -RunFolder is required.' }
$script:DtJobExplicitParams = @($PSBoundParameters.Keys)

# Under `pwsh -File`, `-Mutates a,b` arrives as the single string 'a,b'; split every list on commas.
$DependsOn = Split-DtJobList $DependsOn
$Mutates = Split-DtJobList $Mutates
$PassEnv = Split-DtJobList $PassEnv
# -JobId stays a string for the single-job verbs; wait reads a comma- or space-separated list from it.
$script:DtJobIds = @(([string]$JobId) -split '[,\s]+' | Where-Object { $_ })

# An interactive coordinator's shell keeps no env, so -CoordinatorId identifies it on every call. It counts
# like DT_BUILD_COORDINATOR_ID for renewal and context, never for the operator-only refusal.
$script:DtJobCoordinator = if ($CoordinatorId) { $CoordinatorId } elseif ($env:DT_BUILD_COORDINATOR_ID) { $env:DT_BUILD_COORDINATOR_ID } else { $null }

# Every verb except lease itself renews the caller's lease when it holds it.
if ($script:DtJobCoordinator -and $Verb -ne 'lease') {
    try { [void](Update-DtJobLeaseIfHolder -RunFolder $RunFolder -CoordinatorId $script:DtJobCoordinator) } catch { }
}

# A coordinator's every call reports its context; only start is ever refused on it.
if ($script:DtJobCoordinator) {
    if ($Verb -ne 'mark-bootstrap') { $script:DtJobContext = Get-DtJobContextReport -RunFolder $RunFolder -CoordinatorId $script:DtJobCoordinator -RequestedHost $CoordinatorHost }
    $script:DtJobEnvelopeMaxBytes -= $script:DtJobContextReserveBytes
}

$verbOutput = switch ($Verb) {
    'start' { Invoke-DtJobStart }
    'status' { Invoke-DtJobStatus }
    'wait' { Invoke-DtJobWait }
    'cancel' { Invoke-DtJobCancel }
    'reconcile' { Invoke-DtJobReconcile }
    'lease' { Invoke-DtJobLease }
    'register-run' { Invoke-DtJobRegisterRun }
    'unregister-run' { Invoke-DtJobUnregisterRun }
    'consume' { Invoke-DtJobConsume }
    'request-continuation' { Invoke-DtJobRequestContinuation }
    'await-danny' { Invoke-DtJobAwaitDanny }
    'approve' { Invoke-DtJobApprove }
    'resume' { Invoke-DtJobResume }
    'finish' { Invoke-DtJobFinish }
    'mark-bootstrap' { Invoke-DtJobMarkBootstrap }
    'irreversible' { Invoke-DtJobIrreversible }
}
$verbOutput
if ($null -ne $script:DtJobContext -and -not $Json) { $script:DtJobContext.line }
