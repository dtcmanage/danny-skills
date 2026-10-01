Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../resolve-model.ps1')
$script:passed = 0
function Assert-True { param([object]$Condition,[string]$Name) if (-not [bool]$Condition) { throw "FAIL: $Name" }; $script:passed++; Write-Output "PASS: $Name" }
function Copy-Roster { return (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 20) }
function Save-Roster { param([object]$Roster) $Roster | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json') }
function Get-RosterErrors { param([object]$Roster) return @(Test-RouterRoster -Roster $Roster) }
function Get-RouterVendorBlocked { param([string]$Vendor) return ($script:blocked -contains $Vendor) }
$prior = $env:DT_MODEL_ROUTER_STATE
$priorTransport = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
$temp = Join-Path $env:TEMP ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$env:DT_MODEL_ROUTER_STATE = $temp
$fakeScript = Join-Path $temp 'fake-transport.ps1'
Set-Content -LiteralPath $fakeScript -Value @'
param($request)
if ($request['kind'] -eq 'secret') { return 'fake-secret' }
if ($request['uri'] -like '*/oauth2/applications/@me') { return [pscustomobject]@{ owner = [pscustomobject]@{ id = '123456789' } } }
if ($request['uri'] -like '*/users/@me/channels') { return [pscustomobject]@{ id = 'dm-channel' } }
if ($request['uri'] -like '*/messages' -and $request['body'] -like '*roster*') { Add-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'fake-deliveries.log') -Value ([string]$request['body']) }
return [pscustomobject]@{ id = 'fake-message' }
'@
$env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $fakeScript
$script:blocked = @()
$catalog = [pscustomobject]@{ models=@([pscustomobject]@{slug='gpt-6.1-sol';visibility='list'},[pscustomobject]@{slug='gpt-6-luna';visibility='list'}) }
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixtureCodexHome = Enter-RouterTestCodexHome
try {
    $r = Copy-Roster
    Assert-True (@(Get-RosterErrors $r).Count -eq 0) 'seed validates'
    foreach ($job in @(Get-RouterJobs)) {
        Assert-True ($r.jobs.$job.first_effort -ceq (Get-RouterJobEffort -Job $job) -and $r.jobs.$job.backup_effort -ceq (Get-RouterJobEffort -Job $job)) "fixed effort $job"
        foreach ($slot in @('first','backup')) {
            $bad = Copy-Roster; $bad.jobs.$job.PSObject.Properties.Remove("${slot}_effort")
            Assert-True ((Get-RosterErrors $bad) -ceq "ROSTER_EFFORT: $job/$slot") "missing effort $job/$slot"
            foreach ($value in @('max','xhigh','ultra','LOW',1,$null)) {
                if ($job -eq 'illustrator' -and $null -eq $value) { continue }
                $bad = Copy-Roster; $bad.jobs.$job."${slot}_effort" = $value
                $errorText = if ($job -eq 'illustrator') { 'ROSTER_EFFORT_ILLUSTRATOR: must be null' } else { "ROSTER_EFFORT: $job/$slot" }
                Assert-True ((Get-RosterErrors $bad) -ceq $errorText) "invalid effort $job/$slot/$value"
            }
        }
    }
    $legacy = Copy-Roster
    foreach ($job in @(Get-RouterJobs)) { foreach ($slot in @('first','backup')) { $legacy.jobs.$job.PSObject.Properties.Remove("${slot}_effort") } }
    Assert-True (@(Get-RosterErrors $legacy).Count -eq 10 -and @(Get-RosterErrors $legacy | Where-Object { $_ -notlike 'ROSTER_EFFORT: *' }).Count -eq 0) 'legacy roster fails with plain effort messages'
    $r.schema_version = 2; Assert-True ((Get-RosterErrors $r) -eq 'ROSTER_SCHEMA_VERSION: expected integer 1') 'schema version rule'; $r = Copy-Roster
    $r.generated_at = 'bad'; Assert-True ((Get-RosterErrors $r) -eq 'ROSTER_GENERATED_AT: expected ISO date') 'generated date rule'; $r = Copy-Roster
    $r.approved = 'yes'; Assert-True ((Get-RosterErrors $r) -eq 'ROSTER_APPROVED: expected Boolean') 'approval type rule'; $r = Copy-Roster
    $r.approved = $true; Assert-True ((Get-RosterErrors $r) -eq 'ROSTER_APPROVED_AT: approved roster needs date') 'approval date rule'; $r = Copy-Roster
    $r.category_jobs.mechanical = 'coder'; Assert-True ((Get-RosterErrors $r) -eq 'ROSTER_CATEGORY_JOB: mechanical') 'category map rule'; $r = Copy-Roster
    $r.jobs.PSObject.Properties.Remove('writer'); Assert-True ((Get-RosterErrors $r) -eq 'ROSTER_JOB: missing or invalid writer') 'every job rule'; $r = Copy-Roster
    $r.jobs.coder.PSObject.Properties.Remove('first_vendor'); Assert-True ((Get-RosterErrors $r) -eq 'ROSTER_JOB_FIELD: coder/first_vendor') 'job field rule'; $r = Copy-Roster
    $r.jobs.fast.backup_vendor = 'codex'; Assert-True ((Get-RosterErrors $r) -eq 'ROSTER_VENDOR_PAIR: fast') 'different vendors rule'; $r = Copy-Roster
    $r.jobs.fast.backup = $null; Assert-True ((Get-RosterErrors $r) -eq 'ROSTER_BACKUP: fast') 'backup required rule'; $r = Copy-Roster
    $r.jobs.illustrator.backup = 'claude-opus-5-5'; Assert-True ((Get-RosterErrors $r) -eq 'ROSTER_ILLUSTRATOR_BACKUP: must be null') 'illustrator null rule'; $r = Copy-Roster
    $r.jobs.coder.first = 'gpt-6-astra'; Assert-True ((Get-RosterErrors $r) -eq 'ROSTER_FRONTIER: coder/first') 'frontier rule'; $r = Copy-Roster
    $r.jobs.fast.first_vendor = 'claude'; Assert-True ((Get-RosterErrors $r) -eq 'ROSTER_MODEL_VENDOR: fast/first') 'model vendor rule'; $r = Copy-Roster
    $r.jobs.fast.backup = 'claude-sonnet-5'; $r.jobs.writer.backup = 'gpt-5.6-sol'; Assert-True ((Get-RosterErrors $r) -eq 'ROSTER_MODEL_CAP: maximum 5 distinct models') 'five distinct models rule'
    Assert-True ((Read-RouterRoster).source -eq 'default') 'default source when state missing'
    $r = Copy-Roster; $r.approved = $true; $r.approved_at = '2026-09-28T01:00:00Z'; Save-Roster $r
    Assert-True ((Read-RouterRoster).source -eq 'state') 'approved state source'
    $invalid = Copy-Roster; $invalid.jobs.coder.first = 'gpt-6-astra'; Save-Roster $invalid
    $read = Read-RouterRoster
    Assert-True ($read.source -eq 'default' -and $read.validation_error -match 'ROSTER_FRONTIER') 'invalid state falls back with validation error'
    $deliveryLog = Join-Path $temp 'fake-deliveries.log'
    $invalidPick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex -Catalog $catalog
    Assert-True ($invalidPick.validation_error -match 'ROSTER_FRONTIER' -and @($invalidPick.alerts | Where-Object { $_ -like 'router-roster-invalid:*' }).Count -eq 1) 'result records invalid roster alert'
    Assert-True (-not (Test-Path -LiteralPath $deliveryLog)) 'roster alert is not delivered without SendAlerts'
    $null = Resolve-RouterModel -SkipModelCheck -SendAlerts -Category complex-coding -Lane codex -Catalog $catalog
    Assert-True ((Test-Path -LiteralPath $deliveryLog) -and @(Get-Content -LiteralPath $deliveryLog).Count -eq 1) 'roster alert delivered once with SendAlerts'
    Save-Roster $r
    foreach ($category in $r.category_jobs.PSObject.Properties.Name) {
        $pick = Resolve-RouterModel -SkipModelCheck -Category $category -Catalog $catalog
        Assert-True ($pick.job -eq $r.category_jobs.$category -and $pick.roster_source -eq 'state') "category job $category"
    }
    $codex = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex -Catalog $catalog
    $claude = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane claude -Catalog $catalog
    Assert-True ($codex.model -eq 'gpt-6.1-sol' -and $codex.vendor -eq 'codex' -and $claude.model -eq 'claude-opus-5-5' -and $claude.agent_alias -eq 'opus') 'lane constraint both ways'
    Assert-True ($codex.effort -eq 'medium' -and $claude.effort -eq 'medium') 'first and backup effort returned'
    $r.jobs.coder.first_effort = 'low'; $r.jobs.coder.backup_effort = 'high'; Save-Roster $r
    Assert-True ((Resolve-RouterModel -Category complex-coding -Lane codex -Catalog $catalog).effort -eq 'low' -and (Resolve-RouterModel -Category complex-coding -Lane claude -Catalog $catalog).effort -eq 'high') 'picked slot effort is returned'
    $r.jobs.coder.first_effort = Get-RouterJobEffort coder; $r.jobs.coder.backup_effort = Get-RouterJobEffort coder; Save-Roster $r
    Assert-True ($null -eq (Resolve-RouterModel -Category image-generation -Catalog $catalog).effort) 'illustrator effort is null'
    $image = Resolve-RouterModel -SkipModelCheck -Category image-generation -Lane claude
    Assert-True ($image.status -eq 'wait' -and $null -eq $image.model -and $image.reason -match 'image model') 'illustrator Claude lane waits'
    Assert-True ($image.PSObject.Properties['effort'] -and $null -eq $image.effort) 'wait effort is null'
    $script:blocked = @('codex')
    $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Catalog $catalog
    Assert-True ($pick.model -eq 'claude-opus-5-5' -and $pick.reason -match 'Backup used: codex at its usage limit') 'blocked first vendor uses backup'
    $constrained = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex -Catalog $catalog
    Assert-True ($constrained.status -eq 'wait' -and $null -eq $constrained.model -and $constrained.reason -match 'codex at its usage limit') 'blocked constrained lane waits'
    $script:blocked = @('codex','claude')
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category complex-coding -Catalog $catalog).status -eq 'wait') 'both vendors blocked wait'
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category image-generation).status -eq 'wait') 'blocked illustrator waits'
    $script:blocked = @()
    @([pscustomobject]@{model='gpt-6.1-sol';job='coder'}) | ConvertTo-Json -AsArray | Set-Content (Join-Path $temp 'drift-marks.json')
    $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Catalog $catalog
    Assert-True ($pick.model -eq 'claude-opus-5-5' -and $pick.reason -match 'drifting') 'drifting first uses backup'
    $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex -Catalog $catalog
    Assert-True ($pick.status -eq 'wait' -and $null -eq $pick.model -and $pick.reason -match 'drifting') 'drifting constrained lane waits'
    $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex -EscalateFrom 'gpt-6-luna' -Catalog $catalog
    Assert-True ($pick.status -eq 'wait' -and $null -eq $pick.model -and $pick.reason -match 'drifting') 'drifting constrained lane escalation waits'
    @([pscustomobject]@{job='coder'},[pscustomobject]@{model='gpt-6.1-sol'}) | ConvertTo-Json -AsArray | Set-Content (Join-Path $temp 'drift-marks.json')
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category complex-coding -Catalog $catalog).model -eq 'gpt-6.1-sol') 'incomplete drift marks ignored'
    @([pscustomobject]@{model='gpt-image-2';job='illustrator'}) | ConvertTo-Json -AsArray | Set-Content (Join-Path $temp 'drift-marks.json')
    $image = Resolve-RouterModel -SkipModelCheck -Category image-generation
    Assert-True ($image.status -eq 'ok' -and $image.model -eq 'gpt-image-2' -and $image.alerts -contains 'roster-drift-no-backup:gpt-image-2') 'illustrator drift keeps image model and alerts'
    Remove-Item (Join-Path $temp 'drift-marks.json')
    $hidden = [pscustomobject]@{models=@([pscustomobject]@{slug='gpt-6.1-sol';visibility='hide'})}
    $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Catalog $hidden
    Assert-True ($pick.model -eq 'claude-opus-5-5' -and $pick.alerts -contains 'roster-model-unselectable:gpt-6.1-sol') 'unselectable first uses backup and alerts'
    Assert-True (@(Get-Content -LiteralPath $deliveryLog).Count -eq 1) 'unselectable roster alert is not delivered without SendAlerts'
    $null = Resolve-RouterModel -SkipModelCheck -SendAlerts -Category complex-coding -Catalog $hidden
    Assert-True (@(Get-Content -LiteralPath $deliveryLog).Count -eq 2) 'unselectable roster alert delivered once with SendAlerts'
    $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex -Catalog $hidden
    Assert-True ($pick.status -eq 'wait' -and $null -eq $pick.model -and $pick.alerts -contains 'roster-model-unselectable:gpt-6.1-sol') 'unselectable constrained Codex lane waits and alerts'
    $script:blocked = @('claude')
    $pick = Resolve-RouterModel -SkipModelCheck -Category analysis -Catalog $hidden
    Assert-True ($pick.status -eq 'wait' -and $null -eq $pick.model -and $pick.alerts -contains 'roster-model-unselectable:gpt-6.1-sol') 'unselectable Codex backup waits when Claude is blocked'
    $script:blocked = @()
    $pick = Resolve-RouterModel -SkipModelCheck -Category analysis -Lane codex -Catalog $hidden
    Assert-True ($pick.status -eq 'wait' -and $null -eq $pick.model -and $pick.alerts -contains 'roster-model-unselectable:gpt-6.1-sol') 'unselectable constrained Codex backup waits'
    $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex -EscalateFrom 'gpt-6-luna' -Catalog $hidden
    Assert-True ($pick.status -eq 'wait' -and $null -eq $pick.model -and $pick.alerts -contains 'roster-model-unselectable:gpt-6.1-sol') 'unselectable escalated Codex pick waits'
    $fast = Resolve-RouterModel -SkipModelCheck -Category mechanical -Catalog $catalog
    $protected = Resolve-RouterModel -SkipModelCheck -Category mechanical -Protected -Catalog $catalog
    Assert-True ($protected.job -eq 'coder' -and $protected.model -ne $fast.model) 'protected mechanical uses different coder model'
    foreach ($case in @(@('codex','gpt-6.1-sol'),@('claude','claude-opus-5-5'))) {
        $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane $case[0] -EscalateFrom $case[1] -Catalog $catalog
        Assert-True ($pick.model -eq $case[1] -and $pick.reason -match 'top non-frontier') "roster escalation ceiling $($case[0])"
    }
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category analysis -EscalateFrom 'gpt-6-luna' -Catalog $catalog).model -eq 'gpt-6.1-sol') 'roster escalation follows source model lane'
    foreach ($lane in @('codex','claude')) {
        $otherSource = if ($lane -eq 'codex') { 'claude-haiku-4-5-20251001' } else { 'gpt-6-luna' }
        $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane $lane -EscalateFrom $otherSource -Catalog $catalog
        Assert-True ($pick.vendor -eq $lane -and $pick.status -eq 'ok') "cross-vendor escalation stays on $lane lane"
    }
    foreach ($source in @('gpt-6-astra','claude-fable-5-5')) {
        $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -EscalateFrom $source -Catalog $catalog
        Assert-True ($pick.model -notin @('gpt-6-astra','claude-fable-5-5') -and $pick.status -eq 'ok') "roster frontier escalation source $source returns non-frontier"
    }
    $frontier = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json
    foreach ($category in $r.category_jobs.PSObject.Properties.Name) {
        foreach ($lane in @($null,'codex','claude')) {
            foreach ($protectedCase in @($false,$true)) {
                $args = @{ Category=$category; Protected=$protectedCase; SkipModelCheck=$true; Catalog=$catalog }
                if ($lane) { $args.Lane = $lane }
                $pick = Resolve-RouterModel @args
                Assert-True ($null -eq $pick.model -or ($frontier.codex_models -notcontains $pick.model -and @($frontier.claude_patterns | Where-Object { $pick.model -like $_ }).Count -eq 0)) "approved roster non-frontier $category/$lane/$protectedCase"
            }
        }
    }
    Remove-Item (Join-Path $temp 'roster.json')
    $pick = Resolve-RouterModel -SkipModelCheck -Category analysis -Catalog $catalog
    Assert-True ($pick.lane -eq 'claude' -and $pick.model -eq 'claude-opus-5-5' -and $pick.roster_source -eq 'default') 'no lane takes default roster lane'
    $script:blocked = @('claude')
    $pick = Resolve-RouterModel -SkipModelCheck -Category analysis -Catalog $catalog
    Assert-True ($pick.lane -eq 'codex' -and $pick.model -eq 'gpt-6.1-sol') 'no lane takes backup lane when first vendor blocked'
    $script:blocked = @()
    $cli = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../resolve-model.ps1') -Category analysis -SkipModelCheck -Json 2>$null | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $cli.category -eq 'analysis' -and $cli.lane -eq 'claude') 'CLI without Lane returns JSON pick'
    foreach ($category in @('math','analysis')) { Assert-True ((Resolve-RouterModel -SkipModelCheck -Category $category -Lane codex -Catalog $catalog).model -eq (Resolve-RouterModel -SkipModelCheck -Category planning -Lane codex -Catalog $catalog).model) "$category uses the same roster model as planning" }
    foreach ($case in @(@('codex','gpt-6.1-sol'),@('claude','claude-opus-5-5'))) { Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane $case[0] -EscalateFrom $case[1] -Catalog $catalog).model -eq $case[1]) "escalation stops at the non-frontier ladder ceiling for $($case[0])" }
    Write-Output "SUMMARY: $script:passed passed"
} finally { Exit-RouterTestCodexHome $fixtureCodexHome; $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorTransport; $env:DT_MODEL_ROUTER_STATE = $prior; Remove-Item -LiteralPath $temp -Recurse -Force }
