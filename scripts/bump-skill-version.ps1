# bump-skill-version.ps1
# Deterministic per-skill version bump + changelog append for danny-skills.
#
# Parses skills/<Skill>/SKILL.md YAML frontmatter, bumps metadata.version
# (bootstrapping a missing version directly at 0.1.0), and prepends one dated entry to
# skills/<Skill>/CHANGELOG.md (created with a one-line header if missing).
# Both outputs are staged to temp files before either replacement.
#
# Usage:
#   pwsh -NoProfile -File scripts/bump-skill-version.ps1 -Skill dt-tune -Bump patch -Entry "one-line changelog"
#   pwsh -NoProfile -File scripts/bump-skill-version.ps1 -Skill dt-tune -Set 1.2.0 -Entry "one-line changelog"
#
# Output: single JSON object on stdout:
#   {status, skill, old_version, new_version, changelog_path, bootstrapped}

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Skill,

    [ValidateSet('patch', 'minor', 'major')]
    [string]$Bump,

    [string]$Set,

    [Parameter(Mandatory = $true)]
    [string]$Entry,

    # Override for testing only; defaults to <repo-root>/skills resolved from this script's location.
    [string]$SkillsRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    [pscustomobject]@{ status = 'error'; error = $Message } | ConvertTo-Json -Compress | Write-Output
    exit 1
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

function Get-FirstChangelogVersion([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $inFence = $false
    foreach ($line in ([System.IO.File]::ReadAllText($Path) -split "`r?`n")) {
        if ($line -match '^\s*(?:```|~~~)') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        $match = [regex]::Match($line, '^(?:##|-)\s+((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))(?:\s|$)')
        if ($match.Success) { return $match.Groups[1].Value }
    }
    return $null
}

# --- Validate parameter combination -------------------------------------------------
$hasBump = -not [string]::IsNullOrWhiteSpace($Bump)
$hasSet = -not [string]::IsNullOrWhiteSpace($Set)
if ($hasBump -eq $hasSet) {
    Fail "Specify exactly one of -Bump patch|minor|major or -Set x.y.z."
}
if ($hasSet -and $Set -notmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$') {
    Fail "-Set value '$Set' is not a valid x.y.z semantic version."
}
if ([string]::IsNullOrWhiteSpace($Entry)) {
    Fail "-Entry must be a non-empty one-line changelog entry."
}
if ($Entry -match "`r|`n") {
    Fail "-Entry must be a single line (no newlines)."
}

# --- Resolve paths -------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($SkillsRoot)) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $SkillsRoot = Join-Path $repoRoot 'skills'
}
if ($Skill -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
    Fail "-Skill must be one lowercase kebab-case folder name, not a path: '$Skill'."
}
$skillsRootItem = Get-Item -LiteralPath $SkillsRoot -Force
if (($skillsRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    Fail "Refusing to edit through a junction or symbolic-link SkillsRoot; use the canonical repo skills folder."
}
$SkillsRoot = (Resolve-Path -LiteralPath $SkillsRoot).Path
$skillDir = Join-Path $SkillsRoot $Skill
$skillMd = Join-Path $skillDir 'SKILL.md'
if (-not (Test-Path -LiteralPath $skillDir -PathType Container)) {
    Fail "Unknown skill folder: '$Skill' (no directory at $skillDir)."
}
$skillItem = Get-Item -LiteralPath $skillDir -Force
if (($skillItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    Fail "Refusing to edit skill '$Skill' through a junction or symbolic-link mirror; run the helper against the canonical repo folder."
}
$skillDir = (Resolve-Path -LiteralPath $skillDir).Path
if ((Split-Path -Parent $skillDir) -ne $SkillsRoot) {
    Fail "Resolved skill folder escapes SkillsRoot: $skillDir"
}
if (-not (Test-Path -LiteralPath $skillMd -PathType Leaf)) {
    Fail "Skill folder '$Skill' has no SKILL.md at $skillMd."
}

# --- Parse frontmatter ----------------------------------------------------------------
$raw = [System.IO.File]::ReadAllText($skillMd)
$lines = $raw -split "`r?`n"
if ($lines.Count -lt 2 -or $lines[0].Trim() -ne '---') {
    Fail "SKILL.md at $skillMd does not start with a '---' YAML frontmatter delimiter."
}
$closeIndex = -1
for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq '---') { $closeIndex = $i; break }
}
if ($closeIndex -lt 0) {
    Fail "SKILL.md at $skillMd has no closing '---' frontmatter delimiter."
}

# Locate exactly one supported top-level metadata: block and its direct-child
# metadata.version. Reject inline metadata and nested version keys so the helper
# never "repairs" a YAML shape it cannot interpret safely.
$metadataIndex = -1
$versionIndex = -1
$oldVersion = $null
$metadataCount = 0
$versionKeyCount = 0
for ($i = 1; $i -lt $closeIndex; $i++) {
    if ($lines[$i] -match '^metadata\s*:') {
        $metadataCount++
        if ($lines[$i] -notmatch '^metadata:\s*$') {
            Fail "SKILL.md at $skillMd uses unsupported inline or malformed top-level metadata; use a 'metadata:' block."
        }
        $metadataIndex = $i
        for ($j = $i + 1; $j -lt $closeIndex; $j++) {
            if ($lines[$j] -match '^\S') { break }  # end of indented metadata block
            if ($lines[$j] -match '^  version:\s*(.*?)\s*$') {
                $versionKeyCount++
                $versionIndex = $j
                $candidate = $Matches[1].Trim('"')
                if ($candidate -notmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$') {
                    Fail "metadata.version '$candidate' is not strict numeric SemVer in $skillMd."
                }
                $oldVersion = $candidate
            }
            elseif ($lines[$j] -match '^\s+version\s*:') {
                Fail "SKILL.md at $skillMd has a nested or malformed metadata version key; metadata.version must be a direct child indented by exactly two spaces."
            }
        }
    }
}
if ($metadataCount -eq 0) { Fail "SKILL.md at $skillMd must contain exactly one top-level 'metadata:' block." }
if ($metadataCount -gt 1) { Fail "SKILL.md at $skillMd has duplicate metadata blocks." }
if ($versionKeyCount -gt 1) { Fail "SKILL.md at $skillMd has duplicate metadata.version keys." }

$bootstrapped = ($null -eq $oldVersion)
$changelogPath = Join-Path $skillDir 'CHANGELOG.md'
if (-not $bootstrapped) {
    $firstChangelogVersion = Get-FirstChangelogVersion $changelogPath
    if ($firstChangelogVersion -ne $oldVersion) {
        Fail "Existing skill $Skill must have current version $oldVersion as its first changelog record before bumping; found '$firstChangelogVersion'."
    }
}

# --- Compute new version ---------------------------------------------------------------
if ($hasSet) {
    if ($bootstrapped -and $Set -ne '0.1.0') {
        Fail "A skill without metadata.version must bootstrap at 0.1.0; -Set $Set is not allowed."
    }
    $newVersion = $Set
}
elseif ($bootstrapped) {
    $newVersion = '0.1.0'
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
if (-not $bootstrapped -and (Compare-SemVer $newVersion $oldVersion) -le 0) {
    Fail "New version $newVersion must be greater than current version $oldVersion."
}

# --- Rewrite frontmatter ------------------------------------------------------------------
$newLines = [System.Collections.Generic.List[string]]::new()
$newLines.AddRange([string[]]$lines)

if ($versionIndex -ge 0) {
    $indent = ([regex]::Match($lines[$versionIndex], '^(\s+)')).Groups[1].Value
    $newLines[$versionIndex] = "${indent}version: $newVersion"
}
elseif ($metadataIndex -ge 0) {
    # metadata block exists but has no version key; insert version as its first child.
    $newLines.Insert($metadataIndex + 1, "  version: $newVersion")
}
else {
    # No metadata block; create one just before the closing delimiter.
    $newLines.Insert($closeIndex, 'metadata:')
    $newLines.Insert($closeIndex + 1, "  version: $newVersion")
}

$newline = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
$newSkillContent = ($newLines -join $newline)

# --- Prepend changelog entry (newest first) ---------------------------------------------------
$date = Get-Date -Format 'yyyy-MM-dd'
$entryLine = "- $newVersion ($date): $Entry"
if (Test-Path -LiteralPath $changelogPath -PathType Leaf) {
    $existing = [System.IO.File]::ReadAllText($changelogPath)
    $existingLines = @($existing -split "`r?`n")
    $header = if ($existingLines.Count -gt 0 -and $existingLines[0] -match '^#\s+') { $existingLines[0] } else { "# $Skill changelog" }
    $restStart = if ($existingLines.Count -gt 0 -and $existingLines[0] -match '^#\s+') { 1 } else { 0 }
    $rest = @($existingLines | Select-Object -Skip $restStart)
    while ($rest.Count -gt 0 -and [string]::IsNullOrWhiteSpace($rest[0])) { $rest = @($rest | Select-Object -Skip 1) }
    $expandedStyle = $existing -match '(?m)^##\s+[0-9]+\.[0-9]+\.[0-9]+(?:\s|$)'
    $record = if ($expandedStyle) { @("## $newVersion", '', "- $Entry") } else { @($entryLine) }
    $newChangelogContent = (@($header, '') + $record + @('') + $rest -join $newline).TrimEnd() + $newline
}
else {
    $header = "# $Skill changelog"
    $newChangelogContent = $header + $newline + $newline + $entryLine + $newline
}

# Stage both files before replacement and restore originals if either move fails.
$utf8 = [System.Text.UTF8Encoding]::new($false)
$skillTmp = "$skillMd.tmp.$PID"
$changelogTmp = "$changelogPath.tmp.$PID"
$originalSkill = [System.IO.File]::ReadAllBytes($skillMd)
$changelogExisted = Test-Path -LiteralPath $changelogPath -PathType Leaf
$originalChangelog = if ($changelogExisted) { [System.IO.File]::ReadAllBytes($changelogPath) } else { $null }
try {
    [System.IO.File]::WriteAllText($skillTmp, $newSkillContent, $utf8)
    [System.IO.File]::WriteAllText($changelogTmp, $newChangelogContent, $utf8)
    Move-Item -LiteralPath $skillTmp -Destination $skillMd -Force
    Move-Item -LiteralPath $changelogTmp -Destination $changelogPath -Force
}
catch {
    $failure = $_.Exception.Message
    try { [System.IO.File]::WriteAllBytes($skillMd, $originalSkill) } catch { }
    try {
        if ($changelogExisted) { [System.IO.File]::WriteAllBytes($changelogPath, $originalChangelog) }
        elseif (Test-Path -LiteralPath $changelogPath) { Remove-Item -LiteralPath $changelogPath -Force }
    } catch { }
    Remove-Item -LiteralPath $skillTmp, $changelogTmp -Force -ErrorAction SilentlyContinue
    Fail "Skill version update failed and original files were restored: $failure"
}
finally {
    Remove-Item -LiteralPath $skillTmp, $changelogTmp -Force -ErrorAction SilentlyContinue
}

[pscustomobject]@{
    status         = 'ok'
    skill          = $Skill
    old_version    = $oldVersion
    new_version    = $newVersion
    changelog_path = (Resolve-Path -LiteralPath $changelogPath).Path
    bootstrapped   = $bootstrapped
} | ConvertTo-Json -Compress | Write-Output
exit 0
