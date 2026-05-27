# Given a draft path like "<dir>/<name>.md", return the next edit version
# number N such that "<dir>/<name>-edit-vN.md" does not yet exist.
#
# Scans for existing files matching "<name>-edit-v<digits>.md" in the same
# folder and returns max(N) + 1. If none exist, returns 1.
#
# Output (default): writes the integer N on stdout.
# Output (-Json):  writes { draft_path, draft_dir, draft_stem, next_version,
#                            existing_versions, next_edit_path,
#                            next_summary_path, next_review_html_path }.

param(
    [Parameter(Mandatory)]
    [string]$DraftPath,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $DraftPath)) {
    throw "Draft file not found: $DraftPath"
}

$resolved = (Resolve-Path -LiteralPath $DraftPath).Path
$draftDir = Split-Path -Parent $resolved
$draftLeaf = [System.IO.Path]::GetFileName($resolved)
$draftStem = [System.IO.Path]::GetFileNameWithoutExtension($draftLeaf)
$draftExt = [System.IO.Path]::GetExtension($draftLeaf)

if ([string]::IsNullOrWhiteSpace($draftExt)) {
    $draftExt = '.md'
}

# Match "<stem>-edit-v<digits><ext>" (e.g. q4-letter-edit-v2.md)
$pattern = [regex]::Escape($draftStem) + '-edit-v(\d+)' + [regex]::Escape($draftExt) + '$'
$regex = [regex]::new($pattern, 'IgnoreCase')

$existing = @()
foreach ($file in Get-ChildItem -LiteralPath $draftDir -File) {
    $match = $regex.Match($file.Name)
    if ($match.Success) {
        $existing += [int]$match.Groups[1].Value
    }
}

$existing = @($existing | Sort-Object -Unique)
$nextVersion = if ($existing.Count -eq 0) { 1 } else { [int](($existing | Measure-Object -Maximum).Maximum) + 1 }

$nextEditPath = Join-Path $draftDir ("$draftStem-edit-v$nextVersion$draftExt")
$nextSummaryPath = Join-Path $draftDir ("$draftStem-edit-v$nextVersion-summary$draftExt")
$nextReviewHtmlPath = Join-Path $draftDir ("$draftStem-edit-v$nextVersion-review.html")

if ($Json) {
    [pscustomobject]@{
        draft_path = $resolved
        draft_dir = $draftDir
        draft_stem = $draftStem
        next_version = $nextVersion
        existing_versions = $existing
        next_edit_path = $nextEditPath
        next_summary_path = $nextSummaryPath
        next_review_html_path = $nextReviewHtmlPath
    } | ConvertTo-Json -Depth 4
}
else {
    Write-Output $nextVersion
}
