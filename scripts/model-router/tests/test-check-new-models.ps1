Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../resolve-model.ps1')
. (Join-Path $PSScriptRoot '../check-new-models.ps1')

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
$priorTransport = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
$transportPath = Join-Path $temp 'fake-alert-transport.ps1'
Set-Content -LiteralPath $transportPath -Value @'
param($request)
if ($request['kind'] -eq 'secret') { return 'fake-secret' }
if ([string]$request['uri'] -like '*/oauth2/applications/@me') { return [pscustomobject]@{ owner = [pscustomobject]@{ id = '1' } } }
if ([string]$request['uri'] -like '*/users/@me/channels') { return [pscustomobject]@{ id = 'dm' } }
return [pscustomobject]@{ id = 'fake-message' }
'@
$env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $transportPath
$now = [datetime]'2026-09-27T12:00:00Z'
$priorClaudeCredentials = $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS
$env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = Join-Path $temp 'missing-claude-credentials.json'

try {
    $script:RouterDiagnosisHttp = { param($Uri) 'fixture connected' }
    $script:RouterDiagnosisDns = { param($ApiHost) $true }
    $script:canaryLaunchCount = 0
    function Invoke-RouterTriggeredComparison { param($Request,$Trigger,$BenchInvoker) $script:canaryLaunchCount++; [pscustomobject]@{effort_down_qualified=$false;raw_gate='pass'} }
    Reset-State
    $script:launchCount = 0
    $script:RouterResearchLauncher = { param($exe,$arguments)
        $script:launchCount++
        $tokenIndex = [array]::IndexOf($arguments,'-LockToken')
        [void](Update-RouterLockOwned -Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'research.lock') -Token $arguments[$tokenIndex + 1] -Action take)
    }
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6-sol' } else { 'claude-sonnet-4-5' } }
    @{ checked_at = $now.AddHours(-1).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'last-check.json')
    $script:RouterModelCheckFetcher = { param($vendor) throw 'network should not run' }
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Now $now
    Assert-True ($r.skipped -and $r.errors.Count -eq 0) 'inside-window skip makes no network call'
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6-sol' } else { 'claude-sonnet-4-5' } }
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Now $now -Force
    Assert-True (-not $r.skipped -and $r.new_models.Count -eq 0) 'Force runs and bootstrap reports no new models'
    $registry = @(Get-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'known-models.json') -Raw | ConvertFrom-Json)
    Assert-True ($registry.Count -eq 2 -and -not (Test-Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'research-queue.json'))) 'bootstrap writes registry without research queue'


    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6-sol'; 'gpt-6-new' } else { 'claude-sonnet-4-5' } }
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Now $now.AddHours(13)
    $queue = @(Get-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'research-queue.json') -Raw | ConvertFrom-Json)
    Assert-True ($r.new_models -contains 'gpt-6-new' -and $r.alerts -contains 'new-model:gpt-6-new' -and @($queue | Where-Object { $_.model -eq 'gpt-6-new' -and $_.trigger -eq 'release' }).Count -eq 1) 'new model queued and alerted'
    Assert-True ($script:launchCount -eq 0 -and @($queue | Where-Object trigger -eq 'confirmation').Count -eq 1) 'new queue waits for offline cadence and includes confirmation'
    Assert-True ($script:canaryLaunchCount -gt 0) 'new models run job-scoped bench comparisons'
    $registry = @(Get-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'known-models.json') -Raw | ConvertFrom-Json)
    Assert-True ((@($registry | Where-Object id -eq 'gpt-6-new')[0]).status -eq 'unprofiled') 'new model remains unprofiled'
    $pick = Resolve-RouterModel -Category routine-coding -Lane claude -SkipModelCheck
    Assert-True ($pick.model -ne 'gpt-6-new' -and $pick.ranked -notcontains 'gpt-6-new') 'unprofiled model is not pickable'

    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6-new' } else { 'claude-sonnet-4-5' } }
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Now $now.AddHours(26)
    Assert-True ($r.missing_models -contains 'gpt-6-sol' -and $r.alerts -contains 'model-missing:gpt-6-sol') 'missing model alerted'
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Now $now.AddHours(39)
    Assert-True ($r.new_models.Count -eq 0 -and $script:launchCount -eq 0) 'model check leaves research to offline cadence'
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Force -Now $now.AddHours(40)
    Assert-True ($script:launchCount -eq 0) 'model check never launches research'

    $registryPath = Join-Path $env:DT_MODEL_ROUTER_STATE 'known-models.json'
    $before = [IO.File]::ReadAllText($registryPath)
    $stampBefore = [IO.File]::ReadAllText((Join-Path $env:DT_MODEL_ROUTER_STATE 'last-check.json'))
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { Start-Sleep -Seconds 3 }; 'slow-model' }
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Force -Now $now.AddHours(27) -TimeoutSeconds 1
    Assert-True ($r.timed_out -and $r.alerts -contains 'catalog-check-timeout' -and [IO.File]::ReadAllText($registryPath) -ceq $before -and [IO.File]::ReadAllText((Join-Path $env:DT_MODEL_ROUTER_STATE 'last-check.json')) -ceq $stampBefore) 'timeout keeps last-good state and alerts'

    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { throw 'fake failure' }; 'claude-new-1' }
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Force -Now $now.AddHours(27)
    Assert-True ($r.errors.Count -eq 1 -and $r.alerts -contains 'catalog-check-error:openai' -and [IO.File]::ReadAllText($registryPath) -ceq $before) 'one vendor failure does not block other fetch or mutate registry'

    $script:RouterDiagnosisHttp = { param($Uri) throw 'offline fixture' }
    $script:RouterDiagnosisDns = { param($ApiHost) $false }
    $script:RouterModelCheckFetcher = { param($vendor) throw 'fetch must not run offline' }
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Force -Now $now.AddHours(27)
    Assert-True ($r.offline -and $r.skipped -and $r.errors.Count -eq 0 -and $r.alerts.Count -eq 0 -and [IO.File]::ReadAllText($registryPath) -ceq $before -and [IO.File]::ReadAllText((Join-Path $env:DT_MODEL_ROUTER_STATE 'last-check.json')) -ceq $stampBefore) 'offline catalog check raises no catalog-check-error and preserves last-good state'
    $script:RouterDiagnosisDns = { param($ApiHost) $true }
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { throw 'fixture failure online by DNS' }; 'claude-new-1' }
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Force -Now $now.AddHours(27)
    Assert-True (-not $r.offline -and $r.alerts -contains 'catalog-check-error:openai') 'HTTP probe failure alone does not suppress catalog errors'
    $script:RouterDiagnosisHttp = { param($Uri) 'fixture connected' }
    $script:RouterDiagnosisDns = { param($ApiHost) $false }
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Force -Now $now.AddHours(27)
    Assert-True (-not $r.offline -and $r.alerts -contains 'catalog-check-error:openai') 'DNS probe failure alone does not suppress catalog errors'
    $script:RouterDiagnosisDns = { param($ApiHost) $true }

    $vendorsPath = Join-Path $temp 'unknown-vendors.json'
    @([pscustomobject]@{ id='unknown'; lane='claude'; source='future-source' },[pscustomobject]@{ id='anthropic'; lane='claude'; source='anthropic-models-page'; url='https://example.org' }) | ConvertTo-Json | Set-Content -LiteralPath $vendorsPath
    $script:RouterModelCheckVendorsPath = $vendorsPath
    $script:RouterModelCheckFetcher = { param($vendor) 'claude-sonnet-4-5' }
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Force -Now $now.AddHours(27)
    Assert-True ($r.alerts -contains 'catalog-check-error:unknown' -and $r.errors.Count -eq 1) 'unknown source type skipped with alert'
    $script:RouterModelCheckVendorsPath = $null

    Reset-State
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6-sol' } else { 'claude-sonnet-4-5' } }
    [void](Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Force -Now $now)
    $queuePath = Join-Path $env:DT_MODEL_ROUTER_STATE 'research-queue.json'
    [IO.File]::WriteAllText($queuePath,'')
    $registryPath = Join-Path $env:DT_MODEL_ROUTER_STATE 'known-models.json'
    $registryBefore = [IO.File]::ReadAllText($registryPath)
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6-sol'; 'gpt-6-queued' } else { 'claude-sonnet-4-5' } }
    $holder = [IO.FileStream]::new((Join-Path $env:DT_MODEL_ROUTER_STATE 'pending-research.mutex'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $PSDefaultParameterValues['Use-RouterQueueMutex:TimeoutMs'] = 200
    $mutexBlocked = $false
    try { [void](Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Force -Now $now) } catch { $mutexBlocked = $_.Exception.Message -match 'ROUTER_QUEUE_MUTEX_TIMEOUT' }
    $holder.Dispose()
    $PSDefaultParameterValues.Remove('Use-RouterQueueMutex:TimeoutMs')
    Assert-True ($mutexBlocked -and [IO.File]::ReadAllText($registryPath) -ceq $registryBefore -and [IO.File]::ReadAllText($queuePath) -eq '') 'queue write waits on the shared queue mutex and loses nothing when blocked'
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Force -Now $now
    $queue = @(Read-RouterJsonArray -Path $queuePath)
    Assert-True ($r.new_models -contains 'gpt-6-queued' -and $queue.Count -eq 2 -and @($queue | Where-Object { $_.model -eq 'gpt-6-queued' -and $_.trigger -eq 'release' }).Count -eq 1) 'empty queue file treated as empty queue when new model is queued'

    $html = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/anthropic-models-live-20260927.html') -Raw
    $ids = @(Get-RouterAnthropicModelIds -Html $html)
    $expected = @('claude-fable-5-1', 'claude-opus-5-5', 'claude-sonnet-5', 'claude-haiku-4-5-20251001') | Sort-Object
    Assert-True (($ids -join ',') -ceq ($expected -join ',')) 'Anthropic parser reads only current Claude API IDs from live fixture'
    $missingTableFailed = $false
    try { Get-RouterAnthropicModelIds -Html '<p>claude-opus-5-5</p>' | Out-Null } catch { $missingTableFailed = $_.Exception.Message -match 'ANTHROPIC_API_ID_TABLE_NOT_FOUND' }
    Assert-True $missingTableFailed 'Anthropic parser errors when API ID table is absent'

    function Invoke-RouterModelCheck { throw 'synthetic check exception' }
    $pick = Resolve-RouterModel -Category routine-coding -Lane claude
    Assert-True ($pick.model -and @($pick.alerts | Where-Object { $_ -match '^catalog-check-error:resolver:' }).Count -eq 0) 'resolver makes no model check call'
    Remove-Item Function:Invoke-RouterModelCheck
    . (Join-Path $PSScriptRoot '../check-new-models.ps1')

    # --- M04 remediation regressions: tolerant reads of known-models.json / last-check.json ---
    Reset-State
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6-sol' } else { 'claude-sonnet-4-5' } }
    [void](Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Force -Now $now)
    $registryPath = Join-Path $env:DT_MODEL_ROUTER_STATE 'known-models.json'
    [IO.File]::WriteAllText($registryPath, '')
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Force -Now $now.AddHours(1)
    Assert-True ($r.alerts -contains 'known-models-reset' -and -not $r.timed_out -and $r.errors.Count -eq 0) '0-byte registry treated as absent with reset alert instead of throwing'
    $registry = @(Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json)
    Assert-True ($registry.Count -eq 2) '0-byte registry rebuilt from current listing on bootstrap path'

    [IO.File]::WriteAllText($registryPath, '{not valid json')
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Force -Now $now.AddHours(2)
    Assert-True ($r.alerts -contains 'known-models-reset' -and $r.errors.Count -eq 0) 'corrupt registry treated as absent with reset alert instead of throwing'
    $registry = @(Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json)
    Assert-True ($registry.Count -eq 2) 'corrupt registry rebuilt from current listing on bootstrap path'

    $stampPath = Join-Path $env:DT_MODEL_ROUTER_STATE 'last-check.json'
    [IO.File]::WriteAllText($stampPath, '{not valid json')
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Now $now.AddHours(3)
    Assert-True (-not $r.skipped -and $r.errors.Count -eq 0) 'corrupt last-check.json treated as absent; check runs instead of throwing'

    Reset-State
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6-sol' } else { 'claude-sonnet-4-5' } }
    $r = Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Force -TimeoutSeconds 30
    $live = @(Get-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'known-models.json') -Raw | ConvertFrom-Json)
    Assert-True (-not $r.timed_out -and $r.errors.Count -eq 0 -and @($live | Where-Object vendor -eq 'openai').Count -gt 0 -and @($live | Where-Object vendor -eq 'anthropic').Count -gt 0) 'both vendor fixtures return models within 30 seconds without network'

    Reset-State
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6-sol' } else { 'claude-sonnet-4-5' } }
    [void](Invoke-RouterModelCheck -BenchInvoker { param($r) $script:canaryLaunchCount++; [pscustomobject]@{gate='pass';raw_gate='pass';effort_down_qualified=$false} } -Force)
    $cachePath = Join-Path $temp 'models.json'
    @{ models = @(@{ slug = 'gpt-6-sol'; visibility = 'list'; priority = 1 }, @{ slug = 'gpt-6-luna'; visibility = 'list'; priority = 2 }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cachePath
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6-sol'; 'gpt-6-new' } else { 'claude-sonnet-4-5' } }
    @{ checked_at = (Get-Date).AddHours(-13).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'last-check.json')
    try {
        [void](Resolve-CodexModel -Category mechanical -CachePath $cachePath -Strict)
        [void](Resolve-CodexModel -Category mechanical -CachePath $cachePath -Strict)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'research-queue.json'))) 'Resolve-CodexModel lookup does not check for releases'
    } finally { $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $transportPath }
    Write-Output "SUMMARY: $script:passed passed"
} finally {
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = $priorClaudeCredentials
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorTransport
    $env:DT_MODEL_ROUTER_STATE = $priorState
    Remove-Item -LiteralPath $temp -Recurse -Force
}
