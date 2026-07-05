# bump-skill-version.ps1
# Deterministic per-skill version bump + changelog append for danny-skills.
#
# Parses skills/<Skill>/SKILL.md YAML frontmatter, bumps metadata.version
# (bootstrapping it at 0.1.0 if missing - the bootstrap value is the starting
# point BEFORE the bump is applied), and appends one dated entry to
# skills/<Skill>/CHANGELOG.md (created with a one-line header if missing).
# Both writes are atomic (temp file, then move over).
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

function Write-Atomic([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    $tmp = Join-Path $dir ((Split-Path -Leaf $Path) + '.tmp.' + $PID)
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# --- Validate parameter combination -------------------------------------------------
$hasBump = -not [string]::IsNullOrWhiteSpace($Bump)
$hasSet = -not [string]::IsNullOrWhiteSpace($Set)
if ($hasBump -eq $hasSet) {
    Fail "Specify exactly one of -Bump patch|minor|major or -Set x.y.z."
}
if ($hasSet -and $Set -notmatch '^\d+\.\d+\.\d+$') {
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
$skillDir = Join-Path $SkillsRoot $Skill
$skillMd = Join-Path $skillDir 'SKILL.md'
if (-not (Test-Path -LiteralPath $skillDir -PathType Container)) {
    Fail "Unknown skill folder: '$Skill' (no directory at $skillDir)."
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

# Locate metadata: block and metadata.version within the frontmatter.
$metadataIndex = -1
$versionIndex = -1
$oldVersion = $null
for ($i = 1; $i -lt $closeIndex; $i++) {
    if ($lines[$i] -match '^metadata:\s*$') {
        $metadataIndex = $i
        for ($j = $i + 1; $j -lt $closeIndex; $j++) {
            if ($lines[$j] -match '^\S') { break }  # end of indented metadata block
            if ($lines[$j] -match '^(\s+)version:\s*"?(\d+\.\d+\.\d+)"?\s*$') {
                $versionIndex = $j
                $oldVersion = $Matches[2]
                break
            }
        }
        break
    }
}

$bootstrapped = $false
if ($null -eq $oldVersion) {
    # Bootstrap: 0.1.0 is the starting point BEFORE the bump is applied.
    $oldVersion = '0.1.0'
    $bootstrapped = $true
}

# --- Compute new version ---------------------------------------------------------------
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
if ($newVersion -eq $oldVersion -and -not $bootstrapped) {
    Fail "New version $newVersion equals current version $oldVersion; nothing to do."
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
Write-Atomic -Path $skillMd -Content (($newLines -join $newline))

# --- Append changelog entry ------------------------------------------------------------------
$changelogPath = Join-Path $skillDir 'CHANGELOG.md'
$date = Get-Date -Format 'yyyy-MM-dd'
$entryLine = "- $newVersion ($date): $Entry"
if (Test-Path -LiteralPath $changelogPath -PathType Leaf) {
    $existing = [System.IO.File]::ReadAllText($changelogPath)
    if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { $existing += "`n" }
    Write-Atomic -Path $changelogPath -Content ($existing + $entryLine + "`n")
}
else {
    $header = "# $Skill changelog"
    Write-Atomic -Path $changelogPath -Content ($header + "`n`n" + $entryLine + "`n")
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
