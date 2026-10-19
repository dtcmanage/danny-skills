#Requires -Version 7.0
param(
    [ValidateSet('start', 'requeue', 'status', 'wait', 'cancel', 'reconcile', 'lease', 'register-run', 'unregister-run', 'pin', 'consume', 'request-continuation', 'await-danny', 'approve', 'delegate', 'hold', 'note', 'resume', 'finish', 'mark-bootstrap', 'irreversible', 'tree-hash', 'can-reuse')]
    [string]$Verb,

    [string]$RunFolder,

    [string]$JobId,

    [string]$FromJob,

    [string]$PromptPath,

    [string]$OutputPath,

    [switch]$AllowTempRunFolder,

    [string]$Command,

    # Optional spec field exclusive_reason; default jobs run directly.
    # See dt-job-usage.md for policy and examples.
    [string]$ExclusiveReason,

    [string]$ScriptPath,

    [string[]]$ArgumentList = @(),

    [ValidateSet('worker', 'test', 'command')]
    [string]$Kind = 'command',

    [string[]]$DependsOn = @(),

    [string[]]$Mutates = @(),

    [string]$Category,

    [string]$Vendor,

    [string]$Model,

    [ValidateSet('codex', 'claude')]
    [string]$PinVendor,

    [string]$PinModel,

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

    [string]$Delegate,

    [string]$NoteId,

    [switch]$Clear,

    [switch]$Evidence,

    [switch]$AlwaysNotify,

    [string]$TranscriptPath,

    [string]$WorkingTree,

    [string]$Record,

    [switch]$Json
)

$DtJobSkillRoot = Split-Path -Parent $PSScriptRoot
$DtJobResolvedSkillRoot = $null
try { $DtJobResolvedSkillRoot = (Get-Item -LiteralPath $DtJobSkillRoot).ResolveLinkTarget($true) } catch { }
if ($DtJobResolvedSkillRoot) { $DtJobSkillRoot = $DtJobResolvedSkillRoot.FullName }
$DtJobRepoRoot = Split-Path -Parent (Split-Path -Parent $DtJobSkillRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DtJobStatuses = @('queued', 'running', 'succeeded', 'failed', 'timeout', 'orphaned', 'cancelled', 'blocked')
$script:DtJobActive = @('queued', 'running')
$script:DtJobEnvelopeMaxBytes = 8192
$script:DtJobLineMaxChars = 400
$script:DtJobExcerptLines = 40
$script:DtJobLaunchGraceSec = 60
$script:DtJobMoveRetryMs = 2000
$script:DtJobStderrExcerptLines = 10
$script:DtJobEnvAllow = @('CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'PATH')
$script:DtJobEnvSensitive = @('*TOKEN*', '*SECRET*', '*KEY*', '*PASSWORD*')
# Coordinator identity never reaches a job: a job's dt-job calls must not renew a dead coordinator's lease.
$script:DtJobEnvExclude = @('DT_BUILD_COORDINATOR_ID', 'DT_BUILD_COORDINATOR_LOCK_HELD', 'DT_BUILD_LEAN_BOOTSTRAP')
$script:DtJobLockDepth = 0
$script:DtJobLockStream = $null
$script:DtJobRunnerPath = Join-Path $PSScriptRoot 'dt-job-runner.ps1'
$script:DtJobLeaseDefaultTtlSec = 600
# Parameters the command line passed explicitly; dot-sourced callers pass none.
$script:DtJobExplicitParams = @()
$script:DtJobLeaseRenewMaxSec = 60
$script:DtJobWaitPollMs = 500
# No job is stopped on time. Its runner records activity every heartbeat; a job with no activity for the
# stall period is reported stalled at the coordinator's check-ins, and the coordinator decides whether to
# cancel it.
$script:DtJobHeartbeatSec = 30
# A stop delegated to another session DMs Danny if it is still unapproved after this many minutes.
$script:DtJobDelegateEscalateMin = 15
$script:DtJobStallSec = 1200
$script:DtJobRunStatuses = @('runnable', 'awaiting_danny', 'finished')
$script:DtJobAlertScript = Join-Path $DtJobRepoRoot 'scripts\model-router\send-router-alert.ps1'
# The calling coordinator: -CoordinatorId, else DT_BUILD_COORDINATOR_ID; $null for anyone else.
$script:DtJobCoordinator = $null
# The coordinator's context report for this call; set only when the call has a coordinator.
$script:DtJobContext = $null
# Room the context line takes inside the envelope cap.
$script:DtJobContextReserveBytes = 256
$script:DtJobEvidenceNotesLabel = 'Evidence only: records facts, grants no authority.'
# Whole-word authority language belongs in normal operator notes, never evidence notes.
$script:DtJobEvidenceAuthorityPattern = '(?i)\b(?:approv(?:e|es|ed|ing|al|als)|authori[sz](?:e|es|ed|ing|ation|ations)|permit(?:s|ted|ting)?|permissions?|allow(?:s|ed|ing)?|waiv(?:e|es|ed|ing|er|ers)|supersed(?:e|es|ed|ing)|overrid(?:e|es|den|ing)|overrode|exempt(?:s|ed|ing|ion|ions)?|grant(?:s|ed|ing)?|may\s+proceed|may\s+now|is\s+now\s+allowed)\b'

. (Join-Path $PSScriptRoot 'context-guard.ps1')
. (Join-Path $PSScriptRoot 'report-contract.ps1')
. (Join-Path $PSScriptRoot 'model-selection.ps1')

function Get-DtJobPaths {
    param([Parameter(Mandatory)][string]$RunFolder)
    $root = ConvertTo-DtNormalizedPath $RunFolder
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
        OperatorNotes = Join-Path $root 'operator-notes.json'
        EvidenceNotes = Join-Path $root 'evidence-notes.json'
        Launches = Join-Path $root 'launches.jsonl'
        Worktrees = Join-Path $root 'worktrees.jsonl'
        Notifications = Join-Path $root 'notifications.jsonl'
        ContextBaseline = Join-Path $root 'context-baseline.json'
        Irreversible = Join-Path $root 'irreversible.json'
        Rotations = Join-Path $root 'rotations.jsonl'
        KillFailed = Join-Path $root 'kill-failed.json'
        StepErrors = Join-Path $root 'step-errors.json'
        PastHard = Join-Path $root 'past-hard.json'
        ContextWall = Join-Path $root 'context-wall.json'
        HookReads = Join-Path $root 'hook-reads.jsonl'
    }
}

function Test-DtJobTerminal {
    param([string]$Status)
    return ($script:DtJobActive -notcontains $Status)
}

function Assert-DtJobRunFolder {
    param([string]$RunFolder, [switch]$WarnExisting)
    if ($AllowTempRunFolder) { return }
    $root = [IO.Path]::GetFullPath($RunFolder).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    foreach ($temp in @([IO.Path]::GetTempPath(), $env:TEMP, $env:TMP)) {
        if (-not $temp) { continue }
        $normalized = [IO.Path]::GetFullPath($temp).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if ($root.Equals($normalized, [StringComparison]::OrdinalIgnoreCase) -or $root.StartsWith($normalized + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            $message = 'DT_JOB_TEMP_RUN_FOLDER: use <project root>/.dt-build/adhoc/ for durable ad-hoc jobs, or pass -AllowTempRunFolder.'
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw $message }
            if ($WarnExisting) { [Console]::Error.WriteLine("WARNING: $message Existing temp run folder accepted: $root") }
            return
        }
    }
}

function Set-DtJobCommandArgument {
    # Parse argument extents so quoted text and similarly named parameters are never replaced.
    param([string]$Command, [string]$Name, [string]$Value)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$errors)
    $values = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object {
        $elements = $_.CommandElements
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $element = $elements[$i]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst] -or $element.ParameterName -ine $Name) { continue }
            if ($null -ne $element.Argument) { $element.Argument.Extent }
            elseif ($i + 1 -lt $elements.Count -and $elements[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) { $elements[$i + 1].Extent }
        }
    })
    if ($values.Count -eq 0) { throw "DT_JOB_FROMJOB_NO_ARG: stored command has no -$Name argument." }
    $quoted = "'" + $Value.Replace("'", "''") + "'"
    foreach ($extent in @($values | Sort-Object StartOffset -Descending)) {
        $Command = $Command.Substring(0, $extent.StartOffset) + $quoted + $Command.Substring($extent.EndOffset)
    }
    return $Command
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
    return (Resolve-DtJobRecordPaths -RunFolder $RunFolder -Record (Read-DtJobText -Path $path | ConvertFrom-Json))
}

function Resolve-DtJobRecordPaths {
    # Ledger-owned evidence follows a copied run folder; command input/output paths stay untouched.
    param([string]$RunFolder, $Record)
    $jobDir = Join-Path (Get-DtJobPaths -RunFolder $RunFolder).Jobs $Record.job_id
    foreach ($field in @{ output_path = 'stdout.log'; stderr_path = 'stderr.log'; summary_path = 'summary.json' }.GetEnumerator()) {
        if ($Record.PSObject.Properties[$field.Key]) { $Record.($field.Key) = Join-Path $jobDir $field.Value }
    }
    return $Record
}

function Get-DtJobRecords {
    param([Parameter(Mandatory)][string]$RunFolder)
    $jobsDir = (Get-DtJobPaths -RunFolder $RunFolder).Jobs
    if (-not (Test-Path -LiteralPath $jobsDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $jobsDir -File -Filter 'j-*.json' | Sort-Object Name | ForEach-Object {
        Resolve-DtJobRecordPaths -RunFolder $RunFolder -Record (Read-DtJobText -Path $_.FullName | ConvertFrom-Json)
    })
}

function Save-DtJobRecord {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)]$Record)
    $path = Join-Path (Get-DtJobPaths -RunFolder $RunFolder).Jobs "$($Record.job_id).json"
    Write-DtJobAtomic -Path $path -Content ($Record | ConvertTo-Json -Depth 8)
}

function Add-DtJobEvent {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$JobId, [Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)][string]$Status, [string]$Reason, [string]$RequestedBy, [Nullable[long]]$ConsumedEventSeq, [string]$RelaunchedFrom)
    if (-not $RelaunchedFrom -and $Type -in @('launched', 'process_started')) {
        $record = Get-DtJobRecord -RunFolder $RunFolder -JobId $JobId
        if ($null -ne $record -and $record.PSObject.Properties['relaunched_from']) { $RelaunchedFrom = $record.relaunched_from }
    }
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
    if ($RelaunchedFrom) { $evt.relaunched_from = $RelaunchedFrom }
    if ($RequestedBy) { $evt.requested_by = $RequestedBy }
    if ($null -ne $ConsumedEventSeq) { $evt.consumed_event_seq = [long]$ConsumedEventSeq }
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

function Test-DtJobSameInstant {
    # FS-95: timestamps compare as instants, never as text ('.5441830Z' and '.544183Z' are equal).
    param($Left, $Right)
    if ($null -eq $Left -or $null -eq $Right -or '' -eq [string]$Left -or '' -eq [string]$Right) { return ($null -eq $Left -or '' -eq [string]$Left) -and ($null -eq $Right -or '' -eq [string]$Right) }
    try { return (ConvertTo-DtJobUtc $Left).Ticks -eq (ConvertTo-DtJobUtc $Right).Ticks } catch { return $false }
}

function ConvertFrom-DtJobJsonText {
    # FS-95: files dt-job rewrites keep their timestamp text byte-for-byte. Default ConvertFrom-Json turns
    # ISO strings into DateTime and ConvertTo-Json writes them back without trailing zeros.
    param([Parameter(Mandatory, ValueFromPipeline)][string]$Text)
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return ($Text | ConvertFrom-Json -DateKind String) }
    return ($Text | ConvertFrom-Json)
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

function Get-DtJobDescendants {
    # Every live process under the roots, by parent id, each with its start time so a reused PID is never killed.
    param([int[]]$RootPids)
    if (-not $IsWindows -or $RootPids.Count -eq 0) { return @() }
    $all = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, CreationDate -ErrorAction SilentlyContinue)
    $children = @{}
    foreach ($p in $all) { $key = [int]$p.ParentProcessId; if (-not $children.ContainsKey($key)) { $children[$key] = [System.Collections.Generic.List[object]]::new() }; $children[$key].Add($p) }
    $found = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new(); foreach ($r in $RootPids) { $queue.Enqueue($r) }
    while ($queue.Count -gt 0) {
        $id = $queue.Dequeue()
        if (-not $seen.Add($id) -or -not $children.ContainsKey($id)) { continue }
        foreach ($c in $children[$id]) {
            # A child must start after its parent; a reused parent id never adopts older processes.
            $found.Add([pscustomobject]@{ pid = [int]$c.ProcessId; start_utc = $c.CreationDate.ToUniversalTime() }); $queue.Enqueue([int]$c.ProcessId)
        }
    }
    return @($found)
}

function Stop-DtJobProcesses {
    # FS-96: snapshot the whole tree first, kill it, then kill and verify every snapshot member, so a worker
    # under a shim or a re-parented child cannot outlive cancel. Returns the processes still alive afterwards.
    param([Parameter(Mandatory)]$Record)
    $roots = @(foreach ($pair in @(@($Record.runner_pid, $Record.runner_start_utc), @($Record.pid, $Record.process_start_utc))) {
        if (Test-DtJobProcessIdentity $pair[0] $pair[1]) { [pscustomobject]@{ pid = [int]$pair[0]; start_utc = $pair[1] } }
    })
    $tree = @(Get-DtJobDescendants -RootPids @($roots | ForEach-Object { $_.pid }))
    foreach ($root in $roots) { try { (Get-Process -Id $root.pid -ErrorAction Stop).Kill($true) } catch { } }
    foreach ($member in $tree) {
        if (Test-DtJobProcessIdentity $member.pid $member.start_utc) { try { (Get-Process -Id $member.pid -ErrorAction Stop).Kill($true) } catch { } }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $alive = @(@($roots) + @($tree) | Where-Object { Test-DtJobProcessIdentity $_.pid $_.start_utc })
        if ($alive.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return @($alive | ForEach-Object { $_.pid })
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

function ConvertTo-DtJobReadableText {
    # A job's pwsh child can write its errors to a redirected stream as CLIXML ("#< CLIXML" then one long
    # <Objs> line with _xHHHH_ escapes) and colours them with ANSI codes, which buried the real message
    # past the excerpt's line cut. Unwrap the error, warning and output strings and drop the colour codes.
    param([AllowNull()][string]$Text)
    $script:DtJobLastTextDecoded = $false
    if (-not $Text) { return $Text }
    if ($Text.Contains('#< CLIXML') -or $Text.Contains('<Objs Version=')) {
        $parts = foreach ($m in [regex]::Matches($Text, '<S S="[^"]*">(.*?)(?:</S>|$)', [System.Text.RegularExpressions.RegexOptions]::Singleline)) { $m.Groups[1].Value }
        if (@($parts).Count -gt 0) {
            $decoded = [regex]::Replace((@($parts) -join ''), '_x([0-9A-Fa-f]{4})_', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
            $Text = [System.Net.WebUtility]::HtmlDecode($decoded)
            $script:DtJobLastTextDecoded = $true
        }
    }
    return [regex]::Replace($Text, '\x1b\[[0-9;?]*[A-Za-z]', '')
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
    $text = ConvertTo-DtJobReadableText $text
    $lines = @($text -split "\r?\n")
    if ($start -gt 0 -and $lines.Count -gt 0 -and -not $script:DtJobLastTextDecoded) { $lines = @($lines | Select-Object -Skip 1) }
    $lines = @($lines | Where-Object { $_ -notmatch '^\s*\|?\s*~+\s*$' })
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

function Get-DtJobWorkerOutcome {
    # Advisory worker artifacts never change the ledger or break a status/check-in.
    param([string]$RunFolder, $Record)
    $outcome = [ordered]@{ report_path = $null; report_verdict = $null; wrapper_pass = $null; failure_category = $null; termination_reason = $null }
    try {
        if ($Record.kind -ne 'worker') { return [pscustomobject]$outcome }
        $jobDir = Join-Path (Get-DtJobPaths -RunFolder $RunFolder).Jobs $Record.job_id
        $spec = Read-DtJobText -Path (Join-Path $jobDir 'spec.json') | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($spec -isnot [System.Collections.IDictionary] -or $spec['command'] -isnot [string]) { return [pscustomobject]$outcome }
        # PowerShell single-quoted strings escape an apostrophe by doubling it.
        $match = [regex]::Match($spec['command'], '(?i)(?:^|\s)-OutputPath\s+(?:''(?<single>(?:[^'']|'''')*)''|"(?<double>[^"]*)"|(?<bare>[^\s''";]+))(?=\s|;|$)')
        if (-not $match.Success) { return [pscustomobject]$outcome }
        $path = if ($match.Groups['single'].Success) { $match.Groups['single'].Value.Replace("''", "'") } elseif ($match.Groups['double'].Success) { $match.Groups['double'].Value } else { $match.Groups['bare'].Value }
        if ([string]::IsNullOrWhiteSpace($path) -or $path -match '^[\\/]{2}') { return [pscustomobject]$outcome }
        if (-not [IO.Path]::IsPathFullyQualified($path)) { $path = [IO.Path]::GetFullPath($path, [string]$Record.working_directory) }
        $outcome.report_path = $path
    } catch { return [pscustomobject]$outcome }
    try {
        $text = Read-DtJobText -Path $path
        if ($text) {
            $entries = Get-DtReportSection -Text $text -Name 'VERDICT'
            if ($null -ne $entries -and @($entries).Count -gt 0 -and $script:DtReportVerdicts -ccontains $entries[0]) { $outcome.report_verdict = $entries[0] }
        }
    } catch { }
    try {
        $provenance = Read-DtJobText -Path "$path.provenance.json" | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($provenance -is [System.Collections.IDictionary]) {
            if ($provenance['pass'] -is [bool]) { $outcome.wrapper_pass = $provenance['pass'] }
            foreach ($field in @('failure_category', 'termination_reason')) {
                if ($provenance[$field] -is [string] -and $provenance[$field]) { $outcome[$field] = $provenance[$field] }
            }
        }
    } catch { }
    return [pscustomobject]$outcome
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
    $outcome = Get-DtJobWorkerOutcome -RunFolder $RunFolder -Record $Record
    if ($Record.status -eq 'succeeded' -and ($outcome.report_verdict -in @('FAIL', 'BLOCKED') -or $outcome.wrapper_pass -eq $false)) { $verdict = 'fail' }
    $reasonCut = $false
    $reason = Limit-DtJobLine ([string]$Record.status_reason) ([ref]$reasonCut)
    if ($reasonCut) { $cut = $true; $cutPaths.Add($jobFile) }
    $blockers = [System.Collections.Generic.List[string]]::new()
    if ($Record.status_reason -and $verdict -eq 'fail') { $blockers.Add($reason) }
    if ($outcome.report_verdict -in @('FAIL', 'BLOCKED', 'PARTIAL')) {
        $blockerCut = $false
        $blockers.Add((Limit-DtJobLine "report verdict $($outcome.report_verdict); see $($outcome.report_path)" ([ref]$blockerCut)))
        if ($blockerCut) { $cut = $true; $cutPaths.Add($outcome.report_path) }
    }
    if ($outcome.wrapper_pass -eq $false) {
        $blockerCut = $false
        $blockers.Add((Limit-DtJobLine "wrapper reported failure ($($outcome.failure_category))" ([ref]$blockerCut)))
        if ($blockerCut) { $cut = $true; $cutPaths.Add("$($outcome.report_path).provenance.json") }
    }
    $categoryCut = $false
    $failureCategory = if ($null -ne $outcome.failure_category) { Limit-DtJobLine $outcome.failure_category ([ref]$categoryCut) } else { $null }
    if ($categoryCut) { $cut = $true; $cutPaths.Add("$($outcome.report_path).provenance.json") }
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
        exclusive_reason = if ($Record.PSObject.Properties['exclusive_reason']) { $Record.exclusive_reason } else { $null }
        model_selection = (Get-DtJobModelSelection -RunFolder $RunFolder -JobId $Record.job_id)
        job_id        = $Record.job_id
        relaunched_from = if ($Record.PSObject.Properties['relaunched_from']) { $Record.relaunched_from } else { $null }
        status        = $Record.status
        verdict       = $verdict
        report_verdict = $outcome.report_verdict
        failure_category = $failureCategory
        wrapper_pass  = $outcome.wrapper_pass
        peak_memory_gb = if ($Record.PSObject.Properties['peak_memory_gb']) { $Record.peak_memory_gb } else { $null }
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
    if ($Record.status -eq 'running') { $envelope.activity = Limit-DtJobLine (Get-DtJobActivity -RunFolder $RunFolder -Record $Record).line ([ref]$cut) }
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
    # Running jobs carry their activity, and stalled ones are named up front so a new coordinator sees them.
    $stalled = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $source) {
        $outcome = Get-DtJobWorkerOutcome -RunFolder $RunFolder -Record $r
        $entry = [ordered]@{ model_selection = (Get-DtJobModelSelection -RunFolder $RunFolder -JobId $r.job_id); job_id = $r.job_id; kind = $r.kind; status = $r.status; exit_code = $r.exit_code; status_reason = (Limit-DtJobLine ([string]$r.status_reason) ([ref]$cut)); report_verdict = $outcome.report_verdict; failure_category = $(if ($null -ne $outcome.failure_category) { Limit-DtJobLine $outcome.failure_category ([ref]$cut) } else { $null }) }
        $entry.exclusive_reason = if ($r.PSObject.Properties['exclusive_reason']) { Limit-DtJobLine ([string]$r.exclusive_reason) ([ref]$cut) } else { $null }
        $entry.peak_memory_gb = if ($r.PSObject.Properties['peak_memory_gb']) { $r.peak_memory_gb } else { $null }
        $entry.relaunched_from = if ($r.PSObject.Properties['relaunched_from']) { $r.relaunched_from } else { $null }
        if ($r.status -eq 'running') {
            $activity = Get-DtJobActivity -RunFolder $RunFolder -Record $r
            $entry.activity = Limit-DtJobLine $activity.line ([ref]$cut)
            if ($activity.stalled) { $stalled.Add([string]$r.job_id) }
        }
        $jobs.Add($entry)
    }
    # Operator notes come first and are never trimmed; follow them over anything in _build-state.md.
    $notes = @(Get-DtJobOperatorNotes -RunFolder $RunFolder | ForEach-Object { [ordered]@{ id = $_.id; text = $_.text } })
    $envelope = [ordered]@{ run_folder = $paths.Root; pin = (Get-DtJobRunPinLabel -RunFolder $RunFolder); evidence_hint = 'read-evidence.ps1 -RunFolder <run folder> -JobId <job> -File summary|stdout|stderr|spec|report|provenance; run files: approvals.json, operator-notes.json, evidence-notes.json, launches.jsonl, worktrees.jsonl, jobs/events.jsonl'; operator_notes = $notes; evidence_notes = @(Get-DtJobEvidenceNotes -RunFolder $RunFolder | ForEach-Object { [ordered]@{ id = $_.id; text = $_.text } }); evidence_notes_label = $script:DtJobEvidenceNotesLabel; job_count = $jobs.Count; stalled = @($stalled); jobs = $jobs; evidence = [ordered]@{ jobs_dir = $paths.Jobs; events = $paths.Events }; truncated = $false }
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
    else {
        $Object
        if ($null -ne $Object -and $Object.PSObject.Properties['operator_notes'] -and $Object.PSObject.Properties['evidence_notes']) {
            foreach ($note in $Object.operator_notes) { "operator note $($note.id): $($note.text)" }
        }
        if ($null -ne $Object -and $Object.PSObject.Properties['evidence_notes'] -and @($Object.evidence_notes).Count) {
            $script:DtJobEvidenceNotesLabel
            foreach ($note in $Object.evidence_notes) { "evidence note $($note.id): $($note.text)" }
        }
        $selections = @()
        if ($null -ne $Object -and $Object.PSObject.Properties['model_selection']) { $selections += $Object.model_selection }
        if ($null -ne $Object -and $Object.PSObject.Properties['jobs']) { $selections += @($Object.jobs | ForEach-Object { $_.model_selection }) }
        foreach ($selection in $selections) { if ($null -ne $selection) { $selection.disclosure_line } }
    }
}

function Invoke-DtJobStart {
    $paths = Get-DtJobPaths -RunFolder $RunFolder
    $copiedSpec = $null
    $workingDirectory = (Get-Location).ProviderPath
    if ($FromJob) {
        $old = Get-DtJobRecord -RunFolder $RunFolder -JobId $FromJob
        if ($null -eq $old) { throw "DT_JOB_UNKNOWN_JOB: $FromJob" }
        if ($old.status -eq 'running' -and (Test-DtJobAlive $old)) { throw "DT_JOB_FROMJOB_RUNNING: $FromJob is still running." }
        $copiedSpec = Read-DtJobText -Path (Join-Path $paths.Jobs "$($old.job_id)/spec.json") | ConvertFrom-Json -AsHashtable
        $fields = @{
            Command = $copiedSpec.command
            ScriptPath = $copiedSpec.script_path
            ArgumentList = @($copiedSpec.argument_list)
            ExclusiveReason = $copiedSpec.exclusive_reason
            Kind = $old.kind
            Category = $old.category
            Vendor = $old.vendor
            Model = $old.model
            DependsOn = @($old.depends_on)
            Mutates = @($old.mutates)
            RunId = $old.run_id
            TimeoutSec = $old.expected_sec
        }
        foreach ($name in $fields.Keys) {
            if ($script:DtJobExplicitParams -notcontains $name) { Set-Variable -Name $name -Value $fields[$name] }
        }
        if ($script:DtJobExplicitParams -contains 'Command') { $ScriptPath = $null }
        if ($script:DtJobExplicitParams -contains 'ScriptPath') { $Command = $null }
        $workingDirectory = $old.working_directory
        foreach ($name in @('PromptPath', 'OutputPath')) {
            if ($script:DtJobExplicitParams -contains $name) { $Command = Set-DtJobCommandArgument -Command $Command -Name $name -Value (Get-Variable -Name $name -ValueOnly) }
        }
    }
    $ctx = $script:DtJobContext
    if ($null -ne $ctx -and $ctx.state -eq 'rotate' -and -not $ctx.deferred) {
        throw "ROTATE_REQUIRED: $($ctx.line). No new dispatch at the context limit: write _build-state.md and a coordinator handoff, run dt-job request-continuation -RunFolder `"$($paths.Root)`" -Reason context_rotation, release the lease, and end the turn."
    }
    if ([string]::IsNullOrWhiteSpace($Command) -eq [string]::IsNullOrWhiteSpace($ScriptPath)) {
        throw 'DT_JOB_USAGE: start takes exactly one of -Command or -ScriptPath.'
    }
    # No job is stopped on time: -TimeoutSec is the expected duration that check-ins compare against, and
    # only a stall the coordinator confirms ends a job.
    $expectedSec = $TimeoutSec
    $TimeoutSec = 0
    $spec = [ordered]@{ exclusive_reason = $ExclusiveReason; command = $null; script_path = $null; argument_list = @($ArgumentList); timeout_sec = $TimeoutSec; environment = (Get-DtJobEnvironment -Extra $PassEnv) }
    if ($null -ne $copiedSpec) {
        $spec.environment = $copiedSpec.environment
        if ($script:DtJobExplicitParams -contains 'PassEnv') {
            $extraEnv = Get-DtJobEnvironment -Extra $PassEnv
            foreach ($name in $PassEnv) { if ($extraEnv.Contains($name)) { $spec.environment[$name] = $extraEnv[$name] } }
        }
        $spec.relaunched_from = $old.job_id
    }
    if ($Command) { $spec.command = $Command; $identity = $Command }
    else {
        $spec.script_path = [System.IO.Path]::GetFullPath($ScriptPath)
        $identity = (@($spec.script_path) + @($ArgumentList)) -join "`n"
    }
    $commandSha = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
    $resolvedRunId = if ($RunId) { $RunId } else { Split-Path -Leaf $paths.Root }
    New-Item -ItemType Directory -Path $paths.Locks -Force | Out-Null

    $id = Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $pin = Get-DtJobRunPin -RunFolder $RunFolder
        # Registry values replace caller hints, including stale pins inherited from another run.
        $spec.environment.Remove('DT_BUILD_RUN_PIN_VENDOR')
        $spec.environment.Remove('DT_BUILD_RUN_PIN_MODEL')
        if ($null -ne $pin) {
            if ($Kind -eq 'worker' -and $Vendor -and $Vendor -ine $pin.vendor) {
                throw "DT_JOB_PIN_VENDOR: run is pinned to $($pin.vendor) ($($pin.model)); worker vendor $Vendor refused."
            }
            $spec.environment['DT_BUILD_RUN_PIN_VENDOR'] = [string]$pin.vendor
            $spec.environment['DT_BUILD_RUN_PIN_MODEL'] = [string]$pin.model
        }
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
            exclusive_reason  = $ExclusiveReason
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
            peak_memory_gb    = $null
            exit_code         = $null
            timeout_sec       = $TimeoutSec
            expected_sec      = $expectedSec
            working_directory = $workingDirectory
            output_path       = (Join-Path $jobDir 'stdout.log')
            stderr_path       = (Join-Path $jobDir 'stderr.log')
            summary_path      = (Join-Path $jobDir 'summary.json')
            queued            = [DateTime]::UtcNow.ToString('o')
            started           = $null
            ended             = $null
            last_progress     = $null
        }
        $obj = [pscustomobject]$record
        if ($FromJob) { $obj | Add-Member -NotePropertyName relaunched_from -NotePropertyValue $old.job_id }
        Save-DtJobRecord -RunFolder $RunFolder -Record $obj
        Add-DtJobEvent -RunFolder $RunFolder -JobId $newId -Type 'recorded' -Status 'queued' -RelaunchedFrom $FromJob
        Invoke-DtJobSchedule -RunFolder $RunFolder
        $newId
    }
    # Give a newly launched worker a bounded opportunity to disclose its choice.
    # Queued dependency jobs still return immediately; status reads the sidecar later.
    if ($Kind -eq 'worker') {
        $selectionDeadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $record = Get-DtJobRecord -RunFolder $RunFolder -JobId $id
            if ($record.status -ne 'running' -or $null -ne (Get-DtJobModelSelection -RunFolder $RunFolder -JobId $id)) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $selectionDeadline)
    }
    $record = Get-DtJobRecord -RunFolder $RunFolder -JobId $id
    Write-DtJobOutput -Object ([pscustomobject][ordered]@{ job_id = $id; exclusive_reason = $record.exclusive_reason; model_selection = (Get-DtJobModelSelection -RunFolder $RunFolder -JobId $id); status = $record.status; status_reason = $record.status_reason; job_file = (Join-Path $paths.Jobs "$id.json") }) -AsJson:$Json
}

function Invoke-DtJobRequeue {
    if (-not $JobId -or @($JobId).Count -ne 1) { throw 'DT_JOB_USAGE: requeue requires one -JobId.' }
    if ($null -ne $script:DtJobContext -and $script:DtJobContext.state -eq 'rotate' -and -not $script:DtJobContext.deferred) { throw 'ROTATE_REQUIRED: no new dispatch at the context limit.' }
    $replaceDependencies = $script:RequeueReplaceDependencies
    $paths = Get-DtJobPaths -RunFolder $RunFolder
    $id = Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $old = Get-DtJobRecord -RunFolder $RunFolder -JobId $JobId
        if ($null -eq $old) { throw "DT_JOB_UNKNOWN_JOB: $JobId" }
        if ($old.status -notin @('blocked', 'cancelled')) { throw "DT_JOB_REQUEUE_STATE: $($old.job_id) is $($old.status); only blocked or cancelled jobs can be requeued." }
        $deps = if ($replaceDependencies) { @($DependsOn) } else { @($old.depends_on) }
        $existing = @(Get-DtJobRecords -RunFolder $RunFolder)
        foreach ($dep in $deps) {
            if (-not ($existing | Where-Object { $_.job_id -eq $dep })) { throw "DT_JOB_UNKNOWN_DEPENDENCY: $dep" }
        }
        $max = 0
        foreach ($r in $existing) { $max = [Math]::Max($max, [int]($r.job_id -replace '^j-', '')) }
        $newId = 'j-{0:D4}' -f ($max + 1)
        $jobDir = Join-Path $paths.Jobs $newId
        $specText = Read-DtJobText -Path (Join-Path $paths.Jobs "$($old.job_id)/spec.json")
        $record = ($old | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
        $record.job_id = $newId
        $record.depends_on = @($deps)
        $record.status = 'queued'
        $record | Add-Member -NotePropertyName peak_memory_gb -NotePropertyValue $null -Force
        foreach ($field in @('pid','process_start_utc','runner_pid','runner_start_utc','status_reason','exit_code','started','ended','last_progress')) { $record.$field = $null }
        $record.queued = [DateTime]::UtcNow.ToString('o')
        $record.output_path = Join-Path $jobDir 'stdout.log'
        $record.stderr_path = Join-Path $jobDir 'stderr.log'
        $record.summary_path = Join-Path $jobDir 'summary.json'
        New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
        Write-DtJobAtomic -Path (Join-Path $jobDir 'spec.json') -Content $specText
        Save-DtJobRecord -RunFolder $RunFolder -Record $record
        Add-DtJobEvent -RunFolder $RunFolder -JobId $newId -Type 'requeued' -Status 'queued' -Reason "requeued from $($old.job_id)"
        Invoke-DtJobSchedule -RunFolder $RunFolder
        $newId
    }
    $record = Get-DtJobRecord -RunFolder $RunFolder -JobId $id
    Write-DtJobOutput -Object ([pscustomobject]@{ job_id = $id; requeued_from = $JobId; status = $record.status; job_file = (Join-Path $paths.Jobs "$id.json") }) -AsJson:$Json
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
    # A job-scoped snapshot's seq stops before the first unconsumed event of a job (or the run) it does not
    # show, so consuming it never swallows an event the coordinator was not shown.
    $consumed = Get-DtJobConsumedSeq -RunFolder $RunFolder
    $snap = Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $records = if ($null -ne $Ids) { @($Ids | ForEach-Object { Get-DtJobRecord -RunFolder $RunFolder -JobId $_ }) } else { @(Get-DtJobRecords -RunFolder $RunFolder) }
        $seq = Get-DtJobLastEventSeq -RunFolder $RunFolder
        if ($null -ne $Ids) {
            $floor = if ($null -ne $consumed) { [int64]$consumed } else { [int64]0 }
            foreach ($evt in @(Get-DtJobEvents -RunFolder $RunFolder | Sort-Object { [int64]$_.seq })) {
                if ([int64]$evt.seq -le $floor) { continue }
                if ($Ids -notcontains [string]$evt.job_id) { $seq = [Math]::Max($floor, [int64]$evt.seq - 1); break }
            }
        }
        [pscustomobject]@{ records = $records; last_event_seq = $seq }
    }
    $snap | Add-Member -NotePropertyName last_consumed_event_seq -NotePropertyValue $consumed
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
        $envelope = New-DtJobRunEnvelope -RunFolder $RunFolder -Cursor $snap -Records $snap.records
        # FS-94: the run's state comes from run_status, never from the last event's type (a later
        # continuation_requested event can still carry awaiting_danny). Watchers read these fields.
        $runStatus = $null
        $awaiting = $null
        $entry = Get-DtJobRegistryEntry -RunFolder $RunFolder
        $statePath = if ($BuildStatePath) { $BuildStatePath } elseif ($null -ne $entry) { [string]$entry.build_state_path } else { $null }
        if ($statePath -and (Test-Path -LiteralPath $statePath)) {
            $runStatus = (Get-DtJobRunState -BuildStatePath $statePath).run_status
            if ($runStatus -eq 'awaiting_danny') {
                $pending = (Get-DtJobApprovals -RunFolder $RunFolder).awaiting
                if ($null -ne $pending) {
                    $awaiting = [ordered]@{ operation = [string]$pending.operation; seq = $null; since_utc = $null }
                    foreach ($field in @('seq', 'since_utc')) { if ($pending.PSObject.Properties[$field]) { $awaiting[$field] = $pending.$field } }
                    # Use the stop's persisted routing decision, including -AlwaysNotify, rather than
                    # reclassifying it from today's delegate or the operation's wording.
                    $delegatedTo = if ($pending.PSObject.Properties['delegated_to']) { [string]$pending.delegated_to } else { $null }
                    $awaiting.awaiting_owner = if ($delegatedTo) { 'delegate' } else { 'danny' }
                    $awaiting.delegated_to = $delegatedTo
                    $awaiting.message = if ($pending.PSObject.Properties['message']) { [string]$pending.message } else { $null }
                    $runIdNow = (Resolve-DtJobRunContext -RunFolder $RunFolder -BuildStatePath $statePath -RunId $RunId).run_id
                    $alertKey = "dt-build:${runIdNow}:awaiting:$($awaiting.operation):$($awaiting.seq)"
                    $awaiting.alerted_danny = @(Get-DtJobNotifications -RunFolder $RunFolder | Where-Object {
                        [string]$_.key -ceq $alertKey -and (Test-DtJobNotificationDelivered $_)
                    }).Count -gt 0
                }
            }
        }
        $envelope | Add-Member -NotePropertyName run_status -NotePropertyValue $runStatus -Force
        $envelope | Add-Member -NotePropertyName awaiting -NotePropertyValue $awaiting -Force
        Write-DtJobOutput -Object $envelope -AsJson:$Json
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
            $survivors = @(Stop-DtJobProcesses -Record $record)
            # FS-96: cancelled means the whole process tree is gone; a survivor keeps the job running and fails loudly.
            if ($survivors.Count -gt 0) { throw "DT_JOB_CANCEL_INCOMPLETE: $JobId still has live processes $($survivors -join ', ') after cancel; the job stays running." }
            Remove-DtJobKeyLocks -RunFolder $RunFolder -Record $record
            Set-DtJobState -RunFolder $RunFolder -Record $record -Status 'cancelled' -EventType 'cancelled' -Reason 'cancelled while running; process tree verified gone'
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
            # A live job is never ended on time; a silent one shows as stalled at check-ins.
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

function Get-DtJobWorktrees {
    # A partial or malformed line is skipped, like the event ledger.
    param([Parameter(Mandatory)][string]$RunFolder)
    $path = (Get-DtJobPaths -RunFolder $RunFolder).Worktrees
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ((Read-DtJobText -Path $path) -split '\r?\n')) {
        if (-not $line.Trim()) { continue }
        try { $row = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -ne $row -and $row.PSObject.Properties['ts_utc'] -and $row.PSObject.Properties['coordinator_id'] -and $row.PSObject.Properties['path'] -and $row.PSObject.Properties['branch'] -and $row.PSObject.Properties['command']) { $rows.Add($row) }
    }
    return @($rows)
}

function Get-DtJobLiveWorktrees {
    # Admin-directory timestamps survive a coordinator dying before its hook records the tree.
    param([Parameter(Mandatory)][string]$RunFolder, [DateTime]$SinceUtc)
    try {
        $root = @(& git -C $RunFolder rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -ne 0 -or $root.Count -ne 1) { return @() }
        $lines = @(& git -C $root[0] -c core.quotePath=false worktree list --porcelain 2>$null)
        if ($LASTEXITCODE -ne 0) { return @() }
    }
    catch { return @() }
    $rows = [System.Collections.Generic.List[object]]::new()
    $current = $null; $first = $true
    foreach ($line in @($lines) + @('')) {
        if ($line.StartsWith('worktree ')) { $current = [ordered]@{ path = [IO.Path]::GetFullPath($line.Substring(9)); branch = $null; head = $null; created_utc = $null } }
        elseif ($null -ne $current -and $line.StartsWith('HEAD ')) { $current.head = $line.Substring(5) }
        elseif ($null -ne $current -and $line.StartsWith('branch refs/heads/')) { $current.branch = $line.Substring(18) }
        elseif (-not $line -and $null -ne $current) {
            if ($first) { $first = $false; $current = $null; continue }
            try {
                $gitFile = Join-Path $current.path '.git'
                $match = [regex]::Match((Read-DtJobText -Path $gitFile).Trim(), '^gitdir:\s*(.+)$')
                if ($match.Success) {
                    $adminPath = $match.Groups[1].Value
                    if (-not [IO.Path]::IsPathRooted($adminPath)) { $adminPath = Join-Path $current.path $adminPath }
                    $admin = Get-Item -LiteralPath $adminPath -ErrorAction Stop
                    $created = $admin.CreationTimeUtc
                    if ($null -eq $created -or $created -eq [DateTime]::MinValue) { $created = $admin.LastWriteTimeUtc }
                    $current.created_utc = $created
                }
            }
            catch { }
            if (-not $PSBoundParameters.ContainsKey('SinceUtc') -or ($null -ne $current.created_utc -and $current.created_utc -ge $SinceUtc.ToUniversalTime())) { $rows.Add([pscustomobject]$current) }
            $current = $null
            if ($rows.Count -ge 50) { break }
        }
    }
    return @($rows)
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
    return (Get-DtJobRegistryRuns | Where-Object { Test-DtPathEqual ([string]$_.run_folder) $root } | Select-Object -First 1)
}

function Get-DtJobRunPin {
    param([Parameter(Mandatory)][string]$RunFolder)
    $entry = Get-DtJobRegistryEntry -RunFolder $RunFolder
    if ($null -ne $entry -and $entry.PSObject.Properties['pin']) { return $entry.pin }
    return $null
}

function Get-DtJobRunPinLabel {
    param([Parameter(Mandatory)][string]$RunFolder)
    $pin = Get-DtJobRunPin -RunFolder $RunFolder
    if ($null -ne $pin) { return "$($pin.vendor) $($pin.model)" }
    return $null
}

function Invoke-DtJobPin {
    Assert-DtJobOperator -VerbName 'pin' -RunFolder $RunFolder -AllowLiveCoordinator
    if (-not $Clear -and ($Vendor -notin @('codex', 'claude') -or [string]::IsNullOrWhiteSpace($Model))) {
        throw 'DT_JOB_USAGE: pin requires -Vendor codex|claude and -Model, or -Clear.'
    }
    $entry = Invoke-DtJobRegistryLocked -Body {
        $runs = @(Get-DtJobRegistryRuns)
        $root = (Get-DtJobPaths -RunFolder $RunFolder).Root
        $registered = $runs | Where-Object { Test-DtPathEqual ([string]$_.run_folder) $root } | Select-Object -First 1
        if ($null -eq $registered) { throw 'DT_JOB_USAGE: the run is not registered.' }
        if ($Clear) { $registered.PSObject.Properties.Remove('pin') }
        else {
            $registered | Add-Member -NotePropertyName pin -NotePropertyValue ([pscustomobject][ordered]@{ vendor = $Vendor.ToLowerInvariant(); model = $Model; set_utc = [DateTime]::UtcNow.ToString('o') }) -Force
        }
        Save-DtJobRegistryRuns -Runs $runs
        $registered
    }
    Write-DtJobOutput -Object $entry -AsJson:$Json
}

function Resolve-DtJobRunContext {
    param([Parameter(Mandatory)][string]$RunFolder, [string]$BuildStatePath, [string]$RunId)
    $entry = Get-DtJobRegistryEntry -RunFolder $RunFolder
    $statePath = if ($BuildStatePath) { $BuildStatePath } elseif ($null -ne $entry) { [string]$entry.build_state_path } else { $null }
    if (-not $statePath) { throw 'DT_JOB_USAGE: the run is not registered; pass -BuildStatePath.' }
    $statePath = [System.IO.Path]::GetFullPath($statePath)
    if (-not (Test-Path -LiteralPath $statePath)) { throw "DT_JOB_BUILD_STATE_MISSING: $statePath" }
    $resolvedRunId = if ($RunId) { $RunId } elseif ($null -ne $entry) { [string]$entry.run_id } else { Split-Path -Leaf (Get-DtJobPaths -RunFolder $RunFolder).Root }
    return [pscustomobject]@{ run_id = $resolvedRunId; run_folder = (Get-DtJobPaths -RunFolder $RunFolder).Root; build_state_path = $statePath; entry = $entry }
}

function Get-DtJobApprovals {
    param([Parameter(Mandatory)][string]$RunFolder)
    $path = (Get-DtJobPaths -RunFolder $RunFolder).Approvals
    if (Test-Path -LiteralPath $path) {
        $parsed = Read-DtJobText -Path $path | ConvertFrom-DtJobJsonText
        $delegateRecord = if ($parsed.PSObject.Properties['delegate']) { $parsed.delegate } else { $null }
        return [pscustomobject]@{ awaiting = $parsed.awaiting; approvals = @($parsed.approvals | Where-Object { $null -ne $_ }); delegate = $delegateRecord }
    }
    return [pscustomobject]@{ awaiting = $null; approvals = @(); delegate = $null }
}

function Save-DtJobApprovals {
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)]$Approvals)
    $delegateRecord = if ($Approvals.PSObject.Properties['delegate']) { $Approvals.delegate } else { $null }
    $content = [ordered]@{ awaiting = $Approvals.awaiting; approvals = @($Approvals.approvals); delegate = $delegateRecord } | ConvertTo-Json -Depth 5
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

function Get-DtJobSettingSec {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Default)
    $parsed = 0
    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ($value -and [int]::TryParse($value, [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    return $Default
}

function Get-DtJobActivity {
    # A running job's progress from its runner's heartbeat: minutes running, seconds since its last sign
    # of life (CPU, output or file changes in its working directory), and whether that makes it stalled.
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)]$Record)
    $now = [DateTime]::UtcNow
    $started = if ($Record.started) { ConvertTo-DtJobUtc $Record.started } else { $now }
    $beat = $null
    $beatPath = Join-Path (Join-Path (Get-DtJobPaths -RunFolder $RunFolder).Jobs $Record.job_id) 'heartbeat.json'
    if (Test-Path -LiteralPath $beatPath) { try { $beat = Read-DtJobText -Path $beatPath | ConvertFrom-Json -ErrorAction Stop } catch { $beat = $null } }
    $lastActive = if ($null -ne $beat -and $beat.last_activity_utc) { ConvertTo-DtJobUtc $beat.last_activity_utc } else { $started }
    $idleSec = [int][Math]::Max(0, ($now - $lastActive).TotalSeconds)
    $runningMin = [int][Math]::Floor(($now - $started).TotalMinutes)
    $expected = if ($Record.PSObject.Properties['expected_sec'] -and $Record.expected_sec) { [int]$Record.expected_sec } else { 0 }
    $stallSec = Get-DtJobSettingSec -Name 'DT_JOB_STALL_SEC' -Default $script:DtJobStallSec
    $stalled = $idleSec -ge $stallSec
    $cpu = if ($null -ne $beat) { [int]$beat.cpu_seconds } else { $null }
    $files = if ($null -ne $beat) { [int]$beat.file_changes } else { $null }
    $line = "$($Record.job_id) running $runningMin min, last activity $(if ($idleSec -lt 120) { "$idleSec s" } else { "$([int][Math]::Floor($idleSec / 60)) min" }) ago"
    if ($null -ne $beat) { $line += " (cpu $cpu s, $files file changes)" } else { $line += ' (no heartbeat yet)' }
    if ($expected -gt 0 -and ($now - $started).TotalSeconds -gt $expected) { $line += "; past its expected $([int][Math]::Ceiling($expected / 60)) min" }
    if ($stalled) { $line += "; STALLED: no activity for $([int][Math]::Floor($idleSec / 60)) min. Check its output, then cancel and retry or keep waiting" }
    $outcome = Get-DtJobWorkerOutcome -RunFolder $RunFolder -Record $Record
    if ($null -ne $outcome.report_verdict) { $line += " verdict=$($outcome.report_verdict)" }
    return [pscustomobject][ordered]@{ job_id = $Record.job_id; running_min = $runningMin; idle_sec = $idleSec; stalled = $stalled; cpu_seconds = $cpu; file_changes = $files; line = $line }
}

function Get-DtJobWaitRenewSec {
    # A blocked wait renews at least every min(60 s, ttl/2), never more often than once a second.
    param($Lease)
    return [int][Math]::Max(1, [Math]::Min($script:DtJobLeaseRenewMaxSec, [Math]::Floor((Get-DtJobLeaseTtl $Lease) / 2)))
}

function Invoke-DtJobWait {
    $ids = @($script:DtJobIds)
    if ($ids.Count -eq 0) { throw 'DT_JOB_USAGE: wait requires -JobId.' }
    # One job: -Any and -All mean the same thing, so neither is required.
    if ($ids.Count -eq 1 -and -not $Any -and -not $All) { $script:All = $true; $All = $true }
    if ($Any -eq $All) { throw 'DT_JOB_USAGE: wait on several jobs takes exactly one of -Any or -All (single job: wait -JobId <id> -TimeoutSec <n>).' }
    if ($TimeoutSec -le 0) { throw 'DT_JOB_USAGE: wait requires -TimeoutSec greater than 0 (for example: wait -JobId <id> -TimeoutSec 3600).' }
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
        $outcome = Get-DtJobWorkerOutcome -RunFolder $RunFolder -Record $r
        $jobs.Add([ordered]@{ job_id = $r.job_id; status = $r.status; exit_code = $r.exit_code; evidence = $evidence; report_verdict = $outcome.report_verdict; failure_category = $(if ($null -ne $outcome.failure_category) { Limit-DtJobLine $outcome.failure_category ([ref]$cut) } else { $null }) })
        $suffix = if ($null -ne $outcome.report_verdict) { " verdict=$($outcome.report_verdict)" } else { '' }
        $lines.Add((Limit-DtJobLine "$($r.job_id) $($r.status) exit=$($r.exit_code) evidence=$($r.output_path)$suffix" ([ref]$cut)))
    }
    $running = @($records | Where-Object { -not (Test-DtJobTerminal $_.status) } | ForEach-Object { $_.job_id })
    # A check-in: every job still running reports its progress, and a stalled one says so.
    $progress = @($records | Where-Object { $_.status -eq 'running' } | ForEach-Object { Get-DtJobActivity -RunFolder $RunFolder -Record $_ })
    $notes = @(Get-DtJobOperatorNotes -RunFolder $RunFolder | ForEach-Object { [ordered]@{ id = $_.id; text = $_.text } })
    $envelope = [ordered]@{ result = $result; pin = (Get-DtJobRunPinLabel -RunFolder $RunFolder); evidence_hint = 'read-evidence.ps1 -RunFolder <run folder> -JobId <job> -File summary|stdout|stderr|spec|report|provenance; run files: approvals.json, operator-notes.json, evidence-notes.json, launches.jsonl, worktrees.jsonl, jobs/events.jsonl'; operator_notes = $notes; evidence_notes = @(Get-DtJobEvidenceNotes -RunFolder $RunFolder | ForEach-Object { [ordered]@{ id = $_.id; text = $_.text } }); evidence_notes_label = $script:DtJobEvidenceNotesLabel; jobs = $jobs; still_running = @($running); progress = @($progress | ForEach-Object { [ordered]@{ job_id = $_.job_id; running_min = $_.running_min; idle_sec = $_.idle_sec; stalled = $_.stalled; line = (Limit-DtJobLine $_.line ([ref]$cut)) } }); omitted = 0; truncated = $false; last_event_seq = $snap.last_event_seq; last_consumed_event_seq = $snap.last_consumed_event_seq }
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
    foreach ($note in $notes) { $lines.Add("operator note $($note.id): $($note.text)") }
    if (@($envelope.evidence_notes).Count) { $lines.Add($script:DtJobEvidenceNotesLabel) }
    foreach ($note in $envelope.evidence_notes) { $lines.Add("evidence note $($note.id): $($note.text)") }
    foreach ($entry in $envelope.progress) { $lines.Add([string]$entry.line) }
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
    return Test-DtPathEqual $held (Get-DtJobPaths -RunFolder $RunFolder).Root
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
    if (($PinVendor -or $PinModel) -and (-not $PinVendor -or [string]::IsNullOrWhiteSpace($PinModel))) { throw 'DT_JOB_USAGE: register-run pin requires -PinVendor and -PinModel.' }
    if ($PinVendor) { Assert-DtJobOperator -VerbName 'register-run pin' -RunFolder $RunFolder -AllowLiveCoordinator }
    $hasDelegate = $script:DtJobExplicitParams -contains 'Delegate'
    if ($hasDelegate) {
        Assert-DtJobOperator -VerbName 'delegate' -RunFolder $RunFolder
        if ([string]::IsNullOrWhiteSpace($Delegate)) { throw 'DT_JOB_USAGE: delegate requires -Delegate <name> or -Clear.' }
    }
    $root = (Get-DtJobPaths -RunFolder $RunFolder).Root
    $entry = [ordered]@{
        run_id           = $RunId
        run_folder       = $root
        build_state_path = [System.IO.Path]::GetFullPath($BuildStatePath)
        pinned_host      = $PinnedHost
        managed          = [bool]$Managed
        registered_utc   = [DateTime]::UtcNow.ToString('o')
    }
    if ($PinVendor) { $entry.pin = [ordered]@{ vendor = $PinVendor.ToLowerInvariant(); model = $PinModel; set_utc = [DateTime]::UtcNow.ToString('o') } }
    Invoke-DtJobLocked -RunFolder $RunFolder -Action { Invoke-DtJobRegistryLocked -Body {
        $previous = Get-DtJobRunPin -RunFolder $RunFolder
        if (-not $PinVendor -and $null -ne $previous) { $entry.pin = $previous }
        $runs = @(Get-DtJobRegistryRuns | Where-Object { -not (Test-DtPathEqual ([string]$_.run_folder) $root) -and [string]$_.run_id -cne $RunId })
        if ($hasDelegate) {
            $approvals = Get-DtJobApprovals -RunFolder $RunFolder
            $approvals.delegate = [pscustomobject][ordered]@{ name = $Delegate.Trim(); set_utc = [DateTime]::UtcNow.ToString('o') }
            Save-DtJobApprovals -RunFolder $RunFolder -Approvals $approvals
        }
        Save-DtJobRegistryRuns -Runs (@($runs) + @([pscustomobject]$entry))
    } }
    Write-DtJobOutput -Object ([pscustomobject]$entry) -AsJson:$Json
}

function Remove-DtJobRegistryEntry {
    param([Parameter(Mandatory)][string]$RunFolder)
    $root = (Get-DtJobPaths -RunFolder $RunFolder).Root
    return (Invoke-DtJobRegistryLocked -Body {
        $runs = @(Get-DtJobRegistryRuns)
        $kept = @($runs | Where-Object { -not (Test-DtPathEqual ([string]$_.run_folder) $root) })
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
        $cursor = (Get-DtJobRunState -BuildStatePath $ctx.build_state_path).last_consumed_event_seq
        # A coordinator never consumes its own continuation request: that event is the watcher's trigger
        # for its successor, so the cursor stops just before it.
        $target = [int64]$Seq
        if ($CoordinatorId) {
            foreach ($evt in (Get-DtJobEvents -RunFolder $RunFolder)) {
                $s = [int64]$evt.seq
                if ($s -gt $cursor -and $s -le $target -and $evt.type -eq 'continuation_requested' -and
                    $evt.PSObject.Properties['requested_by'] -and $evt.requested_by -ceq $CoordinatorId) { $target = $s - 1 }
            }
        }
        # The cursor never moves backwards; an older seq is a no-op.
        if ($target -gt $cursor) {
            Set-DtJobRunState -BuildStatePath $ctx.build_state_path -Cursor $target
        }
    }
    Write-DtJobOutput -Object (Get-DtJobRunSummary -Context $ctx) -AsJson:$Json
}

function Invoke-DtJobRequestContinuation {
    $ctx = Resolve-DtJobRunContext -RunFolder $RunFolder -BuildStatePath $BuildStatePath -RunId $RunId
    Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $state = Get-DtJobRunState -BuildStatePath $ctx.build_state_path
        Add-DtJobEvent -RunFolder $RunFolder -JobId 'run' -Type 'continuation_requested' -Status $state.run_status -Reason $(if ($Reason) { $Reason } else { 'continuation requested' }) -RequestedBy $CoordinatorId -ConsumedEventSeq $state.last_consumed_event_seq
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
            $awaiting = [ordered]@{ operation = $Operation; message = $Message; since_utc = [DateTime]::UtcNow.ToString('o'); seq = $seq }
            # A delegated run routes routine stops to the delegate; Danny is told only if it has not acted
            # in time, and always for production, install, Azure or irreversible steps.
            if ($null -ne $approvals.delegate -and -not (Test-DtJobMustNotifyDanny -Operation $Operation -Message $Message -AlwaysNotify:$AlwaysNotify)) {
                $awaiting.delegated_to = [string]$approvals.delegate.name
                $awaiting.escalate_after_utc = [DateTime]::UtcNow.AddMinutes((Get-DtJobSettingSec -Name 'DT_BUILD_DELEGATE_ESCALATE_MIN' -Default $script:DtJobDelegateEscalateMin)).ToString('o')
            }
            $approvals.awaiting = $awaiting
            Save-DtJobApprovals -RunFolder $RunFolder -Approvals $approvals
            $seq
        }
    }
    $pendingNow = (Get-DtJobApprovals -RunFolder $RunFolder).awaiting
    $delegatedTo = if ($null -ne $pendingNow -and $pendingNow.PSObject.Properties['delegated_to']) { [string]$pendingNow.delegated_to } else { $null }
    if ($delegatedTo) { $alert = 'delegated' }
    else {
        $text = "dt-build run $($ctx.run_id) is paused for your approval before: $Operation. $Message To approve, run: /dt-build approve $($ctx.run_id) $Operation"
        # Every boundary gets its own key (the await event's seq), so a later boundary for the same operation DMs again.
        $alert = Send-DtJobRunAlert -RunFolder $RunFolder -Key "dt-build:$($ctx.run_id):awaiting:${Operation}:$awaitSeq" -Message $text -RetryUntilDelivered
    }
    Write-DtJobOutput -Object (Get-DtJobRunSummary -Context $ctx -Extra @{ operation = $Operation; alert = $alert; await_seq = $awaitSeq }) -AsJson:$Json
}

function Assert-DtJobOperator {
    # approve and resume are Danny's commands: a coordinator or a job can never release its own boundary.
    param([Parameter(Mandatory)][string]$VerbName, [Parameter(Mandatory)][string]$RunFolder, [switch]$AllowLiveCoordinator)
    if ($env:DT_BUILD_COORDINATOR_ID) { throw "DT_JOB_OPERATOR_ONLY: $VerbName is Danny's command; coordinator $env:DT_BUILD_COORDINATOR_ID cannot run it" }
    if ($env:DT_JOB_ID) { throw "DT_JOB_OPERATOR_ONLY: $VerbName is Danny's command; it cannot run inside dt-job job $env:DT_JOB_ID" }
    $callerLease = Get-DtJobLease -RunFolder $RunFolder
    if ($VerbName -in @('approve','resume') -and $null -ne $callerLease -and $callerLease.launched_by -eq 'watcher' -and $callerLease.pid -and
        (Test-DtJobProcessIdentity $callerLease.pid $callerLease.pid_start_utc)) {
        # Clearing DT_* must not let a coordinator (or its shell child) approve itself.
        $ancestor = $PID
        $seen = @{}
        while ($ancestor -gt 0 -and -not $seen.ContainsKey($ancestor)) {
            if ($ancestor -eq [int]$callerLease.pid) { throw "DT_JOB_OPERATOR_ONLY: $VerbName cannot run from the watcher coordinator process tree" }
            $seen[$ancestor] = $true
            if ($IsWindows) {
                $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$ancestor" -ErrorAction Stop
                $ancestor = if ($parent) { [int]$parent.ParentProcessId } else { 0 }
            } else {
                $parent = & ps -o ppid= -p $ancestor
                $ancestor = if ($parent) { [int]([string]$parent).Trim() } else { 0 }
            }
        }
    }
    # hold only adds a reason to Danny's DM and releases nothing, so it may run while the coordinator closes out.
    if ($AllowLiveCoordinator) { return }
    # The env checks can be bypassed by clearing a variable; a live watcher-launched coordinator cannot hide its process.
    $lease = Get-DtJobLease -RunFolder $RunFolder
    if ($null -ne $lease -and $lease.launched_by -eq 'watcher') {
        $leaseStart = if ($lease.PSObject.Properties['pid_start_utc']) { $lease.pid_start_utc } else { $null }
        if (Test-DtJobProcessIdentity $lease.pid $leaseStart) { throw "DT_JOB_OPERATOR_ONLY: $VerbName is Danny's command; watcher-launched coordinator $($lease.coordinator_id) is still running as pid $($lease.pid)" }
    }
}

function Complete-DtJobApproval {
    param($Context, $Approvals, $Receipt)
    $Receipt | Add-Member -NotePropertyName approved_utc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $Approvals.approvals = @($Approvals.approvals) + @($Receipt)
    $Approvals.awaiting = $null
    Save-DtJobApprovals -RunFolder $Context.run_folder -Approvals $Approvals
    Set-DtJobRunState -BuildStatePath $Context.build_state_path -RunStatus 'runnable'
    Add-DtJobEvent -RunFolder $Context.run_folder -JobId 'run' -Type 'continuation_requested' -Status 'runnable' -Reason "approved $($Receipt.operation)"
}

function Receive-DtJobQueuedApproval {
    param([string]$RunFolder)
    $queuePath = Join-Path $RunFolder 'approval-queued.json'
    if (-not (Test-Path -LiteralPath $queuePath)) { return }
    Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $q = Read-DtJobText -Path $queuePath | ConvertFrom-DtJobJsonText
        if ($q.status -ne 'queued' -or (Test-DtJobProcessIdentity $q.coordinator_pid $q.coordinator_start_utc)) { return }
        $ctx = Resolve-DtJobRunContext -RunFolder $RunFolder -BuildStatePath $q.build_state_path -RunId $q.run_id
        $approvals = Get-DtJobApprovals -RunFolder $RunFolder
        $pending = $approvals.awaiting
        if ($null -eq $pending -or $pending.operation -cne $q.operation -or $pending.seq -ne $q.await_seq -or
            (Get-DtJobRunState -BuildStatePath $ctx.build_state_path).run_status -ne 'awaiting_danny') {
            $recorded = @($approvals.approvals | Where-Object { $_.PSObject.Properties['requested_utc'] -and (Test-DtJobSameInstant $_.requested_utc $q.requested_utc) -and $_.operation -ceq $q.operation })
            if ($recorded.Count -eq 1 -and $null -eq $pending) {
                Set-DtJobRunState -BuildStatePath $ctx.build_state_path -RunStatus 'runnable'
                $existingEvent = @(Get-DtJobEvents -RunFolder $RunFolder | Where-Object { $_.type -eq 'continuation_requested' -and $_.reason -eq "approved $($q.operation)" -and [int64]$_.seq -gt [int64]$q.await_seq })
                if ($existingEvent.Count -eq 0) { Add-DtJobEvent -RunFolder $RunFolder -JobId 'run' -Type 'continuation_requested' -Status 'runnable' -Reason "approved $($q.operation)" }
                $q.status = 'applied'
            } else { $q.status = 'superseded' }
        } else {
            $q.status = 'applied'
            Complete-DtJobApproval -Context $ctx -Approvals $approvals -Receipt $q
        }
        Write-DtJobAtomic -Path $queuePath -Content ($q | ConvertTo-Json -Depth 6)
    }
}

function Invoke-DtJobApprove {
    if (-not $Operation) { throw 'DT_JOB_USAGE: approve requires -Operation.' }
    Assert-DtJobOperator -VerbName 'approve' -RunFolder $RunFolder -AllowLiveCoordinator
    $ctx = Resolve-DtJobRunContext -RunFolder $RunFolder -BuildStatePath $BuildStatePath -RunId $RunId
    $result = Invoke-DtJobCoordinatorLocked -RunFolder $RunFolder -Action {
      Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $approvals = Get-DtJobApprovals -RunFolder $RunFolder
        $queuePath = Join-Path $RunFolder 'approval-queued.json'
        if ($null -eq $approvals.awaiting) {
            $history = @($approvals.approvals)
            if ($history.Count -gt 0 -and $history[-1].operation -ceq $Operation -and
                (Get-DtJobRunState -BuildStatePath $ctx.build_state_path).run_status -eq 'runnable') {
                return @{ approved = $Operation }
            }
            throw "DT_JOB_NOT_AWAITING: run $($ctx.run_id) is not waiting on an approval"
        }
        if ([string]$approvals.awaiting.operation -cne $Operation) {
            throw "DT_JOB_APPROVE_MISMATCH: run $($ctx.run_id) waits on '$($approvals.awaiting.operation)', not '$Operation'; nothing recorded"
        }
        $lease = Get-DtJobLease -RunFolder $RunFolder
        $live = $null -ne $lease -and $lease.launched_by -eq 'watcher' -and (Test-DtJobProcessIdentity $lease.pid $lease.pid_start_utc)
        if ($live -and ((Get-DtJobRunState -BuildStatePath $ctx.build_state_path).run_status -ne 'awaiting_danny' -or -not $lease.pid_start_utc)) {
            throw 'DT_JOB_OPERATOR_ONLY: coordinator is not closing out an approval boundary'
        }
        $delegatedTo = if ($approvals.awaiting.PSObject.Properties['delegated_to']) { [string]$approvals.awaiting.delegated_to } else { $null }
        $receipt = [pscustomobject][ordered]@{ operation = $Operation; await_seq = $approvals.awaiting.seq; run_id = $ctx.run_id; build_state_path = $ctx.build_state_path; requested_by = [Environment]::UserName; requested_pid = $PID; requested_utc = [DateTime]::UtcNow.ToString('o'); delegated_to = $delegatedTo }
        # FS-124: keep the approver's reason (the chosen option of a multi-option stop) on the record.
        if (-not [string]::IsNullOrWhiteSpace($Reason)) { $receipt | Add-Member -NotePropertyName reason -NotePropertyValue $Reason.Trim() }
        if ($live) {
            if (Test-Path -LiteralPath $queuePath) {
                $q = Read-DtJobText -Path $queuePath | ConvertFrom-DtJobJsonText
                if ($q.status -eq 'queued' -and $q.operation -ceq $receipt.operation -and $q.await_seq -eq $receipt.await_seq -and $q.coordinator_id -ceq $lease.coordinator_id -and (Test-DtJobSameInstant $q.coordinator_start_utc $lease.pid_start_utc)) {
                    return @{ approval_queued = $Operation; message = "approval queued; applies when coordinator $($q.coordinator_pid) exits" }
                }
            }
            $receipt | Add-Member -NotePropertyName status -NotePropertyValue 'queued'
            $receipt | Add-Member -NotePropertyName coordinator_id -NotePropertyValue $lease.coordinator_id
            $receipt | Add-Member -NotePropertyName coordinator_pid -NotePropertyValue $lease.pid
            $receipt | Add-Member -NotePropertyName coordinator_start_utc -NotePropertyValue $lease.pid_start_utc
            Write-DtJobAtomic -Path $queuePath -Content ($receipt | ConvertTo-Json -Depth 6)
            return @{ approval_queued = $Operation; message = "approval queued; applies when coordinator $($lease.pid) exits" }
        }
        Complete-DtJobApproval -Context $ctx -Approvals $approvals -Receipt $receipt
        return @{ approved = $Operation }
      }
    }
    Write-DtJobOutput -Object (Get-DtJobRunSummary -Context $ctx -Extra $result) -AsJson:$Json
}

function Test-DtJobMustNotifyDanny {
    # Stops Danny always hears about himself, delegate or not.
    param([string]$Operation, [string]$Message, [switch]$AlwaysNotify)
    if ($AlwaysNotify) { return $true }
    return ("$Operation $Message" -match '(?i)\b(prod|production|install|installs|installation|azure|irreversible)\b')
}

function Invoke-DtJobDelegate {
    # Danny names the session that approves this run's routine stops for him, or clears it with -Clear.
    Assert-DtJobOperator -VerbName 'delegate' -RunFolder $RunFolder
    if (-not $Clear -and [string]::IsNullOrWhiteSpace($Delegate)) { throw 'DT_JOB_USAGE: delegate requires -Delegate <name> or -Clear.' }
    $ctx = Resolve-DtJobRunContext -RunFolder $RunFolder -BuildStatePath $BuildStatePath -RunId $RunId
    Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $approvals = Get-DtJobApprovals -RunFolder $RunFolder
        $approvals.delegate = if ($Clear) { $null } else { [pscustomobject][ordered]@{ name = $Delegate.Trim(); set_utc = [DateTime]::UtcNow.ToString('o') } }
        Save-DtJobApprovals -RunFolder $RunFolder -Approvals $approvals
    }
    Write-DtJobOutput -Object (Get-DtJobRunSummary -Context $ctx -Extra @{ delegate = $(if ($Clear) { $null } else { $Delegate.Trim() }) }) -AsJson:$Json
}

function Invoke-DtJobHold {
    # The delegate says why it is holding a stop on purpose, so the escalation DM tells Danny the stop is
    # handled rather than forgotten. -Clear removes the reason. The DM still goes out on time.
    if (-not $Operation) { throw 'DT_JOB_USAGE: hold requires -Operation.' }
    if (-not $Clear -and [string]::IsNullOrWhiteSpace($Reason)) { throw 'DT_JOB_USAGE: hold requires -Reason "<why>" or -Clear.' }
    Assert-DtJobOperator -VerbName 'hold' -RunFolder $RunFolder -AllowLiveCoordinator
    $ctx = Resolve-DtJobRunContext -RunFolder $RunFolder -BuildStatePath $BuildStatePath -RunId $RunId
    Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $approvals = Get-DtJobApprovals -RunFolder $RunFolder
        if ($null -eq $approvals.awaiting) { throw "DT_JOB_NOT_AWAITING: run $($ctx.run_id) is not waiting on an approval" }
        if ([string]$approvals.awaiting.operation -cne $Operation) {
            throw "DT_JOB_APPROVE_MISMATCH: run $($ctx.run_id) waits on '$($approvals.awaiting.operation)', not '$Operation'; nothing recorded"
        }
        $held = if ($Clear) { $null } else { [pscustomobject][ordered]@{ reason = $Reason.Trim(); held_utc = [DateTime]::UtcNow.ToString('o') } }
        $approvals.awaiting | Add-Member -NotePropertyName held -NotePropertyValue $held -Force
        Save-DtJobApprovals -RunFolder $RunFolder -Approvals $approvals
    }
    Write-DtJobOutput -Object (Get-DtJobRunSummary -Context $ctx -Extra @{ held = $(if ($Clear) { $null } else { $Reason.Trim() }) }) -AsJson:$Json
}

function Send-DtJobDelegateEscalation {
    # A delegated stop the delegate has not approved in time DMs Danny, once.
    param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$RunId)
    $pending = (Get-DtJobApprovals -RunFolder $RunFolder).awaiting
    if ($null -eq $pending -or -not $pending.PSObject.Properties['delegated_to'] -or -not $pending.delegated_to) { return $null }
    if ([DateTime]::UtcNow -lt (ConvertTo-DtJobUtc $pending.escalate_after_utc)) { return $null }
    $minutes = [int][Math]::Round(([DateTime]::UtcNow - (ConvertTo-DtJobUtc $pending.since_utc)).TotalMinutes)
    $held = if ($pending.PSObject.Properties['held'] -and $null -ne $pending.held) { $pending.held } else { $null }
    $text = if ($held) {
        $heldEt = [TimeZoneInfo]::ConvertTimeFromUtc((ConvertTo-DtJobUtc $held.held_utc), [TimeZoneInfo]::FindSystemTimeZoneById($(if ($IsWindows) { 'Eastern Standard Time' } else { 'America/New_York' }))).ToString('h:mm tt')
        "dt-build run $RunId has waited $minutes min for approval before: $($pending.operation). $($pending.delegated_to) is holding it on purpose since $heldEt ET: $($held.reason). Nothing is needed from you unless you want to decide it yourself: /dt-build approve $RunId $($pending.operation)"
    }
    else { "dt-build run $RunId has waited $minutes min for approval before: $($pending.operation), and $($pending.delegated_to) has not approved it. $($pending.message) To approve, run: /dt-build approve $RunId $($pending.operation)" }
    return (Send-DtJobRunAlert -RunFolder $RunFolder -Key "dt-build:${RunId}:awaiting:$($pending.operation):$($pending.seq)" -Message $text -RetryUntilDelivered)
}

function Get-DtJobOperatorNotes {
    # Danny's and his operator sessions' standing instructions for the run, kept outside _build-state.md
    # so no checkpoint rewrite can summarize them away.
    param([Parameter(Mandatory)][string]$RunFolder)
    $path = (Get-DtJobPaths -RunFolder $RunFolder).OperatorNotes
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try { return @((Read-DtJobText -Path $path | ConvertFrom-Json -ErrorAction Stop).notes | Where-Object { $null -ne $_ }) } catch { return @() }
}

function Get-DtJobEvidenceNotes {
    # Data only: this file can never grant or change run authority.
    param([Parameter(Mandatory)][string]$RunFolder)
    $path = (Get-DtJobPaths -RunFolder $RunFolder).EvidenceNotes
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try { return @((Read-DtJobText -Path $path | ConvertFrom-Json -ErrorAction Stop).notes | Where-Object { $null -ne $_ }) } catch { return @() }
}

function Invoke-DtJobNote {
    # Adds an operator note (-Message), removes one (-Clear -NoteId) or all (-Clear). Coordinators and jobs
    # cannot write notes; an operator may add one while a coordinator runs.
    if ($env:DT_BUILD_COORDINATOR_ID) { throw "DT_JOB_OPERATOR_ONLY: note is an operator command; coordinator $env:DT_BUILD_COORDINATOR_ID cannot run it" }
    if ($env:DT_JOB_ID) { throw "DT_JOB_OPERATOR_ONLY: note is an operator command; it cannot run inside dt-job job $env:DT_JOB_ID" }
    if (-not $Clear -and [string]::IsNullOrWhiteSpace($Message)) { throw 'DT_JOB_USAGE: note requires -Message <text>, or -Clear [-NoteId <id>].' }
    if (-not $Clear -and $Message.Length -gt 2000) { throw 'DT_JOB_USAGE: an operator note is at most 2000 characters; point to a file for more.' }
    if (-not $Clear -and $Evidence -and $Message -match $script:DtJobEvidenceAuthorityPattern) {
        throw 'DT_JOB_EVIDENCE_NOTE_AUTHORITY: evidence notes cannot carry authorization language; use a normal operator note without -Evidence.'
    }
    $prefix = if ($Evidence) { 'e' } else { 'n' }
    $paths = Get-DtJobPaths -RunFolder $RunFolder
    $notes = Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $current = [System.Collections.Generic.List[object]]::new()
        foreach ($n in $(if ($Evidence) { Get-DtJobEvidenceNotes -RunFolder $RunFolder } else { Get-DtJobOperatorNotes -RunFolder $RunFolder })) { $current.Add($n) }
        if ($Clear) {
            if ($NoteId) {
                $match = @($current | Where-Object { [string]$_.id -ceq $NoteId })
                if ($match.Count -eq 0) { throw "DT_JOB_UNKNOWN: operator note $NoteId" }
                [void]$current.Remove($match[0])
            }
            else { $current.Clear() }
        }
        else {
            $max = 0
            foreach ($n in $current) { if ([string]$n.id -match "^$prefix-(\d+)$") { $max = [Math]::Max($max, [int]$Matches[1]) } }
            $current.Add([pscustomobject][ordered]@{ id = ('{0}-{1:D3}' -f $prefix, ($max + 1)); text = $Message.Trim(); added_utc = [DateTime]::UtcNow.ToString('o') })
        }
        Write-DtJobAtomic -Path $(if ($Evidence) { $paths.EvidenceNotes } else { $paths.OperatorNotes }) -Content ([ordered]@{ notes = @($current) } | ConvertTo-Json -Depth 4)
        @($current)
    }
    $output = [ordered]@{ run_folder = $paths.Root }
    if ($Evidence) { $output.evidence_notes = @($notes); $output.evidence_notes_label = $script:DtJobEvidenceNotesLabel }
    else { $output.operator_notes = @($notes) }
    Write-DtJobOutput -Object ([pscustomobject]$output) -AsJson:$Json
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
    # One FYI digest of the stops a delegate approved for Danny.
    $delegated = @((Get-DtJobApprovals -RunFolder $RunFolder).approvals | Where-Object { $_.PSObject.Properties['delegated_to'] -and $_.delegated_to })
    if ($delegated.Count -gt 0) {
        $et = [TimeZoneInfo]::FindSystemTimeZoneById($(if ($IsWindows) { 'Eastern Standard Time' } else { 'America/New_York' }))
        $items = @($delegated | ForEach-Object { "$($_.operation) ($([TimeZoneInfo]::ConvertTimeFromUtc((ConvertTo-DtJobUtc $_.approved_utc), $et).ToString('MMM d h:mm tt')) ET, $($_.delegated_to))" })
        $null = Send-DtJobRunAlert -RunFolder $RunFolder -Key "dt-build:$($ctx.run_id):delegate-digest" -Message "dt-build run $($ctx.run_id) finished. Approved on your behalf: $($items -join '; ')." -RetryUntilDelivered
    }
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
            $report = Get-DtCtxState -Tokens $tokens -Baseline ([long]$entry.baseline_tokens) -TranscriptHost ([string]$entry.host)
        }
        else {
            $ctxHost = Resolve-DtJobContextHost -RunFolder $RunFolder -CoordinatorId $CoordinatorId -RequestedHost $RequestedHost
            if (-not $ctxHost) { throw 'host unknown before mark-bootstrap' }
            $transcript = Find-DtCtxTranscript -TranscriptHost $ctxHost
            $report = Get-DtCtxState -Tokens (Get-DtCtxTokens -TranscriptHost $ctxHost -TranscriptPath $transcript) -Baseline $null -TranscriptHost $ctxHost
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
        Set-DtCtxBootstrapMeasurement -Entry $new
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
    $overhead = if ($result.entry.PSObject.Properties['host_overhead_tokens']) { $result.entry.host_overhead_tokens } else { $null }
    $measurement = Get-DtCtxBootstrapMeasurement -Baseline $out.baseline_tokens -HostOverhead $overhead
    foreach ($property in $measurement.PSObject.Properties) { $out | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
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
# Check before approval handling, locks, or lease renewal can create the run folder.
Assert-DtJobRunFolder -RunFolder $RunFolder -WarnExisting:($Verb -eq 'start')
Receive-DtJobQueuedApproval -RunFolder $RunFolder

# Under `pwsh -File`, `-Mutates a,b` arrives as the single string 'a,b'; split every list on commas.
$script:RequeueReplaceDependencies = $PSBoundParameters.ContainsKey('DependsOn')
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
    'requeue' { Invoke-DtJobRequeue }
    'status' { Invoke-DtJobStatus }
    'wait' { Invoke-DtJobWait }
    'cancel' { Invoke-DtJobCancel }
    'reconcile' { Invoke-DtJobReconcile }
    'lease' { Invoke-DtJobLease }
    'pin' { Invoke-DtJobPin }
    'register-run' { Invoke-DtJobRegisterRun }
    'unregister-run' { Invoke-DtJobUnregisterRun }
    'consume' { Invoke-DtJobConsume }
    'request-continuation' { Invoke-DtJobRequestContinuation }
    'await-danny' { Invoke-DtJobAwaitDanny }
    'approve' { Invoke-DtJobApprove }
    'delegate' { Invoke-DtJobDelegate }
    'hold' { Invoke-DtJobHold }
    'note' { Invoke-DtJobNote }
    'resume' { Invoke-DtJobResume }
    'finish' { Invoke-DtJobFinish }
    'mark-bootstrap' { Invoke-DtJobMarkBootstrap }
    'irreversible' { Invoke-DtJobIrreversible }
}
$verbOutput
if ($null -ne $script:DtJobContext -and -not $Json) { $script:DtJobContext.line }
