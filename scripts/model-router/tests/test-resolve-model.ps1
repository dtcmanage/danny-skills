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
    $copy.generated_at = '2026-09-27'
    $rows = $copy.categories.'routine-coding'.claude.candidates
    foreach ($row in $rows) { $row.grade = 'unknown'; $row.citations = @(); $row.est_burn = $null; $row.est_seconds = $null; $row.pass_rate = $null; $row.pass_samples = 0 }
    return $copy
}
function Save-Fixture([object]$Table, [string]$Path) { $Table | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path }
function Enable-Candidate([object]$Candidate, [string]$Grade, [double]$Burn, [double]$Seconds) {
    $Candidate.grade = $Grade
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
    $table = New-Fixture
    $r = $table.categories.'routine-coding'.claude.candidates
    Enable-Candidate $r[1] 'strong' 8 30
    Enable-Candidate $r[2] 'capable' 2 10
    $r[3].grade = 'capable'; $r[3].citations = @([pscustomobject]@{ source = 'Vendor'; url = 'https://example.org/vendor'; independent = $false; note = 'Vendor only' })
    Save-Fixture $table $fixturePath
    $pick = Resolve-RouterModel -Category routine-coding -Lane claude
    Assert-True ($pick.model -eq $r[2].model -and $pick.ranked.Count -eq 2) 'eligibility excludes vendor-only and unknown'
    Assert-True ($pick.table_source -eq 'live' -and $pick.table_date -eq '2026-09-27') 'live table over seed'

    $r[2].est_burn = 6; $r[2].est_seconds = 1
    Save-Fixture $table $fixturePath
    $pick = Resolve-RouterModel -Category routine-coding -Lane claude
    Assert-True ($pick.model -eq $r[2].model) '10 percent time tie-break'
    $r[2].est_seconds = 100
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -Category routine-coding -Lane claude).model -eq $r[1].model) '10 percent tie-break picks faster stronger model'

    Enable-Candidate $r[3] 'capable' 118 100
    $r[1].est_burn = 100; $r[1].est_seconds = 300
    $r[2].est_burn = 109; $r[2].est_seconds = 200
    foreach ($row in @($r[1],$r[2],$r[3])) { $row.pass_rate = 1.0; $row.pass_samples = 10 }
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -Category routine-coding -Lane claude).model -eq $r[2].model) 'tie group anchored to minimum cost, not chained'
    $r[3].grade = 'unknown'
    $r[1].est_burn = 10; $r[1].est_seconds = 300; $r[1].pass_samples = 0
    $r[2].est_burn = 9; $r[2].est_seconds = 1; $r[2].pass_samples = 0
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -Category routine-coding -Lane claude).model -eq $r[1].model) 'strongest own burn excludes nonexistent retry'

    $r[2].est_burn = 2; $r[2].est_seconds = 10
    $r[2].pass_rate = 0.0; $r[2].pass_samples = 10
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -Category routine-coding -Lane claude).model -eq $r[1].model) 'calibrated pass rate affects expected cost'
    $r[2].pass_samples = 9
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -Category routine-coding -Lane claude).model -eq $r[2].model) 'uncalibrated grade default affects expected cost'

    $r[1].est_burn = $null; $r[2].est_burn = $null
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -Category routine-coding -Lane claude).model -eq $r[1].model) 'null burn retains strength order'
    Assert-True ((Resolve-RouterModel -Category routine-coding -Lane claude -Protected).model -eq $r[1].model) 'protected picks strongest'
    Assert-True ((Resolve-RouterModel -Category routine-coding -Lane claude -EscalateFrom $r[2].model).model -eq $r[1].model) 'escalation next stronger'
    Assert-True ((Resolve-RouterModel -Category routine-coding -Lane claude -EscalateFrom $r[1].model).reason -match 'no stronger') 'escalation ceiling reason'

    $r[1].grade = 'unknown'; $r[2].grade = 'unknown'
    Enable-Candidate $r[0] 'strong' 100 100
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -Category routine-coding -Lane claude).model -eq $r[0].model) 'frontier only when non-frontier absent'
    Enable-Candidate $r[1] 'capable' 1000 100
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -Category routine-coding -Lane claude).model -eq $r[1].model) 'frontier excluded with non-frontier eligible'
    Assert-True ((Resolve-RouterModel -Category routine-coding -Lane claude -EscalateFrom $r[1].model).model -eq $r[0].model) 'escalation from strongest non-frontier reaches frontier'

    $writing = $table.categories.'long-form-writing'.claude.candidates
    Enable-Candidate $writing[0] 'strong' 1 1
    Enable-Candidate $writing[1] 'strong' 100 100
    $cheapWriting = $r[2] | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
    Enable-Candidate $cheapWriting 'capable' 1 1
    $table.categories.'long-form-writing'.claude.candidates = @($writing) + @($cheapWriting)
    Save-Fixture $table $fixturePath
    $writingPick = Resolve-RouterModel -Category long-form-writing -Lane claude
    Assert-True ($writingPick.protected -and $writingPick.model -eq $writing[1].model -and $writingPick.ranked.Count -eq 2) 'writing skips cost ranking with multiple eligible candidates'

    $table.categories.'complex-coding'.codex.candidates[1].grade = 'capable'
    $table.categories.'complex-coding'.codex.candidates[1].citations = $r[1].citations
    $table.categories.'complex-coding'.codex.candidates[3].grade = 'capable'
    $table.categories.'complex-coding'.codex.candidates[3].citations = $r[1].citations
    Save-Fixture $table $fixturePath
    $catalog = [pscustomobject]@{ models = @([pscustomobject]@{slug='gpt-6-astra';visibility='list';description='frontier'},[pscustomobject]@{slug='gpt-6-sol';visibility='hide'},[pscustomobject]@{slug='gpt-5.6-sol';visibility='list'}) }
    $codexPick = Resolve-RouterModel -Category complex-coding -Lane codex -Catalog $catalog
    Assert-True ($codexPick.model -eq 'gpt-5.6-sol' -and @($codexPick.alerts | Where-Object { $_ -match '^UNSELECTABLE_CODEX_MODEL: gpt-6-sol$' }).Count -eq 1) 'unselectable Codex candidate skipped with alert'
    Assert-True (@($codexPick.alerts | Where-Object { $_ -match 'fallback_unselectable' }).Count -eq 1) 'unselectable fallback alerted'
    $table.categories.'complex-coding'.codex.candidates[0].grade = 'strong'
    $table.categories.'complex-coding'.codex.candidates[0].citations = $r[1].citations
    Save-Fixture $table $fixturePath
    $catalog.models[2] | Add-Member -NotePropertyName upgrade -NotePropertyValue 'Use a newer model'
    $codexPick = Resolve-RouterModel -Category complex-coding -Lane codex -Catalog $catalog
    Assert-True ($codexPick.model -eq 'gpt-6-astra' -and @($codexPick.alerts | Where-Object { $_ -match 'gpt-5.6-sol' }).Count -eq 1) 'upgrade notice makes candidate unselectable'
    $catalog.models[1].visibility = 'list'
    $table.categories.'routine-coding'.codex.candidates[1].grade = 'capable'
    $table.categories.'routine-coding'.codex.candidates[1].citations = $r[1].citations
    Save-Fixture $table $fixturePath
    $codexFallback = Resolve-RouterModel -Category routine-coding -Lane codex -Catalog $catalog
    Assert-True ($codexFallback.model -eq 'gpt-6-sol' -and @($codexFallback.alerts | Where-Object { $_ -match 'fallback_unselectable' }).Count -eq 0) 'selectable fallback has no alert'
    $catalog.models[1].visibility = 'hide'
    $table.categories.'routine-coding'.codex.candidates[1].grade = 'unknown'
    Save-Fixture $table $fixturePath
    $unselectableFallback = Resolve-RouterModel -Category routine-coding -Lane codex -Catalog $catalog
    Assert-True ($unselectableFallback.model -eq 'gpt-6-sol' -and @($unselectableFallback.alerts | Where-Object { $_ -match '^fallback_unselectable:' }).Count -eq 1) 'unselectable fallback returned with alert'

    foreach ($row in $r) { $row.grade = 'unknown' }
    Save-Fixture $table $fixturePath
    $fallback = Resolve-RouterModel -Category routine-coding -Lane claude
    Assert-True ($fallback.model -eq 'claude-opus-5-5' -and @($fallback.alerts | Where-Object { $_ -match 'no-eligible:routine-coding:claude' }).Count -eq 1) 'research fallback with keyed alert'

    Set-Content -LiteralPath $fixturePath -Value '{"schema_version":99}'
    $invalid = Resolve-RouterModel -Category routine-coding -Lane claude
    Assert-True ($invalid.table_source -eq 'seed' -and $invalid.validation_error -match 'ROOT_FIELD' -and @($invalid.alerts | Where-Object { $_ -match 'router-live-table-invalid' }).Count -eq 1) 'invalid live table alerts and falls back to seed'
    Assert-True (@($invalid.alerts | Where-Object { $_ -match 'no-eligible:' }).Count -eq 0 -and @($invalid.alerts | Where-Object { $_ -eq 'router-seed-table-in-use' }).Count -eq 1) 'seed suppresses category alert noise'
    $table = $seed | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $table.generated_at = '2026-09-27T12:00:00Z'
    Assert-True (@(Test-RouterTable -Table $table).Count -eq 0) 'ISO timestamp accepted'
    $table.generated_at = [datetime]'2026-09-27'
    Assert-True (@(Test-RouterTable -Table $table).Count -eq 0) 'DateTime accepted'
    $env:DT_MODEL_ROUTER_STATE = $null
    $worktreeDir = Get-RouterStateDir
    $mainDir = Split-Path -Parent ((& git rev-parse --path-format=absolute --git-common-dir).Trim())
    Push-Location $mainDir
    try { $mainState = Get-RouterStateDir } finally { Pop-Location }
    Assert-True ($worktreeDir -eq $mainState) 'state dir identical from main and worktree'
    Push-Location $env:TEMP
    try { $tempState = Get-RouterStateDir } finally { Pop-Location }
    Assert-True ($worktreeDir -eq $tempState) 'state dir independent of temp cwd'
    $outside = Split-Path -Parent $temp
    Push-Location $outside
    try { $outsideState = Get-RouterStateDir } finally { Pop-Location }
    Assert-True ($worktreeDir -eq $outsideState) 'state dir independent of other folder cwd'
    $image = Resolve-RouterModel -Category image-generation -Lane codex -Catalog ([pscustomobject]@{ models = @() })
    Assert-True ($image.model -eq 'gpt-image-2' -and @($image.alerts | Where-Object { $_ -match 'UNSELECTABLE|fallback_unselectable' }).Count -eq 0) 'image advice bypasses chat catalog'
    $env:DT_MODEL_ROUTER_STATE = $temp
    Save-Fixture (New-Fixture) $fixturePath
    $a = Resolve-RouterModel -Category routine-coding -Lane claude | ConvertTo-Json -Depth 12 -Compress
    $b = Resolve-RouterModel -Category routine-coding -Lane claude | ConvertTo-Json -Depth 12 -Compress
    Assert-True ($a -ceq $b) 'identical input produces identical JSON'
    Write-Output "SUMMARY: $script:passed passed"
} finally {
    $env:DT_MODEL_ROUTER_STATE = $priorState
    Remove-Item -LiteralPath $temp -Recurse -Force
}
