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

    $r[2].est_burn = 7; $r[2].est_seconds = 1
    Save-Fixture $table $fixturePath
    $pick = Resolve-RouterModel -Category routine-coding -Lane claude
    Assert-True ($pick.model -eq $r[2].model) '10 percent time tie-break'
    $r[2].est_seconds = 100
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -Category routine-coding -Lane claude).model -eq $r[1].model) '10 percent tie-break picks faster stronger model'

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

    $table.categories.'long-form-writing'.claude.candidates[1].grade = 'capable'
    $table.categories.'long-form-writing'.claude.candidates[1].citations = $r[1].citations
    Save-Fixture $table $fixturePath
    Assert-True ((Resolve-RouterModel -Category long-form-writing -Lane claude).protected) 'writing always protected'

    $table.categories.'complex-coding'.codex.candidates[1].grade = 'capable'
    $table.categories.'complex-coding'.codex.candidates[1].citations = $r[1].citations
    Save-Fixture $table $fixturePath
    $catalog = [pscustomobject]@{ models = @([pscustomobject]@{slug='gpt-6-astra';visibility='list'},[pscustomobject]@{slug='gpt-6-sol';visibility='hide'},[pscustomobject]@{slug='gpt-5.6-sol';visibility='list'}) }
    $codexPick = Resolve-RouterModel -Category complex-coding -Lane codex -Catalog $catalog
    Assert-True ($codexPick.model -eq 'gpt-5.6-sol' -and @($codexPick.alerts | Where-Object { $_ -match 'gpt-6-sol' }).Count -eq 1) 'unselectable Codex candidate skipped with alert'

    foreach ($row in $r) { $row.grade = 'unknown' }
    Save-Fixture $table $fixturePath
    $fallback = Resolve-RouterModel -Category routine-coding -Lane claude
    Assert-True ($fallback.model -eq 'claude-opus-5-5' -and @($fallback.alerts | Where-Object { $_ -match 'NO_ELIGIBLE_MODEL' }).Count -eq 1) 'fallback with alert'

    Set-Content -LiteralPath $fixturePath -Value '{"schema_version":99}'
    Assert-True ((Resolve-RouterModel -Category routine-coding -Lane claude).table_source -eq 'seed') 'invalid live table falls back to seed'
    $env:DT_MODEL_ROUTER_STATE = $null
    $worktreeDir = Get-RouterStateDir
    $mainDir = Split-Path -Parent ((& git rev-parse --path-format=absolute --git-common-dir).Trim())
    Push-Location $mainDir
    try { $mainState = Get-RouterStateDir } finally { Pop-Location }
    Assert-True ($worktreeDir -eq $mainState) 'state dir identical from main and worktree'
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
