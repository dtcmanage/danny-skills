param(
    [ValidateRange(30, 1800)][int]$SuiteTimeoutSeconds = 300,
    [string]$EvidencePath = (Join-Path ([IO.Path]::GetTempPath()) ('mac-regressions-' + [guid]::NewGuid().ToString('N')))
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Actual OS, never the router's fixture platform selector: M01 exercises Windows
# authority, named mutexes and Start-Process -WindowStyle Hidden.
if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    throw 'ROUTER_REGRESSIONS_WINDOWS_ONLY: Run the full gate on Windows; test-mac-observer.ps1 stands alone on Mac.'
}
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$evidence = [IO.Path]::GetFullPath($EvidencePath)
if (Test-Path -LiteralPath $evidence) { throw 'EvidencePath must be a new directory owned by this run.' }
[IO.Directory]::CreateDirectory($evidence) | Out-Null
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('mac-regressions-fixtures-' + [guid]::NewGuid().ToString('N'))
$results = [Collections.Generic.List[object]]::new()
$suites = @(
    'scripts/model-router/tests/test-mac-integration.ps1',
    'scripts/model-router/tests/test-mac-observer.ps1',
    'scripts/model-router/tests/test-resolve-roster.ps1',
    'scripts/model-router/tests/test-roster-approval.ps1',
    'scripts/model-router/tests/test-router-cadence.ps1',
    'scripts/model-router/tests/test-vendor-limits.ps1',
    'scripts/model-router/tests/test-dispatch-diagnosis.ps1',
    'scripts/model-router/tests/test-consumer-wiring.ps1',
    'scripts/model-router/tests/test-build-roster.ps1',
    'scripts/model-router/tests/test-check-new-models.ps1',
    'scripts/model-router/tests/test-router-research.ps1',
    'scripts/model-router/tests/test-canary.ps1',
    'scripts/model-router/tests/test-cost-report.ps1',
    'scripts/model-router/tests/test_cost_report.py',
    'skills/dt-build/scripts/test-dt-build-regressions.ps1'
)
try {
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    $transport = Join-Path $fixtureRoot 'reject-alert.ps1'
    [IO.File]::WriteAllText($transport, @'
param($request)
Add-Content -LiteralPath $env:DT_M03_UNEXPECTED_ALERT -Value 'UNEXPECTED_ALERT_TRANSPORT'
throw 'UNEXPECTED_ALERT_TRANSPORT'
'@)
    $wrapper = Join-Path $fixtureRoot 'suite.ps1'
    [IO.File]::WriteAllText($wrapper, @'
param([string]$Fixture, [string]$Suite)
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Continue'
. $Fixture
$saved = Enter-RouterTestCodexHome
try {
    & $Suite
    # A nested PowerShell script's `exit N` returns to its caller. Preserve that
    # failure before fixture cleanup can replace the success flag.
    if (-not $?) {
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
        throw 'Suite returned failure.'
    }
} finally { Exit-RouterTestCodexHome $saved }
'@)
    foreach ($suite in $suites) {
        $name = [IO.Path]::GetFileNameWithoutExtension($suite)
        $sandbox = Join-Path $fixtureRoot $name
        foreach ($dir in @('state','shared','sessions','codex','claude','tmp')) {
            [IO.Directory]::CreateDirectory((Join-Path $sandbox $dir)) | Out-Null
        }
        $stdout = Join-Path $evidence ($name + '.stdout.log')
        $stderr = Join-Path $evidence ($name + '.stderr.log')
        $unexpectedAlert = Join-Path $sandbox 'unexpected-alert.log'
        $process = [Diagnostics.Process]::new()
        $outFile = $null; $errFile = $null; $timedOut = $false; $exitCode = -1
        $failure = $null; $started = $false
        Write-Output "RUN: $suite (timeout ${SuiteTimeoutSeconds}s)"
        try {
            $python = $suite.EndsWith('.py')
            $exe = if ($python) { (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source } else { Join-Path $PSHOME 'pwsh.exe' }
            $info = [Diagnostics.ProcessStartInfo]::new($exe)
            $info.UseShellExecute = $false; $info.CreateNoWindow = $true
            $info.WorkingDirectory = $repo
            $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
            # Only the child environment changes. Discard inherited opt-ins and seams.
            foreach ($key in @($info.Environment.Keys)) {
                if ($key -like 'DT_MODEL_ROUTER_*' -or $key -like 'DT_BUILD_*' -or $key -like 'DT_FAKE_*') { $null = $info.Environment.Remove($key) }
            }
            $info.Environment['DT_MODEL_ROUTER_STATE'] = Join-Path $sandbox 'state'
            $info.Environment['DT_MODEL_ROUTER_SHARED'] = Join-Path $sandbox 'shared'
            $info.Environment['DT_MODEL_ROUTER_CODEX_SESSIONS'] = Join-Path $sandbox 'sessions'
            $info.Environment['CODEX_HOME'] = Join-Path $sandbox 'codex'
            $info.Environment['CLAUDE_CONFIG_DIR'] = Join-Path $sandbox 'claude'
            # Exclusive missing file prevents file/Keychain/live-token fallback.
            $info.Environment['DT_MODEL_ROUTER_CLAUDE_CREDENTIALS'] = Join-Path $sandbox 'missing-credentials.json'
            $info.Environment['DT_MODEL_ROUTER_ALERT_TRANSPORT'] = $transport
            $info.Environment['DT_M03_UNEXPECTED_ALERT'] = $unexpectedAlert
            $info.Environment['TEMP'] = Join-Path $sandbox 'tmp'
            $info.Environment['TMP'] = Join-Path $sandbox 'tmp'
            $info.Environment['PYTHONDONTWRITEBYTECODE'] = '1'
            $info.Environment['PYTEST_DISABLE_PLUGIN_AUTOLOAD'] = '1'
            # Never alter HOME or LOCALAPPDATA (Windows Python manager shim).
            $arguments = if ($python) {
                @('-B','-m','pytest',$suite,'-q','-p','no:cacheprovider','--basetemp',(Join-Path $sandbox 'pytest'))
            } else {
                @('-NoProfile','-NonInteractive','-File',$wrapper,'-Fixture',(Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1'),'-Suite',(Join-Path $repo $suite))
            }
            foreach ($argument in $arguments) { $info.ArgumentList.Add($argument) }
            $process.StartInfo = $info
            $outFile = [IO.File]::Create($stdout); $errFile = [IO.File]::Create($stderr)
            $null = $process.Start()
            $started = $true
            $outCopy = $process.StandardOutput.BaseStream.CopyToAsync($outFile)
            $errCopy = $process.StandardError.BaseStream.CopyToAsync($errFile)
            if (-not $process.WaitForExit($SuiteTimeoutSeconds * 1000)) {
                $timedOut = $true; $process.Kill($true)
                if (-not $process.WaitForExit(10000)) { throw 'Child tree did not exit after termination.' }
            }
            $exitCode = $process.ExitCode
            if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outCopy,$errCopy),10000)) { throw 'Output capture did not complete.' }
        } catch { $failure = $_.Exception.Message }
        finally {
            if ($started -and -not $process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(10000) }
            $process.Dispose()
            if ($outFile) { $outFile.Dispose() }; if ($errFile) { $errFile.Dispose() }
        }
        $output = (@(Get-Content -LiteralPath $stdout -ErrorAction SilentlyContinue) + @(Get-Content -LiteralPath $stderr -ErrorAction SilentlyContinue)) -join "`n"
        $count = $null
        $patterns = if ($suite.EndsWith('.py')) { @('(?m)(\d+) passed') } else {
            @('(?m)^SUMMARY: (\d+) passed','(?m)^SUMMARY: PASS \((\d+) checks\)','(?m)^TOTAL PASS: (\d+)','(?m)^PASS: (\d+) tests')
        }
        foreach ($pattern in $patterns) {
            $matchesFound = [regex]::Matches($output,$pattern)
            if ($matchesFound.Count) { $count = [int]$matchesFound[-1].Groups[1].Value; break }
        }
        $ok = $exitCode -eq 0 -and -not $timedOut -and -not $failure -and $null -ne $count -and $count -gt 0 -and -not (Test-Path -LiteralPath $unexpectedAlert)
        if ($output -match '(?m)^SUMMARY: .*\b[1-9]\d* failed' -or ($suite.EndsWith('.py') -and $output -match '\b[1-9]\d* failed\b')) { $ok = $false }
        $status = if ($ok) { 'PASS' } else { 'FAIL' }
        $results.Add([pscustomobject]@{ suite=$suite; status=$status; passed=$count; exit_code=$exitCode; timed_out=$timedOut; error=$failure; stdout=$stdout; stderr=$stderr })
        Write-Output "${status}: $suite; passed=$count; exit=$exitCode; timed_out=$timedOut"
        # Keep every warning visible, with full output retained in evidence logs.
        $output -split "`n" | Where-Object { $_ -match 'WARNING:|^WARN:' } | ForEach-Object { Write-Output $_ }
        if (-not $ok) { Write-Output "ERROR: $failure; unexpected_alert=$(Test-Path -LiteralPath $unexpectedAlert)"; $output -split "`n" | Select-Object -Last 40 | Write-Output }
    }
} finally {
    # Validate the absolute owned target before recursive cleanup, including on errors.
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped temp root.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
$failed = @($results | Where-Object status -eq 'FAIL').Count
$total = ($results | Measure-Object -Property passed -Sum).Sum
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $evidence 'results.json')
Write-Output "SUMMARY: $($results.Count - $failed)/$($suites.Count) suites passed; $failed failed; $total checks passed; native Mac acceptance UNVERIFIED"
Write-Output "EVIDENCE: $evidence"
if ($failed -or $results.Count -ne $suites.Count) { exit 1 }
