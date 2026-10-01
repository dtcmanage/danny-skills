Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../resolve-model.ps1')
$script:passed = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Output "PASS: $Name"
}
function Get-RouterVendorBlocked([string]$Vendor) { return ($script:blocked -contains $Vendor) }
$prior = $env:DT_MODEL_ROUTER_STATE
$temp = Join-Path $env:TEMP ('model-router-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$env:DT_MODEL_ROUTER_STATE = $temp
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixtureCodexHome = Enter-RouterTestCodexHome
$script:blocked = @()
try {
    $catalog = Get-CodexModelCatalog
    Assert-True ((Get-RouterModelGeneration 'gpt-6.1-sol').major -gt (Get-RouterModelGeneration 'gpt-5.6-sol').major) 'GPT major generation order'
    Assert-True ((Get-RouterModelGeneration 'gpt-5.6-sol').minor -gt (Get-RouterModelGeneration 'gpt-5.5').minor) 'GPT minor generation order'
    Assert-True ((Get-RouterModelGeneration 'claude-opus-5-5').major -gt (Get-RouterModelGeneration 'claude-haiku-4-5-20251001').major) 'Claude generation order'
    Assert-True ((Get-RouterModelGeneration 'claude-sonnet-5').minor -eq 0 -and (Get-RouterModelGeneration 'claude-sonnet-5').major -eq 5) 'Claude major-only generation is 5.0'
    Assert-True ((Get-RouterModelGeneration 'claude-sonnet-5-20251001').minor -eq 0) 'Claude major-only date-suffixed generation is 5.0'
    Assert-True ((Get-RouterModelGeneration 'claude-opus-5-5').minor -eq 5 -and (Get-RouterModelGeneration 'claude-haiku-4-5-20251001').minor -eq 5) 'Claude minor and date-suffixed generations parse'
    foreach ($category in @('routine-coding','code-review','ui-frontend','deep-research')) {
        $pick = Resolve-RouterModel -Category $category -Lane claude -SkipModelCheck -Catalog $catalog
        Assert-True ($pick.model -eq 'claude-opus-5-5' -and $pick.roster_source -eq 'default' -and $pick.alerts -contains 'router-roster-missing') "missing roster default $category"
        Assert-True ($pick.effort -ceq (Get-RouterJobEffort -Job (Get-RouterCategoryJob -Category $category))) "default effort $category"
    }
    Assert-True ((Get-RouterAlertMessage 'router-roster-missing') -eq 'Model router roster is missing; it is using the default roster.') 'missing roster alert message'
    $rosterPath = Join-Path $temp 'roster.json'
    Set-Content -LiteralPath $rosterPath -Value '{ invalid json'
    $pick = Resolve-RouterModel -Category planning -Catalog $catalog
    Assert-True ($pick.model -eq 'claude-opus-5-5' -and $pick.roster_source -eq 'default' -and $pick.validation_error -like 'ROSTER_PARSE:*' -and $pick.alerts -contains "router-roster-invalid: $($pick.validation_error)") 'invalid roster defaults and alerts'
    Assert-True ((Get-RouterAlertMessage 'router-roster-invalid: fixture error') -eq 'Model router roster is invalid (fixture error); it is using the default roster.') 'invalid roster alert message'
    $roster = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 20
    $roster | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $rosterPath
    Assert-True ((Resolve-RouterModel -Category planning -Catalog $catalog).alerts -contains 'router-roster-invalid: ROSTER_NOT_APPROVED: roster is not approved') 'unapproved roster defaults and alerts'
    $roster.approved = $true; $roster.approved_at = '2026-09-30T20:29:20Z'
    $roster | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $rosterPath
    $expected = @{
        mechanical = @('gpt-6-luna','claude-haiku-4-5-20251001')
        'routine-coding' = @('gpt-6.1-sol','claude-opus-5-5')
        'complex-coding' = @('gpt-6.1-sol','claude-opus-5-5')
        'ui-frontend' = @('gpt-6.1-sol','claude-opus-5-5')
        'code-review' = @('gpt-6.1-sol','claude-opus-5-5')
        planning = @('gpt-6.1-sol','claude-opus-5-5')
        'deep-research' = @('gpt-6.1-sol','claude-opus-5-5')
        math = @('gpt-6.1-sol','claude-opus-5-5')
        analysis = @('gpt-6.1-sol','claude-opus-5-5')
        'long-form-writing' = @('gpt-6.1-sol','claude-opus-5-5')
        'image-generation' = @('gpt-image-2',$null)
    }
    foreach ($category in @(Get-RouterDispatchCategories)) {
        foreach ($lane in @('codex','claude')) {
            $want = $expected[$category][$(if ($lane -eq 'codex') { 0 } else { 1 })]
            $pick = Resolve-RouterModel -Category $category -Lane $lane -SkipModelCheck -Catalog $catalog
            Assert-True ($pick.model -eq $want -and $pick.roster_source -eq 'state' -and $pick.status -eq $(if ($want) { 'ok' } else { 'wait' })) "state pick $category/$lane"
            Assert-True ($pick.PSObject.Properties['effort'] -and $pick.effort -ceq $(if ($want) { Get-RouterJobEffort -Job (Get-RouterCategoryJob -Category $category) } else { $null })) "state effort $category/$lane"
        }
    }
    $snapshot = @(Get-RouterPicksSnapshot)
    Assert-True (@($snapshot | Where-Object { -not $_.PSObject.Properties['effort'] }).Count -eq 0) 'snapshot carries effort'
    Assert-True ($snapshot.Count -eq 42 -and @($snapshot | Where-Object { -not $_.lane }).Count -eq 0 -and @($snapshot | Where-Object { $_.category -in @('math','analysis') }).Count -eq 8) 'snapshot includes math and analysis in 42 rows'
    Assert-True ((Resolve-RouterModel -Category mechanical -Lane codex -Protected -Catalog $catalog).model -eq 'gpt-6.1-sol') 'protected mechanical uses coder'
    Assert-True ((Resolve-RouterModel -Category long-form-writing -Catalog $catalog).protected) 'writing always protected'
    foreach ($step in @(@('codex','gpt-6-luna','gpt-6.1-sol'),@('claude','claude-haiku-4-5-20251001','claude-sonnet-5'),@('claude','claude-sonnet-5','claude-opus-5-5'))) {
        $pick = Resolve-RouterModel -Category routine-coding -Lane $step[0] -EscalateFrom $step[1] -Catalog $catalog
        Assert-True ($pick.model -eq $step[2] -and $pick.reason -match 'one rung up') "ladder step $($step[1])"
    }
    foreach ($step in @(@('haiku','claude-sonnet-5'),@('sonnet','claude-opus-5-5'),@('sonnet[1m]','claude-opus-5-5'),@('opus','claude-opus-5-5'))) {
        Assert-True ((Resolve-RouterModel -Category routine-coding -Lane claude -EscalateFrom $step[0] -Catalog $catalog).model -eq $step[1]) "alias escalation $($step[0])"
    }
    foreach ($top in @(@('codex','gpt-6.1-sol'),@('claude','claude-opus-5-5'))) {
        $pick = Resolve-RouterModel -Category routine-coding -Lane $top[0] -EscalateFrom $top[1] -Catalog $catalog
        Assert-True ($pick.model -eq $top[1] -and $pick.reason -match 'already at the top') "ladder ceiling $($top[0])"
    }
    $noSol = [pscustomobject]@{ models = @([pscustomobject]@{slug='gpt-6-luna';visibility='list'}) }
    $pick = Resolve-RouterModel -Category routine-coding -Catalog $noSol
    Assert-True ($pick.model -eq 'claude-opus-5-5' -and $pick.alerts -contains 'roster-model-unselectable:gpt-6.1-sol') 'unselectable first uses backup and alerts'
    $pick = Resolve-RouterModel -Category routine-coding -Lane codex -Catalog $noSol
    Assert-True ($pick.status -eq 'wait' -and $pick.alerts -contains 'roster-model-unselectable:gpt-6.1-sol') 'unselectable constrained lane waits'
    $script:blocked = @('claude')
    Assert-True ((Resolve-RouterModel -Category planning -Catalog $noSol).status -eq 'wait') 'unselectable backup waits when first vendor blocked'
    $script:blocked = @('codex')
    Assert-True ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).model -eq 'claude-opus-5-5') 'blocked first vendor uses backup'
    Assert-True ((Resolve-RouterModel -Category routine-coding -Lane codex -Catalog $catalog).status -eq 'wait') 'blocked constrained vendor waits'
    $script:blocked = @('codex','claude')
    $pick = Resolve-RouterModel -Category planning -Catalog $catalog
    Assert-True ($pick.status -eq 'wait' -and $null -eq $pick.model) 'both vendors blocked waits'
    $script:blocked = @()
    $a = Resolve-RouterModel -Category routine-coding -Catalog $catalog | ConvertTo-Json -Depth 12 -Compress
    $b = Resolve-RouterModel -Category routine-coding -Catalog $catalog | ConvertTo-Json -Depth 12 -Compress
    Assert-True ($a -ceq $b) 'identical input produces identical JSON'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $temp 'alert-log.jsonl'))) 'alerts are not delivered without SendAlerts'
    Write-Output "SUMMARY: $script:passed passed"
} finally {
    Exit-RouterTestCodexHome $fixtureCodexHome
    $env:DT_MODEL_ROUTER_STATE = $prior
    Remove-Item -LiteralPath $temp -Recurse -Force
}
