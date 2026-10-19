Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passed = 0; $failed = [Collections.Generic.List[string]]::new()
function Check([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passed++ } else { $script:failed.Add($Message) }
}
$scripts = Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'design-coverage.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('coverage-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $source = Join-Path $root 'design.md'
    $requirements = "# Design`n## Requirements`n- Website form.`n- Enrichment client.`n- Outlook -Prospect mode.`n"
    $sequence = @'
## Implementation Sequence
1. Build client.
## Throughput and hardware
Measured test host; isolated roots.
| milestone-id | dependencies | execution | test-execution |
| --- | --- | --- | --- |
| M01 | - | parallel | parallel: independent suite process |
## Validation Gates
- M01: `pwsh -NoProfile -Command 'exit 0'`
'@
    $header = "## Design Coverage`n| requirement-id | requirement | build-id | milestone-id | owner | reason |`n| --- | --- | --- | --- | --- | --- |`n"
    foreach ($split in @($false, $true)) {
        foreach ($mode in @('mapped', 'unmapped', 'out-of-build')) {
            Set-Content -LiteralPath $source -Value ($requirements + $(if ($split) { '' } else { $sequence }))
            $inventory = @(Get-DesignRequirements (Get-Content -Raw $source))
            $rows = foreach ($req in $inventory) {
                $build = if ($split -and $req.id -eq 'L4') { 'database' } elseif ($split) { 'website' } else { 'main' }
                if ($mode -eq 'unmapped' -and $req.id -eq 'L5') { continue }
                if ($mode -eq 'out-of-build' -and $req.id -eq 'L5') { "| $($req.id) | $($req.text) | out-of-build | - | Email HQ | Other workstation; before switch-on |" }
                else { "| $($req.id) | $($req.text) | $build | M01 | - | - |" }
            }
            $table = $header + ($rows -join "`n") + "`n"
            $inputs = if ($split) { @('website', 'database') } else { @('main') }
            $registry = "## Coverage Builds`n| build-id | input-path |`n| --- | --- |`n" + (($inputs | ForEach-Object { "| $_ | $root/$_.md |" }) -join "`n") + "`n"
            foreach ($build in $inputs) {
                $inputPath = Join-Path $root "$build.md"
                $origin = if ($split) { $source } else { $inputPath }
                $body = if ($split) { $sequence } else { $requirements + $sequence }
                Set-Content -LiteralPath $inputPath -Value ("---`ncoverage_design: $origin`ncoverage_build: $build`n---`n" + $body + "`n" + $table + $registry)
            }
            # Inventory is line-based: single input has frontmatter, so regenerate IDs from its actual lines.
            if (-not $split) {
                $inputPath = Join-Path $root 'main.md'
                $actualInventory = @(Get-DesignRequirements (Get-Content -Raw $inputPath))
                $raw = Get-Content -Raw $inputPath
                for ($i = $inventory.Count - 1; $i -ge 0; $i--) {
                    $raw = $raw.Replace("| $($inventory[$i].id) |", "| $($actualInventory[$i].id) |")
                }
                Set-Content -LiteralPath $inputPath -Value $raw
            }
            foreach ($build in $inputs) {
                $roadmap = Join-Path $root "$build-roadmap.md"
                & pwsh -NoProfile -File (Join-Path $scripts 'build-roadmap.ps1') -DesignPath (Join-Path $root "$build.md") -RoadmapPath $roadmap -ForceMermaidFallback | Out-Null
                $result = (& pwsh -NoProfile -File (Join-Path $scripts 'roadmap-validator.ps1') -RoadmapPath $roadmap -Json) -join "`n" | ConvertFrom-Json
                Check ($result.pass -eq ($mode -ne 'unmapped')) "split=$split mode=$mode build=${build}: $($result.errors -join '; ')"
                if ($mode -eq 'unmapped') { Check (($result.errors -join ' ') -match 'COVERAGE_UNMAPPED.*Outlook') 'unmapped error names missing Outlook requirement' }
                if ($mode -eq 'out-of-build') {
                    $checklist = (Get-OutOfBuildChecklist (Get-Content -Raw $roadmap)) -join "`n"
                    Check ($checklist.Contains('- [ ]') -and $checklist.Contains('Email HQ') -and $checklist.Contains('before switch-on')) 'out-of-build checklist includes owner and reason'
                }
            }
        }
    }
    # Mutations of a complete split roadmap: unknown milestone, duplicate owner, missing owner, divergent peer.
    $roadmap = Join-Path $root 'website-roadmap.md'
    $raw = Get-Content -Raw $roadmap
    $cases = @(
        @{ raw = $raw.Replace('| website | M01 |', '| website | M99 |'); code = 'COVERAGE_MILESTONE_UNKNOWN' },
        @{ raw = $raw.Replace('| Email HQ |', '| - |'); code = 'COVERAGE_OWNER_REQUIRED' },
        @{ raw = $raw.Replace('| L3 | Website form. | website | M01 | - | - |', "| L3 | Website form. | website | M01 | - | - |`n| L3 | Website form. | website | M01 | - | - |"); code = 'COVERAGE_DUPLICATE' },
        @{ raw = $raw.Replace('Website form.', 'Changed form.'); code = 'COVERAGE_STALE' },
        @{ raw = $raw.Replace('database.md', 'missing.md'); code = 'COVERAGE_BUILD_MISSING' }
    )
    foreach ($case in $cases) { Check ((@(Test-DesignCoverage $roadmap $case.raw @('M01')) -join ' ') -match $case.code) $case.code }
    $peer = Join-Path $root 'database.md'
    Set-Content -LiteralPath $peer -Value ((Get-Content -Raw $peer).Replace('Email HQ', 'Different owner'))
    Check ((@(Test-DesignCoverage $roadmap $raw @('M01')) -join ' ') -match 'COVERAGE_SPLIT_MISMATCH') 'divergent split table rejected'
    $units = @(Get-DesignRequirements "## Behavior`n- A`n  - B`n~~~text`n- example`n~~~`n## Build-intake revalidation`n- ignored`n")
    Check ($units.Count -eq 2) 'nested bullets included, fences and revalidation excluded'
    Check ((@(Test-DesignCoverage $roadmap '# no source' @('M01')) -join ' ') -match 'COVERAGE_SOURCE_MISSING') 'missing source fails closed'
    $unmarkedSplit = Join-Path $root 'build-input-unmarked.md'
    Set-Content -LiteralPath $unmarkedSplit -Value $sequence
    $caught = $false
    try { New-DesignCoverage $unmarkedSplit | Out-Null } catch { $caught = $_.Exception.Message -match 'COVERAGE_SOURCE_MISSING' }
    Check $caught 'split input cannot silently inventory only its own repo slice'
    $autoSource = Join-Path $root 'auto-design.md'
    Set-Content -LiteralPath $autoSource -Value ($requirements + $sequence)
    $auto = New-DesignCoverage $autoSource
    $autoRaw = "---`ncoverage_design: $($auto.origin)`n---`n## Design Coverage`n$($auto.table)`n## Coverage Builds`n$($auto.builds)"
    Check (@(Get-CoverageRows $autoRaw).Count -eq 4) 'automatic inventory emits every requirement and sequence item'
    Check ((@(Test-DesignCoverage $roadmap $autoRaw @('M01')) -join ' ') -match 'COVERAGE_UNMAPPED.*Outlook') 'producer never guesses ownership of cross-workstation requirement'
    Set-Content -LiteralPath $autoSource -Value '# No requirements'
    Check ((@(Test-DesignCoverage $roadmap $autoRaw @('M01')) -join ' ') -match 'COVERAGE_EMPTY') 'empty inventory fails with named error even with stale rows'
    # Full producer/validator counterexample: legacy headings cannot invent a remote M02
    # when that input's canonical numbered sequence generates only M01.
    $mixedParent = Join-Path $root 'mixed-parent.md'
    Set-Content -LiteralPath $mixedParent -Value "# Design`n## Requirements`n- Client requirement."
    $mixedBody = $sequence + "`n## Notes`n### Phase one`n### Phase two`n"
    $mixedTable = $header + "| L3 | Client requirement. | database | M02 | - | - |`n"
    $mixedRegistry = "## Coverage Builds`n| build-id | input-path |`n| --- | --- |`n| website | $root/mixed-website.md |`n| database | $root/mixed-database.md |`n"
    foreach ($build in @('website', 'database')) {
        Set-Content -LiteralPath (Join-Path $root "mixed-$build.md") -Value ("---`ncoverage_design: $mixedParent`ncoverage_build: $build`n---`n" + $mixedBody + $mixedTable + $mixedRegistry)
    }
    $mixedRoadmap = Join-Path $root 'mixed-roadmap.md'
    & pwsh -NoProfile -File (Join-Path $scripts 'build-roadmap.ps1') -DesignPath (Join-Path $root 'mixed-website.md') -RoadmapPath $mixedRoadmap -ForceMermaidFallback | Out-Null
    $mixedResult = (& pwsh -NoProfile -File (Join-Path $scripts 'roadmap-validator.ps1') -RoadmapPath $mixedRoadmap -Json) -join "`n" | ConvertFrom-Json
    Check (-not $mixedResult.pass -and ($mixedResult.errors -join ' ') -match 'COVERAGE_MILESTONE_UNKNOWN.*database/M02') 'mixed-format split cannot claim a milestone the remote producer never generates'
    $mixedSingle = Join-Path $root 'mixed-single.md'
    Set-Content -LiteralPath $mixedSingle -Value $mixedBody
    $mixedCoverage = New-DesignCoverage $mixedSingle
    $phaseRows = @(Get-CoverageRows ("## Design Coverage`n" + $mixedCoverage.table) | Where-Object { $_['requirement'] -match '^Phase' })
    Check ($phaseRows.Count -eq 2 -and @($phaseRows | Where-Object { $_['milestone-id'] -ne '-' }).Count -eq 0) 'phase units beside a sequence require explicit ownership'
    $legacySource = Join-Path $root 'legacy.md'
    @'
# Legacy design
### Phase one
### Phase two
## Throughput and hardware
| milestone-id | dependencies | execution | test-execution |
| --- | --- | --- | --- |
| M01 | - | parallel | parallel: isolated fixture process |
| M02 | M01 | serial: shared fixture state | serial: shared fixture state |
## Validation Gates
- M01: `pwsh -NoProfile -Command 'exit 0'`
- M02: `pwsh -NoProfile -Command 'exit 0'`
'@ | Set-Content -LiteralPath $legacySource
    $legacyRoadmap = Join-Path $root 'legacy-roadmap.md'
    & pwsh -NoProfile -File (Join-Path $scripts 'build-roadmap.ps1') -DesignPath $legacySource -RoadmapPath $legacyRoadmap -ForceMermaidFallback | Out-Null
    $legacyResult = (& pwsh -NoProfile -File (Join-Path $scripts 'roadmap-validator.ps1') -RoadmapPath $legacyRoadmap -Json) -join "`n" | ConvertFrom-Json
    Check ($legacyResult.pass -and $legacyResult.milestone_count -eq 2) 'legacy-only phase designs retain deterministic ownership and pass validation'
    # A roadmap written before the coverage gate (no coverage_design, no Design Coverage) still validates, with a warning.
    $preGate = Join-Path $root 'pre-gate-roadmap.md'
    $preGateText = ((Get-Content -Raw -LiteralPath $legacyRoadmap) -replace '(?m)^coverage_design:.*\r?\n', '') -replace '(?ms)^## Design Coverage\s*$.*?(?=^## )', ''
    Set-Content -LiteralPath $preGate -Value $preGateText
    $preGateResult = (& pwsh -NoProfile -File (Join-Path $scripts 'roadmap-validator.ps1') -RoadmapPath $preGate -Json) -join "`n" | ConvertFrom-Json
    Check ($preGateResult.pass -and @($preGateResult.warnings | Where-Object { $_ -like 'COVERAGE_LEGACY*' }).Count -eq 1) 'pre-gate roadmaps keep validating with a COVERAGE_LEGACY warning so in-flight builds resume'
} finally {
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetTempPath())) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Write-Output "SUMMARY: $passed passed, $($failed.Count) failed"
foreach ($failure in $failed) { Write-Output "FAIL: $failure" }
if ($failed.Count) { exit 1 }
