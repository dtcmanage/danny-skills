Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../resolve-model.ps1')

$script:passed = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Output "PASS: $Name"
}
function Reset-State {
    $env:DT_MODEL_ROUTER_STATE = Join-Path $script:temp ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $env:DT_MODEL_ROUTER_STATE | Out-Null
}
$priorState = $env:DT_MODEL_ROUTER_STATE
$script:temp = Join-Path $env:TEMP ('model-check-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$now = [datetime]'2026-09-27T12:00:00Z'
try {
    Reset-State
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6-sol' } else { 'claude-sonnet-4-5' } }
    @{ checked_at = $now.AddHours(-1).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'last-check.json')
    $script:RouterModelCheckFetcher = { param($vendor) throw 'network should not run' }
    $r = Invoke-RouterModelCheck -Now $now
    Assert-True ($r.skipped -and $r.errors.Count -eq 0) 'inside-window skip makes no network call'
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6-sol' } else { 'claude-sonnet-4-5' } }
    $r = Invoke-RouterModelCheck -Now $now -Force
    Assert-True (-not $r.skipped -and $r.new_models.Count -eq 0) 'Force runs and bootstrap reports no new models'
    $registry = @(Get-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'known-models.json') -Raw | ConvertFrom-Json)
    Assert-True ($registry.Count -eq 2 -and -not (Test-Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'pending-research.json'))) 'bootstrap writes registry without research queue'

    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6-sol'; 'gpt-6-new' } else { 'claude-sonnet-4-5' } }
    $r = Invoke-RouterModelCheck -Now $now.AddHours(13)
    $queue = @(Get-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'pending-research.json') -Raw | ConvertFrom-Json)
    Assert-True ($r.new_models -contains 'gpt-6-new' -and $r.alerts -contains 'new-model:gpt-6-new' -and $queue[0].id -eq 'gpt-6-new') 'new model queued and alerted'
    $registry = @(Get-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'known-models.json') -Raw | ConvertFrom-Json)
    Assert-True ((@($registry | Where-Object id -eq 'gpt-6-new')[0]).status -eq 'unprofiled') 'new model remains unprofiled'
    $pick = Resolve-RouterModel -Category routine-coding -Lane claude -SkipModelCheck
    Assert-True ($pick.model -ne 'gpt-6-new' -and $pick.ranked -notcontains 'gpt-6-new') 'unprofiled model is not pickable'

    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6-new' } else { 'claude-sonnet-4-5' } }
    $r = Invoke-RouterModelCheck -Now $now.AddHours(26)
    Assert-True ($r.missing_models -contains 'gpt-6-sol' -and $r.alerts -contains 'model-missing:gpt-6-sol') 'missing model alerted'

    $registryPath = Join-Path $env:DT_MODEL_ROUTER_STATE 'known-models.json'
    $before = [IO.File]::ReadAllText($registryPath)
    $stampBefore = [IO.File]::ReadAllText((Join-Path $env:DT_MODEL_ROUTER_STATE 'last-check.json'))
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { Start-Sleep -Seconds 3 }; 'slow-model' }
    $r = Invoke-RouterModelCheck -Force -Now $now.AddHours(27) -TimeoutSeconds 1
    Assert-True ($r.timed_out -and $r.alerts -contains 'catalog-check-timeout' -and [IO.File]::ReadAllText($registryPath) -ceq $before -and [IO.File]::ReadAllText((Join-Path $env:DT_MODEL_ROUTER_STATE 'last-check.json')) -ceq $stampBefore) 'timeout keeps last-good state and alerts'

    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { throw 'fake failure' }; 'claude-new-1' }
    $r = Invoke-RouterModelCheck -Force -Now $now.AddHours(27)
    Assert-True ($r.errors.Count -eq 1 -and $r.alerts -contains 'catalog-check-error:openai' -and [IO.File]::ReadAllText($registryPath) -ceq $before) 'one vendor failure does not block other fetch or mutate registry'

    $vendorsPath = Join-Path $temp 'unknown-vendors.json'
    @([pscustomobject]@{ id='unknown'; lane='claude'; source='future-source' },[pscustomobject]@{ id='anthropic'; lane='claude'; source='anthropic-models-page'; url='https://example.org' }) | ConvertTo-Json | Set-Content -LiteralPath $vendorsPath
    $script:RouterModelCheckVendorsPath = $vendorsPath
    $script:RouterModelCheckFetcher = { param($vendor) 'claude-sonnet-4-5' }
    $r = Invoke-RouterModelCheck -Force -Now $now.AddHours(27)
    Assert-True ($r.alerts -contains 'catalog-check-error:unknown' -and $r.errors.Count -eq 1) 'unknown source type skipped with alert'
    $script:RouterModelCheckVendorsPath = $null

    $html = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/anthropic-models-live-20260927.html') -Raw
    $ids = @(Get-RouterAnthropicModelIds -Html $html)
    $expected = @('claude-fable-5-1', 'claude-opus-5-5', 'claude-sonnet-5', 'claude-haiku-4-5-20251001') | Sort-Object
    Assert-True (($ids -join ',') -ceq ($expected -join ',')) 'Anthropic parser reads only current Claude API IDs from live fixture'
    $missingTableFailed = $false
    try { Get-RouterAnthropicModelIds -Html '<p>claude-opus-5-5</p>' | Out-Null } catch { $missingTableFailed = $_.Exception.Message -match 'ANTHROPIC_API_ID_TABLE_NOT_FOUND' }
    Assert-True $missingTableFailed 'Anthropic parser errors when API ID table is absent'

    function Invoke-RouterModelCheck { throw 'synthetic check exception' }
    $pick = Resolve-RouterModel -Category routine-coding -Lane claude
    Assert-True ($pick.model -and @($pick.alerts | Where-Object { $_ -match '^catalog-check-error:resolver:' }).Count -eq 1) 'resolver alerts and returns model when check throws'
    Remove-Item Function:Invoke-RouterModelCheck
    . (Join-Path $PSScriptRoot '../check-new-models.ps1')

    Reset-State
    $script:RouterModelCheckFetcher = $null
    Write-Output 'LIVE: real vendor check, read-only upstream'
    $r = Invoke-RouterModelCheck -Force -TimeoutSeconds 30
    $live = @(Get-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'known-models.json') -Raw | ConvertFrom-Json)
    Assert-True (-not $r.timed_out -and $r.errors.Count -eq 0 -and @($live | Where-Object vendor -eq 'openai').Count -gt 0 -and @($live | Where-Object vendor -eq 'anthropic').Count -gt 0) 'LIVE: both vendors return models within 30 seconds'
    Write-Output "SUMMARY: $script:passed passed"
} finally {
    $env:DT_MODEL_ROUTER_STATE = $priorState
    Remove-Item -LiteralPath $temp -Recurse -Force
}
