param(
    [ValidateSet('full', 'gate')]
    [string]$Scope = 'full',
    [switch]$Fix,
    [string]$RequirementsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'requirements-test.txt'),
    [string]$HarnessPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/model-router/bench/tasks/ui-frontend-card/harness')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RequirementsPath = [System.IO.Path]::GetFullPath($RequirementsPath)
$Harness = [System.IO.Path]::GetFullPath($HarnessPath)
# Gate inventory: .ship.json runs the bootstrap measurement (tiktoken),
# stdlib-only Eastern tests, and PowerShell/Git fixtures. The versioning suite
# packages a fixture with robocopy. No gate step runs the UI bench or link parser;
# timezone consumers have a stdlib fallback. Keep this list in sync with the gate.
$GatePackages = @('tiktoken')
$Requirements = @(foreach ($Line in Get-Content -LiteralPath $RequirementsPath) {
    $Line = ($Line -split '#', 2)[0].Trim()
    if (-not $Line) { continue }
    if ($Line -notmatch '^([A-Za-z0-9_.-]+)==[^\s]+$') { throw "Invalid pinned requirement: $Line" }
    if ($Scope -eq 'full' -or $Matches[1] -in $GatePackages) { $Line }
})
if ($Scope -eq 'gate') {
    foreach ($Package in $GatePackages) {
        if (-not @($Requirements | Where-Object { ($_ -split '==', 2)[0] -eq $Package }).Count) {
            throw "Gate requirement missing from ${RequirementsPath}: $Package"
        }
    }
}
$PipCommand = "python -m pip install --user -r `"$RequirementsPath`""
if ($Scope -eq 'gate') { $PipCommand = "python -m pip install --user $($Requirements -join ' ')" }
$NpmCommand = "Set-Location -LiteralPath `"$Harness`"; npm ci"
$Python = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$Node = $null
$Npm = $null
if ($Scope -eq 'full') {
    $Node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $Npm = Get-Command npm.cmd,npm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
}
$GateTools = @(
    @{ Name = 'pwsh'; Fix = 'winget install --exact --id Microsoft.PowerShell' },
    @{ Name = 'git'; Fix = 'winget install --exact --id Git.Git' },
    @{ Name = 'robocopy'; Fix = 'DISM.exe /Online /Cleanup-Image /RestoreHealth' }
)

function Get-MissingItems {
    if (-not $Python) { 'python missing; fix: winget install --exact --id Python.Python.3.14' }
    foreach ($Tool in $GateTools) {
        if (-not (Get-Command $Tool.Name -CommandType Application -ErrorAction SilentlyContinue)) {
            "$($Tool.Name) missing; fix: $($Tool.Fix)"
        }
    }
    if ($Scope -eq 'full') {
        if (-not $Node) { 'node missing; fix: winget install --exact --id OpenJS.NodeJS.LTS' }
        if (-not $Npm) { 'npm missing; fix: winget install --exact --id OpenJS.NodeJS.LTS' }
    }
    if ($Python) {
        # Keep package names on stdin, so they never appear in process command lines.
        $Modules = @()
        $DistributionNames = @()
        $ModuleMap = @{ 'markdown-it-py' = 'markdown_it' }
        foreach ($Line in $Requirements) {
            $Name = ($Line -split '==', 2)[0]
            $DistributionNames += $Name
            $Modules += $(if ($ModuleMap.ContainsKey($Name)) { $ModuleMap[$Name] } else { $Name.Replace('-', '_') })
        }
        $Probe = @'
import importlib, json, sys
from zoneinfo import ZoneInfo
missing = []
request = json.load(sys.stdin)
for name in request['modules']:
    try:
        importlib.import_module(name)
    except Exception:
        missing.append(name)
if request['check_zone']:
    try:
        ZoneInfo('America/New_York')
    except Exception:
        missing.append('America/New_York')
print(json.dumps(missing))
'@
        $Result = @{ modules = $Modules; check_zone = ($Scope -eq 'full') } | ConvertTo-Json -Compress | & $Python.Source -c $Probe 2>$null
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
    if ($Scope -eq 'full' -and -not (Test-Path -LiteralPath (Join-Path $Harness 'node_modules') -PathType Container)) {
        "UI harness node_modules missing; fix: $NpmCommand"
    }
}

$Missing = @(Get-MissingItems)
if ($Fix -and $Missing.Count) {
    if ($Python -and @($Missing | Where-Object { $_ -like '*pip install*' }).Count) {
        if ($Scope -eq 'gate') { & $Python.Source -m pip install --user @Requirements }
        else { & $Python.Source -m pip install --user -r $RequirementsPath }
        if ($LASTEXITCODE -ne 0) { Write-Output "Dependency install failed; fix: $PipCommand"; exit 1 }
    }
    if ($Scope -eq 'full' -and $Node -and $Npm -and -not (Test-Path -LiteralPath (Join-Path $Harness 'node_modules') -PathType Container)) {
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
