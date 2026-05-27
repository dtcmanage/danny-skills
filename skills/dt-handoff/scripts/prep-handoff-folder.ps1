# Ensure <project-root>\_handoffs exists, and list any existing files in it
# along with the canonical save path for today's handoff.
#
# Output (default): summary lines.
# Output (-Json):  { project_root, handoff_folder, created, existing_files[],
#                   today, handoff_md_path, handoff_html_path }
# where handoff_md_path/handoff_html_path are deterministic save targets for
# a given -Slug (or null if -Slug was not provided).

param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot,

    [string]$Slug = "",

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ProjectRoot)) {
    throw "Project root not found: $ProjectRoot"
}

$resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$handoffFolder = Join-Path $resolvedRoot '_handoffs'

$created = $false
if (-not (Test-Path -LiteralPath $handoffFolder)) {
    New-Item -ItemType Directory -Path $handoffFolder -Force | Out-Null
    $created = $true
}

$existing = @()
foreach ($file in Get-ChildItem -LiteralPath $handoffFolder -File -ErrorAction SilentlyContinue) {
    $existing += [pscustomobject]@{
        name = $file.Name
        path = $file.FullName
        size_bytes = $file.Length
        modified = $file.LastWriteTime.ToString('o')
    }
}

$today = (Get-Date).ToString('yyyy-MM-dd')
$handoffMdPath = $null
$handoffHtmlPath = $null
if (-not [string]::IsNullOrWhiteSpace($Slug)) {
    $cleanSlug = $Slug.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $cleanSlug = $cleanSlug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($cleanSlug)) {
        throw "Could not derive a slug from '$Slug'."
    }
    $handoffMdPath = Join-Path $handoffFolder "handoff-$today-$cleanSlug.md"
    $handoffHtmlPath = Join-Path $handoffFolder "handoff-$today-$cleanSlug.html"
}

$result = [pscustomobject]@{
    project_root = $resolvedRoot
    handoff_folder = $handoffFolder
    created = $created
    existing_files = $existing
    today = $today
    handoff_md_path = $handoffMdPath
    handoff_html_path = $handoffHtmlPath
}

if ($Json) {
    $result | ConvertTo-Json -Depth 5
}
else {
    Write-Output "Project root: $resolvedRoot"
    Write-Output "Handoff folder: $handoffFolder ($(if ($created) { 'created' } else { 'exists' }))"
    if ($existing.Count -gt 0) {
        Write-Output "Existing handoff files ($($existing.Count)):"
        foreach ($f in $existing) { Write-Output "  $($f.name)  ($($f.modified))" }
    }
    else {
        Write-Output "No existing handoff files."
    }
    if ($handoffMdPath) {
        Write-Output "Target paths for slug '$Slug':"
        Write-Output "  $handoffMdPath"
        Write-Output "  $handoffHtmlPath"
    }
}
