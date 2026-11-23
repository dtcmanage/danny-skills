#Requires -Version 7.0
<#
.SYNOPSIS
Reports gate test tools a roadmap's verification commands name but this host lacks (pytest, pytest-xdist,
Pester 5, tiktoken), with the exact install command for each. Intake runs it and carries the result as a
warning in its report; it never fails intake.

.PARAMETER RoadmapPath
The roadmap whose verification commands, acceptance checks and test-execution columns are scanned.
.PARAMETER RepoPath
The target repo. When it holds requirements-test.txt the Python hint installs from it.
.PARAMETER Json
Print the report as JSON. Without it the report object is returned.

.EXAMPLE
pwsh -NoProfile -File check-gate-tooling.ps1 -RoadmapPath <roadmap.md> -RepoPath <repo> -Json
#>
param(
    [Parameter(Mandatory)][string]$RoadmapPath,
    [string]$RepoPath = '',
    [switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$text = [IO.File]::ReadAllText($RoadmapPath)
$named = [ordered]@{
    pytest = $text -match '(?<![\w-])pytest(?![\w-])'
    'pytest-xdist' = $text -match '(?<![\w-])pytest(?![\w-])[^\r\n|`]*\s-n\s*(?:\d+|auto)\b|\bxdist\b'
    pester = $text -match '(?i)\b(?:Invoke-)?Pester\b'
    tiktoken = $text -match '\btiktoken\b'
}
$modules = @{ pytest = 'pytest'; 'pytest-xdist' = 'xdist'; tiktoken = 'tiktoken' }

# Interpreters: python3/python on PATH, plus any virtual environment the roadmap names that exists.
$interpreters = [Collections.Generic.List[string]]::new()
foreach ($name in @('python3', 'python')) {
    foreach ($command in @(Get-Command $name -CommandType Application -ErrorAction SilentlyContinue)) {
        if ($interpreters -notcontains $command.Source) { $interpreters.Add($command.Source) }
    }
}
foreach ($m in [regex]::Matches($text, '(?<path>(?:[A-Za-z]:)?[\\/][^\s`''"|<>]*venv[^\s`''"|<>]*?)(?=[\s`''"|<>),;]|\.(?:\s|$)|$)')) {
    $venv = $m.Groups['path'].Value.TrimEnd('.', '/', '\')
    foreach ($candidate in @((Join-Path $venv 'bin/python'), (Join-Path $venv 'Scripts/python.exe'))) {
        if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and $interpreters -notcontains $candidate) { $interpreters.Add($candidate) }
    }
}

function Test-GatePythonModule {
    param([string]$Module)
    # Run outside any project folder so a planted module of the same name is never imported.
    Push-Location ([IO.Path]::GetTempPath())
    try {
        foreach ($python in $interpreters) {
            & $python -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('$Module') else 1)" *> $null
            if ($LASTEXITCODE -eq 0) { return $python }
        }
    }
    catch { }
    finally { Pop-Location }
    return $null
}

$requirements = if ($RepoPath -and (Test-Path -LiteralPath (Join-Path $RepoPath 'requirements-test.txt') -PathType Leaf)) { [IO.Path]::GetFullPath((Join-Path $RepoPath 'requirements-test.txt')) } else { $null }
$checked = [Collections.Generic.List[object]]::new()
$missing = [Collections.Generic.List[object]]::new()
$missingPython = [Collections.Generic.List[string]]::new()
foreach ($tool in $named.Keys) {
    if (-not $named[$tool]) { continue }
    $foundAt = $null
    if ($tool -eq 'pester') {
        $pester = @(Get-Module -ListAvailable -Name Pester -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1)
        if ($pester.Count -and $pester[0].Version.Major -ge 5) { $foundAt = "Pester $($pester[0].Version)" }
    }
    else {
        $foundAt = Test-GatePythonModule -Module $modules[$tool]
        if (-not $foundAt -and $tool -eq 'pytest') {
            $command = @(Get-Command pytest -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($command.Count) { $foundAt = $command[0].Source }
        }
        if (-not $foundAt) { $missingPython.Add($tool) }
    }
    $checked.Add([ordered]@{ tool = $tool; present = [bool]$foundAt; found_at = $foundAt })
    if (-not $foundAt) { $missing.Add([ordered]@{ tool = $tool; install = $null }) }
}
$pythonHint = if ($requirements) {
    "cd `"$(Split-Path -Parent $requirements)`" && uv venv && uv pip install -r requirements-test.txt  (then run gates with the venv's python, or uv run --with-requirements requirements-test.txt)"
} else {
    "uv venv && uv pip install $(@($missingPython) -join ' ')  (then run gates with the venv's python)"
}
foreach ($row in $missing) {
    $row.install = if ($row.tool -eq 'pester') { 'pwsh -NoProfile -Command "Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0 -Force -SkipPublisherCheck"' } else { $pythonHint }
}
$warnings = @($missing | ForEach-Object { "GATE_TOOLING_MISSING: $($_.tool) is named by the roadmap's verification commands but not installed on $([Environment]::MachineName). Install: $($_.install)" })
$report = [ordered]@{
    host = [Environment]::MachineName
    interpreters = @($interpreters)
    checked = @($checked)
    missing = @($missing)
    warnings = $warnings
}
if ($Json) { $report | ConvertTo-Json -Depth 5 } else { [pscustomobject]$report }
