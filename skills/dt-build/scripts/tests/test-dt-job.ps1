param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:passed = 0
$script:failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $script:failed++; Write-Output "ASSERT_FAIL: $Message"; return }
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
    $raw = & pwsh -NoProfile -File $dtJob @Arguments -AllowTempRunFolder -Json
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
$savedRouterState = $env:DT_MODEL_ROUTER_STATE
$savedAlertTransport = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
$savedDmLog = $env:DT_TEST_DM_LOG
try {
    # FS-115: every alert this suite raises goes to a fake transport, never Danny's real Discord.
    $env:DT_TEST_DM_LOG = Join-Path $tempRoot 'dms.jsonl'
    $fakeAlertTransport = Join-Path $tempRoot 'fake-alert-transport.ps1'
    Write-Utf8 $fakeAlertTransport @'
param($request)
if ($request['kind'] -eq 'secret') { return 'fake-secret' }
if ([string]$request['uri'] -like '*/oauth2/applications/@me') { return [pscustomobject]@{ owner = [pscustomobject]@{ id = '1' } } }
if ([string]$request['uri'] -like '*/messages') {
    $content = ([string]$request['body'] | ConvertFrom-Json).content
    [System.IO.File]::AppendAllText($env:DT_TEST_DM_LOG, (([ordered]@{ content = $content } | ConvertTo-Json -Compress) + "`n"))
}
return [pscustomobject]@{ id = 'fake' }
'@
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $fakeAlertTransport
    $env:DT_BUILD_STATE_DIR = Join-Path $tempRoot 'registry'
    $env:DT_MODEL_ROUTER_STATE = Join-Path $tempRoot 'router-state'
    New-Item -ItemType Directory -Path $env:DT_MODEL_ROUTER_STATE -Force | Out-Null
    Assert-True ([IO.Path]::GetFullPath($env:DT_MODEL_ROUTER_STATE).StartsWith([IO.Path]::GetFullPath($tempRoot) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'router state stays under the suite temp directory'
    Remove-Item Env:DT_BUILD_COORDINATOR_ID, Env:DT_JOB_ID -ErrorAction SilentlyContinue
    # FS-101: fixtures opt into temp storage explicitly; raw calls exercise the default guard.
    foreach ($verb in @('start', 'register-run', 'lease', 'note')) {
        $newTemp = Join-Path $tempRoot "refused-$verb"
        $raw = & pwsh -NoProfile -File $dtJob $verb -RunFolder $newTemp -Command "'unused'" 2>&1
        Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_TEMP_RUN_FOLDER' -and ($raw -join ' ') -match '\.dt-build/adhoc/') "$verb refuses a new temp run and names durable default"
        Assert-True (-not (Test-Path -LiteralPath $newTemp)) "$verb refusal creates no folder"
    }
    $guardProbe = @'
param($dtJob, $root)
. $dtJob
$env:TEMP = Join-Path $root 'alternate-temp'
$env:TMP = Join-Path $root 'alternate-tmp'
$results = foreach ($path in @((Join-Path $env:TEMP '../alternate-temp/new'), (Join-Path $env:TMP 'NEW').ToUpperInvariant())) {
    try { Assert-DtJobRunFolder $path; $false } catch { $_.Exception.Message -match 'DT_JOB_TEMP_RUN_FOLDER' }
}
try { Assert-DtJobRunFolder (Join-Path $root 'alternate-temp-sibling/new'); $results += $true } catch { $results += $false }
$results | ConvertTo-Json -Compress
'@
    $probePath = Join-Path $tempRoot 'guard-probe.ps1'
    Write-Utf8 $probePath $guardProbe
    $guardResults = ((& pwsh -NoProfile -File $probePath $dtJob $scriptDir) -join "`n") | ConvertFrom-Json
    Assert-True ($guardResults.Count -eq 3 -and @($guardResults | Where-Object { -not $_ }).Count -eq 0) 'TEMP TMP normalization case and path boundary guard'
    $tempRun = Join-Path $tempRoot 'explicit-temp'
    $tempJob = Invoke-DtJob @('start', '-RunFolder', $tempRun, '-Command', "'temp fixture'")
    Assert-True ((Wait-JobTerminal $tempRun $tempJob.job_id).status -eq 'succeeded') 'explicit temp opt-in creates and runs a job'
    $warningPath = Join-Path $tempRoot 'temp-warning.txt'
    $raw = & pwsh -NoProfile -File $dtJob start -RunFolder $tempRun -Command "'existing temp'" -Json 2>$warningPath
    $existingTempJob = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and @(Get-Content $warningPath).Count -eq 1 -and (Get-Content -Raw $warningPath) -match 'WARNING: DT_JOB_TEMP_RUN_FOLDER') 'existing temp run accepts start with exactly one stderr warning'
    $null = Wait-JobTerminal $tempRun $existingTempJob.job_id
    foreach ($verb in @('status', 'wait', 'reconcile', 'cancel')) {
        $raw = & pwsh -NoProfile -File $dtJob $verb -RunFolder $tempRun -JobId $tempJob.job_id -TimeoutSec 1 -Json 2>$warningPath
        Assert-True ($LASTEXITCODE -eq 0 -and -not (Get-Content -Raw $warningPath)) "$verb works on existing temp run without warning"
    }
    $raw = & pwsh -NoProfile -File $dtJob note -RunFolder $tempRun -Evidence -Message 'Fixture evidence recorded.' -Json 2>$warningPath
    Assert-True ($LASTEXITCODE -eq 0 -and -not (Get-Content -Raw $warningPath)) 'evidence notes work in existing temp run'
    $raw = & pwsh -NoProfile -File $readEvidence -RunFolder $tempRun -JobId $tempJob.job_id -File spec -Lines 1-10
    Assert-True ($LASTEXITCODE -eq 0 -and ($raw -join ' ') -match 'temp fixture') 'evidence reads work in existing temp run'
    $copiedRun = Join-Path $tempRoot 'copied-run'
    Copy-Item -LiteralPath $tempRun -Destination $copiedRun -Recurse
    $sourceRoot = [IO.Path]::GetFullPath($tempRun)
    Assert-True ($sourceRoot.StartsWith([IO.Path]::GetFullPath($tempRoot) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'migration source stays within isolated fixtures'
    Rename-Item -LiteralPath $sourceRoot -NewName 'old-temp-unavailable'
    foreach ($file in @('stdout', 'stderr', 'summary', 'spec')) {
        $raw = & pwsh -NoProfile -File $readEvidence -RunFolder $copiedRun -JobId $tempJob.job_id -File $file -Lines 1-10 -Json
        $read = ($raw -join "`n") | ConvertFrom-Json
        Assert-True ($LASTEXITCODE -eq 0 -and $read.path.StartsWith([IO.Path]::GetFullPath($copiedRun), [StringComparison]::OrdinalIgnoreCase)) "$file evidence follows a copied run when the original path is unavailable"
    }

    # FS-103: keep pages resident long enough for several tree samples, in a descendant.
    $memoryRun = New-RunFolder 'memory'
    $memoryScript = Join-Path $tempRoot 'allocate-memory.ps1'
    Write-Utf8 $memoryScript '$buffer = [byte[]]::new(200MB); for ($i = 0; $i -lt $buffer.Length; $i += 4096) { $buffer[$i] = 1 }; Start-Sleep -Seconds 8; [GC]::KeepAlive($buffer)'
    $memoryJob = Invoke-DtJob @('start', '-RunFolder', $memoryRun, '-Command', "& pwsh -NoProfile -File '$($memoryScript.Replace("'", "''"))'", '-Kind', 'test')
    $memoryRecord = Wait-JobTerminal $memoryRun $memoryJob.job_id
    Assert-True ($memoryRecord.status -eq 'succeeded' -and $memoryRecord.peak_memory_gb -gt 0.1) 'resident descendant memory records a measured peak over 0.1 GB'
    Assert-True ($memoryRecord.peak_memory_gb -eq [math]::Round($memoryRecord.peak_memory_gb, 2)) 'peak is rounded to 0.01 GB'
    $memoryStatus = Invoke-DtJob @('status', '-RunFolder', $memoryRun, '-JobId', $memoryJob.job_id)
    Assert-True ($memoryStatus.peak_memory_gb -eq $memoryRecord.peak_memory_gb) 'single job JSON exposes peak'
    $memoryStatus = Invoke-DtJob @('status', '-RunFolder', $memoryRun)
    Assert-True ($memoryStatus.jobs[0].peak_memory_gb -eq $memoryRecord.peak_memory_gb) 'run JSON exposes peak per job'

    # Exercise the real wait loop with an unavailable sampler and a completed fake process.
    & {
        $runnerPath = Join-Path $scriptDir 'dt-job-runner.ps1'
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        $waitFunction = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-DtJobProcess' }, $true)
        . ([scriptblock]::Create($waitFunction.Extent.Text))
        function Get-DtJobSettingSec { param($Name, $Default) return $Default }
        function Get-DtJobTreeMemoryGB { param($RootPid) throw 'fixture sampler unavailable' }
        $script:DtJobHeartbeatSec = 30
        $script:peakMemoryGB = $null; $script:memorySamplingFailed = $false
        $jobDir = $memoryRun; $paths = [pscustomobject]@{ Root = $memoryRun }; $JobId = 'sample-failure'
        $fake = [pscustomobject]@{ HasExited = $false; Id = $PID }
        $fake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $true }
        $output = [IO.MemoryStream]::new()
        try {
            $finished = Wait-DtJobProcess -Process $fake -WorkDir $memoryRun -Outputs @($output)
            Assert-True $finished 'sampler failure never fails or interrupts the job wait'
            Assert-True ($script:memorySamplingFailed -and $null -eq $script:peakMemoryGB) 'unavailable sampler retains a null peak'
        } finally { $output.Dispose() }
    }

    # FS-102: actual script arguments exercise quoted and bare command replacements.
    $relaunchRun = New-RunFolder 'relaunch'
    $argScript = Join-Path $tempRoot 'echo-args.ps1'
    Write-Utf8 $argScript 'param($PromptPath, $OutputPath); Write-Output "$PromptPath|$OutputPath"'
    $originalCommand = "& '$argScript' -PromptPath 'old prompt.txt' -OutputPath old-output.txt"
    $originalJob = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-Command', $originalCommand, '-Category', 'fixture', '-Model', 'fixture-model', '-Mutates', 'fixture-key', '-TimeoutSec', '40')
    $null = Wait-JobTerminal $relaunchRun $originalJob.job_id
    $originalSpecPath = Join-Path $relaunchRun "jobs/$($originalJob.job_id)/spec.json"
    $originalSpecText = Get-Content -Raw $originalSpecPath
    Push-Location $tempRoot
    try { $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $originalJob.job_id) }
    finally { Pop-Location }
    $retryRecord = Wait-JobTerminal $relaunchRun $retry.job_id
    $retrySpec = Get-Content -Raw (Join-Path $relaunchRun "jobs/$($retry.job_id)/spec.json") | ConvertFrom-Json
    Assert-True ($retry.job_id -ne $originalJob.job_id -and $retrySpec.command -ceq $originalCommand -and $retrySpec.relaunched_from -eq $originalJob.job_id) 'FromJob creates a new id with copied command and spec ancestry'
    Assert-True ($retryRecord.category -eq 'fixture' -and $retryRecord.model -eq 'fixture-model' -and $retryRecord.mutates[0] -eq 'fixture-key' -and $retryRecord.expected_sec -eq 40) 'FromJob copies metadata and expected duration'
    Assert-True ($retrySpec.environment.DT_MODEL_ROUTER_STATE -eq $env:DT_MODEL_ROUTER_STATE -and $retryRecord.working_directory -eq (Get-JobRecord $relaunchRun $originalJob.job_id).working_directory) 'FromJob preserves environment and working directory'
    $events = @(Get-Content (Join-Path $relaunchRun 'jobs/events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($events | Where-Object { $_.job_id -eq $retry.job_id -and $_.type -eq 'recorded' })[0].relaunched_from -eq $originalJob.job_id) 'start event records ancestry'
    foreach ($type in @('launched', 'process_started')) {
        Assert-True (@($events | Where-Object { $_.job_id -eq $retry.job_id -and $_.type -eq $type })[0].relaunched_from -eq $originalJob.job_id) "$type event records ancestry"
    }
    $status = Invoke-DtJob @('status', '-RunFolder', $relaunchRun, '-JobId', $retry.job_id)
    Assert-True ($status.relaunched_from -eq $originalJob.job_id) 'single job status exposes ancestry'
    $status = Invoke-DtJob @('status', '-RunFolder', $relaunchRun)
    Assert-True (@($status.jobs | Where-Object { $_.job_id -eq $retry.job_id })[0].relaunched_from -eq $originalJob.job_id) 'run status exposes ancestry'
    $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $originalJob.job_id, '-PromptPath', "new prompt's.txt", '-OutputPath', 'new output.txt', '-Category', 'replacement', '-TimeoutSec', '9', '-Mutates', '')
    $retryRecord = Wait-JobTerminal $relaunchRun $retry.job_id
    Assert-True ($retryRecord.status -eq 'succeeded' -and (Get-Content -Raw $retryRecord.output_path).Trim() -ceq "new prompt's.txt|new output.txt") 'quoted and bare arguments replaced exactly and execute with literal values'
    Assert-True ($retryRecord.category -eq 'replacement' -and $retryRecord.expected_sec -eq 9 -and $retryRecord.mutates.Count -eq 0) 'explicit start parameters override copied values including empty lists'
    Assert-True ((Get-Content -Raw $originalSpecPath) -ceq $originalSpecText) 'relaunch leaves original spec unchanged'
    $missingJob = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-Command', "Write-Output '-PromptPath fake -OutputPath fake'; Write-Output done -OutputPathSuffix untouched")
    $null = Wait-JobTerminal $relaunchRun $missingJob.job_id
    foreach ($name in @('PromptPath', 'OutputPath')) {
        $raw = & pwsh -NoProfile -File $dtJob start -RunFolder $relaunchRun -FromJob $missingJob.job_id "-$name" replacement -AllowTempRunFolder 2>&1
        Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_FROMJOB_NO_ARG') "$name override refuses absent exact argument including quoted decoys"
    }
    $releaseRetry = Join-Path $tempRoot 'release-retry'
    $heldRetry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-Command', (New-HeldJobCommand $releaseRetry))
    $null = Wait-JobState $relaunchRun $heldRetry.job_id -Until { param($r) $r.status -eq 'running' -and $r.pid }
    $raw = & pwsh -NoProfile -File $dtJob start -RunFolder $relaunchRun -FromJob $heldRetry.job_id -AllowTempRunFolder 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_FROMJOB_RUNNING') 'FromJob refuses a live running job'
    $null = Invoke-DtJob @('cancel', '-RunFolder', $relaunchRun, '-JobId', $heldRetry.job_id)
    $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $heldRetry.job_id, '-Command', "'override command'")
    Assert-True ((Wait-JobTerminal $relaunchRun $retry.job_id).status -eq 'succeeded') 'cancelled job relaunch accepts explicit command override'
    $scriptJob = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-ScriptPath', $argScript, '-ArgumentList', 'one,two')
    $null = Wait-JobTerminal $relaunchRun $scriptJob.job_id
    $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $scriptJob.job_id)
    $retryRecord = Wait-JobTerminal $relaunchRun $retry.job_id
    Assert-True ($retryRecord.status -eq 'succeeded' -and (Get-Content -Raw $retryRecord.output_path).Trim() -eq 'one,two|') 'script path and argument list survive relaunch'
    $failedJob = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-Command', 'exit 7', '-Kind', 'test', '-Vendor', 'fixture', '-DependsOn', $scriptJob.job_id)
    $null = Wait-JobTerminal $relaunchRun $failedJob.job_id
    $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $failedJob.job_id)
    $retryRecord = Wait-JobTerminal $relaunchRun $retry.job_id
    Assert-True ($retryRecord.status -eq 'failed' -and $retryRecord.exit_code -eq 7 -and $retryRecord.depends_on[0] -eq $scriptJob.job_id) 'failed job relaunch preserves command and dependencies'
    $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $failedJob.job_id, '-ScriptPath', $argScript, '-ArgumentList', 'replacement', '-Kind', 'command', '-Vendor', 'replacement', '-Model', 'new-model', '-DependsOn', '', '-ExclusiveReason', '', '-RunId', 'new-run')
    $retryRecord = Wait-JobTerminal $relaunchRun $retry.job_id
    Assert-True ($retryRecord.status -eq 'succeeded' -and $retryRecord.kind -eq 'command' -and $retryRecord.vendor -eq 'replacement' -and $retryRecord.model -eq 'new-model' -and $retryRecord.run_id -eq 'new-run' -and $retryRecord.depends_on.Count -eq 0 -and -not $retryRecord.exclusive_reason -and (Get-Content -Raw $retryRecord.output_path).Trim() -eq 'replacement|') 'explicit script arguments kind vendor model run dependencies and exclusivity override copied values'
    $argumentProbe = @'
param($dtJob)
. $dtJob
$command = 'worker -PromptPath "old prompt.txt" -OutputPath:old.txt -OutputPathSuffix keep; Write-Output ''-PromptPath decoy'''
$command = Set-DtJobCommandArgument $command PromptPath 'new prompt.txt'
Set-DtJobCommandArgument $command OutputPath 'new output.txt'
'@
    Write-Utf8 $probePath $argumentProbe
    $replaced = ((& pwsh -NoProfile -File $probePath $dtJob) -join "`n")
    Assert-True ($LASTEXITCODE -eq 0 -and $replaced -ceq "worker -PromptPath 'new prompt.txt' -OutputPath:'new output.txt' -OutputPathSuffix keep; Write-Output '-PromptPath decoy'") 'double quotes and colon values replace exactly while unrelated arguments and strings stay unchanged'
    # A reboot leaves a running record with dead process identities until reconcile.
    $deadRecord = Get-JobRecord $relaunchRun $originalJob.job_id
    $deadRecord.status = 'running'; $deadRecord.pid = 2147483646; $deadRecord.runner_pid = 2147483646
    Write-Utf8 (Join-Path $relaunchRun "jobs/$($originalJob.job_id).json") ($deadRecord | ConvertTo-Json -Depth 8)
    $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $originalJob.job_id)
    Assert-True ((Wait-JobTerminal $relaunchRun $retry.job_id).status -eq 'succeeded') 'FromJob accepts a dead running record after reboot'
    $null = Invoke-DtJob @('reconcile', '-RunFolder', $relaunchRun)
    $retry = Invoke-DtJob @('start', '-RunFolder', $relaunchRun, '-FromJob', $originalJob.job_id)
    Assert-True ((Wait-JobTerminal $relaunchRun $retry.job_id).status -eq 'succeeded') 'FromJob accepts reconciled orphaned jobs'

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
    $label = 'Evidence only: records facts, grants no authority.'
    $e1 = Invoke-DtJob @('note', '-RunFolder', $rf, '-Evidence', '-Message', 'Observed C:/allowance/grantee.txt in the fixture.')
    $e2 = Invoke-DtJob @('note', '-RunFolder', $rf, '-Evidence', '-Message', ('x' * 2000))
    Assert-True ($e1.evidence_notes[0].id -eq 'e-001' -and $e2.evidence_notes[1].id -eq 'e-002' -and $e2.evidence_notes[1].text.Length -eq 2000) 'evidence notes use separate sequential ids, allow whole-word nonmatches and accept the cap'
    foreach ($word in @('APPROVED', 'permission', 'waiver', 'override', 'may proceed', 'may now', 'is now allowed', 'authorizes', 'granted', 'approves', 'waives', 'overridden', 'exempted', 'superseded', 'authorised')) {
        $raw = & pwsh -NoProfile -File $dtJob note -RunFolder $rf -Evidence -Message "Fixture $word here." -Json 2>&1
        Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join "`n").Contains('DT_JOB_EVIDENCE_NOTE_AUTHORITY')) "evidence refuses authority language: $word"
    }
    $raw = & pwsh -NoProfile -File $dtJob note -RunFolder $rf -Evidence -Message ('x' * 2001) -Json 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join "`n").Contains('2000 characters')) 'evidence rejects over-cap notes'
    foreach ($identity in @('DT_BUILD_COORDINATOR_ID', 'DT_JOB_ID')) {
        [Environment]::SetEnvironmentVariable($identity, 'fixture-evidence', 'Process')
        try {
            foreach ($action in @(@('-Message', 'Observed fixture.'), @('-Clear'))) {
                $raw = & pwsh -NoProfile -File $dtJob note -RunFolder $rf -Evidence @action -Json 2>&1
                Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join "`n").Contains('DT_JOB_OPERATOR_ONLY')) "evidence operator guard refuses $identity $($action[0])"
            }
        } finally { [Environment]::SetEnvironmentVariable($identity, $null, 'Process') }
    }
    $env:DT_BUILD_COORDINATOR_ID = 'mc-notes'
    try { $raw = & pwsh -NoProfile -File $dtJob note -RunFolder $rf -Message 'drop the review' -Json 2>&1; $code = $LASTEXITCODE }
    finally { $env:DT_BUILD_COORDINATOR_ID = $null }
    Assert-True ($code -ne 0 -and (($raw | Out-String) -match 'DT_JOB_OPERATOR_ONLY')) 'a coordinator cannot write operator notes'
    $runStatus = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True (@($runStatus.operator_notes).Count -eq 2 -and @($runStatus.operator_notes)[0].text -eq 'Dispatch the repair worker first.') 'run status carries the operator notes in full'
    Assert-True ($runStatus.evidence_notes.Count -eq 2 -and $runStatus.evidence_notes_label -eq $label -and $runStatus.evidence_notes[1].text.Length -eq 2000) 'status shows evidence notes in full with fixed label'
    $statusText = (& pwsh -NoProfile -File $dtJob status -RunFolder $rf | Out-String)
    Assert-True ($statusText.Contains($label) -and $statusText.IndexOf('operator note n-001:') -lt $statusText.IndexOf('evidence note e-001:')) 'status text prints evidence after operator notes'
    $read = & pwsh -NoProfile -File $readEvidence -RunFolder $rf -Path (Join-Path $rf 'evidence-notes.json') -Lines 1-20 -Json
    Assert-True ($LASTEXITCODE -eq 0 -and ($read -join "`n").Contains('e-001')) 'read-evidence resolves evidence-notes.json'
    $missingEvidence = Get-EvidenceError @{ RunFolder = $rf; Path = 'evidence-notes.json'; Lines = '1-20' }
    Assert-True ($missingEvidence.Contains('did you mean') -and $missingEvidence.Contains((Join-Path $rf 'evidence-notes.json'))) 'bare evidence filename suggests the run-folder path like operator notes'


    $release = Join-Path $rf 'release.txt'
    $noteJob = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', (New-HeldJobCommand $release))
    $w = Invoke-DtJob @('wait', '-RunFolder', $rf, '-JobId', $noteJob.job_id, '-Any', '-TimeoutSec', '1')
    Assert-True (@($w.operator_notes).Count -eq 2) 'every wait check-in carries the operator notes'
    Assert-True ($w.evidence_notes.Count -eq 2 -and $w.evidence_notes_label -eq $label) 'wait carries evidence notes and fixed label'
    $text = & pwsh -NoProfile -File $dtJob wait -RunFolder $rf -JobId $noteJob.job_id -Any -TimeoutSec 1
    Assert-True ((@($text) -join "`n") -match 'operator note n-001: Dispatch the repair worker first\.' -and @($text)[-1] -match '^wait_timeout') "text check-ins list notes and keep wait_timeout last ($(@($text) -join ' | '))"
    Write-Utf8 $release 'release'
    Assert-True (($text -join "`n").Contains($label) -and ($text -join "`n").Contains('evidence note e-001:')) 'wait text prints labeled evidence notes'
    $ec = Invoke-DtJob @('note', '-RunFolder', $rf, '-Evidence', '-Clear', '-NoteId', 'e-001')
    $e3 = Invoke-DtJob @('note', '-RunFolder', $rf, '-Evidence', '-Message', 'Third observation.')
    Assert-True ($ec.evidence_notes.Count -eq 1 -and $ec.evidence_notes[0].id -eq 'e-002' -and $e3.evidence_notes[-1].id -eq 'e-003') 'evidence targeted clear preserves remaining ids'
    $ec = Invoke-DtJob @('note', '-RunFolder', $rf, '-Evidence', '-Clear')
    $afterEvidenceClear = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True (@($ec.evidence_notes).Count -eq 0 -and $afterEvidenceClear.operator_notes.Count -eq 2) 'evidence clear leaves operator notes unchanged'
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
    # Older run records predate memory measurements and must still requeue.
    $legacy = Get-JobRecord $rf $b.job_id
    $legacy.PSObject.Properties.Remove('peak_memory_gb')
    Write-Utf8 (Join-Path $rf "jobs/$($b.job_id).json") ($legacy | ConvertTo-Json -Depth 12)
    $legacyStatus = Invoke-DtJob @('status', '-RunFolder', $rf, '-JobId', $b.job_id)
    Assert-True ($null -eq $legacyStatus.peak_memory_gb) 'legacy status exposes a null peak'
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

    # FS-96: job custody must retain a grandchild after its intermediate parent exits.
    if ($IsWindows) {
        $rf = New-RunFolder 'cancel-process-tree'
        $directMarker = 'dt-job-child-' + [guid]::NewGuid().ToString('N')
        do {
            $pingMarker = '127.0.0.' + (Get-Random -Minimum 2 -Maximum 255)
        } while (@(Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" | Where-Object { $_.CommandLine -like "*$pingMarker*" }).Count -gt 0)
        $fixture = Join-Path $rf 'launch-tree.ps1'
        $custodyScript = (Join-Path $scriptDir 'worker-process-tree.ps1').Replace("'", "''")
        Write-Utf8 $fixture @"
`$ErrorActionPreference = 'Stop'
. '$custodyScript'
if ((Initialize-WorkerProcessJob) -ne 'job_object' -or -not `$script:WorkerJobKillOnClose) { throw 'fixture requires kill-on-close job custody' }
`$psi = [Diagnostics.ProcessStartInfo]::new('cmd.exe')
`$psi.UseShellExecute = `$false
`$psi.CreateNoWindow = `$true
`$psi.Arguments = '/c start /b ping -n 300 $pingMarker'
`$intermediate = [Diagnostics.Process]::Start(`$psi)
`$intermediate.WaitForExit()
`$psi = [Diagnostics.ProcessStartInfo]::new('pwsh')
`$psi.UseShellExecute = `$false
`$psi.CreateNoWindow = `$true
foreach (`$arg in @('-NoProfile', '-Command', 'Start-Sleep 300  # $directMarker')) { `$psi.ArgumentList.Add(`$arg) }
`$null = [Diagnostics.Process]::Start(`$psi)
Start-Sleep 300
"@
        $treeJob = $null
        try {
            $treeJob = Invoke-DtJob @('start', '-RunFolder', $rf, '-Command', "& '$($fixture.Replace("'", "''"))'")
            $deadline = [DateTime]::UtcNow.AddSeconds(20)
            do {
                $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE' OR Name = 'pwsh.exe'")
                $pingChildren = @($processes | Where-Object { $_.Name -ieq 'ping.exe' -and $_.CommandLine -like "*$pingMarker*" })
                $directChildren = @($processes | Where-Object { $_.Name -ieq 'pwsh.exe' -and $_.CommandLine -like "*$directMarker*" })
                if ($pingChildren.Count -gt 0 -and $directChildren.Count -gt 0) { break }
                Start-Sleep -Milliseconds 250
            } while ([DateTime]::UtcNow -lt $deadline)
            Assert-True ($pingChildren.Count -eq 1 -and $directChildren.Count -eq 1) 'cancel fixture starts an orphan grandchild and a direct child after cmd exits'
            Assert-True (Test-ProcessGone $pingChildren[0].ParentProcessId) 'cancel fixture intermediate parent has exited'
            $cancelled = Invoke-DtJob @('cancel', '-RunFolder', $rf, '-JobId', $treeJob.job_id)
            Assert-True ($cancelled.status -eq 'cancelled') 'process tree job is cancelled'
            $remaining = @(Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE' OR Name = 'pwsh.exe'" | Where-Object { $_.CommandLine -like "*$pingMarker*" -or $_.CommandLine -like "*$directMarker*" })
            Assert-True ($remaining.Count -eq 0) 'cancel removes the orphan grandchild and direct child markers'

            $deadRecord = Get-JobRecord -RunFolder $rf -JobId $treeJob.job_id
            $deadProbe = ". '$($dtJob.Replace("'", "''"))'; `$deadPidRecord = Get-Content -Raw -LiteralPath '$((Join-Path $rf "jobs/$($treeJob.job_id).json").Replace("'", "''"))' | ConvertFrom-Json; @(Stop-DtJobProcesses -Record `$deadPidRecord).Count"
            $deadCount = & pwsh -NoProfile -Command $deadProbe
            Assert-True ($LASTEXITCODE -eq 0 -and "$deadCount" -eq '0' -and (Test-ProcessGone $deadRecord.pid) -and (Test-ProcessGone $deadRecord.runner_pid)) 'Stop-DtJobProcesses returns an empty array for dead pids'
        }
        finally {
            if ($treeJob) { & pwsh -NoProfile -File $dtJob cancel -RunFolder $rf -JobId $treeJob.job_id -Json | Out-Null }
            Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE' OR Name = 'pwsh.exe'" | Where-Object { $_.CommandLine -like "*$pingMarker*" -or $_.CommandLine -like "*$directMarker*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
    } else { Write-Output 'SKIP: FS-96 Windows process tree cancellation and dead-pid regressions' }

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
    # The first job's record turns terminal before its final event lands, so read the
    # predecessor seq from the events written before job two, not from the earlier snapshot.
    $lastSeq = [int](@($parsed | Where-Object { $_.job_id -ne $job2.job_id -and $after.Count -ge 1 -and [int]$_.seq -lt $after[0] } | ForEach-Object { [int]$_.seq } | Measure-Object -Maximum).Maximum)
    Assert-True ($after.Count -ge 1 -and $after[0] -eq $lastSeq + 1 -and (($after -join ',') -eq (($lastSeq + 1)..($lastSeq + $after.Count) -join ','))) "events continue at the next seq ($lastSeq -> $($after -join ','))"

    # FS-110: launch-time delegation uses the operator verb's record and safety checks.
    $rf = New-RunFolder 'launch-delegate'
    $state = Join-Path $rf '_build-state.md'
    Write-Utf8 $state "run_status: runnable`nlast_consumed_event_seq: 0`n"
    $registerDelegate = @('register-run', '-RunFolder', $rf, '-RunId', 'launch-delegate', '-BuildStatePath', $state, '-PinnedHost', 'codex', '-Managed')
    Invoke-DtJob ($registerDelegate + @('-Delegate', '  launch-session  ')) | Out-Null
    $delegated = Get-Content -Raw (Join-Path $rf 'approvals.json') | ConvertFrom-Json
    Assert-True ($delegated.delegate.name -ceq 'launch-session' -and $delegated.delegate.set_utc -and ($delegated.delegate.PSObject.Properties.Name -join ',') -ceq 'name,set_utc') 'register-run stores the trimmed delegate with the delegate verb record shape'
    $savedDelegate = $delegated.delegate | ConvertTo-Json -Compress
    Invoke-DtJob $registerDelegate | Out-Null
    Assert-True (((Get-Content -Raw (Join-Path $rf 'approvals.json') | ConvertFrom-Json).delegate | ConvertTo-Json -Compress) -ceq $savedDelegate) 'registration without Delegate preserves existing delegation'
    $routine = Invoke-DtJob @('await-danny', '-RunFolder', $rf, '-Operation', 'attempt-budget', '-Message', 'Retry fixture attempt.')
    $pending = (Get-Content -Raw (Join-Path $rf 'approvals.json') | ConvertFrom-Json).awaiting
    Assert-True ($routine.alert -eq 'delegated' -and $pending.delegated_to -ceq 'launch-session' -and ([datetime]$pending.escalate_after_utc - [datetime]$pending.since_utc).TotalMinutes -ge 15 -and -not (Test-Path (Join-Path $rf 'notifications.jsonl'))) 'routine launch stop records delegation and defers Danny alert for fifteen minutes'
    # FS-120: watches see the recorded owner, decision and delivery for the current stop.
    $routineStatus = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True ($routineStatus.run_status -eq 'awaiting_danny' -and $routineStatus.awaiting.awaiting_owner -ceq 'delegate' -and $routineStatus.awaiting.delegated_to -ceq 'launch-session') 'routine stop status names the delegate owner'
    Assert-True ($routineStatus.awaiting.operation -ceq $pending.operation -and $routineStatus.awaiting.since_utc -eq $pending.since_utc -and $routineStatus.awaiting.message -ceq $pending.message -and $routineStatus.awaiting.alerted_danny -eq $false) 'routine status retains stop details and reports no delivered Danny alert'
    $urgent = Invoke-DtJob @('await-danny', '-RunFolder', $rf, '-Operation', 'irreversible-fixture', '-Message', 'Fixture only.')
    $pending = (Get-Content -Raw (Join-Path $rf 'approvals.json') | ConvertFrom-Json).awaiting
    $notifications = @(Get-Content (Join-Path $rf 'notifications.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($urgent.alert -ne 'delegated' -and -not $pending.PSObject.Properties['delegated_to'] -and @($notifications | Where-Object { $_.key -match ':awaiting:irreversible-fixture:' }).Count -eq 1) 'irreversible launch stop immediately attempts Danny alert under the temp router guard'
    Assert-True ((Test-Path $env:DT_TEST_DM_LOG) -and (Get-Content -Raw $env:DT_TEST_DM_LOG) -match 'irreversible-fixture') 'irreversible fixture alert lands on the fake transport, not a live channel'
    $urgentStatus = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True ($urgentStatus.awaiting.awaiting_owner -ceq 'danny' -and -not $urgentStatus.awaiting.delegated_to -and $urgentStatus.awaiting.operation -ceq 'irreversible-fixture' -and $urgentStatus.awaiting.alerted_danny -eq $true) 'irreversible stop status names Danny and confirms fake transport delivery'
    # Delivery must match this boundary's sequence; another stop's DM or a pending row is insufficient.
    $notificationPath = Join-Path $rf 'notifications.jsonl'
    $deliveredLog = Get-Content -Raw $notificationPath
    $currentKey = "dt-build:launch-delegate:awaiting:irreversible-fixture:$($pending.seq)"
    Write-Utf8 $notificationPath (([ordered]@{ key = $currentKey; status = 'pending' } | ConvertTo-Json -Compress) + "`n" + ([ordered]@{ key = "${currentKey}-old"; status = 'delivered' } | ConvertTo-Json -Compress))
    $pendingStatus = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True ($pendingStatus.awaiting.awaiting_owner -ceq 'danny' -and $pendingStatus.awaiting.alerted_danny -eq $false) 'pending delivery and another boundary delivery do not count as alerting Danny'
    Write-Utf8 $notificationPath $deliveredLog
    Invoke-DtJob @('await-danny', '-RunFolder', $rf, '-Operation', 'manual-review', '-Message', 'Decide whether to retry.', '-AlwaysNotify') | Out-Null
    $forcedStatus = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True ($forcedStatus.awaiting.awaiting_owner -ceq 'danny' -and $forcedStatus.awaiting.alerted_danny -eq $true) 'AlwaysNotify status reuses persisted routing even for routine wording'
    foreach ($invalid in @('blank', 'coordinator', 'job')) {
        $name = if ($invalid -eq 'blank') { '   ' } else { 'forbidden-session' }
        if ($invalid -eq 'coordinator') { $env:DT_BUILD_COORDINATOR_ID = 'fixture' }
        if ($invalid -eq 'job') { $env:DT_JOB_ID = 'fixture' }
        try {
            $raw = & pwsh -NoProfile -File $dtJob @registerDelegate -Delegate $name -AllowTempRunFolder -Json 2>&1
            Assert-True ($LASTEXITCODE -ne 0 -and ($raw -join ' ') -match 'DT_JOB_(USAGE|OPERATOR_ONLY)') "register-run rejects $invalid delegate assignment"
        } finally { Remove-Item Env:DT_BUILD_COORDINATOR_ID, Env:DT_JOB_ID -ErrorAction SilentlyContinue }
    }
    Assert-True (((Get-Content -Raw (Join-Path $rf 'approvals.json') | ConvertFrom-Json).delegate | ConvertTo-Json -Compress) -ceq $savedDelegate) 'rejected delegate assignments leave the original record unchanged'

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
    # FS-94: a continuation_requested event after the stop must not hide it; status reads run_status.
    Invoke-DtJob @('request-continuation', '-RunFolder', $rf, '-Reason', 'fixture rotation') | Out-Null
    $stopped = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True ($stopped.run_status -eq 'awaiting_danny' -and $stopped.awaiting.operation -ceq 'immediate-review' -and [int64]$stopped.awaiting.seq -gt 0) 'run status reports awaiting_danny and the pending stop after a later continuation event'
    Invoke-DtJob @('approve', '-RunFolder', $rf, '-Operation', 'immediate-review', '-Reason', '  Danny chose option A.  ') | Out-Null
    $reasonRecord = @((Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json).approvals)[-1]
    Assert-True ($reasonRecord.operation -ceq 'immediate-review' -and $reasonRecord.reason -ceq 'Danny chose option A.') 'FS-124: approve stores the trimmed -Reason on the approval record'
    $resumed = Invoke-DtJob @('status', '-RunFolder', $rf)
    Assert-True ($resumed.run_status -eq 'runnable' -and $null -eq $resumed.awaiting) 'run status clears the pending stop after approval'
    Invoke-DtJob @('approve', '-RunFolder', $rf, '-Operation', 'immediate-review') | Out-Null
    Assert-True ((Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json).approvals.Count -eq 2) 'immediate approve twice records only one new approval without a queue'
    # FS-95: a later approval write keeps earlier timestamp text byte-for-byte (no trailing-zero trim).
    $zeroStamp = '2026-10-15T16:14:05.5441830Z'
    $approvalText = [regex]::Replace((Get-Content -LiteralPath $pendingPath -Raw), '"approved_utc":\s*"[^"]+"', ('"approved_utc": "' + $zeroStamp + '"'), 1)
    Write-Utf8 $pendingPath $approvalText
    Invoke-DtJob @('await-danny', '-RunFolder', $rf, '-Operation', 'timestamp-text', '-Message', 'fixture only') | Out-Null
    Invoke-DtJob @('approve', '-RunFolder', $rf, '-Operation', 'timestamp-text') | Out-Null
    Assert-True ((Get-Content -LiteralPath $pendingPath -Raw).Contains('"' + $zeroStamp + '"')) 'approval rewrites preserve stored timestamp text exactly'
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

    if ($script:failed -gt 0) { $exitCode = 1 } else { Write-Output 'PASS: dt-job suite' }
}
catch {
    $script:failed++
    Write-Output "FAIL: $($_.Exception.Message)"
    Write-Output $_.ScriptStackTrace
    $exitCode = 1
}
finally {
    [Environment]::SetEnvironmentVariable('DT_MODEL_ROUTER_STATE', $savedRouterState)
    [Environment]::SetEnvironmentVariable('DT_MODEL_ROUTER_ALERT_TRANSPORT', $savedAlertTransport)
    [Environment]::SetEnvironmentVariable('DT_TEST_DM_LOG', $savedDmLog)
    foreach ($name in $pinEnvNames) { [Environment]::SetEnvironmentVariable($name, $pinSavedEnv[$name]) }
    Write-Output "SUMMARY: $script:passed passed, $script:failed failed"
    # Unlink only: a recursive delete would follow the junction into the real skill folder.
    if ($junctionLink -and [IO.Directory]::Exists($junctionLink)) { [IO.Directory]::Delete($junctionLink) }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

exit $exitCode
