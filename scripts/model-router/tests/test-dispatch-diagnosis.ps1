Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../vendor-limits.ps1')
. (Join-Path $PSScriptRoot '../resolve-model.ps1')
$script:passed = 0
function Assert-True {
    param([object]$Condition, [string]$Name)
    if (-not [bool]$Condition) { throw "FAIL: $Name" }
    $script:passed++; Write-Output "PASS: $Name"
}
$priorState = $env:DT_MODEL_ROUTER_STATE
$priorHttp = $script:RouterDiagnosisHttp
$priorDns = $script:RouterDiagnosisDns
$priorClock = $script:RouterDiagnosisClock
$temp = Join-Path $env:TEMP ('router-diagnosis-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$env:DT_MODEL_ROUTER_STATE = $temp
$script:fixtureNow = [datetimeoffset]'2026-10-01T12:00:00Z'
$script:RouterDiagnosisClock = { $script:fixtureNow }
$script:RouterDiagnosisDns = {
    param($ApiHost)
    $script:dnsHosts.Add($ApiHost)
    if (-not $script:dnsOk) { throw 'fixture DNS failure' }
    return $true
}
$script:RouterDiagnosisHttp = {
    param($Uri)
    $script:httpCalls.Add($Uri)
    if ($Uri -eq 'http://www.msftconnecttest.com/connecttest.txt') {
        if (-not $script:probeOk) { throw 'fixture probe failure' }
        return 'Microsoft Connect Test'
    }
    if ($Uri -eq $script:expectedComponentsUrl) {
        if (-not $script:statusOk) { throw 'fixture status unreachable' }
        return [pscustomobject]@{ components=$script:components }
    }
    if ($Uri -eq $script:expectedIncidentsUrl) {
        if (-not $script:incidentsOk) { throw 'fixture incidents unreachable' }
        return [pscustomobject]@{ incidents=$script:incidents }
    }
    throw "UNEXPECTED_HTTP: $Uri"
}
# Block checks must never inspect real usage or credentials.
function Get-RouterCodexUsage { return $null }
function Get-RouterClaudeUsage { return $null }
function Reset-Fixture {
    param([string]$Vendor = 'codex')
    foreach ($file in @('vendor-status-cache.json','vendor-status.json','vendor-blocks.json')) {
        $path = Join-Path $temp $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    $script:probeOk = $true; $script:dnsOk = $true; $script:statusOk = $true; $script:incidentsOk = $true
    $script:httpCalls = [Collections.Generic.List[string]]::new()
    $script:dnsHosts = [Collections.Generic.List[string]]::new()
    $config = Read-RouterJsonObject -Path (Join-Path $PSScriptRoot '../../../references/model-router/vendor-status.json')
    $lane = $config.$Vendor
    $script:expectedComponentsUrl = $lane.components_url
    $script:expectedIncidentsUrl = $lane.incidents_url
    $script:components = @($lane.components | ForEach-Object {
        [pscustomobject]@{ id=('id-' + $_); name=$_; status='operational' }
    })
    $script:components += [pscustomobject]@{ id='unrelated'; name='Unrelated service'; status='operational' }
    $script:incidents = @(
        [pscustomobject]@{ id='unrelated-incident'; components=@([pscustomobject]@{ id='unrelated' }) },
        [pscustomobject]@{ id='lane-incident'; components=@([pscustomobject]@{ id=$script:components[0].id }) }
    )
}
function Invoke-Diagnosis { param([string]$Vendor = 'codex') Resolve-RouterDispatchFailure -Vendor $Vendor -ErrorText 'server error' }
try {
    Reset-Fixture
    $result = Resolve-RouterDispatchFailure -Vendor codex -ErrorText 'ERROR: usage limit reached'
    Assert-True ($result.verdict -eq 'quota' -and $script:httpCalls.Count -eq 0 -and $script:dnsHosts.Count -eq 0) 'quota short-circuits network checks'
    $refusal = Test-RouterLimitRefusal -Vendor codex -Text 'ERROR: usage limit reached; try again in 45 minutes'
    Assert-True ([datetimeoffset]$refusal.reset_at_utc -eq $script:fixtureNow.AddMinutes(45)) 'refusal relative time uses injected clock'
    foreach ($vendor in @('codex','claude')) {
        Reset-Fixture $vendor
        $result = Invoke-Diagnosis $vendor
        Assert-True ($result.verdict -eq 'unexplained' -and $result.checks.status -eq 'operational') "$vendor operational fixture"
        $expectedHost = if ($vendor -eq 'codex') { 'api.openai.com' } else { 'api.anthropic.com' }
        Assert-True ($script:dnsHosts[0] -eq $expectedHost -and -not @($script:httpCalls | Where-Object { $_ -like '*/status.json' }).Count) "$vendor uses API DNS and only component status"
        Reset-Fixture $vendor
        $script:components[0].status = 'degraded_performance'
        $result = Invoke-Diagnosis $vendor
        Assert-True ($result.verdict -eq 'vendor_incident' -and $result.incident_id -eq 'lane-incident' -and $result.detail.Contains($script:components[0].name)) "$vendor degraded named component links matching incident"
    }
    Reset-Fixture
    $script:components[-1].status = 'major_outage'
    $result = Invoke-Diagnosis
    Assert-True ($result.verdict -eq 'unexplained' -and $null -eq $result.incident_id -and -not (Test-Path (Join-Path $temp 'vendor-blocks.json'))) 'degraded unrelated component does not create incident'
    Reset-Fixture
    $script:components[0].name = 'Renamed API'
    $result = Invoke-Diagnosis
    Assert-True ($result.verdict -eq 'unexplained' -and $result.detail -like '*Named component not found: Codex API*') 'renamed component names lookup failure'
    Reset-Fixture
    $script:statusOk = $false
    $result = Invoke-Diagnosis
    Assert-True ($result.verdict -eq 'unexplained' -and $result.detail -like '*lookup failed*status unreachable*') 'status unreachable names lookup failure'
    Reset-Fixture
    $script:probeOk = $false
    $result = Invoke-Diagnosis
    Assert-True ($result.verdict -eq 'unexplained' -and -not $result.checks.http -and $result.checks.dns -and $result.checks.status -eq 'operational') 'probe-only failure falls through to status'
    Reset-Fixture
    $script:dnsOk = $false
    $result = Invoke-Diagnosis
    Assert-True ($result.verdict -eq 'unexplained' -and $result.checks.http -and -not $result.checks.dns -and $result.checks.status -eq 'operational') 'DNS-only failure falls through to status'
    Reset-Fixture
    $script:probeOk = $false; $script:dnsOk = $false
    $result = Invoke-Diagnosis
    Assert-True ($result.verdict -eq 'offline' -and $null -eq $result.checks.status -and $script:httpCalls.Count -eq 1) 'both failures are offline without status fetch'
    Reset-Fixture
    $null = Invoke-Diagnosis
    $script:fixtureNow = $script:fixtureNow.AddSeconds(299)
    $script:statusOk = $false
    $result = Invoke-Diagnosis
    Assert-True ($result.verdict -eq 'unexplained' -and $result.checks.cache_hit -and $result.checks.status -eq 'operational' -and @($script:httpCalls | Where-Object { $_ -eq $script:expectedComponentsUrl }).Count -eq 1) 'cache hit within five minutes avoids status HTTP'
    $cache = Read-RouterJsonObject -Path (Join-Path $temp 'vendor-status-cache.json')
    Assert-True ($cache.codex.fetched_at -and $cache.codex.components.'Codex API'.status -eq 'operational') 'persistent cache contains timestamp and component map'
    $script:fixtureNow = $script:fixtureNow.AddSeconds(1)
    $script:statusOk = $true; $script:components[0].status = 'partial_outage'
    $result = Invoke-Diagnosis
    Assert-True ($result.verdict -eq 'vendor_incident' -and -not $result.checks.cache_hit -and @($script:httpCalls | Where-Object { $_ -eq $script:expectedComponentsUrl }).Count -eq 2) 'cache expires at five minutes and refreshes status'
    # A second vendor's reading must preserve the first vendor's cache.
    $claudeConfig = (Read-RouterJsonObject -Path (Join-Path $PSScriptRoot '../../../references/model-router/vendor-status.json')).claude
    $script:expectedComponentsUrl = $claudeConfig.components_url; $script:expectedIncidentsUrl = $claudeConfig.incidents_url
    $script:components = @($claudeConfig.components | ForEach-Object { [pscustomobject]@{ id=$_; name=$_; status='operational' } })
    $null = Invoke-Diagnosis claude
    $cache = Read-RouterJsonObject -Path (Join-Path $temp 'vendor-status-cache.json')
    Assert-True ($cache.PSObject.Properties['codex'] -and $cache.PSObject.Properties['claude']) 'cache keeps separate vendor entries'
    Reset-Fixture
    $null = Invoke-Diagnosis
    $override = [pscustomobject]@{ codex=[pscustomobject]@{ api_host='fixture.api'; components_url='https://fixture/components.json'; incidents_url='https://fixture/incidents/unresolved.json'; components=@('Fixture API') } }
    Write-RouterJsonAtomic -Path (Join-Path $temp 'vendor-status.json') -Value $override
    $script:expectedComponentsUrl = $override.codex.components_url; $script:expectedIncidentsUrl = $override.codex.incidents_url
    $script:components = @([pscustomobject]@{ id='fixture-id'; name='Fixture API'; status='operational' })
    $result = Invoke-Diagnosis
    Assert-True ($result.verdict -eq 'unexplained' -and $result.checks.status -eq 'operational' -and -not $result.checks.cache_hit -and $script:dnsHosts[-1] -eq 'fixture.api' -and $script:httpCalls[-1] -eq $script:expectedComponentsUrl) 'state override wins and invalidates different-endpoint cache'
    Reset-Fixture
    $script:components[0].status = 'major_outage'
    $result = Invoke-Diagnosis
    $blocks = @(Read-RouterJsonArray -Path (Join-Path $temp 'vendor-blocks.json'))
    Assert-True ($blocks.Count -eq 1 -and $blocks[0].reason -eq 'vendor_incident' -and $blocks[0].component -eq 'Codex API' -and $blocks[0].incident_id -eq 'lane-incident' -and -not $blocks[0].PSObject.Properties['reset_at_utc'] -and (Get-RouterVendorBlocked codex)) 'incident record has no reset time and blocks vendor'
    $null = Add-RouterVendorBlock -Vendor codex -Reason quota -ResetAtUtc $script:fixtureNow.AddHours(1)
    $null = Add-RouterVendorBlock -Vendor claude -Reason vendor_incident -Component 'Claude Code' -IncidentId 'claude-incident'
    $null = Invoke-Diagnosis
    $blocks = @(Read-RouterJsonArray -Path (Join-Path $temp 'vendor-blocks.json'))
    Assert-True ($blocks.Count -eq 3 -and @($blocks | Where-Object { $_.reason -eq 'vendor_incident' -and $_.vendor -eq 'codex' }).Count -eq 1) 'quota and other-vendor siblings survive incident refresh without duplicates'
    $script:fixtureNow = $script:fixtureNow.AddMinutes(5)
    $script:components[0].status = 'operational'
    $null = Invoke-Diagnosis
    $blocks = @(Read-RouterJsonArray -Path (Join-Path $temp 'vendor-blocks.json'))
    Assert-True ($blocks.Count -eq 2 -and (Get-RouterVendorBlocked codex) -and (Get-RouterVendorBlocked claude)) 'operational recovery clears only matching incident and retains quota'
    $script:fixtureNow = $script:fixtureNow.AddHours(2)
    Assert-True (-not (Get-RouterVendorBlocked codex) -and (Get-RouterVendorBlocked claude)) 'recovered vendor opens after quota expires while other incident stays blocked'
    Reset-Fixture
    $script:components[0].status = 'partial_outage'; $script:incidentsOk = $false
    $result = Invoke-Diagnosis
    Assert-True ($result.verdict -eq 'unexplained' -and $result.detail -like '*lookup failed*incidents unreachable*') 'failed incident lookup is unexplained'
    $catalog = [pscustomobject]@{ models=@([pscustomobject]@{ slug='gpt-6.1-sol'; visibility='list' }) }
    foreach ($vendor in @('codex','claude')) {
        Reset-Fixture $vendor
        $category = if ($vendor -eq 'codex') { 'routine-coding' } else { 'planning' }
        $backupVendor = if ($vendor -eq 'codex') { 'claude' } else { 'codex' }
        $null = Add-RouterVendorBlock -Vendor $vendor -Reason vendor_incident -Component $script:components[0].name -IncidentId 'lane-incident'
        $result = Resolve-RouterModel -Category $category -Catalog $catalog
        Assert-True ($result.status -eq 'ok' -and $result.vendor -eq $backupVendor -and $result.reason -like '*vendor incident*' -and $script:httpCalls.Count -eq 0 -and $script:dnsHosts.Count -eq 0) "$vendor fresh incident routes normal resolve to backup without checks"
        $script:fixtureNow = $script:fixtureNow.AddSeconds(299)
        $result = Resolve-RouterModel -Category $category -Catalog $catalog
        Assert-True ($result.vendor -eq $backupVendor -and $script:httpCalls.Count -eq 0) "$vendor incident younger than five minutes is not rechecked"
        $script:fixtureNow = $script:fixtureNow.AddSeconds(1)
        $result = Resolve-RouterModel -Category $category -Catalog $catalog
        $blocks = @(Read-RouterJsonArray -Path (Join-Path $temp 'vendor-blocks.json'))
        Assert-True ($result.vendor -eq $vendor -and $blocks.Count -eq 0 -and @($script:httpCalls | Where-Object { $_ -eq $script:expectedComponentsUrl }).Count -eq 1) "$vendor stale incident rechecked and cleared on operational at five minutes"
        $count = $script:httpCalls.Count
        $null = Resolve-RouterModel -Category $category -Catalog $catalog
        Assert-True ($script:httpCalls.Count -eq $count) "$vendor recovered normal resolve does not poll status"
    }
    Reset-Fixture
    $script:components[0].status = 'partial_outage'
    $null = Invoke-Diagnosis
    $script:fixtureNow = $script:fixtureNow.AddMinutes(5)
    $result = Resolve-RouterModel -Category routine-coding -Catalog $catalog
    $blocks = @(Read-RouterJsonArray -Path (Join-Path $temp 'vendor-blocks.json'))
    Assert-True ($result.vendor -eq 'claude' -and $blocks.Count -eq 1 -and [datetimeoffset]$blocks[0].blocked_at_utc -eq $script:fixtureNow) 'stale degraded incident refreshes its record and retains backup routing'
    $count = $script:httpCalls.Count
    $null = Resolve-RouterModel -Category routine-coding -Catalog $catalog
    Assert-True ($script:httpCalls.Count -eq $count) 'refreshed incident is not rechecked on the next dispatch'
    $script:fixtureNow = $script:fixtureNow.AddMinutes(5)
    $script:statusOk = $false
    $result = Resolve-RouterModel -Category routine-coding -Catalog $catalog
    Assert-True ($result.vendor -eq 'claude' -and (Get-RouterVendorBlocked codex)) 'failed stale component recheck keeps incident blocked'
    Reset-Fixture
    $null = Add-RouterVendorBlock -Vendor codex -Reason vendor_incident -Component $script:components[0].name -IncidentId 'lane-incident'
    $null = Add-RouterVendorBlock -Vendor codex -Reason quota -ResetAtUtc $script:fixtureNow.AddHours(1)
    $script:fixtureNow = $script:fixtureNow.AddMinutes(5)
    $result = Resolve-RouterModel -Category routine-coding -Catalog $catalog
    $blocks = @(Read-RouterJsonArray -Path (Join-Path $temp 'vendor-blocks.json'))
    Assert-True ($result.vendor -eq 'claude' -and $blocks.Count -eq 1 -and $blocks[0].reason -eq 'quota') 'resolver recovery clears incident while honoring quota sibling'
    Write-Output "SUMMARY: $script:passed passed"
} catch {
    Write-Output $_
    Write-Output "SUMMARY: $script:passed passed, 1 failed"
    exit 1
} finally {
    $env:DT_MODEL_ROUTER_STATE = $priorState
    $script:RouterDiagnosisHttp = $priorHttp; $script:RouterDiagnosisDns = $priorDns; $script:RouterDiagnosisClock = $priorClock
    if ([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath($env:TEMP) + [IO.Path]::DirectorySeparatorChar)) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
