#Requires -Version 7.0
# Claude PostToolUse hook for dt-build coordinator sessions; installed only at adoption (see README.md).
# After a shell call that ran dt-job mark-bootstrap, records this session's own session_id and transcript
# into context-baseline.json for that coordinator: the hook is the authoritative source and replaces any
# discovered guess, creates the entry when mark-bootstrap found no transcript, and never moves a
# hook-recorded entry to a different session. Surfaces the context line as additional context when the coordinator reaches
# checkpoint or rotate; silent when the state is ok and for every non-coordinator session. With the env
# var unset and no registered run it exits before loading anything. Any error is silent.
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'coordinator-pretooluse.ps1'))

function Get-HookArgument {
    # The literal value of -<Name> in one command segment, or $null (absent, or a variable).
    param([Parameter(Mandatory)][string]$Segment, [Parameter(Mandatory)][string]$Name)
    $m = [regex]::Match($Segment, "(?i)(?:^|\s)-$Name\s+(?:`"([^`"]*)`"|'([^']*)'|([^\s'`"]+))")
    if (-not $m.Success) { return $null }
    $value = @($m.Groups[1], $m.Groups[2], $m.Groups[3] | Where-Object { $_.Success } | ForEach-Object { $_.Value })[0]
    if (-not $value -or $value.StartsWith('$')) { return $null }
    return $value
}

function Get-HookBootstrapCapture {
    # The run and coordinator whose baseline this call's mark-bootstrap wrote, or $null.
    param($HookInput)
    if ($script:HookShellTools -notcontains [string](Get-HookProperty $HookInput 'tool_name')) { return $null }
    if (-not (Get-HookProperty $HookInput 'session_id') -or -not (Get-HookProperty $HookInput 'transcript_path')) { return $null }
    $command = [string](Get-HookProperty (Get-HookProperty $HookInput 'tool_input') 'command')
    if (-not $command.Contains('mark-bootstrap')) { return $null }
    foreach ($segment in (Split-HookShellSegments $command)) {
        if ($segment -notmatch '(?i)(?:^|\s)mark-bootstrap(?:\s|$)' -or $segment -notmatch '(?i)dt-job\.ps1') { continue }
        $isCall = $false
        foreach ($pattern in $script:HookShellAllowed[0..1]) { if ($segment -match $pattern) { $isCall = $true; break } }
        if (-not $isCall) { continue }
        $id = Get-HookArgument -Segment $segment -Name 'CoordinatorId'
        if (-not $id) { $id = $env:DT_BUILD_COORDINATOR_ID }
        if (-not $id) { continue }
        $named = Get-HookArgument -Segment $segment -Name 'RunFolder'
        foreach ($run in @(Get-HookRegistryRuns)) {
            $folder = [string]$run.run_folder
            if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
            if ($named -and -not (Test-DtCtxSamePath $named $folder)) { continue }
            $files = Get-HookRunFiles -Folder $folder
            $entry = $files.baselines | Where-Object { [string]$_.coordinator_id -ceq $id } | Select-Object -First 1
            if ($null -ne $entry -and [string]$entry.host -eq 'claude') { return [pscustomobject]@{ run_folder = $folder; coordinator_id = $id } }
            # No entry: mark-bootstrap found no transcript (e.g. after a cd). The named run, or the run this
            # coordinator holds the lease of, gets one from this session.
            if ($null -eq $entry -and ($named -or [string](Get-HookProperty $files.lease 'coordinator_id') -ceq $id)) { return [pscustomobject]@{ run_folder = $folder; coordinator_id = $id } }
        }
    }
    return $null
}

function Save-HookBootstrapCapture {
    # Writes this session into the coordinator's baseline under the run lock. A different transcript than
    # the recorded one also replaces the baseline tokens, measured from this session's transcript.
    param([Parameter(Mandatory)]$Capture, [Parameter(Mandatory)]$HookInput)
    $sessionId = [string]$HookInput.session_id
    $transcript = [System.IO.Path]::GetFullPath([string]$HookInput.transcript_path)
    $paths = Get-DtJobPaths -RunFolder $Capture.run_folder
    Invoke-DtJobLocked -RunFolder $Capture.run_folder -Action {
        $all = Get-DtJobContextBaselines -RunFolder $Capture.run_folder
        $prop = $all.coordinators.PSObject.Properties[$Capture.coordinator_id]
        if ($null -eq $prop) {
            if (-not (Test-Path -LiteralPath $transcript)) { return }
            $tokens = Get-DtCtxTokens -TranscriptHost 'claude' -TranscriptPath $transcript
            if ($null -eq $tokens) { return }
            $new = [pscustomobject][ordered]@{
                coordinator_id = $Capture.coordinator_id; host = 'claude'; transcript_path = $transcript; session_id = $sessionId
                transcript_source = 'hook'; baseline_tokens = [long]$tokens; marked_utc = [DateTime]::UtcNow.ToString('o'); captured_utc = [DateTime]::UtcNow.ToString('o')
            }
            $all.coordinators | Add-Member -NotePropertyName $Capture.coordinator_id -NotePropertyValue $new -Force
            Write-DtJobAtomic -Path $paths.ContextBaseline -Content ($all | ConvertTo-Json -Depth 6)
            return
        }
        $entry = $prop.Value
        $samePath = Test-DtCtxSamePath ([string]$entry.transcript_path) $transcript
        $recordedSession = if ($entry.PSObject.Properties['session_id']) { [string]$entry.session_id } else { '' }
        $recordedSource = if ($entry.PSObject.Properties['transcript_source']) { [string]$entry.transcript_source } else { '' }
        if ($samePath -and $recordedSession -ceq $sessionId -and $recordedSource -eq 'hook') { return }
        # A hook-sourced entry is the coordinator's own session: another session never takes it over.
        if ($recordedSource -eq 'hook' -and $recordedSession -cne $sessionId) { return }
        if (-not $samePath -and (Test-Path -LiteralPath $transcript)) {
            $tokens = Get-DtCtxTokens -TranscriptHost 'claude' -TranscriptPath $transcript
            if ($null -ne $tokens) { $entry.baseline_tokens = [long]$tokens }
        }
        $entry | Add-Member -NotePropertyName transcript_path -NotePropertyValue $transcript -Force
        $entry | Add-Member -NotePropertyName session_id -NotePropertyValue $sessionId -Force
        $entry | Add-Member -NotePropertyName transcript_source -NotePropertyValue 'hook' -Force
        $entry | Add-Member -NotePropertyName captured_utc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        Write-DtJobAtomic -Path $paths.ContextBaseline -Content ($all | ConvertTo-Json -Depth 6)
    }
}

try {
    $rawText = Read-HookStdin
    if (-not $rawText.Trim() -or (Test-HookIdle)) { exit 0 }
    . (Join-Path $PSScriptRoot '..\scripts\context-guard.ps1')
    $hookInput = $rawText | ConvertFrom-Json
    # Only this rare call loads dt-job.ps1, for its run lock and atomic write.
    try {
        $capture = Get-HookBootstrapCapture -HookInput $hookInput
        if ($null -ne $capture) {
            . (Join-Path $PSScriptRoot '..\scripts\dt-job.ps1')
            Save-HookBootstrapCapture -Capture $capture -HookInput $hookInput
        }
    }
    catch { }
    $coordinator = Find-HookCoordinator -HookInput $hookInput
    if ($null -eq $coordinator) { exit 0 }
    $context = Get-HookContext -Coordinator $coordinator -HookInput $hookInput
    if (@('checkpoint', 'rotate') -notcontains $context.state) { exit 0 }
    $runFolder = if ($coordinator.run_folder) { $coordinator.run_folder } else { '<run folder>' }
    $next = if ($context.state -eq 'checkpoint') {
        'Soft limit reached: finish the current decision and write _build-state.md before taking on more.'
    }
    elseif ($context.deferred) {
        'Hard limit reached; rotation waits for the open irreversible step. Finish it, run dt-job irreversible -Action end, then rotate.'
    }
    else {
        "Hard limit reached: write _build-state.md and the coordinator handoff, run pwsh -NoProfile -File `"$($script:HookDtJob)`" request-continuation -RunFolder `"$runFolder`" -Reason context_rotation, release the lease, and end the turn."
    }
    [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PostToolUse'; additionalContext = "$($context.line). $next" } } | ConvertTo-Json -Depth 4 -Compress
    exit 0
}
catch { exit 0 }
