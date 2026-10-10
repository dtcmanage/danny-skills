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
foreach ($name in @('DT_BUILD_STATE_DIR', 'DT_MODEL_ROUTER_STATE', 'DT_MODEL_ROUTER_ALERT_TRANSPORT', 'DT_BUILD_COORDINATOR_LAUNCHER', 'DT_BUILD_VENDOR_LIMITS_SCRIPT', 'DT_BUILD_WATCHER_NOW_UTC', 'DT_BUILD_COORDINATOR_ID', 'DT_TEST_DM_LOG', 'DT_TEST_LAUNCH_LOG', 'DT_TEST_DEAD_PID', 'DT_TEST_BLOCKED', 'DT_TEST_RESET_CLAUDE', 'DT_TEST_RESET_CODEX', 'DT_TEST_DTJOB', 'DT_TEST_LIVE_CHILD', 'DT_TEST_LAUNCH_SLEEP_MS', 'DT_TEST_LAUNCH_FAIL', 'DT_TEST_DM_FAIL', 'DT_BUILD_COORDINATOR_LOCK_HELD', 'DT_JOB_ID')) {
    $savedEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
}

# Isolation: temp registry, temp router state, fake alert transport, fake launcher, fake vendor limits.
$env:DT_MODEL_ROUTER_STATE = Join-Path $tempRoot 'router-state'
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

$exitCode = 0
$background = $null
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

    # ---- wait renews at least every min(60 s, ttl/2).
    $renewSec = @(& pwsh -NoProfile -Command ". '$dtJob'; foreach (`$t in 600, 7200, 100, 4, 1) { Get-DtJobWaitRenewSec ([pscustomobject]@{ ttl_sec = `$t }) }")
    Assert-True (($renewSec -join ',') -eq '60,60,50,2,1') "wait renewal interval is min(60 s, ttl/2) ($($renewSec -join ','))"

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
