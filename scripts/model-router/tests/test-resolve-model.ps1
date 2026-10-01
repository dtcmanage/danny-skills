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
    # Restore real limit functions for fixture-backed integration and CLI tests.
    . (Join-Path $PSScriptRoot '../vendor-limits.ps1')
    $cachePath = Join-Path $temp 'claude-usage.json'
    Write-RouterJsonAtomic -Path $cachePath -Value ([pscustomobject]@{ used_percent=0; resets_at_utc=[datetimeoffset]::UtcNow.AddDays(1).ToString('o'); observed_at_utc=[datetimeoffset]::UtcNow.ToString('o') })
    $blockPath = Join-Path $temp 'vendor-blocks.json'
    $codexReset = [datetimeoffset]::UtcNow.AddHours(4)
    $null = Add-RouterVendorBlock -Vendor codex -ResetAtUtc $codexReset -Reason 'refusal'
    $claudeBlock = Add-RouterVendorBlock -Vendor claude -Reason 'refusal'
    $pick = Resolve-RouterModel -Category routine-coding -Catalog $catalog
    Assert-True ($pick.status -eq 'wait' -and $pick.resume_after_utc -eq $claudeBlock.reset_at_utc -and $pick.resume_after_source -eq 'recheck') 'both blocked wait takes earlier vendor constraint'
    $pick = Resolve-RouterModel -Category routine-coding -Lane codex -Catalog $catalog
    Assert-True ($pick.resume_after_utc -eq $codexReset.ToString('o') -and $pick.resume_after_source -eq 'refusal-reset') 'constrained wait ignores other vendor time'
    Write-RouterJsonAtomic -Path (Join-Path $temp 'drift-marks.json') -Value @([pscustomobject]@{ model='gpt-6.1-sol'; job='coder' })
    $pick = Resolve-RouterModel -Category routine-coding -Lane codex -Catalog $catalog
    Assert-True ($pick.status -eq 'wait' -and $null -eq $pick.resume_after_utc -and $null -eq $pick.resume_after_source -and $null -eq $pick.resume_after_et) 'drift wait has null resume fields even with active block'
    Remove-Item -LiteralPath (Join-Path $temp 'drift-marks.json'),$blockPath
    $pick = Resolve-RouterModel -Category routine-coding -Lane codex -Catalog $noSol
    Assert-True ($pick.status -eq 'wait' -and $null -eq $pick.resume_after_utc -and $null -eq $pick.resume_after_source -and $null -eq $pick.resume_after_et) 'unselectable wait has null resume fields'
    $message = "ERROR: You've hit your usage limit. Try again at $($codexReset.ToString('o'))."
    $pick = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../resolve-model.ps1') -Category routine-coding -AfterRefusal codex -RefusalText $message -Json | ConvertFrom-Json
    $blocks = @(Read-RouterJsonArray -Path $blockPath)
    Assert-True ($blocks.Count -eq 1 -and $blocks[0].vendor -eq 'codex' -and $blocks[0].reason -eq 'refusal' -and [datetimeoffset]$blocks[0].reset_at_utc -eq $codexReset) 'AfterRefusal CLI persists parsed Codex reset'
    Assert-True ($pick.status -eq 'ok' -and $pick.vendor -eq 'claude' -and $pick.vendor_block_recorded.vendor -eq 'codex' -and $pick.vendor_block_recorded.reset_at_utc -eq $blocks[0].reset_at_utc) 'same refusal CLI call returns Claude backup and recorded block'
    Assert-True ($pick.PSObject.Properties['resume_after_utc'] -and $null -eq $pick.resume_after_utc -and $null -eq $pick.resume_after_source -and $null -eq $pick.resume_after_et) 'non-wait has stable null resume keys'
    foreach ($text in @('', 'ordinary output')) {
        $pick = Resolve-RouterModel -Category routine-coding -AfterRefusal codex -RefusalText $text -Catalog $catalog
        $blocks = @(Read-RouterJsonArray -Path $blockPath)
        Assert-True ($blocks[0].resume_after_source -eq 'recheck' -and ([datetimeoffset]$blocks[0].reset_at_utc - [datetimeoffset]$blocks[0].blocked_at_utc).TotalSeconds -eq 3600) "AfterRefusal without parsable reset writes one-hour block ($text)"
    }
    $pick = Resolve-RouterModel -Category routine-coding -AfterRefusal codex -ResetAtUtc $codexReset -Catalog $catalog
    Assert-True ($pick.vendor_block_recorded.reset_at_utc -eq $codexReset.ToString('o')) 'AfterRefusal accepts explicit reset'
    $before = [IO.File]::ReadAllText($blockPath)
    $failed = $false
    try { $null = Resolve-RouterModel -Category routine-coding -AfterRefusal codex -Lane codex -Catalog $catalog } catch { $failed = $_.Exception.Message -like 'AFTER_REFUSAL_LANE_CONFLICT:*' }
    Assert-True ($failed -and [IO.File]::ReadAllText($blockPath) -ceq $before) 'same-vendor lane refusal errors before writing'
    Remove-Item -LiteralPath $blockPath
    $errorPath = Join-Path $temp 'dispatch error.txt'
    $script:diagnoseNow = [datetimeoffset]::UtcNow
    $script:RouterDiagnosisClock = { $script:diagnoseNow }
    $script:diagnoseOffline = $false
    $script:diagnoseDegraded = $false
    $script:diagnoseCalls = 0
    $statusConfig = Read-RouterJsonObject -Path (Join-Path $PSScriptRoot '../../../references/model-router/vendor-status.json')
    $script:RouterDiagnosisDns = { param($ApiHost) -not $script:diagnoseOffline }
    $script:RouterDiagnosisHttp = {
        param($Uri)
        $script:diagnoseCalls++
        if ($script:diagnoseOffline) { throw 'fixture offline' }
        if ($Uri -eq 'http://www.msftconnecttest.com/connecttest.txt') { return 'Microsoft Connect Test' }
        foreach ($vendor in @('codex','claude')) {
            $lane = $statusConfig.$vendor
            if ($Uri -eq $lane.components_url) {
                return [pscustomobject]@{ components=@($lane.components | ForEach-Object {
                    [pscustomobject]@{ id=$_; name=$_; status=$(if ($script:diagnoseDegraded) { 'partial_outage' } else { 'operational' }) }
                }) }
            }
            if ($Uri -eq $lane.incidents_url) {
                return [pscustomobject]@{ incidents=@([pscustomobject]@{ id='fixture-incident'; components=@($lane.components | ForEach-Object { [pscustomobject]@{ id=$_ } }) }) }
            }
        }
        throw "UNEXPECTED_HTTP: $Uri"
    }
    foreach ($vendor in @('codex','claude')) {
        foreach ($file in @('vendor-blocks.json','vendor-status-cache.json')) {
            $path = Join-Path $temp $file
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
        }
        $script:diagnoseCalls = 0
        [IO.File]::WriteAllText($errorPath, "quoted input ' and `"`nERROR: usage limit reached")
        $result = Resolve-RouterModel -Category routine-coding -Diagnose $vendor -ErrorTextPath $errorPath -Catalog $catalog
        Assert-True ($result.verdict -eq 'quota' -and $result.checks.quota -and $script:diagnoseCalls -eq 0) "$vendor diagnose reads multiline quota text from file"
        # The actual script entry point must bind both new aliases and emit JSON.
        $result = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../resolve-model.ps1') -Category routine-coding -Diagnose $vendor -ErrorTextPath $errorPath -Json | ConvertFrom-Json
        Assert-True ($LASTEXITCODE -eq 0 -and $result.verdict -eq 'quota' -and $result.PSObject.Properties['detail'] -and $result.PSObject.Properties['incident_id'] -and $result.PSObject.Properties['checks']) "$vendor diagnose CLI emits diagnosis JSON"
        [IO.File]::WriteAllText($errorPath, "server error`nwith 'quotes' and `"double quotes`"")
        $script:diagnoseOffline = $true
        $result = Resolve-RouterModel -Category routine-coding -Diagnose $vendor -ErrorTextPath $errorPath -Catalog $catalog
        Assert-True ($result.verdict -eq 'offline' -and -not $result.checks.http -and -not $result.checks.dns -and -not $result.PSObject.Properties['model']) "$vendor diagnose offline does not select another vendor"
        $script:diagnoseOffline = $false; $script:diagnoseDegraded = $false
        $result = Resolve-RouterModel -Category routine-coding -Diagnose $vendor -ErrorTextPath $errorPath -Catalog $catalog
        Assert-True ($result.verdict -eq 'unexplained' -and $result.checks.status -eq 'operational' -and -not $result.PSObject.Properties['model']) "$vendor diagnose unexplained does not escalate"
        Remove-Item -LiteralPath (Join-Path $temp 'vendor-status-cache.json')
        $script:diagnoseDegraded = $true
        $backupVendor = if ($vendor -eq 'codex') { 'claude' } else { 'codex' }
        $normal = Resolve-RouterModel -Category routine-coding -Lane $backupVendor -Protected -Catalog $catalog
        $result = Resolve-RouterModel -Category routine-coding -Diagnose $vendor -ErrorTextPath $errorPath -Protected -Catalog $catalog | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        Assert-True ($result.verdict -eq 'vendor_incident' -and $result.incident_id -eq 'fixture-incident' -and $result.checks.status -eq 'non_operational' -and $result.status -eq 'ok' -and $result.vendor -eq $backupVendor) "$vendor diagnose incident returns other-vendor backup with verdict"
        foreach ($name in @('model','agent_alias','effort','category','lane','protected','job','vendor','roster_source','resume_after_utc','resume_after_source','resume_after_et')) {
            Assert-True ($result.PSObject.Properties[$name] -and $result.$name -eq $normal.$name) "$vendor incident backup preserves normal $name"
        }
        $null = Add-RouterVendorBlock -Vendor $backupVendor -Reason vendor_incident -Component $statusConfig.$backupVendor.components[0] -IncidentId 'backup-incident'
        $result = Resolve-RouterModel -Category routine-coding -Diagnose $vendor -ErrorTextPath $errorPath -Catalog $catalog
        Assert-True ($result.verdict -eq 'vendor_incident' -and $result.status -eq 'wait' -and $null -eq $result.model) "$vendor diagnose waits when backup has an incident too"
    }
    $failed = $false
    try { $null = Resolve-RouterModel -Category routine-coding -Diagnose codex -Catalog $catalog } catch { $failed = $_.Exception.Message -like 'DIAGNOSE_ERROR_TEXT_PATH_REQUIRED:*' }
    Assert-True $failed 'diagnose requires an error text file'
    Write-Output "SUMMARY: $script:passed passed"
} finally {
    Exit-RouterTestCodexHome $fixtureCodexHome
    $env:DT_MODEL_ROUTER_STATE = $prior
    Remove-Item -LiteralPath $temp -Recurse -Force
}
