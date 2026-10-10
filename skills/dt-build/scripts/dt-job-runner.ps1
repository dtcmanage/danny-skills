#Requires -Version 7.0
# Detached runner for one dt-job job. dt-job.ps1 launches it hidden; never call it directly.
param(
    [Parameter(Mandatory)]
    [string]$RunFolder,

    [Parameter(Mandatory)]
    [string]$JobId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pass our own values so the dot-sourced param block does not clear them.
. (Join-Path $PSScriptRoot 'dt-job.ps1') -RunFolder $RunFolder -JobId $JobId

$paths = Get-DtJobPaths -RunFolder $RunFolder
$jobDir = Join-Path $paths.Jobs $JobId
$runnerLog = Join-Path $jobDir 'runner.log'
$process = $null

function Complete-DtJobRun {
    param([Parameter(Mandatory)][string]$Status, $ExitCode, [string]$Reason)
    Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $record = Get-DtJobRecord -RunFolder $RunFolder -JobId $JobId
        # A terminal result (cancel, reconcile) is never overwritten by this later write.
        if ($null -eq $record -or $record.status -ne 'running') { return }
        $record.exit_code = $ExitCode
        $record.last_progress = [DateTime]::UtcNow.ToString('o')
        Remove-DtJobKeyLocks -RunFolder $RunFolder -Record $record
        $record.status = $Status
        $record.status_reason = if ($Reason) { $Reason } else { $null }
        $record.ended = [DateTime]::UtcNow.ToString('o')
        Write-DtJobAtomic -Path ([string]$record.summary_path) -Content ((New-DtJobEnvelope -RunFolder $RunFolder -Record $record) | ConvertTo-Json -Depth 8)
        Set-DtJobState -RunFolder $RunFolder -Record $record -Status $Status -EventType 'completed' -Reason $Reason
        Invoke-DtJobSchedule -RunFolder $RunFolder
    }
}

try {
    $spec = Get-Content -Raw -LiteralPath (Join-Path $jobDir 'spec.json') | ConvertFrom-Json
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = (Get-Location).ProviderPath
    $psi.Environment['DT_JOB_ID'] = $JobId
    $psi.Environment['DT_JOB_DIR'] = $jobDir
    if ($spec.command) {
        # pwsh -Command reports 1 for any failing native command; this tail keeps the real exit code.
        $script = "`$global:LASTEXITCODE = 0`n$($spec.command)`n`$dtJobOk = `$?`nif (`$global:LASTEXITCODE -ne 0) { exit `$global:LASTEXITCODE }`nif (-not `$dtJobOk) { exit 1 }`nexit 0`n"
        $psi.FileName = [System.Environment]::ProcessPath
        foreach ($a in @('-NoProfile', '-NonInteractive', '-EncodedCommand', [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script)))) { $psi.ArgumentList.Add($a) }
    }
    elseif ([System.IO.Path]::GetExtension([string]$spec.script_path) -eq '.ps1') {
        $psi.FileName = [System.Environment]::ProcessPath
        foreach ($a in @('-NoProfile', '-NonInteractive', '-File', [string]$spec.script_path) + @($spec.argument_list)) { $psi.ArgumentList.Add([string]$a) }
    }
    else {
        $psi.FileName = [string]$spec.script_path
        foreach ($a in @($spec.argument_list)) { $psi.ArgumentList.Add([string]$a) }
    }

    # Recheck under the lock before starting: a job cancelled after launch never runs.
    $proceed = Invoke-DtJobLocked -RunFolder $RunFolder -Action {
        $record = Get-DtJobRecord -RunFolder $RunFolder -JobId $JobId
        if ($null -eq $record -or $record.status -ne 'running') { return $false }
        $record.runner_pid = $PID
        $record.runner_start_utc = Get-DtJobProcessStartUtc -ProcessId $PID
        Save-DtJobRecord -RunFolder $RunFolder -Record $record
        return $true
    }
    if (-not $proceed) { exit 0 }

    $stdoutFile = [System.IO.File]::Open((Join-Path $jobDir 'stdout.log'), [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $stderrFile = [System.IO.File]::Open((Join-Path $jobDir 'stderr.log'), [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        $copyOut = $process.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
        $copyErr = $process.StandardError.BaseStream.CopyToAsync($stderrFile)

        $stillOurs = Invoke-DtJobLocked -RunFolder $RunFolder -Action {
            $record = Get-DtJobRecord -RunFolder $RunFolder -JobId $JobId
            if ($null -eq $record -or $record.status -ne 'running') { return $false }
            $record.pid = $process.Id
            $record.process_start_utc = $process.StartTime.ToUniversalTime().ToString('o')
            $record.last_progress = [DateTime]::UtcNow.ToString('o')
            Save-DtJobRecord -RunFolder $RunFolder -Record $record
            Add-DtJobEvent -RunFolder $RunFolder -JobId $JobId -Type 'process_started' -Status 'running'
            return $true
        }
        if (-not $stillOurs) {
            $process.Kill($true)
            exit 0
        }

        $timeoutSec = [int]$spec.timeout_sec
        $finished = if ($timeoutSec -gt 0) { $process.WaitForExit($timeoutSec * 1000) } else { $process.WaitForExit(); $true }
        if (-not $finished) {
            $process.Kill($true)
            $process.WaitForExit()
            [void]$copyOut.Wait(5000); [void]$copyErr.Wait(5000)
            $stdoutFile.Flush(); $stderrFile.Flush()
            Complete-DtJobRun -Status 'timeout' -ExitCode $null -Reason "timed out after $timeoutSec s"
        }
        else {
            $process.WaitForExit()
            [void]$copyOut.Wait(5000); [void]$copyErr.Wait(5000)
            $stdoutFile.Flush(); $stderrFile.Flush()
            $exitCode = $process.ExitCode
            if ($exitCode -eq 0) { Complete-DtJobRun -Status 'succeeded' -ExitCode 0 }
            else { Complete-DtJobRun -Status 'failed' -ExitCode $exitCode -Reason "exit code $exitCode" }
        }
    }
    finally {
        $stdoutFile.Dispose()
        $stderrFile.Dispose()
    }
}
catch {
    $message = [string]$_.Exception.Message
    try { [System.IO.File]::AppendAllText($runnerLog, "$([DateTime]::UtcNow.ToString('o')) $message`n") } catch { }
    if ($null -ne $process -and -not $process.HasExited) { try { $process.Kill($true) } catch { } }
    Complete-DtJobRun -Status 'failed' -ExitCode $null -Reason "runner error: $message"
    exit 1
}
exit 0
