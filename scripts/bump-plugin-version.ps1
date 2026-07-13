# bump-plugin-version.ps1
# Deterministic plugin-level version bump for danny-skills.
#
# The plugin version lives in THREE fields that must always agree:
#   1. .claude-plugin/plugin.json          -> version
#   2. .claude-plugin/marketplace.json     -> metadata.version
#   3. .claude-plugin/marketplace.json     -> plugins[0].version
#
# -Check: verify the three fields match. Exit 0 on agreement; exit 1 printing all three on drift.
# Bump mode: verify agreement, compute the new version, update all three atomically
# (both files written to temp, then both moved over), and prepend the entry to
# plugin.json's metadata.changelog array (newest-first, "<version> <text>" shape,
# matching the existing entries).
#
# Usage:
#   pwsh -NoProfile -File scripts/bump-plugin-version.ps1 -Check
#   pwsh -NoProfile -File scripts/bump-plugin-version.ps1 -Bump patch -Entry "slug: what changed"
#   pwsh -NoProfile -File scripts/bump-plugin-version.ps1 -Set 1.0.0 -Entry "slug: what changed"
#
# Output: single JSON object on stdout:
#   check mode: {status, plugin_json_version, marketplace_metadata_version, marketplace_plugin_version}
#   bump mode:  {status, old_version, new_version, files_updated}

[CmdletBinding()]
param(
    [ValidateSet('patch', 'minor', 'major')]
    [string]$Bump,

    [string]$Set,

    [string]$Entry,

    [switch]$Check,

    # Override for testing only; defaults to <repo-root>/.claude-plugin resolved from this script's location.
    [string]$PluginRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message, [hashtable]$Extra = @{}) {
    $obj = [ordered]@{ status = 'error'; error = $Message }
    foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] }
    [pscustomobject]$obj | ConvertTo-Json -Compress | Write-Output
    exit 1
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-RequiredJsonProperty(
    [System.Text.Json.JsonElement]$Object,
    [string]$Name,
    [string]$Context
) {
    if ($Object.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
        Fail "$Context must be a JSON object."
    }
    $matches = [System.Collections.Generic.List[System.Text.Json.JsonElement]]::new()
    foreach ($property in $Object.EnumerateObject()) {
        if ($property.Name -ceq $Name) { $matches.Add($property.Value) }
    }
    if ($matches.Count -ne 1) {
        Fail "$Context must contain exactly one '$Name' property; found $($matches.Count)."
    }
    return $matches[0]
}

function Assert-JsonKind(
    [System.Text.Json.JsonElement]$Element,
    [System.Text.Json.JsonValueKind]$Kind,
    [string]$Context
) {
    if ($Element.ValueKind -ne $Kind) { Fail "$Context must be JSON $($Kind.ToString().ToLowerInvariant())." }
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

# --- Resolve paths -------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($PluginRoot)) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $PluginRoot = Join-Path $repoRoot '.claude-plugin'
}
$pluginJsonPath = Join-Path $PluginRoot 'plugin.json'
$marketplaceJsonPath = Join-Path $PluginRoot 'marketplace.json'
foreach ($p in @($pluginJsonPath, $marketplaceJsonPath)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        Fail "Required file not found: $p"
    }
}

# --- Read the three version fields ---------------------------------------------------
$pluginRaw = [System.IO.File]::ReadAllText($pluginJsonPath)
$marketplaceRaw = [System.IO.File]::ReadAllText($marketplaceJsonPath)
try { $pluginDocument = [System.Text.Json.JsonDocument]::Parse($pluginRaw) }
catch { Fail "plugin.json is not valid JSON: $($_.Exception.Message)" }
try { $marketplaceDocument = [System.Text.Json.JsonDocument]::Parse($marketplaceRaw) }
catch { $pluginDocument.Dispose(); Fail "marketplace.json is not valid JSON: $($_.Exception.Message)" }

$pluginRootElement = $pluginDocument.RootElement
$pluginVersionElement = Get-RequiredJsonProperty $pluginRootElement 'version' 'plugin.json root'
Assert-JsonKind $pluginVersionElement ([System.Text.Json.JsonValueKind]::String) 'plugin.json version'
$pluginMetadataElement = Get-RequiredJsonProperty $pluginRootElement 'metadata' 'plugin.json root'
Assert-JsonKind $pluginMetadataElement ([System.Text.Json.JsonValueKind]::Object) 'plugin.json metadata'
$pluginChangelogElement = Get-RequiredJsonProperty $pluginMetadataElement 'changelog' 'plugin.json metadata'
Assert-JsonKind $pluginChangelogElement ([System.Text.Json.JsonValueKind]::Array) 'plugin.json metadata.changelog'

$marketRootElement = $marketplaceDocument.RootElement
$marketMetadataElement = Get-RequiredJsonProperty $marketRootElement 'metadata' 'marketplace.json root'
Assert-JsonKind $marketMetadataElement ([System.Text.Json.JsonValueKind]::Object) 'marketplace.json metadata'
$marketMetadataVersionElement = Get-RequiredJsonProperty $marketMetadataElement 'version' 'marketplace.json metadata'
Assert-JsonKind $marketMetadataVersionElement ([System.Text.Json.JsonValueKind]::String) 'marketplace.json metadata.version'
$marketPluginsElement = Get-RequiredJsonProperty $marketRootElement 'plugins' 'marketplace.json root'
Assert-JsonKind $marketPluginsElement ([System.Text.Json.JsonValueKind]::Array) 'marketplace.json plugins'
if ($marketPluginsElement.GetArrayLength() -lt 1) { Fail 'marketplace.json plugins must contain at least one object.' }
$marketPluginElement = $marketPluginsElement[0]
Assert-JsonKind $marketPluginElement ([System.Text.Json.JsonValueKind]::Object) 'marketplace.json plugins[0]'
$marketPluginVersionElement = Get-RequiredJsonProperty $marketPluginElement 'version' 'marketplace.json plugins[0]'
Assert-JsonKind $marketPluginVersionElement ([System.Text.Json.JsonValueKind]::String) 'marketplace.json plugins[0].version'
$pluginDocument.Dispose()
$marketplaceDocument.Dispose()

try { $pluginObj = $pluginRaw | ConvertFrom-Json } catch { Fail "plugin.json is not valid JSON: $($_.Exception.Message)" }
try { $marketplaceObj = $marketplaceRaw | ConvertFrom-Json } catch { Fail "marketplace.json is not valid JSON: $($_.Exception.Message)" }

$pluginMetadata = Get-PropertyValue $pluginObj 'metadata'
$marketplaceMetadata = Get-PropertyValue $marketplaceObj 'metadata'
$marketplacePlugins = @(Get-PropertyValue $marketplaceObj 'plugins')
$v1 = [string](Get-PropertyValue $pluginObj 'version')
$v2 = [string](Get-PropertyValue $marketplaceMetadata 'version')
$v3 = if ($marketplacePlugins.Count -gt 0) { [string](Get-PropertyValue $marketplacePlugins[0] 'version') } else { '' }
$allMatch = ($v1 -eq $v2) -and ($v2 -eq $v3)
$strictSemVerPattern = '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$'
$validSemVer = $v1 -match $strictSemVerPattern -and $v2 -match $strictSemVerPattern -and $v3 -match $strictSemVerPattern
$changelogProperty = if ($pluginMetadata) { $pluginMetadata.PSObject.Properties['changelog'] } else { $null }
$existingHistory = @()
if ($changelogProperty -and $changelogProperty.Value -is [array]) { $existingHistory = @($changelogProperty.Value) }
$changelogAligned = $existingHistory.Count -gt 0 -and [string]$existingHistory[0] -match ('^' + [regex]::Escape($v1) + '\s+\S')

# --- Check mode ------------------------------------------------------------------------
if ($Check) {
    $result = [ordered]@{
        status                       = if ($allMatch -and $validSemVer -and $changelogAligned) { 'ok' } else { 'mismatch' }
        plugin_json_version          = $v1
        marketplace_metadata_version = $v2
        marketplace_plugin_version   = $v3
        valid_semver                 = $validSemVer
        changelog_aligned            = $changelogAligned
    }
    [pscustomobject]$result | ConvertTo-Json -Compress | Write-Output
    exit $(if ($allMatch -and $validSemVer -and $changelogAligned) { 0 } else { 1 })
}

# --- Validate bump-mode parameters -------------------------------------------------------
$hasBump = -not [string]::IsNullOrWhiteSpace($Bump)
$hasSet = -not [string]::IsNullOrWhiteSpace($Set)
if ($hasBump -eq $hasSet) {
    Fail "Specify exactly one of -Bump patch|minor|major or -Set x.y.z (or use -Check)."
}
if ($hasSet -and $Set -notmatch $strictSemVerPattern) {
    Fail "-Set value '$Set' is not a valid x.y.z semantic version."
}
if ([string]::IsNullOrWhiteSpace($Entry)) {
    Fail "-Entry is required in bump mode."
}
if ($Entry -match "`r|`n") {
    Fail "-Entry must be a single line (no newlines)."
}
if (-not $allMatch) {
    Fail "The three plugin version fields disagree; fix them before bumping." @{
        plugin_json_version          = $v1
        marketplace_metadata_version = $v2
        marketplace_plugin_version   = $v3
    }
}
if (-not $validSemVer) {
    Fail "Current version '$v1' is not a valid x.y.z semantic version."
}
if (-not $changelogAligned) {
    Fail "plugin.json metadata.changelog must be a non-empty array whose first entry starts with current version $v1."
}

# --- Compute new version -------------------------------------------------------------------
$oldVersion = $v1
if ($hasSet) {
    $newVersion = $Set
}
else {
    $parts = $oldVersion -split '\.'
    $major = [System.Numerics.BigInteger]::Parse($parts[0]); $minor = [System.Numerics.BigInteger]::Parse($parts[1]); $patch = [System.Numerics.BigInteger]::Parse($parts[2])
    switch ($Bump) {
        'major' { $major += [System.Numerics.BigInteger]::One; $minor = 0; $patch = 0 }
        'minor' { $minor += [System.Numerics.BigInteger]::One; $patch = 0 }
        'patch' { $patch += [System.Numerics.BigInteger]::One }
    }
    $newVersion = "$major.$minor.$patch"
}
if ((Compare-SemVer $newVersion $oldVersion) -le 0) {
    Fail "New version $newVersion must be greater than current version $oldVersion."
}

# --- Rewrite version fields via targeted text replacement (preserves file formatting) --------
$versionPattern = '("version"\s*:\s*)"' + [regex]::Escape($oldVersion) + '"'
$replacement = ('${1}"' + $newVersion + '"')

$newPluginRaw = [regex]::Replace($pluginRaw, $versionPattern, $replacement)
$pluginHits = ([regex]::Matches($pluginRaw, $versionPattern)).Count
if ($pluginHits -ne 1) {
    Fail "Expected exactly 1 version field match in plugin.json; found $pluginHits. Aborting without writes."
}

$newMarketplaceRaw = [regex]::Replace($marketplaceRaw, $versionPattern, $replacement)
$marketplaceHits = ([regex]::Matches($marketplaceRaw, $versionPattern)).Count
if ($marketplaceHits -ne 2) {
    Fail "Expected exactly 2 version field matches in marketplace.json; found $marketplaceHits. Aborting without writes."
}

# --- Append changelog entry to plugin.json's metadata.changelog array (newest-first) ---------
# Existing shape: "changelog": [ "<version> <text>", ... ] with entries indented 6 spaces.
$changelogAppended = $false
$hasChangelog = $changelogProperty -and $changelogProperty.Value -is [array]
if ($hasChangelog) {
    $entryJson = ("$newVersion $Entry" | ConvertTo-Json)  # produces a correctly escaped quoted JSON string
    $arrayOpenPattern = '("changelog"\s*:\s*\[)(\s*\r?\n)(\s*)'
    $m = [regex]::Match($newPluginRaw, $arrayOpenPattern)
    if ($m.Success) {
        # Multi-line array: insert the new entry as the first element, reusing the existing indent.
        $indent = $m.Groups[3].Value
        $insertion = $m.Groups[1].Value + $m.Groups[2].Value + $indent + $entryJson + ',' + $m.Groups[2].Value + $indent
        $newPluginRaw = $newPluginRaw.Substring(0, $m.Index) + $insertion + $newPluginRaw.Substring($m.Index + $m.Length)
        $changelogAppended = $true
    }
    else {
        # Inline (possibly empty) array: insert right after the opening bracket.
        $inlinePattern = '("changelog"\s*:\s*\[)'
        $mi = [regex]::Match($newPluginRaw, $inlinePattern)
        if ($mi.Success) {
            $suffix = if ($newPluginRaw.Substring($mi.Index + $mi.Length).TrimStart().StartsWith(']')) { '' } else { ', ' }
            $newPluginRaw = $newPluginRaw.Substring(0, $mi.Index + $mi.Length) + $entryJson + $suffix + $newPluginRaw.Substring($mi.Index + $mi.Length)
            $changelogAppended = $true
        }
    }
}
if (-not $changelogAppended) {
    Fail "plugin.json metadata.changelog is missing or could not accept a newest-first entry. Aborting without writes."
}

# --- Validate rewritten JSON before any write --------------------------------------------------
try { $checkPlugin = $newPluginRaw | ConvertFrom-Json } catch { Fail "Internal error: rewritten plugin.json is invalid JSON. Aborting without writes." }
try { $checkMarketplace = $newMarketplaceRaw | ConvertFrom-Json } catch { Fail "Internal error: rewritten marketplace.json is invalid JSON. Aborting without writes." }
if ([string]$checkPlugin.version -ne $newVersion -or
    [string]$checkMarketplace.metadata.version -ne $newVersion -or
    [string]$checkMarketplace.plugins[0].version -ne $newVersion) {
    Fail "Internal error: rewritten files do not all carry $newVersion. Aborting without writes."
}
if (@($checkPlugin.metadata.changelog).Count -eq 0 -or [string]$checkPlugin.metadata.changelog[0] -notmatch ('^' + [regex]::Escape($newVersion) + '(?:\s|$)')) {
    Fail "Internal error: plugin changelog was not prepended with $newVersion. Aborting without writes."
}

# --- Atomic write: both temp files first, then both moves --------------------------------------
$utf8 = [System.Text.UTF8Encoding]::new($false)
$pluginTmp = "$pluginJsonPath.tmp.$PID"
$marketplaceTmp = "$marketplaceJsonPath.tmp.$PID"
$originalPlugin = [System.IO.File]::ReadAllBytes($pluginJsonPath)
$originalMarketplace = [System.IO.File]::ReadAllBytes($marketplaceJsonPath)
try {
    [System.IO.File]::WriteAllText($pluginTmp, $newPluginRaw, $utf8)
    [System.IO.File]::WriteAllText($marketplaceTmp, $newMarketplaceRaw, $utf8)
    Move-Item -LiteralPath $pluginTmp -Destination $pluginJsonPath -Force
    Move-Item -LiteralPath $marketplaceTmp -Destination $marketplaceJsonPath -Force
}
catch {
    try { [System.IO.File]::WriteAllBytes($pluginJsonPath, $originalPlugin) } catch { }
    try { [System.IO.File]::WriteAllBytes($marketplaceJsonPath, $originalMarketplace) } catch { }
    Remove-Item -LiteralPath $pluginTmp, $marketplaceTmp -Force -ErrorAction SilentlyContinue
    Fail "Atomic plugin version update failed and original files were restored: $($_.Exception.Message)"
}
finally {
    Remove-Item -LiteralPath $pluginTmp, $marketplaceTmp -Force -ErrorAction SilentlyContinue
}

[pscustomobject]@{
    status              = 'ok'
    old_version         = $oldVersion
    new_version         = $newVersion
    files_updated       = @($pluginJsonPath, $marketplaceJsonPath)
    changelog_appended  = $changelogAppended
} | ConvertTo-Json -Compress | Write-Output
exit 0
