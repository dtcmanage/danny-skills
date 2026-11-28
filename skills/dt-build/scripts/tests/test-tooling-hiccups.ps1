# Regression fixtures own every process, registry and file. No live builds or model calls.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../../../scripts/lib/runtime-test-admission.ps1')
Enter-RuntimeTestSuite
$ErrorActionPreference = 'Stop'
$scripts = Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'dt-job.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('tooling-hiccups-' + [guid]::NewGuid().ToString('N'))
$savedRegistry = $env:DT_BUILD_STATE_DIR
$savedHeadless = $env:DT_BUILD_HEADLESS
$savedLogDir = $env:DT_BUILD_LOG_DIR
$env:DT_BUILD_STATE_DIR = Join-Path $root 'registry'
$env:DT_BUILD_HEADLESS = '1'
$env:DT_BUILD_LOG_DIR = '/stale/inherited/logs'
$failed = 0; $passed = 0; $launcher = $null
function Check($ok, $message) {
    if ($ok) { $script:passed++ } else { $script:failed++; Write-Output "FAIL: $message" }
}
function Job([string[]]$Arguments) {
    $out = & pwsh -NoProfile -File (Join-Path $scripts 'dt-job.ps1') @Arguments -AllowTempRunFolder -Json
    if ($LASTEXITCODE) { throw "fixture dt-job failed: $Arguments" }
    return ($out -join "`n" | ConvertFrom-Json)
}
try {
    $run = Join-Path $root 'run with spaces'
    New-Item -ItemType Directory $run -Force | Out-Null
    $state = Join-Path $run '_build-state.md'
    [IO.File]::WriteAllText($state, "run_status: runnable`nlast_consumed_event_seq: 0`nstatus_line: No jobs run while the fixture prepares its verification.`n## Authority`nOnly fixture operations permitted.`n")
    Job @('register-run','-RunFolder',$run,'-RunId','hiccup-fixture','-BuildStatePath',$state,'-PinnedHost','codex') | Out-Null

    # Both the real approval writer and checkpoint installer must publish a fresh pin, but cannot
    # repin an unrelated stale source. These are actual writes to isolated run state.
    $approvals = [pscustomobject]@{ awaiting=$null; approvals=@(); delegate=$null }
    Save-DtJobApprovals $run $approvals
    $null = & (Join-Path $scripts 'build-authority-digest.ps1') -RunFolder $run -BuildStatePath $state
    # Dynamic caller scope must not redirect the approval writer to another checkpoint.
    $BuildStatePath = Join-Path $root 'unrelated-state.md'
    [IO.File]::WriteAllText($BuildStatePath, "Unrelated authority must remain untouched.`n")
    $unrelatedState = [IO.File]::ReadAllText($BuildStatePath)
    $approvals.approvals = @([pscustomobject]@{ operation='fixture'; approved_by='fixture' })
    Save-DtJobApprovals $run $approvals
    $verified = & (Join-Path $scripts 'verify-authority-digest.ps1') -RunFolder $run -BuildStatePath $state | ConvertFrom-Json
    Check $verified.verified 'approval writer refreshes authority digest'
    Check ([IO.File]::ReadAllText($BuildStatePath) -ceq $unrelatedState) 'approval writer ignores unrelated ambient BuildStatePath'
    $candidate = Join-Path $root 'candidate.md'
    [IO.File]::WriteAllText($candidate, ([IO.File]::ReadAllText($state) + "`nAdditional restriction: fixture remains read-only outside its root.`n"))
    $null = & (Join-Path $scripts 'write-resume-checkpoint.ps1') -RunFolder $run -BuildStatePath $state -ContentPath $candidate
    $verified = & (Join-Path $scripts 'verify-authority-digest.ps1') -RunFolder $run -BuildStatePath $state | ConvertFrom-Json
    Check $verified.verified 'checkpoint installer pins the final checkpoint'
    $pin = [IO.File]::ReadAllText((Join-Path $run 'authority-digest.json.sha256'))
    $beforeApproval = [IO.File]::ReadAllText((Join-Path $run 'approvals.json'))
    $beforeState = [IO.File]::ReadAllText($state)
    [IO.File]::AppendAllText($state, "`nUnreviewed authority drift.`n")
    $driftedState = [IO.File]::ReadAllText($state)
    $rejected = $false
    try { Save-DtJobApprovals $run $approvals } catch { $rejected = $_.Exception.Message -like 'AUTHORITY_CHECKPOINT_HASH:*' }
    Check ($rejected -and [IO.File]::ReadAllText((Join-Path $run 'approvals.json')) -ceq $beforeApproval) 'approval writer refuses stale authority before mutation'
    $rejected = $false
    try { $null = & (Join-Path $scripts 'write-resume-checkpoint.ps1') -RunFolder $run -BuildStatePath $state -ContentPath $candidate } catch { $rejected = $_.Exception.Message -like 'AUTHORITY_CHECKPOINT_HASH:*' }
    Check ($rejected -and [IO.File]::ReadAllText((Join-Path $run 'authority-digest.json.sha256')) -ceq $pin) 'checkpoint writer refuses to bless stale authority'
    Check ([IO.File]::ReadAllText($state) -ceq $driftedState) 'checkpoint writer leaves stale checkpoint content unchanged'
    [IO.File]::WriteAllText($state, $beforeState)

    # Hold the worker until AFTER the start | tail caller exits. Its stdin must already be EOF.
    if (-not $IsWindows) {
        $ready = Join-Path $root 'ready.json'; $release = Join-Path $root 'release'
        $worker = Join-Path $root 'held.ps1'
        [IO.File]::WriteAllText($worker, @'
param($Ready, $Release)
$eof = $null -eq [Console]::ReadLine()
@{eof=$eof; log=$env:DT_BUILD_LOG_DIR; exists=(Test-Path -LiteralPath $env:DT_BUILD_LOG_DIR -PathType Container)} | ConvertTo-Json | Set-Content -LiteralPath $Ready
while (-not (Test-Path -LiteralPath $Release)) { Start-Sleep -Milliseconds 100 }
'worker survived caller'
'@)
        $jobPath = Join-Path $scripts 'dt-job.ps1'
        # Use a command string for two literal worker arguments.
        $workerCommand = "& '$worker' '$ready' '$release'"
        $command = "& '$jobPath' start -RunFolder '$run' -Command '" + $workerCommand.Replace("'", "''") + "' -AllowTempRunFolder -Json | & tail -n 1"
        $psi = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
        $psi.UseShellExecute=$false; $psi.RedirectStandardInput=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
        foreach ($arg in @('-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))) { $psi.ArgumentList.Add($arg) }
        $launcher = [Diagnostics.Process]::Start($psi)
        $outTask = $launcher.StandardOutput.ReadToEndAsync(); $errTask = $launcher.StandardError.ReadToEndAsync()
        $exited = $launcher.WaitForExit(30000)
        Check $exited 'dt-job start piped to tail exits while held worker survives'
        if ($exited) {
            Check ($launcher.ExitCode -eq 0) "launcher succeeds: $($errTask.GetAwaiter().GetResult())"
            $started = $outTask.GetAwaiter().GetResult() | ConvertFrom-Json
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path $ready) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
            Check (Test-Path $ready) 'worker receives EOF without waiting for caller stdin'
            if (Test-Path $ready) {
                $receipt = Get-Content -Raw $ready | ConvertFrom-Json
                $expectedLog = Join-Path $run "jobs/$($started.job_id)/logs"
                Check ($receipt.eof -and $receipt.exists -and $receipt.log -ceq $expectedLog) 'worker gets job-local log directory, replacing stale inherited path'
            }
            Check ((Job @('status','-RunFolder',$run,'-JobId',$started.job_id)).status -eq 'running') 'job is alive after piped caller exits'
            [IO.File]::WriteAllText($release, 'release')
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            do {
                $status = Job @('status','-RunFolder',$run,'-JobId',$started.job_id)
                if ($status.status -notin @('running','queued')) { break }
                Start-Sleep -Milliseconds 100
            } while ([DateTime]::UtcNow -lt $deadline)
            Check ($status.status -eq 'succeeded') 'detached worker completes normally'
        }
    }
} catch { $failed++; Write-Output "FAIL: $($_.Exception.Message) $($_.ScriptStackTrace)" }
finally {
    if ($launcher -and -not $launcher.HasExited) { $launcher.Kill($true) }
    if ($launcher) { $launcher.Dispose() }
    if ($run -and (Test-Path (Join-Path $run 'jobs'))) {
        foreach ($recordPath in Get-ChildItem (Join-Path $run 'jobs') -Filter 'j-*.json') {
            $jobRecord = Get-Content -Raw $recordPath.FullName | ConvertFrom-Json
            if ($jobRecord.status -in @('running','queued')) { Job @('cancel','-RunFolder',$run,'-JobId',$jobRecord.job_id) | Out-Null }
        }
    }
    $env:DT_BUILD_STATE_DIR=$savedRegistry; $env:DT_BUILD_HEADLESS=$savedHeadless; $env:DT_BUILD_LOG_DIR=$savedLogDir
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "SUMMARY: $passed passed, $failed failed"
if ($failed) { exit 1 }
