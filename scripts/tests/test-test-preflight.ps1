Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('fs66-preflight-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Temporary | Out-Null
$PriorPythonPath = $env:PYTHONPATH
$PriorSmokeDir = $env:DANNY_BROWSER_SMOKE_DIR
try {
    # Resolve Chromium through a synthetic external installation; never launch a browser.
    $Smoke = Join-Path $Temporary 'browser-smoke'
    $Playwright = Join-Path $Smoke 'node_modules/playwright'
    New-Item -ItemType Directory -Path $Playwright -Force | Out-Null
    '' | Set-Content -LiteralPath (Join-Path $Smoke 'smoke.mjs')
    "exports.chromium = { executablePath: () => __filename };" | Set-Content -LiteralPath (Join-Path $Playwright 'index.js')
    $env:DANNY_BROWSER_SMOKE_DIR = $Smoke
    $Requirements = Join-Path $Temporary 'requirements.txt'
    'fs66-nonexistent-package==0.0.0' | Set-Content -LiteralPath $Requirements
    $Output = & pwsh -NoProfile -File (Join-Path $Root 'scripts/test-preflight.ps1') -RequirementsPath $Requirements 2>&1
    $Code = $LASTEXITCODE
    $Expected = "fs66-nonexistent-package missing or cannot import; fix: python -m pip install --user -r `"$Requirements`""
    if ($Code -ne 1) { throw "Expected exit 1, got $Code" }
    if ($Expected -notin $Output) { throw "Expected fix line absent: $($Output -join [Environment]::NewLine)" }
    Write-Output 'PASS: missing module exits 1 with the exact fix command.'

    $Harness = Join-Path $Temporary 'absent-harness'
    @('tiktoken==0.12.0', 'fs66-nonexistent-package==0.0.0') | Set-Content -LiteralPath $Requirements
    foreach ($Extra in @(@(), @('-Fix'))) {
        $Output = & pwsh -NoProfile -File (Join-Path $Root 'scripts/test-preflight.ps1') -Scope gate -RequirementsPath $Requirements -HarnessPath $Harness @Extra 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Gate failed with absent harness: $($Output -join [Environment]::NewLine)" }
        if (Test-Path -LiteralPath $Harness) { throw 'Gate created the harness directory.' }
    }
    Write-Output 'PASS: gate and gate -Fix ignore absent UI dependencies and full-only Python modules.'

    $Output = & pwsh -NoProfile -File (Join-Path $Root 'scripts/test-preflight.ps1') -RequirementsPath $Requirements -HarnessPath $Harness 2>&1
    if ($LASTEXITCODE -ne 1 -or $Expected -notin $Output -or -not @($Output | Where-Object { $_ -like 'UI harness node_modules missing;*' }).Count) {
        throw "Default full scope did not report both missing dependencies: $($Output -join [Environment]::NewLine)"
    }
    Write-Output 'PASS: default full scope still checks full-only modules and the UI harness.'

    # Shadow only fixture Python modules; pip records argv instead of installing.
    $PipFixture = Join-Path $Temporary 'pip'
    New-Item -ItemType Directory -Path $PipFixture | Out-Null
    '' | Set-Content -LiteralPath (Join-Path $PipFixture '__init__.py')
    @'
from pathlib import Path
if not (Path(__file__).parent / 'installed').exists():
    raise ImportError('fixture missing tiktoken')
'@ | Set-Content -LiteralPath (Join-Path $Temporary 'tiktoken.py')
    @'
import json, sys
from pathlib import Path
root = Path(__file__).parent.parent
(root / 'pip-args.json').write_text(json.dumps(sys.argv[1:]))
(root / 'installed').touch()
'@ | Set-Content -LiteralPath (Join-Path $PipFixture '__main__.py')
    $env:PYTHONPATH = $Temporary
    $Output = & pwsh -NoProfile -File (Join-Path $Root 'scripts/test-preflight.ps1') -Scope gate -RequirementsPath $Requirements -HarnessPath $Harness 2>&1
    if ($LASTEXITCODE -ne 1 -or 'tiktoken missing or cannot import; fix: python -m pip install --user tiktoken==0.12.0' -notin $Output) {
        throw "Gate did not detect missing required module: $($Output -join [Environment]::NewLine)"
    }
    $Output = & pwsh -NoProfile -File (Join-Path $Root 'scripts/test-preflight.ps1') -Scope gate -Fix -RequirementsPath $Requirements -HarnessPath $Harness 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Gate fix failed: $($Output -join [Environment]::NewLine)" }
    $PipArgs = @(Get-Content -Raw -LiteralPath (Join-Path $Temporary 'pip-args.json') | ConvertFrom-Json)
    if (($PipArgs -join ' ') -ne 'install --user tiktoken==0.12.0') { throw "Gate pip installed unexpected packages: $PipArgs" }
    if (Test-Path -LiteralPath $Harness) { throw 'Gate fix touched the UI harness.' }
    Write-Output 'PASS: gate detects tiktoken and -Fix installs only its pinned gate requirement, then rechecks.'

    Remove-Item -LiteralPath (Join-Path $Temporary 'installed')
    Copy-Item -LiteralPath (Join-Path $Temporary 'tiktoken.py') -Destination (Join-Path $Temporary 'fs66_nonexistent_package.py')
    New-Item -ItemType Directory -Path (Join-Path $Harness 'node_modules') -Force | Out-Null
    $Output = & pwsh -NoProfile -File (Join-Path $Root 'scripts/test-preflight.ps1') -Fix -RequirementsPath $Requirements -HarnessPath $Harness 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Full fix failed: $($Output -join [Environment]::NewLine)" }
    $PipArgs = @(Get-Content -Raw -LiteralPath (Join-Path $Temporary 'pip-args.json') | ConvertFrom-Json)
    if ($PipArgs.Count -ne 4 -or ($PipArgs[0..2] -join ' ') -ne 'install --user -r' -or $PipArgs[3] -ne $Requirements) {
        throw "Full fix did not install the full manifest: $PipArgs"
    }
    Write-Output 'PASS: default full -Fix installs the full requirements manifest and rechecks.'

    "exports.chromium = { executablePath: () => __filename + '.missing' };" | Set-Content -LiteralPath (Join-Path $Playwright 'index.js')
    $Output = & pwsh -NoProfile -File (Join-Path $Root 'scripts/test-preflight.ps1') -RequirementsPath $Requirements -HarnessPath $Harness 2>&1
    $RendererFix = 'Ranked renderer Chromium unavailable; fix: set DANNY_BROWSER_SMOKE_DIR to an installed browser-smoke folder, or run npm ci and npx playwright install chromium in that folder.'
    if ($LASTEXITCODE -ne 1 -or $RendererFix -notin $Output) { throw "Missing Chromium was not reported: $($Output -join [Environment]::NewLine)" }
    Write-Output 'PASS: full scope rejects a resolved package with a missing Chromium executable and prints the fix.'
    $Output = & pwsh -NoProfile -File (Join-Path $Root 'scripts/test-preflight.ps1') -Scope gate -RequirementsPath $Requirements -HarnessPath $Harness 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Gate checked Chromium: $($Output -join [Environment]::NewLine)" }
    Write-Output 'PASS: gate scope ignores missing Chromium.'
} finally {
    $env:PYTHONPATH = $PriorPythonPath
    $env:DANNY_BROWSER_SMOKE_DIR = $PriorSmokeDir
    $ResolvedTemporary = [IO.Path]::GetFullPath($Temporary)
    $TempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $ResolvedTemporary.StartsWith($TempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped temp root.' }
    Remove-Item -LiteralPath $ResolvedTemporary -Recurse -Force
}
