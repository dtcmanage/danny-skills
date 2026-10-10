param()

Set-StrictMode -Version Latest
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
$repoRoot = (Resolve-Path (Join-Path $scriptDir '..\..\..')).Path
$dtJob = Join-Path $scriptDir 'dt-job.ps1'
$watcher = Join-Path $scriptDir 'dt-build-watcher.ps1'
$templatePath = Join-Path $repoRoot 'skills\dt-pipeline\templates\build-state-template.md'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-watcher-tests-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$savedEnv = @{}
foreach ($name in @('DT_BUILD_STATE_DIR', 'DT_MODEL_ROUTER_STATE', 'DT_MODEL_ROUTER_ALERT_TRANSPORT', 'DT_BUILD_COORDINATOR_LAUNCHER', 'DT_BUILD_VENDOR_LIMITS_SCRIPT', 'DT_BUILD_WATCHER_NOW_UTC', 'DT_BUILD_COORDINATOR_ID', 'DT_TEST_DM_LOG', 'DT_TEST_LAUNCH_LOG', 'DT_TEST_DEAD_PID', 'DT_TEST_BLOCKED', 'DT_TEST_RESET_CLAUDE', 'DT_TEST_RESET_CODEX', 'DT_TEST_DTJOB', 'DT_TEST_LIVE_CHILD', 'DT_TEST_LAUNCH_SLEEP_MS', 'DT_TEST_LAUNCH_FAIL', 'DT_TEST_DM_FAIL', 'DT_BUILD_COORDINATOR_LOCK_HELD', 'DT_JOB_ID', 'DT_TEST_TREE_FAIL', 'DT_TEST_KILLABLE', 'DT_TEST_KILL_LOG', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME')) {
    $savedEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
}

# Isolation: temp registry, temp router state, fake alert transport, fake launcher, fake vendor limits,
# and empty transcript roots so a coordinator's context lookup never reads a real session.
$env:DT_MODEL_ROUTER_STATE = Join-Path $tempRoot 'router-state'
$env:CLAUDE_CONFIG_DIR = Join-Path $tempRoot 'claude-config'
$env:CODEX_HOME = Join-Path $tempRoot 'codex-home'
$env:DT_TEST_DM_LOG = Join-Path $tempRoot 'dms.jsonl'
$env:DT_TEST_LAUNCH_LOG = Join-Path $tempRoot 'launches-fake.jsonl'
$fakeTransport = Join-Path $tempRoot 'fake-alert-transport.ps1'
Write-Utf8 -Path $fakeTransport -Content @'
param($request)
if ($env:DT_TEST_DM_FAIL) { throw 'fake transport down' }
if ($request['kind'] -eq 'secret') { return 'fake-secret' }
if ([string]$request['uri'] -like '*/oauth2/applications/@me') { return [pscustomobject]@{ owner = [pscustomobject]@{ id = '1' } } }
if ([string]$request['uri'] -like '*/messages') {
    $content = ([string]$request['body'] | ConvertFrom-Json).content
    [System.IO.File]::AppendAllText($env:DT_TEST_DM_LOG, (([ordered]@{ content = $content } | ConvertTo-Json -Compress) + "`n"))
}
return [pscustomobject]@{ id = 'fake' }
'@
$env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $fakeTransport
$fakeLauncher = Join-Path $tempRoot 'fake-launcher.ps1'
Write-Utf8 -Path $fakeLauncher -Content @'
param([Alias('Host')][string]$CoordinatorHost, [string]$RunId, [string]$RunFolder, [string]$BuildStatePath, [string]$CoordinatorId)
# Same order as the default launcher: lease first (a refusal starts nothing), then the child, then its pid.
[System.IO.File]::WriteAllText((Join-Path $RunFolder 'fake-launcher-started'), $CoordinatorId)
if ($env:DT_TEST_LAUNCH_SLEEP_MS) { Start-Sleep -Milliseconds ([int]$env:DT_TEST_LAUNCH_SLEEP_MS) }
& pwsh -NoProfile -File $env:DT_TEST_DTJOB lease -RunFolder $RunFolder -Action acquire -CoordinatorId $CoordinatorId -Host $CoordinatorHost -LaunchedBy watcher -TtlSec 600 -Json *> $null
if ($LASTEXITCODE -ne 0) { exit 3 }
if ($env:DT_TEST_TREE_FAIL) {
    # The child starts a grandchild (standing in for claude/codex), then recording the child's pid fails;
    # the failure path below is the default launcher's.
    $childPid = $null
    $grandFile = "$($env:DT_TEST_TREE_FAIL).grand"
    try {
        $childScript = "`$g = Start-Process -FilePath 'ping.exe' -ArgumentList '-n','90','127.0.0.1' -WindowStyle Hidden -PassThru; [System.IO.File]::WriteAllText('$grandFile', [string]`$g.Id); Start-Sleep -Seconds 90"
        $childPid = (Start-Process -FilePath 'pwsh' -ArgumentList '-NoProfile', '-Command', $childScript -WindowStyle Hidden -PassThru).Id
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath $grandFile) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        $grandPid = [int](Get-Content -Raw -LiteralPath $grandFile)
        [System.IO.File]::WriteAllText($env:DT_TEST_TREE_FAIL, ([ordered]@{ child = $childPid; grandchild = $grandPid } | ConvertTo-Json -Compress))
        throw 'DT_BUILD_LEASE_FAILED: fake pid record failure'
    }
    catch {
        if ($childPid) { try { [System.Diagnostics.Process]::GetProcessById($childPid).Kill($true) } catch { } }
        & pwsh -NoProfile -File $env:DT_TEST_DTJOB lease -RunFolder $RunFolder -Action release -CoordinatorId $CoordinatorId -Json *> $null
        exit 1
    }
}
if ($env:DT_TEST_LAUNCH_FAIL) {
    & pwsh -NoProfile -File $env:DT_TEST_DTJOB lease -RunFolder $RunFolder -Action release -CoordinatorId $CoordinatorId -Json *> $null
    exit 1
}
$child = Start-Process -FilePath 'ping.exe' -ArgumentList '-n', '90', '127.0.0.1' -WindowStyle Hidden -PassThru
& pwsh -NoProfile -File $env:DT_TEST_DTJOB lease -RunFolder $RunFolder -Action renew -CoordinatorId $CoordinatorId -Pid $child.Id -Json *> $null
# The fake coordinator never consumes its trigger; unless told to stay up, it crashes right after launch.
if (-not $env:DT_TEST_LIVE_CHILD) { Stop-Process -Id $child.Id -Force; $child.WaitForExit() }
[System.IO.File]::AppendAllText($env:DT_TEST_LAUNCH_LOG, (([ordered]@{ run_id = $RunId; host = $CoordinatorHost; coordinator_id = $CoordinatorId; build_state_path = $BuildStatePath; pid = $child.Id } | ConvertTo-Json -Compress) + "`n"))
'@
$env:DT_TEST_DTJOB = $dtJob
$env:DT_BUILD_COORDINATOR_LAUNCHER = $fakeLauncher
$fakeLimits = Join-Path $tempRoot 'fake-vendor-limits.ps1'
Write-Utf8 -Path $fakeLimits -Content @'
param([string]$Vendor, [switch]$Json)
$blocked = @(([string]$env:DT_TEST_BLOCKED) -split ',' | Where-Object { $_ }) -contains $Vendor
$reset = if ($Vendor -eq 'claude') { $env:DT_TEST_RESET_CLAUDE } else { $env:DT_TEST_RESET_CODEX }
[ordered]@{ vendor = $Vendor; blocked = $blocked; reason = $null; used_percent = $(if ($blocked) { 99 } else { 10 }); resets_at_utc = $reset } | ConvertTo-Json -Compress
'@
$env:DT_BUILD_VENDOR_LIMITS_SCRIPT = $fakeLimits
$env:DT_TEST_BLOCKED = ''
$deadProcess = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'exit 0' -WindowStyle Hidden -PassThru -Wait
$env:DT_TEST_DEAD_PID = [string]$deadProcess.Id
Remove-Item Env:DT_BUILD_COORDINATOR_ID -ErrorAction SilentlyContinue
Remove-Item Env:DT_BUILD_WATCHER_NOW_UTC -ErrorAction SilentlyContinue

function Use-Scenario {
    # Each scenario gets its own registry so watcher ticks only see that scenario's runs.
    param([string]$Name)
    $env:DT_BUILD_STATE_DIR = Join-Path $tempRoot "state-$Name"
    Remove-Item Env:DT_BUILD_WATCHER_NOW_UTC -ErrorAction SilentlyContinue
}

function Invoke-DtJob {
    param([string[]]$Arguments)
    $raw = & pwsh -NoProfile -File $dtJob @Arguments -Json
    if ($LASTEXITCODE -ne 0) { throw "dt-job $($Arguments -join ' ') exited $LASTEXITCODE" }
    return (($raw -join "`n") | ConvertFrom-Json)
}

function Invoke-DtJobExpectFail {
    param([string[]]$Arguments)
    $raw = & pwsh -NoProfile -File $dtJob @Arguments -Json 2>&1
    return [pscustomobject]@{ exit = $LASTEXITCODE; text = (($raw | ForEach-Object { [string]$_ }) -join "`n") }
}

function New-BuildState {
    param([string]$Path, [string]$RunStatus = 'runnable', [int]$Cursor = 0)
    $text = (Get-Content -Raw -LiteralPath $templatePath).Replace('__RUN_STATUS__', $RunStatus).Replace('__LAST_CONSUMED_EVENT_SEQ__', [string]$Cursor).Replace('__UPDATED_UTC__', '2026-10-10T00:00:00Z')
    Write-Utf8 -Path $Path -Content $text
}

function Write-Lease {
    param([string]$RunFolder, [string]$LaunchedBy = 'watcher', [int]$LeasePid = [int]$env:DT_TEST_DEAD_PID, [string]$PidStartUtc = $null, [DateTime]$ExpiresUtc = [DateTime]::UtcNow.AddMinutes(-5), [string]$CoordinatorId = 'old-coordinator')
    $lease = [ordered]@{ coordinator_id = $CoordinatorId; host = 'claude'; session_id = $null; pid = $LeasePid; pid_start_utc = $(if ($PidStartUtc) { $PidStartUtc } else { $null }); launched_by = $LaunchedBy; ttl_sec = 600; acquired_utc = $ExpiresUtc.AddMinutes(-10).ToString('o'); expires_utc = $ExpiresUtc.ToString('o'); released_utc = $null }
    Write-Utf8 -Path (Join-Path $RunFolder 'coordinator.lease') -Content ($lease | ConvertTo-Json)
}

function New-Run {
    param([string]$Name, [string]$PinnedHost = 'claude', [switch]$Unmanaged, [string]$LaunchedBy = 'watcher', [int]$Cursor = 0, [switch]$NoLease)
    $rf = Join-Path $tempRoot "runs/$Name"
    New-Item -ItemType Directory -Path $rf -Force | Out-Null
    $bs = Join-Path $tempRoot "planning/$Name/_build-state.md"
    New-BuildState -Path $bs -Cursor $Cursor
    $registerArgs = @('register-run', '-RunFolder', $rf, '-BuildStatePath', $bs, '-RunId', $Name, '-PinnedHost', $PinnedHost)
    if (-not $Unmanaged) { $registerArgs += '-Managed' }
    Invoke-DtJob $registerArgs | Out-Null
    if (-not $NoLease) { Write-Lease -RunFolder $rf -LaunchedBy $LaunchedBy }
    return [pscustomobject]@{ run_id = $Name; folder = $rf; state = $bs }
}

function Invoke-Tick {
    param([DateTime]$NowUtc)
    if ($PSBoundParameters.ContainsKey('NowUtc')) { $env:DT_BUILD_WATCHER_NOW_UTC = $NowUtc.ToString('o') } else { Remove-Item Env:DT_BUILD_WATCHER_NOW_UTC -ErrorAction SilentlyContinue }
    $raw = & pwsh -NoProfile -File $watcher
    $code = $LASTEXITCODE
    Remove-Item Env:DT_BUILD_WATCHER_NOW_UTC -ErrorAction SilentlyContinue
    $results = @($raw | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    if ($code -ne 0) { throw "watcher exited $code : $($raw -join ' | ')" }
    return $results
}

function Get-LaunchCount {
    param([string]$RunId)
    if (-not (Test-Path -LiteralPath $env:DT_TEST_LAUNCH_LOG)) { return 0 }
    return @(Get-Content -LiteralPath $env:DT_TEST_LAUNCH_LOG | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.run_id -eq $RunId }).Count
}

function Get-Launches {
    param([string]$RunId)
    if (-not (Test-Path -LiteralPath $env:DT_TEST_LAUNCH_LOG)) { return @() }
    return @(Get-Content -LiteralPath $env:DT_TEST_LAUNCH_LOG | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.run_id -eq $RunId })
}

function Get-DmCount {
    param([string]$RunId)
    if (-not (Test-Path -LiteralPath $env:DT_TEST_DM_LOG)) { return 0 }
    return @(Get-Content -LiteralPath $env:DT_TEST_DM_LOG | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { ([string]$_.content).Contains("run $RunId ") }).Count
}

function Get-RunState {
    param([string]$Path)
    $text = Get-Content -Raw -LiteralPath $Path
    $status = if ($text -match '(?m)^run_status:\s*(\S+)') { $Matches[1] } else { $null }
    $cursor = if ($text -match '(?m)^last_consumed_event_seq:\s*(\d+)') { [int]$Matches[1] } else { $null }
    return [pscustomobject]@{ run_status = $status; cursor = $cursor }
}

function Get-LaunchRecords {
    param([string]$RunFolder)
    $path = Join-Path $RunFolder 'launches.jsonl'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-Content -LiteralPath $path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-JobRecord {
    param([string]$RunFolder, [string]$JobId)
    return (Get-Content -Raw -LiteralPath (Join-Path $RunFolder "jobs/$JobId.json") | ConvertFrom-Json)
}

function Wait-JobRunning {
    param([string]$RunFolder, [string]$JobId, [int]$TimeoutSec = 60)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        $r = Get-JobRecord -RunFolder $RunFolder -JobId $JobId
        if ($r.status -eq 'running' -and $r.pid) { return $r }
        Start-Sleep -Milliseconds 250
    }
    throw "TIMEOUT waiting for $JobId to run"
}

function Stop-Job {
    param([string]$RunFolder, [string]$JobId)
    Invoke-DtJob @('cancel', '-RunFolder', $RunFolder, '-JobId', $JobId) | Out-Null
}

function New-CodexRollout {
    # A Codex rollout whose last token_count reports the final input size.
    param([string]$Path, [long[]]$Inputs)
    $lines = @(([ordered]@{ timestamp = [DateTime]::UtcNow.ToString('o'); type = 'session_meta'; payload = [ordered]@{ id = [guid]::NewGuid().ToString(); cwd = 'C:\fixture'; cli_version = '0.0.0' } } | ConvertTo-Json -Compress -Depth 6))
    foreach ($n in $Inputs) {
        $lines += ([ordered]@{ timestamp = [DateTime]::UtcNow.ToString('o'); type = 'event_msg'; payload = [ordered]@{ type = 'token_count'; info = [ordered]@{ total_token_usage = [ordered]@{ input_tokens = $n * 3 }; last_token_usage = [ordered]@{ input_tokens = $n; cached_input_tokens = 1000; output_tokens = 50 } } } } | ConvertTo-Json -Compress -Depth 6)
    }
    Write-Utf8 -Path $Path -Content (($lines -join "`n") + "`n")
}

function Start-RotationFixture {
    # A managed Codex run whose watcher-launched coordinator (a pwsh child with a ping grandchild standing in
    # for codex) is past its hard limit, with an unconsumed event so a free run would relaunch at once.
    param([string]$Name)
    $run = New-Run -Name $Name -PinnedHost 'codex' -NoLease
    $grandFile = Join-Path $tempRoot "$Name.grand"
    $childScript = "`$g = Start-Process -FilePath 'ping.exe' -ArgumentList '-n','120','127.0.0.1' -WindowStyle Hidden -PassThru; [System.IO.File]::WriteAllText('$grandFile', [string]`$g.Id); Start-Sleep -Seconds 120"
    $child = Start-Process -FilePath 'pwsh' -ArgumentList '-NoProfile', '-Command', $childScript -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $grandFile) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    $grand = [int](Get-Content -Raw -LiteralPath $grandFile)
    $script:spawned += @($child.Id, $grand)
    $childStart = (Get-Process -Id $child.Id).StartTime.ToUniversalTime().ToString('o')
    $coordinatorId = "mc-$Name"
    $lease = [ordered]@{ coordinator_id = $coordinatorId; host = 'codex'; session_id = $null; pid = $child.Id; pid_start_utc = $childStart; launched_by = 'watcher'; ttl_sec = 600; acquired_utc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o'); expires_utc = [DateTime]::UtcNow.AddMinutes(9).ToString('o'); released_utc = $null }
    Write-Utf8 -Path (Join-Path $run.folder 'coordinator.lease') -Content ($lease | ConvertTo-Json)
    $rollout = Join-Path $tempRoot "$Name-rollout.jsonl"
    New-CodexRollout -Path $rollout -Inputs @(50000, 130000)
    $baseline = [ordered]@{ coordinators = [ordered]@{ $coordinatorId = [ordered]@{ coordinator_id = $coordinatorId; host = 'codex'; transcript_path = $rollout; session_id = $null; transcript_source = 'explicit'; baseline_tokens = 50000; marked_utc = [DateTime]::UtcNow.ToString('o') } } }
    Write-Utf8 -Path (Join-Path $run.folder 'context-baseline.json') -Content ($baseline | ConvertTo-Json -Depth 6)
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    return [pscustomobject]@{ run_id = $Name; folder = $run.folder; coordinator_id = $coordinatorId; child = $child.Id; grandchild = $grand }
}

function ConvertTo-TestUtc {
    param($Value)
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    return [DateTime]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Test-Alive {
    param([int]$ProcessId)
    return ($null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
}

function Invoke-StubbedRun {
    # One watcher tick for one run, in a process whose watcher functions $Stubs replaces.
    param([string]$RunFolder, [string]$Stubs)
    $raw = & pwsh -NoProfile -Command ". '$watcher'; $Stubs; Invoke-WatcherRun -Entry (Get-DtJobRegistryEntry -RunFolder '$RunFolder') | ConvertTo-Json -Compress -Depth 6"
    if ($LASTEXITCODE -ne 0) { throw "stubbed watcher run exited $LASTEXITCODE : $($raw -join ' | ')" }
    return (@($raw | Where-Object { $_ })[-1] | ConvertFrom-Json)
}

$exitCode = 0
$background = $null
$script:spawned = @()
try {
    # ---- wait: -Any, -All, timeout, compact text lines.
    Use-Scenario 'wait'
    $rf = Join-Path $tempRoot 'runs/wait'
    New-Item -ItemType Directory -Path $rf -Force | Out-Null
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Start-Sleep 1; ''a''')
    $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Start-Sleep 8; ''b''')
    $any = Invoke-DtJob @('wait', '-RunFolder', $rf, '-JobId', "$($a.job_id),$($b.job_id)", '-Any', '-TimeoutSec', '60')
    Assert-True ($any.result -eq 'finished') "wait -Any finished (got $($any.result))"
    Assert-True (@($any.jobs).Count -eq 1 -and $any.jobs[0].job_id -eq $a.job_id -and $any.jobs[0].status -eq 'succeeded' -and $any.jobs[0].exit_code -eq 0) 'wait -Any returns the first finished job with status and exit code'
    Assert-True ((Test-Path -LiteralPath $any.jobs[0].evidence) -and (@($any.still_running) -contains $b.job_id)) 'wait -Any names evidence and the still-running job'
    $all = Invoke-DtJob @('wait', '-RunFolder', $rf, '-JobId', "$($a.job_id),$($b.job_id)", '-All', '-TimeoutSec', '60')
    Assert-True ($all.result -eq 'finished' -and @($all.jobs).Count -eq 2 -and @($all.still_running).Count -eq 0) 'wait -All returns both jobs'
    $text = @(& pwsh -NoProfile -File $dtJob wait -RunFolder $rf -JobId "$($a.job_id),$($b.job_id)" -All -TimeoutSec 10)
    Assert-True ($text.Count -eq 2 -and $text[0] -match "^$($a.job_id) succeeded exit=0 evidence=\S" -and @($text | Where-Object { $_.Length -gt 400 }).Count -eq 0) 'text wait prints one compact line per finished job'
    $c = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Start-Sleep 30')
    $started = [DateTime]::UtcNow
    $timeout = Invoke-DtJob @('wait', '-RunFolder', $rf, '-JobId', $c.job_id, '-Any', '-TimeoutSec', '2')
    Assert-True ($timeout.result -eq 'wait_timeout' -and @($timeout.still_running) -contains $c.job_id -and @($timeout.jobs).Count -eq 0) 'wait times out with the still-running ids'
    Assert-True (([DateTime]::UtcNow - $started).TotalSeconds -lt 15) 'wait timeout returns promptly'
    $text = @(& pwsh -NoProfile -File $dtJob wait -RunFolder $rf -JobId $c.job_id -Any -TimeoutSec 1)
    Assert-True ($text[-1] -eq "wait_timeout still_running=$($c.job_id)") 'text wait timeout line names the running ids'
    Stop-Job -RunFolder $rf -JobId $c.job_id
    $bad = Invoke-DtJobExpectFail @('wait', '-RunFolder', $rf, '-JobId', $a.job_id, '-TimeoutSec', '5')
    Assert-True ($bad.exit -ne 0 -and $bad.text -match 'exactly one of -Any or -All') 'wait requires -Any or -All'

    # ---- lease: acquire conflict, renew, release, renewal by other verbs.
    Use-Scenario 'lease'
    $rf = Join-Path $tempRoot 'runs/lease'
    New-Item -ItemType Directory -Path $rf -Force | Out-Null
    $leaseA = Invoke-DtJob @('lease', '-RunFolder', $rf, '-Action', 'acquire', '-CoordinatorId', 'coord-a', '-Host', 'claude', '-SessionId', 's-1', '-LaunchedBy', 'interactive')
    Assert-True ($leaseA.coordinator_id -eq 'coord-a' -and $leaseA.host -eq 'claude' -and $leaseA.session_id -eq 's-1' -and $leaseA.launched_by -eq 'interactive' -and $null -eq $leaseA.pid) 'lease acquire records holder fields'
    $onDisk = Get-Content -Raw -LiteralPath (Join-Path $rf 'coordinator.lease') | ConvertFrom-Json
    $ttl = ($onDisk.expires_utc - $onDisk.acquired_utc).TotalSeconds
    Assert-True ([Math]::Round($ttl) -eq 600) "default lease TTL is 600 s (got $ttl)"
    $conflict = Invoke-DtJobExpectFail @('lease', '-RunFolder', $rf, '-Action', 'acquire', '-CoordinatorId', 'coord-b')
    Assert-True ($conflict.exit -ne 0 -and $conflict.text -match 'DT_JOB_LEASE_HELD') 'acquire fails while a different unexpired holder exists'
    $notHolder = Invoke-DtJobExpectFail @('lease', '-RunFolder', $rf, '-Action', 'renew', '-CoordinatorId', 'coord-b')
    Assert-True ($notHolder.exit -ne 0 -and $notHolder.text -match 'DT_JOB_LEASE_NOT_HOLDER') 'renew by a non-holder fails'
    $again = Invoke-DtJob @('lease', '-RunFolder', $rf, '-Action', 'acquire', '-CoordinatorId', 'coord-a', '-TtlSec', '30')
    Assert-True ($again.coordinator_id -eq 'coord-a') 'the holder can re-acquire'
    $released = Invoke-DtJob @('lease', '-RunFolder', $rf, '-Action', 'release', '-CoordinatorId', 'coord-a')
    Assert-True ([bool]$released.released_utc -and $released.coordinator_id -eq 'coord-a') 'release keeps the holder identity and expires the lease'
    $leaseB = Invoke-DtJob @('lease', '-RunFolder', $rf, '-Action', 'acquire', '-CoordinatorId', 'coord-b', '-Pid', $PID, '-LaunchedBy', 'watcher')
    Assert-True ($leaseB.coordinator_id -eq 'coord-b' -and $leaseB.pid -eq $PID -and [bool]$leaseB.pid_start_utc) 'acquire after release succeeds and records pid start time'
    $before = (Get-Content -Raw -LiteralPath (Join-Path $rf 'coordinator.lease') | ConvertFrom-Json).expires_utc
    Start-Sleep -Milliseconds 1200
    $env:DT_BUILD_COORDINATOR_ID = 'coord-b'
    Invoke-DtJob @('status', '-RunFolder', $rf) | Out-Null
    Remove-Item Env:DT_BUILD_COORDINATOR_ID
    $after = (Get-Content -Raw -LiteralPath (Join-Path $rf 'coordinator.lease') | ConvertFrom-Json).expires_utc
    Assert-True ($after -gt $before) 'another verb renews the lease when DT_BUILD_COORDINATOR_ID matches the holder'
    $env:DT_BUILD_COORDINATOR_ID = 'someone-else'
    Invoke-DtJob @('status', '-RunFolder', $rf) | Out-Null
    Remove-Item Env:DT_BUILD_COORDINATOR_ID
    $unchanged = (Get-Content -Raw -LiteralPath (Join-Path $rf 'coordinator.lease') | ConvertFrom-Json).expires_utc
    Assert-True ($unchanged -eq $after) 'a non-holder verb leaves the lease alone'
    # An interactive coordinator's shell keeps no env: -CoordinatorId on each call renews its lease, so calls
    # spaced inside the TTL keep it live well past its first window.
    $rf = Join-Path $tempRoot 'runs/lease-interactive'
    New-Item -ItemType Directory -Path $rf -Force | Out-Null
    Invoke-DtJob @('lease', '-RunFolder', $rf, '-Action', 'acquire', '-CoordinatorId', 'coord-i', '-Host', 'claude', '-TtlSec', '8') | Out-Null
    $firstExpiry = ConvertTo-TestUtc (Get-Content -Raw -LiteralPath (Join-Path $rf 'coordinator.lease') | ConvertFrom-Json).expires_utc
    $lapses = 0
    foreach ($i in 1..4) {
        Start-Sleep -Seconds 3
        Invoke-DtJob @('status', '-RunFolder', $rf, '-CoordinatorId', 'coord-i') | Out-Null
        $l = Get-Content -Raw -LiteralPath (Join-Path $rf 'coordinator.lease') | ConvertFrom-Json
        if ((ConvertTo-TestUtc $l.expires_utc) -le [DateTime]::UtcNow -or $l.released_utc -or $l.coordinator_id -ne 'coord-i') { $lapses++ }
    }
    Assert-True ($lapses -eq 0 -and [DateTime]::UtcNow -gt $firstExpiry) "repeated -CoordinatorId calls spaced inside the TTL keep an interactive lease live past its first window ($lapses lapses)"

    # ---- registry: register, re-register replaces, unregister; DT_BUILD_STATE_DIR honored.
    Use-Scenario 'registry'
    $rf = Join-Path $tempRoot 'runs/registry'
    New-Item -ItemType Directory -Path $rf -Force | Out-Null
    $bs = Join-Path $tempRoot 'planning/registry/_build-state.md'
    New-BuildState -Path $bs
    Invoke-DtJob @('register-run', '-RunFolder', $rf, '-BuildStatePath', $bs, '-RunId', 'reg-1', '-PinnedHost', 'codex') | Out-Null
    Invoke-DtJob @('register-run', '-RunFolder', $rf, '-BuildStatePath', $bs, '-RunId', 'reg-1', '-PinnedHost', 'claude', '-Managed') | Out-Null
    $registry = Get-Content -Raw -LiteralPath (Join-Path $env:DT_BUILD_STATE_DIR 'active-runs.json') | ConvertFrom-Json
    Assert-True (@($registry.runs).Count -eq 1 -and $registry.runs[0].pinned_host -eq 'claude' -and $registry.runs[0].managed -eq $true) 're-register replaces the entry in the temp registry'
    $removed = Invoke-DtJob @('unregister-run', '-RunFolder', $rf)
    $registry = Get-Content -Raw -LiteralPath (Join-Path $env:DT_BUILD_STATE_DIR 'active-runs.json') | ConvertFrom-Json
    Assert-True ($removed.removed -eq 1 -and @($registry.runs).Count -eq 0) 'unregister-run removes the entry'

    # ---- consume never moves backwards and never past the last event.
    Use-Scenario 'consume'
    $run = New-Run -Name 'consume-run' -Unmanaged -LaunchedBy 'interactive'
    1..3 | ForEach-Object { Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder, '-Reason', "r$_") | Out-Null }
    Invoke-DtJob @('consume', '-RunFolder', $run.folder, '-Seq', '2') | Out-Null
    Assert-True ((Get-RunState $run.state).cursor -eq 2) 'consume advances the cursor'
    $back = Invoke-DtJob @('consume', '-RunFolder', $run.folder, '-Seq', '1')
    Assert-True ((Get-RunState $run.state).cursor -eq 2 -and $back.last_consumed_event_seq -eq 2) 'consume never moves the cursor backwards'
    Invoke-DtJob @('consume', '-RunFolder', $run.folder, '-Seq', '3') | Out-Null
    $ahead = Invoke-DtJobExpectFail @('consume', '-RunFolder', $run.folder, '-Seq', '9')
    Assert-True ($ahead.exit -ne 0 -and $ahead.text -match 'DT_JOB_CONSUME_AHEAD' -and (Get-RunState $run.state).cursor -eq 3) 'consume past the last event is refused'
    $events = @(Get-Content -LiteralPath (Join-Path $run.folder 'jobs/events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($events.Count -eq 3 -and @($events | Where-Object { $_.type -eq 'continuation_requested' }).Count -eq 3) 'consume appends no event; request-continuation appends one each'

    # ---- template fields: insert at position, then a two-line rewrite.
    $template = Get-Content -Raw -LiteralPath $templatePath
    $templateLines = $template -split "\r?\n"
    $u = [array]::IndexOf($templateLines, 'updated_utc: __UPDATED_UTC__')
    Assert-True ($u -ge 0 -and $templateLines[$u + 1] -eq 'run_status: __RUN_STATUS__' -and $templateLines[$u + 2] -eq 'last_consumed_event_seq: __LAST_CONSUMED_EVENT_SEQ__') 'template carries both fields directly under updated_utc'
    Use-Scenario 'template'
    $rf = Join-Path $tempRoot 'runs/template'
    New-Item -ItemType Directory -Path $rf -Force | Out-Null
    $legacyLines = [System.Collections.Generic.List[string]]::new()
    $skip = 0
    foreach ($line in $templateLines) {
        if ($line -match '^(run_status|last_consumed_event_seq):') { continue }
        if ($line -match '^<!-- run_status:') { $skip = 1; continue }
        if ($skip -eq 1) { $skip = 0; if ($line -match '-->\s*$') { continue } }
        $legacyLines.Add($line)
    }
    $legacy = ($legacyLines -join "`r`n").Replace('__UPDATED_UTC__', '2026-10-01T00:00:00Z')
    $legacyPath = Join-Path $tempRoot 'planning/template/_build-state.md'
    Write-Utf8 -Path $legacyPath -Content $legacy
    Invoke-DtJob @('request-continuation', '-RunFolder', $rf, '-BuildStatePath', $legacyPath) | Out-Null
    Invoke-DtJob @('consume', '-RunFolder', $rf, '-BuildStatePath', $legacyPath, '-Seq', '1') | Out-Null
    $inserted = [System.IO.File]::ReadAllText($legacyPath)
    $insertedLines = $inserted -split "`r`n"
    $lu = [array]::IndexOf($insertedLines, 'updated_utc: 2026-10-01T00:00:00Z')
    Assert-True ($lu -ge 0 -and $insertedLines[$lu + 1] -eq 'run_status: runnable' -and $insertedLines[$lu + 2] -eq 'last_consumed_event_seq: 1') 'missing fields are inserted directly under updated_utc'
    $expected = [System.Collections.Generic.List[string]]::new([string[]]($legacy -split "`r`n"))
    $expected.Insert($lu + 1, 'run_status: runnable'); $expected.Insert($lu + 2, 'last_consumed_event_seq: 1')
    Assert-True ($inserted -ceq ($expected -join "`r`n")) 'insert changes nothing else and keeps CRLF line endings'
    $beforeLines = $insertedLines
    Invoke-DtJob @('await-danny', '-RunFolder', $rf, '-BuildStatePath', $legacyPath, '-RunId', 'template-run', '-Operation', 'merge', '-Message', 'Merge ready.') | Out-Null
    $afterLines = [System.IO.File]::ReadAllText($legacyPath) -split "`r`n"
    $diff = @(0..($beforeLines.Count - 1) | Where-Object { $beforeLines[$_] -cne $afterLines[$_] })
    Assert-True ($afterLines.Count -eq $beforeLines.Count -and $diff.Count -eq 1 -and $afterLines[$lu + 1] -eq 'run_status: awaiting_danny') 'a later update rewrites only the field lines in place'
    Invoke-DtJob @('approve', '-RunFolder', $rf, '-BuildStatePath', $legacyPath, '-RunId', 'template-run', '-Operation', 'merge') | Out-Null
    Invoke-DtJob @('consume', '-RunFolder', $rf, '-BuildStatePath', $legacyPath, '-Seq', '3') | Out-Null
    $finalLines = [System.IO.File]::ReadAllText($legacyPath) -split "`r`n"
    $diff = @(0..($beforeLines.Count - 1) | Where-Object { $beforeLines[$_] -cne $finalLines[$_] })
    Assert-True ($diff.Count -eq 1 -and $finalLines[$lu + 2] -eq 'last_consumed_event_seq: 3' -and $finalLines[$lu + 1] -eq 'run_status: runnable') 'two-line rewrite leaves every other line untouched'
    $fresh = Join-Path $tempRoot 'planning/template/fresh.md'
    Write-Utf8 -Path $fresh -Content $template
    Invoke-DtJob @('consume', '-RunFolder', $rf, '-BuildStatePath', $fresh, '-Seq', '2') | Out-Null
    $freshLines = (Get-Content -Raw -LiteralPath $fresh) -split "\r?\n"
    Assert-True ($freshLines.Count -eq $templateLines.Count -and $freshLines[$u + 1] -eq 'run_status: runnable' -and $freshLines[$u + 2] -eq 'last_consumed_event_seq: 2') 'template placeholders are replaced in place'

    # ---- scenario 9: a live waiting coordinator past the old lease window is not replaced.
    Use-Scenario 'live-wait'
    $run = New-Run -Name 'live-wait'
    $job = Invoke-DtJob @('start', '-RunFolder', $run.folder, '-Command', 'Start-Sleep 12')
    # The waiting coordinator is a live process (this test's pid stands in for it).
    Invoke-DtJob @('lease', '-RunFolder', $run.folder, '-Action', 'acquire', '-CoordinatorId', 'waiter', '-Pid', [string]$PID, '-LaunchedBy', 'watcher', '-TtlSec', '4') | Out-Null
    $leaseStart = (Get-Content -Raw -LiteralPath (Join-Path $run.folder 'coordinator.lease') | ConvertFrom-Json).expires_utc
    $waitOut = Join-Path $tempRoot 'live-wait-out.txt'
    $env:DT_BUILD_COORDINATOR_ID = 'waiter'
    $background = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', "`"$dtJob`"", 'wait', '-RunFolder', "`"$($run.folder)`"", '-JobId', $job.job_id, '-All', '-TimeoutSec', '60', '-Json') -RedirectStandardOutput $waitOut -WindowStyle Hidden -PassThru
    Remove-Item Env:DT_BUILD_COORDINATOR_ID
    Start-Sleep -Seconds 8
    $leaseNow = (Get-Content -Raw -LiteralPath (Join-Path $run.folder 'coordinator.lease') | ConvertFrom-Json).expires_utc
    Assert-True ($leaseNow -gt $leaseStart -and $leaseNow -gt [DateTime]::UtcNow) 'a blocked wait renews the lease past its original window'
    Invoke-Tick | Out-Null
    Assert-True ((Get-LaunchCount 'live-wait') -eq 0) 'the watcher does not relaunch while the waiting coordinator holds a renewed lease'
    $background.WaitForExit(60000) | Out-Null
    $waitResult = Get-Content -Raw -LiteralPath $waitOut | ConvertFrom-Json
    Assert-True ($waitResult.result -eq 'finished' -and $waitResult.jobs[0].status -eq 'succeeded') 'the waiting coordinator receives the job result'
    $background = $null

    # ---- scenario 3: missed notification; the watcher records it and launches once for that trigger.
    Use-Scenario 'missed'
    $run = New-Run -Name 'missed'
    $job = Invoke-DtJob @('start', '-RunFolder', $run.folder, '-Command', 'Start-Sleep 60')
    $record = Wait-JobRunning -RunFolder $run.folder -JobId $job.job_id
    $seqBefore = @(Get-Content -LiteralPath (Join-Path $run.folder 'jobs/events.jsonl')).Count
    Invoke-DtJob @('consume', '-RunFolder', $run.folder, '-Seq', [string]$seqBefore) | Out-Null
    foreach ($p in @($record.runner_pid, $record.pid)) { if ($p) { Stop-Process -Id ([int]$p) -Force -ErrorAction SilentlyContinue } }
    Start-Sleep -Milliseconds 500
    $t0 = [DateTime]::UtcNow
    Invoke-Tick -NowUtc $t0 | Out-Null
    $record = Get-JobRecord -RunFolder $run.folder -JobId $job.job_id
    Assert-True ($record.status -eq 'orphaned') "the watcher's reconcile records the lost job (status $($record.status))"
    $launches = @(Get-LaunchRecords $run.folder | Where-Object { $_.type -eq 'launch' })
    $lastSeq = (Get-Content -LiteralPath (Join-Path $run.folder 'jobs/events.jsonl') | Select-Object -Last 1 | ConvertFrom-Json).seq
    Assert-True ((Get-LaunchCount 'missed') -eq 1 -and $launches.Count -eq 1 -and $launches[0].trigger_seq -eq $lastSeq -and $launches[0].attempt -eq 1 -and $launches[0].host -eq 'claude') 'one launch for the orphaned-job trigger, recorded with its trigger seq'
    Assert-True ($launches[0].pid -eq (Get-Launches 'missed')[0].pid -and [bool]$launches[0].launched_utc) 'launches.jsonl records the child pid and launch time'
    Invoke-Tick -NowUtc $t0 | Out-Null
    Invoke-Tick -NowUtc $t0.AddSeconds(90) | Out-Null
    Assert-True ((Get-LaunchCount 'missed') -eq 1) 'later ticks inside the retry window launch nothing'

    # ---- scenario 7 (unit level): a running job keeps its pid and start time across a relaunch.
    Use-Scenario 'adopt'
    $run = New-Run -Name 'adopt'
    $job = Invoke-DtJob @('start', '-RunFolder', $run.folder, '-Command', 'Start-Sleep 60')
    $beforeJob = Wait-JobRunning -RunFolder $run.folder -JobId $job.job_id
    Invoke-Tick | Out-Null
    $afterJob = Get-JobRecord -RunFolder $run.folder -JobId $job.job_id
    Assert-True ((Get-LaunchCount 'adopt') -eq 1) 'the dead coordinator is relaunched'
    Assert-True ($afterJob.status -eq 'running' -and $afterJob.pid -eq $beforeJob.pid -and $afterJob.process_start_utc -eq $beforeJob.process_start_utc -and $afterJob.runner_pid -eq $beforeJob.runner_pid) 'the running job keeps the same pid and start time'
    Stop-Job -RunFolder $run.folder -JobId $job.job_id

    # ---- interactive coordinator: one DM per waiting period, never a launch.
    Use-Scenario 'interactive'
    $run = New-Run -Name 'interactive' -LaunchedBy 'interactive'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    Invoke-Tick | Out-Null
    Invoke-Tick | Out-Null
    Assert-True ((Get-DmCount 'interactive') -eq 1) 'one DM for the first trigger across two ticks'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    Invoke-Tick | Out-Null
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    Invoke-Tick | Out-Null
    Invoke-Tick | Out-Null
    Assert-True ((Get-DmCount 'interactive') -eq 1) 'three events over several ticks of one waiting period send one DM'
    Invoke-DtJob @('consume', '-RunFolder', $run.folder, '-Seq', '1') | Out-Null
    Invoke-Tick | Out-Null
    Invoke-Tick | Out-Null
    Assert-True ((Get-DmCount 'interactive') -eq 2) 'once the cursor passes the event behind the last DM, the next wait gets one more DM'
    Assert-True ((Get-LaunchCount 'interactive') -eq 0 -and @(Get-LaunchRecords $run.folder).Count -eq 0) 'an interactive coordinator is never replaced'

    # ---- a managed coordinator that consumes per the adapter is not relaunched; one that does not, is.
    Use-Scenario 'consume-adapter'
    $consumer = New-Run -Name 'consume-adapter'
    $control = New-Run -Name 'consume-control'
    foreach ($r in @($consumer, $control)) {
        $j = Invoke-DtJob @('start', '-RunFolder', $r.folder, '-Command', 'Write-Output done')
        $r | Add-Member -NotePropertyName job_id -NotePropertyValue $j.job_id
        $r | Add-Member -NotePropertyName waited -NotePropertyValue (Invoke-DtJob @('wait', '-RunFolder', $r.folder, '-JobId', $j.job_id, '-All', '-TimeoutSec', '60'))
    }
    $waited = $consumer.waited
    $fileSeq = (Get-Content -LiteralPath (Join-Path $consumer.folder 'jobs/events.jsonl') | Select-Object -Last 1 | ConvertFrom-Json).seq
    Assert-True ($waited.result -eq 'finished' -and $waited.last_event_seq -eq $fileSeq -and $fileSeq -gt 0 -and $waited.last_consumed_event_seq -eq 0) "the wait envelope carries last_event_seq ($($waited.last_event_seq) of $fileSeq) and last_consumed_event_seq"
    $jobStatus = Invoke-DtJob @('status', '-RunFolder', $consumer.folder, '-JobId', $consumer.job_id)
    $runStatus = Invoke-DtJob @('status', '-RunFolder', $consumer.folder)
    Assert-True ($jobStatus.last_event_seq -eq $fileSeq -and $jobStatus.last_consumed_event_seq -eq 0 -and $runStatus.last_event_seq -eq $fileSeq -and $runStatus.last_consumed_event_seq -eq 0) 'job and run status envelopes carry both values'
    $unregistered = Join-Path $tempRoot 'runs/consume-unregistered'
    New-Item -ItemType Directory -Path $unregistered -Force | Out-Null
    $bare = Invoke-DtJob @('status', '-RunFolder', $unregistered)
    Assert-True ($bare.PSObject.Properties['last_event_seq'] -and $bare.last_event_seq -eq 0 -and $bare.PSObject.Properties['last_consumed_event_seq'] -and $null -eq $bare.last_consumed_event_seq) 'an unregistered run reports last_event_seq 0 and a null consumed cursor'
    # Per the adapter: handle the events, then consume up to the envelope's last_event_seq.
    $after = Invoke-DtJob @('consume', '-RunFolder', $consumer.folder, '-Seq', [string]$waited.last_event_seq)
    Assert-True ($after.last_consumed_event_seq -eq $fileSeq -and (Get-RunState $consumer.state).cursor -eq $fileSeq) 'consume moves the cursor to the envelope seq'
    Invoke-Tick | Out-Null
    Assert-True ((Get-LaunchCount 'consume-adapter') -eq 0 -and @(Get-LaunchRecords $consumer.folder).Count -eq 0) 'a managed run whose coordinator consumed per the adapter is not relaunched on the next tick'
    Assert-True ((Get-LaunchCount 'consume-control') -eq 1) 'the same run without the consume is relaunched on that tick'
    # A job-scoped envelope never covers another job's unconsumed event, so consuming it leaves that event pending.
    Use-Scenario 'consume-scoped'
    $scoped = New-Run -Name 'consume-scoped'
    $other = Invoke-DtJob @('start', '-RunFolder', $scoped.folder, '-Command', 'Write-Output a')
    $mine = Invoke-DtJob @('start', '-RunFolder', $scoped.folder, '-Command', 'Write-Output b')
    Invoke-DtJob @('wait', '-RunFolder', $scoped.folder, '-JobId', "$($other.job_id),$($mine.job_id)", '-All', '-TimeoutSec', '60') | Out-Null
    $scopedWait = Invoke-DtJob @('wait', '-RunFolder', $scoped.folder, '-JobId', $mine.job_id, '-All', '-TimeoutSec', '60')
    $scopedStatus = Invoke-DtJob @('status', '-RunFolder', $scoped.folder, '-JobId', $mine.job_id)
    $runWide = Invoke-DtJob @('status', '-RunFolder', $scoped.folder)
    $firstOther = (Get-Content -LiteralPath (Join-Path $scoped.folder 'jobs/events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.job_id -eq $other.job_id } | Select-Object -First 1).seq
    Assert-True ($scopedWait.last_event_seq -eq ($firstOther - 1) -and $scopedStatus.last_event_seq -eq ($firstOther - 1) -and $runWide.last_event_seq -gt $scopedWait.last_event_seq) "a job-scoped wait and status stop before another job's first unconsumed event ($($scopedWait.last_event_seq), $($scopedStatus.last_event_seq) vs run $($runWide.last_event_seq))"
    Invoke-DtJob @('consume', '-RunFolder', $scoped.folder, '-Seq', [string]$scopedWait.last_event_seq) | Out-Null
    Invoke-Tick | Out-Null
    Assert-True ((Get-LaunchCount 'consume-scoped') -eq 1) "consuming a job-scoped seq leaves the other job's completion pending, so the next tick relaunches"

    # ---- scenario 10a: consumed event and finished run produce nothing across ticks.
    Use-Scenario 'quiet'
    $consumed = New-Run -Name 'consumed'
    Invoke-DtJob @('request-continuation', '-RunFolder', $consumed.folder) | Out-Null
    Invoke-DtJob @('consume', '-RunFolder', $consumed.folder, '-Seq', '1') | Out-Null
    $finished = New-Run -Name 'finished'
    Invoke-DtJob @('request-continuation', '-RunFolder', $finished.folder) | Out-Null
    $fin = Invoke-DtJob @('finish', '-RunFolder', $finished.folder)
    Assert-True ($fin.run_status -eq 'finished' -and $fin.unregistered -eq 1 -and (Get-RunState $finished.state).run_status -eq 'finished') 'finish sets finished and unregisters'
    $statusFinished = New-Run -Name 'finished-registered'
    Invoke-DtJob @('request-continuation', '-RunFolder', $statusFinished.folder) | Out-Null
    Invoke-DtJob @('finish', '-RunFolder', $statusFinished.folder) | Out-Null
    Invoke-DtJob @('register-run', '-RunFolder', $statusFinished.folder, '-BuildStatePath', $statusFinished.state, '-RunId', 'finished-registered', '-PinnedHost', 'claude', '-Managed') | Out-Null
    $tq = [DateTime]::UtcNow
    foreach ($offset in @(0, 3, 15, 45)) { Invoke-Tick -NowUtc $tq.AddMinutes($offset) | Out-Null }
    Assert-True ((Get-LaunchCount 'consumed') -eq 0 -and (Get-LaunchCount 'finished') -eq 0 -and (Get-LaunchCount 'finished-registered') -eq 0) 'consumed and finished runs never launch'
    Assert-True ((Get-DmCount 'consumed') -eq 0 -and (Get-DmCount 'finished') -eq 0 -and (Get-DmCount 'finished-registered') -eq 0) 'consumed and finished runs never DM'

    # ---- scenario 10b: approval wait; approve for another operation does not release; approve launches once.
    Use-Scenario 'approval'
    $run = New-Run -Name 'approval'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    Invoke-DtJob @('consume', '-RunFolder', $run.folder, '-Seq', '1') | Out-Null
    $await = Invoke-DtJob @('await-danny', '-RunFolder', $run.folder, '-Operation', 'merge', '-Message', 'Milestone M02 is ready to merge.')
    Assert-True ($await.run_status -eq 'awaiting_danny' -and $await.alert -eq 'sent' -and (Get-DmCount 'approval') -eq 1) 'await-danny sets awaiting_danny and sends one DM'
    $dm = Get-Content -LiteralPath $env:DT_TEST_DM_LOG | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { ([string]$_.content).Contains('run approval ') } | Select-Object -First 1
    Assert-True (([string]$dm.content).Contains('/dt-build approve approval merge')) 'the approval DM ends with the copy-paste approve command'
    $repeat = Invoke-DtJob @('await-danny', '-RunFolder', $run.folder, '-Operation', 'merge', '-Message', 'Milestone M02 is ready to merge.')
    Assert-True ($repeat.alert -eq 'already_sent' -and (Get-DmCount 'approval') -eq 1) 'a repeated await for the same operation sends no second DM'
    $ta = [DateTime]::UtcNow
    foreach ($offset in @(0, 3, 15, 45)) { Invoke-Tick -NowUtc $ta.AddMinutes($offset) | Out-Null }
    Assert-True ((Get-LaunchCount 'approval') -eq 0 -and (Get-DmCount 'approval') -eq 1) 'awaiting_danny produces no launches or DMs across ticks'
    $wrong = Invoke-DtJobExpectFail @('approve', '-RunFolder', $run.folder, '-Operation', 'push')
    $approvals = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'approvals.json') | ConvertFrom-Json
    Assert-True ($wrong.exit -ne 0 -and $wrong.text -match 'DT_JOB_APPROVE_MISMATCH' -and (Get-RunState $run.state).run_status -eq 'awaiting_danny' -and @($approvals.approvals).Count -eq 0) 'approve for a different operation does not release or record'
    $resumeBlocked = Invoke-DtJobExpectFail @('resume', '-RunFolder', $run.folder)
    Assert-True ($resumeBlocked.exit -ne 0 -and $resumeBlocked.text -match 'DT_JOB_RESUME_AWAITING_APPROVAL') 'resume cannot bypass a pending approval'
    Invoke-Tick -NowUtc $ta.AddMinutes(50) | Out-Null
    Assert-True ((Get-LaunchCount 'approval') -eq 0) 'still no launch after the wrong approval'
    $ok = Invoke-DtJob @('approve', '-RunFolder', $run.folder, '-Operation', 'merge')
    $approvals = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'approvals.json') | ConvertFrom-Json
    Assert-True ($ok.run_status -eq 'runnable' -and @($approvals.approvals).Count -eq 1 -and $approvals.approvals[0].operation -eq 'merge' -and [bool]$approvals.approvals[0].approved_utc -and $null -eq $approvals.awaiting) 'approve records {operation, approved_utc} and sets runnable'
    $lastEvent = Get-Content -LiteralPath (Join-Path $run.folder 'jobs/events.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ($lastEvent.type -eq 'continuation_requested') 'approve appends continuation_requested'
    $tb = $ta.AddMinutes(60)
    Invoke-Tick -NowUtc $tb | Out-Null
    Invoke-Tick -NowUtc $tb.AddSeconds(30) | Out-Null
    Assert-True ((Get-LaunchCount 'approval') -eq 1) 'approve produces exactly one new launch'

    # ---- scenario 10c: failed launches honor 2/10/30, stop with one DM, and resume re-arms once.
    Use-Scenario 'retry'
    $run = New-Run -Name 'retry'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $t0 = [DateTime]::UtcNow
    $schedule = @(
        @(0, 1), @(60, 1), @(90, 1), @(119, 1), @(121, 2),
        @(300, 2), @(720, 2), @(722, 3),
        @(1800, 3), @(2521, 3), @(2523, 4)
    )
    foreach ($step in $schedule) {
        Invoke-Tick -NowUtc $t0.AddSeconds($step[0]) | Out-Null
        Assert-True ((Get-LaunchCount 'retry') -eq $step[1]) "at +$($step[0]) s expected $($step[1]) launches, got $(Get-LaunchCount 'retry')"
    }
    $attempts = @(Get-LaunchRecords $run.folder | Where-Object { $_.type -eq 'launch' })
    Assert-True (($attempts | ForEach-Object { $_.attempt }) -join ',' -eq '1,2,3,4' -and @($attempts | Select-Object -ExpandProperty trigger_seq -Unique).Count -eq 1) 'attempts are numbered per trigger seq'
    Assert-True ((Get-RunState $run.state).run_status -eq 'runnable' -and (Get-DmCount 'retry') -eq 0) 'no stop before the last retry has failed'
    Invoke-Tick -NowUtc $t0.AddSeconds(2600) | Out-Null
    Assert-True ((Get-RunState $run.state).run_status -eq 'awaiting_danny' -and (Get-DmCount 'retry') -eq 1 -and (Get-LaunchCount 'retry') -eq 4) 'after the last failed retry the run stops with one DM'
    $stopDm = Get-Content -LiteralPath $env:DT_TEST_DM_LOG | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { ([string]$_.content).Contains('run retry ') } | Select-Object -First 1
    Assert-True (([string]$stopDm.content).Contains('/dt-build resume retry')) 'the stop DM names resume'
    foreach ($offset in @(2700, 4000, 9000)) { Invoke-Tick -NowUtc $t0.AddSeconds($offset) | Out-Null }
    Assert-True ((Get-LaunchCount 'retry') -eq 4 -and (Get-DmCount 'retry') -eq 1) 'a stopped run stays quiet across ticks'
    Invoke-DtJob @('resume', '-RunFolder', $run.folder) | Out-Null
    Assert-True ((Get-RunState $run.state).run_status -eq 'runnable') 'resume sets runnable'
    Invoke-Tick -NowUtc $t0.AddSeconds(9100) | Out-Null
    Invoke-Tick -NowUtc $t0.AddSeconds(9110) | Out-Null
    Assert-True ((Get-LaunchCount 'retry') -eq 5) 'resume produces exactly one new launch'

    # ---- quota: pinned vendor blocked launches the other host; both blocked launches nothing.
    Use-Scenario 'quota'
    $run = New-Run -Name 'quota-one' -PinnedHost 'claude'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $env:DT_TEST_BLOCKED = 'claude'
    Invoke-Tick | Out-Null
    $launch = @(Get-Launches 'quota-one')
    $recorded = @(Get-LaunchRecords $run.folder | Where-Object { $_.type -eq 'launch' })
    Assert-True ($launch.Count -eq 1 -and $launch[0].host -eq 'codex' -and $recorded[0].host -eq 'codex') 'a blocked pinned vendor relaunches on the other host'
    Use-Scenario 'quota-both'
    $run = New-Run -Name 'quota-both' -PinnedHost 'claude'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $env:DT_TEST_BLOCKED = 'claude,codex'
    $claudeReset = [DateTime]::UtcNow.AddHours(3)
    $codexReset = [DateTime]::UtcNow.AddHours(1)
    $env:DT_TEST_RESET_CLAUDE = $claudeReset.ToString('o')
    $env:DT_TEST_RESET_CODEX = $codexReset.ToString('o')
    Invoke-Tick | Out-Null
    Invoke-Tick | Out-Null
    $deferred = @(Get-LaunchRecords $run.folder | Where-Object { $_.type -eq 'deferred' })
    Assert-True ((Get-LaunchCount 'quota-both') -eq 0 -and @(Get-LaunchRecords $run.folder | Where-Object { $_.type -eq 'launch' }).Count -eq 0) 'both vendors blocked launches nothing'
    Assert-True ($deferred.Count -eq 1 -and ([DateTime]$deferred[0].resume_after_utc).ToUniversalTime().Ticks -eq $codexReset.Ticks) 'resume_after_utc is the earlier reset, recorded once'
    $env:DT_TEST_BLOCKED = ''

    # ---- both vendors blocked with a stale or missing reset: one deferred row per change, not per tick.
    Use-Scenario 'quota-stale'
    $run = New-Run -Name 'quota-stale' -PinnedHost 'claude'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $env:DT_TEST_BLOCKED = 'claude,codex'
    $env:DT_TEST_RESET_CLAUDE = [DateTime]::UtcNow.AddHours(-2).ToString('o')
    $env:DT_TEST_RESET_CODEX = [DateTime]::UtcNow.AddHours(-1).ToString('o')
    $ts = [DateTime]::UtcNow
    foreach ($offset in @(0, 2, 4)) { Invoke-Tick -NowUtc $ts.AddMinutes($offset) | Out-Null }
    Assert-True (@(Get-LaunchRecords $run.folder | Where-Object { $_.type -eq 'deferred' }).Count -eq 1) 'a past reset still reported blocked records one deferred row across ticks'
    $env:DT_TEST_RESET_CLAUDE = ''
    $env:DT_TEST_RESET_CODEX = ''
    foreach ($offset in @(6, 8, 10)) { Invoke-Tick -NowUtc $ts.AddMinutes($offset) | Out-Null }
    $deferred = @(Get-LaunchRecords $run.folder | Where-Object { $_.type -eq 'deferred' })
    Assert-True ($deferred.Count -eq 2 -and $null -eq $deferred[1].resume_after_utc) 'a changed resume time records exactly one new row; unchanged ticks add none'
    Assert-True ((Get-LaunchCount 'quota-stale') -eq 0) 'nothing launches while both vendors stay blocked'
    $env:DT_TEST_BLOCKED = ''

    # ---- a crash right after launch is retried at 2 minutes, without waiting out the 600 s lease.
    Use-Scenario 'crash'
    $run = New-Run -Name 'crash'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $tc = [DateTime]::UtcNow
    Invoke-Tick -NowUtc $tc | Out-Null
    $crashLease = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'coordinator.lease') | ConvertFrom-Json
    Assert-True ($crashLease.launched_by -eq 'watcher' -and [bool]$crashLease.pid_start_utc -and ([DateTime]$crashLease.expires_utc).ToUniversalTime() -gt $tc.AddMinutes(5)) 'the launch holds a long lease with the child pid and start time'
    Invoke-Tick -NowUtc $tc.AddSeconds(119) | Out-Null
    Assert-True ((Get-LaunchCount 'crash') -eq 1) 'no retry before 2 minutes'
    Invoke-Tick -NowUtc $tc.AddSeconds(121) | Out-Null
    Assert-True ((Get-LaunchCount 'crash') -eq 2) 'a provably dead coordinator is retried at 2 minutes while its lease is unexpired'

    # ---- a registered managed run with no lease file has no coordinator and launches.
    Use-Scenario 'no-lease'
    $run = New-Run -Name 'no-lease' -NoLease
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    Invoke-Tick | Out-Null
    Assert-True ((Get-LaunchCount 'no-lease') -eq 1) 'a managed run with an unconsumed event and no lease launches'
    $quietRun = New-Run -Name 'no-lease-quiet' -NoLease
    Invoke-Tick | Out-Null
    Assert-True ((Get-LaunchCount 'no-lease-quiet') -eq 0) 'a run with no lease and no unconsumed event launches nothing'

    # ---- a corrupt irreversible.json or context-baseline.json fails only its own step; the run's tick still runs.
    Use-Scenario 'corrupt-steps'
    $run = New-Run -Name 'corrupt-ir' -NoLease
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    Write-Utf8 -Path (Join-Path $run.folder 'irreversible.json') -Content '{ not json'
    $tick = @(Invoke-Tick | Where-Object { $_.run_id -eq 'corrupt-ir' })[0]
    Assert-True ((Get-LaunchCount 'corrupt-ir') -eq 1 -and $tick.action -eq 'launch' -and @($tick.step_errors | Where-Object { $_ -match '^stale irreversible check failed' }).Count -eq 1) "a corrupt irreversible.json still lets the tick launch, and reports the error ($($tick | ConvertTo-Json -Compress))"
    $live = Start-Process -FilePath 'ping.exe' -ArgumentList '-n', '60', '127.0.0.1' -WindowStyle Hidden -PassThru
    try {
        $run = New-Run -Name 'corrupt-baseline' -PinnedHost 'codex' -NoLease
        $liveStart = (Get-Process -Id $live.Id).StartTime.ToUniversalTime().ToString('o')
        $lease = [ordered]@{ coordinator_id = 'mc-live'; host = 'codex'; session_id = $null; pid = $live.Id; pid_start_utc = $liveStart; launched_by = 'watcher'; ttl_sec = 600; acquired_utc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o'); expires_utc = [DateTime]::UtcNow.AddMinutes(9).ToString('o'); released_utc = $null }
        Write-Utf8 -Path (Join-Path $run.folder 'coordinator.lease') -Content ($lease | ConvertTo-Json)
        Write-Utf8 -Path (Join-Path $run.folder 'context-baseline.json') -Content '{ broken'
        $tick = @(Invoke-Tick | Where-Object { $_.run_id -eq 'corrupt-baseline' })[0]
        Assert-True ($tick.action -ne 'error' -and @($tick.step_errors | Where-Object { $_ -match '^context rotation failed' }).Count -eq 1 -and (Get-LaunchCount 'corrupt-baseline') -eq 0 -and -not $live.HasExited) "a corrupt context-baseline.json fails only the rotation step; the tick still decides ($($tick | ConvertTo-Json -Compress))"
    }
    finally { if (-not $live.HasExited) { $live.Kill() } }

    # ---- the same step error on 3 consecutive ticks sends one DM; other runs still tick and the watcher exits 0.
    Use-Scenario 'step-repeat'
    $okRun = New-Run -Name 'step-ok' -NoLease
    Invoke-DtJob @('request-continuation', '-RunFolder', $okRun.folder) | Out-Null
    $live = Start-Process -FilePath 'ping.exe' -ArgumentList '-n', '90', '127.0.0.1' -WindowStyle Hidden -PassThru
    try {
        $run = New-Run -Name 'step-err' -PinnedHost 'codex' -NoLease
        $liveStart = (Get-Process -Id $live.Id).StartTime.ToUniversalTime().ToString('o')
        $lease = [ordered]@{ coordinator_id = 'mc-live'; host = 'codex'; session_id = $null; pid = $live.Id; pid_start_utc = $liveStart; launched_by = 'watcher'; ttl_sec = 600; acquired_utc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o'); expires_utc = [DateTime]::UtcNow.AddMinutes(9).ToString('o'); released_utc = $null }
        Write-Utf8 -Path (Join-Path $run.folder 'coordinator.lease') -Content ($lease | ConvertTo-Json)
        Write-Utf8 -Path (Join-Path $run.folder 'context-baseline.json') -Content '{ broken'
        $ticks = @()
        foreach ($n in 1..4) { $ticks += , @(Invoke-Tick) }
        $errTicks = @($ticks | ForEach-Object { @($_ | Where-Object { $_.run_id -eq 'step-err' })[0] })
        $stepDms = @(Get-Content -LiteralPath $env:DT_TEST_DM_LOG | Where-Object { $_ -match 'run step-err ' -and $_ -match 'same watcher error on 3 ticks in a row' -and $_ -match 'context rotation failed' })
        Assert-True (-not $errTicks[0].PSObject.Properties['step_error_alerts'] -and -not $errTicks[1].PSObject.Properties['step_error_alerts'] -and @($errTicks[2].step_error_alerts)[0].alert -eq 'sent' -and @($errTicks[3].step_error_alerts)[0].alert -eq 'already_sent') "the repeated step error alerts on the third tick only ($($errTicks | ConvertTo-Json -Compress -Depth 5))"
        Assert-True ($stepDms.Count -eq 1 -and (Get-DmCount 'step-err') -eq 1) "a step error repeated on 4 ticks sends exactly one DM ($($stepDms.Count))"
        $okTicks = @($ticks | ForEach-Object { @($_ | Where-Object { $_.run_id -eq 'step-ok' })[0] })
        Assert-True ($okTicks[0].action -eq 'launch' -and (Get-LaunchCount 'step-ok') -ge 1 -and -not $okTicks[0].PSObject.Properties['step_errors'] -and (Get-DmCount 'step-ok') -eq 0) 'another run in the same tick still launches, with no step error or DM'
        $counts = (Get-Content -Raw -LiteralPath (Join-Path $run.folder 'step-errors.json') | ConvertFrom-Json).errors
        Assert-True (@($counts).Count -eq 1 -and [int]@($counts)[0].count -eq 4) 'step-errors.json counts consecutive ticks per error'
        Write-Utf8 -Path (Join-Path $run.folder 'context-baseline.json') -Content '{ "coordinators": {} }'
        Invoke-Tick | Out-Null
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $run.folder 'step-errors.json'))) 'a tick with no step error clears the consecutive count'
        Write-Utf8 -Path (Join-Path $run.folder 'context-baseline.json') -Content '{ broken'
        $again = @(foreach ($n in 1..3) { @(Invoke-Tick | Where-Object { $_.run_id -eq 'step-err' })[0] })
        Assert-True (-not $again[1].PSObject.Properties['step_error_alerts'] -and @($again[2].step_error_alerts)[0].alert -eq 'already_sent' -and (Get-DmCount 'step-err') -eq 1) 'an interrupted streak starts over, and the same error on the same run is never sent twice'
    }
    finally { if (-not $live.HasExited) { $live.Kill() } }

    # ---- a rotation kill that leaves the codex child alive holds the run until every survivor is gone.
    Use-Scenario 'kill-episode'
    $killLog = Join-Path $tempRoot 'kill-calls.txt'
    $env:DT_TEST_KILL_LOG = $killLog
    $rootOnlyStub = 'function Stop-WatcherProcessTree { param([int]$ProcessId) [System.IO.File]::AppendAllText($env:DT_TEST_KILL_LOG, "$ProcessId`n"); if ($ProcessId -eq [int]$env:DT_TEST_KILLABLE) { Stop-Process -Id $ProcessId -Force; Start-Sleep -Milliseconds 500 } }'
    $ep = Start-RotationFixture -Name 'kill-episode'
    $env:DT_TEST_KILLABLE = [string]$ep.child
    $killFailedPath = Join-Path $ep.folder 'kill-failed.json'
    $first = Invoke-StubbedRun -RunFolder $ep.folder -Stubs $rootOnlyStub
    Assert-True (-not (Test-Alive $ep.child) -and (Test-Alive $ep.grandchild) -and [string]$first.rotation -match "^rotation kill failed: $($ep.coordinator_id) pid [0-9, ]*(?<![0-9])$($ep.grandchild)(?![0-9])[0-9, ]* still running" -and [string]$first.rotation -notmatch "(?<![0-9])$($ep.child)(?![0-9])" -and $first.action -eq 'none' -and (Get-LaunchCount 'kill-episode') -eq 0) "root dead, child alive: the tick that opens the episode launches nothing ($($first | ConvertTo-Json -Compress -Depth 5))"
    $episode = Get-Content -Raw -LiteralPath $killFailedPath | ConvertFrom-Json
    $grandStart = (Get-Process -Id $ep.grandchild).StartTime.ToUniversalTime()
    $grandRow = @(@($episode.survivors) | Where-Object { [int]$_.pid -eq $ep.grandchild })
    Assert-True ($episode.coordinator_id -eq $ep.coordinator_id -and $episode.first_seen_utc -and $grandRow.Count -eq 1 -and (ConvertTo-TestUtc $grandRow[0].start_utc).Ticks -eq $grandStart.Ticks -and @(@($episode.survivors) | Where-Object { [int]$_.pid -eq $ep.child }).Count -eq 0) "kill-failed.json lists the survivor pid with its start time, the coordinator, and first_seen_utc ($($episode | ConvertTo-Json -Compress -Depth 5))"
    Remove-Item -LiteralPath $killLog -Force -ErrorAction SilentlyContinue
    $later = @(foreach ($n in 1..2) { Invoke-StubbedRun -RunFolder $ep.folder -Stubs $rootOnlyStub })
    $retried = @(Get-Content -LiteralPath $killLog | Where-Object { $_ } | ForEach-Object { [int]$_ })
    Assert-True (@($later | Where-Object { $_.action -ne 'none' -or [string]$_.rotation -notmatch 'rotation kill failed' }).Count -eq 0 -and (Get-LaunchCount 'kill-episode') -eq 0 -and (Test-Path -LiteralPath $killFailedPath)) "while the survivor lives, later ticks launch nothing ($($later | ConvertTo-Json -Compress -Depth 5))"
    Assert-True (@($retried | Where-Object { $_ -eq $ep.grandchild }).Count -eq 2 -and @($retried | Where-Object { $_ -eq $ep.child }).Count -eq 0) "each later tick retries the survivor's tree kill, never the dead root ($($retried -join ','))"
    Assert-True ((Get-DmCount 'kill-episode') -eq 1 -and [string]$later[-1].rotation -match 'alert already_sent') 'one DM for the whole kill-failed episode'
    $leaseMid = Get-Content -Raw -LiteralPath (Join-Path $ep.folder 'coordinator.lease') | ConvertFrom-Json
    Assert-True (-not $leaseMid.released_utc -and @(Get-Content -LiteralPath (Join-Path $ep.folder 'jobs/events.jsonl') | Where-Object { $_ -match 'context_rotation' }).Count -eq 0) 'the lease stays held and no continuation is requested while the survivor lives'
    Stop-Process -Id $ep.grandchild -Force
    Start-Sleep -Milliseconds 500
    $resolved = Invoke-StubbedRun -RunFolder $ep.folder -Stubs $rootOnlyStub
    $leaseAfter = Get-Content -Raw -LiteralPath (Join-Path $ep.folder 'coordinator.lease') | ConvertFrom-Json
    Assert-True ([string]$resolved.rotation -match '^rotation kill confirmed' -and -not (Test-Path -LiteralPath $killFailedPath) -and $resolved.action -eq 'launch' -and (Get-LaunchCount 'kill-episode') -eq 1) "once the survivor is gone the file is removed and exactly one coordinator launches ($($resolved | ConvertTo-Json -Compress -Depth 5))"
    Assert-True (@(Get-Content -LiteralPath (Join-Path $ep.folder 'jobs/events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -eq 'continuation_requested' -and $_.reason -eq 'context_rotation' }).Count -eq 1 -and $leaseAfter.coordinator_id -ne $ep.coordinator_id) 'the old lease was released and one continuation_requested appended before the relaunch'
    Invoke-StubbedRun -RunFolder $ep.folder -Stubs $rootOnlyStub | Out-Null
    Invoke-Tick | Out-Null
    Assert-True ((Get-LaunchCount 'kill-episode') -eq 1 -and (Get-DmCount 'kill-episode') -eq 1) 'later ticks start no second coordinator and send no second DM'

    # ---- a failed descendant snapshot still kills the root tree but holds the run as an unconfirmed kill.
    Use-Scenario 'snapshot-fail'
    $sf = Start-RotationFixture -Name 'snapshot-fail'
    $snapshotStub = 'function Get-WatcherDescendantProcesses { param([int]$ProcessId) throw "CIM unavailable" }'
    $sfFirst = Invoke-StubbedRun -RunFolder $sf.folder -Stubs $snapshotStub
    Start-Sleep -Milliseconds 500
    $sfEpisode = Get-Content -Raw -LiteralPath (Join-Path $sf.folder 'kill-failed.json') | ConvertFrom-Json
    Assert-True (-not (Test-Alive $sf.child) -and -not (Test-Alive $sf.grandchild)) 'with no descendant snapshot the root tree is still killed'
    Assert-True ($sfFirst.action -eq 'none' -and (Get-LaunchCount 'snapshot-fail') -eq 0 -and [string]$sfFirst.rotation -match "^rotation kill failed: $($sf.coordinator_id) pid $($sf.child) " -and [string]$sfFirst.rotation -match 'descendant snapshot failed: CIM unavailable' -and @($sfEpisode.survivors).Count -eq 1 -and [int]@($sfEpisode.survivors)[0].pid -eq $sf.child) "an unconfirmed kill opens a kill-failed episode listing the root pid ($($sfFirst | ConvertTo-Json -Compress -Depth 5))"
    Assert-True ((Get-DmCount 'snapshot-fail') -eq 1) 'an unconfirmed kill sends one DM'
    $sfNext = Invoke-StubbedRun -RunFolder $sf.folder -Stubs $snapshotStub
    Assert-True ([string]$sfNext.rotation -match '^rotation kill confirmed' -and $sfNext.action -eq 'launch' -and (Get-LaunchCount 'snapshot-fail') -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $sf.folder 'kill-failed.json'))) "the next tick finds the root gone and hands the run to exactly one new coordinator ($($sfNext | ConvertTo-Json -Compress -Depth 5))"

    # ---- a descendant missed by the first snapshot that survives the kill is found by the second and holds the run.
    Use-Scenario 'late-descendant'
    $ld = Start-RotationFixture -Name 'late-descendant'
    $env:DT_TEST_KILLABLE = [string]$ld.child
    $lateStub = $rootOnlyStub + '; $script:snapshotCalls = 0; $script:realDescendants = ${function:Get-WatcherDescendantProcesses}; function Get-WatcherDescendantProcesses { param([int]$ProcessId, $StartUtc) if (-not $script:snapshotCalls) { $script:snapshotCalls = 1; return @() } & $script:realDescendants @PSBoundParameters }'
    $ldFirst = Invoke-StubbedRun -RunFolder $ld.folder -Stubs $lateStub
    $ldEpisodePath = Join-Path $ld.folder 'kill-failed.json'
    $ldEpisode = if (Test-Path -LiteralPath $ldEpisodePath) { Get-Content -Raw -LiteralPath $ldEpisodePath | ConvertFrom-Json } else { $null }
    Assert-True (-not (Test-Alive $ld.child) -and (Test-Alive $ld.grandchild) -and $null -ne $ldEpisode -and @(@($ldEpisode.survivors) | Where-Object { [int]$_.pid -eq $ld.grandchild }).Count -eq 1 -and $ldFirst.action -eq 'none' -and (Get-LaunchCount 'late-descendant') -eq 0) "a survivor missing from the first snapshot is added to the episode by the snapshot after the kill ($($ldFirst | ConvertTo-Json -Compress -Depth 5))"
    Stop-Process -Id $ld.grandchild -Force -ErrorAction SilentlyContinue

    # ---- a corrupt kill-failed.json: the repeated-error DM names the file and says relaunch is held.
    Use-Scenario 'kill-failed-corrupt'
    $kc = New-Run -Name 'kf-corrupt' -PinnedHost 'codex' -NoLease
    Invoke-DtJob @('request-continuation', '-RunFolder', $kc.folder) | Out-Null
    $kcPath = Join-Path $kc.folder 'kill-failed.json'
    Write-Utf8 -Path $kcPath -Content '{ broken'
    $kcTicks = @(foreach ($n in 1..3) { @(Invoke-Tick | Where-Object { $_.run_id -eq 'kf-corrupt' })[0] })
    $kcDms = @(Get-Content -LiteralPath $env:DT_TEST_DM_LOG | ForEach-Object { [string]($_ | ConvertFrom-Json).content } | Where-Object { $_.Contains('run kf-corrupt ') })
    Assert-True (@($kcTicks[0].step_errors | Where-Object { $_.Contains("kill-failed.json ($kcPath)") }).Count -eq 1 -and (Get-LaunchCount 'kf-corrupt') -eq 0) "a corrupt kill-failed.json is reported as that file's step error and launches nothing ($($kcTicks[0] | ConvertTo-Json -Compress -Depth 5))"
    Assert-True ($kcDms.Count -eq 1 -and $kcDms[0].Contains($kcPath) -and $kcDms[0].Contains('Relaunch is held for this run while kill-failed.json exists') -and -not $kcDms[0].Contains('relaunch and stop checks still run')) "the repeated-error DM names kill-failed.json and says relaunch is held ($($kcDms -join ' | '))"

    # ---- ending a kill-failed episode is idempotent: a failed removal or a repeated completion appends nothing.
    Use-Scenario 'complete-idempotent'
    $ci = New-Run -Name 'complete-idem' -PinnedHost 'codex'
    $ciPath = Join-Path $ci.folder 'kill-failed.json'
    Write-Utf8 -Path $ciPath -Content '{ "coordinator_id": "old-coordinator", "survivors": [] }'
    $ciEvents = Join-Path $ci.folder 'jobs/events.jsonl'
    $countRotations = { if (Test-Path -LiteralPath $ciEvents) { @(Get-Content -LiteralPath $ciEvents | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -eq 'continuation_requested' -and $_.reason -eq 'context_rotation' }).Count } else { 0 } }
    $complete = ". '$watcher'; try { Complete-WatcherRotation -Entry (Get-DtJobRegistryEntry -RunFolder '$($ci.folder)') -CoordinatorId 'old-coordinator' -NowUtc ([DateTime]::UtcNow) -KillFailedPath '$ciPath'; 'ok' } catch { 'threw' }"
    $held = [System.IO.File]::Open($ciPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try { $blocked = @(& pwsh -NoProfile -Command $complete)[-1] }
    finally { $held.Dispose() }
    $ciLease = Get-Content -Raw -LiteralPath (Join-Path $ci.folder 'coordinator.lease') | ConvertFrom-Json
    Assert-True ($blocked -eq 'threw' -and (& $countRotations) -eq 0 -and (Test-Path -LiteralPath $ciPath) -and -not $ciLease.released_utc) "a kill-failed.json that cannot be removed leaves the lease held and appends nothing ($blocked)"
    $done = @(foreach ($n in 1..2) { @(& pwsh -NoProfile -Command $complete)[-1] })
    $ciLease = Get-Content -Raw -LiteralPath (Join-Path $ci.folder 'coordinator.lease') | ConvertFrom-Json
    Assert-True (($done -join ',') -eq 'ok,ok' -and (& $countRotations) -eq 1 -and -not (Test-Path -LiteralPath $ciPath) -and $ciLease.released_utc) "the first completion removes the file, releases the lease, and appends one continuation; a repeat appends nothing ($($done -join ','), $(& $countRotations))"

    # ---- a live watcher-launched pid is not replaced, even with its lease expired.
    Use-Scenario 'live-pid'
    $run = New-Run -Name 'live-pid'
    $selfStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    Write-Lease -RunFolder $run.folder -LaunchedBy 'watcher' -LeasePid $PID -PidStartUtc $selfStart -CoordinatorId 'mc-live'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $live = @(Invoke-Tick)
    Assert-True ((Get-LaunchCount 'live-pid') -eq 0 -and $live[0].detail -eq 'coordinator process alive') 'a live watcher-launched coordinator is never replaced'
    $refused = Invoke-DtJobExpectFail @('lease', '-RunFolder', $run.folder, '-Action', 'acquire', '-CoordinatorId', 'danny-session', '-LaunchedBy', 'interactive')
    Assert-True ($refused.exit -ne 0 -and $refused.text -match 'DT_JOB_LEASE_HELD' -and $refused.text -match 'still running') 'acquire is refused while a live watcher-launched pid holds an expired lease'

    # ---- coordinator.lock busy skips the tick.
    Use-Scenario 'busy'
    $run = New-Run -Name 'busy'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $held = [System.IO.File]::Open((Join-Path $run.folder 'coordinator.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try { $busy = @(Invoke-Tick) }
    finally { $held.Dispose() }
    Assert-True ($busy[0].detail -eq 'coordinator lock busy' -and (Get-LaunchCount 'busy') -eq 0 -and @(Get-LaunchRecords $run.folder).Count -eq 0) 'a busy coordinator lock skips the tick'
    Invoke-Tick | Out-Null
    Assert-True ((Get-LaunchCount 'busy') -eq 1) 'the next tick launches once the lock is free'

    # ---- state changed between the unlocked decision and the locked recheck aborts the launch.
    Use-Scenario 'changed'
    $run = New-Run -Name 'changed'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $probe = Join-Path $tempRoot 'changed-under-lock.ps1'
    Write-Utf8 -Path $probe -Content @'
param([string]$WatcherScript)
. $WatcherScript
$entry = @(Get-DtJobRegistryRuns)[0]
$script:decisionCalls = 0
$original = ${function:Get-WatcherDecision}
function Get-WatcherDecision {
    param($Entry, $NowUtc)
    $script:decisionCalls++
    # Between the unlocked decision and the recheck, a coordinator consumes the trigger.
    if ($script:decisionCalls -eq 2) {
        Invoke-DtJobLocked -RunFolder $Entry.run_folder -Action { Set-DtJobRunState -BuildStatePath $Entry.build_state_path -Cursor (Get-DtJobLastEventSeq -RunFolder $Entry.run_folder) }
    }
    & $original -Entry $Entry -NowUtc $NowUtc
}
Invoke-WatcherRun -Entry $entry | ConvertTo-Json -Compress
'@
    $changed = (& pwsh -NoProfile -File $probe -WatcherScript $watcher | Select-Object -Last 1) | ConvertFrom-Json
    Assert-True ($changed.action -eq 'none' -and $changed.detail -like 'changed under lock*' -and (Get-LaunchCount 'changed') -eq 0 -and @(Get-LaunchRecords $run.folder).Count -eq 0) "a change under the lock aborts the launch ($($changed.detail))"

    # ---- a launcher that exits non-zero counts as a failed attempt and is retried on schedule.
    Use-Scenario 'launcher-fail'
    $run = New-Run -Name 'launcher-fail'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $env:DT_TEST_LAUNCH_FAIL = '1'
    $tf = [DateTime]::UtcNow
    try {
        Invoke-Tick -NowUtc $tf | Out-Null
        Invoke-Tick -NowUtc $tf.AddSeconds(60) | Out-Null
    }
    finally { Remove-Item Env:DT_TEST_LAUNCH_FAIL -ErrorAction SilentlyContinue }
    $failed = @(Get-LaunchRecords $run.folder | Where-Object { $_.type -eq 'launch' })
    $failLease = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'coordinator.lease') | ConvertFrom-Json
    Assert-True ($failed.Count -eq 1 -and $failed[0].launcher_exit -eq 1 -and $null -eq $failed[0].pid -and (Get-LaunchCount 'launcher-fail') -eq 0) 'a failed launcher is recorded as attempt 1 with its exit code and no child'
    Assert-True ([bool]$failLease.released_utc -and $failLease.coordinator_id -eq $failed[0].coordinator_id) 'the failed launcher released the lease it took'
    Invoke-Tick -NowUtc $tf.AddSeconds(121) | Out-Null
    $failed = @(Get-LaunchRecords $run.folder | Where-Object { $_.type -eq 'launch' })
    Assert-True ($failed.Count -eq 2 -and $failed[1].attempt -eq 2 -and (Get-LaunchCount 'launcher-fail') -eq 1) 'the failed attempt is retried at 2 minutes'

    # ---- an interactive acquire racing a launch: exactly one holder, no orphan child.
    Use-Scenario 'race'
    $run = New-Run -Name 'race'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $env:DT_TEST_LIVE_CHILD = '1'
    $env:DT_TEST_LAUNCH_SLEEP_MS = '4000'
    $tickOut = Join-Path $tempRoot 'race-tick.txt'
    try {
        $background = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', "`"$watcher`"") -RedirectStandardOutput $tickOut -WindowStyle Hidden -PassThru
        $marker = Join-Path $run.folder 'fake-launcher-started'
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while (-not (Test-Path -LiteralPath $marker) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Assert-True (Test-Path -LiteralPath $marker) 'the watcher reached its launcher'
        # The launcher is between the watcher's locked recheck and its own lease acquire: Danny resumes now.
        $raceStart = [DateTime]::UtcNow
        $interactive = Invoke-DtJobExpectFail @('lease', '-RunFolder', $run.folder, '-Action', 'acquire', '-CoordinatorId', 'danny-session', '-LaunchedBy', 'interactive')
        $raceWait = ([DateTime]::UtcNow - $raceStart).TotalSeconds
        $background.WaitForExit(60000) | Out-Null
        $background = $null
    }
    finally {
        Remove-Item Env:DT_TEST_LIVE_CHILD, Env:DT_TEST_LAUNCH_SLEEP_MS -ErrorAction SilentlyContinue
    }
    $spawns = @(Get-Launches 'race')
    $raceLease = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'coordinator.lease') | ConvertFrom-Json
    Assert-True ($interactive.exit -ne 0 -and $interactive.text -match 'DT_JOB_LEASE_HELD') "the interactive acquire is refused ($($interactive.text))"
    Assert-True ($raceWait -ge 2) "the interactive acquire waited on coordinator.lock until the launch finished ($raceWait s)"
    Assert-True ($spawns.Count -eq 1 -and $raceLease.coordinator_id -eq $spawns[0].coordinator_id -and $raceLease.pid -eq $spawns[0].pid -and $raceLease.launched_by -eq 'watcher') 'exactly one holder: the one spawned child holds the lease'
    $childStart = Get-Process -Id ([int]$raceLease.pid) -ErrorAction SilentlyContinue
    Assert-True ($null -ne $childStart -and ([DateTime]$raceLease.pid_start_utc).ToUniversalTime().Ticks -eq $childStart.StartTime.ToUniversalTime().Ticks) 'the lease records the live child pid and its start time'
    # Expire the lease while the child lives: acquire is still refused.
    $raceLease.expires_utc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
    Write-Utf8 -Path (Join-Path $run.folder 'coordinator.lease') -Content ($raceLease | ConvertTo-Json)
    $expiredLive = Invoke-DtJobExpectFail @('lease', '-RunFolder', $run.folder, '-Action', 'acquire', '-CoordinatorId', 'danny-session', '-LaunchedBy', 'interactive')
    Assert-True ($expiredLive.exit -ne 0 -and $expiredLive.text -match 'still running') 'an expired lease whose watcher-launched pid lives still refuses acquire'
    Stop-Process -Id ([int]$raceLease.pid) -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    $takeover = Invoke-DtJob @('lease', '-RunFolder', $run.folder, '-Action', 'acquire', '-CoordinatorId', 'danny-session', '-LaunchedBy', 'interactive')
    Assert-True ($takeover.coordinator_id -eq 'danny-session') 'once the child is gone the interactive acquire succeeds'

    # ---- coordinators and jobs cannot approve or resume; the operator can.
    Use-Scenario 'operator'
    $run = New-Run -Name 'operator'
    Invoke-DtJob @('await-danny', '-RunFolder', $run.folder, '-Operation', 'merge', '-Message', 'Ready.') | Out-Null
    $env:DT_BUILD_COORDINATOR_ID = 'mc-self'
    try {
        $selfApprove = Invoke-DtJobExpectFail @('approve', '-RunFolder', $run.folder, '-Operation', 'merge')
        $selfResume = Invoke-DtJobExpectFail @('resume', '-RunFolder', $run.folder)
    }
    finally { Remove-Item Env:DT_BUILD_COORDINATOR_ID -ErrorAction SilentlyContinue }
    $approvals = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'approvals.json') | ConvertFrom-Json
    Assert-True ($selfApprove.exit -ne 0 -and $selfApprove.text -match 'DT_JOB_OPERATOR_ONLY' -and @($approvals.approvals).Count -eq 0 -and (Get-RunState $run.state).run_status -eq 'awaiting_danny') 'approve with DT_BUILD_COORDINATOR_ID set is refused and records nothing'
    Assert-True ($selfResume.exit -ne 0 -and $selfResume.text -match 'DT_JOB_OPERATOR_ONLY') 'resume with DT_BUILD_COORDINATOR_ID set is refused'
    $inJob = Invoke-DtJob @('start', '-RunFolder', $run.folder, '-Command', "`$o = (& pwsh -NoProfile -File '$dtJob' approve -RunFolder '$($run.folder)' -Operation merge 2>&1 | ForEach-Object { [string]`$_ }) -join ' '; `$r = (& pwsh -NoProfile -File '$dtJob' resume -RunFolder '$($run.folder)' 2>&1 | ForEach-Object { [string]`$_ }) -join ' '; 'approve=' + `$o + ' resume=' + `$r")
    Invoke-DtJob @('wait', '-RunFolder', $run.folder, '-JobId', $inJob.job_id, '-All', '-TimeoutSec', '90') | Out-Null
    $inJobOut = Get-Content -Raw -LiteralPath (Join-Path $run.folder "jobs/$($inJob.job_id)/stdout.log")
    Assert-True ($inJobOut -match "DT_JOB_OPERATOR_ONLY: approve is Danny's command; it cannot run inside dt-job" -and $inJobOut -match "DT_JOB_OPERATOR_ONLY: resume is Danny's command; it cannot run inside dt-job") "approve and resume inside a dt-job job are refused ($($inJobOut.Substring(0, [Math]::Min(600, $inJobOut.Length))))"
    Assert-True ((Get-RunState $run.state).run_status -eq 'awaiting_danny') 'a job cannot release the boundary'
    $operatorOk = Invoke-DtJob @('approve', '-RunFolder', $run.folder, '-Operation', 'merge')
    Assert-True ($operatorOk.run_status -eq 'runnable') 'the operator path still approves'

    # ---- jobs never inherit the coordinator identity.
    $env:DT_BUILD_COORDINATOR_ID = 'mc-parent'
    try { $envJob = Invoke-DtJob @('start', '-RunFolder', $run.folder, '-Command', "'coord=[{0}] job=[{1}]' -f `$env:DT_BUILD_COORDINATOR_ID, `$env:DT_JOB_ID") }
    finally { Remove-Item Env:DT_BUILD_COORDINATOR_ID -ErrorAction SilentlyContinue }
    Invoke-DtJob @('wait', '-RunFolder', $run.folder, '-JobId', $envJob.job_id, '-All', '-TimeoutSec', '60') | Out-Null
    $envOut = (Get-Content -Raw -LiteralPath (Join-Path $run.folder "jobs/$($envJob.job_id)/stdout.log")).Trim()
    $envSpec = Get-Content -Raw -LiteralPath (Join-Path $run.folder "jobs/$($envJob.job_id)/spec.json")
    Assert-True ($envOut -eq "coord=[] job=[$($envJob.job_id)]" -and -not $envSpec.Contains('mc-parent')) "DT_BUILD_COORDINATOR_ID is not passed to jobs ($envOut)"

    # ---- every approval boundary DMs; a repeat of the same boundary does not.
    Use-Scenario 'boundaries'
    $run = New-Run -Name 'boundaries'
    $first = Invoke-DtJob @('await-danny', '-RunFolder', $run.folder, '-Operation', 'merge', '-Message', 'M01 ready.')
    $firstRepeat = Invoke-DtJob @('await-danny', '-RunFolder', $run.folder, '-Operation', 'merge', '-Message', 'M01 ready.')
    $tbd = [DateTime]::UtcNow
    foreach ($offset in @(0, 2, 4)) { Invoke-Tick -NowUtc $tbd.AddMinutes($offset) | Out-Null }
    Assert-True ($first.alert -eq 'sent' -and $firstRepeat.alert -eq 'already_sent' -and $firstRepeat.await_seq -eq $first.await_seq -and (Get-DmCount 'boundaries') -eq 1) 'the same boundary sends one DM across repeats and ticks'
    Invoke-DtJob @('approve', '-RunFolder', $run.folder, '-Operation', 'merge') | Out-Null
    $second = Invoke-DtJob @('await-danny', '-RunFolder', $run.folder, '-Operation', 'merge', '-Message', 'M02 ready.')
    foreach ($offset in @(6, 8)) { Invoke-Tick -NowUtc $tbd.AddMinutes($offset) | Out-Null }
    $keys = @(Get-Content -LiteralPath (Join-Path $run.folder 'notifications.jsonl') | ForEach-Object { ($_ | ConvertFrom-Json).key })
    Assert-True ($second.alert -eq 'sent' -and $second.await_seq -gt $first.await_seq -and (Get-DmCount 'boundaries') -eq 2) 'a second boundary for the same operation sends a new DM'
    Assert-True (($keys -join '|') -eq "dt-build:boundaries:awaiting:merge:$($first.await_seq)|dt-build:boundaries:awaiting:merge:$($second.await_seq)") 'the DM key carries the await event seq'

    # ---- an approval DM that failed to send is retried on later ticks until delivered.
    Use-Scenario 'dm-retry'
    $run = New-Run -Name 'dm-retry'
    $env:DT_TEST_DM_FAIL = '1'
    $tr = [DateTime]::UtcNow
    try {
        $failedAwait = Invoke-DtJob @('await-danny', '-RunFolder', $run.folder, '-Operation', 'push', '-Message', 'Push ready.')
        Invoke-Tick -NowUtc $tr | Out-Null
    }
    finally { Remove-Item Env:DT_TEST_DM_FAIL -ErrorAction SilentlyContinue }
    $pending = @(Get-Content -LiteralPath (Join-Path $run.folder 'notifications.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($failedAwait.alert -eq 'failed' -and (Get-DmCount 'dm-retry') -eq 0 -and $pending.Count -eq 1 -and $pending[0].status -eq 'pending') 'a failed approval DM is recorded as pending'
    foreach ($offset in @(2, 4, 6)) { Invoke-Tick -NowUtc $tr.AddMinutes($offset) | Out-Null }
    $rowsAfter = @(Get-Content -LiteralPath (Join-Path $run.folder 'notifications.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ((Get-DmCount 'dm-retry') -eq 1 -and @($rowsAfter | Where-Object { $_.status -eq 'delivered' }).Count -eq 1) 'a later tick delivers it exactly once'

    # ---- run-wide cap: 6 launches in 60 minutes, then a stop whose failed DM is retried; resume re-arms.
    Use-Scenario 'cap'
    $run = New-Run -Name 'cap'
    $tk = [DateTime]::UtcNow
    for ($i = 0; $i -lt 6; $i++) {
        Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
        Invoke-Tick -NowUtc $tk.AddMinutes(2 * $i) | Out-Null
    }
    Assert-True ((Get-LaunchCount 'cap') -eq 6 -and @(Get-LaunchRecords $run.folder | Select-Object -ExpandProperty trigger_seq -Unique).Count -eq 6) 'six triggers launch six times'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $env:DT_TEST_DM_FAIL = '1'
    try { Invoke-Tick -NowUtc $tk.AddMinutes(12) | Out-Null }
    finally { Remove-Item Env:DT_TEST_DM_FAIL -ErrorAction SilentlyContinue }
    Assert-True ((Get-LaunchCount 'cap') -eq 6 -and (Get-RunState $run.state).run_status -eq 'awaiting_danny' -and (Get-DmCount 'cap') -eq 0) 'the seventh launch inside 60 minutes stops the run instead'
    foreach ($offset in @(14, 16, 18)) { Invoke-Tick -NowUtc $tk.AddMinutes($offset) | Out-Null }
    $capDm = Get-Content -LiteralPath $env:DT_TEST_DM_LOG | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { ([string]$_.content).Contains('run cap ') }
    Assert-True ((Get-DmCount 'cap') -eq 1 -and ([string]@($capDm)[0].content).Contains('/dt-build resume cap') -and (Get-LaunchCount 'cap') -eq 6) 'the failed stop DM is retried once and names resume'
    Invoke-DtJob @('resume', '-RunFolder', $run.folder) | Out-Null
    Invoke-Tick -NowUtc $tk.AddMinutes(20) | Out-Null
    Assert-True ((Get-LaunchCount 'cap') -eq 7) 'resume re-arms the run under the cap'

    # ---- the first run_status and last_consumed_event_seq lines win for both reader and writer.
    Use-Scenario 'dup-lines'
    $run = New-Run -Name 'dup-lines' -Unmanaged -LaunchedBy 'interactive'
    [System.IO.File]::AppendAllText($run.state, "`nrun_status: finished`nlast_consumed_event_seq: 99`n", [System.Text.UTF8Encoding]::new($false))
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $dupSummary = Invoke-DtJob @('consume', '-RunFolder', $run.folder, '-Seq', '1')
    $dupLines = @((Get-Content -Raw -LiteralPath $run.state) -split "\r?\n")
    Assert-True ($dupSummary.run_status -eq 'runnable' -and $dupSummary.last_consumed_event_seq -eq 1) 'the reader takes the first field lines, not a later duplicate'
    Assert-True (@($dupLines | Where-Object { $_ -eq 'last_consumed_event_seq: 1' }).Count -eq 1 -and @($dupLines | Where-Object { $_ -eq 'last_consumed_event_seq: 99' }).Count -eq 1 -and @($dupLines | Where-Object { $_ -eq 'run_status: finished' }).Count -eq 1) 'the writer edits the same first lines and leaves the duplicate alone'

    # ---- a managed coordinator that re-acquires its own lease stays watcher-launched and is relaunched after a crash.
    Use-Scenario 'reacquire'
    $run = New-Run -Name 'reacquire' -NoLease
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $env:DT_TEST_LIVE_CHILD = '1'
    try { Invoke-Tick | Out-Null }
    finally { Remove-Item Env:DT_TEST_LIVE_CHILD -ErrorAction SilentlyContinue }
    $managedSpawn = @(Get-Launches 'reacquire')[0]
    $leaseBefore = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'coordinator.lease') | ConvertFrom-Json
    $env:DT_BUILD_COORDINATOR_ID = $managedSpawn.coordinator_id
    try {
        $reacquired = Invoke-DtJob @('lease', '-RunFolder', $run.folder, '-Action', 'acquire', '-CoordinatorId', $managedSpawn.coordinator_id, '-Host', 'claude')
        $renewed = Invoke-DtJob @('lease', '-RunFolder', $run.folder, '-Action', 'renew', '-CoordinatorId', $managedSpawn.coordinator_id)
        # The coordinator handles its trigger and raises the next event, then crashes before handling that one.
        Invoke-DtJob @('consume', '-RunFolder', $run.folder, '-Seq', [string]@(Get-LaunchRecords $run.folder)[0].trigger_seq) | Out-Null
        Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    }
    finally { Remove-Item Env:DT_BUILD_COORDINATOR_ID -ErrorAction SilentlyContinue }
    $startTicks = { param($v) ([DateTime]$v).ToUniversalTime().Ticks }
    Assert-True ($reacquired.launched_by -eq 'watcher' -and $reacquired.pid -eq $managedSpawn.pid -and (& $startTicks $reacquired.pid_start_utc) -eq (& $startTicks $leaseBefore.pid_start_utc)) "a holder re-acquire without -LaunchedBy or -Pid keeps launched_by, pid, and pid_start_utc ($($reacquired.launched_by), $($reacquired.pid))"
    Assert-True ($renewed.launched_by -eq 'watcher' -and $renewed.pid -eq $managedSpawn.pid -and (& $startTicks $renewed.pid_start_utc) -eq (& $startTicks $leaseBefore.pid_start_utc)) 'a holder renew keeps launched_by, pid, and pid_start_utc'
    $managedProcess = Get-Process -Id ([int]$managedSpawn.pid) -ErrorAction SilentlyContinue
    if ($null -ne $managedProcess) { $managedProcess.Kill(); $managedProcess.WaitForExit(10000) | Out-Null }
    $afterCrash = @(Invoke-Tick | Where-Object { $_.run_id -eq 'reacquire' })
    Assert-True ((Get-LaunchCount 'reacquire') -eq 2 -and $afterCrash.Count -eq 1 -and $afterCrash[0].action -eq 'launch') "after the re-acquired managed coordinator crashes, the watcher relaunches it ($(@($afterCrash | ForEach-Object { $_.detail }) -join '; '))"
    $relaunched = @(Get-Launches 'reacquire')[1]
    $explicit = Invoke-DtJob @('lease', '-RunFolder', $run.folder, '-Action', 'acquire', '-CoordinatorId', $relaunched.coordinator_id, '-LaunchedBy', 'interactive')
    Assert-True ($explicit.launched_by -eq 'interactive') 'an explicit -LaunchedBy on a holder re-acquire is applied'

    # ---- approve and resume refuse while a watcher-launched coordinator is alive, even with its env cleared.
    Use-Scenario 'operator-live'
    $run = New-Run -Name 'operator-live' -NoLease
    Invoke-DtJob @('await-danny', '-RunFolder', $run.folder, '-Operation', 'merge', '-Message', 'Ready.') | Out-Null
    $liveCoordinator = Start-Process -FilePath 'ping.exe' -ArgumentList '-n', '90', '127.0.0.1' -WindowStyle Hidden -PassThru
    try {
        Write-Lease -RunFolder $run.folder -LaunchedBy 'watcher' -LeasePid $liveCoordinator.Id -PidStartUtc $liveCoordinator.StartTime.ToUniversalTime().ToString('o') -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(10)) -CoordinatorId 'mc-live'
        $liveApprove = Invoke-DtJobExpectFail @('approve', '-RunFolder', $run.folder, '-Operation', 'merge')
        $liveResume = Invoke-DtJobExpectFail @('resume', '-RunFolder', $run.folder)
    }
    finally {
        Stop-Process -Id $liveCoordinator.Id -Force -ErrorAction SilentlyContinue
        $liveCoordinator.WaitForExit(10000) | Out-Null
    }
    $liveApprovals = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'approvals.json') | ConvertFrom-Json
    Assert-True ($liveApprove.exit -ne 0 -and $liveApprove.text -match 'DT_JOB_OPERATOR_ONLY' -and $liveApprove.text -match 'mc-live' -and @($liveApprovals.approvals).Count -eq 0 -and (Get-RunState $run.state).run_status -eq 'awaiting_danny') "approve is refused while the watcher-launched coordinator lives ($($liveApprove.text))"
    Assert-True ($liveResume.exit -ne 0 -and $liveResume.text -match 'DT_JOB_OPERATOR_ONLY' -and $liveResume.text -match 'mc-live') 'resume is refused while the watcher-launched coordinator lives'
    $goneApprove = Invoke-DtJob @('approve', '-RunFolder', $run.folder, '-Operation', 'merge')
    $goneResume = Invoke-DtJob @('resume', '-RunFolder', $run.folder)
    Assert-True ($goneApprove.run_status -eq 'runnable' -and $goneResume.run_status -eq 'runnable') 'once that pid is gone the operator can approve and resume'

    # ---- a launcher failure after the child starts kills the child's whole tree.
    Use-Scenario 'tree-kill'
    $run = New-Run -Name 'tree-kill' -NoLease
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $treeFile = Join-Path $tempRoot 'tree-pids.json'
    $env:DT_TEST_TREE_FAIL = $treeFile
    try { Invoke-Tick | Out-Null }
    finally { Remove-Item Env:DT_TEST_TREE_FAIL -ErrorAction SilentlyContinue }
    $treePids = Get-Content -Raw -LiteralPath $treeFile | ConvertFrom-Json
    Start-Sleep -Milliseconds 500
    $survivors = @(@($treePids.child, $treePids.grandchild) | ForEach-Object { Get-Process -Id ([int]$_) -ErrorAction SilentlyContinue } | Where-Object { $_.ProcessName -in @('pwsh', 'PING') })
    $treeLaunch = @(Get-LaunchRecords $run.folder | Where-Object { $_.type -eq 'launch' })
    Assert-True ([int]$treePids.grandchild -gt 0 -and $survivors.Count -eq 0) "the failed launch leaves neither the child nor its grandchild running ($($survivors.Count) survivors)"
    Assert-True ($treeLaunch.Count -eq 1 -and $treeLaunch[0].launcher_exit -eq 1) 'the failed launch is recorded with its exit code'
    $launcherSource = Get-Content -Raw -LiteralPath (Join-Path $scriptDir 'launch-managed-coordinator.ps1')
    Assert-True ($launcherSource.Contains('[System.Diagnostics.Process]::GetProcessById($childPid).Kill($true)') -and -not $launcherSource.Contains('Stop-Process -Id $childPid')) 'the default launcher kills the child tree on its failure path'

    # ---- a resume between the coordinator.lock recheck and the stop leaves the run runnable and sends no stop DM.
    Use-Scenario 'stop-race'
    $run = New-Run -Name 'stop-race'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $stopProbe = Join-Path $tempRoot 'stop-race.ps1'
    Write-Utf8 -Path $stopProbe -Content @'
param([string]$WatcherScript, [string]$DtJobScript)
. $WatcherScript
$entry = @(Get-DtJobRegistryRuns)[0]
$seq = Get-DtJobLastEventSeq -RunFolder $entry.run_folder
# Every retry for the trigger is used up, so this tick decides to stop.
for ($i = 1; $i -le $script:WatcherMaxAttempts; $i++) {
    Add-WatcherLaunch -RunFolder $entry.run_folder -Record ([ordered]@{ type = 'launch'; trigger_seq = $seq; host = 'claude'; attempt = $i; launched_utc = [DateTime]::UtcNow.AddHours(-2).ToString('o'); pid = $null; coordinator_id = "old-$i"; launcher_exit = 0 })
}
$script:decisionCalls = 0
$original = ${function:Get-WatcherDecision}
function Get-WatcherDecision {
    param($Entry, $NowUtc)
    $script:decisionCalls++
    $result = & $original -Entry $Entry -NowUtc $NowUtc
    # Danny resumes right after the coordinator.lock recheck, before the stop is written.
    if ($script:decisionCalls -eq 2) { & pwsh -NoProfile -File $DtJobScript resume -RunFolder $Entry.run_folder *> $null }
    $result
}
Invoke-WatcherRun -Entry $entry | ConvertTo-Json -Compress
'@
    $stopRace = (& pwsh -NoProfile -File $stopProbe -WatcherScript $watcher -DtJobScript $dtJob | Select-Object -Last 1) | ConvertFrom-Json
    Assert-True ($stopRace.action -eq 'none' -and $stopRace.detail -like 'changed under run lock*') "the stop sees the resume under the run lock ($($stopRace.detail))"
    Assert-True ((Get-RunState $run.state).run_status -eq 'runnable' -and (Get-DmCount 'stop-race') -eq 0 -and @(Get-LaunchRecords $run.folder | Where-Object { $_.type -eq 'stopped' }).Count -eq 0) 'the run stays runnable, no stop is recorded, and no stop DM is sent'

    # ---- a corrupt registry exits non-zero with one DM per episode until it parses again.
    Use-Scenario 'registry-corrupt'
    $registryFile = Join-Path $env:DT_BUILD_STATE_DIR 'active-runs.json'
    Write-Utf8 -Path $registryFile -Content '{ "runs": [ {'
    $registryDms = { @(if (Test-Path -LiteralPath $env:DT_TEST_DM_LOG) { Get-Content -LiteralPath $env:DT_TEST_DM_LOG | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { ([string]$_.content).Contains('cannot read its run registry') } }).Count }
    $corruptExits = @()
    foreach ($n in 1..2) {
        & pwsh -NoProfile -File $watcher *> $null
        $corruptExits += $LASTEXITCODE
    }
    Assert-True (@($corruptExits | Where-Object { $_ -eq 0 }).Count -eq 0 -and (& $registryDms) -eq 1) "a corrupt registry exits non-zero every tick and DMs once (exits $($corruptExits -join ','), DMs $(& $registryDms))"
    Write-Utf8 -Path $registryFile -Content '{ "runs": [] }'
    & pwsh -NoProfile -File $watcher *> $null
    Assert-True ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath "$registryFile.error.json")) 'a registry that parses again clears the error'
    Write-Utf8 -Path $registryFile -Content '{ "runs": [ {'
    & pwsh -NoProfile -File $watcher *> $null
    Assert-True ($LASTEXITCODE -ne 0 -and (& $registryDms) -eq 2) 'a new corruption after a clean parse DMs again'

    # ---- wait renews at least every min(60 s, ttl/2).
    $renewSec = @(& pwsh -NoProfile -Command ". '$dtJob'; foreach (`$t in 600, 7200, 100, 4, 1) { Get-DtJobWaitRenewSec ([pscustomobject]@{ ttl_sec = `$t }) }")
    Assert-True (($renewSec -join ',') -eq '60,60,50,2,1') "wait renewal interval is min(60 s, ttl/2) ($($renewSec -join ','))"

    # ---- a resume that beats a cap stop re-arms the cap window, so the next tick launches instead of stopping.
    Use-Scenario 'cap-rearm'
    $run = New-Run -Name 'cap-rearm'
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $rearmProbe = Join-Path $tempRoot 'cap-rearm.ps1'
    Write-Utf8 -Path $rearmProbe -Content @'
param([string]$WatcherScript, [string]$DtJobScript)
. $WatcherScript
$entry = @(Get-DtJobRegistryRuns)[0]
# Six recent launches for earlier triggers fill the run-wide cap, so this tick decides a cap stop.
for ($i = 1; $i -le $script:WatcherRunLaunchCap; $i++) {
    Add-WatcherLaunch -RunFolder $entry.run_folder -Record ([ordered]@{ type = 'launch'; trigger_seq = 1000 + $i; host = 'claude'; attempt = 1; launched_utc = [DateTime]::UtcNow.AddMinutes(-5).ToString('o'); pid = $null; coordinator_id = "cap-$i"; launcher_exit = 0 })
}
$script:decisionCalls = 0
$original = ${function:Get-WatcherDecision}
function Get-WatcherDecision {
    param($Entry, $NowUtc)
    $script:decisionCalls++
    $result = & $original -Entry $Entry -NowUtc $NowUtc
    if ($script:decisionCalls -eq 2) { & pwsh -NoProfile -File $DtJobScript resume -RunFolder $Entry.run_folder *> $null }
    $result
}
$first = Invoke-WatcherRun -Entry $entry
[pscustomobject]@{ first_detail = $first.detail; decision = (& $original -Entry $entry -NowUtc ([DateTime]::UtcNow)).action } | ConvertTo-Json -Compress
'@
    $rearm = (& pwsh -NoProfile -File $rearmProbe -WatcherScript $watcher -DtJobScript $dtJob | Select-Object -Last 1) | ConvertFrom-Json
    $rearmRows = @(Get-LaunchRecords $run.folder | Where-Object { $_.type -eq 'rearmed' })
    Assert-True ($rearm.first_detail -like 'changed under run lock*' -and $rearmRows.Count -eq 1 -and @(Get-LaunchRecords $run.folder | Where-Object { $_.type -eq 'stopped' }).Count -eq 0) "a cap stop beaten by resume writes one re-arm marker and no stop ($($rearm.first_detail))"
    Assert-True ($rearm.decision -eq 'launch') "after the re-arm the next decision is a launch, not another cap stop ($($rearm.decision))"
    $rearmTick = @(Invoke-Tick | Where-Object { $_.run_id -eq 'cap-rearm' })[0]
    Assert-True ($rearmTick.action -eq 'launch' -and (Get-RunState $run.state).run_status -eq 'runnable' -and (Get-DmCount 'cap-rearm') -eq 0) "the next tick launches and the run stays runnable ($($rearmTick.action): $($rearmTick.detail))"

    # ---- a holder re-acquire keeps launched_by, pid, and pid_start_utc only while its lease is unreleased.
    Use-Scenario 'reacquire-released'
    $rf = Join-Path $tempRoot 'runs/reacquire-released'
    New-Item -ItemType Directory -Path $rf -Force | Out-Null
    $holderProc = Start-Process -FilePath 'ping.exe' -ArgumentList '-n', '60', '127.0.0.1' -WindowStyle Hidden -PassThru
    try {
        Invoke-DtJob @('lease', '-RunFolder', $rf, '-Action', 'acquire', '-CoordinatorId', 'mc-hold', '-Host', 'codex', '-LaunchedBy', 'watcher', '-Pid', [string]$holderProc.Id) | Out-Null
        $kept = Invoke-DtJob @('lease', '-RunFolder', $rf, '-Action', 'acquire', '-CoordinatorId', 'mc-hold', '-Host', 'codex')
        Assert-True ($kept.launched_by -eq 'watcher' -and [int]$kept.pid -eq $holderProc.Id -and $kept.pid_start_utc) 'an unreleased holder re-acquire keeps launched_by, pid, and pid_start_utc'
        Invoke-DtJob @('lease', '-RunFolder', $rf, '-Action', 'release', '-CoordinatorId', 'mc-hold') | Out-Null
        $fresh = Invoke-DtJob @('lease', '-RunFolder', $rf, '-Action', 'acquire', '-CoordinatorId', 'mc-hold', '-Host', 'codex')
        Assert-True ($fresh.launched_by -eq 'interactive' -and $null -eq $fresh.pid -and $null -eq $fresh.pid_start_utc -and $null -eq $fresh.released_utc) "a re-acquire after release keeps none of the old identity ($($fresh.launched_by), pid $($fresh.pid))"
    }
    finally { if (-not $holderProc.HasExited) { $holderProc.Kill() } }

    # ---- one failed registry read is retried within the tick before it counts as an error.
    $registryProbe = Join-Path $tempRoot 'registry-retry.ps1'
    Write-Utf8 -Path $registryProbe -Content @'
param([string]$WatcherScript, [int]$Failures)
. $WatcherScript
$script:WatcherRegistryRetryMs = 1
$script:registryCalls = 0
function Get-DtJobRegistryRuns {
    $script:registryCalls++
    if ($script:registryCalls -le $Failures) { throw "registry read failure $script:registryCalls" }
    return @([pscustomobject]@{ run_id = 'from-retry' })
}
try { $runs = @(Read-WatcherRegistry); $outcome = "ok:$($runs[0].run_id)" } catch { $outcome = "error:$($_.Exception.Message)" }
[pscustomobject]@{ outcome = $outcome; calls = $script:registryCalls } | ConvertTo-Json -Compress
'@
    $once = (& pwsh -NoProfile -File $registryProbe -WatcherScript $watcher -Failures 1 | Select-Object -Last 1) | ConvertFrom-Json
    Assert-True ($once.outcome -eq 'ok:from-retry' -and $once.calls -eq 2) "a single failed registry read is retried and succeeds ($($once.outcome), $($once.calls) calls)"
    $twice = (& pwsh -NoProfile -File $registryProbe -WatcherScript $watcher -Failures 2 | Select-Object -Last 1) | ConvertFrom-Json
    Assert-True ($twice.outcome -eq 'error:registry read failure 2' -and $twice.calls -eq 2) "two failed reads surface the error after exactly one retry ($($twice.outcome), $($twice.calls) calls)"
    $watcherText = Get-Content -Raw -LiteralPath $watcher
    Assert-True ($watcherText.Contains('try { $runs = @(Read-WatcherRegistry) }')) 'the watcher reads the registry through the retrying reader'

    # ---- static: the default launcher and the task registration parse, and the task uses the shim.
    foreach ($file in @('launch-managed-coordinator.ps1', 'register-dt-build-watcher.ps1', 'dt-build-watcher.ps1')) {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptDir $file), [ref]$tokens, [ref]$errors) | Out-Null
        Assert-True (@($errors).Count -eq 0) "$file parses"
    }
    $registerText = Get-Content -Raw -LiteralPath (Join-Path $scriptDir 'register-dt-build-watcher.ps1')
    Assert-True ($registerText.Contains("-Execute 'wscript.exe'") -and $registerText.Contains('run-hidden.vbs') -and $registerText.Contains('New-TimeSpan -Minutes 2')) 'the scheduled task runs through run-hidden.vbs every 2 minutes'
    $launcherText = Get-Content -Raw -LiteralPath (Join-Path $scriptDir 'launch-managed-coordinator.ps1')
    Assert-True ($launcherText.Contains('resume $RunId (managed coordinator $CoordinatorId)') -and $launcherText.Contains("'`$dt-build'") -and $launcherText.Contains('-LaunchedBy watcher')) 'the default launcher sends the one-line resume prompt and writes a watcher lease'
    $acquireAt = $launcherText.IndexOf('-Action acquire')
    $createAt = $launcherText.IndexOf('-MethodName Create')
    $pidAt = $launcherText.IndexOf('-Action renew -CoordinatorId $CoordinatorId -Pid $childPid')
    $releaseAt = $launcherText.IndexOf('-Action release')
    Assert-True ($acquireAt -gt 0 -and $acquireAt -lt $createAt -and $createAt -lt $pidAt -and $releaseAt -gt $createAt) 'the default launcher takes the lease before starting the child, then records its pid, and releases on failure'
}
catch {
    Write-Output "FAIL: $($_.Exception.Message)"
    Write-Output $_.ScriptStackTrace
    $exitCode = 1
}
finally {
    if ($null -ne $background -and -not $background.HasExited) { $background.Kill($true) }
    foreach ($spawnedPid in $script:spawned) { Get-Process -Id $spawnedPid -ErrorAction SilentlyContinue | Where-Object { @('ping', 'pwsh') -contains $_.ProcessName } | Stop-Process -Force -ErrorAction SilentlyContinue }
    # Fake coordinators told to stay up are ping processes; stop any a failed test left behind.
    if ($env:DT_TEST_LAUNCH_LOG -and (Test-Path -LiteralPath $env:DT_TEST_LAUNCH_LOG)) {
        foreach ($spawn in @(Get-Content -LiteralPath $env:DT_TEST_LAUNCH_LOG | ForEach-Object { $_ | ConvertFrom-Json })) {
            Get-Process -Id ([int]$spawn.pid) -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -ieq 'ping' } | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($name in $savedEnv.Keys) { [System.Environment]::SetEnvironmentVariable($name, $savedEnv[$name]) }
    Write-Output "SUMMARY: $script:passed passed"
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
exit $exitCode
