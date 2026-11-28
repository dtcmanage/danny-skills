# Fast, isolated watcher/CLI integration fixtures; no live builds or external transport.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../../../scripts/lib/runtime-test-admission.ps1')
Enter-RuntimeTestSuite
$ErrorActionPreference = 'Stop'
$script:passed = 0; $script:failed = 0
$script:children = [Collections.Generic.List[object]]::new()
function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passed++ } else { $script:failed++; Write-Output "ASSERT_FAIL: $Message" }
}
$scriptDir = Split-Path -Parent $PSScriptRoot
$jobScript = Join-Path $scriptDir 'dt-job.ps1'
$tempRoot = Join-Path (Join-Path $scriptDir '../../../.dt-build') ('dt-stalls-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tempRoot | Out-Null
$env:DT_BUILD_STATE_DIR = Join-Path $tempRoot 'registry'
$env:DT_MODEL_ROUTER_STATE = Join-Path $tempRoot 'router'
$env:DT_BUILD_HEADLESS = '1'
$env:DT_JOB_STALL_SEC = '10'
$env:DT_STALL_TEST_DM = Join-Path $tempRoot 'dm.jsonl'
$env:DT_MODEL_ROUTER_ALERT_TRANSPORT = Join-Path $tempRoot 'transport.ps1'
@'
param($request)
if ($request['kind'] -eq 'secret') { return 'fixture-secret' }
if ($env:DT_STALL_TEST_FAIL_DM -eq '1' -and ([string]$request['uri'] -like '*/messages' -or [string]$request['uri'] -like '*/emails')) { throw 'fixture alert delivery failure' }
if ([string]$request['uri'] -like '*/oauth2/applications/@me') { return [pscustomobject]@{ owner=[pscustomobject]@{ id='1' } } }
if ([string]$request['uri'] -like '*/messages') { [IO.File]::AppendAllText($env:DT_STALL_TEST_DM, ([string]$request['body']) + "`n") }
return [pscustomobject]@{ id='fixture' }
'@ | Set-Content $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
. (Join-Path $scriptDir 'dt-build-watcher.ps1')
function New-Fixture([string]$Name, [int]$Idle=15) {
    $rf = Join-Path $tempRoot $Name
    $dir = Join-Path $rf 'jobs/j-0001'
    New-Item -ItemType Directory $dir -Force | Out-Null
    $state = Join-Path $rf '_build-state.md'
    "run_status: runnable`nlast_consumed_event_seq: 0`nstatus_line: fixture" | Set-Content $state
    $child = Start-Process (Join-Path $PSHOME 'pwsh') -ArgumentList @('-NoProfile','-Command','Start-Sleep 600') -PassThru
    $script:children.Add($child)
    $record = [pscustomobject]@{ job_id='j-0001'; kind='command'; category='fixture'; status='running'; status_reason=$null; exit_code=$null; started=[DateTime]::UtcNow.AddMinutes(-10).ToString('o'); expected_sec=0; pid=$child.Id; process_start_utc=(Get-DtJobProcessStartUtc -ProcessId $child.Id); runner_pid=$null; runner_start_utc=$null; depends_on=@(); mutates=@(); output_path=(Join-Path $dir 'stdout.log'); stderr_path=(Join-Path $dir 'stderr.log'); summary_path=(Join-Path $dir 'summary.json') }
    Save-DtJobRecord -RunFolder $rf -Record $record
    @{ command="while (`$true) { Start-Sleep 1 } # release.py ship"; script_path=$null; argument_list=@() } | ConvertTo-Json | Set-Content (Join-Path $dir 'spec.json')
    'waiting for release.py ship' | Set-Content $record.output_path
    '' | Set-Content $record.stderr_path
    Set-Beat $rf $Idle
    $director = [pscustomobject]@{ name='fixture-director'; pid=$PID; pid_start_utc=(Get-DtJobProcessStartUtc -ProcessId $PID); session_id='fixture' }
    $entry = [pscustomobject]@{ run_id=$Name; run_folder=$rf; build_state_path=$state; managed=$false; pinned_host='codex'; director=$director }
    Save-DtJobRegistryRuns -Runs (@(Get-DtJobRegistryRuns) + @($entry))
    return $entry
}
function Set-Beat([string]$Rf, [int]$Idle) {
    @{ last_activity_utc=[DateTime]::UtcNow.AddSeconds(-$Idle).ToString('o'); cpu_seconds=68; file_changes=0 } | ConvertTo-Json | Set-Content (Join-Path $Rf 'jobs/j-0001/heartbeat.json')
}
function Read-Reply([string[]]$JobArgs) {
    $raw = & pwsh -NoProfile -File $jobScript @JobArgs -Json
    if ($LASTEXITCODE -ne 0) { throw "dt-job failed: $JobArgs" }
    return (($raw -join "`n") | ConvertFrom-Json)
}
function Test-AlertDelivered([string]$Rf, [string]$Key) {
    return @((Get-DtJobNotifications $Rf) | Where-Object { $_.key -ceq $Key -and (Test-DtJobNotificationDelivered $_) }).Count -gt 0
}
try {
    # Advance the production sampler's clock through two hours, without sleeping.
    # The same confirmed clock is then consumed by the real watcher/director path.
    $origin = [DateTime]::UtcNow.AddMinutes(-120)
    foreach ($scenario in @('chatter', 'flapping', 'fast-retry', 'request-ids', 'wait-attempt', 'heartbeat', 'download-progress', 'rows-progress', 'tests', 'jittered-tests', 'poll-progress', 'shard-progress', 'iteration-progress', 'percent-progress', 'cpu', 'files')) {
        $progress = New-DtJobProgress -Now $origin
        $everStalled = $false; $dueMinute = $null
        $nextReport = 0; $reportIndex = 0; $fastPhase = 0
        $fastPath = Join-Path $tempRoot 'fast-retry.log'
        if ($scenario -eq 'fast-retry') { [IO.File]::WriteAllText($fastPath, '') }
        for ($sec=0; $sec -le 7200; $sec+=30) {
            $now = $origin.AddSeconds($sec)
            $lines = @()
            if ($scenario -eq 'wait-attempt') {
                # Six lines emitted every five seconds between runner samples.
                $lines = @(0..5 | ForEach-Object { "waiting for db (attempt $($sec/5 + $_))" })
            }
            if ($scenario -eq 'heartbeat') { $lines=@("heartbeat alive #$($sec/30) epoch=$(1764000000 + $sec)") }
            if ($scenario -eq 'download-progress') { $lines=@("downloaded $(123456789 + $sec) bytes") }
            if ($scenario -eq 'rows-progress') { $lines=@("rows=$(10485760 + $sec)") }
            if ($scenario -eq 'chatter' -and $sec % 900 -eq 0) { $lines=@("$($now.ToString('o')) still waiting... polling=$sec") }
            if ($scenario -eq 'tests' -and $sec % 60 -eq 0) { $lines=@("tests/case_$sec passed") }
            if ($scenario -eq 'fast-retry') {
                # 50 identical UTF-8 lines/sec, with a different cut on each tick.
                $line = "connection refused, retrying: service unavailable é`n"
                $length = $line.Length * 1500 + $sec % 7
                [IO.File]::AppendAllText($fastPath, ($line * 1502).Substring($fastPhase, $length))
                $fastPhase = ($fastPhase + $length) % $line.Length
                $lines = @(Read-DtJobProgressOutput $progress @($fastPath))
            }
            if ($scenario -eq 'request-ids' -and $sec % 900 -eq 0) {
                $lines=@("retry req=$([guid]::NewGuid()) trace=$($sec.ToString('x8')) pid=$sec port=$(1000+$sec) after $sec`ms")
            }
            if ($scenario -eq 'jittered-tests' -and $sec -ge $nextReport) {
                $lines=@("tests/jitter_$reportIndex passed")
                $nextReport += @(61,89,73,90,67,82)[$reportIndex % 6]; $reportIndex++
            }
            if ($scenario -eq 'poll-progress') { $lines=@("polling job: $sec/20000 complete") }
            if ($scenario -eq 'shard-progress') { $lines=@("retrying shard $sec of 20000") }
            if ($scenario -eq 'iteration-progress') { $lines=@("iteration $sec/20000") }
            if ($scenario -eq 'percent-progress') { $lines=@("polling $($sec/100)% complete") }
            $burst = $scenario -eq 'flapping' -and $sec % 1800 -eq 0
            $last = Update-DtJobProgress -Progress $progress -Now $now -CpuActive ($scenario -eq 'cpu' -or $burst) -FileActive ($scenario -eq 'files' -or $burst) -Lines $lines
            $idle = ($now - $last).TotalSeconds
            if ($idle -ge 1200) { $everStalled=$true }
            if ($idle -ge 2400 -and $null -eq $dueMinute) { $dueMinute=$sec/60 }
        }
        if ($scenario -in @('chatter','flapping','fast-retry','request-ids','wait-attempt','heartbeat')) {
            Assert-True ($everStalled -and $dueMinute -le 120 -and $last -eq $origin) "$scenario escalates by two hours without resetting first stall"
            $entry = New-Fixture "progress-$scenario"
            $rf = $entry.run_folder
            @{ last_activity_utc=$last.ToString('o'); cpu_seconds=68; file_changes=0 } | ConvertTo-Json | Set-Content (Join-Path $rf 'jobs/j-0001/heartbeat.json')
            Update-DtJobStalls $rf
            $episode = Get-DtJobStall $rf 'j-0001'
            $episode.ack_count=1
            $episode.ack=[pscustomobject]@{until_utc=[DateTime]::UtcNow.AddDays(1).ToString('o')}
            Save-DtJobStall $rf 'j-0001' $episode
            $null = Invoke-WatcherRunTick -Entry $entry
            $stall = Get-DtJobStall $rf 'j-0001'
            $seq = (Get-DtJobApprovals $rf).awaiting.seq
            $null = Invoke-WatcherRunTick -Entry $entry
            Assert-True ($null -ne $stall.stop_seq -and $seq -eq (Get-DtJobApprovals $rf).awaiting.seq) "$scenario reaches director exactly once"
            Assert-True ($stall.first_stalled_utc -and (Get-DtJobRecord $rf 'j-0001').status -eq 'running') "$scenario preserves first stall and never kills"
            Assert-True ($stall.ack_count -eq 1 -and $stall.first_stalled_utc -eq $episode.first_stalled_utc) "$scenario preserves acknowledgement and caps its deadline despite chatter"
        } else {
            Assert-True (-not $everStalled -and $null -eq $dueMinute) "steady $scenario progress stays clean for two hours"
        }
    }
    $progress = New-DtJobProgress -Now $origin
    $null = Test-DtJobNovelOutput $progress @('2026-11-24T10:00:00Z still waiting... retrying=1 (15 seconds)') $origin
    Assert-True (-not (Test-DtJobNovelOutput $progress @('2026-11-24T10:15:00Z still waiting... retrying=2 (30 seconds)') $origin.AddMinutes(15))) 'timestamps and retry counters do not disguise repeat output'
    foreach ($pair in @(
        @('retry #4821', 'retry #4822'),
        @('attempt 37 failed', 'attempt 38 failed'),
        @('reconnecting, try 12', 'reconnecting, try 13'),
        @('waiting 3 jobs remaining', 'waiting 2 jobs remaining'),
        @('waiting 3 left', 'waiting 2 left'),
        @('waiting 1 req=12345678-1234-1234-1234-123456789abc after 5s', 'waiting 2 req=abcdefab-abcd-abcd-abcd-abcdefabcdef after 250ms'),
        @('retrying 1 req=9f3c1234 pid=12 port=80', 'retrying 2 req=0xabcdef12 pid=34 port=8080'),
        @('polling 1 after 5s', 'polling 2 after 250ms'),
        @('retry pid=1234567 port=80', 'retry pid=12345678 port=8080')
    )) {
        $p = New-DtJobProgress $origin
        $null = Test-DtJobNovelOutput $p @($pair[0]) $origin
        Assert-True (-not (Test-DtJobNovelOutput $p @($pair[1]) $origin.AddMinutes(15))) 'volatile IDs, retry numbers and short durations normalize as repeats'
    }
    foreach ($word in @('retry','retrying','attempt','try','waiting','wait','polling','poll','reconnect','reconnecting','backoff')) {
        $p = New-DtJobProgress $origin
        $null = Test-DtJobNovelOutput $p @("4821 failures: $word for db (cycle 37)") $origin
        Assert-True (-not (Test-DtJobNovelOutput $p @("4822 failures: $word for db (cycle 38)") $origin.AddSeconds(30))) "all numbers repeat with wait/retry word anywhere: $word"
    }
    foreach ($template in @('polling job: {0}/2000 complete','retrying shard {0} of 40','iteration {0}/2000','count: {0} of 2000','polling {0}%','waiting {0}/2000','iteration {0}/200000000','waiting {0} of 40 remaining','waiting {0}/40 left','downloaded {0} bytes','rows={0}')) {
        $p = New-DtJobProgress $origin
        $null = Test-DtJobNovelOutput $p @(($template -f 7)) $origin
        Assert-True (Test-DtJobNovelOutput $p @(($template -f 8)) $origin.AddSeconds(30)) "changing progress survives normalization: $template"
        Assert-True (-not (Test-DtJobNovelOutput $p @(($template -f 8)) $origin.AddSeconds(60))) "unchanged progress remains repeat: $template"
    }
    # Run the actual helper initializer twice; reuse must not compile again.
    $runnerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptDir 'dt-job-runner.ps1'), [ref]$null, [ref]$null)
    $copyInit = $runnerAst.Find({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith("if (-not ('DtJobOutputCopy' -as [type]))")
    }, $true)
    & ([scriptblock]::Create($copyInit.Extent.Text))
    & {
        function Add-Type { throw 'output helper compiled twice' }
        & ([scriptblock]::Create($copyInit.Extent.Text))
    }
    $source = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(('live output é' * 10000)))
    $destination = [IO.MemoryStream]::new()
    try {
        [DtJobOutputCopy]::CopyAsync($source, $destination).GetAwaiter().GetResult()
        Assert-True ([Convert]::ToBase64String($source.ToArray()) -eq [Convert]::ToBase64String($destination.ToArray())) 'cached output helper preserves multi-chunk bytes'
    } finally { $source.Dispose(); $destination.Dispose() }
    $p = New-DtJobProgress $origin
    $null = Test-DtJobNovelOutput $p @('oldest item','keep item') $origin
    for ($i=0; $i -lt 9998; $i++) { $null = Test-DtJobNovelOutput $p @("unique item $i") $origin }
    $null = Test-DtJobNovelOutput $p @('keep item','overflow item') $origin.AddMinutes(1)
    Assert-True ($p.seen.Count -eq 10000) 'seen lines capped at 10000'
    Assert-True (-not (Test-DtJobNovelOutput $p @('keep item') $origin.AddMinutes(2))) 'recently repeated line retained at capacity'
    Assert-True (Test-DtJobNovelOutput $p @('oldest item') $origin.AddMinutes(2)) 'oldest line evicted first'
    $null = Test-DtJobNovelOutput $p @() $origin.AddMinutes(123)
    Assert-True ($p.seen.Count -eq 0) 'oldest-prefix expiration clears stale history'
    $p = New-DtJobProgress $origin -WindowSec 10
    $null = Update-DtJobProgress $p $origin $false $false @('fresh output')
    Assert-True ($p.novel_until -eq $origin.AddSeconds(3)) 'shortened recovery windows retain proportional output credit'
    $entry = New-Fixture 'sustained-recovery'
    $rf = $entry.run_folder
    Update-DtJobStalls $rf
    $old = Get-DtJobStall $rf 'j-0001'
    for ($sec=0; $sec -le 360; $sec+=30) {
        $last = Update-DtJobProgress $progress ([DateTime]::UtcNow.AddSeconds($sec - 360)) $true $false @()
    }
    @{ last_activity_utc=$last.ToString('o'); cpu_seconds=68; file_changes=0 } | ConvertTo-Json | Set-Content (Join-Path $rf 'jobs/j-0001/heartbeat.json')
    Update-DtJobStalls $rf
    Assert-True ($null -eq (Get-DtJobStall $rf 'j-0001')) 'sustained recovery clears existing episode'
    Set-Beat $rf 15
    Update-DtJobStalls $rf
    Assert-True ((Get-DtJobStall $rf 'j-0001').event_seq -gt $old.event_seq) 'stall after real recovery starts a new episode'

    $outputProgress = New-DtJobProgress -Now $origin
    $outputPath = Join-Path $tempRoot 'progress-output.log'
    [IO.File]::WriteAllText($outputPath, 'still wai')
    Assert-True (@(Read-DtJobProgressOutput $outputProgress @($outputPath)).Count -eq 0) 'partial line waits for completion'
    [IO.File]::AppendAllText($outputPath, "ting...`n")
    Assert-True ((@(Read-DtJobProgressOutput $outputProgress @($outputPath)) -join '') -eq 'still waiting...') 'incremental reader completes line once'
    Assert-True (@(Read-DtJobProgressOutput $outputProgress @($outputPath)).Count -eq 0) 'unchanged output is not reread'
    $utf8 = [Text.Encoding]::UTF8.GetBytes("é🙂 finished`n")
    foreach ($split in 1..5) {
        $p = New-DtJobProgress $origin
        [IO.File]::WriteAllBytes($outputPath, $utf8[0..($split-1)])
        $null = @(Read-DtJobProgressOutput $p @($outputPath))
        $append = [IO.File]::Open($outputPath, 'Append', 'Write', 'ReadWrite')
        try { $append.Write($utf8, $split, $utf8.Length-$split) } finally { $append.Dispose() }
        Assert-True ((@(Read-DtJobProgressOutput $p @($outputPath)) -join '') -ceq 'é🙂 finished') "UTF-8 character survives read boundary $split"
    }
    foreach ($cut in 0..5) {
        $p = New-DtJobProgress $origin
        # Newest 64 KiB starts at each byte of the multibyte prefix.
        $tail = [Text.Encoding]::UTF8.GetBytes(("é🙂 discarded`n") + ("repeat`n" * 10))
        $bytes = [byte[]]::new(65536 + 20)
        [Array]::Copy($tail, $cut, $bytes, 20, $tail.Length-$cut)
        # Padding is an unterminated final line, never emitted.
        [IO.File]::WriteAllBytes($outputPath, $bytes)
        $readLines = @(Read-DtJobProgressOutput $p @($outputPath))
        Assert-True ($readLines.Count -eq 10 -and @($readLines | Where-Object { $_ -cne 'repeat' }).Count -eq 0) "jump discards incomplete UTF-8 line at byte $cut"
    }
    $p = New-DtJobProgress $origin
    $bytes = [Text.Encoding]::UTF8.GetBytes("🙂" + ('a' * 65534) + "`n")
    [IO.File]::WriteAllBytes($outputPath, $bytes[0..2])
    $null = @(Read-DtJobProgressOutput $p @($outputPath))
    $append = [IO.File]::Open($outputPath, 'Append', 'Write', 'ReadWrite')
    try { $append.Write($bytes, 3, $bytes.Length - 3) } finally { $append.Dispose() }
    Assert-True ((@(Read-DtJobProgressOutput $p @($outputPath)) -join '') -ceq ("🙂" + ('a' * 65534))) 'full read accommodates pending UTF-8 surrogate pair'
    $p = New-DtJobProgress $origin
    [IO.File]::WriteAllText($outputPath, ('x' * 70000) + "`rcomplete`r")
    Assert-True ((@(Read-DtJobProgressOutput $p @($outputPath)) -join '') -ceq 'complete') 'jump recognizes CR-only line endings'
    $p = New-DtJobProgress $origin
    [IO.File]::WriteAllText($outputPath, ('x' * 70000))
    Assert-True (@(Read-DtJobProgressOutput $p @($outputPath)).Count -eq 0) 'jump without newline emits nothing'
    [IO.File]::AppendAllText($outputPath, "discarded`ncomplete`n")
    Assert-True ((@(Read-DtJobProgressOutput $p @($outputPath)) -join '') -ceq 'complete') 'discard continues until next newline'

    $entry = New-Fixture 'runner-output'
    $rf = $entry.run_folder
    $job = Read-Reply @('start','-RunFolder',$rf,'-Command',"Write-Output 'test_alpha passed'; Start-Sleep 60")
    try {
        $limit = [DateTime]::UtcNow.AddSeconds(15)
        $lines = @()
        do {
            $liveRecord = Get-DtJobRecord $rf $job.job_id
            $lines = @(Read-DtJobProgressOutput $outputProgress @($liveRecord.output_path))
            if ($lines.Count) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $limit)
        Assert-True (($lines -join '') -eq 'test_alpha passed' -and $liveRecord.status -eq 'running') 'real runner exposes small progress lines before job exit'
    } finally { $null = Read-Reply @('cancel','-RunFolder',$rf,'-JobId',$job.job_id) }

    Assert-True ($script:DtJobStallSec -eq 1200 -and $script:DtJobHeartbeatSec -eq 30) 'production stall and heartbeat defaults unchanged'
    Assert-True (-not (Test-DtJobCpuActivity -Cpu 68 -LastCpu 67 -ElapsedSec 30)) 'low CPU loop is not activity'
    Assert-True (Test-DtJobCpuActivity -Cpu 72 -LastCpu 68 -ElapsedSec 30) 'sustained CPU is activity'
    Assert-True (-not (Test-DtJobCpuActivity -Cpu $null -LastCpu 68 -ElapsedSec 30)) 'missing CPU sampler is not activity'
    $entry = New-Fixture 'detect'
    $rf = $entry.run_folder
    $status = Read-Reply @('status','-RunFolder',$rf)
    $null = Read-Reply @('status','-RunFolder',$rf)
    Assert-True (@($status.stalled) -contains 'j-0001') 'status names stalled job'
    Assert-True (@(Get-DtJobEvents $rf | Where-Object type -eq 'job_stalled').Count -eq 1) 'one stalled event across repeated status calls'
    Assert-True ((Get-Content $entry.build_state_path -Raw) -match 'j-0001 stalled.*since .* ET') 'status_line plainly shows age and Eastern time'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $reply = Read-Reply @('wait','-RunFolder',$rf,'-JobId','j-0001','-TimeoutSec','30')
    Assert-True ($reply.result -eq 'stalled' -and $watch.Elapsed.TotalSeconds -lt 15) 'wait returns early on a stall'
    Assert-True ($reply.stalled[0].command -match 'release.py ship' -and $reply.stalled[0].last_output -match 'waiting' -and $reply.stalled[0].process_tree.Count -gt 0 -and $reply.stalled[0].idle_sec -ge 10) 'wait carries command, output, process tree and idle age'
    $ack = Read-Reply @('stall-ack','-RunFolder',$rf,'-JobId','j-0001','-Reason','release lock owned by expected train; checked process','-Until','2')
    Assert-True ($ack.ack.reason -match 'checked process') 'ack records reason and deadline'
    $reply = Read-Reply @('wait','-RunFolder',$rf,'-JobId','j-0001','-TimeoutSec','1')
    Assert-True ($reply.result -eq 'wait_timeout') 'ack suppresses repeated wait interruption'
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ($null -eq (Get-DtJobApprovals $rf).awaiting) 'ack suppresses watcher escalation'
    $stall = Get-DtJobStall $rf 'j-0001'
    $stall.ack.until_utc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o')
    Save-DtJobStall $rf 'j-0001' $stall
    $reply = Read-Reply @('wait','-RunFolder',$rf,'-JobId','j-0001','-TimeoutSec','30')
    Assert-True ($reply.result -eq 'stalled') 'expired acknowledgement interrupts wait again'
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ((Get-DtJobRunState $entry.build_state_path).run_status -eq 'awaiting_danny') 'expired ack becomes a watcher stop'
    $firstDetectStop = (Get-DtJobApprovals $rf).awaiting.seq
    Assert-True ((Get-DtJobApprovals $rf).awaiting.delegated_to -eq 'fixture-director') 'stop routes to live director'
    Assert-True (-not (Test-Path $env:DT_STALL_TEST_DM)) 'no DM while director is alive'

    # Approving alone must not silently suppress a still-expired stall forever.
    $null = Read-Reply @('approve','-RunFolder',$rf,'-Operation','stalled-jobs')
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ((Get-DtJobApprovals $rf).awaiting.seq -gt $firstDetectStop) 'approval without a fresh acknowledgement re-escalates the expired stall'
    $firstDetectStop = (Get-DtJobApprovals $rf).awaiting.seq

    # Director keeps the job, records a fresh deadline, and approves the existing stop.
    $null = Read-Reply @('stall-ack','-RunFolder',$rf,'-JobId','j-0001','-Reason','verified lock owner; keep','-Until','2')
    $null = Read-Reply @('approve','-RunFolder',$rf,'-Operation','stalled-jobs')
    $null = Invoke-WatcherRunTick -Entry $entry
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ($null -eq (Get-DtJobApprovals $rf).awaiting) 'director keep at an open stop sticks across ticks'
    Assert-True ((Get-DtJobStall $rf 'j-0001').ack_count -eq 2) 'acknowledgements counted per episode'
    $stall = Get-DtJobStall $rf 'j-0001'
    $stall.ack.until_utc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o')
    Save-DtJobStall $rf 'j-0001' $stall
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ((Get-DtJobApprovals $rf).awaiting.seq -gt $firstDetectStop) 'a kept stall re-escalates at its next deadline'
    $deadlineSeq = (Get-DtJobApprovals $rf).awaiting.seq
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ((Get-DtJobApprovals $rf).awaiting.seq -eq $deadlineSeq) 'deadline raises one stop, not one per tick'

    # Production clock fixtures: no waiting for real minutes, and no episode identity changes.
    $env:DT_JOB_STALL_SEC = '1200'
    $entry = New-Fixture 'ack-cap' (21 * 60)
    $rf = $entry.run_folder
    $ack = Read-Reply @('stall-ack','-RunFolder',$rf,'-JobId','j-0001','-Reason','quiet database wait','-Until','1440')
    $stall = Get-DtJobStall $rf 'j-0001'
    $cap = (ConvertTo-DtJobUtc $stall.last_activity_utc).AddMinutes(110)
    Assert-True ((ConvertTo-DtJobUtc $ack.ack.until_utc) -eq $cap) '24 hour ack at minute 21 capped at episode minute 110'
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ($null -eq (Get-DtJobApprovals $rf).awaiting) 'first acknowledgement allows bounded quiet work'
    $null = Read-Reply @('stall-ack','-RunFolder',$rf,'-JobId','j-0001','-Reason','renewal','-Until','1440')
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ((Get-DtJobApprovals $rf).awaiting.delegated_to -eq 'fixture-director') 'renewal reaches director immediately'
    $renewalStop = (Get-DtJobApprovals $rf).awaiting.seq
    Assert-True ((Get-DtJobStall $rf 'j-0001').stop_seq -eq $renewalStop -and (Get-DtJobStall $rf 'j-0001').escalated_ack_count -eq 2) 'renewal records its triggering stop and acknowledgement count'
    $null = Read-Reply @('approve','-RunFolder',$rf,'-Operation','stalled-jobs')
    $null = Invoke-WatcherRunTick -Entry $entry
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ($null -eq (Get-DtJobApprovals $rf).awaiting -and (ConvertTo-DtJobUtc (Get-DtJobStall $rf 'j-0001').ack.until_utc) -eq $cap) 'approval of renewal honours capped deadline across ticks'
    $null = Read-Reply @('stall-ack','-RunFolder',$rf,'-JobId','j-0001','-Reason','another renewal','-Until','1440')
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ((Get-DtJobApprovals $rf).awaiting.seq -gt $renewalStop) 'a later renewal forces its own stop exactly once'
    $entry = New-Fixture 'hard-cap' (121 * 60)
    $rf = $entry.run_folder
    $null = Read-Reply @('status','-RunFolder',$rf)
    $stall = Get-DtJobStall $rf 'j-0001'
    # Legacy/unbounded sidecars must also obey the cap during escalation.
    $stall.ack = [pscustomobject]@{ until_utc=[DateTime]::UtcNow.AddDays(1).ToString('o') }
    Save-DtJobStall $rf 'j-0001' $stall
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ((Get-DtJobApprovals $rf).awaiting.operation -eq 'stalled-jobs') 'two hour cap overrides legacy future acknowledgement'
    $null = Read-Reply @('stall-ack','-RunFolder',$rf,'-JobId','j-0001','-Reason','explicit keep beyond two hours','-Until','1440')
    $approvalStart = [DateTime]::UtcNow
    $null = Read-Reply @('approve','-RunFolder',$rf,'-Operation','stalled-jobs')
    $stall = Get-DtJobStall $rf 'j-0001'
    $limit = ConvertTo-DtJobUtc $stall.director_limit_utc
    Assert-True ($limit -ge $approvalStart.AddHours(2) -and $limit -le [DateTime]::UtcNow.AddHours(2) -and (ConvertTo-DtJobUtc $stall.ack.until_utc) -eq $limit) 'explicit keep beyond two hours gets bounded two hour approval window'
    $null = Invoke-WatcherRunTick -Entry $entry
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ($null -eq (Get-DtJobApprovals $rf).awaiting) 'past-cap keep sticks across ticks'
    $stall.director_limit_utc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o')
    Save-DtJobStall $rf 'j-0001' $stall
    $null = Invoke-WatcherRunTick -Entry $entry
    $pastCapSeq = (Get-DtJobApprovals $rf).awaiting.seq
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ((Get-DtJobApprovals $rf).awaiting.seq -eq $pastCapSeq) 'past-cap approval deadline re-escalates once'
    $null = Read-Reply @('stall-ack','-RunFolder',$rf,'-JobId','j-0001','-Reason','keep for five more minutes','-Until','5')
    $nextApproval = [DateTime]::UtcNow
    $null = Read-Reply @('approve','-RunFolder',$rf,'-Operation','stalled-jobs')
    $stall = Get-DtJobStall $rf 'j-0001'
    $approvedDeadline = ConvertTo-DtJobUtc $stall.ack.until_utc
    Assert-True ($approvedDeadline -ge $nextApproval.AddMinutes(5) -and $approvedDeadline -le [DateTime]::UtcNow.AddMinutes(5)) 'subsequent explicit keep honours requested duration inside new bounded window'
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ($null -eq (Get-DtJobApprovals $rf).awaiting) 'subsequent approved window also sticks'
    $env:DT_JOB_STALL_SEC = '10'

    # An already delivered unrelated stop must get exactly one fresh notice for a new stall.
    $entry = New-Fixture 'existing-stop' 35
    $rf = $entry.run_folder
    $approvals = Get-DtJobApprovals $rf
    $approvals.awaiting = [pscustomobject]@{ operation='other-boundary'; message='existing decision'; seq=1; since_utc=[DateTime]::UtcNow.ToString('o') }
    Save-DtJobApprovals $rf $approvals
    $entries = @(Get-DtJobRegistryRuns)
    ($entries | Where-Object run_id -eq 'existing-stop').director.pid = 2147483646
    Save-DtJobRegistryRuns $entries
    $null = Send-DtJobDelegateEscalation $rf 'existing-stop'
    $before = @(Get-Content $env:DT_STALL_TEST_DM).Count
    $null = Invoke-WatcherRunTick -Entry $entry
    $pending = (Get-DtJobApprovals $rf).awaiting
    Assert-True ($pending.operation -eq 'other-boundary' -and $pending.seq -eq 1 -and $pending.stall_notice_seq -gt 1) 'existing boundary preserved with fresh stall notice'
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True (@(Get-Content $env:DT_STALL_TEST_DM).Count -eq ($before + 1)) 'existing delivered stop gets one new stall DM without tick duplicates'
    $baseLength = $pending.message.Length
    foreach ($renewal in 1..3) {
        $null = Read-Reply @('stall-ack','-RunFolder',$rf,'-JobId','j-0001','-Reason','renew while stop remains open','-Until','2')
        $null = Invoke-WatcherRunTick -Entry $entry
    }
    $pending = (Get-DtJobApprovals $rf).awaiting
    Assert-True ($pending.message.Length -eq $baseLength -and $pending.stalled_jobs.Count -eq 1) 'open-stop renewals do not grow message or job list'
    # Recovery followed by a new episode attaches fresh facts, replacing the old job row.
    Set-Beat $rf 0
    $null = Invoke-WatcherRunTick -Entry $entry
    Set-Beat $rf 35
    $null = Invoke-WatcherRunTick -Entry $entry
    $pending = (Get-DtJobApprovals $rf).awaiting
    Assert-True ($pending.stalled_jobs.Count -eq 1 -and ([regex]::Matches($pending.message, 'Stuck on:')).Count -eq 1 -and $pending.message.StartsWith('existing decision')) 'new episode replaces facts and preserves unrelated stop message once'
    Remove-Item $env:DT_STALL_TEST_DM

    # Fail a fresh stall notice after the original boundary was already delivered.
    $entry = New-Fixture 'failed-dm' 0
    $rf = $entry.run_folder
    $entries = @(Get-DtJobRegistryRuns)
    ($entries | Where-Object run_id -eq 'failed-dm').director.pid = 2147483646
    Save-DtJobRegistryRuns $entries
    Set-DtJobRunState -BuildStatePath $entry.build_state_path -RunStatus 'awaiting_danny'
    $approvals = Get-DtJobApprovals $rf
    $approvals.awaiting = [pscustomobject]@{ operation='other-boundary'; message='original'; seq=1; since_utc=[DateTime]::UtcNow.ToString('o') }
    Save-DtJobApprovals $rf $approvals
    $null = Send-DtJobDelegateEscalation $rf 'failed-dm'
    Set-Beat $rf 35
    $env:DT_STALL_TEST_FAIL_DM = '1'
    $null = Invoke-WatcherRunTick -Entry $entry
    $pending = (Get-DtJobApprovals $rf).awaiting
    $noticeKey = "dt-build:failed-dm:awaiting:other-boundary:1:stall:$($pending.stall_notice_seq)"
    Assert-True (-not (Test-AlertDelivered $rf $noticeKey) -and @(Get-Content $env:DT_STALL_TEST_DM).Count -eq 1) 'failed notice remains undelivered despite delivered original boundary'
    Assert-True (@(Get-DtJobNotifications $rf | Where-Object { $_.key -ceq $noticeKey -and $_.status -eq 'pending' }).Count -eq 1) 'failed notice persists its full stall delivery key for retry'
    $env:DT_STALL_TEST_FAIL_DM = '0'
    # Bypass escalation's sender so only the watcher's failed-DM retry path can deliver.
    $savedEscalationRetry = ${function:Invoke-DtJobStallEscalation}
    try {
        function Invoke-DtJobStallEscalation { }
        $null = Invoke-WatcherRunTick -Entry $entry
    } finally { ${function:Invoke-DtJobStallEscalation} = $savedEscalationRetry }
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ((Test-AlertDelivered $rf $noticeKey) -and @(Get-Content $env:DT_STALL_TEST_DM).Count -eq 2) 'watcher retry delivers notice key exactly once'
    Remove-Item $env:DT_STALL_TEST_DM

    $entry = New-Fixture 'tick-errors' 0
    $savedEscalation = ${function:Invoke-DtJobStallEscalation}
    $savedDecision = ${function:Get-WatcherDecision}
    $script:decisionsAfterError = 0
    try {
        function Invoke-DtJobStallEscalation { throw 'DT_JOB_LOCK_TIMEOUT: fixture busy run lock' }
        function Get-WatcherDecision { $script:decisionsAfterError++; [pscustomobject]@{ action='none'; detail='fixture decision reached' } }
        $tick = Invoke-WatcherRun -Entry $entry
        Assert-True (@($tick.step_errors -match 'stall escalation failed.*LOCK_TIMEOUT').Count -eq 1) 'busy stall lock recorded as a step error'
        Assert-True ($script:decisionsAfterError -eq 1 -and $tick.action -eq 'none') 'stall exception does not skip remaining tick decision'
    } finally {
        ${function:Invoke-DtJobStallEscalation} = $savedEscalation
        ${function:Get-WatcherDecision} = $savedDecision
    }

    $entry = New-Fixture 'unread-results' 0
    $rf = $entry.run_folder
    try {
        function Get-WatcherDecision { [pscustomobject]@{ action='notify_interactive'; trigger_seq=(Get-DtJobLastEventSeq $entry.run_folder); detail='fixture idle session' } }
        Add-DtJobEvent -RunFolder $rf -JobId 'j-0001' -Type 'job_stalled' -Status 'stalled' -Reason 'fixture'
        $tick = Invoke-WatcherRunTick -Entry $entry
        Assert-True ($tick.action -eq 'none' -and -not (Test-Path $env:DT_STALL_TEST_DM)) 'stall-only unread events suppress generic idle DM'
        Add-DtJobEvent -RunFolder $rf -JobId 'j-result' -Type 'job_completed' -Status 'succeeded' -Reason 'real result'
        Add-DtJobEvent -RunFolder $rf -JobId 'j-0001' -Type 'job_stalled' -Status 'stalled' -Reason 'later stall'
        $tick = Invoke-WatcherRunTick -Entry $entry
        Assert-True ($tick.action -eq 'notify_interactive' -and @(Get-Content $env:DT_STALL_TEST_DM).Count -eq 1) 'unread result followed by stall still sends idle DM'
    } finally { ${function:Get-WatcherDecision} = $savedDecision }
    Remove-Item $env:DT_STALL_TEST_DM

    # Exercise the actual director watch's snapshot/change functions without its polling loop.
    $tokens = $null; $parseErrors = $null
    $watchAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptDir 'watch-run-state.ps1'), [ref]$tokens, [ref]$parseErrors)
    foreach ($node in $watchAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Get-WatchSnapshot', 'Get-WatchChange') }, $false)) {
        . ([scriptblock]::Create($node.Extent.Text))
    }
    $entry = New-Fixture 'director-notice' 35
    $rf = $entry.run_folder
    Set-DtJobRunState -BuildStatePath $entry.build_state_path -RunStatus 'awaiting_danny'
    $approvals = Get-DtJobApprovals $rf
    $approvals.awaiting = [pscustomobject]@{ operation='other-boundary'; message='existing decision'; seq=1; since_utc=[DateTime]::UtcNow.ToString('o') }
    Save-DtJobApprovals $rf $approvals
    $paths = Get-DtJobPaths $rf
    $beforeNotice = Get-WatchSnapshot
    $null = Invoke-WatcherRunTick -Entry $entry
    $afterNotice = Get-WatchSnapshot
    $change = Get-WatchChange -Before $beforeNotice -Now $afterNotice -NoCoordinatorSince $null
    Assert-True ($change.reason -eq 'awaiting' -and $afterNotice.awaiting -match ':stall:') 'new stall wakes live director even when original boundary and stalled job were already observed'
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ($null -eq (Get-WatchChange -Before $afterNotice -Now (Get-WatchSnapshot) -NoCoordinatorSince $null)) 'repeated tick does not wake director again'
    Assert-True (-not (Test-Path $env:DT_STALL_TEST_DM)) 'new notice to live director never DMs Danny'

    $entry = New-Fixture 'watcher-only' 35
    $rf = $entry.run_folder
    # No coordinator or status action: the real tick reconciles, detects and escalates by itself.
    $coordLock = [IO.File]::Open((Get-DtJobPaths $rf).CoordinatorLock, 'OpenOrCreate', 'ReadWrite', 'None')
    try { $null = Invoke-WatcherRunTick -Entry $entry } finally { $coordLock.Dispose() }
    $pending = (Get-DtJobApprovals $rf).awaiting
    Assert-True ($pending.operation -eq 'stalled-jobs' -and $pending.message -match 'watcher-only.*release.py ship.*cancel/fix or keep') 'watcher alone raises actionable director stop'
    Assert-True ((Get-DtJobRecord $rf 'j-0001').status -eq 'running' -and (Test-DtJobProcessIdentity $PID $entry.director.pid_start_utc)) 'watcher never kills stalled job'
    $firstSeq = $pending.seq
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True ((Get-DtJobApprovals $rf).awaiting.seq -eq $firstSeq) 'repeated tick keeps the same boundary'
    $entries = @(Get-DtJobRegistryRuns)
    ($entries | Where-Object run_id -eq 'watcher-only').director.pid = 2147483646
    Save-DtJobRegistryRuns $entries
    $null = Invoke-WatcherRunTick -Entry $entry
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True (@(Get-Content $env:DT_STALL_TEST_DM).Count -eq 1) 'dead director gets exactly one DM through test transport'
    $null = Read-Reply @('stall-ack','-RunFolder',$rf,'-JobId','j-0001','-Reason','keep until explicit deadline','-Until','2')
    $null = Read-Reply @('stall-ack','-RunFolder',$rf,'-JobId','j-0001','-Reason','renew before approval','-Until','2')
    $null = Read-Reply @('approve','-RunFolder',$rf,'-Operation','stalled-jobs')
    $null = Invoke-WatcherRunTick -Entry $entry
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True (@(Get-Content $env:DT_STALL_TEST_DM).Count -eq 1 -and $null -eq (Get-DtJobApprovals $rf).awaiting) 'dead-director keep causes no per-tick DM or stop'
    $stall = Get-DtJobStall $rf 'j-0001'
    $stall.ack.until_utc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o')
    Save-DtJobStall $rf 'j-0001' $stall
    $null = Invoke-WatcherRunTick -Entry $entry
    $null = Invoke-WatcherRunTick -Entry $entry
    Assert-True (@(Get-Content $env:DT_STALL_TEST_DM).Count -eq 2) 'dead director receives one additional DM at new deadline'

    Set-Beat $rf 0
    $status = Read-Reply @('status','-RunFolder',$rf)
    Assert-True ($status.stalled.Count -eq 0 -and $null -eq (Get-DtJobStall $rf 'j-0001')) 'resumed activity clears episode and acknowledgement'
    Assert-True (@(Get-DtJobEvents $rf | Where-Object type -eq 'job_stall_cleared').Count -eq 1) 'resumed activity records one clear event'
    Set-Beat $rf 15
    $null = Read-Reply @('status','-RunFolder',$rf)
    Assert-True (@(Get-DtJobEvents $rf | Where-Object type -eq 'job_stalled').Count -eq 2) 'new stall episode rearms event dedupe'
} finally {
    foreach ($child in $script:children) {
        if (-not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }
        $child.Dispose()
    }
    Remove-Item $tempRoot -Recurse -Force
}
Write-Output "SUMMARY: $script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
