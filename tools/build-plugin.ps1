# build-plugin.ps1
# Packages the danny-skills repo into a drag-installable .plugin file for Cowork.
#
# Output: D:\Claude\danny-skills-<version>.plugin
#
# Reads the version from .claude-plugin\plugin.json so the filename always
# matches the manifest. Excludes .git, tools, and OS junk from the archive.

$ErrorActionPreference = "Stop"

# Resolve paths relative to this script so it works no matter where it's called from.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir

$manifestPath = Join-Path $repoRoot ".claude-plugin\plugin.json"
if (-not (Test-Path $manifestPath)) {
    throw "plugin.json not found at $manifestPath"
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$name     = $manifest.name
$version  = $manifest.version
if (-not $name -or -not $version) {
    throw "plugin.json is missing 'name' or 'version'"
}

$staging   = Join-Path $env:TEMP ("$name-build")
$zipOut    = Join-Path $env:TEMP ("$name-$version.zip")
$pluginOut = "D:\Claude\$name-$version.plugin"

# Clean any prior build artifacts.
if (Test-Path $staging)   { Remove-Item $staging   -Recurse -Force }
if (Test-Path $zipOut)    { Remove-Item $zipOut    -Force }
if (Test-Path $pluginOut) { Remove-Item $pluginOut -Force }

# Stage a clean copy. /MIR mirrors; /XD excludes directories; /XF excludes files.
# robocopy returns 0-7 for success, so swallow its non-zero "no files copied" codes.
New-Item -ItemType Directory -Path $staging | Out-Null
$null = robocopy $repoRoot $staging /MIR /XD ".git" "tools" "node_modules" /XF ".DS_Store" "Thumbs.db" ".gitignore"

# Zip the staged contents at the archive root (no wrapping folder).
Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zipOut -Force

# Rename .zip to .plugin and place the deliverable in D:\Claude.
Move-Item $zipOut $pluginOut -Force

# Cleanup staging.
Remove-Item $staging -Recurse -Force

Write-Host ""
Write-Host "Built: $pluginOut"
Write-Host ""
Write-Host "Drag this file into Cowork to install."
