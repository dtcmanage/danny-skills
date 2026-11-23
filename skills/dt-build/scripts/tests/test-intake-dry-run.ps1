#Requires -Version 7.0
# B2 fixes 7 and 9: intake never nests <RunId>/<RunId>, and it warns about gate test tools the roadmap names but
# the host lacks (pytest, pytest-xdist, Pester 5, tiktoken) with exact install commands. Fixtures only.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:passed = 0
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "ASSERT_FAIL: $Message" }
    $script:passed++; Write-Output "PASS: $Message"
}
function Write-Utf8([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
$scripts = Split-Path -Parent $PSScriptRoot
$roadmap = Join-Path $PSScriptRoot 'fixtures/intake-gate-tooling-roadmap.md'
$root = Join-Path ([IO.Path]::GetTempPath()) ('intake-b2-' + [guid]::NewGuid().ToString('N'))
$savedPath = $env:PATH; $savedModulePath = $env:PSModulePath
try {
    $repo = Join-Path $root 'target repo'
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git -C $repo init -q -b main
    & git -C $repo -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m base
    if ($LASTEXITCODE -ne 0) { throw 'fixture git repo failed' }

    # ---- fix 7: -OutputDirectory may be the parent of run folders or the run folder itself.
    $runFolder = Join-Path $repo '.dt-build/run-b2'
    $raw = & pwsh -NoProfile -File (Join-Path $scripts 'intake-dry-run.ps1') -RepoPath $repo -RoadmapPath $roadmap -OutputDirectory $runFolder -RunId run-b2 -Json 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "intake into the run folder itself succeeds ($($raw -join ' '))"
    $result = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($result.output_run_directory -eq [IO.Path]::GetFullPath($runFolder) -and (Test-Path -LiteralPath (Join-Path $runFolder 'build-plan.md')) -and -not (Test-Path -LiteralPath (Join-Path $runFolder 'run-b2'))) "an -OutputDirectory ending in the RunId is used as the run folder, never <run>/<run> ($($result.output_run_directory))"
    $parentRaw = & pwsh -NoProfile -File (Join-Path $scripts 'intake-dry-run.ps1') -RepoPath $repo -RoadmapPath $roadmap -OutputDirectory (Join-Path $repo '.dt-build-parent') -RunId run-b3 -Json 2>&1
    $parentResult = ($parentRaw -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $parentResult.output_run_directory -eq [IO.Path]::GetFullPath((Join-Path $repo '.dt-build-parent/run-b3'))) 'a parent -OutputDirectory still gets <parent>/<RunId>'
    $help = Get-Help (Join-Path $scripts 'intake-dry-run.ps1') -Full | Out-String
    Assert-True ($help -match 'OutputDirectory' -and $help -match 'Never nests') 'header help documents -OutputDirectory'

    # ---- fix 9: the intake report carries a gate_tooling block (warning only, never a failure).
    Assert-True ($null -ne $result.gate_tooling -and @($result.gate_tooling.checked.tool) -join ',' -eq 'pytest,pytest-xdist,pester,tiktoken') "intake checks every gate tool the roadmap names ($(@($result.gate_tooling.checked.tool) -join ','))"
    Assert-True (@($result.warnings).Count -eq @($result.gate_tooling.missing).Count -and $result.pass) 'missing gate tools are warnings in the intake report, never an intake failure'

    $check = Join-Path $scripts 'check-gate-tooling.ps1'
    $emptyBin = Join-Path $root 'empty-bin'
    $emptyModules = Join-Path $root 'empty-modules'
    New-Item -ItemType Directory -Path $emptyBin, $emptyModules -Force | Out-Null
    $env:PATH = $emptyBin; $env:PSModulePath = $emptyModules
    $bare = & $check -RoadmapPath $roadmap -RepoPath $repo
    $env:PATH = $savedPath; $env:PSModulePath = $savedModulePath
    Assert-True ((@($bare.missing.tool) -join ',') -eq 'pytest,pytest-xdist,pester,tiktoken') "a fresh host with no Python tools and no Pester reports all four ($(@($bare.missing.tool) -join ','))"
    $pesterHint = @($bare.missing | Where-Object tool -eq 'pester')[0].install
    Assert-True ($pesterHint.Contains('Install-Module Pester -Scope CurrentUser')) "Pester hint is exact ($pesterHint)"
    $pyHint = @($bare.missing | Where-Object tool -eq 'pytest')[0].install
    Assert-True ($pyHint.StartsWith('uv venv && uv pip install pytest pytest-xdist tiktoken')) "without requirements-test.txt the hint installs exactly the missing modules ($pyHint)"
    Assert-True (@($bare.warnings | Where-Object { $_ -like 'GATE_TOOLING_MISSING: *Install: *' }).Count -eq 4) 'each missing tool has one warning with its install command'
    Write-Utf8 (Join-Path $repo 'requirements-test.txt') "pytest`npytest-xdist`ntiktoken`n"
    $env:PATH = $emptyBin; $env:PSModulePath = $emptyModules
    $withReq = & $check -RoadmapPath $roadmap -RepoPath $repo
    $env:PATH = $savedPath; $env:PSModulePath = $savedModulePath
    $reqHint = @($withReq.missing | Where-Object tool -eq 'pytest-xdist')[0].install
    Assert-True ($reqHint.Contains('uv venv && uv pip install -r requirements-test.txt') -and $reqHint.Contains($repo)) "with requirements-test.txt the hint is uv venv + uv pip install -r requirements-test.txt in the repo ($reqHint)"
    if (-not $IsWindows) {
        # A fake interpreter that has everything except xdist; a roadmap-named venv is checked too.
        $fakeBin = Join-Path $root 'fake-bin'
        Write-Utf8 (Join-Path $fakeBin 'python3') "#!/bin/sh`ncase `"`$*`" in *\'xdist\'*) exit 1;; esac`nexit 0`n"
        & chmod +x (Join-Path $fakeBin 'python3')
        $venv = Join-Path $root 'gate-venv'
        Write-Utf8 (Join-Path $venv 'bin/python') "#!/bin/sh`nexit 0`n"
        & chmod +x (Join-Path $venv 'bin/python')
        $env:PATH = $fakeBin; $env:PSModulePath = $emptyModules
        $partial = & $check -RoadmapPath $roadmap -RepoPath $repo
        $env:PATH = $savedPath
        Assert-True ((@($partial.missing.tool) -join ',') -eq 'pytest-xdist,pester') "only the tools the interpreter lacks are reported ($(@($partial.missing.tool) -join ','))"
        $venvRoadmap = Join-Path $root 'roadmap-venv.md'
        Write-Utf8 $venvRoadmap ([IO.File]::ReadAllText($roadmap) + "`nGates run from the venv ``$venv`` with ``pytest -n 4``.`n")
        $env:PATH = $fakeBin
        $viaVenv = & $check -RoadmapPath $venvRoadmap -RepoPath $repo
        $env:PATH = $savedPath; $env:PSModulePath = $savedModulePath
        Assert-True ((@($viaVenv.missing.tool) -join ',') -eq 'pester' -and @($viaVenv.interpreters) -contains (Join-Path $venv 'bin/python')) "a venv the roadmap names counts as an interpreter ($(@($viaVenv.missing.tool) -join ','))"
    }
    $quiet = Join-Path $root 'roadmap-none.md'
    Write-Utf8 $quiet "## Verification`nRun ``node --test`` and capture PASS/FAIL.`n"
    Assert-True (@((& $check -RoadmapPath $quiet).checked).Count -eq 0) 'a roadmap naming no gate tools checks nothing'
    Write-Output "SUMMARY: $script:passed passed"
}
finally {
    $env:PATH = $savedPath; $env:PSModulePath = $savedModulePath
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
