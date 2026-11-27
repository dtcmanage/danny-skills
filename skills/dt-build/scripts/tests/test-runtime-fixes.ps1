# Focused runtime regressions. Every process, file root and Git ref is fixture-owned.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scripts = Split-Path -Parent $PSScriptRoot
$job = Join-Path $scripts 'dt-job.ps1'
. (Join-Path $PSScriptRoot 'test-shell.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('runtime-fixes-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$failed = 0; $passed = 0
function Check($ok, $message) { if ($ok) { $script:passed++ } else { $script:failed++; Write-Output "ASSERT_FAIL: $message" } }
function JobCall([string[]]$arguments) {
    $result = Invoke-TestShell -File $job -Arguments ($arguments + @('-AllowTempRunFolder','-Json'))
    $raw = $result.Output
    if ($result.ExitCode) { throw "job command failed: $arguments $raw $($result.ErrorText)" }
    return ($raw -join "`n" | ConvertFrom-Json)
}
function WaitDone($run, $id) {
    $until = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $r = JobCall @('status','-RunFolder',$run,'-JobId',$id)
        if ($r.status -notin 'queued','running') { return $r }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $until)
    throw "fixture job did not finish: $id"
}
$run = Join-Path $root 'run'; $run2 = Join-Path $root 'run2'
$tree = Join-Path $root 'tree'; $otherTree = Join-Path $root 'other-tree'
New-Item -ItemType Directory -Path $run,$run2,$tree,$otherTree | Out-Null
$state = Join-Path $run '_build-state.md'
[IO.File]::WriteAllText($state, "updated_utc: fixture`nstatus_line: old job is still rebasing now`nrun_status: runnable`nlast_consumed_event_seq: 0`nbody: preserve me`n")
$env:DT_BUILD_STATE_DIR = Join-Path $root 'state'
$env:DT_JOB_HEARTBEAT_SEC = '1'
$originalStallSec = $env:DT_JOB_STALL_SEC
try {
    JobCall @('register-run','-RunFolder',$run,'-RunId','runtime-fixture','-BuildStatePath',$state,'-PinnedHost','codex') | Out-Null
    $candidate = Join-Path $root 'older-checkpoint.md'
    [IO.File]::Copy($state, $candidate)
    & git -C $tree init -q
    & git -C $tree config user.name Fixture
    & git -C $tree config user.email fixture@example.invalid
    [IO.File]::WriteAllText((Join-Path $tree 'base'), 'base')
    & git -C $tree add .
    & git -C $tree commit -qm base
    & git -C $tree branch -M main
    $base = (& git -C $tree rev-parse HEAD).Trim()
    & git -C $tree worktree add -qb fixture-other $otherTree HEAD 2>$null
    $a = JobCall @('start','-RunFolder',$run,'-WorkingTree',$tree,'-Writes','-Command','Start-Sleep 60')
    Check ($a.status -eq 'running') 'first writer starts'
    Check ((Get-Content -Raw $state) -match '1 job is running: j-0001' -and (Get-Content -Raw $state) -match 'body: preserve me') 'start refreshes status without rewriting body'
    $installed = & pwsh -NoProfile -File (Join-Path $scripts 'write-resume-checkpoint.ps1') -RunFolder $run -BuildStatePath $state -ContentPath $candidate
    Check ($LASTEXITCODE -eq 0 -and (Get-Content -Raw $state) -match '1 job is running: j-0001') 'older checkpoint candidate cannot restore stale status after a lifecycle event'
    Check (($installed -join "`n" | ConvertFrom-Json).bytes -eq (Get-Item $state).Length) 'checkpoint receipt reports final rendered byte count'
    # Inject only the display failure into the real checkpoint writer; retain all write/lock logic.
    $checkpointScript = Get-Content -Raw (Join-Path $scripts 'write-resume-checkpoint.ps1')
    $checkpointScript = $checkpointScript.Replace(". (Join-Path `$PSScriptRoot 'dt-job.ps1')", ". '$($job.Replace("'", "''"))'`nfunction Update-DtJobStatusLine { throw 'fixture display unavailable' }")
    $guarded = & ([scriptblock]::Create($checkpointScript)) -RunFolder $run -BuildStatePath $state -ContentPath $candidate
    Check (($guarded -join "`n" | ConvertFrom-Json).checkpoint -eq $state -and (Get-Content -Raw $state) -match 'body: preserve me') 'D: checkpoint succeeds when display refresh throws after atomic write'
    $b = JobCall @('start','-RunFolder',$run2,'-WorkingTree',(Join-Path $tree '.'),'-Writes','-Command',"'second'")
    Check ($b.status -eq 'queued') 'blocking 2: cross-run writer waits while holder is live'
    $defaultA = JobCall @('start','-RunFolder',$run2,'-WorkingTree',$tree,'-Command','Start-Sleep 60')
    $defaultB = JobCall @('start','-RunFolder',$run2,'-WorkingTree',$tree,'-Command','Start-Sleep 60')
    Check ($defaultA.status -eq 'running' -and $defaultB.status -eq 'running') 'blocking 1: existing callers run in parallel without ReadOnly flags'
    foreach ($id in $defaultA.job_id,$defaultB.job_id) { JobCall @('cancel','-RunFolder',$run2,'-JobId',$id) | Out-Null }
    $writerRecord = Get-Content -Raw (Join-Path $run "jobs/$($a.job_id).json") | ConvertFrom-Json
    Check ($writerRecord.worktree_lock_path.StartsWith($env:DT_BUILD_STATE_DIR)) 'reservation uses durable shared state'
    $c = JobCall @('start','-RunFolder',$run2,'-WorkingTree',$tree,'-ReadOnly','-Command',"'read'")
    Check ((WaitDone $run2 $c.job_id).status -eq 'succeeded') 'declared read-only job can overlap writer'
    $d = JobCall @('start','-RunFolder',$run2,'-WorkingTree',$otherTree,'-Writes','-Command',"'other'")
    Check ((WaitDone $run2 $d.job_id).status -eq 'succeeded') 'different Git worktree can run independently'
    JobCall @('cancel','-RunFolder',$run,'-JobId',$a.job_id) | Out-Null
    Check ((WaitDone $run2 $b.job_id).status -eq 'succeeded') 'B: status alone reschedules cross-run waiting writer after holder ends'
    $e = JobCall @('start','-RunFolder',$run,'-WorkingTree',$tree,'-Writes','-Command',"'after'")
    Check ((WaitDone $run $e.job_id).status -eq 'succeeded') 'terminal writer releases reservation'
    Check (-not (Test-Path $writerRecord.worktree_lock_path)) 'A: completion deletes its reservation'
    $waitHolder = JobCall @('start','-RunFolder',$run,'-WorkingTree',$tree,'-Writes','-Command','Start-Sleep 4')
    $waiter = JobCall @('start','-RunFolder',$run2,'-WorkingTree',$tree,'-Writes','-Command',"'wait woke me'")
    $waitResult = JobCall @('wait','-RunFolder',$run2,'-JobId',$waiter.job_id,'-TimeoutSec','30')
    Check ($waitResult.result -eq 'finished' -and $waitResult.jobs[0].status -eq 'succeeded') 'B: wait alone reschedules cross-run queued writer'
    Check ((Get-Content -Raw $state) -match 'No jobs are running' -and (Get-Content -Raw $state) -match 'succeeded') 'finish refreshes checkpoint'
    $f = JobCall @('start','-RunFolder',$run,'-WorkingTree',$tree,'-Command','exit 3')
    WaitDone $run $f.job_id | Out-Null
    Check ((Get-Content -Raw $state) -match 'failed') 'failure refreshes checkpoint'

    # Launch from a subdirectory; only a sibling file changes, with no stdout.
    $sub = Join-Path $tree 'sub'; New-Item -ItemType Directory $sub | Out-Null
    $touch = (Join-Path $tree 'activity').Replace("'", "''")
    # Exercise sustained file progress in a two-second fixture window. Production's five-minute
    # window cannot be proved by a four-second freshness assertion on a twenty-second worker.
    $env:DT_JOB_STALL_SEC = '8'
    Push-Location $sub
    try { $h = JobCall @('start','-RunFolder',$run,'-Writes','-Command',"while (`$true) { [IO.File]::WriteAllText('$touch', [DateTime]::UtcNow.Ticks.ToString()); Start-Sleep 1 }") } finally { Pop-Location }
    $reader = JobCall @('start','-RunFolder',$run2,'-WorkingTree',$tree,'-ReadOnly','-Command','while ($true) { Start-Sleep 1 }')
    # Observe real heartbeat readiness and idle age. Process startup under load
    # can consume most of a fixed sleep before the read-only heartbeat exists.
    $heartbeatDeadline = [DateTime]::UtcNow.AddSeconds(60)
    $writerFirstActivity = $null; $writerAdvanced = $false
    do {
        $writerHeartbeat = Join-Path $run "jobs/$($h.job_id)/heartbeat.json"
        $readerHeartbeat = Join-Path $run2 "jobs/$($reader.job_id)/heartbeat.json"
        $ready = $false
        if ((Test-Path $writerHeartbeat) -and (Test-Path $readerHeartbeat)) {
            $observedWriter = Get-Content -Raw $writerHeartbeat | ConvertFrom-Json
            $observedReader = Get-Content -Raw $readerHeartbeat | ConvertFrom-Json
            if ($null -eq $writerFirstActivity) { $writerFirstActivity = [DateTime]$observedWriter.last_activity_utc }
            $writerAdvanced = [DateTime]$observedWriter.last_activity_utc -gt $writerFirstActivity
            $ready = $observedWriter.file_changes -gt 0 -and $writerAdvanced -and
                ([DateTime]::UtcNow - [DateTime]$observedReader.last_activity_utc).TotalSeconds -ge 3
        }
        if (-not $ready) { Start-Sleep -Milliseconds 100 }
    } while (-not $ready -and [DateTime]::UtcNow -lt $heartbeatDeadline)
    $beat = Get-Content -Raw (Join-Path $run "jobs/$($h.job_id)/heartbeat.json") | ConvertFrom-Json
    Check ($beat.file_changes -gt 0 -and $writerAdvanced) "sibling worktree writes refresh heartbeat from nested launch directory ($($beat | ConvertTo-Json -Compress); $(Get-Content -Raw (Join-Path $run ('jobs/' + $h.job_id + '.json'))))"
    $readerBeat = Get-Content -Raw (Join-Path $run2 "jobs/$($reader.job_id)/heartbeat.json") | ConvertFrom-Json
    Check ($readerBeat.file_changes -eq 0 -and ([DateTime]::UtcNow - [DateTime]$readerBeat.last_activity_utc).TotalSeconds -ge 3) 'unrelated worktree writes do not refresh read-only job activity'
    JobCall @('cancel','-RunFolder',$run2,'-JobId',$reader.job_id) | Out-Null
    JobCall @('cancel','-RunFolder',$run,'-JobId',$h.job_id) | Out-Null
    $env:DT_JOB_STALL_SEC = $originalStallSec

    # Missing/archived holder records release, malformed reservations still diagnose corruption.
    foreach ($holderRun in @((Join-Path $root 'deleted'), $run)) {
        [IO.File]::WriteAllText($writerRecord.worktree_lock_path, (@{run_folder=$holderRun;job_id='j-9999'} | ConvertTo-Json -Compress))
        $released = JobCall @('start','-RunFolder',$run2,'-WorkingTree',$tree,'-Writes','-Command',"'released'")
        Check ((WaitDone $run2 $released.job_id).status -eq 'succeeded') 'A: missing holder record or archived run releases reservation'
    }
    # Inject a real reservation Remove-Item failure, retaining state-save and event logic.
    & {
        param($fixtureRun, $fixtureJobScript, $fixtureId)
        . $fixtureJobScript
        $fixtureRecord = Get-DtJobRecord -RunFolder $fixtureRun -JobId $fixtureId
        [IO.File]::WriteAllText($fixtureRecord.worktree_lock_path, (@{run_folder=$fixtureRun;job_id=$fixtureId} | ConvertTo-Json -Compress))
        $injection = @{ called = $false }
        function Remove-Item {
            [CmdletBinding()] param([string]$LiteralPath, [switch]$Force)
            $injection.called = $true
            $saved = Get-DtJobRecord -RunFolder $fixtureRun -JobId $fixtureId
            Check ($saved.status -eq 'succeeded' -and $saved.status_reason -eq 'release failure fixture') 'N1: terminal record is saved before reservation removal'
            throw [IO.IOException]::new('fixture Remove-Item permission failure')
        }
        $verbose = Invoke-DtJobLocked -RunFolder $fixtureRun -Action {
            Set-DtJobState -RunFolder $fixtureRun -Record $fixtureRecord -Status 'succeeded' -EventType 'release_failure_fixture' -Reason 'release failure fixture' -Verbose
        } 4>&1
        Check ($injection.called -and ($verbose | Out-String) -match 'DT_JOB_WORKTREE_RELEASE_FAILED.*fixture Remove-Item permission failure') 'N1: reservation removal failure is caught and logged to verbose'
        $event = @(Get-DtJobEvents -RunFolder $fixtureRun | Where-Object type -eq 'release_failure_fixture')
        Check ($event.Count -eq 1 -and $event[0].job_id -eq $fixtureId -and $event[0].status -eq 'succeeded') 'N1: completion event is appended despite reservation removal failure'
        Check (Test-Path $fixtureRecord.worktree_lock_path) 'N1: injected failure leaves the terminal reservation for acquisition recovery'
    } $run $job $a.job_id
    $afterFailure = JobCall @('start','-RunFolder',$run2,'-WorkingTree',$tree,'-Writes','-Command',"'after failed release'")
    Check ((WaitDone $run2 $afterFailure.job_id).status -eq 'succeeded') 'N1: terminal reservation recovers after failed release'
    [IO.File]::WriteAllText($writerRecord.worktree_lock_path, '{broken')
    $stale = JobCall @('start','-RunFolder',$run2,'-WorkingTree',$tree,'-Writes','-Command',"'never'")
    Check ($stale.status -eq 'failed' -and $stale.status_reason -match 'DT_JOB_WORKTREE_STALE') 'malformed holder yields a structured failure'
    Remove-Item -LiteralPath $writerRecord.worktree_lock_path

    # Use the real short guard deadline, and prove polls and another tree still schedule.
    $guard = [IO.File]::Open("$($writerRecord.worktree_lock_path).guard", 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $busy = JobCall @('start','-RunFolder',$run2,'-WorkingTree',$tree,'-Writes','-Command',"'after guard'")
        Check ($busy.status -eq 'queued' -and $busy.status_reason -match 'DT_JOB_WORKTREE_LOCK_TIMEOUT') 'C: guard timeout returns structured queued job'
        & {
            param($fixtureRun, $fixtureJobScript, $fixtureId)
            . $fixtureJobScript
            $fixtureRecord = Get-DtJobRecord -RunFolder $fixtureRun -JobId $fixtureId
            Invoke-DtJobLocked -RunFolder $fixtureRun -Action {
                $timer = [Diagnostics.Stopwatch]::StartNew()
                $conflict = Enter-DtJobWorktree -RunFolder $fixtureRun -Record $fixtureRecord
                $timer.Stop()
                Check ($conflict -match 'DT_JOB_WORKTREE_LOCK_TIMEOUT' -and $timer.Elapsed.TotalSeconds -lt 1) "N3: real busy guard returns under one second while holding run lock ($($timer.Elapsed.TotalMilliseconds) ms)"
            }
        } $run2 $job $busy.job_id
        $pollTimer = [Diagnostics.Stopwatch]::StartNew()
        $pollStatus = JobCall @('status','-RunFolder',$run2,'-JobId',$busy.job_id)
        $pollTimer.Stop()
        Check ($pollStatus.status -eq 'queued' -and $pollTimer.Elapsed.TotalSeconds -lt 5) 'N3: status poll leaves busy writer queued without a 30-second guard wait'
        $pollTimer.Restart()
        $pollWait = JobCall @('wait','-RunFolder',$run2,'-JobId',$busy.job_id,'-TimeoutSec','1')
        $pollTimer.Stop()
        $queuedAfterWait = Get-Content -Raw (Join-Path $run2 "jobs/$($busy.job_id).json") | ConvertFrom-Json
        Check ($pollWait.result -eq 'wait_timeout' -and $pollWait.still_running -contains $busy.job_id -and $queuedAfterWait.status -eq 'queued' -and $pollTimer.Elapsed.TotalSeconds -lt 5) 'N3: wait polls leave busy writer queued without a 30-second guard wait'
        $independent = JobCall @('start','-RunFolder',$run2,'-WorkingTree',$otherTree,'-Writes','-Command',"'independent'")
        Check ($independent.status -eq 'running') 'C: scheduler continues past busy guard and launches another eligible job'
    } finally { $guard.Dispose() }
    # Both status processes reach scheduling while the parent owns the run lock.
    & {
        param($fixtureRun, $fixtureJobScript, $fixtureId, $fixtureRoot)
        . $fixtureJobScript
        $workers = [Collections.Generic.List[object]]::new()
        try {
            Invoke-DtJobLocked -RunFolder $fixtureRun -Action {
                foreach ($part in 1,2) {
                    $ready = Join-Path $fixtureRoot "status-$part.ready"
                    $command = "[IO.File]::WriteAllText('$($ready.Replace("'", "''"))', 'ready'); & '$($fixtureJobScript.Replace("'", "''"))' status -RunFolder '$($fixtureRun.Replace("'", "''"))' -AllowTempRunFolder -Json; exit `$LASTEXITCODE"
                    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
                    $process = Start-Process (Join-Path $PSHOME 'pwsh') -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) -RedirectStandardOutput (Join-Path $fixtureRoot "status-$part.log") -RedirectStandardError (Join-Path $fixtureRoot "status-$part.stderr.log") -PassThru
                    $workers.Add(@{ Process=$process; Ready=$ready })
                }
                $deadline = [DateTime]::UtcNow.AddSeconds(15)
                while (@($workers | Where-Object { -not (Test-Path $_.Ready) }).Count -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
                Check (@($workers | Where-Object { Test-Path $_.Ready }).Count -eq 2) 'N2: two concurrent status processes are ready behind the held run lock'
                Check ((Get-DtJobRecord -RunFolder $fixtureRun -JobId $fixtureId).status -eq 'queued') 'N2: concurrent status cannot launch while another process holds the run lock'
            }
            foreach ($worker in $workers) {
                $finished = $worker.Process.WaitForExit(15000)
                Check ($finished -and $worker.Process.ExitCode -eq 0) 'N2: concurrent status returns successfully after lock release'
            }
        } finally {
            foreach ($worker in $workers) {
                if (-not $worker.Process.HasExited) { $worker.Process.Kill($true); $worker.Process.WaitForExit() }
                $worker.Process.Dispose()
            }
        }
    } $run2 $job $busy.job_id $root
    Check ((WaitDone $run2 $busy.job_id).status -eq 'succeeded') 'C: guard contention recovers without resubmission'
    $launches = @(Get-Content (Join-Path $run2 'jobs/events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.job_id -eq $busy.job_id -and $_.type -eq 'launched' })
    $busyRecord = Get-Content -Raw (Join-Path $run2 "jobs/$($busy.job_id).json") | ConvertFrom-Json
    Check ($launches.Count -eq 1 -and (Get-Content -Raw $busyRecord.output_path).Trim() -eq 'after guard') 'N2: two concurrent status calls launch the one queued job exactly once'
    WaitDone $run2 $independent.job_id | Out-Null

    # A queued reservation left by a dead coordinator has no process; recover under both locks.
    $holderPath = Join-Path $run "jobs/$($e.job_id).json"
    $dead = Get-Content -Raw $holderPath | ConvertFrom-Json
    $dead.status = 'queued'
    [IO.File]::WriteAllText($holderPath, ($dead | ConvertTo-Json -Depth 8))
    JobCall @('lease','-Action','acquire','-RunFolder',$run,'-CoordinatorId','dead-fixture') | Out-Null
    $leasePath = Join-Path $run 'coordinator.lease'
    $lease = Get-Content -Raw $leasePath | ConvertFrom-Json
    $lease.expires_utc = [DateTime]::UtcNow.AddMinutes(-5).ToString('o')
    [IO.File]::WriteAllText($leasePath, ($lease | ConvertTo-Json))
    [IO.File]::WriteAllText($writerRecord.worktree_lock_path, (@{run_folder=$run;job_id=$dead.job_id} | ConvertTo-Json -Compress))
    $recovered = JobCall @('start','-RunFolder',$run2,'-WorkingTree',$tree,'-Writes','-Command',"'recovered'")
    Check ((WaitDone $run2 $recovered.job_id).status -eq 'succeeded') 'B: dead coordinator queued holder cannot block forever'
    Check ((Get-Content -Raw (Join-Path $run2 'jobs/events.jsonl')) -match 'coordinator lease is dead or expired') 'B: abandoned queued reservation recovery is reported plainly'
    $dead.status = 'running'; $dead.runner_pid = 99999999; $dead.pid = $null
    [IO.File]::WriteAllText($holderPath, ($dead | ConvertTo-Json -Depth 8))
    [IO.File]::WriteAllText($writerRecord.worktree_lock_path, (@{run_folder=$run;job_id=$dead.job_id} | ConvertTo-Json -Compress))
    $deadWaiter = JobCall @('start','-RunFolder',$run2,'-WorkingTree',$tree,'-Writes','-Command',"'after reconcile'")
    Check ($deadWaiter.status -eq 'queued' -and $deadWaiter.status_reason -match 'reconcile its run') 'E: dead running holder leaves waiter queued with recovery reason'
    JobCall @('reconcile','-RunFolder',$run) | Out-Null
    Check ((WaitDone $run2 $deadWaiter.job_id).status -eq 'succeeded') 'E: reconcile releases dead running holder'

    & {
        param($fixtureRun, $fixtureJobScript)
        . $fixtureJobScript
        function Update-DtJobStatusLine { throw 'fixture checkpoint is busy' }
        Invoke-DtJobLocked -RunFolder $fixtureRun -Action {
            Add-DtJobEvent -RunFolder $fixtureRun -JobId 'run' -Type 'refresh_fixture' -Status 'runnable'
        }
    } $run $job 3>$null
    Check ((Get-Content -Raw (Join-Path $run 'jobs/events.jsonl')) -match 'refresh_fixture') 'checkpoint refresh failure cannot fail event append'

    & {
        param($fixtureRun, $fixtureJobScript, $fixtureScripts, $fixtureState)
        . $fixtureJobScript
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $fixtureScripts 'dt-build-watcher.ps1'), [ref]$tokens, [ref]$errors)
        $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-WatcherTriggerSeq' }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
        $trigger = Get-WatcherTriggerSeq -RunFolder $fixtureRun
        $recordCount = @(Get-DtJobRecords -RunFolder $fixtureRun).Count
        Invoke-DtJobLocked -RunFolder $fixtureRun -Action {
            foreach ($status in 'runnable','accepted','failed') {
                Add-DtJobEvent -RunFolder $fixtureRun -JobId 'run' -Type 'branch_rebase_fixture' -Status $status
            }
        }
        Check ((Get-WatcherTriggerSeq -RunFolder $fixtureRun) -eq $trigger) 'run rebase statuses do not trigger watcher job completion'
        $snapshot = Get-DtJobSnapshot -RunFolder $fixtureRun
        Check (@($snapshot.records).Count -eq $recordCount -and @($snapshot.records | Where-Object job_id -eq 'run').Count -eq 0) 'status snapshot reads job records and never invents a run job'
        Check ((Get-DtJobRunState -BuildStatePath $fixtureState).run_status -eq 'runnable') 'run event failed status does not change authoritative run status'
        Check ((Get-Content -Raw $fixtureState) -match 'No jobs are running; 0 jobs are waiting.*Latest run event: branch_rebase_fixture \(failed\)') 'status line counts real jobs and labels run event type explicitly'
    } $run $job $scripts $state
    $syntheticWait = JobCall @('wait','-RunFolder',$run,'-JobId',$f.job_id,'-TimeoutSec','1')
    Check ($syntheticWait.jobs.Count -eq 1 -and $syntheticWait.jobs[0].job_id -eq $f.job_id -and $syntheticWait.jobs[0].status -eq 'failed') 'wait returns only requested job records despite synthetic run events in the same run'
    $syntheticReconcile = JobCall @('reconcile','-RunFolder',$run)
    Check (@($syntheticReconcile.orphaned | Where-Object { $_ -eq 'run' }).Count -eq 0) 'reconcile never treats synthetic run event as orphaned job'

    if ($IsLinux) {
        # Load just the sampler, then keep a silent descendant busy while its wrapper sleeps.
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'dt-job-runner.ps1'), [ref]$tokens, [ref]$errors)
        $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DtJobTreeCpuSeconds' }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
        $psi = [Diagnostics.ProcessStartInfo]::new('/bin/sh'); $psi.ArgumentList.Add('-c'); $psi.ArgumentList.Add('yes > /dev/null & child=$!; trap "kill $child" EXIT; sleep 20')
        $p = [Diagnostics.Process]::Start($psi)
        try {
            $before = Get-DtJobTreeCpuSeconds $p.Id
            Start-Sleep -Seconds 3
            $after = Get-DtJobTreeCpuSeconds $p.Id
            Check ($after - $before -gt 0.5) 'Linux sampler counts silent busy descendants while wrapper sleeps'
        } finally { $p.Kill($true); $p.WaitForExit(); $p.Dispose() }
    }

    # Explicit old-tip rebase attestation, ledger and stale-CAS protection.
    & git -C $tree checkout -qb old-build
    [IO.File]::WriteAllText((Join-Path $tree 'patch'), 'patch')
    & git -C $tree add patch; & git -C $tree commit -qm patch
    $old = (& git -C $tree rev-parse HEAD).Trim()
    & git -C $tree branch build/fixture $old
    & git -C $tree checkout -q main
    [IO.File]::WriteAllText((Join-Path $tree 'upstream'), 'upstream')
    & git -C $tree add upstream; & git -C $tree commit -qm upstream
    & git -C $tree checkout -qb rebased old-build
    & git -C $tree rebase main 2>$null | Out-Null
    $new = (& git -C $tree rev-parse HEAD).Trim()
    $cas = Join-Path $scripts 'branch-cas-update.ps1'
    # Loading dt-job and its transitive dependencies must preserve the CAS Git wrapper.
    & {
        param($fixtureJobScript)
        function Invoke-Git { 'CAS fixture sentinel' }
        $before = (Get-Command Invoke-Git).ScriptBlock.ToString()
        . $fixtureJobScript
        Check ((Get-Command Invoke-Git).ScriptBlock.ToString() -ceq $before) 'dot-sourcing dt-job preserves Invoke-Git definition'
        Check ((Invoke-Git) -eq 'CAS fixture sentinel') 'dot-sourcing preserves callable Git wrapper behavior'
    } $job
    & git -C $tree checkout -qb unrelated main
    [IO.File]::WriteAllText((Join-Path $tree 'unrelated'), 'different patch')
    & git -C $tree add unrelated; & git -C $tree commit -qm unrelated
    $unrelated = (& git -C $tree rev-parse HEAD).Trim()
    $refused = & pwsh -NoProfile -File $cas -RepoPath $tree -SourceRef $unrelated -ExpectedTargetSha $old -TargetBranch build/fixture -AllowRebase -RebasedFromSha $old -RunFolder $run -Json
    Check ($LASTEXITCODE -ne 0 -and ($refused -join "`n" | ConvertFrom-Json).reason -match 'patch set does not match' -and (& git -C $tree rev-parse build/fixture).Trim() -eq $old) 'F: unrelated replacement patch set is refused without moving ref'
    & pwsh -NoProfile -File $cas -RepoPath $tree -SourceRef $new -ExpectedTargetSha $old -TargetBranch build/fixture -Json >$null
    Check ($LASTEXITCODE -ne 0) 'ordinary CAS refuses non-fast-forward'
    & pwsh -NoProfile -File $cas -RepoPath $tree -SourceRef $new -ExpectedTargetSha $old -TargetBranch build/fixture -AllowRebase -RebasedFromSha $base -RunFolder $run -Json >$null
    Check ($LASTEXITCODE -ne 0) 'mismatched rebased old tip is refused'
    & pwsh -NoProfile -File $cas -RepoPath $tree -SourceRef $new -ExpectedTargetSha $old -TargetBranch build/fixture -AllowRebase -RebasedFromSha $old -Json >$null
    Check ($LASTEXITCODE -ne 0) 'rebase without ledger is refused'
    $refLock = Join-Path $tree '.git/refs/heads/build/fixture.lock'
    [IO.File]::WriteAllText($refLock, 'fixture lock contention')
    try {
        $failure = & pwsh -NoProfile -File $cas -RepoPath $tree -SourceRef $new -ExpectedTargetSha $old -TargetBranch build/fixture -AllowRebase -RebasedFromSha $old -RunFolder $run -Json
        Check ($LASTEXITCODE -ne 0 -and ($failure -join "`n" | ConvertFrom-Json).reason -match 'CAS_FAIL') 'failed ref update still returns JSON reason'
        Check ((Get-Content -Raw (Join-Path $run 'jobs/events.jsonl')) -match 'branch_rebase_failed') 'failed ref update records failure evidence'
    } finally { Remove-Item -LiteralPath $refLock }
    $result = & pwsh -NoProfile -File $cas -RepoPath $tree -SourceRef $new -ExpectedTargetSha $old -TargetBranch build/fixture -AllowRebase -RebasedFromSha $old.Substring(0,12).ToUpperInvariant() -RunFolder $run -Json
    Check ($LASTEXITCODE -eq 0 -and ($result -join "`n" | ConvertFrom-Json).mode -eq 'compare-and-swap-rebase') 'planned rebase moves branch through CAS'
    $events = Get-Content -Raw (Join-Path $run 'jobs/events.jsonl')
    Check ($events -match 'branch_rebased' -and $events -match $old -and $events -match $new) 'rebase ledger records both tips and acceptance'
    Check ((Get-Content -Raw $state) -match 'accepted') 'acceptance refreshes checkpoint'
    & pwsh -NoProfile -File $cas -RepoPath $tree -SourceRef $old -ExpectedTargetSha $old -TargetBranch build/fixture -AllowRebase -RebasedFromSha $old -RunFolder $run -Json >$null
    Check ($LASTEXITCODE -ne 0 -and (& git -C $tree rev-parse build/fixture).Trim() -eq $new) 'rebase option preserves stale-tip rejection'
} finally {
    $env:DT_JOB_STALL_SEC = $originalStallSec
    foreach ($rf in $run,$run2) {
        foreach ($record in @(Get-ChildItem (Join-Path $rf 'jobs') -Filter 'j-*.json' -ErrorAction SilentlyContinue)) {
            $r = Get-Content -Raw $record | ConvertFrom-Json
            if ($r.status -in 'running','queued') { JobCall @('cancel','-RunFolder',$rf,'-JobId',$r.job_id) | Out-Null }
        }
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-Output "SUMMARY: $passed passed, $failed failed (runtime fixes)"
if ($failed) { exit 1 }
