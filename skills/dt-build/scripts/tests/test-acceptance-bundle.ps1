param([Parameter(Mandatory)][string]$LogDirectory, [Parameter(Mandatory)][string]$MainSource)
# One legitimate lease; descendants inherit its verified ancestry. Runtime suites
# are sequential because they exercise the same registry/admission machinery.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../../scripts/lib/runtime-test-admission.ps1')
Enter-RuntimeTestSuite
$env:DT_TEST_WORKER_LIMIT = '6'
New-Item -ItemType Directory $LogDirectory -Force | Out-Null
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
$selection = @(
    @{ name='authority'; argv=@('pwsh','-NoProfile','-File',"$PSScriptRoot/test-authority-digest.ps1") },
    @{ name='bootstrap'; argv=@('python3','-m','pytest','-n','6','-q',"$PSScriptRoot/test-resume-bootstrap.py") },
    @{ name='authority-rollover'; argv=@('pwsh','-NoProfile','-File',"$PSScriptRoot/test-authority-rollover.ps1") },
    @{ name='heartbeat'; argv=@('pwsh','-NoProfile','-File',"$PSScriptRoot/test-heartbeat-paths.ps1") },
    @{ name='control'; argv=@('pwsh','-NoProfile','-File',"$PSScriptRoot/test-control-compatibility.ps1") },
    @{ name='launch-watch'; argv=@('pwsh','-NoProfile','-File',"$PSScriptRoot/test-launch-watch.ps1") },
    @{ name='envelope-main'; argv=@('pwsh','-NoProfile','-File',"$PSScriptRoot/test-envelope-boundary.ps1",'-DtJobPath',"$MainSource/skills/dt-build/scripts/dt-job.ps1",'-ObserveOnly') },
    @{ name='envelope-current'; argv=@('pwsh','-NoProfile','-File',"$PSScriptRoot/test-envelope-boundary.ps1") },
    @{ name='dt-job'; argv=@('pwsh','-NoProfile','-File',"$PSScriptRoot/test-dt-job.ps1") },
    @{ name='build-regressions'; argv=@('pwsh','-NoProfile','-File',"$PSScriptRoot/../test-dt-build-regressions.ps1") }
)
$results = @()
foreach ($test in $selection) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    # Start-Process file redirection avoids pipe capture held by grandchildren.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('& ' + (($test.argv | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ' ') + '; exit $LASTEXITCODE'))
    $child = Start-Process (Join-Path $PSHOME 'pwsh') -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) -WorkingDirectory $repo -RedirectStandardOutput "$LogDirectory/$($test.name).log" -RedirectStandardError "$LogDirectory/$($test.name).stderr.log" -PassThru
    "RUNNING: $($test.name) pid=$($child.Id) command=$($test.argv -join ' ')"
    [IO.File]::AppendAllText("$LogDirectory/pids.log", "$($child.Id) $($test.name)`n")
    try {
        $child.WaitForExit()
        $row = [ordered]@{ name=$test.name; command=$test.argv; exit=$child.ExitCode; seconds=[math]::Round($clock.Elapsed.TotalSeconds,2) }
        $results += $row
        [IO.File]::WriteAllText("$LogDirectory/results.json", (ConvertTo-Json -InputObject @($results) -Depth 8))
        "RESULT: $($test.name) exit=$($child.ExitCode) seconds=$($row.seconds)"
    } finally {
        if (-not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }
        $child.Dispose()
    }
}
if (@($results | Where-Object { $_.exit -ne 0 }).Count) { exit 1 }
