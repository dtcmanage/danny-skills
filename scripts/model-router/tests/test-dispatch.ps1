foreach ($name in @('DT_JOB_ID','DT_JOB_DIR','DT_BUILD_COORDINATOR_ID')) { Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../dispatch.ps1')
. (Join-Path $PSScriptRoot '../update-outcomes.ps1')
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) ('dispatch-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$priorState = $env:DT_MODEL_ROUTER_STATE
$env:DT_MODEL_ROUTER_STATE = Join-Path $temp 'state'
$fixture = Enter-RouterTestCodexHome
$script:blocked = @()
function Get-RouterVendorBlocked { param($Vendor,$UsageReadings) $Vendor -in $script:blocked }
function Get-RouterClaudeUsage { $null }
function Get-RouterCodexUsage { $null }
$checks = 0
function Check([bool]$Condition,[string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $script:checks++ }
function Reject([scriptblock]$Action,[string]$Pattern) {
    try { & $Action | Out-Null } catch { Check ($_.Exception.Message -match $Pattern) "reject $Pattern ($($_.Exception.Message))"; return }
    throw "FAIL: accepted $Pattern"
}
$script:mode = 'success'
$script:received = [Collections.Generic.List[object]]::new()
$fake = {
    param($Vendor,$Arguments)
    $script:received.Add([pscustomobject]@{vendor=$Vendor;arguments=$Arguments.Clone();dispatch_id=$Arguments.DispatchContext.dispatch_id})
    $ctx = $Arguments.DispatchContext
    $pick = $Arguments.RouterResolution
    $row = [pscustomobject]@{resolved_model=$pick.model; effort=$Arguments.Effort; lane=$Vendor; tier='standard'; failure_category=$null; pass=$true}
    if ($script:mode -eq 'crash') { return }
    if ($script:mode -eq 'fallback' -and $Vendor -eq 'codex') {
        $backup = Resolve-RouterModel -Category $Arguments.Category -Lane claude -SkipModelCheck
        $row | Add-Member -NotePropertyName backup_pick -NotePropertyValue $backup
        $row.failure_category = 'environment'
        Write-RouterDispatchEvidence ($Arguments.OutputPath+'.provenance.json') $row $ctx -ExitCode 9
    } else {
        $actual = if ($script:mode -eq 'unknown') { $null } else { $pick.model }
        Write-RouterDispatchEvidence ($Arguments.OutputPath+'.provenance.json') $row $ctx -ExitCode 0 -ActualModel $actual
    }
}
try {
    $dispatchSource=Get-Content (Join-Path $PSScriptRoot '../dispatch.ps1') -Raw
    Check ($dispatchSource -match 'SendAlerts=\(-not \$Options\[''Scrutiny''\]\)') 'public resolver preserves alerts outside scrutiny'
    $repo = Join-Path $temp 'repo'; [IO.Directory]::CreateDirectory($repo) | Out-Null
    $prompt = Join-Path $temp 'prompt.md'; [IO.File]::WriteAllText($prompt,'fixture')
    $roster = Get-Content (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json
    $roster.approved=$true; $roster.approved_at='2026-11-05T00:00:00Z'
    [IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_STATE) | Out-Null
    $roster | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json')
    $base = @{ProjectPath=$repo; Category='routine-coding'; PromptPath=$prompt; OutputPath=(Join-Path $repo 'output.md'); SelectionReason='fixture reason'; AdHoc=$true; ReadOnly=$true}
    foreach ($field in @('ProjectPath','Category','PromptPath','OutputPath','SelectionReason')) {
        $o=$base.Clone(); $o.Remove($field); Reject { Invoke-RouterDispatch $o $fake } "DISPATCH_REQUIRED: $field"
    }
    $o=$base.Clone(); $o.Model='inherit'; Reject { Invoke-RouterDispatch $o $fake } 'INHERITED_MODEL'
    $o=$base.Clone(); $o.Model='fable'; Reject { Invoke-RouterDispatch $o $fake } 'FRONTIER_REQUEST_REQUIRED'
    foreach ($category in @(Get-RouterDispatchCategories)) {
        $o=$base.Clone(); $o.Category=$category
        if ($category -eq 'image-generation') {
            Reject { Invoke-RouterDispatch $o $fake } 'dt-image-gen/scripts/gen-image.sh'
            $record=Get-Content ($o.OutputPath+'.provenance.json') -Raw | ConvertFrom-Json
            Check ($record.termination_reason -match 'dt-image-gen/scripts/gen-image.sh' -and $record.execution_result -eq 'failure') 'image refusal recorded'
            continue
        }
        $r=Invoke-RouterDispatch $o $fake
        $want=Resolve-RouterModel -Category $category
        Check ($r.requested_model -ceq $want.model -and $r.effort -ceq $want.effort) "roster $category"
        Check ($null -eq $r.independent_acceptance -and $r.execution_result -eq 'success') 'exit success is not acceptance'
    }
    $o=$base.Clone(); $o.Model='claude-opus-5-5'; $r=Invoke-RouterDispatch $o $fake
    Check ($r.override_reason -ceq 'fixture reason' -and $r.requested_model -ceq $o.Model) 'override reason recorded'
    $o.Remove('SelectionReason'); Reject { Invoke-RouterDispatch $o $fake } 'SELECTION|SelectionReason'
    $o=$base.Clone(); $o.Lane='claude'; $o.Protected=$true
    $r=Invoke-RouterDispatch $o $fake
    Check ($script:received[-1].vendor -eq 'claude' -and $script:received[-1].arguments.ReadOnly -and $script:received[-1].arguments.Protected) 'cross-family, read-only and protection passed'
    $script:blocked=@('codex'); $r=Invoke-RouterDispatch $base $fake
    Check ($r.actual_model -like 'claude-*') 'quota fallback'
    $script:blocked=@('codex','claude'); Reject { Invoke-RouterDispatch $base $fake } 'ROUTER_WAIT'
    $script:blocked=@()
    $o=$base.Clone(); $o.Attempt=3; Reject { Invoke-RouterDispatch $o $fake } 'ATTEMPT_APPROVAL_REQUIRED'
    $o=$base.Clone(); $o.Attempt=2; $o.RetryAtHardFrom='gpt-6.1-sol'; $o.DifficultyReason='failed first attempt'
    $r=Invoke-RouterDispatch $o $fake
    Check ($script:received[-1].arguments.RouterResolution.effort -eq 'high') 'hard retry keeps router authority'
    $script:mode='fallback'; $r=Invoke-RouterDispatch $base $fake
    Check ($r.requested_model -like 'gpt-*' -and $r.actual_model -like 'claude-*' -and $r.fallback_reason -eq 'environment') 'Codex fallback retains requested and actual model plus reason'
    Check ($script:received[-1].dispatch_id -eq $script:received[-2].dispatch_id) 'nested adapters share identity'
    $script:mode='unknown'; $r=Invoke-RouterDispatch $base $fake
    Check ($null -eq $r.actual_model -and $null -eq $r.usage) 'unknown actual and usage stay null'
    $script:mode='crash'; $r=Invoke-RouterDispatch $base $fake
    Check ($null -eq $r.finished_utc -and $null -eq $r.execution_result) 'crashed start stays unfinished'
    $script:mode='success'; $o=$base.Clone(); $o.OutputPath=Join-Path $temp 'outside-project.md'; $r=Invoke-RouterDispatch $o $fake
    $indexed=@(Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object dispatch_id -eq $r.dispatch_id)
    Check ($indexed.Count -eq 1 -and $indexed[0].provenance_path -eq ($o.OutputPath+'.provenance.json')) 'ad hoc output outside project is indexed automatically'

    # Import correlated provenance, including ad hoc files outside .dt-build.
    Remove-Item -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl')
    $sources=Join-Path $temp 'sources.json'; ConvertTo-Json -InputObject @($repo) | Set-Content $sources
    Remove-Item -LiteralPath ($base.OutputPath+'.provenance.json')
    $ctx=New-RouterDispatchContext -Project $repo -Category routine-coding -LogicalTaskId 'retry-task' -RequestedModel 'gpt-6.1-sol'
    $first=Join-Path $repo 'first.provenance.json'
    Write-RouterDispatchEvidence $first ([pscustomobject]@{resolved_model='gpt-6.1-sol';effort='medium';failure_category='quality';lane='codex'}) $ctx -ExitCode 0 -ActualModel 'gpt-6.1-sol'
    Set-RouterDispatchAcceptance $first $ctx.dispatch_id $false
    $ctx2=New-RouterDispatchContext -Project (Join-Path $temp 'other-worktree') -Category routine-coding -LogicalTaskId 'retry-task' -Attempt 2 -PriorDispatchId $ctx.dispatch_id
    $second=Join-Path $repo 'second.provenance.json'
    Write-RouterDispatchEvidence $second ([pscustomobject]@{resolved_model='gpt-6.1-sol';effort='high';lane='codex'}) $ctx2 -ExitCode 0 -ActualModel 'gpt-6.1-sol'
    Set-RouterDispatchAcceptance $second $ctx2.dispatch_id $true
    Copy-Item $second (Join-Path $repo 'nested.provenance.json')
    $ctx3=New-RouterDispatchContext -Project $repo -Category mechanical
    Write-RouterDispatchEvidence (Join-Path $repo 'adhoc.provenance.json') ([pscustomobject]@{}) $ctx3 -ExitCode 0
    $ctx4=New-RouterDispatchContext -Project $repo -Category routine-coding
    Write-RouterDispatchEvidence (Join-Path $repo 'bench.provenance.json') ([pscustomobject]@{source='bench'}) $ctx4 -ExitCode 0
    Update-RouterOutcomes -SourcesPath $sources | Out-Null
    $rows=@(Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Check ($rows.Count -eq 4) 'nested provenance deduplicated by dispatch identity'
    $denominator=@($rows | Where-Object {$_.attempt -eq 1 -and $null -ne $_.independent_acceptance -and $_.source -ne 'bench'})
    Check ($denominator.Count -eq 1 -and @($denominator | Where-Object pass).Count -eq 0 -and $denominator[0].retry_count -eq 1) 'first-attempt 0/1 with one retry; unknown and bench excluded'
    Reject { Set-RouterDispatchAcceptance $first 'wrong-id' $true } 'ID_MISMATCH'
    $importAgain = Update-RouterOutcomes -SourcesPath $sources
    Check ($importAgain.total_records -eq 4) 'repeat import retains one row per dispatch'
    "PASS: $checks dispatch checks (fake adapters; no model calls)"
} finally {
    Exit-RouterTestCodexHome $fixture
    $env:DT_MODEL_ROUTER_STATE=$priorState
    Remove-Item -LiteralPath $temp -Recurse -Force
}
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-dispatch-real-wrappers.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Real-wrapper dispatch tests failed' }
& python -m pytest (Join-Path $PSScriptRoot 'test_dispatch_read_guard.py') -n 4 --dist loadfile -q -rs
if ($LASTEXITCODE -ne 0) { throw 'Read-guard smoke failed' }
