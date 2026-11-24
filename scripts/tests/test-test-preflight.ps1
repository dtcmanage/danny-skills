Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $Root 'scripts/lib/resolve-test-python.ps1')
$Temporary = Join-Path $Root ('.test-venv-' + [guid]::NewGuid())
$Saved = @{}
foreach ($Name in @('PATH', 'PYTHONPATH', 'DANNY_SKILLS_TEST_PYTHON', 'DANNY_BROWSER_SMOKE_DIR', 'TEST_REAL_PYTHON', 'TEST_VENV_ROOT', 'TEST_UV_SKIP_MARKER')) {
    $Saved[$Name] = [Environment]::GetEnvironmentVariable($Name)
}
$RealPython = (Get-TestPythonCommand $(if ($IsWindows) { 'python' } else { 'python3' })).Source
$Pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$Passed = 0
$Failures = @()
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Output "PASS: $Name" }
    catch { $script:Failures += "${Name}: $_"; Write-Output "FAIL: ${Name}: $_" }
    finally { $env:PATH = $Saved.PATH; $env:DANNY_SKILLS_TEST_PYTHON = $null }
}
try {
    New-Item -ItemType Directory -Path $Temporary | Out-Null
    $Bin = Join-Path $Temporary 'tools'
    $Venv = Join-Path $Temporary 'standard venv'
    New-Item -ItemType Directory -Path $Bin | Out-Null
    $Requirements = Join-Path $Temporary 'requirements.txt'
    'tiktoken==0.12.0' | Set-Content $Requirements
    $env:PYTHONPATH = $Temporary
    $env:TEST_REAL_PYTHON = $RealPython
    $env:TEST_VENV_ROOT = $Temporary
    @'
from pathlib import Path
if not (Path(__file__).parent / 'installed').exists():
    raise ImportError('fixture missing tiktoken')
'@ | Set-Content (Join-Path $Temporary 'tiktoken.py')
    @'
param()
$argv = @($args)
Add-Content (Join-Path $env:TEST_VENV_ROOT 'uv.jsonl') (ConvertTo-Json -InputObject $argv -Compress)
if ($argv[0] -eq 'venv') {
    & $env:TEST_REAL_PYTHON -m venv --without-pip $argv[1]
    exit $LASTEXITCODE
}
if (($argv[0..2] -join ' ') -ne 'pip install --python') { exit 91 }
if ($env:TEST_UV_SKIP_MARKER -ne '1') {
    New-Item -ItemType File -Path (Join-Path $env:TEST_VENV_ROOT 'installed') -Force | Out-Null
}
exit 0
'@ | Set-Content (Join-Path $Bin 'uv.ps1')

    Case 'env override wins without provisioning' {
        $env:DANNY_SKILLS_TEST_PYTHON = $RealPython
        $env:PATH = $Bin
        $Result = Resolve-TestPython -VenvPath $Venv -RequirementsPath $Requirements
        Assert ($Result.Path -eq $RealPython -and $Result.Source -eq 'DANNY_SKILLS_TEST_PYTHON') 'override not selected'
        Assert (-not (Test-Path $Venv) -and -not (Test-Path (Join-Path $Temporary 'uv.jsonl'))) 'override invoked uv'
    }
    Case 'missing venv plus uv creates and installs once, then re-probes' {
        $env:PATH = $Bin
        $Result = Resolve-TestPython -VenvPath $Venv -RequirementsPath $Requirements
        Assert ($Result.Source -eq 'standard venv') 'venv not selected'
        $Calls = @(Get-Content (Join-Path $Temporary 'uv.jsonl') | ForEach-Object { ,@($_ | ConvertFrom-Json) })
        Assert ($Calls.Count -eq 2 -and $Calls[0][0] -eq 'venv' -and $Calls[0][1] -eq $Venv) 'expected one create'
        Assert (($Calls[1][0..2] -join ' ') -eq 'pip install --python' -and $Calls[1][3] -eq $Result.Path -and $Calls[1][4] -eq '-r' -and $Calls[1][5] -eq $Requirements) 'wrong install argv'
        Assert (Test-PythonRequirements -Python $Result.Path -RequirementsPath $Requirements).Passed 're-probe failed'
    }
    Case 'standard venv preferred over PATH python, healthy venv untouched' {
        $env:PATH = $Bin + [IO.Path]::PathSeparator + $Saved.PATH
        $Result = Resolve-TestPython -VenvPath $Venv -RequirementsPath $Requirements
        Assert ($Result.Source -eq 'standard venv' -and $Result.Path.StartsWith($Venv)) 'PATH won'
        Assert (@(Get-Content (Join-Path $Temporary 'uv.jsonl')).Count -eq 2) 'healthy venv invoked uv'
        $ChildPython = & $Pwsh -NoProfile -Command '(Get-Command python -CommandType Application | Select-Object -First 1).Source'
        Assert ($ChildPython -eq $Result.Path) 'child python did not inherit venv PATH'
        if (-not $IsWindows) {
            $ChildPython3 = & $Pwsh -NoProfile -Command '(Get-Command python3 -CommandType Application | Select-Object -First 1).Source'
            Assert ($ChildPython3.StartsWith($Venv)) 'child python3 did not inherit venv PATH'
        }
    }
    Case 'existing incomplete venv installs once without recreating or removing extras' {
        Remove-Item (Join-Path $Temporary 'installed')
        'keep' | Set-Content (Join-Path $Venv 'unrelated-package')
        $env:PATH = $Bin
        $null = Resolve-TestPython -VenvPath $Venv -RequirementsPath $Requirements
        $Calls = @(Get-Content (Join-Path $Temporary 'uv.jsonl'))
        Assert ($Calls.Count -eq 3 -and ($Calls[2] | ConvertFrom-Json)[0] -eq 'pip') 'existing venv was recreated'
        Assert (Test-Path (Join-Path $Venv 'unrelated-package')) 'extra package removed'
    }
    Case 'uv absent falls back with hint and does not install' {
        $env:PATH = Split-Path -Parent $RealPython
        $Result = Resolve-TestPython -VenvPath (Join-Path $Temporary 'absent') -RequirementsPath $Requirements
        Assert ($Result.Source -eq 'PATH' -and $Result.Path -and $Result.Hint -match 'uv missing') 'fallback or hint missing'
        Assert (@(Get-Content (Join-Path $Temporary 'uv.jsonl')).Count -eq 3) 'fallback installed packages'
    }
    Case 'invalid override falls through to standard venv' {
        $env:DANNY_SKILLS_TEST_PYTHON = Join-Path $Temporary 'not-executable'
        $Result = Resolve-TestPython -VenvPath $Venv -RequirementsPath $Requirements
        Assert ($Result.Source -eq 'standard venv' -and $Result.Hint -match 'not executable') 'invalid override blocked fallback'
    }
    Case 'gate reports override; ignores full-only modules, UI harness and Chromium' {
        $env:DANNY_SKILLS_TEST_PYTHON = $RealPython
        @('tiktoken==0.12.0', 'fixture-nonexistent==0.0.0') | Set-Content $Requirements
        foreach ($Extra in @(@(), @('-Fix'))) {
            $Output = & $Pwsh -NoProfile -File (Join-Path $Root 'scripts/test-preflight.ps1') -Scope gate -RequirementsPath $Requirements -HarnessPath (Join-Path $Temporary 'absent-harness') @Extra 2>&1
            Assert ($LASTEXITCODE -eq 0 -and ($Output -join ' ') -match 'source: DANNY_SKILLS_TEST_PYTHON') "gate failed: $Output"
        }
        Assert (-not (Test-Path (Join-Path $Temporary 'absent-harness'))) 'gate created UI harness'
    }
    Case 'full preflight reports missing module and harness without installing system packages' {
        $env:DANNY_SKILLS_TEST_PYTHON = $RealPython
        $Output = & $Pwsh -NoProfile -File (Join-Path $Root 'scripts/test-preflight.ps1') -RequirementsPath $Requirements -HarnessPath (Join-Path $Temporary 'absent-harness') 2>&1
        Assert ($LASTEXITCODE -eq 1 -and ($Output -join ' ') -match 'fixture-nonexistent missing' -and ($Output -join ' ') -match 'UI harness') "full scope diagnostics missing: $Output"
        Assert (@(Get-Content (Join-Path $Temporary 'uv.jsonl')).Count -eq 3) 'override installed packages'
    }
    Case 'full scope checks externally resolved Chromium and -Fix never installs into override' {
        'tiktoken==0.12.0' | Set-Content $Requirements
        $Smoke = Join-Path $Temporary 'browser-smoke'
        $Playwright = Join-Path $Smoke 'node_modules/playwright'
        $Harness = Join-Path $Temporary 'harness'
        New-Item -ItemType Directory -Path $Playwright, (Join-Path $Harness 'node_modules') -Force | Out-Null
        $env:DANNY_BROWSER_SMOKE_DIR = $Smoke
        $env:DANNY_SKILLS_TEST_PYTHON = $RealPython
        'exports.chromium = { executablePath: () => __filename };' | Set-Content (Join-Path $Playwright 'index.js')
        $Output = & $Pwsh -NoProfile -File (Join-Path $Root 'scripts/test-preflight.ps1') -Fix -RequirementsPath $Requirements -HarnessPath $Harness 2>&1
        Assert ($LASTEXITCODE -eq 0) "full preflight failed: $Output"
        'exports.chromium = { executablePath: () => __filename + ".missing" };' | Set-Content (Join-Path $Playwright 'index.js')
        $Output = & $Pwsh -NoProfile -File (Join-Path $Root 'scripts/test-preflight.ps1') -RequirementsPath $Requirements -HarnessPath $Harness 2>&1
        Assert ($LASTEXITCODE -eq 1 -and ($Output -join ' ') -match 'Ranked renderer Chromium unavailable') "Chromium not checked: $Output"
        Remove-Item (Join-Path $Temporary 'installed')
        $Output = & $Pwsh -NoProfile -File (Join-Path $Root 'scripts/test-preflight.ps1') -Scope gate -Fix -RequirementsPath $Requirements -HarnessPath $Harness 2>&1
        Assert ($LASTEXITCODE -eq 1 -and ($Output -join ' ') -match 'tiktoken missing') "override missing import not reported: $Output"
        Assert (-not (Test-Path (Join-Path $Temporary 'installed'))) '-Fix modified override'
    }
    Case 'existing incomplete venv without uv reports a hint without installing' {
        $env:PATH = Split-Path -Parent $RealPython
        $Result = Resolve-TestPython -VenvPath $Venv -RequirementsPath $Requirements
        Assert ($Result.Source -eq 'standard venv' -and $Result.Hint -match 'uv missing') 'incomplete venv hint missing'
        Assert (@(Get-Content (Join-Path $Temporary 'uv.jsonl')).Count -eq 3) 'uv unexpectedly invoked'
        New-Item -ItemType File -Path (Join-Path $Temporary 'installed') | Out-Null
    }
    Case 'gate-style preflight retains venv PATH for later children in the same process' {
        $env:DANNY_SKILLS_TEST_PYTHON = Join-Path $Venv $(if ($IsWindows) { 'Scripts/python.exe' } else { 'bin/python' })
        $Wrapper = '& $args[0] -Scope gate -RequirementsPath $args[1]; if ($LASTEXITCODE -ne 0) { exit 1 }; (Get-Command python -CommandType Application | Select-Object -First 1).Source'
        $Output = & $Pwsh -NoProfile -CommandWithArgs $Wrapper (Join-Path $Root 'scripts/test-preflight.ps1') $Requirements 2>&1
        Assert ($LASTEXITCODE -eq 0 -and $env:DANNY_SKILLS_TEST_PYTHON -in $Output) "gate lost venv PATH: $Output"
    }
    Case 'failed re-probe stops after one install attempt' {
        Remove-Item (Join-Path $Temporary 'installed')
        $env:TEST_UV_SKIP_MARKER = '1'
        $env:PATH = $Bin
        $ErrorText = ''
        try { $null = Resolve-TestPython -VenvPath $Venv -RequirementsPath $Requirements }
        catch { $ErrorText = $_.ToString() }
        Assert ($ErrorText -match 'still failed after install') 'failed re-probe not reported'
        Assert (@(Get-Content (Join-Path $Temporary 'uv.jsonl')).Count -eq 4) 'install attempted more than once'
    }
    Case 'existing damaged venv is never recreated' {
        $Damaged = Join-Path $Temporary 'damaged'
        New-Item -ItemType Directory -Path $Damaged | Out-Null
        $env:PATH = $Bin + [IO.Path]::PathSeparator + $Saved.PATH
        $Result = Resolve-TestPython -VenvPath $Damaged -RequirementsPath $Requirements
        Assert ($Result.Source -eq 'PATH' -and $Result.Hint -match 'existing directory') 'damaged environment not explained'
        Assert (@(Get-Content (Join-Path $Temporary 'uv.jsonl')).Count -eq 4) 'damaged venv recreated'
    }
} finally {
    foreach ($Name in $Saved.Keys) { [Environment]::SetEnvironmentVariable($Name, $Saved[$Name]) }
    Remove-Item -LiteralPath $Temporary -Recurse -Force
}
Write-Output "SUMMARY: $Passed passed; $($Failures.Count) failed; no network or real uv install"
if ($Failures.Count) { $Failures | Write-Output; exit 1 }
