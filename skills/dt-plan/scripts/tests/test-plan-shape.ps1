Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passed = 0
function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_FAIL: $Message" }; $script:passed++
}
$path = Join-Path $PSScriptRoot ('plan-fixture-' + [guid]::NewGuid().ToString('N') + '.md')
$plan = @'
---
shape_version: 1
---
# Fixture Plan
**Date:** 2026-10-17
**Surface:** utility
**Scope:** light
**Dimension framework:** provisional
## Behavior
Run the isolated suite.
## Throughput and hardware
Host measured: 16 cores, 32 logical processors, 63 GiB RAM, CIM, 2026-10-17.
Tests: parallel, pytest -n 4, isolated roots, 2 GiB per job.
## Build-intake revalidation
| Claim | Evidence/source | Checked at | Recheck gate |
| --- | --- | --- | --- |
| No external claims | self-contained | 2026-10-17 | intake |
## Open Questions
None.
## Out of Scope
Deployment.
'@
try {
    [IO.File]::WriteAllText($path, $plan)
    $result = (& (Join-Path $PSScriptRoot '../verify-plan-shape.ps1') -Path $path -Json) | ConvertFrom-Json
    Check $result.ok 'complete throughput plan passes producer shape gate'
    [IO.File]::WriteAllText($path, ($plan -replace '(?ms)^## Throughput and hardware.*?(?=^## )', ''))
    $result = (& (Join-Path $PSScriptRoot '../verify-plan-shape.ps1') -Path $path -Json) | ConvertFrom-Json
    Check (-not $result.ok -and $result.missing_sections -contains '## Throughput and hardware') 'missing throughput section fails producer gate'
    $skill = Get-Content (Join-Path $PSScriptRoot '../../SKILL.md') -Raw
    Check ($skill.Contains('Grill this under Feasibility') -and $skill.Contains('named cause') -and $skill.Contains('Measure each execution')) 'dt-plan requires measured hosts and deliberate per-step decisions'
    Write-Output "SUMMARY: $passed passed"
} finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
