[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$BaseRef = "",
    [switch]$Snapshot,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$semverPattern = '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$'

function Add-Error([string]$Code, [string]$Message) {
    $errors.Add("${Code}: $Message") | Out-Null
}

if ([string]::IsNullOrWhiteSpace($BaseRef) -and -not $Snapshot) {
    Add-Error 'BASE_REF_REQUIRED' 'Pass -BaseRef <merge-target> for a release gate, or explicit -Snapshot for inventory-only validation.'
}
if (-not [string]::IsNullOrWhiteSpace($BaseRef) -and $Snapshot) {
    Add-Error 'VALIDATION_MODE_CONFLICT' 'Use either -BaseRef or -Snapshot, not both.'
}

function Invoke-Git {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $lines = & git -C $RepoRoot @Arguments 2>&1
    $code = $LASTEXITCODE
    if (-not $AllowFailure -and $code -ne 0) {
        throw "git $($Arguments -join ' ') failed:`n$($lines -join "`n")"
    }
    return [pscustomobject]@{ code = $code; lines = @($lines); text = ($lines -join "`n") }
}

function Get-FrontmatterText([string]$Text) {
    $match = [regex]::Match($Text, '\A---\r?\n(?<frontmatter>.*?)\r?\n---(?:\r?\n|\z)', 'Singleline')
    if ($match.Success) { return $match.Groups['frontmatter'].Value }
    return $null
}

function Get-SkillVersionFromText([string]$Text) {
    $frontmatter = Get-FrontmatterText $Text
    if ($null -eq $frontmatter) { return $null }
    $lines = @($frontmatter -split "`r?`n")
    $metadataLines = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^metadata\s*:') { $metadataLines += $i }
    }
    if ($metadataLines.Count -ne 1) { return $null }
    $metadataIndex = $metadataLines[0]
    if ($lines[$metadataIndex] -notmatch '^metadata:\s*$') { return $null }

    $versions = @()
    for ($i = $metadataIndex + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\S') { break }
        if ($lines[$i] -match '^  version:\s*"?([^"\s]+)"?\s*$') {
            $versions += $Matches[1]
        }
        elseif ($lines[$i] -match '^\s+version\s*:') {
            return $null
        }
    }
    if ($versions.Count -ne 1 -or $versions[0] -notmatch $semverPattern) { return $null }
    return [string]$versions[0]
}

function Get-SkillNameFromText([string]$Text) {
    $frontmatter = Get-FrontmatterText $Text
    if ($null -eq $frontmatter) { return $null }
    $matches = [regex]::Matches($frontmatter, '(?m)^name:\s*"?([^"\r\n]+)"?\s*$')
    if ($matches.Count -eq 1) { return $matches[0].Groups[1].Value.Trim() }
    return $null
}

function Get-ChangelogAnalysis([string]$Path) {
    $records = [System.Collections.Generic.List[object]]::new()
    $issues = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ records=@(); issues=@() }
    }
    $inFence = $false
    $activeExpanded = $null
    $lineNumber = 0
    foreach ($line in ([System.IO.File]::ReadAllText($Path) -split "`r?`n")) {
        $lineNumber++
        if ($line -match '^\s*(?:```|~~~)') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        $markerMatch = [regex]::Match($line, '^\s*(?<marker>#{1,6}|[-*+])\s+(?<payload>.*)$')
        $normalizedPayload = if ($markerMatch.Success) {
            ($markerMatch.Groups['payload'].Value -replace '[\[\]\*_`~]', '').Trim()
        } else { '' }
        if ($markerMatch.Success -and $normalizedPayload -match '(?i)^Unreleased(?:\s|[:;,.!?—-]|$)') {
            $issues.Add("unreleased:$lineNumber") | Out-Null
            continue
        }
        $recognized = [regex]::Match($line, '^(?<style>##|-)\s+(?<version>(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))(?<tail>\s.*)?$')
        if ($recognized.Success) {
            if ($null -ne $activeExpanded -and
                $recognized.Groups['style'].Value -eq '-' -and
                $recognized.Groups['version'].Value -eq $activeExpanded.version) {
                if ([string]::IsNullOrWhiteSpace($recognized.Groups['tail'].Value)) {
                    $issues.Add("expanded-detail-missing-summary:$lineNumber") | Out-Null
                }
                $activeExpanded.has_detail = $true
                continue
            }
            if ($null -ne $activeExpanded -and -not $activeExpanded.has_detail) {
                $issues.Add("expanded-record-missing-detail:$($activeExpanded.line)") | Out-Null
            }
            if ($recognized.Groups['style'].Value -eq '-' -and [string]::IsNullOrWhiteSpace($recognized.Groups['tail'].Value)) {
                $issues.Add("compact-record-missing-summary:$lineNumber") | Out-Null
            }
            $record = [pscustomobject]@{
                style=$recognized.Groups['style'].Value
                version=$recognized.Groups['version'].Value
                line=$lineNumber
                has_detail=($recognized.Groups['style'].Value -ne '##')
            }
            $records.Add($record) | Out-Null
            $activeExpanded = if ($record.style -eq '##') { $record } else { $null }
            continue
        }
        if ($markerMatch.Success -and $normalizedPayload -match '^(?:v)?[0-9]+\.[0-9]+\.[0-9]+') {
            $issues.Add("unsupported-version-record:$lineNumber") | Out-Null
            continue
        }
        if ($null -ne $activeExpanded -and $line -match '^-\s+\S') {
            $activeExpanded.has_detail = $true
        }
    }
    if ($null -ne $activeExpanded -and -not $activeExpanded.has_detail) {
        $issues.Add("expanded-record-missing-detail:$($activeExpanded.line)") | Out-Null
    }
    if ($inFence) { $issues.Add('unclosed-fence') | Out-Null }
    return [pscustomobject]@{ records=@($records); issues=@($issues) }
}

function Compare-SemVer([string]$Left, [string]$Right) {
    $leftParts = @($Left -split '\.' | ForEach-Object { [System.Numerics.BigInteger]::Parse($_) })
    $rightParts = @($Right -split '\.' | ForEach-Object { [System.Numerics.BigInteger]::Parse($_) })
    for ($i = 0; $i -lt 3; $i++) {
        $comparison = $leftParts[$i].CompareTo($rightParts[$i])
        if ($comparison -ne 0) { return $comparison }
    }
    return 0
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-RequiredJsonPropertyStrict(
    [System.Text.Json.JsonElement]$Object,
    [string]$Name,
    [string]$Context
) {
    if ($Object.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw "$Context must be an object" }
    $matches = [System.Collections.Generic.List[System.Text.Json.JsonElement]]::new()
    foreach ($property in $Object.EnumerateObject()) {
        if ($property.Name -ceq $Name) { $matches.Add($property.Value) }
    }
    if ($matches.Count -ne 1) { throw "$Context must contain exactly one '$Name' property; found $($matches.Count)" }
    return $matches[0]
}

$skillsRoot = Join-Path $RepoRoot 'skills'
if (-not (Test-Path -LiteralPath $skillsRoot -PathType Container)) {
    Add-Error 'SKILLS_ROOT_MISSING' $skillsRoot
}

$skillRecords = [ordered]@{}
if (Test-Path -LiteralPath $skillsRoot -PathType Container) {
    foreach ($dir in Get-ChildItem -LiteralPath $skillsRoot -Directory | Sort-Object Name) {
        $skillMd = Join-Path $dir.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $skillMd -PathType Leaf)) {
            Add-Error 'SKILL_MD_MISSING' $dir.Name
            continue
        }
        $raw = [System.IO.File]::ReadAllText($skillMd)
        $frontmatter = Get-FrontmatterText $raw
        if ($null -eq $frontmatter) {
            Add-Error 'SKILL_FRONTMATTER_INVALID' "$($dir.Name)/SKILL.md must begin with one closed YAML frontmatter block"
        }
        $declaredName = Get-SkillNameFromText $raw
        $version = Get-SkillVersionFromText $raw
        if ($declaredName -ne $dir.Name) {
            Add-Error 'SKILL_NAME_MISMATCH' "$($dir.Name) declares '$declaredName'"
        }
        if ([string]::IsNullOrWhiteSpace($version) -or $version -notmatch $semverPattern) {
            Add-Error 'SKILL_VERSION_INVALID' "$($dir.Name) has no numeric x.y.z metadata.version"
        }
        if ($raw -notmatch [regex]::Escape('../../references/deterministic-reference-policy.md')) {
            Add-Error 'SHARED_POLICY_MISSING' "$($dir.Name)/SKILL.md does not inherit the shared policy"
        }
        $changelogPath = Join-Path $dir.FullName 'CHANGELOG.md'
        if (-not (Test-Path -LiteralPath $changelogPath -PathType Leaf)) {
            Add-Error 'SKILL_CHANGELOG_MISSING' "$($dir.Name)/CHANGELOG.md"
        }
        elseif ($version) {
            $analysis = Get-ChangelogAnalysis $changelogPath
            $records = @($analysis.records)
            foreach ($issue in $analysis.issues) {
                if ($issue -like 'unreleased:*') {
                    Add-Error 'SKILL_CHANGELOG_UNRELEASED' "$($dir.Name) must bump once at finalization instead of retaining Unreleased ($issue)"
                }
                else {
                    Add-Error 'SKILL_CHANGELOG_STRUCTURE_INVALID' "$($dir.Name) $issue"
                }
            }
            $firstVersion = if ($records.Count -gt 0) { [string]$records[0].version } else { $null }
            if ($firstVersion -ne $version) {
                Add-Error 'SKILL_CHANGELOG_STALE' "$($dir.Name) current=$version first_changelog=$firstVersion"
            }
            $styles = @($records | ForEach-Object { $_.style } | Sort-Object -Unique)
            if ($styles.Count -gt 1) {
                Add-Error 'SKILL_CHANGELOG_STYLE_MIXED' "$($dir.Name) mixes compact and expanded version records"
            }
            $versionRecords = @($records | ForEach-Object { $_.version } | Where-Object { $_ -eq $version })
            if ($versionRecords.Count -ne 1) {
                Add-Error 'SKILL_CHANGELOG_DUPLICATE' "$($dir.Name) version=$version occurrences=$($versionRecords.Count)"
            }
            $duplicates = @($records | ForEach-Object { $_.version } | Group-Object | Where-Object Count -gt 1)
            if ($duplicates.Count -gt 0) {
                Add-Error 'SKILL_CHANGELOG_DUPLICATE' "$($dir.Name) duplicate_versions=$(($duplicates.Name) -join ',')"
            }
            for ($i = 1; $i -lt $records.Count; $i++) {
                if ((Compare-SemVer $records[$i - 1].version $records[$i].version) -le 0) {
                    Add-Error 'SKILL_CHANGELOG_ORDER' "$($dir.Name) $($records[$i - 1].version) must be newer than $($records[$i].version)"
                }
            }
        }
        $skillRecords[$dir.Name] = [pscustomobject]@{
            name = $dir.Name; version = $version; skill_md = $skillMd; changelog = $changelogPath
        }
    }
}

$pluginPath = Join-Path $RepoRoot '.claude-plugin\plugin.json'
$marketplacePath = Join-Path $RepoRoot '.claude-plugin\marketplace.json'
$plugin = $null
$marketplace = $null
try {
    $pluginRaw = Get-Content -Raw -LiteralPath $pluginPath
    $plugin = $pluginRaw | ConvertFrom-Json
    $pluginDoc = [System.Text.Json.JsonDocument]::Parse($pluginRaw)
    try {
        $rootElement = $pluginDoc.RootElement
        $versionElement = Get-RequiredJsonPropertyStrict $rootElement 'version' 'plugin.json root'
        if ($versionElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw 'plugin.json version must be a string' }
        $metadataElement = Get-RequiredJsonPropertyStrict $rootElement 'metadata' 'plugin.json root'
        $changelogElement = Get-RequiredJsonPropertyStrict $metadataElement 'changelog' 'plugin.json metadata'
        if ($changelogElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { throw 'plugin.json metadata.changelog must be an array' }
    }
    finally { $pluginDoc.Dispose() }
}
catch { Add-Error 'PLUGIN_JSON_INVALID' $_.Exception.Message }
try {
    $marketplaceRaw = Get-Content -Raw -LiteralPath $marketplacePath
    $marketplace = $marketplaceRaw | ConvertFrom-Json
    $marketDoc = [System.Text.Json.JsonDocument]::Parse($marketplaceRaw)
    try {
        $rootElement = $marketDoc.RootElement
        $metadataElement = Get-RequiredJsonPropertyStrict $rootElement 'metadata' 'marketplace.json root'
        $metadataVersionElement = Get-RequiredJsonPropertyStrict $metadataElement 'version' 'marketplace.json metadata'
        if ($metadataVersionElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw 'marketplace metadata.version must be a string' }
        $pluginsElement = Get-RequiredJsonPropertyStrict $rootElement 'plugins' 'marketplace.json root'
        if ($pluginsElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array -or $pluginsElement.GetArrayLength() -lt 1) {
            throw 'marketplace plugins must be a non-empty array'
        }
        $firstPluginElement = $pluginsElement[0]
        $marketPluginVersionElement = Get-RequiredJsonPropertyStrict $firstPluginElement 'version' 'marketplace.json plugins[0]'
        if ($marketPluginVersionElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw 'marketplace plugins[0].version must be a string' }
    }
    finally { $marketDoc.Dispose() }
}
catch { Add-Error 'MARKETPLACE_JSON_INVALID' $_.Exception.Message }

$pluginVersion = [string](Get-PropertyValue $plugin 'version')
$marketMetadata = Get-PropertyValue $marketplace 'metadata'
$marketPlugins = @(Get-PropertyValue $marketplace 'plugins')
$marketMetadataVersion = [string](Get-PropertyValue $marketMetadata 'version')
$marketPluginVersion = if ($marketPlugins.Count -gt 0) { [string](Get-PropertyValue $marketPlugins[0] 'version') } else { '' }
foreach ($pair in @(
    @{ name='plugin.json'; value=$pluginVersion },
    @{ name='marketplace metadata'; value=$marketMetadataVersion },
    @{ name='marketplace plugin'; value=$marketPluginVersion }
)) {
    if ($pair.value -notmatch $semverPattern) {
        Add-Error 'PLUGIN_VERSION_INVALID' "$($pair.name)='$($pair.value)'"
    }
}
if ($pluginVersion -ne $marketMetadataVersion -or $pluginVersion -ne $marketPluginVersion) {
    Add-Error 'PLUGIN_VERSION_DRIFT' "plugin=$pluginVersion marketplace_metadata=$marketMetadataVersion marketplace_plugin=$marketPluginVersion"
}
$history = @()
if ($plugin) {
    $pluginMetadata = Get-PropertyValue $plugin 'metadata'
    $history = @(Get-PropertyValue $pluginMetadata 'changelog')
    if ($history.Count -eq 0 -or [string]$history[0] -notmatch ('^' + [regex]::Escape($pluginVersion) + '(?:\s|$)')) {
        Add-Error 'PLUGIN_CHANGELOG_STALE' "first plugin changelog entry must start with $pluginVersion"
    }
    $historyVersions = @()
    foreach ($entry in $history) {
        $match = [regex]::Match([string]$entry, '^((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\s+\S')
        if (-not $match.Success) {
            Add-Error 'PLUGIN_CHANGELOG_INVALID' "entry does not begin with strict SemVer: $entry"
            continue
        }
        $historyVersions += $match.Groups[1].Value
    }
    $currentOccurrences = @($historyVersions | Where-Object { $_ -eq $pluginVersion }).Count
    if ($currentOccurrences -ne 1) {
        Add-Error 'PLUGIN_CHANGELOG_DUPLICATE' "current=$pluginVersion occurrences=$currentOccurrences"
    }
    for ($i = 1; $i -lt $historyVersions.Count; $i++) {
        # Historical releases may have multiple detail rows with the same version,
        # but a later entry may never be newer than the entry above it.
        if ((Compare-SemVer $historyVersions[$i - 1] $historyVersions[$i]) -lt 0) {
            Add-Error 'PLUGIN_CHANGELOG_ORDER' "$($historyVersions[$i - 1]) appears before newer $($historyVersions[$i])"
        }
    }
}

$changedSkills = @()
$newSkills = @()
$removedSkills = @()
$changedPaths = @()
$distributableChanges = @()
$sharedChanges = @()
$releaseEntries = @()
$sharedOwners = $null
$sharedOwnersPath = Join-Path $RepoRoot 'references\shared-component-owners.json'
try { $sharedOwners = Get-Content -Raw -LiteralPath $sharedOwnersPath | ConvertFrom-Json }
catch { Add-Error 'SHARED_OWNER_MAP_INVALID' $_.Exception.Message }
if (-not [string]::IsNullOrWhiteSpace($BaseRef)) {
    $baseProbe = Invoke-Git -Arguments @('rev-parse', '--verify', "$BaseRef`^{commit}") -AllowFailure
    if ($baseProbe.code -ne 0) {
        Add-Error 'BASE_REF_INVALID' $BaseRef
    }
    else {
        $baseCommit = $baseProbe.text.Trim()
        $headProbe = Invoke-Git -Arguments @('rev-parse', 'HEAD')
        $headCommit = $headProbe.text.Trim()
        $branchProbe = Invoke-Git -Arguments @('branch', '--show-current')
        $branch = $branchProbe.text.Trim()
        if ([string]::IsNullOrWhiteSpace($branch)) {
            Add-Error 'BRANCH_INVALID' 'release validation requires a named branch'
        }
        elseif ($branch -ne 'main') {
            $mainProbe = Invoke-Git -Arguments @('rev-parse', '--verify', 'main^{commit}') -AllowFailure
            if ($mainProbe.code -ne 0) {
                Add-Error 'MERGE_TARGET_INVALID' 'local main does not resolve'
            }
            else {
                $mainCommit = $mainProbe.text.Trim()
                if ($baseCommit -ne $mainCommit) {
                    Add-Error 'BASE_REF_NOT_MAIN' "$BaseRef resolves to $baseCommit; feature branches must compare against local main $mainCommit"
                }
                $ancestorProbe = Invoke-Git -Arguments @('merge-base', '--is-ancestor', $mainCommit, $headCommit) -AllowFailure
                if ($ancestorProbe.code -ne 0) {
                    Add-Error 'MAIN_NOT_ANCESTOR' 'local main must be an ancestor of the feature-branch HEAD before release validation'
                }
            }
        }
        else {
            $workingProbe = Invoke-Git -Arguments @('status', '--porcelain', '--untracked-files=normal')
            $hasWorkingChanges = @($workingProbe.lines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0
            if ($hasWorkingChanges) {
                if ($baseCommit -ne $headCommit) {
                    Add-Error 'BASE_REF_MAIN_DIRTY' "dirty main must compare working-tree changes against HEAD ($headCommit)"
                }
            }
            else {
                if ($baseCommit -eq $headCommit) {
                    Add-Error 'BASE_REF_SELF' 'clean main cannot validate against HEAD because that proves no release delta'
                }
                $latestPluginCommit = (Invoke-Git -Arguments @('log', '-1', '--format=%H', '--', '.claude-plugin/plugin.json')).text.Trim()
                if ($latestPluginCommit -ne $headCommit) {
                    Add-Error 'RELEASE_COMMIT_NOT_HEAD' "clean main HEAD must be the commit that established plugin $pluginVersion; latest plugin commit is $latestPluginCommit"
                }
                $expectedBase = ''
                foreach ($candidate in (Invoke-Git -Arguments @('rev-list', 'HEAD', '--', '.claude-plugin/plugin.json')).lines) {
                    $candidatePlugin = Invoke-Git -Arguments @('show', "$candidate`:.claude-plugin/plugin.json") -AllowFailure
                    if ($candidatePlugin.code -ne 0) { continue }
                    try { $candidateVersion = [string](($candidatePlugin.text | ConvertFrom-Json).version) }
                    catch { continue }
                    if ($candidateVersion -ne $pluginVersion) { $expectedBase = [string]$candidate; break }
                }
                if ([string]::IsNullOrWhiteSpace($expectedBase)) {
                    Add-Error 'PRIOR_RELEASE_BASE_MISSING' "could not locate the release before plugin $pluginVersion"
                }
                elseif ($baseCommit -ne $expectedBase) {
                    Add-Error 'BASE_REF_RELEASE_BOUNDARY' "$BaseRef resolves to $baseCommit; expected prior release boundary $expectedBase"
                }
            }
        }
        $diff = Invoke-Git -Arguments @('diff', '--name-only', $BaseRef, '--')
        $untracked = Invoke-Git -Arguments @('ls-files', '--others', '--exclude-standard')
        $changedPaths = @($diff.lines + $untracked.lines | ForEach-Object { ([string]$_).Trim().Replace('\', '/') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

        $runtimeSkillPaths = @($changedPaths | Where-Object {
            $_ -match '^skills/([^/]+)/' -and $_ -notmatch '^skills/[^/]+/(?:_log(?:-archive)?\.md|CHANGELOG\.md)$'
        })
        $changedSkills = @($runtimeSkillPaths | ForEach-Object {
            if ($_ -match '^skills/([^/]+)/') { $Matches[1] }
        } | Sort-Object -Unique)

        foreach ($skill in $changedSkills) {
            if (-not $skillRecords.Contains($skill)) {
                $baseSkill = Invoke-Git -Arguments @('show', "${BaseRef}:skills/$skill/SKILL.md") -AllowFailure
                if ($baseSkill.code -eq 0) { $removedSkills += $skill }
                else { Add-Error 'SKILL_INVALID' "$skill changed but has no current valid skill record" }
                continue
            }
            $baseSkill = Invoke-Git -Arguments @('show', "${BaseRef}:skills/$skill/SKILL.md") -AllowFailure
            if ($baseSkill.code -ne 0) {
                $newSkills += $skill
                if ($skillRecords[$skill].version -ne '0.1.0') {
                    Add-Error 'NEW_SKILL_VERSION_INVALID' "$skill must start at 0.1.0, found $($skillRecords[$skill].version)"
                }
                continue
            }
            $baseVersion = Get-SkillVersionFromText $baseSkill.text
            $currentVersion = [string]$skillRecords[$skill].version
            if (-not $baseVersion -or -not $currentVersion -or (Compare-SemVer $currentVersion $baseVersion) -le 0) {
                Add-Error 'SKILL_VERSION_NOT_BUMPED' "$skill base=$baseVersion current=$currentVersion"
            }
        }

        $distributableChanges = @($changedPaths | Where-Object {
            ($_ -match '^(skills|scripts|references|assets)/' -and
                $_ -notmatch '^skills/[^/]+/(?:_log(?:-archive)?\.md|CHANGELOG\.md)$') -or
            $_ -match '^\.claude-plugin/' -or
            $_ -eq 'tools/build-plugin.ps1'
        })
        $sharedChanges = @($changedPaths | Where-Object {
            $_ -match '^(scripts|references|assets)/' -or $_ -eq 'tools/build-plugin.ps1'
        })
        if ($distributableChanges.Count -gt 0 -and $pluginVersion -match $semverPattern) {
            $basePlugin = Invoke-Git -Arguments @('show', "${BaseRef}:.claude-plugin/plugin.json") -AllowFailure
            if ($basePlugin.code -ne 0) {
                Add-Error 'BASE_PLUGIN_MISSING' $BaseRef
            }
            else {
                try { $basePluginVersion = [string](($basePlugin.text | ConvertFrom-Json).version) }
                catch { $basePluginVersion = ''; Add-Error 'BASE_PLUGIN_INVALID' $_.Exception.Message }
                if ($basePluginVersion -notmatch $semverPattern) {
                    Add-Error 'BASE_PLUGIN_INVALID' "version='$basePluginVersion'"
                }
                elseif ((Compare-SemVer $pluginVersion $basePluginVersion) -le 0) {
                    Add-Error 'PLUGIN_VERSION_NOT_BUMPED' "base=$basePluginVersion current=$pluginVersion"
                }
                elseif ($basePluginVersion) {
                    $baseParts = $basePluginVersion -split '\.'
                    $currentParts = $pluginVersion -split '\.'
                    $baseMajor = [System.Numerics.BigInteger]::Parse($baseParts[0])
                    $baseMinor = [System.Numerics.BigInteger]::Parse($baseParts[1])
                    $currentMajor = [System.Numerics.BigInteger]::Parse($currentParts[0])
                    $currentMinor = [System.Numerics.BigInteger]::Parse($currentParts[1])
                    if ($newSkills.Count -gt 0 -and $currentMajor -eq $baseMajor -and $currentMinor -le $baseMinor) {
                        Add-Error 'PLUGIN_NEW_SKILL_MINOR_REQUIRED' "new=$($newSkills -join ',') base=$basePluginVersion current=$pluginVersion"
                    }
                    if ($removedSkills.Count -gt 0 -and $currentMajor -le $baseMajor) {
                        Add-Error 'PLUGIN_REMOVAL_MAJOR_REQUIRED' "removed=$($removedSkills -join ',') base=$basePluginVersion current=$pluginVersion"
                    }

                    $baseHistoryFound = $false
                    foreach ($entry in $history) {
                        if ([string]$entry -match ('^' + [regex]::Escape($basePluginVersion) + '(?:\s|$)')) {
                            $baseHistoryFound = $true
                            break
                        }
                        $releaseEntries += [string]$entry
                    }
                    if (-not $baseHistoryFound) {
                        Add-Error 'BASE_PLUGIN_HISTORY_MISSING' "plugin changelog has no $basePluginVersion boundary"
                    }
                    foreach ($skill in @($changedSkills | Where-Object { $removedSkills -notcontains $_ })) {
                        $skillVersion = [string]$skillRecords[$skill].version
                        $coveragePattern = '(?i)(?:^|\W)' + [regex]::Escape($skill) + '\s+' + [regex]::Escape($skillVersion) + '(?:\W|$)'
                        if (@($releaseEntries | Where-Object { $_ -match $coveragePattern }).Count -eq 0) {
                            Add-Error 'PLUGIN_CHANGELOG_SKILL_MISSING' "$skill $skillVersion is absent from release entries newer than $basePluginVersion"
                        }
                    }
                    foreach ($skill in $removedSkills) {
                        $removalPattern = '(?i)(?:^|\W)' + [regex]::Escape($skill) + '\s+(?:removed|renamed)(?:\W|$)'
                        if (@($releaseEntries | Where-Object { $_ -match $removalPattern }).Count -eq 0) {
                            Add-Error 'PLUGIN_CHANGELOG_REMOVAL_MISSING' "$skill removal/rename is absent from release entries"
                        }
                    }
                    foreach ($path in $sharedChanges) {
                        $declaration = if ($sharedOwners) { $sharedOwners.PSObject.Properties[$path] } else { $null }
                        if ($null -eq $declaration) {
                            Add-Error 'SHARED_IMPACT_UNDECLARED' "$path has no references/shared-component-owners.json entry"
                            continue
                        }
                        $consumers = @((Get-PropertyValue $declaration.Value 'consumers'))
                        $summaryToken = [string](Get-PropertyValue $declaration.Value 'summary_token')
                        if ($consumers.Count -eq 0 -and [string]::IsNullOrWhiteSpace($summaryToken)) {
                            Add-Error 'SHARED_IMPACT_EMPTY' "$path must declare at least one consumer or a non-empty summary token"
                        }
                        foreach ($consumer in $consumers) {
                            if ($changedSkills -notcontains [string]$consumer) {
                                Add-Error 'SHARED_CONSUMER_NOT_BUMPED' "$path requires $consumer"
                            }
                        }
                        if (-not [string]::IsNullOrWhiteSpace($summaryToken) -and
                            @($releaseEntries | Where-Object { $_ -match [regex]::Escape($summaryToken) }).Count -eq 0) {
                            Add-Error 'PLUGIN_CHANGELOG_SHARED_MISSING' "$path requires summary token '$summaryToken'"
                        }
                    }
                }
            }
        }
    }
}

$result = [pscustomobject]@{
    pass = ($errors.Count -eq 0)
    repo_root = $RepoRoot
    base_ref = if ($BaseRef) { $BaseRef } else { $null }
    mode = if ($Snapshot) { 'snapshot' } else { 'release' }
    skill_count = $skillRecords.Count
    plugin_version = $pluginVersion
    changed_skills = @($changedSkills)
    new_skills = @($newSkills)
    removed_skills = @($removedSkills)
    changed_paths = @($changedPaths)
    distributable_changes = @($distributableChanges)
    shared_changes = @($sharedChanges)
    release_entries = @($releaseEntries)
    errors = @($errors)
    warnings = @($warnings)
}

if ($Json) { $result | ConvertTo-Json -Depth 6 }
else {
    if ($result.pass) { Write-Output "PASS: versioning policy ($($result.skill_count) skills, plugin $pluginVersion)" }
    else { Write-Output ("FAIL: versioning policy`n- " + ($result.errors -join "`n- ")) }
}
if (-not $result.pass) { exit 1 }
