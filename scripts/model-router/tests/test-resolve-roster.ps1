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
$temp = Join-Path $env:TEMP ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$env:DT_MODEL_ROUTER_STATE = $temp
$script:blocked = @()
$catalog = [pscustomobject]@{ models=@([pscustomobject]@{slug='gpt-6-sol';visibility='list'},[pscustomobject]@{slug='gpt-6-luna';visibility='list'}) }
try {
    $r = Copy-Roster
    Assert-True (@(Get-RosterErrors $r).Count -eq 0) 'seed validates'
    $r.schema_version = 2; Assert-True ((Get-RosterErrors $r) -match 'ROSTER_SCHEMA_VERSION') 'schema version rule'; $r = Copy-Roster
    $r.generated_at = 'bad'; Assert-True ((Get-RosterErrors $r) -match 'ROSTER_GENERATED_AT') 'generated date rule'; $r = Copy-Roster
    $r.approved = 'yes'; Assert-True ((Get-RosterErrors $r) -match 'ROSTER_APPROVED') 'approval type rule'; $r = Copy-Roster
    $r.approved = $true; Assert-True ((Get-RosterErrors $r) -match 'ROSTER_APPROVED_AT') 'approval date rule'; $r = Copy-Roster
    $r.category_jobs.mechanical = 'coder'; Assert-True ((Get-RosterErrors $r) -match 'ROSTER_CATEGORY_JOB') 'category map rule'; $r = Copy-Roster
    $r.jobs.PSObject.Properties.Remove('writer'); Assert-True ((Get-RosterErrors $r) -match 'ROSTER_JOB') 'every job rule'; $r = Copy-Roster
    $r.jobs.coder.PSObject.Properties.Remove('first_vendor'); Assert-True ((Get-RosterErrors $r) -match 'ROSTER_JOB_FIELD') 'job field rule'; $r = Copy-Roster
    $r.jobs.fast.backup_vendor = 'codex'; Assert-True ((Get-RosterErrors $r) -match 'ROSTER_VENDOR_PAIR') 'different vendors rule'; $r = Copy-Roster
    $r.jobs.fast.backup = $null; Assert-True ((Get-RosterErrors $r) -match 'ROSTER_BACKUP') 'backup required rule'; $r = Copy-Roster
    $r.jobs.illustrator.backup = 'claude-opus-5-5'; Assert-True ((Get-RosterErrors $r) -match 'ROSTER_ILLUSTRATOR_BACKUP') 'illustrator null rule'; $r = Copy-Roster
    $r.jobs.coder.first = 'gpt-6-astra'; Assert-True ((Get-RosterErrors $r) -match 'ROSTER_FRONTIER') 'frontier rule'; $r = Copy-Roster
    $r.jobs.fast.first_vendor = 'claude'; Assert-True ((Get-RosterErrors $r) -match 'ROSTER_MODEL_VENDOR') 'model vendor rule'; $r = Copy-Roster
    $r.jobs.fast.backup = 'claude-sonnet-5'; $r.jobs.writer.backup = 'gpt-5.6-sol'; Assert-True ((Get-RosterErrors $r) -match 'ROSTER_MODEL_COUNT') 'five distinct models rule'
    Assert-True ((Read-RouterRoster).source -eq 'default') 'default source when state missing'
    $r = Copy-Roster; $r.approved = $true; $r.approved_at = '2026-09-28T01:00:00Z'; Save-Roster $r
    Assert-True ((Read-RouterRoster).source -eq 'state') 'approved state source'
    $invalid = Copy-Roster; $invalid.jobs.coder.first = 'gpt-6-astra'; Save-Roster $invalid
    $read = Read-RouterRoster
    Assert-True ($read.source -eq 'default' -and $read.validation_error -match 'ROSTER_FRONTIER') 'invalid state falls back with validation error'
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex -Catalog $catalog).validation_error -match 'ROSTER_FRONTIER') 'v1 result records invalid roster error'
    Save-Roster $r
    foreach ($category in $r.category_jobs.PSObject.Properties.Name) {
        $pick = Resolve-RouterModel -SkipModelCheck -Category $category -Catalog $catalog
        Assert-True ($pick.job -eq $r.category_jobs.$category -and $pick.roster_source -eq 'state') "category job $category"
    }
    $codex = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex -Catalog $catalog
    $claude = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane claude -Catalog $catalog
    Assert-True ($codex.model -eq 'gpt-6-sol' -and $codex.vendor -eq 'codex' -and $claude.model -eq 'claude-opus-5-5' -and $claude.agent_alias -eq 'opus') 'lane constraint both ways'
    $image = Resolve-RouterModel -SkipModelCheck -Category image-generation -Lane claude
    Assert-True ($image.status -eq 'wait' -and $null -eq $image.model -and $image.reason -match 'image model') 'illustrator Claude lane waits'
    $script:blocked = @('codex')
    $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Catalog $catalog
    Assert-True ($pick.model -eq 'claude-opus-5-5' -and $pick.reason -match 'Backup used: codex at its usage limit') 'blocked first vendor uses backup'
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex -Catalog $catalog).model -eq 'claude-opus-5-5') 'blocked constrained lane uses available backup'
    $script:blocked = @('codex','claude')
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category complex-coding -Catalog $catalog).status -eq 'wait') 'both vendors blocked wait'
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category image-generation).status -eq 'wait') 'blocked illustrator waits'
    $script:blocked = @()
    @([pscustomobject]@{model='gpt-6-sol';job='coder'}) | ConvertTo-Json -AsArray | Set-Content (Join-Path $temp 'drift-marks.json')
    $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Catalog $catalog
    Assert-True ($pick.model -eq 'claude-opus-5-5' -and $pick.reason -match 'drifting') 'drifting first uses backup'
    Remove-Item (Join-Path $temp 'drift-marks.json')
    $hidden = [pscustomobject]@{models=@([pscustomobject]@{slug='gpt-6-sol';visibility='hide'})}
    $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Catalog $hidden
    Assert-True ($pick.model -eq 'claude-opus-5-5' -and $pick.alerts -contains 'roster-model-unselectable:gpt-6-sol') 'unselectable first uses backup and alerts'
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category mechanical -Protected).job -eq 'coder') 'protected mechanical uses coder'
    foreach ($case in @(@('codex','gpt-6-sol'),@('claude','claude-opus-5-5'))) {
        $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane $case[0] -EscalateFrom $case[1] -Catalog $catalog
        Assert-True ($pick.model -eq $case[1] -and $pick.reason -match 'top non-frontier') "roster escalation ceiling $($case[0])"
    }
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category analysis -EscalateFrom 'gpt-6-luna' -Catalog $catalog).model -eq 'gpt-6-sol') 'roster escalation follows source model lane'
    Remove-Item (Join-Path $temp 'roster.json')
    $pick = Resolve-RouterModel -SkipModelCheck -Category analysis -Catalog $catalog
    Assert-True ($pick.lane -eq 'claude' -and $pick.model -eq 'claude-opus-5-5' -and $pick.roster_source -eq 'default') 'v1 no lane takes default roster lane'
    foreach ($category in @('math','analysis')) { Assert-True ((Resolve-RouterModel -SkipModelCheck -Category $category -Lane codex -Catalog $catalog).model -eq (Resolve-RouterModel -SkipModelCheck -Category planning -Lane codex -Catalog $catalog).model) "v1 $category maps to planning" }
    foreach ($case in @(@('codex','gpt-6-sol'),@('claude','claude-opus-5-5'))) { Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane $case[0] -EscalateFrom $case[1] -Catalog $catalog).model -eq $case[1]) "v1 frontier ceiling $($case[0])" }
    Write-Output "SUMMARY: $script:passed passed"
} finally { $env:DT_MODEL_ROUTER_STATE = $prior; Remove-Item -LiteralPath $temp -Recurse -Force }

