param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_FAIL: $Message" }
}

function Write-Manifests([string]$Root, [string]$Version, [string]$Summary, [string]$PreviousVersion = '1.0.0') {
    $entry = "$Version $Summary"
    $history = if ($Version -eq $PreviousVersion) { "[`"$entry`"]" } else { "[`"$entry`",`"$PreviousVersion prior release`"]" }
    Write-Utf8 (Join-Path $Root '.claude-plugin\plugin.json') (@"
{"name":"fixture","version":"$Version","metadata":{"changelog":$history}}
"@)
    Write-Utf8 (Join-Path $Root '.claude-plugin\marketplace.json') (@"
{"metadata":{"version":"$Version"},"plugins":[{"version":"$Version"}]}
"@)
}

function Write-Skill([string]$Root, [string]$Name, [string]$Version) {
    $dir = Join-Path $Root "skills\$Name"
    Write-Utf8 (Join-Path $dir 'SKILL.md') (@"
---
name: $Name
description: "Fixture."
metadata:
  version: $Version
---

# Fixture

Apply the shared deterministic and referencing baseline at ``../../references/deterministic-reference-policy.md``.
"@)
    Write-Utf8 (Join-Path $dir 'CHANGELOG.md') "# $Name changelog`n`n- $Version (2026-07-12): Fixture release.`n"
}

$validator = Join-Path $PSScriptRoot 'verify-versioning-policy.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("version-policy-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    Write-Manifests $tempRoot '1.0.0' 'initial'
    Write-Skill $tempRoot 'alpha' '1.0.0'
    Write-Utf8 (Join-Path $tempRoot 'references\shared-component-owners.json') '{"references/shared-component-owners.json":{"consumers":[],"summary_token":"shared"}}'
    New-Item -ItemType Directory -Path (Join-Path $tempRoot 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath $validator -Destination (Join-Path $tempRoot 'scripts\verify-versioning-policy.ps1')
    & git -C $tempRoot init -q
    & git -C $tempRoot config user.email 'fixture@example.invalid'
    & git -C $tempRoot config user.name 'Fixture'
    & git -C $tempRoot add .
    & git -C $tempRoot commit -q -m 'base'
    & git -C $tempRoot branch -M main

    $snapshotJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 0) "valid snapshot failed: $($snapshotJson -join ' ')"
    Assert-True ([bool](($snapshotJson -join "`n") | ConvertFrom-Json).pass) 'valid snapshot did not report pass'

    # A behavioral file without either release bump must fail both layers.
    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\scripts\run.ps1') 'Write-Output fixture'
    $missingBumpsJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -BaseRef main -Json
    Assert-True ($LASTEXITCODE -eq 1) 'behavioral edit without bumps passed'
    $missingBumps = ($missingBumpsJson -join "`n") | ConvertFrom-Json
    Assert-True (@($missingBumps.errors | Where-Object { $_ -match '^SKILL_VERSION_NOT_BUMPED:' }).Count -eq 1) 'missing skill bump was not reported'
    Assert-True (@($missingBumps.errors | Where-Object { $_ -match '^PLUGIN_VERSION_NOT_BUMPED:' }).Count -eq 1) 'missing plugin bump was not reported'

    # Skill bump alone remains an invalid pack release.
    Write-Skill $tempRoot 'alpha' '1.0.1'
    $skillOnlyJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -BaseRef main -Json
    Assert-True ($LASTEXITCODE -eq 1) 'skill-only bump passed without plugin bump'
    Assert-True (@((($skillOnlyJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^PLUGIN_VERSION_NOT_BUMPED:' }).Count -eq 1) 'skill-only release missed plugin error'

    Write-Manifests $tempRoot '1.0.1' 'unrelated change'
    $missingCoverageJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -BaseRef main -Json
    Assert-True ($LASTEXITCODE -eq 1) 'plugin release summary omitted changed skill/version but passed'
    Assert-True (@((($missingCoverageJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^PLUGIN_CHANGELOG_SKILL_MISSING:' }).Count -eq 1) 'missing plugin skill coverage was not reported'

    Write-Manifests $tempRoot '1.0.1' 'alpha 1.0.1'
    $validReleaseJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -BaseRef main -Json
    Assert-True ($LASTEXITCODE -eq 0) "valid release failed: $($validReleaseJson -join ' ')"
    & git -C $tempRoot add .
    & git -C $tempRoot commit -q -m 'valid release'
    $releaseBase = (& git -C $tempRoot rev-parse HEAD).Trim()
    & git -C $tempRoot checkout -q -b 'feat/version-fixture'
    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\_log.md') 'temporary gate-only log'
    & git -C $tempRoot add skills/alpha/_log.md
    & git -C $tempRoot commit -q -m 'log-only feature commit'

    & pwsh -NoProfile -File (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\build-plugin.ps1') `
        -RepoRoot $tempRoot -ValidateOnly *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'feature-branch packaging allowed snapshot-only validation'
    & pwsh -NoProfile -File (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\build-plugin.ps1') `
        -RepoRoot $tempRoot -BaseRef main -ValidateOnly *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'feature-branch packaging rejected explicit base-ref validation'
    & pwsh -NoProfile -File (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\build-plugin.ps1') `
        -RepoRoot $tempRoot -BaseRef HEAD -ValidateOnly *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'feature-branch packaging accepted self-referential BaseRef HEAD'
    $selfBaseJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -BaseRef HEAD -Json
    Assert-True ($LASTEXITCODE -eq 1) 'authoritative validator accepted feature-branch BaseRef HEAD'
    Assert-True (@((($selfBaseJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^BASE_REF_NOT_MAIN:' }).Count -eq 1) 'validator self-base failure did not identify non-main base'
    & git -C $tempRoot rm -q skills/alpha/_log.md
    & git -C $tempRoot commit -q -m 'remove gate-only log'

    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\_log.md') '2026-07-12 alpha: fixture friction'
    $logOnlyJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -BaseRef $releaseBase -Json
    Assert-True ($LASTEXITCODE -eq 0) "_log-only change incorrectly required a release: $($logOnlyJson -join ' ')"
    Remove-Item -LiteralPath (Join-Path $tempRoot 'skills\alpha\_log.md') -Force

    Write-Utf8 (Join-Path $tempRoot 'scripts\shared.ps1') 'Write-Output shared'
    Write-Manifests $tempRoot '1.0.2' 'shared change' '1.0.1'
    $undeclaredSharedJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -BaseRef main -Json
    Assert-True ($LASTEXITCODE -eq 1) 'undeclared shared change passed'
    Assert-True (@((($undeclaredSharedJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^SHARED_IMPACT_UNDECLARED:' }).Count -eq 1) 'undeclared shared impact was not reported'
    Write-Utf8 (Join-Path $tempRoot 'references\shared-component-owners.json') '{"references/shared-component-owners.json":{"consumers":[],"summary_token":"shared"},"scripts/shared.ps1":{"consumers":[],"summary_token":""}}'
    $emptySharedJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -BaseRef main -Json
    Assert-True ($LASTEXITCODE -eq 1) 'semantically empty shared-impact declaration passed'
    Assert-True (@((($emptySharedJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^SHARED_IMPACT_EMPTY:' }).Count -eq 1) 'empty shared-impact declaration was not reported'
    Write-Utf8 (Join-Path $tempRoot 'references\shared-component-owners.json') '{"references/shared-component-owners.json":{"consumers":[],"summary_token":"shared"},"scripts/shared.ps1":{"consumers":["alpha"],"summary_token":"shared"}}'
    $unbumpedConsumerJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -BaseRef main -Json
    Assert-True ($LASTEXITCODE -eq 1) 'shared consumer without skill bump passed'
    Assert-True (@((($unbumpedConsumerJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^SHARED_CONSUMER_NOT_BUMPED:' }).Count -eq 1) 'unbumped shared consumer was not reported'
    Remove-Item -LiteralPath (Join-Path $tempRoot 'scripts\shared.ps1') -Force
    Write-Utf8 (Join-Path $tempRoot 'references\shared-component-owners.json') '{"references/shared-component-owners.json":{"consumers":[],"summary_token":"shared"}}'
    Write-Manifests $tempRoot '1.0.1' 'alpha 1.0.1'

    Write-Skill $tempRoot 'alpha' '1.0.2'
    Write-Utf8 (Join-Path $tempRoot '.claude-plugin\plugin.json') '{"name":"fixture","version":"1.0.3","metadata":{"changelog":["1.0.3 alpha","1.0.2 details","1.0.1 alpha 1.0.1"]}}'
    Write-Utf8 (Join-Path $tempRoot '.claude-plugin\marketplace.json') '{"metadata":{"version":"1.0.3"},"plugins":[{"version":"1.0.3"}]}'
    $boundaryCoverageJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -BaseRef main -Json
    Assert-True ($LASTEXITCODE -eq 1) 'plugin skill coverage was synthesized across changelog entry boundaries'
    Assert-True (@((($boundaryCoverageJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^PLUGIN_CHANGELOG_SKILL_MISSING:' }).Count -eq 1) 'entry-boundary coverage failure was not reported'
    Write-Skill $tempRoot 'alpha' '1.0.1'
    Write-Manifests $tempRoot '1.0.1' 'alpha 1.0.1'

    # Current version must be the first changelog record.
    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n`n- 1.0.0 (2026-01-01): stale`n- 1.0.1 (2026-07-12): current`n"
    $staleLogJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'stale changelog ordering passed'
    Assert-True (@((($staleLogJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^SKILL_CHANGELOG_STALE:' }).Count -eq 1) 'stale changelog was not reported'
    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n`n- 1.0.1 (2026-07-12): current`n- 1.0.1 (2026-07-11): duplicate`n"
    $duplicateLogJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'duplicate changelog version passed'
    Assert-True (@((($duplicateLogJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^SKILL_CHANGELOG_DUPLICATE:' }).Count -gt 0) 'duplicate changelog was not reported'
    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n`n- 1.0.1 (2026-07-12): current`n- 0.8.0 (2026-07-11): older`n- 0.9.0 (2026-07-10): out of order`n"
    $orderJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'out-of-order changelog passed'
    Assert-True (@((($orderJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^SKILL_CHANGELOG_ORDER:' }).Count -gt 0) 'changelog order error was not reported'
    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n`n- 1.0.1 (2026-07-12): current`n## 1.0.0`n`n- older detail`n"
    $mixedJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'mixed changelog styles passed'
    Assert-True (@((($mixedJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^SKILL_CHANGELOG_STYLE_MIXED:' }).Count -eq 1) 'mixed changelog style was not reported'

    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n`n~~~text`n- 1.0.1 fake`n~~~`n- 0.9.0 (2026-07-11): stale`n"
    $fencedJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'version-like line in a fenced block counted as release history'
    Assert-True (@((($fencedJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^SKILL_CHANGELOG_STALE:' }).Count -eq 1) 'fenced fake current version did not expose stale history'

    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n`n### Unreleased`n`n- pending`n- 1.0.1 (2026-07-12): current`n"
    $unreleasedJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'non-H2 Unreleased section passed'
    Assert-True (@((($unreleasedJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^SKILL_CHANGELOG_UNRELEASED:' }).Count -eq 1) 'non-H2 Unreleased section was not reported'

    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n`n- 1.0.1 (2026-07-12): current`n* 9.0.0 unsupported`n- 1.0.0 (2026-07-11): older`n"
    $unsupportedLogJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'unsupported version-record marker passed'
    Assert-True (@((($unsupportedLogJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^SKILL_CHANGELOG_STRUCTURE_INVALID:' }).Count -gt 0) 'unsupported version-record marker was not reported'

    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n`n- 1.0.1 (2026-07-12): current`n- 9.0.0-beta hidden`n* 9.0.0: hidden`n### Unreleased:`n"
    $malformedMarkersJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'malformed version and Unreleased markers passed'
    $malformedMarkerErrors = @(($malformedMarkersJson -join "`n") | ConvertFrom-Json).errors
    Assert-True (@($malformedMarkerErrors | Where-Object { $_ -match '^SKILL_CHANGELOG_STRUCTURE_INVALID:' }).Count -ge 2) 'malformed version markers were not reported'
    Assert-True (@($malformedMarkerErrors | Where-Object { $_ -match '^SKILL_CHANGELOG_UNRELEASED:' }).Count -eq 1) 'punctuated Unreleased marker was not reported'

    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n`n- 1.0.1 (2026-07-12): current`n## [9.0.0]`n`n- hidden`n## [Unreleased]`n"
    $bracketedMarkersJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'bracketed version and Unreleased markers passed'
    $bracketedErrors = @(($bracketedMarkersJson -join "`n") | ConvertFrom-Json).errors
    Assert-True (@($bracketedErrors | Where-Object { $_ -match '^SKILL_CHANGELOG_STRUCTURE_INVALID:' }).Count -ge 1) 'bracketed version marker was not reported'
    Assert-True (@($bracketedErrors | Where-Object { $_ -match '^SKILL_CHANGELOG_UNRELEASED:' }).Count -eq 1) 'bracketed Unreleased marker was not reported'

    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n`n- 1.0.1 (2026-07-12): current`n## **9.0.0**`n`n- hidden`n## **Unreleased**`n"
    $emphasizedMarkersJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'Markdown-emphasized version and Unreleased headings passed'
    $emphasizedErrors = @(($emphasizedMarkersJson -join "`n") | ConvertFrom-Json).errors
    Assert-True (@($emphasizedErrors | Where-Object { $_ -match '^SKILL_CHANGELOG_STRUCTURE_INVALID:' }).Count -ge 1) 'emphasized version heading was not reported'
    Assert-True (@($emphasizedErrors | Where-Object { $_ -match '^SKILL_CHANGELOG_UNRELEASED:' }).Count -eq 1) 'emphasized Unreleased heading was not reported'

    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n"
    $emptyLogJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'empty changelog passed'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string](($emptyLogJson -join "`n") | ConvertFrom-Json).errors[0])) 'empty changelog crashed instead of returning policy JSON'

    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n`n- 1.0.1`n"
    $summarylessJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'compact changelog record without summary passed'
    Assert-True (@((($summarylessJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^SKILL_CHANGELOG_STRUCTURE_INVALID:' }).Count -gt 0) 'summaryless compact record was not reported'
    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n`n## 1.0.1`n`n## 1.0.0`n`n- Older release detail.`n"
    $detailLessJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'expanded changelog record without detail passed'
    Assert-True (@((($detailLessJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match 'expanded-record-missing-detail' }).Count -eq 1) 'summaryless expanded record was not reported'
    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n`n## 1.0.1`n`n- 1.0.1 current release detail.`n`n## 1.0.0`n`n- Older release detail.`n"
    $versionLedDetailJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 0) "expanded detail beginning with its heading version was misread as a duplicate record: $($versionLedDetailJson -join ' ')"
    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n`n## 1.0.1`n`n- 1.0.1`n`n## 1.0.0`n`n- Older release detail.`n"
    $bareVersionDetailJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'bare same-version bullet was accepted as expanded release detail'
    Assert-True (@((($bareVersionDetailJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match 'expanded-detail-missing-summary' }).Count -eq 1) 'bare same-version expanded detail was not reported'
    Write-Utf8 (Join-Path $tempRoot 'skills\alpha\CHANGELOG.md') "# alpha changelog`n`n- 1.0.1 (2026-07-12): current`n- 1.0.0 (2026-07-11): older`n"

    $scopeDir = Join-Path $tempRoot 'skills\scope-test'
    Write-Utf8 (Join-Path $scopeDir 'SKILL.md') "---`nname: scope-test`ndescription: `"Fixture.`"`nmetadata:`n  owner: fixture`nruntime:`n  version: 1.0.0`n---`n`nApply the shared deterministic and referencing baseline at ``../../references/deterministic-reference-policy.md``.`n"
    Write-Utf8 (Join-Path $scopeDir 'CHANGELOG.md') "# scope-test changelog`n`n- 1.0.0 (2026-07-12): fake`n"
    $scopeJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'top-level runtime.version was accepted as metadata.version'
    Remove-Item -LiteralPath $scopeDir -Recurse -Force

    $duplicateMetadataDir = Join-Path $tempRoot 'skills\duplicate-metadata'
    Write-Utf8 (Join-Path $duplicateMetadataDir 'SKILL.md') "---`nname: duplicate-metadata`ndescription: `"Fixture.`"`nmetadata:`n  version: 1.0.0`nmetadata:`n  version: 1.0.1`n---`n`nApply the shared deterministic and referencing baseline at ``../../references/deterministic-reference-policy.md``.`n"
    Write-Utf8 (Join-Path $duplicateMetadataDir 'CHANGELOG.md') "# duplicate-metadata changelog`n`n- 1.0.0 (2026-07-12): fake`n"
    $duplicateMetadataJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'duplicate metadata mappings passed validator'
    Remove-Item -LiteralPath $duplicateMetadataDir -Recurse -Force

    $fakeFrontmatterDir = Join-Path $tempRoot 'skills\body-only'
    Write-Utf8 (Join-Path $fakeFrontmatterDir 'SKILL.md') "# body only`nname: body-only`nmetadata:`n  version: 1.0.0`n"
    Write-Utf8 (Join-Path $fakeFrontmatterDir 'CHANGELOG.md') "# body-only changelog`n`n- 1.0.0 (2026-07-12): fake`n"
    $bodyOnlyJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'body-only metadata was accepted as frontmatter'
    Assert-True (@((($bodyOnlyJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^SKILL_FRONTMATTER_INVALID:' }).Count -eq 1) 'missing frontmatter was not reported'
    Remove-Item -LiteralPath $fakeFrontmatterDir -Recurse -Force

    Write-Manifests $tempRoot '01.0.1' 'invalid-semver'
    $invalidSemVerJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -Snapshot -Json
    Assert-True ($LASTEXITCODE -eq 1) 'leading-zero plugin SemVer passed'
    Assert-True (@((($invalidSemVerJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^PLUGIN_VERSION_INVALID:' }).Count -gt 0) 'invalid plugin SemVer was not reported'
    Write-Manifests $tempRoot '1.0.1' 'alpha 1.0.1'

    # New skills start at 0.1.0 and require a changelog.
    Write-Skill $tempRoot 'beta' '0.2.0'
    $newSkillJson = & pwsh -NoProfile -File $validator -RepoRoot $tempRoot -BaseRef main -Json
    Assert-True ($LASTEXITCODE -eq 1) 'new skill with wrong initial version passed'
    Assert-True (@((($newSkillJson -join "`n") | ConvertFrom-Json).errors | Where-Object { $_ -match '^NEW_SKILL_VERSION_INVALID:' }).Count -eq 1) 'new-skill version error missing'

    $bigRoot = Join-Path $tempRoot 'big-semver-repo'
    $bigBase = '999999999999999999999.0.0'
    $bigCurrent = '999999999999999999999.0.1'
    Write-Manifests $bigRoot $bigBase 'initial' $bigBase
    Write-Skill $bigRoot 'omega' $bigBase
    Write-Utf8 (Join-Path $bigRoot 'references\shared-component-owners.json') '{}'
    & git -C $bigRoot init -q
    & git -C $bigRoot config user.email 'fixture@example.invalid'
    & git -C $bigRoot config user.name 'Fixture'
    & git -C $bigRoot add .
    & git -C $bigRoot commit -q -m 'big base'
    & git -C $bigRoot branch -M main
    Write-Skill $bigRoot 'omega' $bigCurrent
    Write-Utf8 (Join-Path $bigRoot 'skills\omega\scripts\run.ps1') 'Write-Output big'
    Write-Manifests $bigRoot $bigCurrent "omega $bigCurrent" $bigBase
    $bigJson = & pwsh -NoProfile -File $validator -RepoRoot $bigRoot -BaseRef main -Json
    Assert-True ($LASTEXITCODE -eq 0) "large numeric SemVer crashed or failed comparison: $($bigJson -join ' ')"

    $piggyRoot = Join-Path $tempRoot 'piggyback-repo'
    Write-Manifests $piggyRoot '1.0.0' 'initial' '1.0.0'
    Write-Skill $piggyRoot 'alpha' '1.0.0'
    Write-Utf8 (Join-Path $piggyRoot 'references\shared-component-owners.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $piggyRoot 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath $validator -Destination (Join-Path $piggyRoot 'scripts\verify-versioning-policy.ps1')
    & git -C $piggyRoot init -q
    & git -C $piggyRoot config user.email 'fixture@example.invalid'
    & git -C $piggyRoot config user.name 'Fixture'
    & git -C $piggyRoot add .
    & git -C $piggyRoot commit -q -m 'base release'
    & git -C $piggyRoot branch -M main
    Write-Skill $piggyRoot 'alpha' '1.0.1'
    Write-Utf8 (Join-Path $piggyRoot 'skills\alpha\scripts\run.ps1') 'Write-Output released'
    Write-Manifests $piggyRoot '1.0.1' 'alpha 1.0.1' '1.0.0'
    & git -C $piggyRoot add .
    & git -C $piggyRoot commit -q -m 'valid 1.0.1 release'
    Write-Utf8 (Join-Path $piggyRoot 'skills\alpha\scripts\run.ps1') 'Write-Output unversioned-later-change'
    & git -C $piggyRoot add .
    & git -C $piggyRoot commit -q -m 'unversioned behavioral change'
    & pwsh -NoProfile -File (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\build-plugin.ps1') `
        -RepoRoot $piggyRoot -ValidateOnly *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'clean-main packaging let a post-release behavioral commit piggyback the old bump'

    $staleRoot = Join-Path $tempRoot 'stale-feature-repo'
    Write-Manifests $staleRoot '1.0.0' 'initial' '1.0.0'
    Write-Skill $staleRoot 'alpha' '1.0.0'
    Write-Utf8 (Join-Path $staleRoot 'references\shared-component-owners.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $staleRoot 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath $validator -Destination (Join-Path $staleRoot 'scripts\verify-versioning-policy.ps1')
    & git -C $staleRoot init -q
    & git -C $staleRoot config user.email 'fixture@example.invalid'
    & git -C $staleRoot config user.name 'Fixture'
    & git -C $staleRoot add .
    & git -C $staleRoot commit -q -m 'base'
    & git -C $staleRoot branch -M main
    $staleBranchBase = (& git -C $staleRoot rev-parse HEAD).Trim()
    Write-Utf8 (Join-Path $staleRoot 'README.md') 'current main content'
    & git -C $staleRoot add README.md
    & git -C $staleRoot commit -q -m 'advance main'
    & git -C $staleRoot checkout -q -b 'feat/stale' $staleBranchBase
    Write-Skill $staleRoot 'alpha' '1.0.1'
    Write-Utf8 (Join-Path $staleRoot 'skills\alpha\scripts\run.ps1') 'Write-Output feature'
    Write-Manifests $staleRoot '1.0.1' 'alpha 1.0.1' '1.0.0'
    & git -C $staleRoot add .
    & git -C $staleRoot commit -q -m 'stale feature release'
    & pwsh -NoProfile -File (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\build-plugin.ps1') `
        -RepoRoot $staleRoot -BaseRef main -ValidateOnly *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'packaging accepted a feature branch that did not contain current main'

    $packageRoot = Join-Path $tempRoot 'package-inventory-repo'
    Write-Manifests $packageRoot '1.0.0' 'initial' '1.0.0'
    Write-Skill $packageRoot 'alpha' '1.0.0'
    Write-Utf8 (Join-Path $packageRoot 'references\shared-component-owners.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $packageRoot 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath $validator -Destination (Join-Path $packageRoot 'scripts\verify-versioning-policy.ps1')
    & git -C $packageRoot init -q
    & git -C $packageRoot config user.email 'fixture@example.invalid'
    & git -C $packageRoot config user.name 'Fixture'
    & git -C $packageRoot add .
    & git -C $packageRoot commit -q -m 'base release'
    & git -C $packageRoot branch -M main
    Write-Skill $packageRoot 'alpha' '1.0.1'
    Write-Utf8 (Join-Path $packageRoot 'skills\alpha\scripts\run.ps1') 'Write-Output released'
    Write-Manifests $packageRoot '1.0.1' 'alpha 1.0.1' '1.0.0'
    & git -C $packageRoot add .
    & git -C $packageRoot commit -q -m 'valid package release'
    Write-Utf8 (Join-Path $packageRoot 'private-root-evidence.txt') 'must never ship'
    Write-Utf8 (Join-Path $packageRoot 'skills\alpha\_log.md') 'must never ship'
    $packageArtifact = Join-Path $tempRoot 'fixture.plugin'
    & pwsh -NoProfile -File (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\build-plugin.ps1') `
        -RepoRoot $packageRoot -OutputPath $packageArtifact *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'allowlisted package inventory fixture failed to build'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $packageArchive = [System.IO.Compression.ZipFile]::OpenRead($packageArtifact)
    try { $packageEntries = @($packageArchive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') }) }
    finally { $packageArchive.Dispose() }
    Assert-True ($packageEntries -contains '.claude-plugin/plugin.json') 'package omitted plugin manifest'
    Assert-True ($packageEntries -contains 'skills/alpha/SKILL.md') 'package omitted allowlisted skill'
    Assert-True ($packageEntries -notcontains 'private-root-evidence.txt') 'package included arbitrary root evidence'
    Assert-True (@($packageEntries | Where-Object { $_ -match '(?:^|/)_log(?:-archive)?\.md$' }).Count -eq 0) 'package included exempt friction logs'

    # Mutation helpers prepend records and reject non-forward -Set values.
    $helperRoot = Join-Path $tempRoot 'helper-fixtures'
    Write-Skill $helperRoot 'gamma' '1.0.0'
    $skillBump = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
        -SkillsRoot (Join-Path $helperRoot 'skills') -Skill gamma -Bump patch -Entry 'Compatible correction'
    Assert-True ($LASTEXITCODE -eq 0) "skill bump helper failed: $($skillBump -join ' ')"
    $gammaRaw = Get-Content -Raw -LiteralPath (Join-Path $helperRoot 'skills\gamma\SKILL.md')
    Assert-True ($gammaRaw -match '(?m)^\s+version:\s*1\.0\.1\s*$') 'skill helper did not bump metadata.version'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $helperRoot 'skills\gamma\CHANGELOG.md')) -match '(?m)^- 1\.0\.1\b') 'skill helper did not prepend changelog entry'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
        -SkillsRoot (Join-Path $helperRoot 'skills') -Skill gamma -Set 0.9.0 -Entry 'downgrade' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'skill helper allowed a downgrade'

    $gammaSkillPath = Join-Path $helperRoot 'skills\gamma\SKILL.md'
    $gammaLogPath = Join-Path $helperRoot 'skills\gamma\CHANGELOG.md'
    $gammaBefore = Get-Content -Raw -LiteralPath $gammaSkillPath
    $lockedLog = [System.IO.File]::Open($gammaLogPath, 'Open', 'Read', 'None')
    try {
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
            -SkillsRoot (Join-Path $helperRoot 'skills') -Skill gamma -Bump patch -Entry 'locked failure' *> $null
        Assert-True ($LASTEXITCODE -eq 1) 'skill helper did not fail on locked second destination'
    }
    finally { $lockedLog.Dispose() }
    Assert-True ((Get-Content -Raw -LiteralPath $gammaSkillPath) -eq $gammaBefore) 'skill helper failed to roll back first destination'
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $gammaSkillPath) -Filter '*.tmp.*').Count -eq 0) 'skill helper left temp files after rollback'

    $epsilonDir = Join-Path $helperRoot 'skills\epsilon'
    Write-Utf8 (Join-Path $epsilonDir 'SKILL.md') "---`nname: epsilon`ndescription: `"Fixture.`"`nmetadata:`n  changelog: baseline`n---`n"
    Write-Utf8 (Join-Path $epsilonDir 'CHANGELOG.md') '# epsilon changelog'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
        -SkillsRoot (Join-Path $helperRoot 'skills') -Skill epsilon -Set 9.0.0 -Entry 'bad bootstrap' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'missing-version skill bypassed 0.1.0 bootstrap through -Set'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
        -SkillsRoot (Join-Path $helperRoot 'skills') -Skill epsilon -Bump patch -Entry 'Initial release' *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'missing-version skill did not bootstrap at 0.1.0'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $epsilonDir 'SKILL.md')) -match '(?m)^\s+version:\s*0\.1\.0$') 'bootstrap version was not 0.1.0'

    $zetaDir = Join-Path $helperRoot 'skills\zeta'
    Write-Utf8 (Join-Path $zetaDir 'SKILL.md') "---`nname: zeta`ndescription: `"Fixture.`"`nmetadata:`n  version: bananas`n---`n"
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
        -SkillsRoot (Join-Path $helperRoot 'skills') -Skill zeta -Bump patch -Entry 'bad metadata' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'malformed metadata.version was treated as missing'

    $etaDir = Join-Path $helperRoot 'skills\eta'
    Write-Utf8 (Join-Path $etaDir 'SKILL.md') "---`nname: eta`ndescription: `"Fixture.`"`nmetadata:`n  version: 1.0.0`n  version: 1.0.1`n---`n"
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
        -SkillsRoot (Join-Path $helperRoot 'skills') -Skill eta -Bump patch -Entry 'duplicate metadata' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'duplicate metadata.version keys were accepted'

    $thetaDir = Join-Path $helperRoot 'skills\theta'
    Write-Utf8 (Join-Path $thetaDir 'SKILL.md') "---`nname: theta`ndescription: `"Fixture.`"`nmetadata: { version: 1.2.3 }`n---`n"
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
        -SkillsRoot (Join-Path $helperRoot 'skills') -Skill theta -Bump patch -Entry 'inline metadata' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'inline metadata was rewritten instead of rejected'

    $iotaDir = Join-Path $helperRoot 'skills\iota'
    Write-Utf8 (Join-Path $iotaDir 'SKILL.md') "---`nname: iota`ndescription: `"Fixture.`"`nmetadata:`n  runtime:`n    version: 2.3.4`n---`n"
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
        -SkillsRoot (Join-Path $helperRoot 'skills') -Skill iota -Bump patch -Entry 'nested metadata' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'nested metadata version was rewritten instead of rejected'

    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
        -SkillsRoot (Join-Path $helperRoot 'skills') -Skill '..\gamma' -Bump patch -Entry 'traversal' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'skill helper accepted traversal in -Skill'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
        -SkillsRoot (Join-Path $helperRoot 'skills') -Skill $gammaSkillPath -Bump patch -Entry 'absolute path' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'skill helper accepted an absolute path in -Skill'

    $victimDir = Join-Path $helperRoot 'victim'
    Write-Utf8 (Join-Path $victimDir 'SKILL.md') "---`nname: linked`ndescription: `"Fixture.`"`nmetadata:`n  version: 1.0.0`n---`n"
    Write-Utf8 (Join-Path $victimDir 'CHANGELOG.md') "# linked changelog`n`n- 1.0.0 (2026-07-12): current`n"
    $junctionPath = Join-Path $helperRoot 'skills\linked'
    New-Item -ItemType Junction -Path $junctionPath -Target $victimDir | Out-Null
    $victimBefore = Get-Content -Raw -LiteralPath (Join-Path $victimDir 'SKILL.md')
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
        -SkillsRoot (Join-Path $helperRoot 'skills') -Skill linked -Bump patch -Entry 'junction escape' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'skill helper accepted a junction-backed skill folder'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $victimDir 'SKILL.md')) -eq $victimBefore) 'junction rejection mutated the target skill'
    Remove-Item -LiteralPath $junctionPath -Force

    $canonicalRoot = Join-Path $helperRoot 'canonical-skills'
    Write-Utf8 (Join-Path $canonicalRoot 'mirror-victim\SKILL.md') "---`nname: mirror-victim`ndescription: `"Fixture.`"`nmetadata:`n  version: 1.0.0`n---`n"
    Write-Utf8 (Join-Path $canonicalRoot 'mirror-victim\CHANGELOG.md') "# mirror-victim changelog`n`n- 1.0.0 (2026-07-12): current`n"
    $mirrorRoot = Join-Path $helperRoot 'skills-mirror'
    New-Item -ItemType Junction -Path $mirrorRoot -Target $canonicalRoot | Out-Null
    $mirrorVictimPath = Join-Path $canonicalRoot 'mirror-victim\SKILL.md'
    $mirrorVictimBefore = Get-Content -Raw -LiteralPath $mirrorVictimPath
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
        -SkillsRoot $mirrorRoot -Skill mirror-victim -Bump patch -Entry 'root junction escape' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'skill helper accepted a junction-backed SkillsRoot'
    Assert-True ((Get-Content -Raw -LiteralPath $mirrorVictimPath) -eq $mirrorVictimBefore) 'SkillsRoot junction rejection mutated the canonical target'
    Remove-Item -LiteralPath $mirrorRoot -Force

    $unicodeDir = Join-Path $helperRoot 'skills\unicode'
    Write-Utf8 (Join-Path $unicodeDir 'SKILL.md') "---`nname: unicode`ndescription: `"Fixture.`"`nmetadata:`n  version: 1.2٢.3`n---`n"
    Write-Utf8 (Join-Path $unicodeDir 'CHANGELOG.md') "# unicode changelog`n`n- 1.2٢.3 (2026-07-12): invalid`n"
    $unicodeSkillBefore = Get-Content -Raw -LiteralPath (Join-Path $unicodeDir 'SKILL.md')
    $unicodeSkillJson = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
        -SkillsRoot (Join-Path $helperRoot 'skills') -Skill unicode -Bump patch -Entry 'unicode digit'
    Assert-True ($LASTEXITCODE -eq 1) 'skill helper accepted a Unicode digit in SemVer'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string](($unicodeSkillJson -join "`n") | ConvertFrom-Json).error)) 'skill Unicode SemVer failure was not JSON'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $unicodeDir 'SKILL.md')) -eq $unicodeSkillBefore) 'skill Unicode SemVer failure mutated SKILL.md'

    $kappaDir = Join-Path $helperRoot 'skills\kappa'
    Write-Skill $helperRoot 'kappa' '1.2.3'
    Write-Utf8 (Join-Path $kappaDir 'CHANGELOG.md') "# kappa changelog`n`n- 1.2.2 (2026-07-11): stale`n"
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
        -SkillsRoot (Join-Path $helperRoot 'skills') -Skill kappa -Bump patch -Entry 'mask stale history' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'skill helper accepted stale prior changelog history'

    $lambdaDir = Join-Path $helperRoot 'skills\lambda'
    Write-Skill $helperRoot 'lambda' '1.2.3'
    Remove-Item -LiteralPath (Join-Path $lambdaDir 'CHANGELOG.md') -Force
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-skill-version.ps1') `
        -SkillsRoot (Join-Path $helperRoot 'skills') -Skill lambda -Bump patch -Entry 'missing history' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'released skill helper accepted missing changelog history'

    Write-Manifests $helperRoot '1.0.0' 'initial'
    $pluginBump = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-plugin-version.ps1') `
        -PluginRoot (Join-Path $helperRoot '.claude-plugin') -Bump patch -Entry 'gamma 1.0.1'
    Assert-True ($LASTEXITCODE -eq 0) "plugin bump helper failed: $($pluginBump -join ' ')"
    $helperPlugin = Get-Content -Raw -LiteralPath (Join-Path $helperRoot '.claude-plugin\plugin.json') | ConvertFrom-Json
    Assert-True ([string]$helperPlugin.version -eq '1.0.1') 'plugin helper did not bump version'
    Assert-True ([string]$helperPlugin.metadata.changelog[0] -match '^1\.0\.1\s') 'plugin helper did not prepend changelog'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-plugin-version.ps1') `
        -PluginRoot (Join-Path $helperRoot '.claude-plugin') -Set 1.0.0 -Entry 'downgrade' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'plugin helper allowed a downgrade'

    $helperPluginPath = Join-Path $helperRoot '.claude-plugin\plugin.json'
    $helperMarketplacePath = Join-Path $helperRoot '.claude-plugin\marketplace.json'
    $pluginBefore = Get-Content -Raw -LiteralPath $helperPluginPath
    $lockedMarketplace = [System.IO.File]::Open($helperMarketplacePath, 'Open', 'Read', 'None')
    try {
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-plugin-version.ps1') `
            -PluginRoot (Join-Path $helperRoot '.claude-plugin') -Bump patch -Entry 'locked failure' *> $null
        Assert-True ($LASTEXITCODE -eq 1) 'plugin helper did not fail on locked second destination'
    }
    finally { $lockedMarketplace.Dispose() }
    Assert-True ((Get-Content -Raw -LiteralPath $helperPluginPath) -eq $pluginBefore) 'plugin helper failed to roll back first destination'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $helperRoot '.claude-plugin') -Filter '*.tmp.*').Count -eq 0) 'plugin helper left temp files after rollback'

    Write-Utf8 $helperPluginPath '{"name":"fixture","version":"1.0.1","metadata":{"changelog":["1.0.0 stale"]}}'
    Write-Utf8 $helperMarketplacePath '{"metadata":{"version":"1.0.1"},"plugins":[{"version":"1.0.1"}]}'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-plugin-version.ps1') `
        -PluginRoot (Join-Path $helperRoot '.claude-plugin') -Bump patch -Entry 'mask stale history' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'plugin helper accepted stale prior changelog history'

    Write-Utf8 $helperPluginPath '{"name":"fixture","version":"1.0.1","metadata":{}}'
    $shapeJson = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-plugin-version.ps1') `
        -PluginRoot (Join-Path $helperRoot '.claude-plugin') -Bump patch -Entry 'missing history'
    Assert-True ($LASTEXITCODE -eq 1) 'plugin helper accepted missing changelog structure'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string](($shapeJson -join "`n") | ConvertFrom-Json).error)) 'malformed plugin shape did not return JSON error'

    Write-Utf8 $helperPluginPath '{"name":"fixture","version":"1.0.1","metadata":{"changelog":["1.0.1"]}}'
    Write-Utf8 $helperMarketplacePath '{"metadata":{"version":"1.0.1"},"plugins":[{"version":"1.0.1"}]}'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-plugin-version.ps1') `
        -PluginRoot (Join-Path $helperRoot '.claude-plugin') -Bump patch -Entry 'missing prior summary' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'plugin helper accepted a summaryless current history entry'

    Write-Utf8 $helperPluginPath '{"name":"fixture","version":"0.9.0","version":"1.0.0","metadata":{"changelog":["1.0.0 current"]}}'
    Write-Utf8 $helperMarketplacePath '{"metadata":{"version":"1.0.0"},"plugins":[{"version":"1.0.0"}]}'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-plugin-version.ps1') `
        -PluginRoot (Join-Path $helperRoot '.claude-plugin') -Bump patch -Entry 'duplicate plugin key' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'plugin helper accepted duplicate plugin.version keys'

    Write-Utf8 $helperPluginPath '{"name":"fixture","version":"1.0.0","metadata":{"changelog":["1.0.0 current"]}}'
    Write-Utf8 $helperMarketplacePath '{"metadata":{"version":"0.9.0","version":"1.0.0"},"plugins":[{"version":"1.0.0"}]}'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-plugin-version.ps1') `
        -PluginRoot (Join-Path $helperRoot '.claude-plugin') -Bump patch -Entry 'duplicate market key' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'plugin helper accepted duplicate marketplace metadata.version keys'

    Write-Utf8 $helperMarketplacePath '{"metadata":{"version":"1.0.0"},"plugins":{"version":"1.0.0"}}'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-plugin-version.ps1') `
        -PluginRoot (Join-Path $helperRoot '.claude-plugin') -Bump patch -Entry 'object plugins' *> $null
    Assert-True ($LASTEXITCODE -eq 1) 'plugin helper accepted marketplace.plugins as an object'

    Write-Utf8 $helperPluginPath '{"name":"fixture","version":"1.2٢.3","metadata":{"changelog":["1.2٢.3 invalid"]}}'
    Write-Utf8 $helperMarketplacePath '{"metadata":{"version":"1.2٢.3"},"plugins":[{"version":"1.2٢.3"}]}'
    $unicodePluginBefore = Get-Content -Raw -LiteralPath $helperPluginPath
    $unicodePluginJson = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'bump-plugin-version.ps1') `
        -PluginRoot (Join-Path $helperRoot '.claude-plugin') -Bump patch -Entry 'unicode digit'
    Assert-True ($LASTEXITCODE -eq 1) 'plugin helper accepted a Unicode digit in SemVer'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string](($unicodePluginJson -join "`n") | ConvertFrom-Json).error)) 'plugin Unicode SemVer failure was not JSON'
    Assert-True ((Get-Content -Raw -LiteralPath $helperPluginPath) -eq $unicodePluginBefore) 'plugin Unicode SemVer failure mutated plugin.json'

    Write-Output 'PASS: versioning policy regression suite'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
