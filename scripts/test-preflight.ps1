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
. (Join-Path $PSScriptRoot 'lib/resolve-test-python.ps1')
$Python = Resolve-TestPython -RequirementsPath $RequirementsPath
if ($Python.Hint) { Write-Output $Python.Hint }
Write-Output "Test Python: $($Python.Path) (source: $($Python.Source))"
$PipCommand = "install uv and rerun to provision the standard venv, or set DANNY_SKILLS_TEST_PYTHON to a prepared interpreter"
$NpmCommand = "Set-Location -LiteralPath `"$Harness`"; npm ci"
$Node = $null
$Npm = $null
if ($Scope -eq 'full') {
    $Node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $Npm = Get-Command npm.cmd,npm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
}
# Fix hints follow the host: winget on Windows, apt on the Linux session host, brew on the Mac.
$OnLinux = $IsLinux
$OnMac = $IsMacOS
function Get-InstallHint([string]$Windows, [string]$Linux, [string]$Mac) {
    if ($OnLinux) { return $Linux }
    if ($OnMac) { return $Mac }
    return $Windows
}
$GateTools = @(
    @{ Name = 'pwsh'; Fix = (Get-InstallHint 'winget install --exact --id Microsoft.PowerShell' 'sudo apt install powershell' 'brew install powershell') },
    @{ Name = 'git'; Fix = (Get-InstallHint 'winget install --exact --id Git.Git' 'sudo apt install git' 'brew install git') }
)
if ($IsWindows) { $GateTools += @{ Name = 'robocopy'; Fix = 'DISM.exe /Online /Cleanup-Image /RestoreHealth' } }
else { $GateTools += @{ Name = 'rsync'; Fix = (Get-InstallHint '' 'sudo apt install rsync' 'brew install rsync') } }

function Get-MissingItems {
    if (-not $Python.Path) { "python missing; fix: $(Get-InstallHint 'winget install --exact --id Python.Python.3.14' 'sudo apt install python-is-python3' 'brew install python')" }
    foreach ($Tool in $GateTools) {
        if (-not (Get-Command $Tool.Name -CommandType Application -ErrorAction SilentlyContinue)) {
            "$($Tool.Name) missing; fix: $($Tool.Fix)"
        }
    }
    if ($Scope -eq 'full') {
        if (-not $Node) { "node missing; fix: $(Get-InstallHint 'winget install --exact --id OpenJS.NodeJS.LTS' 'sudo apt install nodejs' 'brew install node')" }
        if (-not $Npm) { "npm missing; fix: $(Get-InstallHint 'winget install --exact --id OpenJS.NodeJS.LTS' 'sudo apt install npm' 'brew install node')" }
    }
    if ($Python.Path) {
        $Probe = Test-PythonRequirements -Python $Python.Path -RequirementsPath $RequirementsPath -Requirements $Requirements -CheckZone:($Scope -eq 'full')
        foreach ($Module in $Probe.Missing) {
            $Name = if ($Module -eq 'markdown_it') { 'markdown-it-py' } else { $Module.Replace('_', '-') }
            "$Name missing or cannot import; fix: $PipCommand"
        }
    }
    if ($Scope -eq 'full' -and -not (Test-Path -LiteralPath (Join-Path $Harness 'node_modules') -PathType Container)) {
        "UI harness node_modules missing; fix: $NpmCommand"
    }
    if ($Scope -eq 'full' -and $Node) {
        # Mirror the engine child environment: external node_modules via NODE_PATH,
        # then the renderer's normal require and workspace-parent fallback.
        $ChromiumProbe = @'
const fs = require('node:fs'), path = require('node:path');
const {createRequire} = require('node:module');
const harness = path.resolve(process.argv[1]);
function chromium() {
  try { return createRequire(path.join(harness, 'render-ranked.cjs'))('playwright').chromium; }
  catch (error) { if (error.code !== 'MODULE_NOT_FOUND') throw error; }
  for (let root = harness; ; root = path.dirname(root)) {
    const smoke = path.join(root, '00_Resources', 'tools', 'browser-smoke', 'smoke.mjs');
    if (fs.existsSync(smoke)) return createRequire(smoke)('playwright').chromium;
    if (path.dirname(root) === root) throw new Error('No parent browser-smoke folder found');
  }
}
try {
  if (!fs.existsSync(chromium().executablePath())) throw new Error('Chromium executable missing');
} catch (error) { console.error(error.message); process.exitCode = 1; }
'@
        $PriorNodePath = $env:NODE_PATH
        try {
            if ($env:DANNY_BROWSER_SMOKE_DIR) {
                $ModulesPath = Join-Path ([IO.Path]::GetFullPath($env:DANNY_BROWSER_SMOKE_DIR)) 'node_modules'
                if (Test-Path -LiteralPath $ModulesPath -PathType Container) {
                    $env:NODE_PATH = $ModulesPath
                    if ($PriorNodePath) { $env:NODE_PATH += [IO.Path]::PathSeparator + $PriorNodePath }
                }
            }
            $null = & $Node.Source -e $ChromiumProbe $Harness 2>$null
        } finally {
            $env:NODE_PATH = $PriorNodePath
        }
        if ($LASTEXITCODE -ne 0) {
            'Ranked renderer Chromium unavailable; fix: set DANNY_BROWSER_SMOKE_DIR to an installed browser-smoke folder, or run npm ci and npx playwright install chromium in that folder.'
        }
    }
}

$Missing = @(Get-MissingItems)
if ($Fix -and $Missing.Count) {
    # Python provisioning is automatic in the resolver and never targets system Python.
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
