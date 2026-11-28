#Requires -Version 7.0
# Real processes and the production ledger/lease/operator/watcher code; no model or external service.
param([string]$EvidencePath)
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../../../scripts/lib/runtime-test-admission.ps1')
Enter-RuntimeTestSuite
$ErrorActionPreference = 'Stop'
$dtJob = Join-Path (Split-Path -Parent $PSScriptRoot) 'dt-job.ps1'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'dt-build-watcher.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('approval-wait-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$saved = @{}
foreach ($name in @('DT_BUILD_STATE_DIR','DT_BUILD_HEADLESS','DT_BUILD_COORDINATOR_ID','DT_JOB_ID','DT_MODEL_ROUTER_STATE','DT_MODEL_ROUTER_ALERT_TRANSPORT')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
$env:DT_BUILD_STATE_DIR = Join-Path $root 'registry'
$env:DT_MODEL_ROUTER_STATE = Join-Path $root 'router'
$env:DT_BUILD_HEADLESS = '1'
Remove-Item Env:DT_BUILD_COORDINATOR_ID,Env:DT_JOB_ID -ErrorAction SilentlyContinue
$transport = Join-Path $root 'transport.ps1'
[IO.File]::WriteAllText($transport, 'param($request); if ($request.kind -eq "secret") { return "fake" }; return @{id="fake";owner=@{id="1"}}')
$env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $transport
$passed = 0; $failed = 0; $processes = @(); $measurements = @()
function Check([bool]$Condition, [string]$Label) {
    if ($Condition) { $script:passed++; Write-Output "PASS: $Label" }
    else { $script:failed++; Write-Output "FAIL: $Label" }
}
function Call-Job([string[]]$Arguments) {
    $raw = & pwsh -NoProfile -File $dtJob @Arguments -AllowTempRunFolder -Json 2>&1
    if ($LASTEXITCODE) { throw ($raw -join "`n") }
    ($raw -join "`n") | ConvertFrom-Json
}
function Wait-Until([scriptblock]$Condition, [int]$Seconds = 180) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Condition)) {
        if ($timer.Elapsed.TotalSeconds -gt $Seconds) { throw 'Fixture condition timed out' }
        Start-Sleep -Milliseconds 100
    }
}
$child = Join-Path $root 'coordinator.ps1'
$helper = Join-Path $root 'waiter.ps1'
[IO.File]::WriteAllText($helper, @'
param($DtJob, $Folder, $Minutes, $CallStartedUtc, $CoordinatorId)
$ErrorActionPreference = 'Stop'
$raw = & $DtJob await-danny -RunFolder $Folder -BuildStatePath (Join-Path $Folder '_build-state.md') -CoordinatorId $CoordinatorId -Operation review -Message 'Review fixture work.' -WaitMinutes $Minutes -CallStartedUtc $CallStartedUtc -AllowTempRunFolder -Json
$resultPath = Join-Path $Folder 'result.json'
[IO.File]::WriteAllText(($resultPath + '.tmp'), ($raw -join "`n"))
[IO.File]::Move(($resultPath + '.tmp'), $resultPath)
'@)
[IO.File]::WriteAllText($child, @'
param($DtJob, $Folder, $Minutes, $CoordinatorId)
$ErrorActionPreference = 'Stop'
$env:DT_BUILD_COORDINATOR_ID = $CoordinatorId
$state = Join-Path $Folder '_build-state.md'
& $DtJob lease -RunFolder $Folder -CoordinatorId $CoordinatorId -Action acquire -Host codex -Pid $PID -LaunchedBy watcher -TtlSec 3 -AllowTempRunFolder -Json | Out-Null
$callStarted = [DateTime]::UtcNow.ToString('o')
# The caller's 2.4-second budget is already exhausted, with ample margin.
# Do not depend on child startup taking a particular amount of real time.
if ((Split-Path $Folder -Leaf) -eq 'setup-delay') { $callStarted = [DateTime]::UtcNow.AddMinutes(-1).ToString('o') }
& pwsh -NoProfile -File (Join-Path (Split-Path $Folder -Parent) 'waiter.ps1') $DtJob $Folder $Minutes $callStarted $CoordinatorId
$result = [IO.File]::ReadAllText((Join-Path $Folder 'result.json')) | ConvertFrom-Json
if ($result.decision -eq 'approved') {
    $continued = Join-Path $Folder 'continued'
    [IO.File]::WriteAllText(($continued + '.tmp'), [string]$PID)
    [IO.File]::Move(($continued + '.tmp'), $continued)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path (Join-Path $Folder 'release'))) {
        if ($timer.Elapsed.TotalSeconds -gt 180) { throw 'Fixture release condition timed out' }
        Start-Sleep -Milliseconds 100
    }
}
& $DtJob lease -RunFolder $Folder -CoordinatorId $CoordinatorId -Action release -AllowTempRunFolder -Json | Out-Null
'@)
try {
    foreach ($case in @('approved','timeout','setup-delay','coordinator-gone','declined','held','no-director','director-gone','superseded')) {
        $p = $null
        try {
            $folder = Join-Path $root $case
            # Linux watcher liveness checks scan process tags across all runs.
            # Parallel fixture copies must never share a coordinator identity.
            $coordinatorId = 'wait-fixture-' + [guid]::NewGuid().ToString('N')
            New-Item -ItemType Directory -Path $folder | Out-Null
            $state = Join-Path $folder '_build-state.md'
            [IO.File]::WriteAllText($state, "run_status: runnable`nlast_consumed_event_seq: 0`nupdated_utc: fixture`n")
            $director = if ($case -eq 'no-director') { $null } else {
                @{ name='fixture-director'; pid=$PID; pid_start_utc=(Get-DtJobProcessStartUtc $PID); session_id='fixture-director' }
            }
            $approvalsPath = Join-Path $folder 'approvals.json'
            [IO.File]::WriteAllText($approvalsPath, (@{awaiting=$null;approvals=@();delegate=$director} | ConvertTo-Json -Depth 5))
            $minutes = if ($case -in @('timeout','setup-delay')) { '0.04' } else { '5' }
            $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
            $psi.UseShellExecute = $false
            foreach ($arg in @('-NoProfile','-File',$child,$dtJob,$folder,$minutes,$coordinatorId)) { $psi.ArgumentList.Add($arg) }
            $psi.RedirectStandardError = $true
            $psi.RedirectStandardOutput = $true
            $p = [Diagnostics.Process]::Start($psi); $processes += $p
            $timer = [Diagnostics.Stopwatch]::StartNew()
            # Deliberately observe setup-delay only after it exits: its expired waiter
            # is transient, while the boundary, deadline and result are durable.
            if ($case -eq 'setup-delay') { Wait-Until { $p.HasExited } }
            Wait-Until { (Test-Path $approvalsPath) -and ((Get-DtJobApprovals $folder).awaiting) }
            $entry = [pscustomobject]@{ run_id=$case; run_folder=$folder; build_state_path=$state; managed=$true }
            if ($case -ne 'no-director') {
                # A short or already-expired budget can clear the waiter before any
                # parent poll. Only cases that interact with a live waiter need it.
                if ($case -notin @('timeout','setup-delay')) {
                    Wait-Until { $a = (Get-DtJobApprovals $folder).awaiting; $a -and $a.PSObject.Properties['waiter'] }
                }
                Check ((Get-WatcherDecision -Entry $entry -NowUtc ([DateTime]::UtcNow)).action -eq 'none') "$case watcher does not relaunch while awaiting"
                $firstLease = Get-DtJobLease $folder
                if ($case -eq 'approved') {
                    $pending = (Get-DtJobApprovals $folder).awaiting
                    Check (Test-DtJobApprovalWaiter $pending $firstLease) 'live matching waiter is eligible for immediate approval'
                    foreach ($fence in @('deadline','waiter-start','lease-start','lease-pid','coordinator','released')) {
                        $copy = $pending | ConvertTo-Json -Depth 8 | ConvertFrom-DtJobJsonText
                        $leaseCopy = $firstLease | ConvertTo-Json -Depth 8 | ConvertFrom-DtJobJsonText
                        switch ($fence) {
                            'deadline' { $copy.waiter.until_utc = '2000-01-01T00:00:00Z' }
                            'waiter-start' { $copy.waiter.pid_start_utc = '2000-01-01T00:00:00Z' }
                            'lease-start' { $copy.waiter.lease_start_utc = '2000-01-01T00:00:00Z' }
                            'lease-pid' { $copy.waiter.lease_pid = $PID }
                            'coordinator' { $copy.waiter.coordinator_id = 'different' }
                            'released' { $leaseCopy.released_utc = [DateTime]::UtcNow.ToString('o') }
                        }
                        Check (-not (Test-DtJobApprovalWaiter $copy $leaseCopy)) "$fence fences stale/mismatched waiter"
                    }
                    # Observe renewal across the original lease expiry, rather than sleeping twenty
                    # seconds. Approval still happens only after the real waiter is blocked and has
                    # kept its coordinator alive beyond that original three-second lease.
                    Wait-Until {
                        $now = [DateTime]::UtcNow
                        $fresh = Get-DtJobLease $folder
                        $now -gt (ConvertTo-DtJobUtc $firstLease.expires_utc) -and
                            (ConvertTo-DtJobUtc $fresh.expires_utc) -gt $now
                    }
                    $freshLease = Get-DtJobLease $folder
                    Check ((ConvertTo-DtJobUtc $freshLease.expires_utc) -gt [DateTime]::UtcNow -and (ConvertTo-DtJobUtc $freshLease.expires_utc) -gt (ConvertTo-DtJobUtc $firstLease.expires_utc)) 'three-second lease renewed beyond its original expiry while waiter blocks'
                    $cpu = $p.TotalProcessorTime.TotalSeconds
                    $approval = Call-Job @('approve','-RunFolder',$folder,'-BuildStatePath',$state,'-Operation','review','-Reason','Fixture approved.')
                    Check ($approval.approved -eq 'review' -and -not $approval.PSObject.Properties['approval_queued']) 'operator applies approval before coordinator exits'
                    Check ($approval.decision -eq 'approved' -and $approval.reason -ceq 'Fixture approved.' -and $approval.actor -ceq [Environment]::UserName) 'immediate approval echoes persisted decision, reason and actor'
                    $repeat = Call-Job @('approve','-RunFolder',$folder,'-BuildStatePath',$state,'-Operation','review')
                    Check ($repeat.approved -eq 'review' -and (Get-DtJobApprovals $folder).approvals.Count -eq 1) 'repeated immediate approval is idempotent'
                } elseif ($case -eq 'declined') {
                    Call-Job @('approve','-RunFolder',$folder,'-BuildStatePath',$state,'-Operation','review','-Decline','-Reason','Do not proceed.') | Out-Null
                } elseif ($case -eq 'held') {
                    Call-Job @('hold','-RunFolder',$folder,'-BuildStatePath',$state,'-Operation','review','-Reason','Decision escalated to Danny.') | Out-Null
                } elseif ($case -eq 'director-gone') {
                    Invoke-DtJobLocked $folder { $a = Get-DtJobApprovals $folder; $a.delegate.pid_start_utc = '2000-01-01T00:00:00Z'; Save-DtJobApprovals $folder $a }
                } elseif ($case -eq 'superseded') {
                    Invoke-DtJobLocked $folder { $a = Get-DtJobApprovals $folder; $a.awaiting.seq++; Save-DtJobApprovals $folder $a }
                } elseif ($case -eq 'coordinator-gone') {
                    $helperPid = (Get-DtJobApprovals $folder).awaiting.waiter.pid
                    Check ($helperPid -ne $p.Id) 'waiter helper and coordinator are separate processes'
                    $p.Kill(); $p.WaitForExit()
                    Check (-not (Test-DtJobApprovalWaiter (Get-DtJobApprovals $folder).awaiting (Get-DtJobLease $folder))) 'dead coordinator immediately invalidates surviving waiter'
                    Check ($null -ne (Get-Process -Id $helperPid -ErrorAction SilentlyContinue)) 'helper survives killing only coordinator'
                }
            }
            $resultPath = Join-Path $folder 'result.json'
            Wait-Until { (Test-Path $resultPath) -or ($case -ne 'coordinator-gone' -and $p.HasExited) }
            if (-not (Test-Path $resultPath)) { throw "Child exited $($p.ExitCode): $($p.StandardError.ReadToEnd())" }
            $r = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
            $expected = if ($case -in @('timeout','setup-delay','coordinator-gone','no-director','director-gone')) { 'unanswered' } else { $case }
            Check ($r.decision -eq $expected) "$case returns $expected"
            # AI-139: the waiter reads the persisted operator reason (the chosen option) with the decision.
            if ($case -eq 'approved') { Check ($r.reason -ceq 'Fixture approved.') 'approved waiter receives the persisted approval reason' }
            if ($case -eq 'declined') { Check ($r.reason -ceq 'Do not proceed.') 'declined waiter receives the persisted decline reason' }
            if ($case -eq 'approved') {
                Wait-Until { Test-Path (Join-Path $folder 'continued') }
                Check (-not $p.HasExited -and [int]([IO.File]::ReadAllText((Join-Path $folder 'continued'))) -eq $p.Id) 'same coordinator PID continues after approval'
                Check ((Get-WatcherDecision -Entry $entry -NowUtc ([DateTime]::UtcNow)).action -eq 'none') 'watcher does not launch beside approved live coordinator'
                $events = @(Get-DtJobEvents $folder)
                Check (@($events | Where-Object type -in @('continuation_requested','coordinator_launched')).Count -eq 0) 'approval emits no relaunch/continuation event'
                Check ((Get-DtJobApprovals $folder).approvals[0].reason -eq 'Fixture approved.') 'approval reason survives immediate wake'
                [IO.File]::WriteAllText((Join-Path $folder 'release'), '')
            }
            Wait-Until { $p.HasExited }
            $p.WaitForExit()
            if ($case -ne 'coordinator-gone') { Check ($p.ExitCode -eq 0) "$case coordinator exits cleanly" }
            if ($case -ne 'approved') {
                $a = Get-DtJobApprovals $folder
                Check ($a.awaiting -and -not $a.awaiting.PSObject.Properties['waiter'] -and $a.approvals.Count -eq 0) "$case preserves boundary and clears waiter"
                Check ((Get-DtJobRunState $state).run_status -eq 'awaiting_danny') "$case stays stopped"
            }
            if ($case -eq 'timeout') {
                $deadline = (Get-DtJobApprovals $folder).awaiting.wait_until_utc
                # A live interactive lease and live director make this a genuine repeated wait attempt.
                Call-Job @('lease','-RunFolder',$folder,'-CoordinatorId',$coordinatorId,'-Action','acquire','-Host','codex') | Out-Null
                $again = Call-Job @('await-danny','-RunFolder',$folder,'-BuildStatePath',$state,'-Operation','review','-Message','Repeated boundary.','-CoordinatorId',$coordinatorId)
                Check ($again.decision -eq 'unanswered' -and
                    (Test-DtJobSameInstant $deadline (Get-DtJobApprovals $folder).awaiting.wait_until_utc)) 'live repeat cannot reset expired boundary deadline'
                Call-Job @('lease','-RunFolder',$folder,'-CoordinatorId',$coordinatorId,'-Action','release') | Out-Null
                Call-Job @('approve','-RunFolder',$folder,'-BuildStatePath',$state,'-Operation','review') | Out-Null
                Check (@(Get-DtJobEvents $folder | Where-Object type -eq 'continuation_requested').Count -eq 1) 'late approval retains continuation event for relaunch'
                Check ((Get-WatcherDecision -Entry $entry -NowUtc ([DateTime]::UtcNow)).action -eq 'launch') 'timeout plus late approval is eligible for normal watcher relaunch'
            }
            if ($case -eq 'coordinator-gone') {
                $expires = (Get-DtJobLease $folder).expires_utc
                Start-Sleep -Seconds 2
                Check ((Get-DtJobLease $folder).expires_utc -eq $expires) 'dead coordinator lease is no longer renewed'
                Call-Job @('approve','-RunFolder',$folder,'-BuildStatePath',$state,'-Operation','review') | Out-Null
                Check (@(Get-DtJobEvents $folder | Where-Object type -eq 'continuation_requested').Count -eq 1) 'approval after coordinator death requests continuation'
                Check ((Get-WatcherDecision -Entry $entry -NowUtc ([DateTime]::UtcNow)).action -eq 'launch') 'watcher relaunches after coordinator death and approval'
            }
            if ($case -eq 'declined') {
                Call-Job @('approve','-RunFolder',$folder,'-BuildStatePath',$state,'-Operation','review') | Out-Null
                $a = Get-DtJobApprovals $folder
                Check (-not $a.awaiting -and $a.approvals[0].overruled_decline.reason -eq 'Do not proceed.') 'later approval preserves overruled decline in receipt'
            }
            if ($case -eq 'setup-delay') {
                $a = Get-DtJobApprovals $folder
                Check ((ConvertTo-DtJobUtc $a.awaiting.wait_until_utc) -lt (ConvertTo-DtJobUtc $a.awaiting.since_utc)) 'startup delay consumes caller budget before boundary setup'
            }
            $measurement = @{case=$case; seconds=[Math]::Round($timer.Elapsed.TotalSeconds,3); decision=$r.decision}
            if ($case -eq 'approved') {
                $measurement.coordinator_pid = $p.Id; $measurement.cpu_seconds = $cpu; $measurement.events = @($events.type)
            }
            $measurements += $measurement
        } catch { Check $false "$case exception: $($_.Exception.Message) $($_.ScriptStackTrace)" }
        finally { if ($p -and -not $p.HasExited) { $p.Kill($true); $p.WaitForExit() } }
    }
    & {
        # Exercise a genuinely held OS run lock, with the caller's remaining hard budget exhausted.
        $lockFolder = Join-Path $root 'lock-budget'
        $paths = Get-DtJobPaths $lockFolder
        New-Item -ItemType Directory -Force -Path $paths.Locks | Out-Null
        $handle = [IO.File]::Open($paths.RunLock, 'OpenOrCreate', 'ReadWrite', 'None')
        $Verb = 'await-danny'
        # Exhaust the hard budget before acquiring the held lock. A one-second
        # remaining budget plus a two-second wall-time assertion races scheduling.
        $CallStartedUtc = [DateTime]::UtcNow.AddMinutes(-8)
        try {
            Invoke-DtJobLocked $lockFolder { throw 'Lock unexpectedly acquired' }
            Check $false 'held lock respects total caller deadline'
        } catch {
            Check ($_.Exception.Message -like 'DT_JOB_LOCK_TIMEOUT:*') 'held lock respects total caller deadline'
        } finally { $handle.Dispose() }
    }
    foreach ($hostName in @('claude','codex')) {
        $rulebook = (& pwsh -NoProfile -File (Join-Path (Split-Path -Parent $PSScriptRoot) 'read-coordinator-rulebook.ps1') -CoordinatorHost $hostName) -join "`n"
        Check ($rulebook -match 'WaitMinutes 7.5' -and $rulebook -match 'CallStartedUtc' -and $rulebook -match '600000' -and $rulebook -notmatch 'At approval boundaries:.*then end\.') "$hostName rendered rulebook teaches wait and same-session continuation"
    }
    $measurements | ConvertTo-Json -Depth 6 | Write-Output
    if ($EvidencePath) { $measurements | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $EvidencePath }
} finally {
    foreach ($p in $processes) { if (-not $p.HasExited) { $p.Kill($true); $p.WaitForExit() }; $p.Dispose() }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) }
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-Output "Approval wait: $passed passed, $failed failed"
if ($failed) { exit 1 }
