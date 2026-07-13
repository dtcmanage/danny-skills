# build-plugin.ps1
# Packages the danny-skills repo into a drag-installable .plugin file for Cowork.
#
# Output: D:\Claude\danny-skills-<version>.plugin
#
# Reads the version from .claude-plugin\plugin.json so the filename always
# matches the manifest. Excludes .git, tools, and OS junk from the archive.

param(
    [string]$BaseRef = "",
    [switch]$ValidateOnly,
    [string]$RepoRoot = "",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

# Resolve paths relative to this script so it works no matter where it's called from.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $scriptDir }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$branch = (& git -C $RepoRoot branch --show-current).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
    throw "Could not resolve the current Git branch for $RepoRoot."
}

if ([string]::IsNullOrWhiteSpace($BaseRef)) {
    if ($branch -ne 'main') {
        throw "-BaseRef is required when packaging or validating from any branch other than main."
    }
    $workingChanges = @(& git -C $RepoRoot status --porcelain --untracked-files=normal)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the working tree.' }
    if ($workingChanges.Count -gt 0) {
        $BaseRef = 'HEAD'
    }
    else {
        $manifestPathForBase = Join-Path $RepoRoot '.claude-plugin\plugin.json'
        $currentVersionForBase = [string]((Get-Content -Raw -LiteralPath $manifestPathForBase | ConvertFrom-Json).version)
        foreach ($candidate in @(& git -C $RepoRoot rev-list HEAD -- '.claude-plugin/plugin.json')) {
            $candidateManifest = & git -C $RepoRoot show "$candidate`:.claude-plugin/plugin.json" 2>$null
            if ($LASTEXITCODE -ne 0) { continue }
            try { $candidateVersion = [string](($candidateManifest -join "`n" | ConvertFrom-Json).version) }
            catch { continue }
            if ($candidateVersion -ne $currentVersionForBase) { $BaseRef = [string]$candidate; break }
        }
        if ([string]::IsNullOrWhiteSpace($BaseRef)) {
            throw 'Could not locate the prior plugin release boundary from main history; pass an explicit ancestor -BaseRef.'
        }
    }
}
else {
    $baseCommit = (& git -C $RepoRoot rev-parse --verify "$BaseRef`^{commit}").Trim()
    if ($LASTEXITCODE -ne 0) { throw "-BaseRef '$BaseRef' does not resolve to a commit." }
    $headCommit = (& git -C $RepoRoot rev-parse HEAD).Trim()
    if ($branch -ne 'main') {
        $mainCommit = (& git -C $RepoRoot rev-parse --verify 'main^{commit}').Trim()
        if ($LASTEXITCODE -ne 0 -or $baseCommit -ne $mainCommit) {
            throw "Feature-branch packaging must compare against the local main merge target; -BaseRef '$BaseRef' is not main."
        }
        & git -C $RepoRoot merge-base --is-ancestor $mainCommit $headCommit
        if ($LASTEXITCODE -ne 0) {
            throw 'Local main must be an ancestor of feature-branch HEAD before packaging.'
        }
    }
    elseif ($baseCommit -eq $headCommit) {
        $workingChanges = @(& git -C $RepoRoot status --porcelain --untracked-files=normal)
        if ($workingChanges.Count -eq 0) {
            throw '-BaseRef resolves to HEAD with no working-tree changes, so it cannot prove a release delta.'
        }
    }
    else {
        & git -C $RepoRoot merge-base --is-ancestor $baseCommit $headCommit
        if ($LASTEXITCODE -ne 0) { throw "-BaseRef '$BaseRef' must be an ancestor of HEAD." }
    }
}

$versionValidator = Join-Path $RepoRoot 'scripts\verify-versioning-policy.ps1'
$validatorArgs = @('-NoProfile', '-File', $versionValidator, '-RepoRoot', $RepoRoot, '-BaseRef', $BaseRef, '-Json')
$versionResult = & pwsh @validatorArgs
if ($LASTEXITCODE -ne 0) {
    throw "Versioning policy gate failed before packaging:`n$($versionResult -join "`n")"
}
if ($ValidateOnly) {
    Write-Output ($versionResult -join "`n")
    exit 0
}

$manifestPath = Join-Path $RepoRoot ".claude-plugin\plugin.json"
if (-not (Test-Path $manifestPath)) {
    throw "plugin.json not found at $manifestPath"
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$name     = $manifest.name
$version  = $manifest.version
if (-not $name -or -not $version) {
    throw "plugin.json is missing 'name' or 'version'"
}

$buildId   = [guid]::NewGuid().ToString('N')
$staging   = Join-Path $env:TEMP ("$name-build-$buildId")
$zipOut    = Join-Path $env:TEMP ("$name-$version-$buildId.zip")
$pluginTmp = Join-Path $env:TEMP ("$name-$version-$buildId.plugin")
$pluginOut = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    "D:\Claude\$name-$version.plugin"
}
else {
    $outputParent = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputParent) -and -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
        throw "OutputPath parent does not exist: $outputParent"
    }
    [System.IO.Path]::GetFullPath($OutputPath)
}

try {
    # Stage only version-governed plugin surfaces. Local plans, evidence, reports,
    # friction logs, and arbitrary root files can never enter the artifact.
    New-Item -ItemType Directory -Path $staging | Out-Null
    foreach ($relativeRoot in @('.claude-plugin', 'skills', 'scripts', 'references', 'assets')) {
        $source = Join-Path $RepoRoot $relativeRoot
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { continue }
        $destination = Join-Path $staging $relativeRoot
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        & robocopy $source $destination /E /XD "node_modules" /XF "_log.md" "_log-archive.md" ".DS_Store" "Thumbs.db" | Out-Null
        $copyExit = $LASTEXITCODE
        if ($copyExit -ge 8) {
            throw "robocopy failed for $relativeRoot with exit code $copyExit; refusing to archive a partial staging tree."
        }
    }

    # Build and open the archive before replacing any prior valid artifact.
    $archiveInputs = @(Get-ChildItem -LiteralPath $staging -Force | ForEach-Object { $_.FullName })
    if ($archiveInputs.Count -eq 0) { throw 'Allowlisted staging tree is empty.' }
    Compress-Archive -LiteralPath $archiveInputs -DestinationPath $zipOut -Force
    if (-not (Test-Path -LiteralPath $zipOut -PathType Leaf) -or (Get-Item -LiteralPath $zipOut).Length -eq 0) {
        throw 'Archive creation produced no usable output.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipOut)
    try {
        if ($archive.Entries.Count -eq 0) { throw 'Archive verification found zero entries.' }
    }
    finally { $archive.Dispose() }

    Move-Item -LiteralPath $zipOut -Destination $pluginTmp -Force
    Move-Item -LiteralPath $pluginTmp -Destination $pluginOut -Force
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zipOut, $pluginTmp -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Built: $pluginOut"
Write-Host ""
Write-Host "Drag this file into Cowork to install."
