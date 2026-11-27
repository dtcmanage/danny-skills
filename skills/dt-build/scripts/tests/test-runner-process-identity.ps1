# Execute the production runner block. A ledger holder waits for the real child
# to exit before admitting the write, reproducing the Linux race deterministically.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scripts = Split-Path -Parent $PSScriptRoot
$runner = Get-Content -LiteralPath (Join-Path $scripts 'dt-job-runner.ps1') -Raw
# The extracted execution block uses the production asynchronous copy helper.
$tokens = $null; $errors = $null
$runnerAst = [Management.Automation.Language.Parser]::ParseInput($runner,[ref]$tokens,[ref]$errors)
$copyType = $runnerAst.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type' },$true)
if (-not $copyType) { throw 'Runner output-copy helper not found' }
. ([scriptblock]::Create($copyType.Extent.Text))
$start = $runner.IndexOf('        $process = [System.Diagnostics.Process]::Start($psi)')
$endToken = '        Complete-DtJobRun @outcome'
$end = $runner.IndexOf($endToken, $start) + $endToken.Length
if ($start -lt 0 -or $end -lt $start) { throw 'Runner execution block not found' }
$execution = [scriptblock]::Create($runner.Substring($start,$end-$start))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'dt-job.ps1'),[ref]$tokens,[ref]$errors)
$helper = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DtJobProcessStartUtc' },$true)
. ([scriptblock]::Create($helper.Extent.Text.Replace('function Get-DtJobProcessStartUtc {','function Get-ActualProcessStartUtc {')))
$root = Join-Path ([IO.Path]::GetTempPath()) ('runner-identity-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$passed = 0
try {
    foreach ($unavailable in @($false,$true)) {
        foreach ($expectedExit in @(0,7)) {
            $process = $null
            $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.RedirectStandardInput = $true
            foreach ($arg in @('-NoProfile','-Command',"Start-Sleep -Milliseconds 250; 'fast child'; exit $expectedExit")) { $psi.ArgumentList.Add($arg) }
            $stdoutFile = [IO.File]::Create((Join-Path $root 'stdout'))
            $stderrFile = [IO.File]::Create((Join-Path $root 'stderr'))
            $record = [pscustomobject]@{ status='running'; pid=$null; process_start_utc=$null; last_progress=$null }
            $RunFolder = $root; $JobId = 'fixture'; $pytestReadyFile = $null
            # Minimal script specs omit both command and argument_list. The
            # failure diagnostic must still complete with the real exit code.
            $spec = [pscustomobject]@{ timeout_sec=10; script_path='fixture.ps1' }; $outcome = $null
            function Get-DtJobProcessStartUtc {
                param([Diagnostics.Process]$Process)
                if ($unavailable -and -not $Process.WaitForExit(10000)) { throw 'Child did not exit' }
                Get-ActualProcessStartUtc -Process $Process
            }
            function Invoke-DtJobLocked {
                param($RunFolder,$Action)
                $held = [IO.File]::Open((Join-Path $RunFolder 'run.lock'),'OpenOrCreate','ReadWrite','None')
                try {
                    if (-not $process.WaitForExit(10000)) { throw 'Child did not exit while ledger lock held' }
                    if ($IsLinux -and $null -ne (Get-ActualProcessStartUtc -Process $process)) { throw 'Expected Linux identity to be unavailable after exit' }
                }
                finally { $held.Dispose() }
                & $Action
            }
            function Get-DtJobRecord { param($RunFolder,$JobId) return $record }
            function Save-DtJobRecord { param($RunFolder,$Record) }
            function Add-DtJobEvent { param($RunFolder,$JobId,$Type,$Status) }
            function Wait-DtJobProcess { param($Process,$TimeoutSec,$WorkDir,$Outputs,$AdmissionReady) return $Process.HasExited }
            function Complete-DtJobRun {
                param($Status,$ExitCode,$Reason)
                if ($ExitCode -ne $expectedExit -or $Status -ne $(if ($expectedExit -eq 0) { 'succeeded' } else { 'failed' })) { throw "Real child result lost: $Status / $ExitCode / $Reason" }
                $script:passed++
            }
            try {
                . $execution
                if ($IsLinux -and $unavailable -and $null -ne $record.process_start_utc) { throw 'Unavailable identity must be recorded as null' }
                if (-not $unavailable -and -not $record.process_start_utc) { throw 'Live identity was not captured before ledger admission' }
                $passed++
            }
            finally {
                if ($null -ne $process) { if (-not $process.HasExited) { $process.Kill($true) }; $process.Dispose() }
                $stdoutFile.Dispose(); $stderrFile.Dispose()
            }
        }
    }
    Write-Output "PASS: runner process identity ($passed assertions; exit 0 and 7, captured and unavailable identity, held ledger lock)"
}
finally { Remove-Item -LiteralPath $root -Recurse -Force }
