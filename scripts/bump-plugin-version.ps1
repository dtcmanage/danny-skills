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
try { $pluginObj = $pluginRaw | ConvertFrom-Json } catch { Fail "plugin.json is not valid JSON: $($_.Exception.Message)" }
try { $marketplaceObj = $marketplaceRaw | ConvertFrom-Json } catch { Fail "marketplace.json is not valid JSON: $($_.Exception.Message)" }

$v1 = [string]$pluginObj.version
$v2 = [string]$marketplaceObj.metadata.version
$v3 = [string]$marketplaceObj.plugins[0].version
$allMatch = ($v1 -eq $v2) -and ($v2 -eq $v3)

# --- Check mode ------------------------------------------------------------------------
if ($Check) {
    $result = [ordered]@{
        status                       = if ($allMatch) { 'ok' } else { 'mismatch' }
        plugin_json_version          = $v1
        marketplace_metadata_version = $v2
        marketplace_plugin_version   = $v3
    }
    [pscustomobject]$result | ConvertTo-Json -Compress | Write-Output
    exit $(if ($allMatch) { 0 } else { 1 })
}

# --- Validate bump-mode parameters -------------------------------------------------------
$hasBump = -not [string]::IsNullOrWhiteSpace($Bump)
$hasSet = -not [string]::IsNullOrWhiteSpace($Set)
if ($hasBump -eq $hasSet) {
    Fail "Specify exactly one of -Bump patch|minor|major or -Set x.y.z (or use -Check)."
}
if ($hasSet -and $Set -notmatch '^\d+\.\d+\.\d+$') {
    Fail "-Set value '$Set' is not a valid x.y.z semantic version."
}
if ([string]::IsNullOrWhiteSpace($Entry)) {
    Fail "-Entry is required in bump mode."
}
if (-not $allMatch) {
    Fail "The three plugin version fields disagree; fix them before bumping." @{
        plugin_json_version          = $v1
        marketplace_metadata_version = $v2
        marketplace_plugin_version   = $v3
    }
}
if ($v1 -notmatch '^\d+\.\d+\.\d+$') {
    Fail "Current version '$v1' is not a valid x.y.z semantic version."
}

# --- Compute new version -------------------------------------------------------------------
$oldVersion = $v1
if ($hasSet) {
    $newVersion = $Set
}
else {
    $parts = $oldVersion -split '\.'
    $major = [int]$parts[0]; $minor = [int]$parts[1]; $patch = [int]$parts[2]
    switch ($Bump) {
        'major' { $major++; $minor = 0; $patch = 0 }
        'minor' { $minor++; $patch = 0 }
        'patch' { $patch++ }
    }
    $newVersion = "$major.$minor.$patch"
}
if ($newVersion -eq $oldVersion) {
    Fail "New version $newVersion equals current version $oldVersion; nothing to do."
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
$hasChangelog = ($null -ne ($pluginObj.metadata.PSObject.Properties['changelog'])) -and ($pluginObj.metadata.changelog -is [array])
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

# --- Validate rewritten JSON before any write --------------------------------------------------
try { $checkPlugin = $newPluginRaw | ConvertFrom-Json } catch { Fail "Internal error: rewritten plugin.json is invalid JSON. Aborting without writes." }
try { $checkMarketplace = $newMarketplaceRaw | ConvertFrom-Json } catch { Fail "Internal error: rewritten marketplace.json is invalid JSON. Aborting without writes." }
if ([string]$checkPlugin.version -ne $newVersion -or
    [string]$checkMarketplace.metadata.version -ne $newVersion -or
    [string]$checkMarketplace.plugins[0].version -ne $newVersion) {
    Fail "Internal error: rewritten files do not all carry $newVersion. Aborting without writes."
}

# --- Atomic write: both temp files first, then both moves --------------------------------------
$utf8 = [System.Text.UTF8Encoding]::new($false)
$pluginTmp = "$pluginJsonPath.tmp.$PID"
$marketplaceTmp = "$marketplaceJsonPath.tmp.$PID"
[System.IO.File]::WriteAllText($pluginTmp, $newPluginRaw, $utf8)
[System.IO.File]::WriteAllText($marketplaceTmp, $newMarketplaceRaw, $utf8)
Move-Item -LiteralPath $pluginTmp -Destination $pluginJsonPath -Force
Move-Item -LiteralPath $marketplaceTmp -Destination $marketplaceJsonPath -Force

[pscustomobject]@{
    status              = 'ok'
    old_version         = $oldVersion
    new_version         = $newVersion
    files_updated       = @($pluginJsonPath, $marketplaceJsonPath)
    changelog_appended  = $changelogAppended
} | ConvertTo-Json -Compress | Write-Output
exit 0
