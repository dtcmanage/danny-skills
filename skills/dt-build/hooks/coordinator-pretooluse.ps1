#Requires -Version 7.0
# Claude PreToolUse hook for dt-build coordinator sessions; installed only at adoption (see README.md).
# A session is a coordinator when DT_BUILD_COORDINATOR_ID is set, or when the hook's session_id matches a
# session recorded in a registered run's lease or context-baseline.json. Every other session passes
# untouched. For a coordinator it denies a Read of a file over 400 lines without offset/limit, image
# Reads, and CronCreate; past the hard context limit (unless an irreversible step is open) it also denies
# every discretionary tool, including shell commands other than the dt-build state scripts. Any error
# inside the hook allows the call: the hook must never break a session it cannot judge. Script-level
# names avoid dt-job.ps1's typed parameters, which dot-sourcing brings into this scope.
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\scripts\dt-job.ps1')

$script:HookDtJob = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts\dt-job.ps1'))
$script:HookReadMaxLines = 400
$script:HookImageExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp')
$script:HookDiscretionaryTools = @('Read', 'Grep', 'Glob', 'WebFetch', 'WebSearch', 'Agent', 'Task', 'NotebookEdit')
$script:HookShellTools = @('Bash', 'PowerShell')
# Past the hard limit a shell segment may only run these (plus a bare cd).
$script:HookShellAllowed = @(
    '(?i)\b(dt-job|read-evidence|write-build-state)\.ps1\b',
    '(?i)^\s*git(\s+-C\s+("[^"]*"|''[^'']*''|\S+))?\s+(status|log|rev-parse)\b',
    '(?i)^\s*(cd|Set-Location|Push-Location|sl)(\s|$)'
)

function Get-HookProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) { return $null }
    return $Object.$Name
}

function Find-HookCoordinator {
    # The coordinator this session is, or $null for any other session.
    param($HookInput)
    $sessionId = [string](Get-HookProperty $HookInput 'session_id')
    $transcript = [string](Get-HookProperty $HookInput 'transcript_path')
    $envId = $env:DT_BUILD_COORDINATOR_ID
    $runs = @()
    try { $runs = @(Get-DtJobRegistryRuns) } catch { $runs = @() }
    foreach ($run in $runs) {
        $folder = [string]$run.run_folder
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        $lease = Get-DtJobLease -RunFolder $folder
        $baselines = @((Get-DtJobContextBaselines -RunFolder $folder).coordinators.PSObject.Properties | ForEach-Object { $_.Value })
        $match = $null
        if ($envId) {
            $match = $baselines | Where-Object { [string]$_.coordinator_id -ceq $envId } | Select-Object -First 1
            if ($null -eq $match -and -not ($null -ne $lease -and [string]$lease.coordinator_id -ceq $envId)) { continue }
        }
        else {
            if ($sessionId) { $match = $baselines | Where-Object { $_.PSObject.Properties['session_id'] -and [string]$_.session_id -ceq $sessionId } | Select-Object -First 1 }
            if ($null -eq $match -and $transcript) { $match = $baselines | Where-Object { Test-DtCtxSamePath ([string]$_.transcript_path) $transcript } | Select-Object -First 1 }
            $leaseSession = [string](Get-HookProperty $lease 'session_id')
            if ($null -eq $match -and -not ($sessionId -and $leaseSession -ceq $sessionId)) { continue }
        }
        $id = if ($envId) { $envId } elseif ($null -ne $match) { [string]$match.coordinator_id } else { [string]$lease.coordinator_id }
        return [pscustomobject]@{ coordinator_id = $id; run_folder = (Get-DtJobPaths -RunFolder $folder).Root; baseline = $match }
    }
    # The env var alone marks a coordinator even before its run is registered: only the ceiling applies.
    if ($envId) { return [pscustomobject]@{ coordinator_id = $envId; run_folder = $null; baseline = $null } }
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
    $open = @(if ($Coordinator.run_folder) { Get-DtJobIrreversibleOpen -RunFolder $Coordinator.run_folder })
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

function Test-HookShellAllowed {
    # Every command segment must run a dt-build state script, git status/log/rev-parse, or a bare cd.
    param([string]$CommandText)
    if (-not $CommandText -or -not $CommandText.Trim()) { return $false }
    foreach ($segment in ($CommandText -split '\r?\n|;|&&|\|\|')) {
        if (-not $segment.Trim()) { continue }
        $ok = $false
        foreach ($pattern in $script:HookShellAllowed) { if ($segment -match $pattern) { $ok = $true; break } }
        if (-not $ok) { return $false }
    }
    return $true
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
        elseif ($script:HookShellTools -contains $tool -and -not (Test-HookShellAllowed ([string](Get-HookProperty $toolInput 'command')))) { $hard = $true }
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

function Read-HookInput {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw.Trim()) { return $null }
    return ($raw | ConvertFrom-Json)
}

# Dot-sourcing (the PostToolUse hook does) loads the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    $hookInput = Read-HookInput
    if ($null -eq $hookInput) { exit 0 }
    $coordinator = Find-HookCoordinator -HookInput $hookInput
    if ($null -eq $coordinator) { exit 0 }
    $context = Get-HookContext -Coordinator $coordinator -HookInput $hookInput
    $denyReason = Get-HookDenyReason -HookInput $hookInput -Coordinator $coordinator -Context $context
    if ($null -eq $denyReason) { exit 0 }
    [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $denyReason } } | ConvertTo-Json -Depth 4 -Compress
    exit 0
}
catch { exit 0 }
