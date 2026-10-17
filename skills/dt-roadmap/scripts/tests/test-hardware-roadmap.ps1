Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passed = 0
function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_FAIL: $Message" }; $script:passed++
}
$root = Join-Path $PSScriptRoot ('roadmap-fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $design = Join-Path $root 'design.md'
    @'
# Fixture
## Implementation Sequence
1. Alpha. Build isolated alpha worktree.
2. Beta. Build isolated beta worktree.
3. Integrate. Accept both on integration branch.
## Throughput and hardware
Host: measured 32 logical processors, 63 GiB RAM, CIM, 2026-10-17; 2 GiB per job.
| Step | Host | Parallel method or serial reason | Dependencies / isolation | RAM per job |
| --- | --- | --- | --- | --- |
| Tests | SNOWWHITE | parallel: pytest -n 2 | isolated roots | 2 GiB |

| milestone-id | dependencies | execution | test-execution |
| --- | --- | --- | --- |
| M01 | - | parallel | parallel: pytest -n 2 tests/test_alpha.py |
| M02 | - | parallel | parallel: pytest -n 2 tests/test_beta.py |
| M03 | M01,M02 | serial: shared integration ref | serial: fixed device slot, separate roots did not isolate |

| Host | Cores | Logical processors | RAM |
| --- | --- | --- | --- |
| SNOWWHITE | 16 | 32 | 63 GiB |
## Validation Gates
- M01: `pytest -n 2 tests/test_alpha.py`
- M02: `pytest -n 2 tests/test_beta.py`
- M03: `pytest tests/test_integration.py`
'@ | Set-Content -LiteralPath $design
    $roadmap = Join-Path $root 'roadmap.md'
    & (Join-Path $PSScriptRoot '../build-roadmap.ps1') -DesignPath $design -RoadmapPath $roadmap -ForceMermaidFallback | Out-Null
    $raw = Get-Content $roadmap -Raw
    Check ($raw -match '\| M02 \| Beta \| - \|' -and $raw.Contains('M01,M02')) 'independent branches and fan-in survive generation'
    Check (-not $raw.Contains('M01 --> M02') -and $raw.Contains('M01 --> M03') -and $raw.Contains('M02 --> M03') -and $raw.Contains('after m01 m02')) 'graph and timeline honor declared concurrency and fan-in'
    Check ($raw.Contains('## Throughput and hardware') -and $raw.Contains('serial: shared integration ref') -and $raw.Contains('parallel: pytest -n 2')) 'hardware, serial causes and shard commands survive generation'
    Check (-not $raw.Contains('## Producer Warnings')) 'complete decisions generate no throughput warnings'
    $validated = (& (Join-Path $PSScriptRoot '../roadmap-validator.ps1') -RoadmapPath $roadmap -Json) | ConvertFrom-Json
    Check ($validated.pass -and $validated.milestone_count -eq 3) 'extended roadmap passes existing contract validation'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../milestones-to-xlsx.ps1') -RoadmapPath $roadmap -OutputDirectory $root -ForceCsvFallback | Out-Null
    Check ($LASTEXITCODE -eq 0) 'fallback milestone export succeeds'
    $rows = @(Import-Csv (Join-Path $root 'milestones.csv'))
    Check ($rows[1].execution -eq 'parallel' -and $rows[2].test_execution.Contains('fixed device slot')) 'export retains concurrency and serial causes'
    Check ((Get-Content (Join-Path $root 'milestones-table.md') -Raw).Contains('parallel: pytest -n 2')) 'markdown export retains sharding'
    Check ($raw.Contains('| Tests | SNOWWHITE |') -and $raw.Contains('| SNOWWHITE | 16 | 32 |')) 'plan step and host tables survive alongside milestone decisions'
    $broken = (Get-Content $design -Raw).Replace('serial: shared integration ref', 'serial')
    Set-Content -LiteralPath $design -Value $broken
    & (Join-Path $PSScriptRoot '../build-roadmap.ps1') -DesignPath $design -RoadmapPath $roadmap -ForceMermaidFallback | Out-Null
    Check ((Get-Content $roadmap -Raw).Contains('M03: supply dependencies, execution and test-execution')) 'unnamed serial cause produces an intake warning'
    $legacy = (Get-Content $design -Raw) -replace '(?ms)^## Throughput and hardware.*?(?=^## )', ''
    Set-Content -LiteralPath $design -Value $legacy
    & (Join-Path $PSScriptRoot '../build-roadmap.ps1') -DesignPath $design -RoadmapPath $roadmap -ForceMermaidFallback | Out-Null
    $raw = Get-Content $roadmap -Raw
    Check ($raw.Contains('UNRESOLVED') -and $raw.Contains('M01: supply dependencies') -and $raw.Contains('M03: supply dependencies')) 'legacy designs surface missing decisions for every milestone'
    Write-Output "SUMMARY: $passed passed"
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
