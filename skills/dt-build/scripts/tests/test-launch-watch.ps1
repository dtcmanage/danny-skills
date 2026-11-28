param()

# await-coordinator-start.ps1 (did the launched coordinator start, exit, or get stopped?) and
# watch-run-state.ps1 (background watch that exits only on a change that needs the launching session).
# Fixture run folders only; no watcher, no model calls.

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../../../scripts/lib/runtime-test-admission.ps1')
Enter-RuntimeTestSuite
$ErrorActionPreference = 'Stop'
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT_FAIL: $Message" }
    $script:passed++
}

function Write-Utf8 {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

$scriptDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$repoRoot = (Resolve-Path (Join-Path $scriptDir '../../..')).Path
$dtJob = Join-Path $scriptDir 'dt-job.ps1'
$await = Join-Path $scriptDir 'await-coordinator-start.ps1'
$watch = Join-Path $scriptDir 'watch-run-state.ps1'
$templatePath = Join-Path $repoRoot 'skills/dt-pipeline/templates/build-state-template.md'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-launch-watch-tests-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$savedState = $env:DT_BUILD_STATE_DIR
$savedCoordinator = $env:DT_BUILD_COORDINATOR_ID
$env:DT_BUILD_STATE_DIR = Join-Path $tempRoot 'state'
Remove-Item Env:DT_BUILD_COORDINATOR_ID -ErrorAction SilentlyContinue

function New-FixtureRun {
    param([string]$Name)
    $folder = Join-Path $tempRoot "runs/$Name"
    New-Item -ItemType Directory -Path (Join-Path $folder 'jobs') -Force | Out-Null
    $state = Join-Path $tempRoot "planning/$Name/_build-state.md"
    $text = (Get-Content -Raw -LiteralPath $templatePath).Replace('__RUN_STATUS__', 'runnable').Replace('__LAST_CONSUMED_EVENT_SEQ__', '0').Replace('__UPDATED_UTC__', '2026-11-23T00:00:00Z')
    Write-Utf8 -Path $state -Content $text
    & pwsh -NoProfile -File $dtJob register-run -RunFolder $folder -BuildStatePath $state -RunId $Name -PinnedHost claude -Managed -Json 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "register-run failed for $Name" }
    & pwsh -NoProfile -File $dtJob request-continuation -RunFolder $folder -CoordinatorId 'launcher-session' -Reason managed_start -Json 2>$null | Out-Null
    return [pscustomobject]@{ folder = $folder; state = $state }
}

function Add-Launch {
    param([string]$Folder, [string]$Id, [int]$LauncherExit = 0, [DateTime]$At = [DateTime]::UtcNow)
    $row = [ordered]@{ type = 'launch'; trigger_seq = 1; host = 'claude'; attempt = 1; launched_utc = $At.ToString('o'); pid = $null; coordinator_id = $Id; launcher_exit = $LauncherExit; checkpoint_sha256 = 'x' }
    [IO.File]::AppendAllText((Join-Path $Folder 'launches.jsonl'), (($row | ConvertTo-Json -Compress) + "`n"))
}

function Set-Mark {
    param([string]$Folder, [string]$Id)
    $baseline = [ordered]@{ coordinators = [ordered]@{ $Id = [ordered]@{ coordinator_id = $Id; host = 'claude'; transcript_path = '/fixture'; baseline_tokens = 41000; marked_utc = [DateTime]::UtcNow.ToString('o') } } }
    Write-Utf8 -Path (Join-Path $Folder 'context-baseline.json') -Content ($baseline | ConvertTo-Json -Depth 6)
}

function Invoke-Script {
    param([string]$Path, [string[]]$Arguments)
    $raw = & pwsh -NoProfile -File $Path @Arguments -Json 2>&1
    $code = $LASTEXITCODE
    $line = @($raw | ForEach-Object { [string]$_ } | Where-Object { $_.StartsWith('{') } | Select-Object -Last 1)
    $parsed = if ($line.Count) { $line[0] | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{ exit = $code; out = $parsed; text = (($raw | ForEach-Object { [string]$_ }) -join "`n") }
}

$exitCode = 0
try {
    # ---- await: a coordinator that marks bootstrap is 'started' (exit 0).
    $r = New-FixtureRun -Name 'await-started'
    Add-Launch -Folder $r.folder -Id 'mc-ok'
    Set-Mark -Folder $r.folder -Id 'mc-ok'
    $res = Invoke-Script $await @('-RunFolder', $r.folder, '-TimeoutSec', '5', '-PollSec', '1')
    Assert-True ($res.exit -eq 0 -and $res.out.result -eq 'started' -and $res.out.coordinator_id -eq 'mc-ok' -and $res.out.baseline_tokens -eq 41000) "a marked coordinator is reported started ($($res.text))"

    # ---- await: a coordinator that exits 1 before bootstrap is 'exited' with its exit code and log tail (exit 1).
    $r = New-FixtureRun -Name 'await-exited'
    Add-Launch -Folder $r.folder -Id 'mc-bad'
    Write-Utf8 -Path (Join-Path $r.folder 'coordinator-mc-bad.log') -Content "booting`nError: CLAUDE_CODE_OAUTH_TOKEN is not set`n"
    Write-Utf8 -Path (Join-Path $r.folder 'coordinator-mc-bad.exit.json') -Content '{"coordinator_id":"mc-bad","exit_code":1,"failure_category":null}'
    $res = Invoke-Script $await @('-RunFolder', $r.folder, '-TimeoutSec', '5', '-PollSec', '1')
    Assert-True ($res.exit -eq 1 -and $res.out.result -eq 'exited' -and $res.out.exit_code -eq 1 -and [string]$res.out.log_tail -match 'OAUTH_TOKEN is not set' -and [string]$res.out.detail -match 'exited 1 before marking bootstrap') "a coordinator that exits before bootstrap is reported with its code and log tail ($($res.text))"

    # ---- await: a later launch that started wins over an earlier failed one.
    Add-Launch -Folder $r.folder -Id 'mc-retry' -At ([DateTime]::UtcNow.AddSeconds(1))
    Set-Mark -Folder $r.folder -Id 'mc-retry'
    $res = Invoke-Script $await @('-RunFolder', $r.folder, '-TimeoutSec', '5', '-PollSec', '1')
    Assert-True ($res.exit -eq 0 -and $res.out.coordinator_id -eq 'mc-retry') 'a retried launch that marked bootstrap is started even after an earlier exit'

    # ---- await: a failed launcher (no coordinator) is 'exited' with launcher_exit.
    $r = New-FixtureRun -Name 'await-launcher'
    Add-Launch -Folder $r.folder -Id 'mc-nolaunch' -LauncherExit 3
    $res = Invoke-Script $await @('-RunFolder', $r.folder, '-TimeoutSec', '5', '-PollSec', '1')
    Assert-True ($res.exit -eq 1 -and $res.out.result -eq 'exited' -and $res.out.launcher_exit -eq 3) "a failed launcher is reported ($($res.text))"

    # ---- await: the watcher's stop row is 'stopped'.
    $r = New-FixtureRun -Name 'await-stopped'
    [IO.File]::AppendAllText((Join-Path $r.folder 'launches.jsonl'), ((([ordered]@{ type = 'stopped'; trigger_seq = 1; stopped_utc = [DateTime]::UtcNow.AddSeconds(1).ToString('o'); reason = 'thrash' }) | ConvertTo-Json -Compress) + "`n"))
    $res = Invoke-Script $await @('-RunFolder', $r.folder, '-TimeoutSec', '5', '-PollSec', '1')
    Assert-True ($res.exit -eq 1 -and $res.out.result -eq 'stopped' -and $res.out.stop_reason -eq 'thrash') "a watcher stop is reported ($($res.text))"

    # ---- await: launches before -SinceUtc are ignored; nothing new is a timeout (exit 2) naming the pending launch.
    $r = New-FixtureRun -Name 'await-timeout'
    Add-Launch -Folder $r.folder -Id 'mc-old' -At ([DateTime]::UtcNow.AddHours(-1))
    Set-Mark -Folder $r.folder -Id 'mc-old'
    Add-Launch -Folder $r.folder -Id 'mc-slow'
    Write-Utf8 -Path (Join-Path $r.folder 'coordinator-mc-slow.log') -Content "reading managed-resume.md`n"
    $res = Invoke-Script $await @('-RunFolder', $r.folder, '-SinceUtc', [DateTime]::UtcNow.AddMinutes(-5).ToString('o'), '-TimeoutSec', '2', '-PollSec', '1')
    Assert-True ($res.exit -eq 2 -and $res.out.result -eq 'timeout' -and $res.out.coordinator_id -eq 'mc-slow' -and [string]$res.out.log_tail -match 'managed-resume') "an older marked launch does not count and a slow boot times out with its log tail ($($res.text))"

    # ---- await: the default since is the newest continuation request, so an earlier launch does not count.
    $r = New-FixtureRun -Name 'await-default-since'
    Add-Launch -Folder $r.folder -Id 'mc-before' -At ([DateTime]::UtcNow.AddMinutes(-10))
    Set-Mark -Folder $r.folder -Id 'mc-before'
    $res = Invoke-Script $await @('-RunFolder', $r.folder, '-TimeoutSec', '1', '-PollSec', '1')
    Assert-True ($res.exit -eq 2 -and $res.out.result -eq 'timeout' -and [string]$res.out.detail -match 'no launch since the request') "a launch before the newest request is ignored by default ($($res.text))"

    # ---- watch: quiet run times out with exit 2 and reason quiet.
    $w = New-FixtureRun -Name 'watch-quiet'
    $leaseWatcher = [ordered]@{ coordinator_id = 'mc-live'; host = 'claude'; session_id = $null; pid = $PID; pid_start_utc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); launched_by = 'watcher'; state = 'running'; starting_until_utc = $null; ttl_sec = 600; acquired_utc = [DateTime]::UtcNow.ToString('o'); expires_utc = [DateTime]::UtcNow.AddMinutes(10).ToString('o'); released_utc = $null }
    Write-Utf8 -Path (Join-Path $w.folder 'coordinator.lease') -Content ($leaseWatcher | ConvertTo-Json)
    $res = Invoke-Script $watch @('-RunFolder', $w.folder, '-TimeoutSec', '2', '-PollSec', '1')
    Assert-True ($res.exit -eq 2 -and $res.out.reason -eq 'quiet' -and $res.out.coordinator.state -eq 'running') "a quiet run returns quiet ($($res.text))"

    # ---- watch: run_status change wakes it.
    $job = Start-Job -ScriptBlock { param($path) Start-Sleep -Seconds 2; (Get-Content -Raw -LiteralPath $path).Replace('run_status: runnable', 'run_status: awaiting_danny') | Set-Content -LiteralPath $path -NoNewline } -ArgumentList $w.state
    $res = Invoke-Script $watch @('-RunFolder', $w.folder, '-TimeoutSec', '20', '-PollSec', '1')
    Receive-Job $job -Wait -AutoRemoveJob | Out-Null
    Assert-True ($res.exit -eq 0 -and $res.out.reason -eq 'run_status' -and [string]$res.out.detail -match 'runnable -> awaiting_danny') "a stop wakes the watch ($($res.text))"

    # ---- watch: a job turning orphaned (worker death) wakes it.
    $w = New-FixtureRun -Name 'watch-job'
    Write-Utf8 -Path (Join-Path $w.folder 'coordinator.lease') -Content ($leaseWatcher | ConvertTo-Json)
    $record = [ordered]@{ job_id = 'j-fixture'; kind = 'worker'; status = 'queued'; exit_code = $null; status_reason = '' }
    $recordPath = Join-Path $w.folder 'jobs/j-fixture.json'
    Write-Utf8 -Path $recordPath -Content ($record | ConvertTo-Json)
    $job = Start-Job -ScriptBlock { param($path) Start-Sleep -Seconds 2; $r = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json; $r.status = 'orphaned'; [IO.File]::WriteAllText($path, ($r | ConvertTo-Json)) } -ArgumentList $recordPath
    $res = Invoke-Script $watch @('-RunFolder', $w.folder, '-TimeoutSec', '20', '-PollSec', '1')
    Receive-Job $job -Wait -AutoRemoveJob | Out-Null
    Assert-True ($res.exit -eq 0 -and $res.out.reason -eq 'job_failed' -and [string]$res.out.detail -match 'j-fixture is orphaned') "worker death wakes the watch ($($res.text))"

    # ---- watch: a dead watcher-launched coordinator holding the lease wakes it.
    $w = New-FixtureRun -Name 'watch-gone'
    Write-Utf8 -Path (Join-Path $w.folder 'coordinator.lease') -Content ($leaseWatcher | ConvertTo-Json)
    $dead = Start-Process -FilePath 'pwsh' -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru -Wait
    $job = Start-Job -ScriptBlock { param($path, $deadPid) Start-Sleep -Seconds 2; $l = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json; $l.coordinator_id = 'mc-crashed'; $l.pid = $deadPid; $l.pid_start_utc = $null; [IO.File]::WriteAllText($path, ($l | ConvertTo-Json)) } -ArgumentList (Join-Path $w.folder 'coordinator.lease'), $dead.Id
    $res = Invoke-Script $watch @('-RunFolder', $w.folder, '-TimeoutSec', '20', '-PollSec', '1')
    Receive-Job $job -Wait -AutoRemoveJob | Out-Null
    Assert-True ($res.exit -eq 0 -and $res.out.reason -eq 'coordinator' -and [string]$res.out.detail -match 'mc-crashed is gone') "a crashed coordinator wakes the watch ($($res.text))"

    # ---- watch: a runnable run with no coordinator past the grace wakes it; a starting coordinator does not.
    $w = New-FixtureRun -Name 'watch-none'
    $res = Invoke-Script $watch @('-RunFolder', $w.folder, '-TimeoutSec', '10', '-PollSec', '1', '-NoCoordinatorSec', '2')
    Assert-True ($res.exit -eq 0 -and $res.out.reason -eq 'coordinator' -and [string]$res.out.detail -match 'no live coordinator \(none\)') "a runnable run left without a coordinator wakes the watch ($($res.text))"
    $starting = [ordered]@{ coordinator_id = 'mc-boot'; host = 'claude'; session_id = $null; pid = $null; pid_start_utc = $null; launched_by = 'watcher'; state = 'starting'; starting_until_utc = [DateTime]::UtcNow.AddMinutes(15).ToString('o'); ttl_sec = 600; acquired_utc = [DateTime]::UtcNow.ToString('o'); expires_utc = [DateTime]::UtcNow.AddMinutes(10).ToString('o'); released_utc = $null }
    Write-Utf8 -Path (Join-Path $w.folder 'coordinator.lease') -Content ($starting | ConvertTo-Json)
    $res = Invoke-Script $watch @('-RunFolder', $w.folder, '-TimeoutSec', '4', '-PollSec', '1', '-NoCoordinatorSec', '2')
    Assert-True ($res.exit -eq 2 -and $res.out.reason -eq 'quiet' -and $res.out.coordinator.state -eq 'starting') "a booting coordinator is not reported missing ($($res.text))"

    # ---- the default launcher returns at once while its coordinator runs, and tags the coordinator tree.
    if (-not $IsWindows) {
        $bin = Join-Path $tempRoot 'fake-bin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        Write-Utf8 -Path (Join-Path $bin 'claude') -Content "#!/bin/sh`nsleep 20`necho fake-claude-done`n"
        & chmod +x (Join-Path $bin 'claude')
        $lr = New-FixtureRun -Name 'launcher-detach'
        $savedPath = $env:PATH
        $env:PATH = $bin + [IO.Path]::PathSeparator + $env:PATH
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $launched = & pwsh -NoProfile -NonInteractive -File (Join-Path $scriptDir 'launch-managed-coordinator.ps1') -Host claude -RunId 'launcher-detach' -RunFolder $lr.folder -BuildStatePath $lr.state -CoordinatorId 'mc-detach' 2>&1
            $elapsed = $clock.Elapsed.TotalSeconds
        }
        finally { $env:PATH = $savedPath }
        $lease = Get-Content -Raw -LiteralPath (Join-Path $lr.folder 'coordinator.lease') | ConvertFrom-Json
        Assert-True ($LASTEXITCODE -eq 0 -and $elapsed -lt 15) "the launcher returns while its coordinator still runs ($([int]$elapsed) s; $($launched -join ' '))"
        Assert-True ($lease.state -eq 'starting' -and $lease.launched_by -eq 'watcher' -and $lease.pid) "the launcher's lease is starting with the wrapper pid ($($lease | ConvertTo-Json -Compress))"
        if ($IsLinux) {
            $tree = @([int]$lease.pid) + @(Get-ChildItem /proc -Directory | Where-Object { $_.Name -match '^\d+$' } | Where-Object { try { ((Get-Content -Raw "/proc/$($_.Name)/stat") -split ' ')[3] -eq [string]$lease.pid } catch { $false } } | ForEach-Object { [int]$_.Name })
            $tagged = @($tree | Where-Object { try { [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes("/proc/$_/environ")).Split([char]0) -ccontains 'DT_BUILD_COORDINATOR_ID=mc-detach' } catch { $false } })
            Assert-True ($tree.Count -ge 2 -and $tagged.Count -eq $tree.Count) "the wrapper and the coordinator under it carry DT_BUILD_COORDINATOR_ID from exec (tree $($tree -join ','); tagged $($tagged -join ','))"
        }
        $exitPath = Join-Path $lr.folder 'coordinator-mc-detach.exit.json'
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while (-not (Test-Path -LiteralPath $exitPath) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 500 }
        Assert-True ((Test-Path -LiteralPath $exitPath) -and (Get-Content -Raw (Join-Path $lr.folder 'coordinator-mc-detach.log')).Contains('fake-claude-done')) 'the detached coordinator still writes its log and exit receipt'
    }

    Write-Output "SUMMARY: $script:passed passed"
}
catch {
    $exitCode = 1
    Write-Output "FAIL: $($_.Exception.Message)"
    Write-Output $_.ScriptStackTrace
    Write-Output "SUMMARY: $script:passed passed"
}
finally {
    if ($null -eq $savedState) { Remove-Item Env:DT_BUILD_STATE_DIR -ErrorAction SilentlyContinue } else { $env:DT_BUILD_STATE_DIR = $savedState }
    if ($null -ne $savedCoordinator) { $env:DT_BUILD_COORDINATOR_ID = $savedCoordinator }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
exit $exitCode
