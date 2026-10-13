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

function Get-DtJobCommandScript {
    # Exit like `pwsh -Command`: the outcome of the final statement decides. LASTEXITCODE is reset just
    # before that statement, so an earlier handled native failure does not leak into the exit code, while
    # a failing final native command keeps its real exit code instead of pwsh's flattened 1.
    param([Parameter(Mandatory)][string]$Command)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$errors)
    $body = "`$global:LASTEXITCODE = 0`n$Command"
    if (@($errors).Count -eq 0 -and $null -ne $ast.EndBlock -and @($ast.EndBlock.Statements).Count -gt 0) {
        $offset = @($ast.EndBlock.Statements)[-1].Extent.StartOffset
        $body = $Command.Substring(0, $offset) + "`$global:LASTEXITCODE = 0; " + $Command.Substring($offset)
    }
    return "$body`n`$dtJobOk = `$?`nif (`$global:LASTEXITCODE -ne 0) { exit `$global:LASTEXITCODE }`nif (-not `$dtJobOk) { exit 1 }`nexit 0`n"
}

function Get-DtJobTreeCpuSeconds {
    # CPU seconds used so far by the job process and every process under it.
    param([Parameter(Mandatory)][int]$RootPid)
    if ($IsWindows) {
        $all = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, KernelModeTime, UserModeTime -ErrorAction Stop)
        $children = @{}
        foreach ($p in $all) { $key = [int]$p.ParentProcessId; if (-not $children.ContainsKey($key)) { $children[$key] = [System.Collections.Generic.List[object]]::new() }; $children[$key].Add($p) }
        $byId = @{}; foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
        $total = [double]0
        $queue = [System.Collections.Generic.Queue[int]]::new(); $queue.Enqueue($RootPid)
        $seen = [System.Collections.Generic.HashSet[int]]::new()
        while ($queue.Count -gt 0) {
            $id = $queue.Dequeue()
            if (-not $seen.Add($id)) { continue }
            if ($byId.ContainsKey($id)) { $total += ([double]$byId[$id].KernelModeTime + [double]$byId[$id].UserModeTime) / 1e7 }
            if ($children.ContainsKey($id)) { foreach ($c in $children[$id]) { $queue.Enqueue([int]$c.ProcessId) } }
        }
        return $total
    }
    return (Get-Process -Id $RootPid -ErrorAction Stop).TotalProcessorTime.TotalSeconds
}

function Wait-DtJobProcess {
    # Waits for the job without a time limit unless the job has one, and every heartbeat records whether
    # it showed any sign of life: CPU in its process tree, output, or file changes in its working
    # directory outside the run folder. Returns $false only when a job time limit ran out.
    param([Parameter(Mandatory)]$Process, [int]$TimeoutSec, [Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][System.IO.Stream[]]$Outputs, [string]$AdmissionReady)
    $heartbeatSec = Get-DtJobSettingSec -Name 'DT_JOB_HEARTBEAT_SEC' -Default $script:DtJobHeartbeatSec
    $beatPath = Join-Path $jobDir 'heartbeat.json'
    $runRoot = [System.IO.Path]::GetFullPath($paths.Root).TrimEnd('\', '/')
    $sourceId = "dtjob-fs-$JobId"
    $fsWatcher = $null
    try {
        $fsWatcher = [System.IO.FileSystemWatcher]::new($WorkDir)
        $fsWatcher.IncludeSubdirectories = $true
        $fsWatcher.InternalBufferSize = 65536
        foreach ($name in 'Changed', 'Created', 'Deleted', 'Renamed') { Register-ObjectEvent -InputObject $fsWatcher -EventName $name -SourceIdentifier "$sourceId-$name" | Out-Null }
        $fsWatcher.EnableRaisingEvents = $true
    }
    catch { $fsWatcher = $null }
    $started = [DateTime]::UtcNow
    $executionStarted = if ($AdmissionReady) { $null } else { $started }
    $lastActivity = $started
    $lastCpu = $null; $lastBytes = [long]-1; $fileChanges = 0; $newFiles = 0
    $nextBeat = $started
    try {
        while (-not $Process.WaitForExit(1000)) {
            if ($null -ne $fsWatcher) {
                foreach ($evt in @(Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "$sourceId-*" })) {
                    $full = [string]$evt.SourceEventArgs.FullPath
                    if (-not $full.StartsWith($runRoot, [System.StringComparison]::OrdinalIgnoreCase)) { $newFiles++ }
                    Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue
                }
            }
            $now = [DateTime]::UtcNow
            if ($null -eq $executionStarted -and (Test-Path -LiteralPath $AdmissionReady)) { $executionStarted = $now }
            if ($now -ge $nextBeat) {
                $cpu = try { Get-DtJobTreeCpuSeconds -RootPid $Process.Id } catch { $null }
                $bytes = [long]0; foreach ($s in $Outputs) { try { $bytes += $s.Position } catch { } }
                $active = $newFiles -gt 0 -or ($lastBytes -ge 0 -and $bytes -ne $lastBytes) -or ($null -ne $cpu -and $null -ne $lastCpu -and ($cpu - $lastCpu) -ge 1)
                if ($active) { $lastActivity = $now }
                $fileChanges += $newFiles; $newFiles = 0
                if ($null -ne $cpu) { $lastCpu = $cpu }
                $lastBytes = $bytes
                $beat = [ordered]@{ sampled_utc = $now.ToString('o'); last_activity_utc = $lastActivity.ToString('o'); cpu_seconds = $(if ($null -ne $cpu) { [int]$cpu } else { $null }); output_bytes = $bytes; file_changes = $fileChanges }
                try { Write-DtJobAtomic -Path $beatPath -Content ($beat | ConvertTo-Json -Compress) } catch { }
                $nextBeat = $now.AddSeconds($heartbeatSec)
            }
            if ($TimeoutSec -gt 0 -and $null -ne $executionStarted -and ($now - $executionStarted).TotalSeconds -ge $TimeoutSec) { return $false }
        }
        return $true
    }
    finally {
        if ($null -ne $fsWatcher) {
            $fsWatcher.EnableRaisingEvents = $false
            foreach ($name in 'Changed', 'Created', 'Deleted', 'Renamed') { Unregister-Event -SourceIdentifier "$sourceId-$name" -ErrorAction SilentlyContinue }
            Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like "$sourceId-*" } | Remove-Event -ErrorAction SilentlyContinue
            $fsWatcher.Dispose()
        }
    }
}

# Set once the child's result is known, so a failed ledger save cannot turn it into a runner error.
$outcome = $null

try {
    $spec = Read-DtJobText -Path (Join-Path $jobDir 'spec.json') | ConvertFrom-Json
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = (Get-Location).ProviderPath
    # This runner was started from the registry profile; restore the caller's allow-listed environment.
    if ($spec.PSObject.Properties['environment'] -and $null -ne $spec.environment) {
        foreach ($property in $spec.environment.PSObject.Properties) { $psi.Environment[$property.Name] = [string]$property.Value }
        # The runner's own heartbeat settings come from the caller too.
        foreach ($property in @($spec.environment.PSObject.Properties | Where-Object { $_.Name -like 'DT_JOB_*' })) { [System.Environment]::SetEnvironmentVariable($property.Name, [string]$property.Value) }
    }
    # Defense against an inherited watcher environment or legacy job spec.
    $psi.Environment.Remove('DT_BUILD_LEAN_BOOTSTRAP') | Out-Null
    $psi.Environment['DT_JOB_ID'] = $JobId
    $psi.Environment['DT_JOB_DIR'] = $jobDir
    if ($spec.command) {
        $script = Get-DtJobCommandScript -Command ([string]$spec.command)
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

    # Explicit pytest test jobs and commands share the machine lock, even
    # when the command launches a shell or a nested grader.
    $pytestReadyFile = $null
    . (Join-Path $DtJobRepoRoot 'scripts/pytest-command.ps1')
    if (Test-DannyPytestCommand -Command ([string]$spec.command) -Executable ([string]$spec.script_path) -ArgumentList @($spec.argument_list)) {
        $testExe = $psi.FileName
        $testArgs = @($psi.ArgumentList)
        $psi.ArgumentList.Clear()
        $psi.FileName = (Get-Command python -CommandType Application | Select-Object -First 1).Source
        $psi.ArgumentList.Add((Join-Path $DtJobRepoRoot 'scripts/pytest-lock.py'))
        $pytestReadyFile = Join-Path $jobDir ('pytest-ready-' + [guid]::NewGuid().ToString('N'))
        $psi.ArgumentList.Add('--ready-file')
        $psi.ArgumentList.Add($pytestReadyFile)
        $psi.ArgumentList.Add('--')
        $psi.ArgumentList.Add($testExe)
        foreach ($arg in $testArgs) { $psi.ArgumentList.Add($arg) }
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
        $finished = Wait-DtJobProcess -Process $process -TimeoutSec $timeoutSec -WorkDir $psi.WorkingDirectory -Outputs @($stdoutFile, $stderrFile) -AdmissionReady $pytestReadyFile
        if (-not $finished) {
            $process.Kill($true)
            $process.WaitForExit()
            [void]$copyOut.Wait(5000); [void]$copyErr.Wait(5000)
            $stdoutFile.Flush(); $stderrFile.Flush()
            $outcome = @{ Status = 'timeout'; ExitCode = $null; Reason = "timed out after $timeoutSec s" }
        }
        else {
            $process.WaitForExit()
            [void]$copyOut.Wait(5000); [void]$copyErr.Wait(5000)
            $stdoutFile.Flush(); $stderrFile.Flush()
            $exitCode = $process.ExitCode
            if ($exitCode -eq 0) { $outcome = @{ Status = 'succeeded'; ExitCode = 0; Reason = $null } }
            else { $outcome = @{ Status = 'failed'; ExitCode = $exitCode; Reason = "exit code $exitCode" } }
        }
        Complete-DtJobRun @outcome
    }
    finally {
        $stdoutFile.Dispose()
        $stderrFile.Dispose()
    }
}
catch {
    $message = [string]$_.Exception.Message
    try { [System.IO.File]::AppendAllText($runnerLog, "$([DateTime]::UtcNow.ToString('o')) $message`n") } catch { }
    if ($null -ne $outcome) {
        # The child finished; only recording it failed. Record the real result, not a runner error.
        Start-Sleep -Milliseconds 200
        Complete-DtJobRun @outcome
        exit 0
    }
    if ($null -ne $process -and -not $process.HasExited) { try { $process.Kill($true) } catch { } }
    Complete-DtJobRun -Status 'failed' -ExitCode $null -Reason "runner error: $message"
    exit 1
}
exit 0
