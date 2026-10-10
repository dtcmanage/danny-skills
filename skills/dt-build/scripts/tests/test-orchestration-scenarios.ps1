#Requires -Version 7.0
# Part G. Synthetic by default: only dt-job owns detached jobs. No task registration or live settings.
# -Live additionally calls both real model wrappers and launches one managed coordinator per host.
param([switch]$Live, [string]$EvidenceDir)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Live -and -not $EvidenceDir) { throw '-Live requires a caller-named -EvidenceDir.' }
$scripts = Split-Path -Parent $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $scripts '../../..')).Path
$jobScript = Join-Path $scripts 'dt-job.ps1'
$watcher = Join-Path $scripts 'dt-build-watcher.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('dt-scenarios-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$evidence = if ($EvidenceDir) { [IO.Path]::GetFullPath($EvidenceDir) } else { Join-Path $root 'evidence' }
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$saved = @{}
$envNames = @('CODEX_HOME','CLAUDE_CONFIG_DIR','DT_BUILD_STATE_DIR','DT_BUILD_COORDINATOR_ID','DT_BUILD_COORDINATOR_LOCK_HELD','DT_JOB_ID','DT_MODEL_ROUTER_STATE','DT_MODEL_ROUTER_ALERT_TRANSPORT','DT_BUILD_COORDINATOR_LAUNCHER','DT_BUILD_VENDOR_LIMITS_SCRIPT','DT_BUILD_WATCHER_NOW_UTC','DT_BUILD_CTX_SOFT_MARGIN','DT_BUILD_CTX_HARD_MARGIN','DT_BUILD_CTX_CEILING','GIT_INDEX_FILE','DT_SCENARIO_ROOT','DT_SCENARIO_BLOCKED','DT_SCENARIO_FAIL')
foreach ($name in $envNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $null) }
$env:CODEX_HOME = Join-Path $root 'codex'
$env:CLAUDE_CONFIG_DIR = Join-Path $root 'claude'
$env:DT_MODEL_ROUTER_STATE = Join-Path $root 'router'
$env:DT_SCENARIO_ROOT = $root
$script:commands = 0
$script:passed = 0
$script:failed = 0
$script:runs = @()
function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Quote([string]$Text) { "'" + $Text.Replace("'", "''") + "'" }
function Call([string]$File, [string[]]$Arguments, [switch]$AllowFailure) {
    $script:commands++
    $log = Join-Path $evidence ('command-{0:d4}.txt' -f $script:commands)
    & pwsh -NoProfile -File $File @Arguments *> $log
    $code = $LASTEXITCODE
    $text = [IO.File]::ReadAllText($log)
    [IO.File]::AppendAllText((Join-Path $evidence 'commands.txt'), ('pwsh -NoProfile -File ' + (Quote $File) + ' ' + ($Arguments | ForEach-Object { Quote $_ } | Join-String -Separator ' ') + " => exit $code; $log`n"))
    if (-not $AllowFailure -and $code -ne 0) { throw "exit $code; $log; $($text.Substring(0,[Math]::Min(500,$text.Length)))" }
    [pscustomobject]@{ exit = $code; text = $text; path = $log }
}
function Job([string[]]$Arguments) { (Call $jobScript ($Arguments + '-Json')).text | ConvertFrom-Json }
function Rows([string]$Path) { if (Test-Path -LiteralPath $Path) { foreach ($line in [IO.File]::ReadLines($Path)) { if ($line.Trim()) { $line | ConvertFrom-Json } } } }
function Tick([DateTime]$Now = [DateTime]::UtcNow) {
    $env:DT_BUILD_WATCHER_NOW_UTC = $Now.ToString('o')
    try { Call $watcher @() | Out-Null } finally { Remove-Item Env:DT_BUILD_WATCHER_NOW_UTC -ErrorAction SilentlyContinue }
}
function New-Run([string]$Name, [string]$Vendor = 'claude', [bool]$Managed = $true) {
    $env:DT_BUILD_STATE_DIR = Join-Path $root "registry-$Name"
    $folder = Join-Path $root "runs/$Name"
    $state = Join-Path $folder '_build-state.md'
    $template = [IO.File]::ReadAllText((Join-Path $repoRoot 'skills/dt-pipeline/templates/build-state-template.md'))
    Write-Text $state ($template.Replace('__RUN_STATUS__','runnable').Replace('__LAST_CONSUMED_EVENT_SEQ__','0').Replace('__UPDATED_UTC__',[DateTime]::UtcNow.ToString('o')))
    $args = @('register-run','-RunFolder',$folder,'-RunId',$Name,'-BuildStatePath',$state,'-PinnedHost',$Vendor)
    if ($Managed) { $args += '-Managed' }
    Job $args | Out-Null
    $run = [pscustomobject]@{ folder = $folder; state = $state; id = $Name }
    $script:runs += $run
    return $run
}
function Start-Echo($Run, [int]$Seconds = 0) {
    Job @('start','-RunFolder',$Run.folder,'-Command',"Start-Sleep -Seconds $Seconds; Write-Output echo",'-TimeoutSec','90')
}
function Wait-Result($Run, [string]$Id) { Job @('wait','-RunFolder',$Run.folder,'-JobId',$Id,'-All','-TimeoutSec','60') }
function Record($Run, [string]$Id) { [IO.File]::ReadAllText((Join-Path $Run.folder "jobs/$Id.json")) | ConvertFrom-Json }
function Wait-Running($Run, [string]$Id) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $row = Record $Run $Id
        if ($row.status -eq 'running' -and $row.pid) { return $row }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Job $Id did not start"
}
function Lease($Run, [string]$Id, [string]$Vendor = 'claude', [int]$ProcessId = 0) {
    $args = @('lease','-RunFolder',$Run.folder,'-Action','acquire','-CoordinatorId',$Id,'-Host',$Vendor,'-LaunchedBy','watcher')
    if ($ProcessId) { $args += @('-Pid',[string]$ProcessId) }
    Job $args | Out-Null
}
function Consume($Run, [string]$Coordinator = 'next') {
    $status = Job @('status','-RunFolder',$Run.folder)
    Job @('consume','-RunFolder',$Run.folder,'-CoordinatorId',$Coordinator,'-Seq',[string]$status.last_event_seq) | Out-Null
}
function Launches($Run) { @(Rows (Join-Path $Run.folder 'launches.jsonl') | Where-Object { $_.type -eq 'launch' }).Count }
function Dms { @(Rows (Join-Path $root 'dms.jsonl')).Count }
function Scenario([int]$Number, [string]$Name, [scriptblock]$Body) {
    try { & $Body | Out-Null; $script:passed++; Write-Output "PASS $Number $Name" }
    catch { $script:failed++; Write-Output "FAIL $Number $Name : $($_.Exception.Message)" }
    finally { $env:DT_SCENARIO_FAIL = ''; $env:DT_SCENARIO_BLOCKED = ''; Remove-Item Env:DT_BUILD_COORDINATOR_ID -ErrorAction SilentlyContinue }
}

$transport = Join-Path $root 'transport.ps1'
Write-Text $transport @'
param($request)
if ($request['kind'] -eq 'secret') { return 'synthetic' }
if ([string]$request['uri'] -like '*/oauth2/applications/@me') { return @{owner=@{id='1'}} }
if ([string]$request['uri'] -like '*/messages') { [IO.File]::AppendAllText((Join-Path $env:DT_SCENARIO_ROOT 'dms.jsonl'), ([string]$request['body'] + "`n")) }
return @{id='synthetic'}
'@
$limits = Join-Path $root 'limits.ps1'
Write-Text $limits @'
param([string]$Vendor,[switch]$Json)
@{vendor=$Vendor;blocked=($env:DT_SCENARIO_BLOCKED -eq $Vendor);reason=$null;used_percent=10;resets_at_utc=$null} | ConvertTo-Json -Compress
'@
$launcher = Join-Path $root 'launcher.ps1'
Write-Text $launcher @'
param([Alias('Host')][string]$CoordinatorHost,[string]$RunId,[string]$RunFolder,[string]$BuildStatePath,[string]$CoordinatorId)
$job = '__JOB__'
& pwsh -NoProfile -File $job lease -RunFolder $RunFolder -Action acquire -CoordinatorId $CoordinatorId -Host $CoordinatorHost -LaunchedBy watcher -Json *> $null
if ($LASTEXITCODE) { exit 1 }
if (-not $env:DT_SCENARIO_FAIL) {
    $s = & pwsh -NoProfile -File $job status -RunFolder $RunFolder -Json | ConvertFrom-Json
    & pwsh -NoProfile -File $job consume -RunFolder $RunFolder -CoordinatorId $CoordinatorId -Seq $s.last_event_seq -Json *> $null
}
& pwsh -NoProfile -File $job lease -RunFolder $RunFolder -Action release -CoordinatorId $CoordinatorId -Json *> $null
if ($env:DT_SCENARIO_FAIL) { exit 1 }
'@
Write-Text $launcher ([IO.File]::ReadAllText($launcher).Replace('__JOB__',$jobScript.Replace("'","''")))
$env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $transport
$env:DT_BUILD_VENDOR_LIMITS_SCRIPT = $limits
$env:DT_BUILD_COORDINATOR_LAUNCHER = $launcher
. (Join-Path $scripts 'report-contract.ps1')

function Dispatch-Stub([string]$Name, [string]$CoordinatorHost, [string]$Vendor) {
    $run = New-Run $Name $CoordinatorHost
    $report = Join-Path $run.folder 'worker-report.md'
    $provenance = Join-Path $run.folder 'worker-provenance.json'
    $wrapper = Join-Path $run.folder "invoke-$Vendor-chunk-stub.ps1"
    Write-Text $wrapper @"
[IO.File]::WriteAllText($(Quote $report), @'
DT_BUILD_REPORT_VERSION: 3
RUN_ID: $Name
chunk_id: echo
attempt: 1
VERDICT: PASS
CHANGED_FILES:
NONE
COMMANDS_AND_RESULTS:
Write-Output echo => exit 0
EVIDENCE_PATHS:
NONE
UNRESOLVED_BLOCKERS:
NONE
DISCOVERED_ENHANCEMENTS:
NONE
CONTINUATION_STATE:
NONE
'@)
[IO.File]::WriteAllText($(Quote $provenance), '{"vendor":"$Vendor","resolved_model":"stub","synthetic":true}')
Write-Output echo
"@
    $j = Job @('start','-RunFolder',$run.folder,'-Kind','worker','-Vendor',$Vendor,'-Category','mechanical','-ScriptPath',$wrapper)
    Wait-Result $run $j.job_id | Out-Null
    Assert ((Record $run $j.job_id).status -eq 'succeeded') 'stub worker failed'
    $shape = Get-ReportShapeResult -Text ([IO.File]::ReadAllText($report)) -RunId $Name -ChunkId echo -ExpectedAttempt 1
    Assert ($shape.version -eq 3 -and @($shape.errors).Count -eq 0) 'v3 shape invalid'
    Assert (([IO.File]::ReadAllText($provenance) | ConvertFrom-Json).vendor -eq $Vendor) 'wrong provenance vendor'
}

function Invoke-LiveValidation {
    # Credentials are copied only when the caller explicitly selects -Live. Neither home gets live
    # settings, hooks, or a registry. Remove the credential copies in finally, retaining only evidence.
    $credentialCopies = @()
    try {
        foreach ($pair in @(@('CODEX_HOME','auth.json'), @('CLAUDE_CONFIG_DIR','.credentials.json'))) {
            $sourceHome = $saved[$pair[0]]
            if (-not $sourceHome) { $sourceHome = Join-Path $HOME $(if ($pair[0] -eq 'CODEX_HOME') { '.codex' } else { '.claude' }) }
            $source = Join-Path $sourceHome $pair[1]
            $destination = Join-Path ([Environment]::GetEnvironmentVariable($pair[0])) $pair[1]
            if (Test-Path -LiteralPath $source) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
                Copy-Item -LiteralPath $source -Destination $destination
                $credentialCopies += $destination
            }
        }
        . (Join-Path $repoRoot 'scripts/model-router/router-platform.ps1')
        $sourceRouter = Get-RouterStatePath -StateOverride $saved['DT_MODEL_ROUTER_STATE']
        New-Item -ItemType Directory -Path $env:DT_MODEL_ROUTER_STATE -Force | Out-Null
        # Copy the approved routing/usage snapshot; wrappers write only to the isolated copy.
        foreach ($file in @('roster.json','vendor-blocks.json','claude-usage.json','codex-usage.json')) {
            $source = Join-Path $sourceRouter $file
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $env:DT_MODEL_ROUTER_STATE $file) }
        }
        foreach ($vendor in @('codex','claude')) {
            Scenario $(if ($vendor -eq 'codex') { 1 } else { 2 }) "LIVE real $vendor wrapper" {
                $r = New-Run "live-worker-$vendor" $(if($vendor -eq 'codex'){'claude'}else{'codex'})
                $work = Join-Path $r.folder 'repo'
                New-Item -ItemType Directory -Path $work -Force | Out-Null
                & git -C $work init --quiet -b main *> (Join-Path $evidence "live-$vendor-git.txt")
                Assert ($LASTEXITCODE -eq 0) 'live temp git init'
                $prompt = Join-Path $r.folder 'prompt.md'
                $output = Join-Path $evidence "live-$vendor-report.md"
                Write-Text $prompt @"
RUN_ID: $($r.id)
chunk_id: echo
attempt: 1
Run only this one-line task in the temporary repo: Write-Output echo. Do not edit files or call other agents.
Return exactly a dt-build v3 report: DT_BUILD_REPORT_VERSION: 3, RUN_ID: $($r.id), chunk_id: echo, attempt: 1, VERDICT: PASS, CHANGED_FILES: NONE, COMMANDS_AND_RESULTS: the echo command and result, EVIDENCE_PATHS: NONE, UNRESOLVED_BLOCKERS: NONE, DISCOVERED_ENHANCEMENTS: NONE, CONTINUATION_STATE: NONE. Put each header and its value on separate lines except the first four identity fields.
"@
                $wrapper = Join-Path $scripts "invoke-$vendor-chunk.ps1"
                $command = "& $(Quote $wrapper) -ProjectPath $(Quote $work) -PromptPath $(Quote $prompt) -OutputPath $(Quote $output) -Category mechanical -TimeoutMs 120000 -Json"
                $j = Job @('start','-RunFolder',$r.folder,'-Kind','worker','-Vendor',$vendor,'-Category','mechanical','-Command',$command,'-PassEnv','DT_MODEL_ROUTER_STATE','-TimeoutSec','150')
                $deadline = [DateTime]::UtcNow.AddSeconds(160)
                do { Wait-Result $r $j.job_id | Out-Null; $row = Record $r $j.job_id } while ($row.status -in @('running','queued') -and [DateTime]::UtcNow -lt $deadline)
                Assert ($row.status -eq 'succeeded') "live $vendor wrapper failed; retained evidence $output"
                $shape = Get-ReportShapeResult -Text ([IO.File]::ReadAllText($output)) -RunId $r.id -ChunkId echo -ExpectedAttempt 1
                Assert ($shape.version -eq 3 -and @($shape.errors).Count -eq 0) 'live report v3 failed'
                $provenance = [IO.File]::ReadAllText("$output.provenance.json") | ConvertFrom-Json
                Assert ($provenance.vendor -eq $vendor) 'live provenance vendor'
            }
        }
        foreach ($vendor in @('claude','codex')) {
            Scenario 8 "LIVE managed context guard on $vendor" {
                $r = New-Run "live-context-$vendor" $vendor
                $coordinator = "live-$vendor"
                $big = Join-Path $r.folder 'large.log'
                Write-Text $big ((1..501 | ForEach-Object { "large-log-line $_" }) -join "`n")
                # launch-managed-coordinator uses its standard resume prompt. The temp state carries
                # the bounded validation task; no production milestones, approvals, or mutable repo.
                $instructions = @"

## Live scenario 8 validation task (caller-authorized temporary run)
This run is solely a context guard test. Do not execute production work or spawn workers.
Use coordinator id $coordinator and run folder $($r.folder). Load the dt-build adapter for $vendor.
The harness will attach your actual transcript with baseline 1. Do not replace its baseline. Wait for the marker by calling dt-job status with your coordinator id, at most 15 calls. After the context line says rotate, attempt a direct Read of $big and a shell Get-Content read of the same log; these are deliberate test calls, expected to be denied on Claude and stopped by the watcher on Codex. Record any denials to $($r.folder)/live-hook-result.md. Request continuation with reason context_rotation, release the lease, and end. Do not approve anything. All evidence belongs in this temp run only.
"@
                [IO.File]::AppendAllText($r.state,$instructions)
                Write-Text (Join-Path $r.folder 'CLAUDE.md') $instructions
                Write-Text (Join-Path $r.folder 'AGENTS.md') $instructions
                $started = (Call (Join-Path $scripts 'launch-managed-coordinator.ps1') @('-Host',$vendor,'-RunId',$r.id,'-RunFolder',$r.folder,'-BuildStatePath',$r.state,'-CoordinatorId',$coordinator)).text | ConvertFrom-Json
                $processId = [int]$started.pid
                $startTime = (Get-Process -Id $processId).StartTime
                try {
                    . (Join-Path $scripts 'context-guard.ps1')
                    $deadline = [DateTime]::UtcNow.AddSeconds(120)
                    $transcript = $null
                    do {
                        $transcript = Find-DtCtxTranscript -TranscriptHost $vendor -Cwd $r.folder
                        if ($transcript) { break }
                        Start-Sleep -Milliseconds 500
                    } while ([DateTime]::UtcNow -lt $deadline)
                    Assert ([bool]$transcript) 'managed host produced no discoverable transcript'
                    # Attach the real transcript with low baseline. No synthetic token rows in live mode.
                    Write-Text (Join-Path $r.folder 'context-baseline.json') (@{coordinators=@{$coordinator=@{coordinator_id=$coordinator;host=$vendor;transcript_path=$transcript;baseline_tokens=1;session_id=[IO.Path]::GetFileNameWithoutExtension($transcript);transcript_source='explicit';marked_utc=[DateTime]::UtcNow.ToString('o')}}} | ConvertTo-Json -Depth 6)
                    $crossed = $false
                    do {
                        $tokens = Get-DtCtxTokens -TranscriptHost $vendor -TranscriptPath $transcript
                        if ($tokens -ge 70001) { $crossed = $true; break }
                        Start-Sleep -Milliseconds 500
                    } while ([DateTime]::UtcNow -lt $deadline)
                    Assert $crossed 'real coordinator did not cross the low-baseline hard limit in 120 seconds'
                    if ($vendor -eq 'codex') {
                        # Prevent automatic second live model launch; rotation itself remains real.
                        $env:DT_SCENARIO_BLOCKED = 'claude'
                        Consume $r
                        Tick
                        $rotation = @(Rows (Join-Path $r.folder 'rotations.jsonl'))
                        Assert ($rotation.Count -eq 1 -and $rotation[0].overshoot -ge 0) 'live Codex overshoot not recorded within one tick'
                        Assert ($null -eq (Get-Process -Id $processId -ErrorAction SilentlyContinue)) 'live Codex survived tick'
                    } else {
                        $resultPath = Join-Path $r.folder 'live-hook-result.md'
                        do { if (Test-Path -LiteralPath $resultPath) { break }; Start-Sleep -Milliseconds 500 } while ([DateTime]::UtcNow -lt $deadline)
                        Assert (Test-Path -LiteralPath $resultPath) 'live Claude did not record hook denials'
                        $denials = [IO.File]::ReadAllText($resultPath)
                        Assert ($denials -match 'Read' -and $denials -match '(Get-Content|shell)' -and $denials -match '(denied|deny)') 'both live read denials not recorded'
                    }
                    Copy-Item -LiteralPath $transcript -Destination (Join-Path $evidence "live-context-$vendor.jsonl")
                    Copy-Item -LiteralPath $r.state -Destination (Join-Path $evidence "live-context-$vendor-state.md")
                    foreach ($file in @('rotations.jsonl','live-hook-result.md')) {
                        $path = Join-Path $r.folder $file
                        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $evidence "live-$vendor-$file") }
                    }
                } finally {
                    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
                    if ($process -and $process.StartTime -eq $startTime) { $process.Kill($true); [void]$process.WaitForExit(10000) }
                    Job @('lease','-RunFolder',$r.folder,'-Action','release','-CoordinatorId',$coordinator) | Out-Null
                }
            }
        }
    } finally {
        foreach ($path in $credentialCopies) { Remove-Item -LiteralPath $path -Force }
    }
}

try {
    Scenario 1 'Claude coordinator dispatches a Codex worker' { Dispatch-Stub s01 claude codex }
    Scenario 2 'Codex coordinator dispatches a Claude worker' { Dispatch-Stub s02 codex claude }
    Scenario 3 'Missed notification' {
        $r = New-Run s03; $j = Start-Echo $r
        Wait-Result $r $j.job_id | Out-Null
        Tick
        Assert ((Record $r $j.job_id).status -eq 'succeeded') 'terminal state missing'
        Assert ((Launches $r) -eq 1) 'next coordinator did not act once'
        Tick; Assert ((Launches $r) -eq 1) 'consumed completion launched twice'
    }
    Scenario 4 'Coordinator killed mid-run' {
        $r = New-Run s04; $j = Start-Echo $r
        Wait-Result $r $j.job_id | Out-Null
        $active = Start-Echo $r 20
        $before = Wait-Running $r $active.job_id
        Lease $r killed
        $leasePath = Join-Path $r.folder 'coordinator.lease'
        $dead = [IO.File]::ReadAllText($leasePath) | ConvertFrom-Json
        $dead.pid = 424242; $dead.pid_start_utc = '2026-10-10T00:00:00Z'
        Write-Text $leasePath ($dead | ConvertTo-Json)
        # A watcher-owned lease with no surviving process represents the killed coordinator.
        Tick; Tick
        Assert ((Launches $r) -eq 1) 'managed relaunch count'
        Assert (@(Get-ChildItem (Join-Path $r.folder 'jobs') -Filter 'j-*.json').Count -eq 2) 'completed worker reran'
        Assert ((Record $r $j.job_id).status -eq 'succeeded') 'completed result lost'
        Assert ((Record $r $active.job_id).pid -eq $before.pid) 'mid-run job was replaced'
        Job @('cancel','-RunFolder',$r.folder,'-JobId',$active.job_id) | Out-Null
    }
    Scenario 5 'Quota fallback adopts running jobs' {
        $r = New-Run s05; $j = Start-Echo $r 20; $before = Wait-Running $r $j.job_id
        $env:DT_SCENARIO_BLOCKED = 'claude'
        Job @('request-continuation','-RunFolder',$r.folder) | Out-Null
        Tick
        $launch = @(Rows (Join-Path $r.folder 'launches.jsonl') | Where-Object { $_.type -eq 'launch' })[0]
        Assert ($launch.host -eq 'codex') 'blocked vendor did not fall back'
        $after = Record $r $j.job_id
        Assert ($after.pid -eq $before.pid -and $after.process_start_utc -eq $before.process_start_utc) 'running worker not adopted'
        Job @('cancel','-RunFolder',$r.folder,'-JobId',$j.job_id) | Out-Null
    }
    Scenario 6 'Fresh worker checkpoint and continuation reuses passing checks' {
        $r = New-Run s06
        $toy = Join-Path $root 'toy-repo'
        New-Item -ItemType Directory -Path $toy -Force | Out-Null
        Copy-Item (Join-Path $PSScriptRoot 'fixtures/toy-build/*') $toy
        & git -C $toy init --quiet -b main *> (Join-Path $evidence 'toy-init.txt')
        Assert ($LASTEXITCODE -eq 0) 'temp git init failed'
        $testCommand = 'pwsh -NoProfile -File check.ps1 -Milestone M01'
        $check = Call (Join-Path $toy 'check.ps1') @('-Milestone','M01')
        $hash = Job @('tree-hash','-WorkingTree',$toy)
        $recordPath = Join-Path $r.folder 'continuation.md'
        $record = [ordered]@{run_id='s06';chunk_id='echo';attempt=1;completed=@('M01 check');tests=@(@{command=$testCommand;exit_code=0;evidence_path=$check.path;tree_hash=$hash.tree_hash;recorded_utc=[DateTime]::UtcNow.ToString('o')});running_jobs=@();blockers=@();authorization=@();next_step='reuse M01 and run M02'}
        Write-Text $recordPath ("``````json`n" + ($record | ConvertTo-Json -Depth 6) + "`n``````")
        Call (Join-Path $scripts 'validate-continuation.ps1') @('-Path',$recordPath,'-RunId','s06','-ChunkId','echo','-Json') | Out-Null
        $fresh = Join-Path $r.folder 'fresh-worker.ps1'
        Write-Text $fresh @"
`$reuse = & pwsh -NoProfile -File $(Quote $jobScript) can-reuse -WorkingTree $(Quote $toy) -Record $(Quote $recordPath) -Command $(Quote $testCommand) -Json | ConvertFrom-Json
if (-not `$reuse.reuse) { throw 'passed check was not reusable' }
& pwsh -NoProfile -File $(Quote (Join-Path $toy 'check.ps1')) -Milestone M02
if (`$LASTEXITCODE) { exit `$LASTEXITCODE }
Write-Output 'M01 reused; M02 checked'
"@
        $j = Job @('start','-RunFolder',$r.folder,'-Kind','worker','-ScriptPath',$fresh)
        Wait-Result $r $j.job_id | Out-Null
        Assert ((Record $r $j.job_id).status -eq 'succeeded') 'fresh worker did not continue'
        $log = [IO.File]::ReadAllText((Join-Path $r.folder "jobs/$($j.job_id)/stdout.log"))
        Assert ($log.Contains('M01 reused') -and -not $log.Contains('PASS: echo M01')) 'passed check reran'
    }
    Scenario 7 'Long-running test survives coordinator rotation' {
        $r = New-Run s07; Lease $r old
        $j = Start-Echo $r 20; $before = Wait-Running $r $j.job_id
        Job @('request-continuation','-RunFolder',$r.folder,'-Reason','context_rotation') | Out-Null
        Job @('lease','-RunFolder',$r.folder,'-Action','release','-CoordinatorId','old') | Out-Null
        Tick
        $after = Record $r $j.job_id
        Assert ((Launches $r) -eq 1 -and $after.status -eq 'running') 'rotation did not occur with running test'
        Assert ($after.pid -eq $before.pid -and $after.process_start_utc -eq $before.process_start_utc) 'PID/start time changed'
        Job @('cancel','-RunFolder',$r.folder,'-JobId',$j.job_id) | Out-Null
    }
    Scenario 8 'Context guard transcript replay, hook refusals, and one-tick Codex stop' {
        $r = New-Run s08
        $transcript = Join-Path $r.folder 'replay.jsonl'
        $fixture = @([IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'fixtures/context-replay.jsonl')))
        Write-Text $transcript ($fixture[0] + "`n")
        Lease $r replay
        Job @('mark-bootstrap','-RunFolder',$r.folder,'-CoordinatorId','replay','-Host','claude','-TranscriptPath',$transcript) | Out-Null
        foreach ($step in @(@(1,'checkpoint'),@(2,'rotate'))) {
            [IO.File]::AppendAllText($transcript,$fixture[$step[0]] + "`n")
            $parsed = (Call (Join-Path $scripts 'context-guard.ps1') @('-Host','claude','-TranscriptPath',$transcript,'-Json')).text | ConvertFrom-Json
            Assert ($parsed.tokens -eq @(140000,175000)[$step[0]-1]) 'guard replay tokens'
            $status = Job @('status','-RunFolder',$r.folder,'-CoordinatorId','replay')
            Assert ($status.context -match $step[1]) "missing $($step[1]) signal"
        }
        $refused = Call $jobScript @('start','-RunFolder',$r.folder,'-CoordinatorId','replay','-Command','Write-Output forbidden','-Json') -AllowFailure
        Assert ($refused.exit -ne 0 -and $refused.text.Contains('ROTATE_REQUIRED')) 'dispatch not refused'
        $env:DT_BUILD_COORDINATOR_ID = 'replay'
        $big = Join-Path $r.folder 'large.log'; Write-Text $big ((1..501 | ForEach-Object { "line $_" }) -join "`n")
        $pre = Join-Path $scripts '../hooks/coordinator-pretooluse.ps1'
        foreach ($tool in @('Read','PowerShell')) {
            $input = @{session_id='replay';transcript_path=$transcript;cwd=$root;hook_event_name='PreToolUse';tool_name=$tool;tool_input=$(if($tool -eq 'Read'){@{file_path=$big}}else{@{command="Get-Content $(Quote $big)"}})}
            $hookLog = Join-Path $evidence "hook-$tool.json"
            ($input | ConvertTo-Json -Depth 6 -Compress) | & pwsh -NoProfile -File $pre > $hookLog
            $answer = [IO.File]::ReadAllText($hookLog) | ConvertFrom-Json
            Assert ($answer.hookSpecificOutput.permissionDecision -eq 'deny') "$tool log read not denied"
        }
        Remove-Item Env:DT_BUILD_COORDINATOR_ID
        $c = New-Run s08-codex codex
        Lease $c managed codex
        $leasePath = Join-Path $c.folder 'coordinator.lease'
        $lease = [IO.File]::ReadAllText($leasePath) | ConvertFrom-Json
        $lease.pid = 424242; $lease.pid_start_utc = '2026-10-10T00:00:00Z'
        Write-Text $leasePath ($lease | ConvertTo-Json)
        $rollout = Join-Path $c.folder 'codex.jsonl'
        Write-Text $rollout '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":175000}}}}'
        Write-Text (Join-Path $c.folder 'context-baseline.json') (@{coordinators=@{managed=@{coordinator_id='managed';host='codex';transcript_path=$rollout;baseline_tokens=100000;session_id=$null;transcript_source='explicit';marked_utc=[DateTime]::UtcNow.ToString('o')}}} | ConvertTo-Json -Depth 6)
        $stubTick = Join-Path $c.folder 'stub-tick.ps1'
        Write-Text $stubTick @"
. $(Quote $watcher)
`$script:alive = `$true
function Test-DtJobProcessIdentity { param(`$ProcessId,`$StartUtc) return (`$ProcessId -eq 424242 -and `$script:alive) }
function Get-WatcherDescendantProcesses { param(`$ProcessId,`$StartUtc) return @() }
function Stop-WatcherProcessTree { param(`$ProcessId) if (`$ProcessId -ne 424242) { throw 'wrong PID' }; `$script:alive = `$false }
Invoke-WatcherRun -Entry (Get-DtJobRegistryEntry -RunFolder $(Quote $c.folder)) | ConvertTo-Json -Depth 6
if (`$script:alive) { throw 'coordinator survived one tick' }
"@
        Call $stubTick @() | Out-Null
        $rotation = @(Rows (Join-Path $c.folder 'rotations.jsonl'))
        Assert ($rotation.Count -eq 1 -and $rotation[0].overshoot -eq 5000 -and $rotation[0].tokens_at_kill -eq 175000) 'overshoot not recorded'
    }
    Scenario 9 'Live coordinator outlasts the old lease window' {
        $r = New-Run s09; Lease $r waiting claude $PID
        $j = Start-Echo $r 2
        $leasePath = Join-Path $r.folder 'coordinator.lease'
        $lease = [IO.File]::ReadAllText($leasePath) | ConvertFrom-Json
        $lease.expires_utc = [DateTime]::UtcNow.AddMinutes(-20).ToString('o')
        Write-Text $leasePath ($lease | ConvertTo-Json)
        Tick; Assert ((Launches $r) -eq 0) 'watcher replaced living coordinator with expired lease'
        Job @('wait','-RunFolder',$r.folder,'-CoordinatorId','waiting','-JobId',$j.job_id,'-All','-TimeoutSec','30') | Out-Null
        Consume $r waiting; Tick
        Assert ((Launches $r) -eq 0) 'more than one coordinator advanced'
        $renewed = [IO.File]::ReadAllText($leasePath) | ConvertFrom-Json
        Assert ([DateTime]$renewed.expires_utc -gt [DateTime]::UtcNow) 'wait did not renew lease'
    }
    Scenario 10 'Consumed event, approval wait, finished run, failed launch stay quiet' {
        $r = New-Run s10-consumed
        Job @('request-continuation','-RunFolder',$r.folder) | Out-Null; Consume $r
        $dmBefore = Dms
        1..3 | ForEach-Object { Tick }
        Assert ((Launches $r) -eq 0 -and (Dms) -eq $dmBefore) 'consumed event repeated'
        $r = New-Run s10-approval
        Job @('await-danny','-RunFolder',$r.folder,'-Operation','merge','-Message','Synthetic approval boundary') | Out-Null
        $dmBefore = Dms; 1..3 | ForEach-Object { Tick }
        Assert ((Launches $r) -eq 0 -and (Dms) -eq $dmBefore) 'approval repeated'
        Job @('finish','-RunFolder',$r.folder) | Out-Null
        1..3 | ForEach-Object { Tick }
        Assert ((Launches $r) -eq 0 -and (Dms) -eq $dmBefore) 'finished run repeated'
        $r = New-Run s10-failed; $env:DT_SCENARIO_FAIL = '1'
        Job @('request-continuation','-RunFolder',$r.folder) | Out-Null
        $now = [DateTime]::UtcNow
        foreach ($seconds in @(0,121,722,2523,2600)) { Tick ($now.AddSeconds($seconds)) }
        Assert ((Launches $r) -eq 4) 'failed launch retry schedule'
        $dmBefore = Dms
        foreach ($seconds in @(2700,4000,9000)) { Tick ($now.AddSeconds($seconds)) }
        Assert ((Launches $r) -eq 4 -and (Dms) -eq $dmBefore) 'failed launches or stop DMs repeated'
        # Canned collect-usage rows for the same toy two-milestone build, each host/style.
        $ledger = Join-Path $root 'usage-ledger-fixture.jsonl'
        $rows = @()
        foreach ($vendor in @('claude','codex')) {
            foreach ($style in @('old','new')) {
                $folder = Join-Path $root "compare/$vendor-$style"
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
                Copy-Item (Join-Path $PSScriptRoot 'fixtures/toy-build/*') $folder
                $rows += @{run_id="$vendor-$style";host=$vendor;role='orchestrator';session_id="$style-first";started='2026-10-10T00:00:00Z';ctx_max=100000;weighted_total=100}
                foreach ($milestone in @('M01','M02')) {
                    $rows += @{run_id="$vendor-$style";host=$vendor;role='chunk';session_id=$milestone;started='2026-10-10T00:00:00Z';ctx_max=999999;weighted_total=10}
                    Call (Join-Path $folder 'check.ps1') @('-Milestone',$milestone) | Out-Null
                }
                if ($style -eq 'new') {
                    $rows += @{run_id="$vendor-$style";host=$vendor;role='orchestrator';session_id='replacement';started='2026-10-10T00:01:00Z';ctx_max=110000;weighted_total=20}
                    if ($vendor -eq 'codex') { Write-Text (Join-Path $folder 'rotations.jsonl') '{"overshoot":0}' }
                    else { Write-Text (Join-Path $folder 'jobs/events.jsonl') '{"type":"continuation_requested","reason":"context_rotation"}' }
                    Write-Text (Join-Path $folder 'jobs/reads.jsonl') ('{"path":"fixture","sha256":"a","selector":{"lines":"1-2"}}' + "`n" + '{"path":"fixture","sha256":"a","selector":{"lines":"1-2"}}')
                }
            }
        }
        Write-Text $ledger (($rows | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join "`n")
        foreach ($vendor in @('claude','codex')) {
            $out = Join-Path $evidence "compare-$vendor"
            Call (Join-Path $scripts 'compare-orchestration.ps1') @('-OldRunFolder',(Join-Path $root "compare/$vendor-old"),'-NewRunFolder',(Join-Path $root "compare/$vendor-new"),'-UsageLedgerPath',$ledger,'-OutputDir',$out) | Out-Null
            $comparison = [IO.File]::ReadAllText((Join-Path $out 'comparison.json')) | ConvertFrom-Json
            $old,$new = $comparison.runs
            Assert ($old.total_weighted_usage.value -eq 120 -and $new.total_weighted_usage.value -eq 140) 'comparison weighted sum'
            Assert ($new.coordinator_peak_context.value -eq 110000 -and $new.wake_count.value -eq 2 -and $new.rotation_cost.value -eq 20) 'comparison coordinator metrics'
            Assert ($null -eq $old.rereads.value -and $new.rereads.value -eq 1 -and $new.rotation_cost.estimate) 'comparison missing/estimated metrics'
        }
    }
    if ($Live) { Invoke-LiveValidation }
}
finally {
    # Retain evidence; cancel only jobs this test created. Never touch another registry/settings/task.
    Remove-Item Env:DT_BUILD_COORDINATOR_ID -ErrorAction SilentlyContinue
    foreach ($run in $script:runs) {
        foreach ($record in @(Get-ChildItem (Join-Path $run.folder 'jobs') -Filter 'j-*.json' -ErrorAction SilentlyContinue)) {
            $row = [IO.File]::ReadAllText($record.FullName) | ConvertFrom-Json
            if ($row.status -in @('running','queued')) { Call $jobScript @('cancel','-RunFolder',$run.folder,'-JobId',$row.job_id,'-Json') -AllowFailure | Out-Null }
        }
    }
    foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}
Write-Output "TOTAL: $script:passed passed; $script:failed failed; evidence: $evidence"
if ($script:failed) { exit 1 }
exit 0
