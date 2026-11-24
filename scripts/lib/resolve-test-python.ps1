# Shared interpreter selection and additive provisioning for repository tests.
function Get-StandardTestVenvPath {
    if ($IsWindows) { return (Join-Path $env:LOCALAPPDATA 'build-test-venv') }
    return (Join-Path $HOME '.local/share/build-test-venv')
}

function Get-TestPythonCommand([string]$Name) {
    if (-not $Name) { return $null }
    return (Get-Command $Name -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Test-PythonRequirements {
    param([string]$Python, [string]$RequirementsPath, [switch]$CheckZone = $true,
        [string[]]$Requirements = @(Get-Content -LiteralPath $RequirementsPath))
    $modules = @(foreach ($line in $Requirements) {
        $line = ($line -split '#', 2)[0].Trim()
        if (-not $line) { continue }
        if ($line -notmatch '^([A-Za-z0-9_.-]+)==[^\s]+$') { throw "Invalid pinned requirement: $line" }
        $name = $Matches[1]
        if ($name -eq 'markdown-it-py') { 'markdown_it' } else { $name.Replace('-', '_') }
    })
    $probe = @'
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
    $result = @{ modules = $modules; check_zone = [bool]$CheckZone } | ConvertTo-Json -Compress | & $Python -c $probe 2>$null
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Passed = $false; Missing = @('import probe failed') } }
    try { $missing = @($result | ConvertFrom-Json -ErrorAction Stop) }
    catch { return [pscustomobject]@{ Passed = $false; Missing = @('import probe returned invalid JSON') } }
    return [pscustomobject]@{ Passed = ($missing.Count -eq 0); Missing = $missing }
}

function Resolve-TestPython {
    param(
        [string]$RequirementsPath = (Join-Path $PSScriptRoot '../../requirements-test.txt'),
        [string]$VenvPath = (Get-StandardTestVenvPath)
    )
    $hint = $null
    $selected = Get-TestPythonCommand $env:DANNY_SKILLS_TEST_PYTHON
    $source = 'DANNY_SKILLS_TEST_PYTHON'
    if ($env:DANNY_SKILLS_TEST_PYTHON -and -not $selected) {
        $hint = 'DANNY_SKILLS_TEST_PYTHON is not executable; trying the standard test venv.'
    }
    if (-not $selected) {
        $venvPython = Join-Path $VenvPath $(if ($IsWindows) { 'Scripts/python.exe' } else { 'bin/python' })
        $uv = Get-TestPythonCommand 'uv'
        $selected = Get-TestPythonCommand $venvPython
        if (-not $selected -and $uv -and -not (Test-Path -LiteralPath $VenvPath)) {
            # Never recreate an existing environment, even if it is damaged.
            & $uv.Source venv $VenvPath | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Test venv creation failed: $VenvPath" }
            $selected = Get-TestPythonCommand $venvPython
            if (-not $selected) { throw "uv did not create an executable Python: $venvPython" }
        }
        if ($selected) {
            $source = 'standard venv'
            $probe = Test-PythonRequirements -Python $selected.Source -RequirementsPath $RequirementsPath
            if (-not $probe.Passed -and $uv) {
                # pip install adds requirements; never sync/remove shared packages.
                & $uv.Source pip install --python $selected.Source -r $RequirementsPath | Out-Host
                if ($LASTEXITCODE -ne 0) { throw "Test dependency install failed: $($selected.Source)" }
                $probe = Test-PythonRequirements -Python $selected.Source -RequirementsPath $RequirementsPath
                if (-not $probe.Passed) { throw "Test venv import probe still failed after install: $($probe.Missing -join ', ')" }
            } elseif (-not $probe.Passed) {
                $hint = "uv missing; cannot provision test dependencies. Install uv, then rerun; standard venv: $VenvPath"
            }
        } else {
            $source = 'PATH'
            $selected = Get-TestPythonCommand 'python'
            if (-not $selected) { $selected = Get-TestPythonCommand 'python3' }
            $hint = "Standard test venv unavailable: $VenvPath; $(if (-not $uv) { 'uv missing; install uv and rerun to create it automatically' } else { 'existing directory has no executable Python; repair it or set DANNY_SKILLS_TEST_PYTHON' }). Falling back to PATH; system Python will not be modified."
        }
    }
    $path = if ($selected) { $selected.Source } else { $null }
    if ($path) {
        # Affect the caller and all subsequent children, including bare python3.
        $bin = Split-Path -Parent $path
        $env:PATH = $bin + [IO.Path]::PathSeparator + $env:PATH
    }
    return [pscustomobject]@{ Path = $path; Source = $source; Hint = $hint }
}
