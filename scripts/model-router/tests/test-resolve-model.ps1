Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../resolve-model.ps1')

$script:passed = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Output "PASS: $Name"
}
function New-Fixture {
    $copy = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/seed-table.json') -Raw | ConvertFrom-Json -Depth 30
    $copy.source = 'research'
    $copy.coverage = 'full'
    $copy.generated_at = '2026-09-27'
    $copy.evidence_routing_approved = $true
    $rows = $copy.categories.'routine-coding'.claude.candidates
    foreach ($row in $rows) { $row.grade = 'unknown'; $row.confirmed_grade = 'unknown'; $row.citations = @(); $row.est_burn = $null; $row.est_seconds = $null; $row.pass_rate = $null; $row.pass_samples = 0 }
    return $copy
}
function Save-Fixture([object]$Table, [string]$Path) { $Table | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path }
function Enable-Candidate([object]$Candidate, [string]$Grade, [double]$Burn, [double]$Seconds) {
    $Candidate.grade = $Grade
    $Candidate.confirmed_grade = $Grade
    $Candidate.citations = @([pscustomobject]@{ source = 'Fixture independent'; url = 'https://example.org/test'; independent = $true; note = 'Fixture' })
    $Candidate.est_burn = $Burn
    $Candidate.est_seconds = $Seconds
}

$priorState = $env:DT_MODEL_ROUTER_STATE
$temp = Join-Path $env:TEMP ("model-router-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$env:DT_MODEL_ROUTER_STATE = $temp
try {
    $fixturePath = Join-Path $temp 'router-table.json'
    $seed = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/seed-table.json') -Raw | ConvertFrom-Json -Depth 30
    Assert-True (@(Test-RouterTable -Table $seed).Count -eq 0) 'seed table schema'
    Assert-True ((Get-RouterModelGeneration 'gpt-6-sol').major -gt (Get-RouterModelGeneration 'gpt-5.6-sol').major) 'GPT major generation order'
    Assert-True ((Get-RouterModelGeneration 'gpt-5.6-sol').minor -gt (Get-RouterModelGeneration 'gpt-5.5').minor) 'GPT minor generation order'
    Assert-True ((Get-RouterModelGeneration 'claude-opus-5-5').major -gt (Get-RouterModelGeneration 'claude-haiku-4-5-20251001').major) 'Claude generation order'
    Assert-True ((Get-RouterModelGeneration 'claude-sonnet-5').minor -eq 0 -and (Get-RouterModelGeneration 'claude-sonnet-5').major -eq 5) 'Claude major-only generation is 5.0'
    Assert-True ((Get-RouterModelGeneration 'claude-sonnet-5-20251001').minor -eq 0) 'Claude major-only date-suffixed generation is 5.0'
    Assert-True ((Get-RouterModelGeneration 'claude-opus-5-5').minor -eq 5 -and (Get-RouterModelGeneration 'claude-haiku-4-5-20251001').minor -eq 5) 'Claude minor and date-suffixed generations parse'
    $table = New-Fixture
    $table.evidence_routing_approved = $false
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex).model -eq 'gpt-6-sol') 'unapproved research table uses bridge'
    $table.evidence_routing_approved = $true
    $imageRow = @($table.categories.'image-generation'.codex.candidates | Where-Object model -eq 'gpt-image-2')[0]
    Enable-Candidate $imageRow 'capable' 2 10
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category image-generation -Lane codex).model -eq 'gpt-image-2') 'confirmed image incumbent resolves without chat catalog'
    & (Join-Path $PSScriptRoot '../approve-router-table.ps1') -Show -TablePath $fixturePath | Out-Null
    Assert-True $true 'approval show handles confirmed image incumbent'
    $legacy = $table | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $legacy.PSObject.Properties.Remove('evidence_routing_approved')
    foreach ($category in $legacy.categories.PSObject.Properties.Name) {
        foreach ($lane in $legacy.categories.$category.PSObject.Properties.Name) {
            foreach ($candidate in $legacy.categories.$category.$lane.candidates) { $candidate.PSObject.Properties.Remove('confirmed_grade') }
        }
    }
    Save-Fixture $legacy $fixturePath
    $legacyPick = Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude
    Assert-True ($legacyPick.model -eq 'claude-sonnet-5' -and $legacyPick.reason -match '^bridge mode' -and $null -eq $legacyPick.validation_error -and @($legacyPick.alerts | Where-Object { $_ -match 'router-live-table-invalid' }).Count -eq 0) 'pre-hardening table is valid and bridges without invalid alert'
    $legacy | Add-Member -NotePropertyName evidence_routing_approved -NotePropertyValue $true
    Save-Fixture $legacy $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude).reason -match '^bridge mode') 'missing confirmed grades bridge even with approval flag'
    Save-Fixture $table $fixturePath
    $sol = @($table.categories.'complex-coding'.codex.candidates | Where-Object model -eq 'gpt-6-sol')[0]
    $older = @($table.categories.'complex-coding'.codex.candidates | Where-Object model -eq 'gpt-5.6-sol')[0]
    Enable-Candidate $sol 'capable' 10 30
    Enable-Candidate $older 'strong' 2 10
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex).model -eq 'gpt-5.6-sol') 'older Sol wins only with higher confirmed grade'
    $older.confirmed_grade = 'capable'
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex).model -eq 'gpt-6-sol') 'equal grade keeps newer Sol despite lower burn'
    $older.confirmed_grade = 'unknown'
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex).model -eq 'gpt-6-sol') 'raw strong without confirmation cannot challenge'
    $mechanical = $table.categories.mechanical.codex.candidates
    $mechanicalSol = @($mechanical | Where-Object model -eq 'gpt-6-sol')[0]
    $mechanicalLuna = @($mechanical | Where-Object model -eq 'gpt-6-luna')[0]
    Enable-Candidate $mechanicalSol 'capable' 10 30
    Enable-Candidate $mechanicalLuna 'capable' 1 5
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category mechanical -Lane codex -Protected).model -eq 'gpt-6-sol') 'protected Codex mechanical retains stronger Sol'
    $mechanicalClaude = $table.categories.mechanical.claude.candidates
    $mechanicalOpus = @($mechanicalClaude | Where-Object model -eq 'claude-opus-5-5')[0]
    $mechanicalHaiku = @($mechanicalClaude | Where-Object model -eq 'claude-haiku-4-5-20251001')[0]
    Enable-Candidate $mechanicalOpus 'capable' 10 30
    Enable-Candidate $mechanicalHaiku 'strong' 1 5
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category mechanical -Lane claude -Protected).model -eq 'claude-opus-5-5') 'protected Claude mechanical retains stronger Opus despite Haiku grade and cost'
    # Real 2026-09-27 research ranks the small models first for mechanical work; protected work must still stay put.
    $tableBackup = $table | ConvertTo-Json -Depth 40
    $opusRank = $mechanicalOpus.strength_rank; $mechanicalOpus.strength_rank = $mechanicalHaiku.strength_rank; $mechanicalHaiku.strength_rank = $opusRank
    $solRank = $mechanicalSol.strength_rank; $mechanicalSol.strength_rank = $mechanicalLuna.strength_rank; $mechanicalLuna.strength_rank = $solRank
    foreach ($laneTable in @($table.categories.mechanical.claude, $table.categories.mechanical.codex)) {
        $laneTable.fallback = @($laneTable.candidates | Where-Object { -not $_.frontier } | Sort-Object strength_rank)[0].model
    }
    $mechanicalOpus.confirmed_grade = 'weak'; $mechanicalOpus.grade = 'weak'
    Enable-Candidate $mechanicalLuna 'strong' 1 5
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category mechanical -Lane claude -Protected).model -eq 'claude-opus-5-5') 'protected Claude work never moves to a smaller model even when research ranks it first'
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category mechanical -Lane codex -Protected).model -eq 'gpt-6-sol') 'protected Codex work never moves to a smaller model even when research ranks it first'
    Assert-True ((Get-RouterModelTier -Model 'claude-haiku-4-5-20251001') -lt (Get-RouterModelTier -Model 'claude-sonnet-5') -and (Get-RouterModelTier -Model 'gpt-6-luna') -lt (Get-RouterModelTier -Model 'gpt-5.6-sol') -and $null -eq (Get-RouterModelTier -Model 'gpt-5.5')) 'fixed model size order'
    $table = $tableBackup | ConvertFrom-Json -Depth 40
    Save-Fixture $table $fixturePath
    $sonnet = @($table.categories.'routine-coding'.claude.candidates | Where-Object model -eq 'claude-sonnet-5')[0]
    $haiku = @($table.categories.'routine-coding'.claude.candidates | Where-Object model -eq 'claude-haiku-4-5-20251001')[0]
    $opus = @($table.categories.'routine-coding'.claude.candidates | Where-Object model -eq 'claude-opus-5-5')[0]
    Enable-Candidate $sonnet 'capable' 10 20
    Enable-Candidate $haiku 'capable' 1 5
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude).model -eq 'claude-sonnet-5') 'confirmed Sonnet 5 stays over equal-grade older cheaper Haiku'
    Enable-Candidate $opus 'strong' 100 100
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude).model -eq 'claude-opus-5-5') 'higher confirmed grade wins despite challenger cost'
    $opus.confirmed_grade = 'unknown'; $haiku.confirmed_grade = 'strong'; $haiku.est_burn = 100; $sonnet.est_burn = 1
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude).model -eq 'claude-haiku-4-5-20251001') 'higher confirmed grade wins despite older generation, lower strength, and cost'
    $sonnet.confirmed_grade = 'unknown'; $opus.confirmed_grade = 'unknown'; $haiku.confirmed_grade = 'unknown'
    $table.categories.'complex-coding'.codex.candidates[1].confirmed_grade = 'capable'
    $table.categories.'complex-coding'.codex.candidates[1].citations = $sonnet.citations
    Save-Fixture $table $fixturePath
    $noneSelectable = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex -Catalog ([pscustomobject]@{ models = @() })
    Assert-True ($noneSelectable.alerts -contains 'no-eligible:complex-coding:codex') 'no-eligible keyed alert fires when incumbent and challengers are unselectable'
    $table.categories.'complex-coding'.codex.candidates[1].confirmed_grade = 'unknown'
    Save-Fixture $table $fixturePath
    $sol.confirmed_grade = 'unknown'
    Save-Fixture $table $fixturePath
    $held = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex
    Assert-True ($held.model -eq 'gpt-6-sol' -and $held.reason -eq 'incumbent kept: no confirmed evidence') 'unknown incumbent kept with reason'
    $script:sentRouterAlerts = [System.Collections.Generic.List[string]]::new()
    function Send-RouterAlerts { param([string[]]$Alerts, [switch]$ChatToStderr) foreach ($alert in $Alerts) { $script:sentRouterAlerts.Add($alert) } }
    $table.categories.'complex-coding'.codex.fallback = 'gpt-6-sol'
    $unknownCatalog = [pscustomobject]@{ models = @([pscustomobject]@{ slug = 'gpt-6-luna'; visibility = 'list' }) }
    $unknownSent = Resolve-RouterModel -SkipModelCheck -SendAlerts -Category complex-coding -Lane codex -Catalog $unknownCatalog
    Assert-True ($unknownSent.model -eq 'gpt-6-luna' -and $script:sentRouterAlerts -contains 'UNSELECTABLE_CODEX_MODEL: gpt-6-sol') 'unknown-incumbent return sends resolver alerts through fake transport'
    $script:sentRouterAlerts.Clear()
    @{ category = 'complex-coding'; lane = 'codex'; model = 'gpt-6-sol' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $temp 'drift-flags.json')
    $driftCatalog = [pscustomobject]@{ models = @([pscustomobject]@{ slug = 'gpt-6-sol'; visibility = 'list' },[pscustomobject]@{ slug = 'gpt-6-astra'; visibility = 'list'; description = 'frontier' }) }
    $driftedUnknown = Resolve-RouterModel -SkipModelCheck -SendAlerts -Category complex-coding -Lane codex -Catalog $driftCatalog
    Assert-True ($driftedUnknown.model -eq 'gpt-6-sol' -and $driftedUnknown.alerts -contains 'drift-no-alternative:gpt-6-sol:complex-coding:codex') 'drift never demotes to a frontier rung as a first pick'
    @{ category = 'mechanical'; lane = 'codex'; model = 'gpt-6-luna' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $temp 'drift-flags.json')
    $lunaCatalog = [pscustomobject]@{ models = @([pscustomobject]@{ slug = 'gpt-6-luna'; visibility = 'list' },[pscustomobject]@{ slug = 'gpt-6-sol'; visibility = 'list' },[pscustomobject]@{ slug = 'gpt-6-astra'; visibility = 'list'; description = 'frontier' }) }
    $driftedLuna = Resolve-RouterModel -SkipModelCheck -Category mechanical -Lane codex -Catalog $lunaCatalog
    Assert-True ($driftedLuna.model -ne 'gpt-6-luna' -and -not $driftedLuna.model.EndsWith('astra') -and $driftedLuna.reason -match 'drift demotion') 'flagged mechanical Luna is demoted off Luna'
    $weakBackup = $table | ConvertTo-Json -Depth 40
    foreach ($row in @($table.categories.mechanical.codex.candidates | Where-Object { $_.model -ne 'gpt-6-luna' })) { $row.grade = 'weak'; $row.confirmed_grade = 'weak' }
    Save-Fixture $table $fixturePath
    $weakStep = Resolve-RouterModel -SkipModelCheck -Category mechanical -Lane codex -Catalog $lunaCatalog
    Assert-True ($weakStep.model -ne 'gpt-6-sol' -and @($weakStep.alerts | Where-Object { $_ -like 'drift-no-alternative:*' }).Count -ge 1 -or $weakStep.model -eq 'gpt-6-luna') 'drift never steps onto a model confirmed weak for the category'
    $table = $weakBackup | ConvertFrom-Json -Depth 40
    Save-Fixture $table $fixturePath
    Remove-Item -LiteralPath (Join-Path $temp 'drift-flags.json')
    . (Join-Path $PSScriptRoot '../send-router-alert.ps1')
    $writing = Resolve-RouterModel -SkipModelCheck -Category long-form-writing -Lane claude
    Assert-True ($writing.model -eq 'claude-opus-5-5' -and $writing.model -ne 'claude-fable-5-1') 'unknown Opus keeps writing, never Fable'
    $table.coverage = 'partial'; Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex).reason -match 'bridge mode') 'partial table stays bridge'
    $table = New-Fixture
    $table.evidence_routing_approved = $false
    Save-Fixture $table $fixturePath
    & (Join-Path $PSScriptRoot '../approve-router-table.ps1') -Show -TablePath $fixturePath | Out-Null
    & (Join-Path $PSScriptRoot '../approve-router-table.ps1') -Approve -TablePath $fixturePath | Out-Null
    $approved = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -Depth 40
    Assert-True ($approved.evidence_routing_approved -and @($approved.approved_picks).Count -eq 34) 'approval stores all ordinary and protected picks'
    & (Join-Path $PSScriptRoot '../approve-router-table.ps1') -Revoke -TablePath $fixturePath | Out-Null
    Assert-True (-not (Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json).evidence_routing_approved) 'revoke restores bridge gate'
    $legacyTable = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -Depth 40
    $legacyTable.PSObject.Properties.Remove('evidence_routing_approved'); $legacyTable.PSObject.Properties.Remove('approved_picks')
    $legacyPath = Join-Path $temp 'legacy-router-table.json'
    $legacyTable | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $legacyPath
    & (Join-Path $PSScriptRoot '../approve-router-table.ps1') -Revoke -TablePath $legacyPath | Out-Null
    Assert-True ((Get-Content -LiteralPath $legacyPath -Raw | ConvertFrom-Json).evidence_routing_approved -eq $false) 'approval script handles a pre-approval-step table'
    foreach ($mode in @('-Show','-Approve')) {
        $legacyTable | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $legacyPath
        $legacyOk = $true
        try { if ($mode -eq '-Show') { & (Join-Path $PSScriptRoot '../approve-router-table.ps1') -Show -TablePath $legacyPath | Out-Null } else { & (Join-Path $PSScriptRoot '../approve-router-table.ps1') -Approve -TablePath $legacyPath | Out-Null } } catch { $legacyOk = $false }
        Assert-True $legacyOk "approval script $mode works on a pre-approval-step table"
    }
    Assert-True (@((Get-Content -LiteralPath $legacyPath -Raw | ConvertFrom-Json -Depth 40).approved_picks).Count -eq 34) 'legacy table approval stores every pick'
    $table = New-Fixture
    $r = $table.categories.'routine-coding'.claude.candidates
    Enable-Candidate $r[1] 'strong' 8 30
    Enable-Candidate $r[2] 'capable' 2 10
    $r[1].confirmed_grade = 'capable'
    $r[3].grade = 'capable'; $r[3].citations = @([pscustomobject]@{ source = 'Vendor'; url = 'https://example.org/vendor'; independent = $false; note = 'Vendor only' })
    Save-Fixture $table $fixturePath
    $pick = Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude
    Assert-True ($pick.model -eq $r[2].model -and $pick.ranked.Count -eq 1) 'eligibility excludes vendor-only, unknown, and non-qualifying challengers'
    Assert-True ($pick.table_source -eq 'live' -and $pick.table_date -eq '2026-09-27') 'live table over seed'

    $r[2].est_burn = 6; $r[2].est_seconds = 1
    Save-Fixture $table $fixturePath
    $pick = Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude
    Assert-True ($pick.model -eq $r[2].model) '10 percent time tie-break'
    $r[2].est_seconds = 100
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude).model -eq $r[1].model) '10 percent tie-break picks faster stronger model'

    Enable-Candidate $r[3] 'capable' 118 100
    $r[1].est_burn = 100; $r[1].est_seconds = 300
    $r[2].est_burn = 109; $r[2].est_seconds = 200
    foreach ($row in @($r[1],$r[2],$r[3])) { $row.pass_rate = 1.0; $row.pass_samples = 10 }
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude).model -eq $r[2].model) 'tie group anchored to minimum cost, not chained'
    $r[3].grade = 'unknown'
    $r[1].est_burn = 10; $r[1].est_seconds = 300; $r[1].pass_samples = 0
    $r[2].est_burn = 9; $r[2].est_seconds = 1; $r[2].pass_samples = 0
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude).model -eq $r[1].model) 'strongest own burn excludes nonexistent retry'

    $r[2].est_burn = 2; $r[2].est_seconds = 10
    $r[2].pass_rate = 0.0; $r[2].pass_samples = 10
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude).model -eq $r[1].model) 'calibrated pass rate affects expected cost'
    $r[2].pass_samples = 9
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude).model -eq $r[2].model) 'uncalibrated grade default affects expected cost'

    $r[1].est_burn = $null; $r[2].est_burn = $null
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude).model -eq $r[2].model) 'null burn keeps incumbent without calibrated cost'
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude -Protected).model -eq 'claude-opus-5-5') 'protected picks strongest incumbent'
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude -EscalateFrom $r[2].model).model -eq $r[1].model) 'escalation next stronger'
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude -EscalateFrom 'sonnet').model -eq $r[1].model) 'evidence escalation resolves Claude alias'
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude -EscalateFrom $r[1].model).reason -match 'no stronger') 'escalation ceiling reason'

    $r[1].grade = 'unknown'; $r[1].confirmed_grade = 'unknown'
    $r[2].grade = 'unknown'; $r[2].confirmed_grade = 'unknown'
    Enable-Candidate $r[0] 'strong' 100 100
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude).model -eq $r[2].model) 'unknown incumbent stays despite frontier-only evidence'
    Enable-Candidate $r[1] 'capable' 1000 100
    Enable-Candidate $r[2] 'capable' 10 10
    Save-Fixture $table $fixturePath
    $nonFrontierPick = Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude
    Assert-True ($nonFrontierPick.model -ne $r[0].model -and $nonFrontierPick.ranked -notcontains $r[0].model) 'frontier excluded with non-frontier eligible'
    Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude -EscalateFrom $r[1].model).model -eq $r[1].model) 'escalation from strongest non-frontier stays at ceiling'

    $writing = $table.categories.'long-form-writing'.claude.candidates
    Enable-Candidate $writing[0] 'strong' 1 1
    Enable-Candidate $writing[1] 'strong' 100 100
    $cheapWriting = $r[2] | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
    Enable-Candidate $cheapWriting 'capable' 1 1
    $table.categories.'long-form-writing'.claude.candidates = @($writing) + @($cheapWriting)
    Save-Fixture $table $fixturePath
    $writingPick = Resolve-RouterModel -SkipModelCheck -Category long-form-writing -Lane claude
    Assert-True ($writingPick.protected -and $writingPick.model -eq $writing[1].model -and $writingPick.ranked.Count -eq 1) 'writing keeps confirmed Opus over weaker cheap candidates'

    $table.categories.'complex-coding'.codex.candidates[1].grade = 'capable'
    $table.categories.'complex-coding'.codex.candidates[1].confirmed_grade = 'capable'
    $table.categories.'complex-coding'.codex.candidates[1].citations = $r[1].citations
    $table.categories.'complex-coding'.codex.candidates[3].grade = 'strong'
    $table.categories.'complex-coding'.codex.candidates[3].confirmed_grade = 'strong'
    $table.categories.'complex-coding'.codex.candidates[3].citations = $r[1].citations
    Save-Fixture $table $fixturePath
    $catalog = [pscustomobject]@{ models = @([pscustomobject]@{slug='gpt-6-astra';visibility='list';description='frontier'},[pscustomobject]@{slug='gpt-6-sol';visibility='hide'},[pscustomobject]@{slug='gpt-5.6-sol';visibility='list'}) }
    $codexPick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex -Catalog $catalog
    Assert-True ($codexPick.model -eq 'gpt-5.6-sol' -and @($codexPick.alerts | Where-Object { $_ -match '^UNSELECTABLE_CODEX_MODEL: gpt-6-sol$' }).Count -eq 1) 'unselectable Codex candidate skipped with alert'
    Assert-True (@($codexPick.alerts | Where-Object { $_ -match 'fallback_unselectable' }).Count -eq 1) 'unselectable fallback alerted'
    $table.categories.'complex-coding'.codex.candidates[0].grade = 'strong'
    $table.categories.'complex-coding'.codex.candidates[0].confirmed_grade = 'strong'
    $table.categories.'complex-coding'.codex.candidates[0].citations = $r[1].citations
    Save-Fixture $table $fixturePath
    $catalog.models[2] | Add-Member -NotePropertyName upgrade -NotePropertyValue 'Use a newer model'
    $codexPick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex -Catalog $catalog
    Assert-True ($codexPick.model -eq 'gpt-6-sol' -and @($codexPick.alerts | Where-Object { $_ -match 'gpt-5.6-sol' }).Count -eq 1 -and @($codexPick.alerts | Where-Object { $_ -match 'fallback_unselectable' }).Count -eq 1) 'upgrade notice excludes older candidate without frontier first pick'
    $catalog.models[1].visibility = 'list'
    $table.categories.'routine-coding'.codex.candidates[1].grade = 'capable'
    $table.categories.'routine-coding'.codex.candidates[1].confirmed_grade = 'capable'
    $table.categories.'routine-coding'.codex.candidates[1].citations = $r[1].citations
    Save-Fixture $table $fixturePath
    $codexFallback = Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane codex -Catalog $catalog
    Assert-True ($codexFallback.model -eq 'gpt-6-sol' -and @($codexFallback.alerts | Where-Object { $_ -match 'fallback_unselectable' }).Count -eq 0) 'selectable fallback has no alert'
    $catalog.models[1].visibility = 'hide'
    $table.categories.'routine-coding'.codex.candidates[1].grade = 'unknown'
    $table.categories.'routine-coding'.codex.candidates[1].confirmed_grade = 'unknown'
    Save-Fixture $table $fixturePath
    $unselectableFallback = Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane codex -Catalog $catalog
    Assert-True ($unselectableFallback.model -eq 'gpt-6-sol' -and @($unselectableFallback.alerts | Where-Object { $_ -match '^fallback_unselectable:' }).Count -eq 1) 'unselectable fallback returned with alert'

    foreach ($row in $r) { $row.grade = 'unknown'; $row.confirmed_grade = 'unknown' }
    Save-Fixture $table $fixturePath
    $fallback = Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude
    Assert-True ($fallback.model -eq 'claude-sonnet-5' -and $fallback.reason -eq 'incumbent kept: no confirmed evidence') 'unknown incumbent keeps bridge without research fallback'

    Set-Content -LiteralPath $fixturePath -Value '{"schema_version":99}'
    $invalid = Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude
    Assert-True ($invalid.table_source -eq 'seed' -and $invalid.validation_error -match 'ROOT_FIELD' -and @($invalid.alerts | Where-Object { $_ -match 'router-live-table-invalid' }).Count -eq 1) 'invalid live table alerts and falls back to seed'
    Assert-True (@($invalid.alerts | Where-Object { $_ -match 'no-eligible:' }).Count -eq 0 -and @($invalid.alerts | Where-Object { $_ -eq 'router-seed-table-in-use' }).Count -eq 1) 'seed suppresses category alert noise'
    $table = $seed | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $table.generated_at = '2026-09-27T12:00:00Z'
    Assert-True (@(Test-RouterTable -Table $table).Count -eq 0) 'ISO timestamp accepted'
    $table.generated_at = [datetime]'2026-09-27'
    Assert-True (@(Test-RouterTable -Table $table).Count -eq 0) 'DateTime accepted'
    $isolatedState = Join-Path $temp 'new-state'
    $env:DT_MODEL_ROUTER_STATE = $isolatedState
    Assert-True ((Get-RouterStateDir) -eq $isolatedState -and (Get-Content -LiteralPath (Join-Path $isolatedState '.gitignore') -Raw) -eq "*`n") 'new machine state gets gitignore'
    Set-Content -LiteralPath (Join-Path $isolatedState '.gitignore') -Value 'custom'
    [void](Get-RouterStateDir)
    Assert-True ((Get-Content -LiteralPath (Join-Path $isolatedState '.gitignore') -Raw).Trim() -eq 'custom') 'existing state gitignore is preserved'
    $image = Resolve-RouterModel -SkipModelCheck -Category image-generation -Lane codex -Catalog ([pscustomobject]@{ models = @() })
    Assert-True ($image.model -eq 'gpt-image-2' -and @($image.alerts | Where-Object { $_ -match 'UNSELECTABLE|fallback_unselectable' }).Count -eq 0) 'image advice bypasses chat catalog'
    $imageProtected = Resolve-RouterModel -SkipModelCheck -Category image-generation -Lane codex -Protected -Catalog ([pscustomobject]@{ models = @() })
    Assert-True ($imageProtected.model -eq 'gpt-image-2') 'protected flag never swaps the image model for a chat model'
    $env:DT_MODEL_ROUTER_STATE = $temp

    # Bridge mode: no research table (seed source) routes exactly as dt-build did pre-router.
    Remove-Item -LiteralPath $fixturePath -Force
    $bridgeCatalog = [pscustomobject]@{ models = @(
        [pscustomobject]@{ slug = 'gpt-6-astra'; visibility = 'list'; description = 'frontier' },
        [pscustomobject]@{ slug = 'gpt-6-sol'; visibility = 'list' },
        [pscustomobject]@{ slug = 'gpt-6-luna'; visibility = 'list' }) }
    $bridgeExpected = [ordered]@{
        'complex-coding' = @('gpt-6-sol','claude-opus-5-5'); 'routine-coding' = @('gpt-6-sol','claude-sonnet-5')
        'code-review' = @('gpt-6-sol','claude-sonnet-5'); 'ui-frontend' = @('gpt-6-sol','claude-sonnet-5')
        'planning' = @('gpt-6-sol','claude-opus-5-5'); 'deep-research' = @('gpt-6-sol','claude-sonnet-5')
        'long-form-writing' = @('gpt-6-sol','claude-opus-5-5'); 'mechanical' = @('gpt-6-luna','claude-haiku-4-5-20251001')
        'image-generation' = @('gpt-image-2',$null) }
    foreach ($category in $bridgeExpected.Keys) {
        foreach ($lane in @('codex','claude')) {
            $want = $bridgeExpected[$category][$(if ($lane -eq 'codex') { 0 } else { 1 })]
            if ($null -eq $want) { continue }
            $pick = Resolve-RouterModel -SkipModelCheck -Category $category -Lane $lane -Catalog $bridgeCatalog
            Assert-True ($pick.model -eq $want -and $pick.reason -match '^bridge mode \(no full research table yet\): ' -and $pick.table_source -eq 'seed' -and @($pick.alerts | Where-Object { $_ -eq 'router-seed-table-in-use' }).Count -eq 1) "bridge pick $category/$lane -> $want"
        }
    }
    $protectedBridge = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex -Protected -Catalog $bridgeCatalog
    Assert-True ($protectedBridge.model -eq 'gpt-6-sol' -and $protectedBridge.protected) 'bridge complex-coding protected -> gpt-6-sol'
    foreach ($case in @(@('code-review','codex','gpt-6-sol'), @('code-review','claude','claude-opus-5-5'), @('routine-coding','claude','claude-opus-5-5'), @('mechanical','codex','gpt-6-sol'))) {
        $protectedCase = Resolve-RouterModel -SkipModelCheck -Category $case[0] -Lane $case[1] -Protected -Catalog $bridgeCatalog
        Assert-True ($protectedCase.model -eq $case[2] -and $protectedCase.protected) "bridge $($case[0])/$($case[1]) protected -> $($case[2])"
    }
    foreach ($step in @(@('codex','gpt-6-luna','gpt-6-sol'), @('claude','claude-haiku-4-5-20251001','claude-sonnet-5'), @('claude','claude-sonnet-5','claude-opus-5-5'))) {
        $up = Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane $step[0] -EscalateFrom $step[1] -Catalog $bridgeCatalog
        Assert-True ($up.model -eq $step[2] -and $up.reason -match 'one rung up') "bridge escalation $($step[1]) -> $($step[2])"
    }
    foreach ($aliasStep in @(@('haiku','claude-sonnet-5'), @('sonnet','claude-opus-5-5'), @('sonnet[1m]','claude-opus-5-5'), @('opus','claude-opus-5-5'))) {
        Assert-True ((Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude -EscalateFrom $aliasStep[0]).model -eq $aliasStep[1]) "bridge alias escalation $($aliasStep[0])"
    }
    foreach ($top in @(@('codex','gpt-6-sol'), @('claude','claude-opus-5-5'))) {
        $same = Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane $top[0] -EscalateFrom $top[1] -Catalog $bridgeCatalog
        Assert-True ($same.model -eq $top[1] -and $same.reason -match 'already at the top') "bridge escalation at top keeps $($top[1]) and says so"
    }
    $noSol = [pscustomobject]@{ models = @([pscustomobject]@{ slug = 'gpt-6-astra'; visibility = 'list'; description = 'frontier' }, [pscustomobject]@{ slug = 'gpt-6-luna'; visibility = 'list' }) }
    $down = Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane codex -Catalog $noSol
    Assert-True ($down.model -eq 'gpt-6-luna' -and @($down.alerts | Where-Object { $_ -eq 'UNSELECTABLE_CODEX_MODEL: gpt-6-sol' }).Count -eq 1) 'bridge unselectable pick falls to next ladder rung with alert, never a frontier first pick'
    $escalatedPastGap = Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane codex -EscalateFrom 'gpt-6-luna' -Catalog $noSol
    Assert-True ($escalatedPastGap.model -eq 'gpt-6-luna') 'bridge escalation never reaches frontier when next rung is unselectable'
    Assert-True ((Get-RouterAlertMessage -Key 'router-seed-table-in-use') -match 'pre-router defaults until research runs') 'seed alert says routing matches pre-router defaults'

    Save-Fixture (New-Fixture) $fixturePath
    $research = Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude
    Assert-True ($research.table_source -eq 'live' -and $research.reason -notmatch 'bridge mode' -and @($research.alerts | Where-Object { $_ -eq 'router-seed-table-in-use' }).Count -eq 0) 'research-sourced table uses evidence rules, not bridge mode'
    $partial = New-Fixture; $partial.coverage = 'partial'; Save-Fixture $partial $fixturePath
    foreach ($case in @(@('routine-coding','claude','claude-sonnet-5'),@('mechanical','claude','claude-haiku-4-5-20251001'),@('mechanical','codex','gpt-6-luna'),@('planning','codex','gpt-6-sol'))) {
        $pick = Resolve-RouterModel -SkipModelCheck -Category $case[0] -Lane $case[1] -Catalog $bridgeCatalog
        Assert-True ($pick.model -eq $case[2] -and $pick.reason -match 'bridge mode') "partial research bridge pick $($case[0])/$($case[1])"
    }
    Save-Fixture (New-Fixture) $fixturePath
    $a = Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude | ConvertTo-Json -Depth 12 -Compress
    $b = Resolve-RouterModel -SkipModelCheck -Category routine-coding -Lane claude | ConvertTo-Json -Depth 12 -Compress
    Assert-True ($a -ceq $b) 'identical input produces identical JSON'
    Write-Output "SUMMARY: $script:passed passed"
} finally {
    $env:DT_MODEL_ROUTER_STATE = $priorState
    Remove-Item -LiteralPath $temp -Recurse -Force
}
