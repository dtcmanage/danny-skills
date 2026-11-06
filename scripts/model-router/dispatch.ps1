[CmdletBinding()]
param(
    [string]$ProjectPath, [string]$Category, [string]$PromptPath, [string]$OutputPath,
    [string]$SelectionReason, [string]$Model, [string]$FrontierRequest,
    [ValidateSet('codex','claude')][string]$Lane,
    [ValidateSet('standard','hard')][string]$Difficulty = 'standard', [string]$DifficultyReason,
    [string]$RetryAtHardFrom, [string]$EscalateFrom, [switch]$Protected,
    [switch]$ReadOnly, [switch]$AdHoc, [switch]$Scrutiny, [switch]$SingleDispatch,
    [int]$Attempt = 1, [string]$ApprovalOperation, [string]$RunFolder,
    [string]$LogicalTaskId, [string]$PriorDispatchId,
    [int]$TimeoutMs, [switch]$AllowOutputInProject, [switch]$Live, [switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'resolve-model.ps1')
. (Join-Path $PSScriptRoot 'dispatch-evidence.ps1')

function New-RouterWrapperInvoker {
    param([string]$WrapperDirectory = (Join-Path $PSScriptRoot '../../skills/dt-build/scripts'))
    { param($Vendor,$Arguments)
        $scriptPath = Join-Path $WrapperDirectory "invoke-$Vendor-chunk.ps1"
        $laneArguments = $Arguments.Clone()
        if ($Vendor -ne 'codex') { $laneArguments.Remove('AllowOutputInProject') }
        if ($env:DT_ROUTER_TEST_FAKE_CLI_ROOT) {
            $cli = Get-Command ($Vendor + '.ps1'), ($Vendor + '.cmd'), $Vendor, ($Vendor + '.exe') -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -in @('Application','ExternalScript') } | Select-Object -First 1
            Assert-RouterTestCliPath -Path $cli.Source
        }
        & $scriptPath @laneArguments | Out-Null
    }.GetNewClosure()
}

function Invoke-RouterDispatch {
    param([hashtable]$Options, [scriptblock]$WrapperInvoker)
    foreach ($field in @('ProjectPath','Category','PromptPath','OutputPath','SelectionReason')) {
        if (-not $Options[$field] -or [string]::IsNullOrWhiteSpace([string]$Options[$field])) { throw "DISPATCH_REQUIRED: $field" }
    }
    if ($Options['SelectionReason'] -match '[\r\n]' -or $Options['SelectionReason'].Length -gt 240) { throw 'DISPATCH_SELECTION_REASON_INVALID' }
    if ([string]$Options['Model'] -match '^\s*(inherit|default|auto)\s*$') { throw 'DISPATCH_INHERITED_MODEL_REFUSED' }
    if (-not (Test-Path -LiteralPath $Options['ProjectPath'] -PathType Container) -or -not (Test-Path -LiteralPath $Options['PromptPath'] -PathType Leaf)) { throw 'DISPATCH_PATH_NOT_FOUND' }
    . (Join-Path $PSScriptRoot '../../skills/dt-build/scripts/worker-verification.ps1')
    if ($env:DT_JOB_DIR) {
        $jobRunFolder = Split-Path -Parent (Split-Path -Parent $env:DT_JOB_DIR)
        if ($Options['RunFolder'] -and [IO.Path]::GetFullPath($Options['RunFolder']) -ne [IO.Path]::GetFullPath($jobRunFolder)) { throw 'ATTEMPT_APPROVAL_REQUIRED: -RunFolder differs from the current dt-job run.' }
        $Options['RunFolder'] = $jobRunFolder
    }
    Assert-WorkerAttemptApproval -RequestedAttempt $(if ($Options['Attempt']) { $Options['Attempt'] } else { 1 }) -ApprovalName $Options['ApprovalOperation'] -ApprovalRunFolder $Options['RunFolder']
    $resolve = @{Category=$Options['Category']; ChatToStderr=$true; SendAlerts=(-not $Options['Scrutiny'])}
    foreach ($name in @('Lane','Protected','Difficulty','DifficultyReason','RetryAtHardFrom','EscalateFrom','FrontierRequest')) {
        if ($Options.ContainsKey($name)) { $resolve[$name] = $Options[$name] }
    }
    # Explicit overrides still pass through the roster and its approvals. A lane
    # constraint selects the matching approved slot; it never inherits host effort.
    if ($Options['Model']) {
        Assert-RouterNamedModel -Model $Options['Model'] -RequestId $Options['FrontierRequest']
        $named = Get-RouterNamedModel $Options['Model']
        if ($named) {
            if ($Options['Lane'] -and $Options['Lane'] -ne $named.vendor) { throw 'DISPATCH_MODEL_LANE_MISMATCH' }
            $resolve.Lane = $named.vendor
            $Options['Model'] = $named.model
        }
    }
    if ($env:DT_BUILD_RUN_PIN_VENDOR) { $resolve.Lane = $env:DT_BUILD_RUN_PIN_VENDOR }
    $pick = Resolve-RouterModel @resolve
    try {
    $requested = if ($Options['Model']) { $Options['Model'] } else { $pick.model }
    $context = New-RouterDispatchContext -PromptPath $Options['PromptPath'] -AdHoc:([bool]$Options['AdHoc']) -Project $Options['ProjectPath'] -Category $Options['Category'] -Attempt $(if ($Options['Attempt']) {$Options['Attempt']} else {1}) -LogicalTaskId $Options['LogicalTaskId'] -PriorDispatchId $Options['PriorDispatchId'] -RequestedModel $requested -OverrideReason $(if ($Options['Model']) {$Options['SelectionReason']})
    $path = [IO.Path]::GetFullPath($Options['OutputPath']) + '.provenance.json'
    $initial = [pscustomobject]@{resolved_model=$pick.model; lane=$pick.vendor; effort=$pick.effort; difficulty=(Get-DispatchValue $pick 'difficulty'); job=(Get-DispatchValue $pick 'job'); selection_reason=$Options['SelectionReason']}
    Write-RouterDispatchEvidence -Path $path -Record $initial -Context $context -Phase started
    if ($pick.status -ne 'ok') {
        $initial | Add-Member -NotePropertyName router_status -NotePropertyValue 'wait'
        $initial | Add-Member -NotePropertyName router_reason -NotePropertyValue $pick.reason
        $initial | Add-Member -NotePropertyName termination_reason -NotePropertyValue "ROUTER_WAIT: $($pick.reason)"
        $initial | Add-Member -NotePropertyName failure_category -NotePropertyValue 'environment' -Force
        Write-RouterDispatchEvidence -Path $path -Record $initial -Context $context -Phase wait
            throw "ROUTER_WAIT: $($pick.reason)"
    }
    if ($Options['Category'] -eq 'image-generation') {
        $initial | Add-Member -NotePropertyName failure_category -NotePropertyValue 'tooling' -Force
        $initial | Add-Member -NotePropertyName termination_reason -NotePropertyValue 'IMAGE_GENERATION_FIXED_PATH: use skills/dt-image-gen/scripts/gen-image.sh through dt-image-gen.'
        Write-RouterDispatchEvidence -Path $path -Record $initial -Context $context -ExitCode 1
            throw $initial.termination_reason
    }
    $adapter = @{}
    foreach ($name in @('ProjectPath','Category','PromptPath','OutputPath','SelectionReason','Model','Protected','ReadOnly','AdHoc','Scrutiny','SingleDispatch','Attempt','ApprovalOperation','RunFolder','FrontierRequest','TimeoutMs','Difficulty','DifficultyReason','RetryAtHardFrom','EscalateFrom','AllowOutputInProject')) {
        if ($Options.ContainsKey($name)) { $adapter[$name] = $Options[$name] }
    }
    $frontierPick = Assert-RouterDispatchPick -Resolution $pick -Model $Options['Model'] -RequestId $Options['FrontierRequest']
    if ($frontierPick) { $adapter.SingleDispatch = $true }
    $adapter.Effort = $pick.effort; $adapter.RouterResolution = $pick; $adapter.DispatchContext = $context; $adapter.Json = $true
    $vendor = $pick.vendor
    if (-not $WrapperInvoker) {
        if (-not $Options['Live']) { throw 'DISPATCH_LIVE_REQUIRED: model calls require -Live' }
        $WrapperInvoker = New-RouterWrapperInvoker
    }
    # Refusals before a wrapper's try/finally are still terminal dispatch evidence.
    $invokeAdapter = {
        param($Vendor, $Arguments)
        $beforeInvocation = [IO.File]::ReadAllText($path)
        try { & $WrapperInvoker $Vendor $Arguments }
        catch {
            if ($_.Exception.Message -like 'ROUTER_TEST_FAKE_CLI_REQUIRED*') { throw }
            $failure = Read-RouterDispatchEvidence -Path $path
            $message = Invoke-SecretRedaction -Text $_.Exception.Message
            if (-not (Get-DispatchValue $failure 'finished_utc') -or [IO.File]::ReadAllText($path) -ceq $beforeInvocation) {
                $failure | Add-Member -Force -NotePropertyName fallback_reason -NotePropertyValue $context.fallback_reason
                $failure | Add-Member -Force -NotePropertyName failure_category -NotePropertyValue 'tooling'
                $failure | Add-Member -Force -NotePropertyName termination_reason -NotePropertyValue $message
                Write-RouterDispatchEvidence -Path $path -Record $failure -Context $context -ExitCode 1
            }
            [Console]::Error.WriteLine($message)
        }
    }
    & $invokeAdapter $vendor $adapter
    $row = Read-RouterDispatchEvidence -Path $path
    $backup = Get-DispatchValue $row 'backup_pick'
    if ($backup -and $backup.status -eq 'ok' -and -not $Options['Lane'] -and -not $Options['SingleDispatch'] -and -not $frontierPick -and -not $env:DT_BUILD_RUN_PIN_VENDOR) {
        $context.fallback_reason = Get-DispatchValue $row 'failure_category'
        if (-not $context.fallback_reason) { $context.fallback_reason = 'wrapper backup choice' }
        $adapter.RouterResolution = $backup; $adapter.Effort = $backup.effort
        $adapter.Remove('Model')
        & $invokeAdapter $backup.vendor $adapter
        $row = Read-RouterDispatchEvidence -Path $path
    }
    if ($backup -and $Options['Lane'] -and $backup.vendor -ne $Options['Lane']) {
        $row | Add-Member -Force -NotePropertyName fallback_refusal -NotePropertyValue 'Explicit -Lane prevents cross-lane fallback.'
        Write-RouterDispatchEvidence -Path $path -Record $row -Context $context -ExitCode 1 -ActualModel $row.actual_model -Usage $row.usage
    }
    if ((Get-DispatchValue $row 'failure_category') -and (Get-DispatchValue $row 'termination_reason')) { [Console]::Error.WriteLine($row.termination_reason) }
    if ($Json) { $row | ConvertTo-Json -Depth 40 } else { $row }
    } finally {
        Undo-RouterFrontierReservation -Resolution $pick
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Live) { throw 'DISPATCH_LIVE_REQUIRED: model calls require -Live' }
    $options = @{}; foreach ($key in $PSBoundParameters.Keys) { $options[$key] = $PSBoundParameters[$key] }
    $row = Invoke-RouterDispatch -Options $options
    $row
    # Preserve execution failure separately from worker report/acceptance failure.
    $evidence = Read-RouterDispatchEvidence -Path ([IO.Path]::GetFullPath($OutputPath) + '.provenance.json')
    if ($evidence.execution_result -ne 'success' -or (Get-DispatchValue $evidence 'failure_category') -or (Get-DispatchValue $evidence 'pass') -eq $false) { exit 1 }
}
