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

function Get-EvidenceError {
    param([hashtable]$Arguments)
    # Match a child pwsh's working directory while capturing the unformatted exception.
    $originalDirectory = [Environment]::CurrentDirectory
    try {
        [Environment]::CurrentDirectory = (Get-Location).ProviderPath
        & $readEvidence @Arguments | Out-Null
    }
    catch { return $_.Exception.Message }
    finally { [Environment]::CurrentDirectory = $originalDirectory }
    throw 'ASSERT_FAIL: read-evidence unexpectedly succeeded'
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

# A test that needs a job to be running holds it on a file, never on the clock.
function New-HeldJobCommand {
    param([string]$ReleasePath, [int]$ExitCode = 0)
    return "`$deadline = [DateTime]::UtcNow.AddSeconds(120); while (-not (Test-Path -LiteralPath '$($ReleasePath.Replace("'", "''"))') -and [DateTime]::UtcNow -lt `$deadline) { Start-Sleep -Milliseconds 100 }; exit $ExitCode"
}

function Test-ProcessGone {
    param($ProcessId)
    if (-not $ProcessId) { return $true }
    return ($null -eq (Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue))
}

$exitCode = 0
$junctionLink = $null
$pinEnvNames = @('DT_BUILD_STATE_DIR', 'DT_BUILD_COORDINATOR_ID', 'DT_JOB_ID', 'DT_BUILD_RUN_PIN_VENDOR', 'DT_BUILD_RUN_PIN_MODEL')
$pinSavedEnv = @{}
foreach ($name in $pinEnvNames) { $pinSavedEnv[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    $env:DT_BUILD_STATE_DIR = Join-Path $tempRoot 'registry'
    Remove-Item Env:DT_BUILD_COORDINATOR_ID, Env:DT_JOB_ID -ErrorAction SilentlyContinue
    $pinRun = New-RunFolder 'pin-run'
    $pinState = Join-Path $pinRun '_build-state.md'
    Write-Utf8 $pinState "updated_utc: fixture`nrun_status: runnable`nlast_consumed_event_seq: 0`n"
    $registrationArgs = @('register-run', '-RunFolder', $pinRun, '-RunId', 'pin-run', '-BuildStatePath', $pinState, '-PinnedHost', 'codex', '-Managed')
    $raw = & pwsh -NoProfile -File $dtJob pin -RunFolder $pinRun -Vendor codex -Model fixture *> $null
    Assert-True ($LASTEXITCODE -ne 0) 'pin refuses an unregistered run'
    $null = Invoke-DtJob $registrationArgs
    foreach ($missing in @(@('-Vendor', 'codex'), @('-Model', 'fixture'))) {
        $raw = & pwsh -NoProfile -File $dtJob pin -RunFolder $pinRun @missing 2>&1
        Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_USAGE') 'pin requires both vendor and model'
    }
    $pinned = Invoke-DtJob @('pin', '-RunFolder', $pinRun, '-Vendor', 'codex', '-Model', 'gpt-fixture')
    Assert-True ($pinned.pin.vendor -eq 'codex' -and $pinned.pin.model -eq 'gpt-fixture' -and [bool]$pinned.pin.set_utc) 'pin saves vendor model and timestamp'
    $pinStatus = Invoke-DtJob @('status', '-RunFolder', $pinRun)
    Assert-True ($pinStatus.pin -eq 'codex gpt-fixture') 'run status carries pin label'
    foreach ($identity in @('DT_BUILD_COORDINATOR_ID', 'DT_JOB_ID')) {
        try {
            [Environment]::SetEnvironmentVariable($identity, 'fixture')
            $raw = & pwsh -NoProfile -File $dtJob pin -RunFolder $pinRun -Clear 2>&1
            Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_OPERATOR_ONLY') "$identity cannot clear a pin"
        } finally { [Environment]::SetEnvironmentVariable($identity, $null) }
    }
    $raw = & pwsh -NoProfile -File $dtJob start -RunFolder $pinRun -Kind worker -Vendor claude -Command "'refused'" 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_PIN_VENDOR: run is pinned to codex \(gpt-fixture\); worker vendor claude refused') 'worker vendor mismatch refused before job creation'
    $env:DT_BUILD_RUN_PIN_VENDOR = 'claude'; $env:DT_BUILD_RUN_PIN_MODEL = 'stale'
    foreach ($kind in @('worker', 'command')) {
        $pinJob = Invoke-DtJob @('start', '-RunFolder', $pinRun, '-Kind', $kind, '-Vendor', 'codex', '-Command', "'pinned'")
        $spec = Get-Content -Raw (Join-Path $pinRun "jobs/$($pinJob.job_id)/spec.json") | ConvertFrom-Json
        Assert-True ($spec.environment.DT_BUILD_RUN_PIN_VENDOR -eq 'codex' -and $spec.environment.DT_BUILD_RUN_PIN_MODEL -eq 'gpt-fixture') "$kind spec carries authoritative registry pin"
        $null = Wait-JobTerminal $pinRun $pinJob.job_id
        $pinWait = Invoke-DtJob @('wait', '-RunFolder', $pinRun, '-JobId', $pinJob.job_id, '-All', '-TimeoutSec', '1')
        Assert-True ($pinWait.pin -eq 'codex gpt-fixture') "$kind wait carries pin label"
        $singleWait = Invoke-DtJob @('wait', '-RunFolder', $pinRun, '-JobId', $pinJob.job_id, '-TimeoutSec', '1')
        Assert-True ($singleWait.result -eq 'finished' -and $singleWait.pin -eq 'codex gpt-fixture') "$kind single-job wait needs neither -Any nor -All"
    }
    $null = Invoke-DtJob @('lease', '-RunFolder', $pinRun, '-Action', 'acquire', '-CoordinatorId', 'pin-reader', '-Host', 'codex', '-LaunchedBy', 'watcher')
    $resumeArgs = @('-RunFolder', $pinRun, '-RunId', 'pin-run', '-BuildStatePath', $pinState, '-CoordinatorId', 'pin-reader')
    $resumeRaw = & pwsh -NoProfile -File (Join-Path $scriptDir 'read-resume-record.ps1') @resumeArgs
    $resume = ($resumeRaw -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $resume.pin.model -eq 'gpt-fixture') 'resume record carries top-level pin object'
    $null = Invoke-DtJob @('pin', '-RunFolder', $pinRun, '-Clear')
    $pinStatus = Invoke-DtJob @('status', '-RunFolder', $pinRun)
    Assert-True ($null -eq $pinStatus.pin) 'clear removes registry pin and status is null'
    $resumeRaw = & pwsh -NoProfile -File (Join-Path $scriptDir 'read-resume-record.ps1') @resumeArgs
    $resume = ($resumeRaw -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $null -eq $resume.pin) 'resume record pin is null after clear'
    $registered = Invoke-DtJob ($registrationArgs + @('-PinVendor', 'claude', '-PinModel', 'claude-fixture'))
    Assert-True ($registered.pin.vendor -eq 'claude' -and $registered.pin.model -eq 'claude-fixture') 'register-run stores a pin'
    $registered = Invoke-DtJob $registrationArgs
    Assert-True ($registered.pin.model -eq 'claude-fixture') 're-registration preserves operator pin'
    $null = Invoke-DtJob @('pin', '-RunFolder', $pinRun, '-Clear')
    $pinJob = Invoke-DtJob @('start', '-RunFolder', $pinRun, '-Command', "'unpinned'")
    $spec = Get-Content -Raw (Join-Path $pinRun "jobs/$($pinJob.job_id)/spec.json") | ConvertFrom-Json
    Assert-True (-not $spec.environment.PSObject.Properties['DT_BUILD_RUN_PIN_VENDOR'] -and -not $spec.environment.PSObject.Properties['DT_BUILD_RUN_PIN_MODEL']) 'unpinned registry removes inherited pin hints'
    $null = Wait-JobTerminal $pinRun $pinJob.job_id
    foreach ($name in $pinEnvNames) { [Environment]::SetEnvironmentVariable($name, $pinSavedEnv[$name]) }
    # Tests that exercise operator verbs must not inherit the outer worker identity.
    Remove-Item Env:DT_BUILD_COORDINATOR_ID, Env:DT_JOB_ID -ErrorAction SilentlyContinue

    # Live discovery uses the actual Git admin directory, not the ledger or tree file timestamps.
    $treeRepo = New-RunFolder 'tree-repo'
    $treeRun = Join-Path $treeRepo '.dt-build/run'
    New-Item -ItemType Directory -Path $treeRun -Force | Out-Null
    $addedTree = Join-Path $tempRoot 'added tree'
    & git -C $treeRepo init -q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'worktree fixture init failed' }
    & git -C $treeRepo -c user.name=Fixture -c user.email=fixture@example.test commit -q --allow-empty -m fixture | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'worktree fixture commit failed' }
    & git -C $treeRepo worktree add -q -b feat/live $addedTree 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'worktree fixture add failed' }
    $treeProbe = ". '$dtJob'; [ordered]@{ live = @(Get-DtJobLiveWorktrees -RunFolder '$treeRun'); future = @(Get-DtJobLiveWorktrees -RunFolder '$treeRun' -SinceUtc ([DateTime]::UtcNow.AddDays(1))); missing = @(Get-DtJobWorktrees -RunFolder '$treeRun') } | ConvertTo-Json -Depth 5"
    $treeResult = ((& pwsh -NoProfile -Command $treeProbe) -join "`n") | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'worktree discovery probe failed' }
    Assert-True ($treeResult.live.Count -eq 1 -and $treeResult.live[0].path -eq [IO.Path]::GetFullPath($addedTree) -and $treeResult.live[0].branch -eq 'feat/live' -and $treeResult.live[0].head -match '^[0-9a-f]{40}$' -and $null -ne $treeResult.live[0].created_utc) 'live worktree discovery returns the added tree, branch, HEAD and admin creation time, excluding main'
    Assert-True ($treeResult.future.Count -eq 0) 'live discovery excludes trees before a future SinceUtc'
    Assert-True ($treeResult.missing.Count -eq 0) 'a missing worktree ledger returns no rows'
    Write-Utf8 -Path (Join-Path $treeRun 'worktrees.jsonl') -Content "{broken`n{}`n"
    $treeResult = ((& pwsh -NoProfile -Command $treeProbe) -join "`n") | ConvertFrom-Json
    Assert-True ($treeResult.missing.Count -eq 0) 'malformed worktree ledger lines are ignored'

    # FS-20: dt-job dot-sourced through a skill junction must resolve its alert script in the real repo.
    $realSkillRoot = Split-Path -Parent $scriptDir
    $realRepoRoot = Split-Path -Parent (Split-Path -Parent $realSkillRoot)
    $junctionLink = Join-Path $tempRoot 'dt-build'
    New-Item -ItemType Junction -Path $junctionLink -Target $realSkillRoot | Out-Null
    $junctionJob = Join-Path $junctionLink 'scripts/dt-job.ps1'
    $alertPath = (& pwsh -NoProfile -Command ". '$($junctionJob.Replace("'", "''"))'; Write-Output `$script:DtJobAlertScript" | Select-Object -Last 1)
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $alertPath -PathType Leaf)) "junction dt-job load resolves an existing alert script ($alertPath)"
    Assert-True ($alertPath.StartsWith($realRepoRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and -not $alertPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) 'junction alert path belongs to the real repo, not the junction parent'
    $directPath = (& pwsh -NoProfile -Command ". '$($dtJob.Replace("'", "''"))'; Write-Output `$script:DtJobAlertScript" | Select-Object -Last 1)
    Assert-True ($LASTEXITCODE -eq 0 -and $directPath -eq $alertPath) 'direct and junction loads resolve the same alert path'
    $fallbackProbe = "function Get-Item { param([string]`$LiteralPath) [pscustomobject]@{} }; . '$($dtJob.Replace("'", "''"))'; Write-Output `$script:DtJobAlertScript"
    $fallbackPath = (& pwsh -NoProfile -Command $fallbackProbe | Select-Object -Last 1)
    Assert-True ($LASTEXITCODE -eq 0 -and $fallbackPath -eq $directPath) 'a missing ResolveLinkTarget falls back to the unresolved path without throwing'
    [IO.Directory]::Delete($junctionLink); $junctionLink = $null

    # Start and succeed (nested pwsh command, the shape the wrappers use).
    $rf = New-RunFolder 'succeed'
    $release = Join-Path $rf "release's.txt"
    $heldCommand = (New-HeldJobCommand $release).Replace('$', '`$')
    $start = Invoke-DtJob @('start', '-RunFolder', $rf, '-Kind', 'test', '-Category', 'fixture', '-Command', "pwsh -NoProfile -Command `"'ok'; $heldCommand`"")
    Assert-True ($start.job_id -eq 'j-0001') 'first job id is j-0001'
    Assert-True ($start.status -in @('running', 'queued')) 'start returns at once with a live status'
    Write-Utf8 $release 'release'
    $record = Wait-JobTerminal -RunFolder $rf -JobId $start.job_id
    Assert-True ($record.status -eq 'succeeded') "succeeded job status was $($record.status)"
    Assert-True ($record.exit_code -eq 0) 'succeeded job exit code 0'
    Assert-True ([bool]$record.pid -and [bool]$record.process_start_utc) 'pid and process_start_utc recorded'
    Assert-True ([bool]$record.ended -and [bool]$record.command_sha256 -and $record.kind -eq 'test' -and $record.category -eq 'fixture') 'ledger fields recorded'
    $envelope = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', $start.job_id)
    Assert-True ($envelope.verdict -eq 'pass' -and $envelope.exit_code -eq 0) 'envelope verdict pass'
    Assert-True (@($envelope.excerpt) -contains 'ok') 'envelope excerpt holds stdout tail'
    Assert-True ((Test-Path -LiteralPath $envelope.evidence.stdout) -and -not $envelope.truncated) 'envelope names stdout evidence and is not truncated'

    # Job evidence uses the record's paths, with the same selectors and ledger as -Path.
    $evidenceRecord = Get-JobRecord -RunFolder $rf -JobId $start.job_id
    $jobDir = Join-Path $rf "jobs/$($start.job_id)"
    $expectedPaths = [ordered]@{ summary = $evidenceRecord.summary_path; stdout = $evidenceRecord.output_path; stderr = $evidenceRecord.stderr_path; spec = (Join-Path $jobDir 'spec.json') }
    foreach ($name in $expectedPaths.Keys) {
        $actual = (& pwsh -NoProfile -File $readEvidence -RunFolder $rf -JobId $start.job_id -File $name -Lines '1-3' -Json) -join "`n" | ConvertFrom-Json
        $expectedLines = @(Get-Content -LiteralPath $expectedPaths[$name] -TotalCount 3)
        Assert-True ($actual.path -eq $expectedPaths[$name] -and @($actual.lines).Count -eq $expectedLines.Count) "$name resolves the recorded job evidence path"
        for ($i = 0; $i -lt $expectedLines.Count; $i++) {
            Assert-True ($actual.lines[$i] -eq "$($i + 1): $($expectedLines[$i])") "$name reads the expected evidence line"
        }
    }
    $defaultRead = (& pwsh -NoProfile -File $readEvidence -RunFolder $rf -JobId $start.job_id -Lines '1-3' -Json) -join "`n" | ConvertFrom-Json
    Assert-True ($defaultRead.path -eq $evidenceRecord.summary_path -and (@($defaultRead.warnings) -join ' ') -match 'repeat_read') 'JobId defaults to summary and shares repeat-read tracking'
    $jobGrep = (& pwsh -NoProfile -File $readEvidence -RunFolder $rf -JobId $start.job_id -File stdout -Grep '^ok$' -Context 1 -Json) -join "`n" | ConvertFrom-Json
    Assert-True (@($jobGrep.lines) -contains '1: ok') 'JobId supports grep and context'
    foreach ($missingPath in @((Join-Path $jobDir 'result.json'), (Join-Path $rf "jobs/$($start.job_id).xml"))) {
        $miss = Get-EvidenceError @{ RunFolder = $rf; Path = $missingPath; Lines = '1-3' }
        Assert-True ($miss.Contains('READ_EVIDENCE_MISSING:') -and $miss.Contains("job $($start.job_id) has: summary.json, stdout.log, stderr.log, spec.json (use -JobId $($start.job_id) -File <name>)")) "job path miss lists existing evidence and the JobId form ($miss)"
    }
    Push-Location $rf
    try {
        $miss = Get-EvidenceError @{ RunFolder = $rf; Path = 'approvals.json'; Lines = '1-3' }
        Assert-True (-not $miss.Contains('did you mean')) 'run-root miss does not suggest the same path'
        Push-Location $jobDir
        try {
            $miss = Get-EvidenceError @{ RunFolder = $rf; Path = 'approvals.json'; Lines = '1-3' }
            Assert-True ($miss.Contains("did you mean $(Join-Path $rf 'approvals.json')")) 'bare approvals miss suggests the run folder'
        } finally { Pop-Location }
    } finally { Pop-Location }
    $badArgs = Get-EvidenceError @{ RunFolder = $rf; Path = $evidenceRecord.output_path; JobId = $start.job_id; Lines = '1-3' }
    Assert-True ($badArgs.Contains('READ_EVIDENCE_ARGS')) 'Path plus JobId fails with the argument error'
    $unknown = Get-EvidenceError @{ RunFolder = $rf; JobId = 'j-9999'; Lines = '1-3' }
    Assert-True ($unknown.Contains('READ_EVIDENCE_NO_JOB: j-9999')) 'unknown JobId has the specific missing-record error'
    $sparseRun = New-RunFolder 'evidence-sparse'
    $sparseDir = Join-Path $sparseRun 'jobs/j-0001'
    Write-Utf8 (Join-Path $sparseDir 'stdout.log') 'only stdout exists'
    $miss = Get-EvidenceError @{ RunFolder = $sparseRun; Path = (Join-Path $sparseDir 'output.log'); Lines = '1-3' }
    Assert-True ($miss.Contains('has: stdout.log (use -JobId j-0001 -File <name>)')) 'job miss lists only files that exist'
    Write-Utf8 (Join-Path $sparseRun 'jobs/j-0001.json') (@{ job_id = 'j-0001'; summary_path = (Join-Path $sparseDir 'summary.json') } | ConvertTo-Json)
    $miss = Get-EvidenceError @{ RunFolder = $sparseRun; JobId = 'j-0001'; Lines = '1-3' }
    Assert-True ($miss.StartsWith("READ_EVIDENCE_MISSING: $(Join-Path $sparseDir 'summary.json')")) 'resolved missing job file retains the missing-path error'

    # Hundreds of finished records force trimming after accounting for the hint.
    $manyRun = New-RunFolder 'evidence-many'
    $manyIds = @(1..300 | ForEach-Object { 'j-{0:D4}' -f $_ })
    foreach ($id in $manyIds) {
        $copy = $evidenceRecord | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $copy.job_id = $id
        Write-Utf8 (Join-Path $manyRun "jobs/$id.json") ($copy | ConvertTo-Json -Depth 8)
    }
    foreach ($arguments in @(@('status', '-RunFolder', $manyRun), @('wait', '-RunFolder', $manyRun, '-JobId', ($manyIds -join ','), '-All', '-TimeoutSec', '1'))) {
        $reply = Invoke-DtJob $arguments
        Assert-True ($reply.evidence_hint -is [string] -and $reply.evidence_hint.Length -lt 400 -and $reply.evidence_hint.Contains('-JobId <job>')) 'large envelope retains its bounded evidence hint'
        Assert-True ($reply.truncated -and @($reply.jobs).Count -lt 300 -and [Text.Encoding]::UTF8.GetByteCount(($reply | ConvertTo-Json -Depth 8 -Compress)) -le 8192) '300-job envelope including hint is trimmed within 8 KB'
    }
    $events = @(Get-Content -LiteralPath (Join-Path $rf 'jobs/events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    $seqs = @($events | ForEach-Object { [int]$_.seq })
    Assert-True (($seqs -join ',') -eq ((1..$seqs.Count) -join ',')) 'event seq is monotonic from 1'
    Assert-True ((@($events | Where-Object { -not ($_.job_id -and $_.ts_utc -and $_.type -and $_.status) })).Count -eq 0) 'every event carries job_id, ts_utc, type, status'
    $all = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True ($all.job_count -eq 1 -and $all.jobs[0].status -eq 'succeeded') 'run status lists jobs'

    # A wrapper can exit successfully while its report records unfinished/failed work.
    $workerRun = New-RunFolder 'worker-outcomes'
    $fakeWrapper = Join-Path $workerRun 'fake-wrapper.ps1'
    Write-Utf8 $fakeWrapper @'
param([string]$OutputPath, [string]$ReportVerdict, [switch]$OmitReport, [switch]$WrapperFailure)
if ($OmitReport) { exit 0 }
[IO.File]::WriteAllText($OutputPath, "DT_BUILD_REPORT_VERSION: 3`nVERDICT: $ReportVerdict`nCHANGED_FILES:`nNONE`n")
@{ pass = (-not $WrapperFailure); failure_category = $(if ($WrapperFailure) { 'environment' } else { $null }); termination_reason = $(if ($WrapperFailure) { 'fixture wrapper failure' } else { $null }) } | ConvertTo-Json | Set-Content -LiteralPath "$OutputPath.provenance.json"
exit 0
'@
    foreach ($case in @('BLOCKED', 'PASS', 'FAIL', 'PARTIAL', 'missing', 'wrapper-failure')) {
        $report = Join-Path $workerRun "report $case.md"
        $reportVerdict = if ($case -eq 'wrapper-failure') { 'PASS' } else { $case }
        $extra = if ($case -eq 'missing') { ' -OmitReport' } elseif ($case -eq 'wrapper-failure') { ' -WrapperFailure' } else { '' }
        $worker = Invoke-DtJob @('start', '-RunFolder', $workerRun, '-Kind', 'worker', '-Command', "& '$fakeWrapper' -OutputPath '$report' -ReportVerdict '$reportVerdict'$extra")
        $workerRecord = Wait-JobTerminal -RunFolder $workerRun -JobId $worker.job_id
        $summary = Invoke-DtJob @('status', '-RunFolder', $workerRun, '-JobId', $worker.job_id)
        $expectedVerdict = if ($case -in @('BLOCKED', 'FAIL', 'wrapper-failure')) { 'fail' } else { 'pass' }
        Assert-True ($workerRecord.status -eq 'succeeded' -and $workerRecord.exit_code -eq 0 -and $summary.verdict -eq $expectedVerdict) "$case keeps successful ledger state and summarizes worker outcome"
        Assert-True ($summary.report_verdict -eq $(if ($case -eq 'missing') { $null } else { $reportVerdict })) "$case extracts report verdict through a path containing spaces"
        if ($case -in @('BLOCKED', 'FAIL', 'PARTIAL')) { Assert-True (@($summary.blockers) -contains "report verdict $case; see $report") "$case summary points to report evidence" }
        if ($case -in @('BLOCKED', 'PASS')) {
            $persisted = Get-Content -Raw -LiteralPath $workerRecord.summary_path | ConvertFrom-Json
            Assert-True ($persisted.report_verdict -eq $reportVerdict -and $persisted.verdict -eq $expectedVerdict -and $persisted.wrapper_pass -eq $true -and $null -eq $persisted.failure_category) "$case persists worker outcome in summary.json"
        }
        if ($case -eq 'PASS') {
            Assert-True (@($summary.blockers).Count -eq 0) 'PASS report has no invented blocker'
            foreach ($name in @('report', 'provenance')) {
                $expectedPath = if ($name -eq 'report') { $report } else { "$report.provenance.json" }
                $actual = (& pwsh -NoProfile -File $readEvidence -RunFolder $workerRun -JobId $worker.job_id -File $name -Lines '1-3' -Json) -join "`n" | ConvertFrom-Json
                $expectedLines = @(Get-Content -LiteralPath $expectedPath -TotalCount 3)
                Assert-True ($actual.path -eq $expectedPath -and @($actual.lines).Count -eq $expectedLines.Count) "$name resolves the worker wrapper artifact"
                for ($i = 0; $i -lt $expectedLines.Count; $i++) {
                    Assert-True ($actual.lines[$i] -eq "$($i + 1): $($expectedLines[$i])") "$name reads the expected worker artifact line"
                }
            }
        }
        if ($case -eq 'wrapper-failure') {
            Assert-True ($summary.wrapper_pass -eq $false -and $summary.failure_category -eq 'environment' -and @($summary.blockers) -contains 'wrapper reported failure (environment)') 'wrapper provenance failure overrides a PASS report'
        } elseif ($case -eq 'missing') {
            Assert-True ($null -eq $summary.wrapper_pass -and $null -eq $summary.failure_category -and $null -eq $summary.report_verdict -and @($summary.blockers).Count -eq 0) 'absent report and provenance preserve legacy pass with null outcomes'
        } else { Assert-True ($summary.wrapper_pass -eq $true -and $null -eq $summary.failure_category) "$case reads boolean provenance pass" }
        $wait = Invoke-DtJob @('wait', '-RunFolder', $workerRun, '-JobId', $worker.job_id, '-All', '-TimeoutSec', '1')
        Assert-True ($wait.jobs[0].report_verdict -eq $summary.report_verdict -and $wait.jobs[0].failure_category -eq $summary.failure_category) "$case wait JSON carries report outcome"
        $runSummary = Invoke-DtJob @('status', '-RunFolder', $workerRun)
        foreach ($reply in @($wait, $runSummary)) {
            Assert-True ($reply.evidence_hint.Contains('-JobId <job> -File summary|stdout|stderr|spec|report|provenance') -and $reply.evidence_hint.Contains('jobs/events.jsonl') -and $reply.evidence_hint.Length -lt 400 -and $reply.evidence_hint -notmatch '[\r\n]') "$case envelope has the one-line evidence hint"
            Assert-True ([Text.Encoding]::UTF8.GetByteCount(($reply | ConvertTo-Json -Depth 8 -Compress)) -le 8192) "$case envelope with evidence hint stays within 8 KB"
        }
        $row = @($runSummary.jobs | Where-Object job_id -eq $worker.job_id)[0]
        Assert-True ($row.report_verdict -eq $summary.report_verdict -and $row.failure_category -eq $summary.failure_category) "$case run status carries report outcome"
        $waitText = & pwsh -NoProfile -File $dtJob wait -RunFolder $workerRun -JobId $worker.job_id -All -TimeoutSec 1
        Assert-True (($waitText -join "`n") -match $(if ($case -eq 'missing') { 'evidence=' } else { "verdict=$reportVerdict" })) "$case terminal check-in text carries available verdict"
    }
    # Probe parser and corrupt-artifact cases without spawning another process for each.
    & {
        . $dtJob
        $fixtureRecord = $workerRecord
        $specPath = Join-Path $workerRun "jobs/$($fixtureRecord.job_id)/spec.json"
        $quotedReport = Join-Path $workerRun "Danny's report.md"
        Write-Utf8 $quotedReport "VERDICT:`nBLOCKED`nPASS`nCHANGED_FILES:`nNONE"
        $simpleReport = Join-Path $workerRun 'simple.md'
        Write-Utf8 $simpleReport 'VERDICT: PARTIAL'
        $fixtureRecord.working_directory = $workerRun
        foreach ($command in @("wrapper -OutputPath '$($quotedReport.Replace("'", "''"))'", "wrapper -OutputPath `"$quotedReport`"", 'wrapper -OutputPath simple.md')) {
            Write-Utf8 $specPath (@{ command = $command } | ConvertTo-Json)
            $outcome = Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord
            Assert-True ($outcome.report_path -eq $(if ($command.EndsWith('simple.md')) { $simpleReport } else { $quotedReport }) -and $outcome.report_verdict -eq $(if ($command.EndsWith('simple.md')) { 'PARTIAL' } else { 'BLOCKED' })) 'single/double/bare OutputPath parser reads first VERDICT entry'
        }
        Write-Utf8 $specPath (@{ command = "wrapper -OutputPath '$quotedReport" } | ConvertTo-Json)
        $outcome = Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord
        Assert-True ($null -eq $outcome.report_path -and $null -eq $outcome.report_verdict) 'unclosed quote returns null outcome'
        Write-Utf8 $specPath '{malformed'
        Assert-True ($null -eq (Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord).report_path) 'malformed spec never throws'
        Write-Utf8 $specPath (@{ command = $null; script_path = $fakeWrapper } | ConvertTo-Json)
        Assert-True ($null -eq (Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord).report_path) 'script specs have no command outcome'
        Write-Utf8 $specPath (@{ command = "wrapper -OutputPath '$simpleReport'" } | ConvertTo-Json)
        Write-Utf8 $simpleReport 'VERDICT: unknown'
        Write-Utf8 "$simpleReport.provenance.json" '{malformed'
        $outcome = Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord
        Assert-True ($null -eq $outcome.report_verdict -and $null -eq $outcome.wrapper_pass -and $null -eq $outcome.failure_category) 'unknown verdict and malformed provenance remain nullable'
        Write-Utf8 "$simpleReport.provenance.json" (@{ pass = 'false'; failure_category = @('bad'); termination_reason = 3 } | ConvertTo-Json)
        $outcome = Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord
        Assert-True ($null -eq $outcome.wrapper_pass -and $null -eq $outcome.failure_category -and $null -eq $outcome.termination_reason) 'malformed provenance field types are not coerced'
        Write-Utf8 $simpleReport 'VERDICT: PASS'
        Write-Utf8 "$simpleReport.provenance.json" (@{ pass = $false; failure_category = ('x' * 1200); termination_reason = 'worker stopped' } | ConvertTo-Json)
        $summary = New-DtJobEnvelope -RunFolder $workerRun -Record $fixtureRecord
        Assert-True ($summary.verdict -eq 'fail' -and $summary.failure_category.Length -le 400 -and $summary.truncated -and @($summary.truncated_evidence) -contains "$simpleReport.provenance.json" -and (Get-DtJobEnvelopeBytes $summary) -le 8192) 'long provenance failure stays bounded and retains truncation evidence'
        Assert-True ((Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord).termination_reason -eq 'worker stopped') 'helper returns provenance termination reason'
        $fixtureRecord.status = 'running'; $fixtureRecord.started = [DateTime]::UtcNow.AddHours(-1).ToString('o')
        $activity = Get-DtJobActivity -RunFolder $workerRun -Record $fixtureRecord
        Assert-True ($activity.stalled -and $activity.line -match 'verdict=PASS') 'stalled running check-in appends report verdict'
        $fixtureRecord.kind = 'test'
        Assert-True ($null -eq (Get-DtJobWorkerOutcome -RunFolder $workerRun -Record $fixtureRecord).report_path) 'non-worker jobs ignore OutputPath'
        Assert-True ($null -eq (Get-DtJobWorkerOutcome -RunFolder $workerRun -Record ([pscustomobject]@{})).report_path) 'incomplete record never throws'
    }

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
    # A pwsh child that writes its error as CLIXML: one long line, _xHHHH_ escapes, ANSI colours, message at the end.
    $clixmlPath = Join-Path $tempRoot 'clixml-stderr.txt'
    $esc = '_x001B_'
    $longPath = 'D:\fixture\' + ('deep\' * 60) + 'run-independent.ps1'
    $clixml = "#< CLIXML`r`n<Objs Version=`"1.1.0.1`" xmlns=`"http://schemas.microsoft.com/powershell/2004/04`"><S S=`"Error`">$esc[31;1mException: $esc[0m$longPath:147$esc[0m_x000D__x000A_</S><S S=`"Error`">$esc[31;1mLine |_x000D__x000A_</S><S S=`"Error`">     | $esc[31;1m~~~~~~~~~~$esc[0m_x000D__x000A_</S><S S=`"Error`">     | $esc[31;1mDIRECT_FILE_CAPTURE_FAILED &amp; settled$esc[0m_x000D__x000A_</S></Objs>"
    Write-Utf8 -Path $clixmlPath -Content $clixml
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "[Console]::Error.Write([System.IO.File]::ReadAllText('$clixmlPath')); exit 1")
    Wait-JobTerminal -RunFolder $rf -JobId $job.job_id | Out-Null
    $envelope = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', $job.job_id)
    $errText = @($envelope.stderr_excerpt) -join "`n"
    Assert-True ($errText.Contains('| DIRECT_FILE_CAPTURE_FAILED & settled') -and -not $errText.Contains('CLIXML') -and -not $errText.Contains('_x001B_') -and -not $errText.Contains('~~~') -and -not $errText.Contains([char]27)) "a CLIXML stderr reaches the envelope as plain readable lines ($errText)"

    # Exit semantics: the final statement decides, as with pwsh -Command.
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "cmd /c exit 3; 'done'")
    $record = Wait-JobTerminal -RunFolder $rf -JobId $job.job_id
    Assert-True ($record.status -eq 'succeeded' -and $record.exit_code -eq 0) "earlier native failure with a succeeding final statement exits 0 ($($record.status), $($record.exit_code))"
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'first'; cmd /c exit 4")
    $record = Wait-JobTerminal -RunFolder $rf -JobId $job.job_id
    Assert-True ($record.status -eq 'failed' -and $record.exit_code -eq 4) "failing final native command keeps its exit code ($($record.status), $($record.exit_code))"

    # -TimeoutSec is an expected duration, never a kill.
    $rf = New-RunFolder 'timeout'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Start-Sleep 4', '-TimeoutSec', '1')
    $record = Wait-JobTerminal -RunFolder $rf -JobId $job.job_id -TimeoutSec 30
    Assert-True ($record.status -eq 'succeeded' -and $record.timeout_sec -eq 0 -and $record.expected_sec -eq 1) "a job past its expected time runs to completion ($($record.status), $($record.timeout_sec), $($record.expected_sec))"

    # No job is stopped on time: -TimeoutSec becomes the expected duration.
    $rf = New-RunFolder 'agent-no-limit'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Write-Output ok # invoke-codex-chunk.ps1 -Category complex-coding', '-TimeoutSec', '660')
    $rec = Get-JobRecord -RunFolder $rf -JobId $job.job_id
    Assert-True ($rec.timeout_sec -eq 0 -and $rec.expected_sec -eq 660) "a wrapper job has no time limit, 660 s expected ($($rec.timeout_sec), $($rec.expected_sec))"
    $driver = Join-Path $rf 'driver.ps1'
    Set-Content -LiteralPath $driver -Value "& (Join-Path 'x' 'invoke-claude-chunk.ps1') -TimeoutMs 600000`nexit 0" -Encoding utf8
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-ScriptPath', $driver, '-TimeoutSec', '900')
    Assert-True ((Get-JobRecord -RunFolder $rf -JobId $job.job_id).timeout_sec -eq 0) 'a driver script that calls a wrapper has no time limit'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', 'Write-Output ok', '-TimeoutSec', '900')
    $rec = Get-JobRecord -RunFolder $rf -JobId $job.job_id
    Assert-True ($rec.timeout_sec -eq 0 -and $rec.expected_sec -eq 900) 'a test or command job has no time limit either'

    # Check-ins: a silent agent job is reported stalled; a working one reports its activity.
    $rf = New-RunFolder 'stall'
    $env:DT_JOB_HEARTBEAT_SEC = '1'; $env:DT_JOB_STALL_SEC = '4'
    try {
        $quietRelease = Join-Path $rf 'quiet-release.txt'; $busyRelease = Join-Path $rf 'busy-release.txt'
        # Watch only this fixture directory; concurrent verification logs are not worker activity.
        Push-Location $rf
        try {
        $quiet = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', ((New-HeldJobCommand $quietRelease) + ' # invoke-codex-chunk.ps1'), '-TimeoutSec', '5')
        $busyCommand = (New-HeldJobCommand $busyRelease).Replace('Start-Sleep -Milliseconds 100', "Write-Output 'step'; Start-Sleep -Milliseconds 100")
        $busy = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', ($busyCommand + ' # invoke-codex-chunk.ps1'))
        } finally { Pop-Location }
        Start-Sleep -Seconds 7
        $checkin = Invoke-DtJob @('wait', '-RunFolder', $rf, '-JobId', "$($quiet.job_id),$($busy.job_id)", '-Any', '-TimeoutSec', '1')
        $q = @($checkin.progress | Where-Object { $_.job_id -eq $quiet.job_id })[0]
        $b = @($checkin.progress | Where-Object { $_.job_id -eq $busy.job_id })[0]
        Assert-True ($checkin.result -eq 'wait_timeout' -and $q.stalled -and $q.line -match 'STALLED' -and $q.line -match 'past its expected 1 min') "a silent agent job is reported stalled at a check-in ($($q.line))"
        Assert-True (-not $b.stalled -and $b.idle_sec -lt 4 -and $b.line -match 'last activity') "a working agent job reports activity, not a stall ($($b.line))"
        $status = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', $quiet.job_id)
        Assert-True ($status.activity -match 'STALLED') "status shows a running job's activity ($($status.activity))"
        $runStatus = Invoke-DtJob @('status', '-RunFolder', $rf)
        Assert-True (@($runStatus.stalled) -contains $quiet.job_id -and @($runStatus.stalled) -notcontains $busy.job_id) "run status names stalled jobs up front ($(@($runStatus.stalled) -join ','))"
        $text = & pwsh -NoProfile -File $DtJob wait -RunFolder $rf -JobId $busy.job_id -Any -TimeoutSec 1
        Assert-True ((@($text) -join "`n") -match "$($busy.job_id) running \d+ min, last activity") "text check-in lists progress ($(@($text) -join ' | '))"
        Write-Utf8 $quietRelease 'release'
        $doneQuiet = Wait-JobTerminal -RunFolder $rf -JobId $quiet.job_id -TimeoutSec 30
        Assert-True ($doneQuiet.status -eq 'succeeded') "a stalled agent job is never stopped on time ($($doneQuiet.status))"
        Write-Utf8 $busyRelease 'release'
        Wait-JobTerminal -RunFolder $rf -JobId $busy.job_id -TimeoutSec 30 | Out-Null
    }
    finally { Remove-Item Env:DT_JOB_HEARTBEAT_SEC, Env:DT_JOB_STALL_SEC -ErrorAction SilentlyContinue }

    # Operator notes: added and cleared by operators only, shown in every status and wait.
    $rf = New-RunFolder 'notes'
    $n1 = Invoke-DtJob @('note', '-RunFolder', $rf, '-Message', 'Dispatch the repair worker first.')
    $n2 = Invoke-DtJob @('note', '-RunFolder', $rf, '-Message', 'R3b3 split review is authorized; see approvals/r3b3.md.')
    Assert-True (@($n2.operator_notes).Count -eq 2 -and @($n2.operator_notes)[1].id -eq 'n-002') "notes get sequential ids ($(@($n2.operator_notes).id -join ','))"
    $env:DT_BUILD_COORDINATOR_ID = 'mc-notes'
    try { $raw = & pwsh -NoProfile -File $dtJob note -RunFolder $rf -Message 'drop the review' -Json 2>&1; $code = $LASTEXITCODE }
    finally { $env:DT_BUILD_COORDINATOR_ID = $null }
    Assert-True ($code -ne 0 -and (($raw | Out-String) -match 'DT_JOB_OPERATOR_ONLY')) 'a coordinator cannot write operator notes'
    $runStatus = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True (@($runStatus.operator_notes).Count -eq 2 -and @($runStatus.operator_notes)[0].text -eq 'Dispatch the repair worker first.') 'run status carries the operator notes in full'
    $release = Join-Path $rf 'release.txt'
    $noteJob = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand $release))
    $w = Invoke-DtJob @('wait', '-RunFolder', $rf, '-JobId', $noteJob.job_id, '-Any', '-TimeoutSec', '1')
    Assert-True (@($w.operator_notes).Count -eq 2) 'every wait check-in carries the operator notes'
    $text = & pwsh -NoProfile -File $dtJob wait -RunFolder $rf -JobId $noteJob.job_id -Any -TimeoutSec 1
    Assert-True ((@($text) -join "`n") -match 'operator note n-001: Dispatch the repair worker first\.' -and @($text)[-1] -match '^wait_timeout') "text check-ins list notes and keep wait_timeout last ($(@($text) -join ' | '))"
    Write-Utf8 $release 'release'
    Wait-JobTerminal -RunFolder $rf -JobId $noteJob.job_id | Out-Null
    $cleared = Invoke-DtJob @('note', '-RunFolder', $rf, '-Clear', '-NoteId', 'n-001')
    Assert-True (@($cleared.operator_notes).Count -eq 1 -and @($cleared.operator_notes)[0].id -eq 'n-002') 'clear -NoteId removes one note'
    $n3 = Invoke-DtJob @('note', '-RunFolder', $rf, '-Message', 'Third.')
    Assert-True (@($n3.operator_notes)[-1].id -eq 'n-003') 'ids are never reused'
    $all = Invoke-DtJob @('note', '-RunFolder', $rf, '-Clear')
    Assert-True (@($all.operator_notes).Count -eq 0) 'clear alone removes every note'

    # Dependency chain: a failure blocks two levels downstream.
    $rf = New-RunFolder 'deps'
    $release = Join-Path $rf 'release.txt'
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand $release -ExitCode 1))
    $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'b'", '-DependsOn', $a.job_id)
    $c = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'c'", '-DependsOn', $b.job_id)
    Assert-True ($b.status -eq 'queued' -and $c.status -eq 'queued') 'dependents wait queued'
    Write-Utf8 $release 'release'
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
    $requeued = Invoke-DtJob @('requeue', '-RunFolder', $rf, '-JobId', $b.job_id, '-DependsOn', $okA.job_id)
    Assert-True ($requeued.job_id -ne $b.job_id -and $requeued.requeued_from -eq $b.job_id) 'requeue allocates a new identity'
    Assert-True ((Wait-JobTerminal -RunFolder $rf -JobId $requeued.job_id).status -eq 'succeeded') 'requeued blocked consumer runs after replacement dependency succeeds'
    Assert-True ((Get-JobRecord $rf $b.job_id).status -eq 'blocked') 'original blocked record stays terminal'
    $oldSpec = [IO.File]::ReadAllText((Join-Path $rf "jobs/$($b.job_id)/spec.json"))
    Assert-True ($oldSpec -ceq [IO.File]::ReadAllText((Join-Path $rf "jobs/$($requeued.job_id)/spec.json"))) 'requeue preserves the complete spec'
    $unchanged = Invoke-DtJob @('requeue', '-RunFolder', $rf, '-JobId', $c.job_id)
    Assert-True ($unchanged.status -eq 'blocked' -and (Get-JobRecord $rf $unchanged.job_id).depends_on[0] -eq $b.job_id) 'omitted dependency override preserves the original chain'
    $restartedTail = Invoke-DtJob @('requeue', '-RunFolder', $rf, '-JobId', $c.job_id, '-DependsOn', $requeued.job_id)
    Assert-True ((Wait-JobTerminal $rf $restartedTail.job_id).status -eq 'succeeded') 'a multi-level chain restarts against new predecessor IDs'
    $raw = & pwsh -NoProfile -File $dtJob requeue -RunFolder $rf -JobId $okA.job_id -Json 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join "`n") -match 'DT_JOB_REQUEUE_STATE') 'requeue rejects a succeeded job'
    $countBefore = @(Get-ChildItem (Join-Path $rf 'jobs') -Filter 'j-*.json').Count
    & pwsh -NoProfile -File $dtJob requeue -RunFolder $rf -JobId $b.job_id -DependsOn j-9999 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0 -and @(Get-ChildItem (Join-Path $rf 'jobs') -Filter 'j-*.json').Count -eq $countBefore) 'unknown dependency fails without allocating a job'
    $heldRelease = Join-Path $rf 'requeue-held.txt'
    $held = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand $heldRelease))
    $cancelSource = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'cancel-copy'", '-DependsOn', $held.job_id)
    Invoke-DtJob @('cancel', '-RunFolder', $rf, '-JobId', $cancelSource.job_id) | Out-Null
    $cancelCopy = Invoke-DtJob @('requeue', '-RunFolder', $rf, '-JobId', $cancelSource.job_id)
    Assert-True ($cancelCopy.status -eq 'queued') 'cancelled job requeues and waits on its original dependency'
    Write-Utf8 $heldRelease 'release'
    Assert-True ((Wait-JobTerminal $rf $cancelCopy.job_id).status -eq 'succeeded' -and (Get-JobRecord $rf $cancelSource.job_id).status -eq 'cancelled') 'cancelled source remains terminal while new job succeeds'

    # Mutation key: a second job on the same key queues until the key frees.
    $rf = New-RunFolder 'mutates'
    $release = Join-Path $rf 'release.txt'
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand $release), '-Mutates', 'worktree:main')
    $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'b'", '-Mutates', 'worktree:main')
    Assert-True ($a.status -eq 'running') 'key holder runs'
    Assert-True ($b.status -eq 'queued') 'second job on the same key queues'
    $other = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'other'", '-Mutates', 'worktree:other')
    Assert-True ($other.status -eq 'running') 'job on a different key runs'
    Write-Utf8 $release 'release'
    $ra = Wait-JobTerminal -RunFolder $rf -JobId $a.job_id
    $rb = Wait-JobTerminal -RunFolder $rf -JobId $b.job_id
    Assert-True ($rb.status -eq 'succeeded') "queued key job ran after release ($($rb.status))"
    Assert-True (([DateTime]$rb.started).ToUniversalTime() -ge ([DateTime]$ra.ended).ToUniversalTime()) 'second key job started after the first ended'
    Assert-True ((@(Get-ChildItem -LiteralPath (Join-Path $rf 'jobs/locks') -Filter 'key-*.lock')).Count -eq 0) 'key locks released'

    # Cancel queued and cancel running.
    $rf = New-RunFolder 'cancel'
    $release = Join-Path $rf 'release.txt'
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand $release), '-Mutates', 'k')
    $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'b'", '-Mutates', 'k')
    $cb = Invoke-DtJob @('cancel', '-RunFolder', $rf, '-JobId', $b.job_id)
    Assert-True ($cb.status -eq 'cancelled') 'queued job cancelled'
    Write-Utf8 $release 'release'
    Wait-JobTerminal -RunFolder $rf -JobId $a.job_id | Out-Null
    Start-Sleep -Seconds 2
    Assert-True ((Get-JobRecord -RunFolder $rf -JobId $b.job_id).status -eq 'cancelled') 'cancelled queued job stays cancelled after its key frees'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rf "jobs/$($b.job_id)/stdout.log"))) 'cancelled queued job never launched'
    $c = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand (Join-Path $rf 'cancel-release.txt')), '-Mutates', 'k2')
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
        $release = Join-Path $rf 'release.txt'; $workRelease = Join-Path $rf 'work-release.txt'
        $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand $release), '-Mutates', 'race')
        $workCommand = (New-HeldJobCommand $workRelease).Replace('exit 0', "Set-Content -LiteralPath '$($marker.Replace("'", "''"))' -Value 'ran'")
        $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', $workCommand, '-Mutates', 'race')
        Start-Sleep -Milliseconds $delayMs
        $cancel = Start-Process -FilePath ([System.Environment]::ProcessPath) -ArgumentList @('-NoProfile', '-File', "`"$dtJob`"", 'cancel', '-RunFolder', "`"$rf`"", '-JobId', $b.job_id, '-Json') -PassThru -WindowStyle Hidden
        Write-Utf8 $release 'release'
        $cancel.WaitForExit()
        Wait-JobTerminal -RunFolder $rf -JobId $a.job_id | Out-Null
        Write-Utf8 $workRelease 'release'
        Start-Sleep -Seconds 3
        $rb = Get-JobRecord -RunFolder $rf -JobId $b.job_id
        Assert-True ($rb.status -eq 'cancelled') "race ($delayMs ms): job ended cancelled ($($rb.status))"
        Assert-True (-not (Test-Path -LiteralPath $marker)) "race ($delayMs ms): cancelled job never did its work"
    }

    # Reconcile: a killed job becomes orphaned (never succeeded) and its keys free.
    $rf = New-RunFolder 'orphan'
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand (Join-Path $rf 'release.txt')), '-Mutates', 'shared')
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
    $release = Join-Path $rf 'release.txt'
    $a = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand $release), '-Mutates', 'a,b')
    $b = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'b'", '-Mutates', 'a')
    Assert-True ((@((Get-JobRecord -RunFolder $rf -JobId $a.job_id).mutates) -join '|') -eq 'a|b') 'comma-separated -Mutates splits into two keys'
    Assert-True ($a.status -eq 'running' -and $b.status -eq 'queued') 'one-key job queues behind the two-key job sharing a key'
    $c = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "'c'", '-DependsOn', "$($a.job_id), $($b.job_id)")
    Assert-True ((@((Get-JobRecord -RunFolder $rf -JobId $c.job_id).depends_on) -join '|') -eq "$($a.job_id)|$($b.job_id)") 'comma-separated -DependsOn resolves both jobs'
    Write-Utf8 $release 'release'
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

    # Runner died but child lives: reconcile leaves it running, and a check-in reports it stalled.
    $rf = New-RunFolder 'expire'
    $job = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand (Join-Path $rf 'release.txt')), '-TimeoutSec', '20', '-Mutates', 'exp')
    $record = Wait-JobState -RunFolder $rf -JobId $job.job_id -Until { param($r) [bool]$r.pid }
    Stop-Process -Id ([int]$record.runner_pid) -Force
    Start-Sleep -Milliseconds 500
    Invoke-DtJob @('reconcile', '-RunFolder', $rf) | Out-Null
    Assert-True ((Get-JobRecord -RunFolder $rf -JobId $job.job_id).status -eq 'running') 'a live child stays running'
    $record = Get-JobRecord -RunFolder $rf -JobId $job.job_id
    Remove-Item -LiteralPath (Join-Path $rf "jobs/$($job.job_id)/heartbeat.json") -Force -ErrorAction SilentlyContinue
    $record.started = [DateTime]::UtcNow.AddSeconds(-60).ToString('o')
    Write-Utf8 (Join-Path $rf "jobs/$($job.job_id).json") ($record | ConvertTo-Json -Depth 8)
    Invoke-DtJob @('reconcile', '-RunFolder', $rf) | Out-Null
    $after = Get-JobRecord -RunFolder $rf -JobId $job.job_id
    Assert-True ($after.status -eq 'running') "a job past its expected time is never ended by reconcile ($($after.status))"
    $env:DT_JOB_STALL_SEC = '30'
    try { $runStatus = Invoke-DtJob @('status', '-RunFolder', $rf) } finally { Remove-Item Env:DT_JOB_STALL_SEC -ErrorAction SilentlyContinue }
    Assert-True (@($runStatus.stalled) -contains $job.job_id) 'a job whose runner died shows as stalled'
    Invoke-DtJob @('cancel', '-RunFolder', $rf, '-JobId', $job.job_id) | Out-Null
    Start-Sleep -Milliseconds 500
    Assert-True (Test-ProcessGone $record.pid) 'cancel stops the child'
    Assert-True (-not (Test-Path -Path (Join-Path $rf 'jobs/locks/key-exp-*.lock'))) 'a cancelled job frees its key'

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

    # FS-57: external approval queues only an exact boundary, survives repeats,
    # and applies after the recorded coordinator identity exits (including PID reuse).
    $rf = New-RunFolder 'approval-queue'
    $state = Join-Path $rf '_build-state.md'
    Write-Utf8 $state "run_status: awaiting_danny`nlast_consumed_event_seq: 0`nupdated_utc: fixture`n"
    Invoke-DtJob @('register-run', '-RunFolder', $rf, '-RunId', 'approval-queue', '-BuildStatePath', $state, '-PinnedHost', 'codex', '-Managed') | Out-Null
    $pendingPath = Join-Path $rf 'approvals.json'
    $queuePath = Join-Path $rf 'approval-queued.json'
    Write-Utf8 $pendingPath '{"awaiting":{"operation":"fixture-review","seq":1},"approvals":[],"delegate":null}'
    $closingRelease = Join-Path $rf 'closing-release'
    $closingScript = Join-Path $rf 'closing.ps1'
    Write-Utf8 $closingScript (New-HeldJobCommand $closingRelease)
    $closing = Start-Process pwsh -ArgumentList @('-NoProfile','-File', $closingScript) -WindowStyle Hidden -PassThru
    $lease = [ordered]@{ coordinator_id = 'closing-fixture'; launched_by = 'watcher'; pid = $closing.Id; pid_start_utc = $closing.StartTime.ToUniversalTime().ToString('o'); released_utc = $null }
    Write-Utf8 (Join-Path $rf 'coordinator.lease') ($lease | ConvertTo-Json)
    foreach ($refusal in @('wrong-operation','coordinator','job','wrong-state')) {
        $op = 'fixture-review'
        if ($refusal -eq 'wrong-operation') { $op = 'different' }
        if ($refusal -eq 'coordinator') { $env:DT_BUILD_COORDINATOR_ID = 'closing-fixture' }
        if ($refusal -eq 'job') { $env:DT_JOB_ID = 'fixture-job' }
        if ($refusal -eq 'wrong-state') { Write-Utf8 $state "run_status: runnable`nlast_consumed_event_seq: 0`nupdated_utc: fixture`n" }
        try {
            $raw = & pwsh -NoProfile -File $dtJob approve -RunFolder $rf -Operation $op -Json 2>&1
            Assert-True ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath $queuePath)) "$refusal preserves refusal without queuing"
        } finally {
            Remove-Item Env:DT_BUILD_COORDINATOR_ID,Env:DT_JOB_ID -ErrorAction SilentlyContinue
            Write-Utf8 $state "run_status: awaiting_danny`nlast_consumed_event_seq: 0`nupdated_utc: fixture`n"
        }
    }
    $queued = Invoke-DtJob @('approve', '-RunFolder', $rf, '-Operation', 'fixture-review')
    Assert-True ($queued.approval_queued -eq 'fixture-review' -and $queued.message -eq "approval queued; applies when coordinator $($closing.Id) exits") 'external operator queues while closing out'
    $firstReceipt = Get-Content -LiteralPath $queuePath -Raw
    Invoke-DtJob @('approve', '-RunFolder', $rf, '-Operation', 'fixture-review') | Out-Null
    Assert-True ((Get-Content -LiteralPath $queuePath -Raw) -ceq $firstReceipt) 'repeated queued approve preserves original who what when identity'
    Invoke-DtJob @('status', '-RunFolder', $rf) | Out-Null
    Assert-True ((Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json).approvals.Count -eq 0) 'live identity does not apply queued approval'
    Write-Utf8 $closingRelease 'release'
    $closing.WaitForExit()
    Invoke-DtJob @('status', '-RunFolder', $rf) | Out-Null
    $applied = Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json
    Assert-True ($applied.approvals.Count -eq 1 -and $applied.approvals[0].status -eq 'applied' -and $null -eq $applied.awaiting -and (Get-Content -LiteralPath $state -Raw) -match 'run_status: runnable') 'next invocation applies durable applied receipt when original process identity exits'
    Invoke-DtJob @('approve', '-RunFolder', $rf, '-Operation', 'fixture-review') | Out-Null
    Assert-True ((Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json).approvals.Count -eq 1) 'applied approval repeats without duplication'

    # Immediate approvals have no queue file; repeat the latest exact approval.
    Remove-Item -LiteralPath $queuePath
    Invoke-DtJob @('await-danny', '-RunFolder', $rf, '-Operation', 'immediate-review', '-Message', 'fixture only') | Out-Null
    Invoke-DtJob @('approve', '-RunFolder', $rf, '-Operation', 'immediate-review') | Out-Null
    Invoke-DtJob @('approve', '-RunFolder', $rf, '-Operation', 'immediate-review') | Out-Null
    Assert-True ((Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json).approvals.Count -eq 2) 'immediate approve twice records only one new approval without a queue'
    $wrongRepeat = & pwsh -NoProfile -File $dtJob approve -RunFolder $rf -Operation fixture-review -Json 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and ($wrongRepeat -join ' ') -match 'DT_JOB_NOT_AWAITING') 'older operation is not accepted as a repeated latest approval'

    # FS-58: exercise the real unwrapped runner with a PS pytest stand-in,
    # then inspect the opt-in runner argv without starting Python.
    $rf = New-RunFolder 'exclusive-reason'
    $direct = Invoke-DtJob @('start','-RunFolder',$rf,'-Kind','test','-Command', "function pytest { 'pytest direct fixture' }; pytest")
    Assert-True ((Wait-JobTerminal -RunFolder $rf -JobId $direct.job_id).status -eq 'succeeded') 'pytest job without exclusive_reason runs directly'
    Assert-True ((Get-Content -Raw (Join-Path $rf "jobs/$($direct.job_id)/stdout.log")) -match 'pytest direct fixture') 'unwrapped pytest stand-in actually executed'
    $held = Invoke-DtJob @('start','-RunFolder',$rf,'-Command',(New-HeldJobCommand (Join-Path $rf 'release')),'-Mutates','exclusive-fixture')
    $reason = "fixture suite: simultaneous shared-device writes (fixture evidence); separate paths failed"
    $wrapped = Invoke-DtJob @('start','-RunFolder',$rf,'-Kind','test','-Command','pytest fixture-selection','-ExclusiveReason',$reason,'-Mutates','exclusive-fixture')
    $record = Get-JobRecord -RunFolder $rf -JobId $wrapped.job_id
    $jobDir = Join-Path $rf "jobs/$($wrapped.job_id)"
    $spec = Get-Content -Raw (Join-Path $jobDir 'spec.json') | ConvertFrom-Json
    Assert-True ($wrapped.status -eq 'queued' -and $wrapped.exclusive_reason -ceq $reason -and $record.exclusive_reason -ceq $reason -and $spec.exclusive_reason -ceq $reason) 'opt-in reason retained exactly in spec, job record and start receipt'
    $status = Invoke-DtJob @('status','-RunFolder',$rf,'-JobId',$wrapped.job_id)
    Assert-True ($status.exclusive_reason -ceq $reason) 'job status receipt retains the reason'
    $runner = Get-Content -Raw (Join-Path $scriptDir 'dt-job-runner.ps1')
    $wrapping = [regex]::Match($runner, '(?s)    # Only a caller-documented suite.*?(?=    # Recheck under the lock)').Value
    Assert-True ([bool]$wrapping) 'runner opt-in argv block found'
    # Substitute only executable discovery; construction uses product code.
    $wrapping = $wrapping.Replace('(Get-Command python -CommandType Application | Select-Object -First 1).Source', "'fixture-python-never-launched'")
    $DtJobRepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptDir))
    foreach ($value in @($null, '', '   ', $reason)) {
        $spec = [pscustomobject]@{ command = 'pytest fixture-selection'; exclusive_reason = $value }
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'pwsh'
        foreach ($arg in @('-NoProfile','-Command','pytest fixture-selection')) { $psi.ArgumentList.Add($arg) }
        & ([scriptblock]::Create($wrapping))
        if ($value -eq $reason) {
            Assert-True ($psi.FileName -eq 'fixture-python-never-launched' -and $psi.ArgumentList[0].EndsWith('pytest-lock.py') -and $psi.ArgumentList[1] -eq '--reason' -and $psi.ArgumentList[2] -ceq $reason -and $psi.ArgumentList[5] -eq '--' -and $psi.ArgumentList[6] -eq 'pwsh' -and $psi.ArgumentList[9] -eq 'pytest fixture-selection') 'documented pytest job is wrapped with exact original argv and reason'
        } else {
            Assert-True ($psi.FileName -eq 'pwsh' -and $psi.ArgumentList.Count -eq 3) 'null empty and whitespace reason do not wrap pytest'
        }
    }
    Invoke-DtJob @('cancel','-RunFolder',$rf,'-JobId',$wrapped.job_id) | Out-Null
    Invoke-DtJob @('cancel','-RunFolder',$rf,'-JobId',$held.job_id) | Out-Null

    Write-Output 'PASS: dt-job suite'
}
catch {
    Write-Output "FAIL: $($_.Exception.Message)"
    Write-Output $_.ScriptStackTrace
    $exitCode = 1
}
finally {
    foreach ($name in $pinEnvNames) { [Environment]::SetEnvironmentVariable($name, $pinSavedEnv[$name]) }
    Write-Output "SUMMARY: $script:passed passed"
    # Unlink only: a recursive delete would follow the junction into the real skill folder.
    if ($junctionLink -and [IO.Directory]::Exists($junctionLink)) { [IO.Directory]::Delete($junctionLink) }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

exit $exitCode
