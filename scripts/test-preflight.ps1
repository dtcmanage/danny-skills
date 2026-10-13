param(
    [switch]$Fix,
    [string]$RequirementsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'requirements-test.txt')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RequirementsPath = [System.IO.Path]::GetFullPath($RequirementsPath)
$Harness = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/model-router/bench/tasks/ui-frontend-card/harness'
$PipCommand = "python -m pip install --user -r `"$RequirementsPath`""
$NpmCommand = "Set-Location -LiteralPath `"$Harness`"; npm ci"
$Python = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$Node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$Npm = Get-Command npm.cmd,npm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1

function Get-MissingItems {
    if (-not $Python) { 'python missing; fix: winget install --exact --id Python.Python.3.14' }
    if (-not $Node) { 'node missing; fix: winget install --exact --id OpenJS.NodeJS.LTS' }
    if (-not $Npm) { 'npm missing; fix: winget install --exact --id OpenJS.NodeJS.LTS' }
    if ($Python) {
        # Keep package names on stdin, so they never appear in process command lines.
        $Modules = @()
        $DistributionNames = @()
        $ModuleMap = @{ 'markdown-it-py' = 'markdown_it' }
        foreach ($Line in Get-Content -LiteralPath $RequirementsPath) {
            $Line = ($Line -split '#', 2)[0].Trim()
            if (-not $Line) { continue }
            if ($Line -notmatch '^([A-Za-z0-9_.-]+)==[^\s]+$') { throw "Invalid pinned requirement: $Line" }
            $Name = $Matches[1]
            $DistributionNames += $Name
            $Modules += $(if ($ModuleMap.ContainsKey($Name)) { $ModuleMap[$Name] } else { $Name.Replace('-', '_') })
        }
        $Probe = @'
import importlib, json, sys
from zoneinfo import ZoneInfo
missing = []
for name in json.load(sys.stdin):
    try:
        importlib.import_module(name)
    except Exception:
        missing.append(name)
try:
    ZoneInfo('America/New_York')
except Exception:
    missing.append('America/New_York')
print(json.dumps(missing))
'@
        $Result = ConvertTo-Json -InputObject $Modules -Compress | & $Python.Source -c $Probe 2>$null
        if ($LASTEXITCODE -ne 0) {
            "python import probe failed; fix: $PipCommand"
        } else {
            $MissingModules = @($Result | ConvertFrom-Json)
            for ($i = 0; $i -lt $Modules.Count; $i++) {
                if ($Modules[$i] -in $MissingModules) { "$($DistributionNames[$i]) missing or cannot import; fix: $PipCommand" }
            }
            if ('America/New_York' -in $MissingModules) { "ZoneInfo('America/New_York') missing; fix: $PipCommand" }
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Harness 'node_modules') -PathType Container)) {
        "UI harness node_modules missing; fix: $NpmCommand"
    }
}

$Missing = @(Get-MissingItems)
if ($Fix -and $Missing.Count) {
    if ($Python -and @($Missing | Where-Object { $_ -like '*pip install*' }).Count) {
        & $Python.Source -m pip install --user -r $RequirementsPath
        if ($LASTEXITCODE -ne 0) { Write-Output "Dependency install failed; fix: $PipCommand"; exit 1 }
    }
    if ($Node -and $Npm -and -not (Test-Path -LiteralPath (Join-Path $Harness 'node_modules') -PathType Container)) {
        Push-Location -LiteralPath $Harness
        try {
            & $Npm.Source ci
            if ($LASTEXITCODE -ne 0) { Write-Output "UI harness install failed; fix: $NpmCommand"; exit 1 }
        } finally { Pop-Location }
    }
    $Missing = @(Get-MissingItems)
}
if ($Missing.Count) { $Missing | Write-Output; exit 1 }
Write-Output 'Test preflight passed.'
exit 0
