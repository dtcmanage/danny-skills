#Requires -Version 7.0
# Claude PreToolUse hook for dt-build coordinator sessions; installed only at adoption (see README.md).
# A session is a coordinator when DT_BUILD_COORDINATOR_ID is set, or when the hook's session_id matches a
# session recorded for the current unreleased lease holder of a registered run, in its lease or
# context-baseline.json (never a discovered guess); a released or superseded coordinator is not one. Every
# other session passes untouched, and with the env var unset and no registered run the hook exits before
# loading anything. For a coordinator it denies a Read of a file over 400 lines without offset/limit, image
# Reads, and CronCreate; past the hard context limit (unless an irreversible step this coordinator opened
# is still open) it also denies every discretionary tool, including shell commands other than the dt-build
# state scripts. Any error inside the hook allows the call: the hook must never break a session it cannot
# judge. The hooks read run files directly rather than loading dt-job.ps1, so their cost stays near the
# pwsh start.
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Run-folder file names, as dt-job.ps1 Get-DtJobPaths names them.
$script:HookLeaseFile = 'coordinator.lease'
$script:HookBaselineFile = 'context-baseline.json'
$script:HookIrreversibleFile = 'irreversible.json'

# Everything up to the idle check uses .NET calls only, so a call that exits there loads no module.
function Get-HookRegistryPath {
    # The run registry, by the same rule as dt-job.ps1 Get-DtJobRegistryPath.
    $dir = if ($env:DT_BUILD_STATE_DIR) { $env:DT_BUILD_STATE_DIR } else { [System.IO.Path]::Combine($env:LOCALAPPDATA, 'dt-build') }
    return [System.IO.Path]::Combine([System.IO.Path]::GetFullPath($dir), 'active-runs.json')
}

function Read-HookText {
    # A run file's text, or $null when it is missing. Shares read, write, and delete like dt-job's readers.
    param([Parameter(Mandatory)][string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try { return [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8).ReadToEnd() }
    finally { $stream.Dispose() }
}

function Read-HookJson {
    # A run file parsed, or $null when it is missing or empty.
    param([Parameter(Mandatory)][string]$Path)
    $text = Read-HookText -Path $Path
    if ($null -eq $text -or -not $text.Trim()) { return $null }
    return ($text | ConvertFrom-Json)
}

function Get-HookRegistryRuns {
    $parsed = Read-HookJson -Path (Get-HookRegistryPath)
    if ($null -eq $parsed -or -not $parsed.PSObject.Properties['runs']) { return @() }
    return @($parsed.runs | Where-Object { $null -ne $_ })
}

function Test-HookIdle {
    # No coordinator can be in play: the env var is unset and the registry is missing or lists no runs.
    # An unreadable registry counts as idle, as any hook error allows the call.
    if ($env:DT_BUILD_COORDINATOR_ID) { return $false }
    try {
        $text = Read-HookText -Path (Get-HookRegistryPath)
        if ($null -eq $text -or -not $text.Trim()) { return $true }
        $doc = [System.Text.Json.JsonDocument]::Parse($text)
        try {
            # A typed out variable: PowerShell finds no TryGetProperty overload for a [ref] to $null.
            $runs = [System.Text.Json.JsonElement]::new()
            if ($doc.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -or -not $doc.RootElement.TryGetProperty('runs', [ref]$runs) -or $runs.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { return $true }
            foreach ($run in $runs.EnumerateArray()) { if ($run.ValueKind -ne [System.Text.Json.JsonValueKind]::Null) { return $false } }
            return $true
        }
        finally { $doc.Dispose() }
    }
    catch { return $true }
}

function Read-HookStdin {
    # The hook input as text; parsed only after the idle check.
    return [Console]::In.ReadToEnd()
}

$script:HookDotSourced = ($MyInvocation.InvocationName -eq '.')
if (-not $script:HookDotSourced) {
    try {
        $script:HookRawText = Read-HookStdin
        if (-not $script:HookRawText.Trim() -or (Test-HookIdle)) { exit 0 }
    }
    catch { exit 0 }
    # Loaded only past the idle check; the PostToolUse hook loads it the same way.
    . (Join-Path $PSScriptRoot '..\scripts\context-guard.ps1')
}

$script:HookDtJob = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'scripts', 'dt-job.ps1'))
$script:HookReadMaxLines = 400
$script:HookImageExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp')
$script:HookDiscretionaryTools = @('Read', 'Grep', 'Glob', 'WebFetch', 'WebSearch', 'Agent', 'Task', 'NotebookEdit')
$script:HookShellTools = @('Bash', 'PowerShell')
# Past the hard limit each shell segment must be one of these: pwsh/powershell -File, or a & or . call, of
# a dt-build state script; or git status, log, or rev-parse. A script name anywhere else in a segment (an
# argument, a comment) does not count.
$script:HookStateScript = '(?:dt-job|read-evidence|write-build-state)\.ps1'
$script:HookScriptPath = "(?:`"(?:[^`"]*[\\/])?$($script:HookStateScript)`"|'(?:[^']*[\\/])?$($script:HookStateScript)'|(?:[^\s'`"]*[\\/])?$($script:HookStateScript))(?=\s|$)"
$script:HookShellAllowed = @(
    "(?i)^\s*(?:pwsh|powershell)(?:\.exe)?(?:\s+(?:-NoProfile|-NonInteractive|-NoLogo|-nop|-noni|-ExecutionPolicy\s+\S+|-ep\s+\S+|-WindowStyle\s+\S+))*\s+-File\s+$($script:HookScriptPath)",
    "(?i)^\s*(?:&\s*|\.\s+)$($script:HookScriptPath)",
    '(?i)^\s*git(?:\s+-C\s+(?:"[^"]*"|''[^'']*''|\S+))?\s+(?:status|log|rev-parse)(?=\s|$)'
)

function Get-HookProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) { return $null }
    return $Object.$Name
}

function Get-HookRunFiles {
    # One registered run's lease and context baselines, read straight from its folder.
    param([Parameter(Mandatory)][string]$Folder)
    $root = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')
    $lease = $null
    try { $lease = Read-HookJson -Path (Join-Path $root $script:HookLeaseFile) } catch { $lease = $null }
    $parsed = Read-HookJson -Path (Join-Path $root $script:HookBaselineFile)
    $baselines = @()
    if ($null -ne $parsed -and $parsed.PSObject.Properties['coordinators'] -and $null -ne $parsed.coordinators) {
        $baselines = @($parsed.coordinators.PSObject.Properties | ForEach-Object { $_.Value })
    }
    return [pscustomobject]@{ root = $root; lease = $lease; baselines = $baselines }
}

function Test-HookBaselineTrusted {
    # A discovered transcript is only a guess at the coordinator's session, so it never identifies one.
    param($Baseline)
    return -not ($Baseline.PSObject.Properties['transcript_source'] -and $Baseline.transcript_source -eq 'discovered')
}

function Find-HookCoordinator {
    # The coordinator this session is, or $null for any other session.
    param($HookInput)
    $sessionId = [string](Get-HookProperty $HookInput 'session_id')
    $transcript = [string](Get-HookProperty $HookInput 'transcript_path')
    $envId = $env:DT_BUILD_COORDINATOR_ID
    $runs = @()
    try { $runs = @(Get-HookRegistryRuns) } catch { $runs = @() }
    foreach ($run in $runs) {
        $folder = [string]$run.run_folder
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        $files = Get-HookRunFiles -Folder $folder
        $lease = $files.lease
        $baselines = $files.baselines
        $match = $null
        if ($envId) {
            $match = $baselines | Where-Object { [string]$_.coordinator_id -ceq $envId } | Select-Object -First 1
            if ($null -eq $match -and -not ($null -ne $lease -and [string]$lease.coordinator_id -ceq $envId)) { continue }
        }
        else {
            # Without the env var only the current unreleased lease holder is a coordinator: a session that
            # released the lease, or whose lease another coordinator took, is left alone.
            $holder = if ($null -ne $lease -and -not (Get-HookProperty $lease 'released_utc')) { [string](Get-HookProperty $lease 'coordinator_id') } else { '' }
            if (-not $holder) { continue }
            $trusted = @($baselines | Where-Object { (Test-HookBaselineTrusted $_) -and [string]$_.coordinator_id -ceq $holder })
            if ($sessionId) { $match = $trusted | Where-Object { $_.PSObject.Properties['session_id'] -and [string]$_.session_id -ceq $sessionId } | Select-Object -First 1 }
            if ($null -eq $match -and $transcript) { $match = $trusted | Where-Object { Test-DtCtxSamePath ([string]$_.transcript_path) $transcript } | Select-Object -First 1 }
            $leaseSession = [string](Get-HookProperty $lease 'session_id')
            if ($null -eq $match -and -not ($sessionId -and $leaseSession -ceq $sessionId)) { continue }
        }
        $id = if ($envId) { $envId } elseif ($null -ne $match) { [string]$match.coordinator_id } else { [string]$lease.coordinator_id }
        return [pscustomobject]@{ coordinator_id = $id; run_folder = $files.root; baseline = $match; lease = $lease }
    }
    # The env var alone marks a coordinator even before its run is registered: only the ceiling applies.
    if ($envId) { return [pscustomobject]@{ coordinator_id = $envId; run_folder = $null; baseline = $null; lease = $null } }
    return $null
}

function Get-HookContext {
    # The coordinator's context state, measured from the session's own transcript.
    param([Parameter(Mandatory)]$Coordinator, $HookInput)
    $transcript = [string](Get-HookProperty $HookInput 'transcript_path')
    if (-not $transcript -and $null -ne $Coordinator.baseline) { $transcript = [string]$Coordinator.baseline.transcript_path }
    $tokens = $null
    if ($transcript -and (Test-Path -LiteralPath $transcript)) { $tokens = Get-DtCtxTokens -TranscriptHost 'claude' -TranscriptPath $transcript }
    $baseline = if ($null -ne $Coordinator.baseline) { [long]$Coordinator.baseline.baseline_tokens } else { $null }
    $report = Get-DtCtxState -Tokens $tokens -Baseline $baseline
    # Only a step the current lease holder opened defers the hard-limit denials.
    $open = @()
    if ($Coordinator.run_folder) {
        $steps = Read-HookJson -Path (Join-Path $Coordinator.run_folder $script:HookIrreversibleFile)
        if ($null -ne $steps -and $steps.PSObject.Properties['open']) { $open = @((Split-DtCtxIrreversibleSteps -Open @($steps.open) -Lease $Coordinator.lease).deferring) }
    }
    $report | Add-Member -NotePropertyName deferred -NotePropertyValue ($report.state -eq 'rotate' -and $open.Count -gt 0)
    return $report
}

function Test-HookFileOverLines {
    # True when the file has more than $MaxLines lines; stops counting at the first line past it.
    param([Parameter(Mandatory)][string]$Path, [int]$MaxLines = $script:HookReadMaxLines)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $buffer = [byte[]]::new(65536)
        $newlines = 0
        $last = [byte]10
        while (($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            for ($i = 0; $i -lt $n; $i++) { if ($buffer[$i] -eq 10) { $newlines++ } }
            $last = $buffer[$n - 1]
            if ($newlines -gt $MaxLines) { return $true }
        }
        $lines = if ($last -eq 10) { $newlines } else { $newlines + 1 }
        return ($lines -gt $MaxLines)
    }
    finally { $stream.Dispose() }
}

function Split-HookShellSegments {
    # Command segments split on newlines, ;, &&, ||, |, and &. A & that opens a segment is the call
    # operator and stays with it; a & inside a redirection (2>&1, &>log) is part of it; any other & ends
    # the segment. Splitting inside quotes only adds segments, each of which must pass on its own, so it
    # can never let a command through.
    param([string]$CommandText)
    $segments = [System.Collections.Generic.List[string]]::new()
    foreach ($piece in ($CommandText -split '\r?\n|;|&&|\|\||\|')) {
        $rest = $piece
        $prefix = ''
        if ($rest -match '^\s*&') {
            $at = $rest.IndexOf('&')
            $prefix = $rest.Substring(0, $at + 1)
            $rest = $rest.Substring($at + 1)
        }
        $parts = @($rest -split '(?<!>)&(?!>)')
        $parts[0] = $prefix + $parts[0]
        foreach ($part in $parts) { if ($part.Trim()) { $segments.Add($part) } }
    }
    return @($segments)
}

function Test-HookShellAllowed {
    # Every command segment must run a dt-build state script or git status/log/rev-parse.
    param([string]$CommandText)
    if (-not $CommandText -or -not $CommandText.Trim()) { return $false }
    foreach ($segment in (Split-HookShellSegments $CommandText)) {
        $ok = $false
        foreach ($pattern in $script:HookShellAllowed) { if ($segment -match $pattern) { $ok = $true; break } }
        if (-not $ok) { return $false }
    }
    return $true
}

function Test-HookShellStartsJob {
    # True when a segment runs dt-job.ps1 with the start verb, positional or as -Verb (quoted, -Verb:start,
    # or an abbreviation). Any argument that is exactly start counts: no call a past-hard coordinator still
    # needs carries one.
    param([string]$CommandText)
    if (-not $CommandText) { return $false }
    foreach ($segment in (Split-HookShellSegments $CommandText)) {
        foreach ($pattern in $script:HookShellAllowed) {
            $call = [regex]::Match($segment, $pattern)
            if (-not $call.Success) { continue }
            if ($call.Value -notmatch "(?i)dt-job\.ps1['`"]?$") { break }
            foreach ($arg in [regex]::Matches($segment.Substring($call.Index + $call.Length), "`"[^`"]*`"|'[^']*'|\S+")) {
                if ($arg.Value -match "(?i)^(?:-v\w*:)?['`"]?start['`"]?$") { return $true }
            }
            break
        }
    }
    return $false
}

function Get-HookDenyReason {
    # The deny reason for this call, or $null to allow it.
    param([Parameter(Mandatory)]$HookInput, [Parameter(Mandatory)]$Coordinator, [Parameter(Mandatory)]$Context)
    $tool = [string](Get-HookProperty $HookInput 'tool_name')
    $toolInput = Get-HookProperty $HookInput 'tool_input'
    $runFolder = if ($Coordinator.run_folder) { $Coordinator.run_folder } else { '<run folder>' }
    if ($Context.state -eq 'rotate' -and -not $Context.deferred) {
        $hard = $false
        if ($script:HookDiscretionaryTools -contains $tool) { $hard = $true }
        elseif ($script:HookShellTools -contains $tool) {
            $shellCommand = [string](Get-HookProperty $toolInput 'command')
            if (-not (Test-HookShellAllowed $shellCommand)) { $hard = $true }
            elseif (Test-HookShellStartsJob $shellCommand) {
                return "dt-build context guard: $($Context.line). This coordinator is past its hard context limit, so dt-job start is blocked: no new dispatch. Next step: write _build-state.md and the coordinator handoff, run pwsh -NoProfile -File `"$($script:HookDtJob)`" request-continuation -RunFolder `"$runFolder`" -Reason context_rotation, release the lease, and end the turn."
            }
        }
        if ($hard) {
            return "dt-build context guard: $($Context.line). This coordinator is past its hard context limit, so $tool is blocked. Next step: write _build-state.md and the coordinator handoff, run pwsh -NoProfile -File `"$($script:HookDtJob)`" request-continuation -RunFolder `"$runFolder`" -Reason context_rotation, release the lease, and end the turn."
        }
    }
    if ($tool -eq 'CronCreate') {
        return 'dt-build context guard: CronCreate is blocked in a dt-build coordinator session; the dt-build watcher owns scheduling. Use dt-job wait for a running job, or end the turn and let the watcher continue the run.'
    }
    if ($tool -eq 'Read') {
        $path = [string](Get-HookProperty $toolInput 'file_path')
        if ($path -and $script:HookImageExtensions -contains [System.IO.Path]::GetExtension($path).ToLowerInvariant()) {
            return "dt-build context guard: image reads are blocked in a dt-build coordinator session ($path). Record the image path as evidence instead of viewing it."
        }
        $ranged = ($null -ne (Get-HookProperty $toolInput 'offset')) -or ($null -ne (Get-HookProperty $toolInput 'limit'))
        if ($path -and -not $ranged -and (Test-HookFileOverLines -Path $path)) {
            return "dt-build context guard: $path is longer than $($script:HookReadMaxLines) lines. Read it again with offset and limit (at most $($script:HookReadMaxLines) lines), or summarize it with read-evidence.ps1."
        }
    }
    return $null
}

# Dot-sourcing (the PostToolUse hook does) loads the functions only.
if ($script:HookDotSourced) { return }

try {
    $hookInput = $script:HookRawText | ConvertFrom-Json
    $coordinator = Find-HookCoordinator -HookInput $hookInput
    if ($null -eq $coordinator) { exit 0 }
    $context = Get-HookContext -Coordinator $coordinator -HookInput $hookInput
    $denyReason = Get-HookDenyReason -HookInput $hookInput -Coordinator $coordinator -Context $context
    if ($null -eq $denyReason) { exit 0 }
    [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $denyReason } } | ConvertTo-Json -Depth 4 -Compress
    exit 0
}
catch { exit 0 }
