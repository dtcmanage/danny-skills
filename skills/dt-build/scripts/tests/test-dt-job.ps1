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
$dtJob = Join-Path $scriptDir 'dt-job.ps1'
$readEvidence = Join-Path $scriptDir 'read-evidence.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-job-tests-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-RunFolder {
    param([string]$Name)
    $path = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Invoke-DtJob {
    param([string[]]$Arguments)
    $raw = & pwsh -NoProfile -File $dtJob @Arguments -Json
    if ($LASTEXITCODE -ne 0) { throw "dt-job $($Arguments -join ' ') exited $LASTEXITCODE" }
    return (($raw -join "`n") | ConvertFrom-Json)
}

function Get-JobRecord {
    param([string]$RunFolder, [string]$JobId)
    return (Get-Content -Raw -LiteralPath (Join-Path $RunFolder "jobs/$JobId.json") | ConvertFrom-Json)
}

function Wait-JobState {
    param([string]$RunFolder, [string]$JobId, [scriptblock]$Until, [int]$TimeoutSec = 60)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        $record = Get-JobRecord -RunFolder $RunFolder -JobId $JobId
        if (& $Until $record) { return $record }
        Start-Sleep -Milliseconds 250
    }
    throw "TIMEOUT waiting on $JobId in $RunFolder (status $((Get-JobRecord -RunFolder $RunFolder -JobId $JobId).status))"
}

function Wait-JobTerminal {
    param([string]$RunFolder, [string]$JobId, [int]$TimeoutSec = 60)
    return (Wait-JobState -RunFolder $RunFolder -JobId $JobId -TimeoutSec $TimeoutSec -Until { param($r) $r.status -notin @('queued', 'running') })
}

function Test-ProcessGone {
    param($ProcessId)
    if (-not $ProcessId) { return $true }
    return ($null -eq (Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue))
}

$exitCode = 0
try {
    # Start and succeed (nested pwsh command, the shape the wrappers use).
    $rf = New-RunFolder 'succeed'
    $start = Invoke-DtJob @('start', '-RunFolder', $rf, '-Kind', 'test', '-Category', 'fixture', '-Command', 'pwsh -NoProfile -Command "Start-Sleep 1; ''ok''"')
    Assert-True ($start.job_id -eq 'j-0001') 'first job id is j-0001'
    Assert-True ($start.status -in @('running', 'queued')) 'start returns at once with a live status'
    $record = Wait-JobTerminal -RunFolder $rf -JobId $start.job_id
    Assert-True ($record.status -eq 'succeeded') "succeeded job status was $($record.status)"
    Assert-True ($record.exit_code -eq 0) 'succeeded job exit code 0'
    Assert-True ([bool]$record.pid -and [bool]$record.process_start_utc) 'pid and process_start_utc recorded'
    Assert-True ([bool]$record.ended -and [bool]$record.command_sha256 -and $record.kind -eq 'test' -and $record.category -eq 'fixture') 'ledger fields recorded'
    $envelope = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', $start.job_id)
    Assert-True ($envelope.verdict -eq 'pass' -and $envelope.exit_code -eq 0) 'envelope verdict pass'
    Assert-True (@($envelope.excerpt) -contains 'ok') 'envelope excerpt holds stdout tail'
    Assert-True ((Test-Path -LiteralPath $envelope.evidence.stdout) -and -not $envelope.truncated) 'envelope names stdout evidence and is not truncated'
    $events = @(Get-Content -LiteralPath (Join-Path $rf 'jobs/events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    $seqs = @($events | ForEach-Object { [int]$_.seq })
    Assert-True (($seqs -join ',') -eq ((1..$seqs.Count) -join ',')) 'event seq is monotonic from 1'
    Assert-True ((@($events | Where-Object { -not ($_.job_id -and $_.ts_utc -and $_.type -and $_.status) })).Count -eq 0) 'every event carries job_id, ts_utc, type, status'
    $all = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True ($all.job_count -eq 1 -and $all.jobs[0].status -eq 'succeeded') 'run status lists jobs'

    # Changed files reported from the job's changed-files.txt.
    $changedJob = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "Set-Content -LiteralPath (Join-Path `$env:DT_JOB_DIR 'changed-files.txt') -Value 'src/a.txt'; 'done'")
    Wait-JobTerminal -RunFolder $rf -JobId $changedJob.job_id | Out-Null
    $envelope = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', $changedJob.job_id)
    Assert-True (@($envelope.changed_files) -contains 'src/a.txt') 'envelope reports changed files'

    # Failure exit code.
    $rf = New-RunFolder 'fail'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'pwsh -NoProfile -Command "exit 3"')
    $record = Wait-JobTerminal -RunFolder $rf -JobId $job.job_id
    Assert-True ($record.status -eq 'failed' -and $record.exit_code -eq 3) "failure recorded exit 3 (status $($record.status), exit $($record.exit_code))"
    $envelope = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', $job.job_id)
    Assert-True ($envelope.verdict -eq 'fail' -and @($envelope.blockers).Count -ge 1) 'failed envelope names a blocker'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "[Console]::Error.WriteLine('boom on stderr'); exit 2")
    Wait-JobTerminal -RunFolder $rf -JobId $job.job_id | Out-Null
    $envelope = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', $job.job_id)
    Assert-True ($envelope.exit_code -eq 2 -and (@($envelope.stderr_excerpt) -contains 'boom on stderr')) 'failed envelope carries a stderr tail'

    # Exit semantics: the final statement decides, as with pwsh -Command.
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "cmd /c exit 3; 'done'")
    $record = Wait-JobTerminal -RunFolder $rf -JobId $job.job_id
    Assert-True ($record.status -eq 'succeeded' -and $record.exit_code -eq 0) "earlier native failure with a succeeding final statement exits 0 ($($record.status), $($record.exit_code))"
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'first'; cmd /c exit 4")
    $record = Wait-JobTerminal -RunFolder $rf -JobId $job.job_id
    Assert-True ($record.status -eq 'failed' -and $record.exit_code -eq 4) "failing final native command keeps its exit code ($($record.status), $($record.exit_code))"

    # Timeout.
    $rf = New-RunFolder 'timeout'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Start-Sleep 30', '-TimeoutSec', '2')
    $record = Wait-JobTerminal -RunFolder $rf -JobId $job.job_id -TimeoutSec 30
    Assert-True ($record.status -eq 'timeout') "timeout status was $($record.status)"
    Assert-True (Test-ProcessGone $record.pid) 'timed-out process was stopped'

    # Dependency chain: a failure blocks two levels downstream.
    $rf = New-RunFolder 'deps'
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Start-Sleep 1; exit 1')
    $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'b'", '-DependsOn', $a.job_id)
    $c = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'c'", '-DependsOn', $b.job_id)
    Assert-True ($b.status -eq 'queued' -and $c.status -eq 'queued') 'dependents wait queued'
    Wait-JobTerminal -RunFolder $rf -JobId $a.job_id | Out-Null
    $rb = Wait-JobTerminal -RunFolder $rf -JobId $b.job_id
    $rc = Wait-JobTerminal -RunFolder $rf -JobId $c.job_id
    Assert-True ($rb.status -eq 'blocked' -and $rb.status_reason -match [regex]::Escape($a.job_id)) "level-1 dependent blocked with reason ($($rb.status): $($rb.status_reason))"
    Assert-True ($rc.status -eq 'blocked' -and $rc.status_reason -match [regex]::Escape($b.job_id)) "level-2 dependent blocked with reason ($($rc.status): $($rc.status_reason))"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rf "jobs/$($b.job_id)/stdout.log"))) 'blocked job never ran'
    $late = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'late'", '-DependsOn', $c.job_id)
    Assert-True ($late.status -eq 'blocked') 'job depending on an already-blocked job is blocked at start'
    $okA = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'a2'")
    $okB = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'b2'", '-DependsOn', $okA.job_id)
    Assert-True ((Wait-JobTerminal -RunFolder $rf -JobId $okB.job_id).status -eq 'succeeded') 'dependent starts after its dependency succeeds'

    # Mutation key: a second job on the same key queues until the key frees.
    $rf = New-RunFolder 'mutates'
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Start-Sleep 3', '-Mutates', 'worktree:main')
    $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'b'", '-Mutates', 'worktree:main')
    Assert-True ($a.status -eq 'running') 'key holder runs'
    Assert-True ($b.status -eq 'queued') 'second job on the same key queues'
    $other = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'other'", '-Mutates', 'worktree:other')
    Assert-True ($other.status -eq 'running') 'job on a different key runs'
    $ra = Wait-JobTerminal -RunFolder $rf -JobId $a.job_id
    $rb = Wait-JobTerminal -RunFolder $rf -JobId $b.job_id
    Assert-True ($rb.status -eq 'succeeded') "queued key job ran after release ($($rb.status))"
    Assert-True (([DateTime]$rb.started).ToUniversalTime() -ge ([DateTime]$ra.ended).ToUniversalTime()) 'second key job started after the first ended'
    Assert-True ((@(Get-ChildItem -LiteralPath (Join-Path $rf 'jobs/locks') -Filter 'key-*.lock')).Count -eq 0) 'key locks released'

    # Cancel queued and cancel running.
    $rf = New-RunFolder 'cancel'
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Start-Sleep 3', '-Mutates', 'k')
    $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'b'", '-Mutates', 'k')
    $cb = Invoke-DtJob @('cancel', '-RunFolder', $rf, '-JobId', $b.job_id)
    Assert-True ($cb.status -eq 'cancelled') 'queued job cancelled'
    Wait-JobTerminal -RunFolder $rf -JobId $a.job_id | Out-Null
    Start-Sleep -Seconds 2
    Assert-True ((Get-JobRecord -RunFolder $rf -JobId $b.job_id).status -eq 'cancelled') 'cancelled queued job stays cancelled after its key frees'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rf "jobs/$($b.job_id)/stdout.log"))) 'cancelled queued job never launched'
    $c = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Start-Sleep 60', '-Mutates', 'k2')
    $rc = Wait-JobState -RunFolder $rf -JobId $c.job_id -Until { param($r) [bool]$r.pid }
    $cc = Invoke-DtJob @('cancel', '-RunFolder', $rf, '-JobId', $c.job_id)
    Assert-True ($cc.status -eq 'cancelled') 'running job cancelled'
    Start-Sleep -Seconds 1
    Assert-True ((Test-ProcessGone $rc.pid) -and (Test-ProcessGone $rc.runner_pid)) 'cancelled running job processes stopped'
    Assert-True ((Get-JobRecord -RunFolder $rf -JobId $c.job_id).status -eq 'cancelled') 'cancel is not overwritten by the runner'
    Assert-True (-not (Test-Path -Path (Join-Path $rf 'jobs/locks/key-k2-*.lock'))) 'cancel frees the mutation key'

    # Race: cancel against launch. Whatever wins, a cancelled job never does its work.
    foreach ($delayMs in @(700, 1100, 1500)) {
        $rf = New-RunFolder "race-$delayMs"
        $marker = Join-Path $rf 'marker.txt'
        $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Start-Sleep 1', '-Mutates', 'race')
        $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "Start-Sleep 2; Set-Content -LiteralPath '$marker' -Value 'ran'", '-Mutates', 'race')
        Start-Sleep -Milliseconds $delayMs
        $cancel = Start-Process -FilePath ([System.Environment]::ProcessPath) -ArgumentList @('-NoProfile', '-File', "`"$dtJob`"", 'cancel', '-RunFolder', "`"$rf`"", '-JobId', $b.job_id, '-Json') -PassThru -WindowStyle Hidden
        $cancel.WaitForExit()
        Wait-JobTerminal -RunFolder $rf -JobId $a.job_id | Out-Null
        Start-Sleep -Seconds 3
        $rb = Get-JobRecord -RunFolder $rf -JobId $b.job_id
        Assert-True ($rb.status -eq 'cancelled') "race ($delayMs ms): job ended cancelled ($($rb.status))"
        Assert-True (-not (Test-Path -LiteralPath $marker)) "race ($delayMs ms): cancelled job never did its work"
    }

    # Reconcile: a killed job becomes orphaned (never succeeded) and its keys free.
    $rf = New-RunFolder 'orphan'
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Start-Sleep 60', '-Mutates', 'shared')
    $ra = Wait-JobState -RunFolder $rf -JobId $a.job_id -Until { param($r) [bool]$r.pid }
    $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'after'", '-Mutates', 'shared')
    Assert-True ($b.status -eq 'queued') 'job queues behind the soon-killed key holder'
    Stop-Process -Id ([int]$ra.runner_pid) -Force
    Stop-Process -Id ([int]$ra.pid) -Force
    Start-Sleep -Milliseconds 500
    $rec = Invoke-DtJob @('reconcile', '-RunFolder', $rf)
    Assert-True (@($rec.orphaned) -contains $a.job_id) 'reconcile reports the orphan'
    $ra = Get-JobRecord -RunFolder $rf -JobId $a.job_id
    Assert-True ($ra.status -eq 'orphaned') "killed job is orphaned ($($ra.status))"
    Assert-True ((Wait-JobTerminal -RunFolder $rf -JobId $b.job_id).status -eq 'succeeded') 'reconcile freed the key and started the queued job'

    # PID reuse: a live PID whose start time does not match is not alive.
    $rf = New-RunFolder 'pid-reuse'
    $now = [DateTime]::UtcNow.AddMinutes(-10).ToString('o')
    $base = [ordered]@{ run_id = 'pid-reuse'; kind = 'command'; category = $null; vendor = $null; model = $null; runner_pid = $null; runner_start_utc = $null; command_sha256 = 'x'; depends_on = @(); mutates = @(); status = 'running'; status_reason = $null; exit_code = $null; timeout_sec = 0; working_directory = $rf; output_path = 'x'; stderr_path = 'x'; summary_path = 'x'; queued = $now; started = $now; ended = $null; last_progress = $now }
    $reused = [ordered]@{ job_id = 'j-0001'; pid = $PID; process_start_utc = '2000-01-01T00:00:00.0000000Z' } + $base
    $live = [ordered]@{ job_id = 'j-0002'; pid = $PID; process_start_utc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') } + $base
    Write-Utf8 (Join-Path $rf 'jobs/j-0001.json') ($reused | ConvertTo-Json)
    Write-Utf8 (Join-Path $rf 'jobs/j-0002.json') ($live | ConvertTo-Json)
    $rec = Invoke-DtJob @('reconcile', '-RunFolder', $rf)
    Assert-True ((Get-JobRecord -RunFolder $rf -JobId 'j-0001').status -eq 'orphaned') 'start-time mismatch on a live PID is not alive'
    Assert-True ((Get-JobRecord -RunFolder $rf -JobId 'j-0002').status -eq 'running') 'matching PID and start time is alive'

    # Envelope cap: one very long line and many lines.
    $rf = New-RunFolder 'envelope'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "1..3000 | ForEach-Object { 'y' * 300 }; 'z' * 5000")
    Wait-JobTerminal -RunFolder $rf -JobId $job.job_id | Out-Null
    $raw = (& pwsh -NoProfile -File $dtJob status -RunFolder $rf -JobId $job.job_id -Json) -join "`n"
    $envelope = $raw | ConvertFrom-Json
    Assert-True ([System.Text.Encoding]::UTF8.GetByteCount($raw) -le 8192) "envelope within 8 KB ($([System.Text.Encoding]::UTF8.GetByteCount($raw)) bytes)"
    Assert-True ($envelope.truncated -eq $true) 'envelope marks truncation'
    Assert-True (@($envelope.truncated_evidence) -contains $envelope.evidence.stdout) 'truncation names the full stdout evidence path'
    Assert-True ((@($envelope.excerpt | Where-Object { $_.Length -gt 400 })).Count -eq 0) 'every envelope line within 400 characters'
    Assert-True (@($envelope.excerpt).Count -ge 1 -and $envelope.excerpt[-1].StartsWith('zzz')) 'excerpt keeps the stdout tail'
    $summary = Get-Content -Raw -LiteralPath (Get-JobRecord -RunFolder $rf -JobId $job.job_id).summary_path | ConvertFrom-Json
    Assert-True ($summary.status -eq 'succeeded') 'runner wrote the bounded summary'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "1..3000 | ForEach-Object { 'y' * 300 }; 1..200 | ForEach-Object { [Console]::Error.WriteLine('e' * 600) }; exit 1")
    Wait-JobTerminal -RunFolder $rf -JobId $job.job_id | Out-Null
    $raw = (& pwsh -NoProfile -File $dtJob status -RunFolder $rf -JobId $job.job_id -Json) -join "`n"
    $envelope = $raw | ConvertFrom-Json
    Assert-True ([System.Text.Encoding]::UTF8.GetByteCount($raw) -le 8192) "failed envelope with stderr within 8 KB ($([System.Text.Encoding]::UTF8.GetByteCount($raw)) bytes)"
    Assert-True (@($envelope.stderr_excerpt).Count -ge 1 -and (@($envelope.stderr_excerpt | Where-Object { $_.Length -gt 400 })).Count -eq 0) 'stderr tail present and line-capped'
    Assert-True (@($envelope.truncated_evidence) -contains $envelope.evidence.stderr) 'stderr truncation names the full stderr evidence path'
    $long = [ordered]@{ job_id = 'j-0099'; status = 'failed'; status_reason = ('r' * 1000); exit_code = 1 }
    Write-Utf8 (Join-Path $rf 'jobs/j-0099.json') ($long | ConvertTo-Json)
    $envelope = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', 'j-0099')
    Assert-True ($envelope.truncated -eq $true -and $envelope.status_reason.Length -le 400) 'cut status_reason marks truncation'
    Assert-True (@($envelope.truncated_evidence) -contains $envelope.evidence.job_file) 'cut status_reason names the job file as evidence'

    # read-evidence: cap, log entry, repeat-read warning.
    $rf = New-RunFolder 'evidence'
    $evidenceFile = Join-Path $rf 'big.log'
    $lines = [System.Collections.Generic.List[string]]::new()
    for ($i = 1; $i -le 5000; $i++) { $lines.Add(('line {0} ' -f $i) + ('x' * 100)) }
    $lines[9] = 'LONG ' + ('q' * 1000)
    Write-Utf8 $evidenceFile (($lines -join "`n") + "`n")
    $raw = (& pwsh -NoProfile -File $readEvidence -RunFolder $rf -Path $evidenceFile -Lines '1-5000' -Json) -join "`n"
    $read = $raw | ConvertFrom-Json
    Assert-True ([System.Text.Encoding]::UTF8.GetByteCount($raw) -le 16384) "read-evidence reply within 16 KB ($([System.Text.Encoding]::UTF8.GetByteCount($raw)) bytes)"
    Assert-True ($read.truncated -eq $true -and $read.evidence_path -eq $evidenceFile) 'read-evidence marks truncation with the evidence path'
    Assert-True ((@($read.lines | Where-Object { $_.Length -gt 400 })).Count -eq 0) 'read-evidence lines within 400 characters'
    $grep = (& pwsh -NoProfile -File $readEvidence -RunFolder $rf -Path $evidenceFile -Grep '^LONG' -Context 1 -Json) -join "`n" | ConvertFrom-Json
    Assert-True (@($grep.lines).Count -eq 3 -and $grep.lines[1].StartsWith('10: LONG') -and $grep.truncated) 'grep with context returns the hit and neighbours, line-capped'
    $first = (& pwsh -NoProfile -File $readEvidence -RunFolder $rf -Path $evidenceFile -Lines '20-22' -Json) -join "`n" | ConvertFrom-Json
    Assert-True (@($first.warnings).Count -eq 0 -and @($first.lines).Count -eq 3) 'first read of a range has no warning'
    $second = (& pwsh -NoProfile -File $readEvidence -RunFolder $rf -Path $evidenceFile -Lines '20-22' -Json) -join "`n" | ConvertFrom-Json
    Assert-True ((@($second.warnings) -join ' ') -match 'repeat_read') 'repeat read of an unchanged range warns'
    Add-Content -LiteralPath $evidenceFile -Value 'appended'
    $third = (& pwsh -NoProfile -File $readEvidence -RunFolder $rf -Path $evidenceFile -Lines '20-22' -Json) -join "`n" | ConvertFrom-Json
    Assert-True (@($third.warnings).Count -eq 0) 'read after the file changed is not a repeat'
    $log = @(Get-Content -LiteralPath (Join-Path $rf 'jobs/reads.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($log.Count -eq 5) "reads.jsonl has one entry per call ($($log.Count))"
    Assert-True ((@($log | Where-Object { -not ($_.path -and $_.sha256 -and $null -ne $_.bytes_returned -and $_.selector) })).Count -eq 0) 'each read log entry has path, selector, sha256, bytes'
    Assert-True ($log[1].selector.mode -eq 'grep' -and $log[1].selector.pattern -eq '^LONG' -and $log[3].repeat_read -eq $true) 'read log records pattern and repeat flag'
    # Text mode: the warning and the truncation marker count against the 16 KB cap.
    $rf = New-RunFolder 'evidence-text'
    & pwsh -NoProfile -File $readEvidence -RunFolder $rf -Path $evidenceFile -Lines '1-5000' | Out-Null
    $text = @(& pwsh -NoProfile -File $readEvidence -RunFolder $rf -Path $evidenceFile -Lines '1-5000')
    $textBytes = ($text | ForEach-Object { [System.Text.Encoding]::UTF8.GetByteCount($_) + [Environment]::NewLine.Length } | Measure-Object -Sum).Sum
    Assert-True ($textBytes -le 16384) "text-mode read with warning and marker within 16 KB ($textBytes bytes)"
    Assert-True ($text[0].StartsWith('WARNING repeat_read') -and $text[-1].StartsWith('[truncated: true')) 'text-mode read shows the warning and the truncation marker'

    # Concurrent readers: a tight status loop never turns a finishing job into a failure.
    $rf = New-RunFolder 'contention'
    $stopFile = Join-Path $rf 'stop.txt'
    $loopScript = Join-Path $tempRoot 'status-loop.ps1'
    Write-Utf8 $loopScript @'
param([string]$DtJob, [string]$RunFolder, [string]$Stop)
. $DtJob -RunFolder $RunFolder
$jobsDir = Join-Path $RunFolder 'jobs'
while (-not (Test-Path -LiteralPath $Stop)) {
    foreach ($f in @(Get-ChildItem -LiteralPath $jobsDir -Filter 'j-*.json' -File -ErrorAction SilentlyContinue)) {
        # A slow foreign reader (Get-Content's share mode) holding the record open blocks a replace.
        try { $held = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite'); Start-Sleep -Milliseconds 20; $held.Dispose() } catch { }
        try { New-DtJobEnvelope -RunFolder $RunFolder -Record (Read-DtJobText -Path $f.FullName | ConvertFrom-Json) | Out-Null } catch { }
    }
}
'@
    New-Item -ItemType Directory -Path (Join-Path $rf 'jobs') -Force | Out-Null
    $loop = Start-Process -FilePath ([System.Environment]::ProcessPath) -ArgumentList @('-NoProfile', '-File', "`"$loopScript`"", '-DtJob', "`"$dtJob`"", '-RunFolder', "`"$rf`"", '-Stop', "`"$stopFile`"") -PassThru -WindowStyle Hidden
    try {
        $ids = @(1..8 | ForEach-Object { (Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "Start-Sleep -Milliseconds 300; 'ok $_'")).job_id })
        $states = @($ids | ForEach-Object { (Wait-JobTerminal -RunFolder $rf -JobId $_).status })
    }
    finally {
        Write-Utf8 $stopFile 'stop'
        if (-not $loop.WaitForExit(10000)) { $loop.Kill() }
    }
    Assert-True ((@($states | Where-Object { $_ -ne 'succeeded' })).Count -eq 0) "every job under a tight status loop succeeded ($($states -join ','))"
    Assert-True ((@(Get-ChildItem -LiteralPath (Join-Path $rf 'jobs') -Recurse -File -Filter '*.tmp')).Count -eq 0) 'no stray temp files after contended writes'

    # Lists under pwsh -File: comma-separated keys and dependencies split.
    $rf = New-RunFolder 'lists'
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Start-Sleep 3', '-Mutates', 'a,b')
    $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'b'", '-Mutates', 'a')
    Assert-True ((@((Get-JobRecord -RunFolder $rf -JobId $a.job_id).mutates) -join '|') -eq 'a|b') 'comma-separated -Mutates splits into two keys'
    Assert-True ($a.status -eq 'running' -and $b.status -eq 'queued') 'one-key job queues behind the two-key job sharing a key'
    $c = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'c'", '-DependsOn', "$($a.job_id), $($b.job_id)")
    Assert-True ((@((Get-JobRecord -RunFolder $rf -JobId $c.job_id).depends_on) -join '|') -eq "$($a.job_id)|$($b.job_id)") 'comma-separated -DependsOn resolves both jobs'
    Assert-True ((Wait-JobTerminal -RunFolder $rf -JobId $c.job_id).status -eq 'succeeded') 'job with two dependencies runs after both succeed'

    # Environment pass-through: allow-listed caller variables reach the job; secrets only when named.
    $rf = New-RunFolder 'env'
    $env:DT_PROBE_VAR = 'hello'; $env:PROBE_PASS = 'passed'; $env:DT_PROBE_TOKEN = 'unnamed-secret'; $env:PROBE_API_KEY = 'named-secret'
    try {
        $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-PassEnv', 'PROBE_PASS,PROBE_API_KEY', '-Command', "'env=[{0}][{1}][{2}][{3}]' -f `$env:DT_PROBE_VAR, `$env:PROBE_PASS, `$env:DT_PROBE_TOKEN, `$env:PROBE_API_KEY")
    }
    finally {
        Remove-Item Env:DT_PROBE_VAR, Env:PROBE_PASS, Env:DT_PROBE_TOKEN, Env:PROBE_API_KEY -ErrorAction SilentlyContinue
    }
    Wait-JobTerminal -RunFolder $rf -JobId $job.job_id | Out-Null
    $stdout = Get-Content -Raw -LiteralPath (Join-Path $rf "jobs/$($job.job_id)/stdout.log")
    Assert-True ($stdout.Trim() -eq 'env=[hello][passed][][named-secret]') "caller environment reaches the job ($($stdout.Trim()))"
    Assert-True (-not ((Get-Content -Raw -LiteralPath (Join-Path $rf "jobs/$($job.job_id)/spec.json")) -match 'unnamed-secret')) 'unnamed secret-looking variable never written to the spec'

    # Runner died but child lives: reconcile expires it past timeout plus grace.
    $rf = New-RunFolder 'expire'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Start-Sleep 120', '-TimeoutSec', '20', '-Mutates', 'exp')
    $record = Wait-JobState -RunFolder $rf -JobId $job.job_id -Until { param($r) [bool]$r.pid }
    Stop-Process -Id ([int]$record.runner_pid) -Force
    Start-Sleep -Milliseconds 500
    Invoke-DtJob @('reconcile', '-RunFolder', $rf) | Out-Null
    Assert-True ((Get-JobRecord -RunFolder $rf -JobId $job.job_id).status -eq 'running') 'live child within its timeout stays running'
    $record = Get-JobRecord -RunFolder $rf -JobId $job.job_id
    $record.started = [DateTime]::UtcNow.AddSeconds(-60).ToString('o')
    Write-Utf8 (Join-Path $rf "jobs/$($job.job_id).json") ($record | ConvertTo-Json -Depth 8)
    Invoke-DtJob @('reconcile', '-RunFolder', $rf) | Out-Null
    $after = Get-JobRecord -RunFolder $rf -JobId $job.job_id
    Assert-True ($after.status -eq 'timeout' -and $after.status_reason -match 'expired') "expired job marked timeout ($($after.status): $($after.status_reason))"
    Start-Sleep -Milliseconds 500
    Assert-True (Test-ProcessGone $record.pid) 'expired child process killed'
    Assert-True (-not (Test-Path -Path (Join-Path $rf 'jobs/locks/key-exp-*.lock'))) 'expired job frees its key'

    # A partial last line in events.jsonl does not wedge later transitions.
    $rf = New-RunFolder 'partial-event'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'one'")
    Wait-JobTerminal -RunFolder $rf -JobId $job.job_id | Out-Null
    $eventsPath = Join-Path $rf 'jobs/events.jsonl'
    $lastSeq = [int](@(Get-Content -LiteralPath $eventsPath | ForEach-Object { $_ | ConvertFrom-Json })[-1].seq)
    [System.IO.File]::AppendAllText($eventsPath, '{"seq":99,"job_')
    $job2 = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'two'")
    Assert-True ((Wait-JobTerminal -RunFolder $rf -JobId $job2.job_id).status -eq 'succeeded') 'transition succeeds after a partial event line'
    $parsed = @(Get-Content -LiteralPath $eventsPath | ForEach-Object { try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { } })
    $after = @($parsed | Where-Object { $_.job_id -eq $job2.job_id } | ForEach-Object { [int]$_.seq })
    Assert-True ($after.Count -ge 1 -and $after[0] -eq $lastSeq + 1 -and (($after -join ',') -eq (($lastSeq + 1)..($lastSeq + $after.Count) -join ','))) "events continue at the next seq ($lastSeq -> $($after -join ','))"

    Write-Output 'PASS: dt-job suite'
}
catch {
    Write-Output "FAIL: $($_.Exception.Message)"
    Write-Output $_.ScriptStackTrace
    $exitCode = 1
}
finally {
    Write-Output "SUMMARY: $script:passed passed"
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

exit $exitCode
