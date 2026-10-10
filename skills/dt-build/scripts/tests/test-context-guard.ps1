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

function Add-Line {
    param([string]$Path, $Object)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $text = if ($Object -is [string]) { $Object } else { $Object | ConvertTo-Json -Depth 8 -Compress }
    [System.IO.File]::AppendAllText($Path, $text + "`n", [System.Text.UTF8Encoding]::new($false))
}

$scriptDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$skillDir = Split-Path -Parent $scriptDir
$repoRoot = (Resolve-Path (Join-Path $scriptDir '..\..\..')).Path
$dtJob = Join-Path $scriptDir 'dt-job.ps1'
$guard = Join-Path $scriptDir 'context-guard.ps1'
$watcher = Join-Path $scriptDir 'dt-build-watcher.ps1'
$preHook = Join-Path $skillDir 'hooks\coordinator-pretooluse.ps1'
$postHook = Join-Path $skillDir 'hooks\coordinator-posttooluse.ps1'
$templatePath = Join-Path $repoRoot 'skills\dt-pipeline\templates\build-state-template.md'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-ctx-tests-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$savedEnv = @{}
foreach ($name in @('DT_BUILD_STATE_DIR', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'DT_BUILD_COORDINATOR_ID', 'DT_BUILD_CTX_SOFT_MARGIN', 'DT_BUILD_CTX_HARD_MARGIN', 'DT_BUILD_CTX_CEILING', 'DT_MODEL_ROUTER_STATE', 'DT_MODEL_ROUTER_ALERT_TRANSPORT', 'DT_BUILD_COORDINATOR_LAUNCHER', 'DT_BUILD_VENDOR_LIMITS_SCRIPT', 'DT_BUILD_WATCHER_NOW_UTC', 'DT_BUILD_COORDINATOR_LOCK_HELD', 'DT_JOB_ID', 'DT_TEST_DM_LOG', 'DT_TEST_LAUNCH_LOG')) {
    $savedEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
}

# Isolation: temp registry, temp transcript roots, temp router state, fake alert transport, fake launcher.
$env:DT_BUILD_STATE_DIR = Join-Path $tempRoot 'state'
$env:CLAUDE_CONFIG_DIR = Join-Path $tempRoot 'claude-config'
$env:CODEX_HOME = Join-Path $tempRoot 'codex-home'
$env:DT_MODEL_ROUTER_STATE = Join-Path $tempRoot 'router-state'
$env:DT_TEST_DM_LOG = Join-Path $tempRoot 'dms.jsonl'
$env:DT_TEST_LAUNCH_LOG = Join-Path $tempRoot 'launches-fake.jsonl'
foreach ($name in @('DT_BUILD_COORDINATOR_ID', 'DT_BUILD_CTX_SOFT_MARGIN', 'DT_BUILD_CTX_HARD_MARGIN', 'DT_BUILD_CTX_CEILING', 'DT_BUILD_WATCHER_NOW_UTC', 'DT_BUILD_COORDINATOR_LOCK_HELD', 'DT_JOB_ID')) {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}
$fakeTransport = Join-Path $tempRoot 'fake-alert-transport.ps1'
Write-Utf8 -Path $fakeTransport -Content @'
param($request)
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
[System.IO.File]::AppendAllText($env:DT_TEST_LAUNCH_LOG, (([ordered]@{ run_id = $RunId; host = $CoordinatorHost; coordinator_id = $CoordinatorId } | ConvertTo-Json -Compress) + "`n"))
'@
$env:DT_BUILD_COORDINATOR_LAUNCHER = $fakeLauncher
$fakeLimits = Join-Path $tempRoot 'fake-vendor-limits.ps1'
Write-Utf8 -Path $fakeLimits -Content @'
param([string]$Vendor, [switch]$Json)
[ordered]@{ vendor = $Vendor; blocked = $false; reason = $null; used_percent = 10; resets_at_utc = $null } | ConvertTo-Json -Compress
'@
$env:DT_BUILD_VENDOR_LIMITS_SCRIPT = $fakeLimits

function Add-ClaudeUsage {
    # One request written as two content-block lines carrying the same usage, as Claude Code does.
    param([string]$Path, [long]$Total, [string]$Cwd = 'C:\fixture', [string]$RequestId = ([guid]::NewGuid().ToString('N')))
    $cacheRead = [long][Math]::Floor($Total * 0.8)
    $cacheWrite = [long][Math]::Floor($Total * 0.15)
    $inputTokens = $Total - $cacheRead - $cacheWrite
    foreach ($block in @(@{ type = 'text'; text = 'thinking about it' }, @{ type = 'tool_use'; name = 'Bash'; input = @{ command = 'git status' } })) {
        Add-Line $Path ([ordered]@{ type = 'assistant'; cwd = $Cwd; requestId = "req-$RequestId"; isSidechain = $false; message = [ordered]@{ id = "msg-$RequestId"; model = 'claude-test'; role = 'assistant'; content = @($block); usage = [ordered]@{ input_tokens = $inputTokens; cache_read_input_tokens = $cacheRead; cache_creation_input_tokens = $cacheWrite; output_tokens = 12 } } })
    }
}

function New-ClaudeTranscript {
    param([string]$Path, [long[]]$Totals, [string]$Cwd = 'C:\fixture')
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Add-Line $Path ([ordered]@{ type = 'user'; cwd = $Cwd; sessionId = [System.IO.Path]::GetFileNameWithoutExtension($Path); message = [ordered]@{ role = 'user'; content = 'start' } })
    foreach ($t in $Totals) {
        Add-ClaudeUsage -Path $Path -Total $t -Cwd $Cwd
        Add-Line $Path ([ordered]@{ type = 'user'; cwd = $Cwd; message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; content = 'On branch main' }) } })
    }
}

function Add-CodexTokens {
    param([string]$Path, [long]$InputTokens)
    Add-Line $Path ([ordered]@{ timestamp = [DateTime]::UtcNow.ToString('o'); type = 'event_msg'; payload = [ordered]@{ type = 'token_count'; info = [ordered]@{ total_token_usage = [ordered]@{ input_tokens = $InputTokens * 3 }; last_token_usage = [ordered]@{ input_tokens = $InputTokens; cached_input_tokens = 1000; output_tokens = 50 } } } })
}

function New-CodexRollout {
    param([string]$Path, [long[]]$Inputs, [string]$Cwd = 'C:\fixture', [string]$SessionId = ([guid]::NewGuid().ToString()))
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Add-Line $Path ([ordered]@{ timestamp = [DateTime]::UtcNow.ToString('o'); type = 'session_meta'; payload = [ordered]@{ id = $SessionId; cwd = $Cwd; cli_version = '0.0.0' } })
    foreach ($n in $Inputs) {
        Add-Line $Path ([ordered]@{ type = 'response_item'; payload = [ordered]@{ type = 'message'; content = 'working' } })
        Add-CodexTokens -Path $Path -InputTokens $n
    }
}

function Invoke-Guard {
    param([string]$TranscriptHost, [string]$Path)
    $raw = & pwsh -NoProfile -File $guard -Host $TranscriptHost -TranscriptPath $Path -Json
    if ($LASTEXITCODE -ne 0) { throw "context-guard exited $LASTEXITCODE" }
    return (($raw -join "`n") | ConvertFrom-Json)
}

function Invoke-DtJob {
    param([string[]]$Arguments)
    $raw = & pwsh -NoProfile -File $dtJob @Arguments -Json
    if ($LASTEXITCODE -ne 0) { throw "dt-job $($Arguments -join ' ') exited $LASTEXITCODE : $($raw -join ' ')" }
    return (($raw -join "`n") | ConvertFrom-Json)
}

function Invoke-DtJobRaw {
    param([string[]]$Arguments, [switch]$Text)
    $extra = @(if (-not $Text) { '-Json' })
    $raw = & pwsh -NoProfile -File $dtJob @Arguments @extra 2>&1
    return [pscustomobject]@{ exit = $LASTEXITCODE; text = (($raw | ForEach-Object { [string]$_ }) -join "`n"); lines = @($raw | ForEach-Object { [string]$_ }) }
}

function New-BuildState {
    param([string]$Path)
    $text = (Get-Content -Raw -LiteralPath $templatePath).Replace('__RUN_STATUS__', 'runnable').Replace('__LAST_CONSUMED_EVENT_SEQ__', '0').Replace('__UPDATED_UTC__', '2026-10-10T00:00:00Z')
    Write-Utf8 -Path $Path -Content $text
}

function New-Run {
    param([string]$Name, [string]$PinnedHost = 'claude', [switch]$Managed)
    $rf = Join-Path $tempRoot "runs/$Name"
    New-Item -ItemType Directory -Path $rf -Force | Out-Null
    $bs = Join-Path $tempRoot "planning/$Name/_build-state.md"
    New-BuildState -Path $bs
    $registerArgs = @('register-run', '-RunFolder', $rf, '-BuildStatePath', $bs, '-RunId', $Name, '-PinnedHost', $PinnedHost)
    if ($Managed) { $registerArgs += '-Managed' }
    Invoke-DtJob $registerArgs | Out-Null
    return [pscustomobject]@{ run_id = $Name; folder = $rf; state = $bs }
}

function Write-Lease {
    param([string]$RunFolder, [string]$CoordinatorId, [string]$LeaseHost, [string]$LaunchedBy = 'interactive', $LeasePid = $null, [string]$PidStartUtc = $null, [string]$SessionId = $null)
    $lease = [ordered]@{ coordinator_id = $CoordinatorId; host = $LeaseHost; session_id = $(if ($SessionId) { $SessionId } else { $null }); pid = $LeasePid; pid_start_utc = $(if ($PidStartUtc) { $PidStartUtc } else { $null }); launched_by = $LaunchedBy; ttl_sec = 600; acquired_utc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o'); expires_utc = [DateTime]::UtcNow.AddMinutes(9).ToString('o'); released_utc = $null }
    Write-Utf8 -Path (Join-Path $RunFolder 'coordinator.lease') -Content ($lease | ConvertTo-Json)
}

function Write-Baseline {
    param([string]$RunFolder, [string]$CoordinatorId, [string]$BaselineHost, [string]$TranscriptPath, [long]$Baseline, [string]$SessionId = $null)
    $path = Join-Path $RunFolder 'context-baseline.json'
    $all = if (Test-Path -LiteralPath $path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } else { [pscustomobject]@{ coordinators = [pscustomobject]@{} } }
    $all.coordinators | Add-Member -NotePropertyName $CoordinatorId -NotePropertyValue ([pscustomobject][ordered]@{ coordinator_id = $CoordinatorId; host = $BaselineHost; transcript_path = $TranscriptPath; session_id = $SessionId; baseline_tokens = $Baseline; marked_utc = [DateTime]::UtcNow.ToString('o') }) -Force
    Write-Utf8 -Path $path -Content ($all | ConvertTo-Json -Depth 6)
}

function Start-FakeTree {
    # A pwsh child standing in for the coordinator wrapper, with a ping grandchild standing in for codex.
    param([string]$Name)
    $grandFile = Join-Path $tempRoot "$Name.grand"
    $childScript = "`$g = Start-Process -FilePath 'ping.exe' -ArgumentList '-n','120','127.0.0.1' -WindowStyle Hidden -PassThru; [System.IO.File]::WriteAllText('$grandFile', [string]`$g.Id); Start-Sleep -Seconds 120"
    $child = Start-Process -FilePath 'pwsh' -ArgumentList '-NoProfile', '-Command', $childScript -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $grandFile) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    $grand = [int](Get-Content -Raw -LiteralPath $grandFile)
    $script:spawned += @($child.Id, $grand)
    return [pscustomobject]@{ child = $child.Id; grandchild = $grand; start_utc = (Get-Process -Id $child.Id).StartTime.ToUniversalTime().ToString('o') }
}

function Test-Alive {
    param([int]$ProcessId)
    return ($null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
}

function Invoke-Tick {
    $raw = & pwsh -NoProfile -File $watcher
    $code = $LASTEXITCODE
    $results = @($raw | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    if ($code -ne 0) { throw "watcher exited $code : $($raw -join ' | ')" }
    return $results
}

function Invoke-Hook {
    param([string]$Hook, [hashtable]$HookInput)
    $json = $HookInput | ConvertTo-Json -Depth 6 -Compress
    $raw = $json | & pwsh -NoProfile -File $Hook
    $text = (@($raw) | Where-Object { $_ }) -join "`n"
    if (-not $text) { return $null }
    return ($text | ConvertFrom-Json)
}

function Test-Denied {
    param($Result)
    return ($null -ne $Result -and $Result.hookSpecificOutput.permissionDecision -eq 'deny')
}

$script:spawned = @()
$exitCode = 0
try {
    $fixtures = Join-Path $tempRoot 'fixtures'

    # ---- guard reads the latest value for each host.
    $claudeT = Join-Path $fixtures 'claude-basic.jsonl'
    New-ClaudeTranscript -Path $claudeT -Totals @(50000, 90000, 123456)
    # A trailing synthetic message with zero usage and a user line quoting usage text are both skipped.
    Add-Line $claudeT ([ordered]@{ type = 'assistant'; message = [ordered]@{ id = 'msg-synth'; model = '<synthetic>'; content = @(); usage = [ordered]@{ input_tokens = 0; cache_read_input_tokens = 0; cache_creation_input_tokens = 0; output_tokens = 0 } } })
    Add-Line $claudeT ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = '{"type":"assistant","message":{"usage":{"input_tokens":999999}}}' } })
    $r = Invoke-Guard -TranscriptHost 'claude' -Path $claudeT
    Assert-True ($r.found -and [long]$r.tokens -eq 123456) "claude guard returns the last request's usage sum ($($r.tokens))"
    $codexT = Join-Path $fixtures 'codex-basic.jsonl'
    New-CodexRollout -Path $codexT -Inputs @(24000, 81000, 97531)
    Add-Line $codexT ([ordered]@{ type = 'event_msg'; payload = [ordered]@{ type = 'token_count'; info = $null; rate_limits = [ordered]@{ primary = 10 } } })
    $r = Invoke-Guard -TranscriptHost 'codex' -Path $codexT
    Assert-True ($r.found -and [long]$r.tokens -eq 97531) "codex guard returns the last token_count last_token_usage.input_tokens ($($r.tokens))"
    $emptyT = Join-Path $fixtures 'claude-empty.jsonl'
    New-ClaudeTranscript -Path $emptyT -Totals @()
    $r = Invoke-Guard -TranscriptHost 'claude' -Path $emptyT
    Assert-True (-not $r.found -and $null -eq $r.tokens) 'a transcript with no usage reports found false'
    $missing = & pwsh -NoProfile -File $guard -Host claude -TranscriptPath (Join-Path $fixtures 'nope.jsonl') -Json 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and (($missing | ForEach-Object { [string]$_ }) -join ' ') -match 'CONTEXT_GUARD_NO_TRANSCRIPT') 'a missing transcript fails clearly'

    # ---- a multi-MB transcript is read from the end, quickly, across a huge final line.
    $bigT = Join-Path $fixtures 'claude-big.jsonl'
    New-ClaudeTranscript -Path $bigT -Totals @(60000)
    $pad = 'x' * 20000
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt 300; $i++) { [void]$sb.Append((([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; content = $pad }) } } | ConvertTo-Json -Depth 6 -Compress) + "`n")) }
    [System.IO.File]::AppendAllText($bigT, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    Add-ClaudeUsage -Path $bigT -Total 187654
    # One 2 MB tool result after the last request: the reader must carry it across blocks.
    Add-Line $bigT ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; content = ('y' * 2000000) }) } })
    $bigCodex = Join-Path $fixtures 'codex-big.jsonl'
    New-CodexRollout -Path $bigCodex -Inputs @(30000)
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt 300; $i++) { [void]$sb.Append((([ordered]@{ type = 'response_item'; payload = [ordered]@{ type = 'function_call_output'; output = $pad } } | ConvertTo-Json -Depth 6 -Compress) + "`n")) }
    [System.IO.File]::AppendAllText($bigCodex, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    Add-CodexTokens -Path $bigCodex -InputTokens 145678
    Add-Line $bigCodex ([ordered]@{ type = 'response_item'; payload = [ordered]@{ type = 'function_call_output'; output = ('z' * 2000000) } })
    $sizeMb = [Math]::Round((Get-Item -LiteralPath $bigT).Length / 1MB, 1)
    $timing = & pwsh -NoProfile -Command ". '$guard'; `$sw = [Diagnostics.Stopwatch]::StartNew(); `$c = Get-DtCtxTokens -TranscriptHost claude -TranscriptPath '$bigT'; `$x = Get-DtCtxTokens -TranscriptHost codex -TranscriptPath '$bigCodex'; `$sw.Stop(); '{0} {1} {2}' -f `$c, `$x, `$sw.ElapsedMilliseconds"
    $parts = ([string]@($timing)[-1]).Split(' ')
    Assert-True ($sizeMb -ge 5 -and [long]$parts[0] -eq 187654 -and [long]$parts[1] -eq 145678) "both hosts read the last value from multi-MB fixtures ($sizeMb MB: $($parts[0]), $($parts[1]))"
    Assert-True ([long]$parts[2] -lt 3000) "multi-MB reads finish quickly ($($parts[2]) ms for both)"

    # ---- limits: soft/hard from the baseline, the ceiling before a marker, env overrides.
    $states = & pwsh -NoProfile -Command ". '$guard'; foreach (`$t in 139999, 140000, 169999, 170000) { (Get-DtCtxState -Tokens `$t -Baseline 100000).state }; foreach (`$t in 199999, 200000) { (Get-DtCtxState -Tokens `$t -Baseline `$null).state }; (Get-DtCtxState -Tokens 150000 -Baseline 100000).line; (Get-DtCtxState -Tokens 150000 -Baseline `$null).line"
    Assert-True ((@($states)[0..5] -join ',') -eq 'ok,checkpoint,checkpoint,rotate,ok,rotate') "soft at baseline+40k, hard at baseline+70k, ceiling 200k before a marker ($(@($states)[0..5] -join ','))"
    Assert-True (@($states)[6] -eq 'context: 150000 checkpoint (baseline 100000, soft 140000, hard 170000)') "the context line format ($(@($states)[6]))"
    Assert-True (@($states)[7] -eq 'context: 150000 ok (baseline none, soft none, hard 200000)') "before a marker only the ceiling shows ($(@($states)[7]))"
    $env:DT_BUILD_CTX_SOFT_MARGIN = '10'; $env:DT_BUILD_CTX_HARD_MARGIN = '20'; $env:DT_BUILD_CTX_CEILING = '50'
    try { $overrides = & pwsh -NoProfile -Command ". '$guard'; (Get-DtCtxState -Tokens 115 -Baseline 100).state; (Get-DtCtxState -Tokens 120 -Baseline 100).state; (Get-DtCtxState -Tokens 50 -Baseline `$null).state" }
    finally { Remove-Item Env:DT_BUILD_CTX_SOFT_MARGIN, Env:DT_BUILD_CTX_HARD_MARGIN, Env:DT_BUILD_CTX_CEILING -ErrorAction SilentlyContinue }
    Assert-True ((@($overrides) -join ',') -eq 'checkpoint,rotate,rotate') "env overrides move soft, hard, and ceiling ($(@($overrides) -join ','))"

    # ---- mark-bootstrap: fixed per coordinator and idempotent.
    $run = New-Run -Name 'boot'
    $bootT = Join-Path $fixtures 'claude-boot.jsonl'
    New-ClaudeTranscript -Path $bootT -Totals @(70000, 104000)
    $m1 = Invoke-DtJob @('mark-bootstrap', '-RunFolder', $run.folder, '-CoordinatorId', 'c1', '-Host', 'claude', '-TranscriptPath', $bootT)
    Assert-True ($m1.newly_marked -and [long]$m1.baseline_tokens -eq 104000 -and $m1.host -eq 'claude') "mark-bootstrap records the baseline ($($m1.baseline_tokens))"
    Add-ClaudeUsage -Path $bootT -Total 130000
    $m2 = Invoke-DtJob @('mark-bootstrap', '-RunFolder', $run.folder, '-CoordinatorId', 'c1', '-Host', 'claude', '-TranscriptPath', $bootT)
    Assert-True (-not $m2.newly_marked -and [long]$m2.baseline_tokens -eq 104000 -and $m2.marked_utc -eq $m1.marked_utc) 'a second mark-bootstrap for the same coordinator returns the stored baseline'
    $m3 = Invoke-DtJob @('mark-bootstrap', '-RunFolder', $run.folder, '-CoordinatorId', 'c2', '-Host', 'claude', '-TranscriptPath', $bootT)
    $stored = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'context-baseline.json') | ConvertFrom-Json
    Assert-True ([long]$m3.baseline_tokens -eq 130000 -and [long]$stored.coordinators.c1.baseline_tokens -eq 104000 -and [long]$stored.coordinators.c2.baseline_tokens -eq 130000) 'each coordinator keeps its own baseline, keyed by coordinator_id'
    Assert-True ($stored.coordinators.c1.session_id -eq 'claude-boot' -and $stored.coordinators.c1.transcript_path -eq [System.IO.Path]::GetFullPath($bootT)) 'the baseline records the transcript and its session id'
    $noUsage = Invoke-DtJobRaw @('mark-bootstrap', '-RunFolder', $run.folder, '-CoordinatorId', 'c3', '-Host', 'claude', '-TranscriptPath', $emptyT)
    Assert-True ($noUsage.exit -ne 0 -and $noUsage.text -match 'DT_JOB_CONTEXT_UNREADABLE') "mark-bootstrap refuses a transcript with no usage (exit $($noUsage.exit): $($noUsage.text))"

    # ---- transcript discovery by cwd for both hosts, and a clear failure when nothing matches.
    $work = Join-Path $tempRoot 'work dir'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $slug = $work -replace '[^A-Za-z0-9]', '-'
    $otherClaude = Join-Path $env:CLAUDE_CONFIG_DIR "projects/$slug/other-session.jsonl"
    New-ClaudeTranscript -Path $otherClaude -Totals @(11111) -Cwd 'C:\somewhere-else'
    $mineClaude = Join-Path $env:CLAUDE_CONFIG_DIR "projects/$slug/sess-disc.jsonl"
    New-ClaudeTranscript -Path $mineClaude -Totals @(88000) -Cwd $work
    (Get-Item -LiteralPath $otherClaude).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(1)
    $mineCodex = Join-Path $env:CODEX_HOME 'sessions/2026/10/10/rollout-2026-10-10T01-00-00-mine.jsonl'
    New-CodexRollout -Path $mineCodex -Inputs @(42000) -Cwd $work -SessionId 'codex-sess-1'
    $otherCodex = Join-Path $env:CODEX_HOME 'sessions/2026/10/10/rollout-2026-10-10T02-00-00-other.jsonl'
    New-CodexRollout -Path $otherCodex -Inputs @(1000) -Cwd 'C:\elsewhere'
    Push-Location -LiteralPath $work
    try {
        $dc = Invoke-DtJob @('mark-bootstrap', '-RunFolder', $run.folder, '-CoordinatorId', 'disc-claude', '-Host', 'claude')
        $dx = Invoke-DtJob @('mark-bootstrap', '-RunFolder', $run.folder, '-CoordinatorId', 'disc-codex', '-Host', 'codex')
    }
    finally { Pop-Location }
    $stored = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'context-baseline.json') | ConvertFrom-Json
    Assert-True ($dc.transcript_path -eq $mineClaude -and [long]$dc.baseline_tokens -eq 88000 -and $stored.coordinators.'disc-claude'.session_id -eq 'sess-disc') "claude discovery picks the newest transcript started in this cwd ($($dc.transcript_path))"
    Assert-True ($dx.transcript_path -eq $mineCodex -and [long]$dx.baseline_tokens -eq 42000 -and $stored.coordinators.'disc-codex'.session_id -eq 'codex-sess-1') "codex discovery matches session_meta cwd ($($dx.transcript_path))"
    $lost = Join-Path $tempRoot 'lost'
    New-Item -ItemType Directory -Path $lost -Force | Out-Null
    Push-Location -LiteralPath $lost
    try { $none = Invoke-DtJobRaw @('mark-bootstrap', '-RunFolder', $run.folder, '-CoordinatorId', 'disc-none', '-Host', 'codex') }
    finally { Pop-Location }
    Assert-True ($none.exit -ne 0 -and $none.text -match 'CONTEXT_GUARD_NO_TRANSCRIPT') 'discovery fails clearly when no transcript matches'

    # ---- every verb reports the context line for a coordinator; start is refused past hard; state verbs are not.
    $run = New-Run -Name 'verbs'
    $vT = Join-Path $fixtures 'claude-verbs.jsonl'
    New-ClaudeTranscript -Path $vT -Totals @(100000)
    Invoke-DtJob @('mark-bootstrap', '-RunFolder', $run.folder, '-CoordinatorId', 'cv', '-Host', 'claude', '-TranscriptPath', $vT) | Out-Null
    Add-ClaudeUsage -Path $vT -Total 120000
    $plain = Invoke-DtJob @('status', '-RunFolder', $run.folder)
    Assert-True (-not $plain.PSObject.Properties['context']) 'no context line without DT_BUILD_COORDINATOR_ID'
    $env:DT_BUILD_COORDINATOR_ID = 'cv'
    try {
        $s = Invoke-DtJob @('status', '-RunFolder', $run.folder)
        Assert-True ($s.context -eq 'context: 120000 ok (baseline 100000, soft 140000, hard 170000)') "JSON output carries the context field ($($s.context))"
        $t = Invoke-DtJobRaw @('status', '-RunFolder', $run.folder) -Text
        Assert-True ($t.exit -eq 0 -and $t.lines[-1] -eq 'context: 120000 ok (baseline 100000, soft 140000, hard 170000)') "text output ends with the context line ($($t.lines[-1]))"
        Add-ClaudeUsage -Path $vT -Total 150000
        $s = Invoke-DtJob @('status', '-RunFolder', $run.folder)
        Assert-True ($s.context -like 'context: 150000 checkpoint *') "checkpoint at the soft limit ($($s.context))"
        $ok = Invoke-DtJob @('start', '-RunFolder', $run.folder, '-Command', 'Write-Output fine')
        Assert-True ($ok.job_id -eq 'j-0001' -and $ok.context -like '*checkpoint*') 'start is allowed at checkpoint'
        Invoke-DtJob @('wait', '-RunFolder', $run.folder, '-JobId', 'j-0001', '-All', '-TimeoutSec', '60') | Out-Null
        Add-ClaudeUsage -Path $vT -Total 170000
        $refused = Invoke-DtJobRaw @('start', '-RunFolder', $run.folder, '-Command', 'Write-Output nope')
        Assert-True ($refused.exit -ne 0 -and $refused.text -match 'ROTATE_REQUIRED' -and $refused.text -match 'request-continuation' -and -not (Test-Path -LiteralPath (Join-Path $run.folder 'jobs/j-0002.json'))) 'start is refused with ROTATE_REQUIRED at the hard limit and records nothing'
        $allowed = [System.Collections.Generic.List[string]]::new()
        $checks = @(
            @('status', '-RunFolder', $run.folder),
            @('wait', '-RunFolder', $run.folder, '-JobId', 'j-0001', '-All', '-TimeoutSec', '5'),
            @('consume', '-RunFolder', $run.folder, '-Seq', '1'),
            @('request-continuation', '-RunFolder', $run.folder, '-Reason', 'context_rotation'),
            @('mark-bootstrap', '-RunFolder', $run.folder, '-CoordinatorId', 'cv', '-Host', 'claude', '-TranscriptPath', $vT),
            @('irreversible', '-RunFolder', $run.folder, '-Action', 'begin', '-Operation', 'probe'),
            @('irreversible', '-RunFolder', $run.folder, '-Action', 'end', '-Operation', 'probe'),
            @('lease', '-RunFolder', $run.folder, '-Action', 'acquire', '-CoordinatorId', 'cv', '-Host', 'claude'),
            @('lease', '-RunFolder', $run.folder, '-Action', 'renew', '-CoordinatorId', 'cv'),
            @('await-danny', '-RunFolder', $run.folder, '-Operation', 'merge', '-Message', 'test boundary.'),
            @('lease', '-RunFolder', $run.folder, '-Action', 'release', '-CoordinatorId', 'cv')
        )
        foreach ($c in $checks) {
            $res = Invoke-DtJobRaw $c
            if ($res.exit -eq 0 -and $res.text -match 'context: 170000 rotate') { $allowed.Add($c[0]) }
            else { throw "ASSERT_FAIL: state verb $($c -join ' ') was refused or lost its context line: $($res.text)" }
        }
        $script:passed++
        Assert-True ($allowed.Count -eq $checks.Count) "state and hand-off verbs still run past the hard limit ($($allowed -join ', '))"
        $fin = Invoke-DtJobRaw @('finish', '-RunFolder', $run.folder)
        Assert-True ($fin.exit -eq 0 -and $fin.text -match 'context: 170000 rotate') 'finish still runs past the hard limit'

        # An open irreversible step defers the refusal; ending it restores it.
        Invoke-DtJob @('irreversible', '-RunFolder', $run.folder, '-Action', 'begin', '-Operation', 'merge') | Out-Null
        $deferred = Invoke-DtJob @('start', '-RunFolder', $run.folder, '-Command', 'Write-Output during-merge')
        Assert-True ($deferred.job_id -eq 'j-0002' -and $deferred.context -match 'rotation deferred: irreversible merge open') "an open irreversible step defers ROTATE_REQUIRED ($($deferred.context))"
        $ir = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'irreversible.json') | ConvertFrom-Json
        Assert-True (@($ir.open).Count -eq 1 -and $ir.open[0].operation -eq 'merge' -and $ir.open[0].coordinator_id -eq 'cv') 'irreversible.json records the open step'
        Invoke-DtJob @('irreversible', '-RunFolder', $run.folder, '-Action', 'end', '-Operation', 'merge') | Out-Null
        $again = Invoke-DtJobRaw @('start', '-RunFolder', $run.folder, '-Command', 'Write-Output after-merge')
        Assert-True ($again.exit -ne 0 -and $again.text -match 'ROTATE_REQUIRED') 'ending the step restores the refusal'
        Invoke-DtJob @('wait', '-RunFolder', $run.folder, '-JobId', 'j-0002', '-All', '-TimeoutSec', '60') | Out-Null
    }
    finally { Remove-Item Env:DT_BUILD_COORDINATOR_ID -ErrorAction SilentlyContinue }

    # ---- before a marker, only the 200k ceiling applies (transcript discovered by cwd, host from the lease).
    $run = New-Run -Name 'ceiling'
    $ceilWork = Join-Path $tempRoot 'ceiling-work'
    New-Item -ItemType Directory -Path $ceilWork -Force | Out-Null
    $ceilT = Join-Path $env:CLAUDE_CONFIG_DIR "projects/$($ceilWork -replace '[^A-Za-z0-9]', '-')/sess-ceil.jsonl"
    New-ClaudeTranscript -Path $ceilT -Totals @(180000) -Cwd $ceilWork
    Write-Lease -RunFolder $run.folder -CoordinatorId 'cpre' -LeaseHost 'claude'
    $env:DT_BUILD_COORDINATOR_ID = 'cpre'
    Push-Location -LiteralPath $ceilWork
    try {
        $pre = Invoke-DtJob @('start', '-RunFolder', $run.folder, '-Command', 'Write-Output pre')
        Assert-True ($pre.job_id -eq 'j-0001' -and $pre.context -eq 'context: 180000 ok (baseline none, soft none, hard 200000)') "below the ceiling a pre-marker start runs ($($pre.context))"
        Add-ClaudeUsage -Path $ceilT -Total 200000 -Cwd $ceilWork
        $preRefused = Invoke-DtJobRaw @('start', '-RunFolder', $run.folder, '-Command', 'Write-Output pre2')
        Assert-True ($preRefused.exit -ne 0 -and $preRefused.text -match 'ROTATE_REQUIRED' -and $preRefused.text -match 'hard 200000') 'at the ceiling a pre-marker start is refused'
        $preStatus = Invoke-DtJobRaw @('status', '-RunFolder', $run.folder)
        Assert-True ($preStatus.exit -eq 0 -and $preStatus.text -match 'context: 200000 rotate') 'status still runs at the ceiling'
        Invoke-DtJob @('wait', '-RunFolder', $run.folder, '-JobId', 'j-0001', '-All', '-TimeoutSec', '60') | Out-Null
    }
    finally { Pop-Location; Remove-Item Env:DT_BUILD_COORDINATOR_ID -ErrorAction SilentlyContinue }

    # ---- watcher: a managed Codex coordinator past hard is killed (tree), its lease released, a continuation requested.
    $run = New-Run -Name 'codex-rot' -PinnedHost 'codex' -Managed
    $rotT = Join-Path $fixtures 'codex-rot.jsonl'
    New-CodexRollout -Path $rotT -Inputs @(50000, 100000)
    $tree = Start-FakeTree -Name 'codex-rot'
    Write-Lease -RunFolder $run.folder -CoordinatorId 'mc-codex' -LeaseHost 'codex' -LaunchedBy 'watcher' -LeasePid $tree.child -PidStartUtc $tree.start_utc
    Write-Baseline -RunFolder $run.folder -CoordinatorId 'mc-codex' -BaselineHost 'codex' -TranscriptPath $rotT -Baseline 50000
    $tick = @(Invoke-Tick | Where-Object { $_.run_id -eq 'codex-rot' })[0]
    Assert-True ((Test-Alive $tree.child) -and -not $tick.PSObject.Properties['rotation'] -and -not (Test-Path -LiteralPath (Join-Path $run.folder 'rotations.jsonl'))) 'below the hard limit the Codex coordinator is left alone'
    Add-CodexTokens -Path $rotT -InputTokens 130000
    Invoke-DtJob @('irreversible', '-RunFolder', $run.folder, '-Action', 'begin', '-Operation', 'push') | Out-Null
    $tick = @(Invoke-Tick | Where-Object { $_.run_id -eq 'codex-rot' })[0]
    Assert-True ((Test-Alive $tree.child) -and (Test-Alive $tree.grandchild) -and [string]$tick.rotation -match 'rotation deferred' -and -not (Test-Path -LiteralPath (Join-Path $run.folder 'rotations.jsonl'))) "an open irreversible step defers the watcher kill ($($tick.rotation))"
    Invoke-DtJob @('irreversible', '-RunFolder', $run.folder, '-Action', 'end', '-Operation', 'push') | Out-Null
    $tick = @(Invoke-Tick | Where-Object { $_.run_id -eq 'codex-rot' })[0]
    Start-Sleep -Milliseconds 500
    Assert-True (-not (Test-Alive $tree.child) -and -not (Test-Alive $tree.grandchild)) 'past the hard limit the watcher kills the coordinator and its child process'
    $rot = @(Get-Content -LiteralPath (Join-Path $run.folder 'rotations.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($rot.Count -eq 1 -and $rot[0].coordinator_id -eq 'mc-codex' -and [long]$rot[0].tokens_at_kill -eq 130000 -and [long]$rot[0].hard_limit -eq 120000 -and [long]$rot[0].overshoot -eq 10000) "rotations.jsonl records tokens, hard limit, and overshoot ($($rot | ConvertTo-Json -Compress))"
    $events = @(Get-Content -LiteralPath (Join-Path $run.folder 'jobs/events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($events | Where-Object { $_.type -eq 'continuation_requested' -and $_.reason -eq 'context_rotation' }).Count -eq 1) 'the rotation appends one continuation_requested (context_rotation)'
    $lease = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'coordinator.lease') | ConvertFrom-Json
    $launched = @(if (Test-Path -LiteralPath $env:DT_TEST_LAUNCH_LOG) { Get-Content -LiteralPath $env:DT_TEST_LAUNCH_LOG | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.run_id -eq 'codex-rot' } })
    Assert-True ($lease.coordinator_id -eq 'mc-codex' -and $lease.released_utc -and $tick.action -eq 'launch' -and $launched.Count -eq 1 -and $launched[0].host -eq 'codex') "the lease is released and the relaunch rules start a fresh coordinator ($($tick.action))"
    $tick = @(Invoke-Tick | Where-Object { $_.run_id -eq 'codex-rot' })[0]
    Assert-True (@(Get-Content -LiteralPath (Join-Path $run.folder 'rotations.jsonl')).Count -eq 1 -and -not $tick.PSObject.Properties['rotation']) 'a released lease is not rotated again'

    # ---- watcher: a Claude coordinator past hard is never killed by the watcher.
    $run = New-Run -Name 'claude-rot' -PinnedHost 'claude' -Managed
    $cRotT = Join-Path $fixtures 'claude-rot.jsonl'
    New-ClaudeTranscript -Path $cRotT -Totals @(100000, 190000)
    $cTree = Start-FakeTree -Name 'claude-rot'
    Write-Lease -RunFolder $run.folder -CoordinatorId 'mc-claude' -LeaseHost 'claude' -LaunchedBy 'watcher' -LeasePid $cTree.child -PidStartUtc $cTree.start_utc
    Write-Baseline -RunFolder $run.folder -CoordinatorId 'mc-claude' -BaselineHost 'claude' -TranscriptPath $cRotT -Baseline 100000
    Invoke-DtJob @('request-continuation', '-RunFolder', $run.folder) | Out-Null
    $tick = @(Invoke-Tick | Where-Object { $_.run_id -eq 'claude-rot' })[0]
    Assert-True ((Test-Alive $cTree.child) -and (Test-Alive $cTree.grandchild) -and -not (Test-Path -LiteralPath (Join-Path $run.folder 'rotations.jsonl')) -and $tick.action -eq 'none') 'a Claude coordinator past hard is not killed by the watcher'

    # ---- PreToolUse / PostToolUse hooks.
    $run = New-Run -Name 'hooks'
    $hookOk = Join-Path $fixtures 'hook-ok.jsonl'
    New-ClaudeTranscript -Path $hookOk -Totals @(100000, 110000)
    $hookCheck = Join-Path $fixtures 'hook-check.jsonl'
    New-ClaudeTranscript -Path $hookCheck -Totals @(100000, 145000)
    $hookHard = Join-Path $fixtures 'hook-hard.jsonl'
    New-ClaudeTranscript -Path $hookHard -Totals @(100000, 175000)
    Write-Baseline -RunFolder $run.folder -CoordinatorId 'hc1' -BaselineHost 'claude' -TranscriptPath $hookOk -Baseline 100000 -SessionId 'sess-hook'
    $bigFile = Join-Path $fixtures 'big.log'
    Write-Utf8 -Path $bigFile -Content ((1..500 | ForEach-Object { "line $_" }) -join "`n")
    $smallFile = Join-Path $fixtures 'small.txt'
    Write-Utf8 -Path $smallFile -Content ((1..10 | ForEach-Object { "line $_" }) -join "`n")
    $exactFile = Join-Path $fixtures 'exact.txt'
    Write-Utf8 -Path $exactFile -Content (((1..400 | ForEach-Object { "line $_" }) -join "`n") + "`n")
    $mk = {
        param([string]$Session, [string]$Transcript, [string]$Tool, [hashtable]$ToolInput, [string]$EventName = 'PreToolUse')
        @{ session_id = $Session; transcript_path = $Transcript; cwd = $tempRoot; hook_event_name = $EventName; tool_name = $Tool; tool_input = $ToolInput }
    }
    # Not a coordinator: nothing is denied.
    Assert-True ($null -eq (Invoke-Hook $preHook (& $mk 'other-session' $hookHard 'CronCreate' @{ cron = '* * * * *'; prompt = 'x' }))) 'a non-coordinator session may use CronCreate'
    Assert-True ($null -eq (Invoke-Hook $preHook (& $mk 'other-session' $hookHard 'Read' @{ file_path = $bigFile }))) 'a non-coordinator session may Read a long file whole'
    Assert-True ($null -eq (Invoke-Hook $preHook (& $mk 'other-session' $hookHard 'Grep' @{ pattern = 'x' }))) 'a non-coordinator session is unaffected by the hard limit'
    # Coordinator by session id, context ok.
    $r = Invoke-Hook $preHook (& $mk 'sess-hook' $hookOk 'CronCreate' @{ cron = '* * * * *'; prompt = 'x' })
    Assert-True ((Test-Denied $r) -and $r.hookSpecificOutput.hookEventName -eq 'PreToolUse' -and $r.hookSpecificOutput.permissionDecisionReason -match 'CronCreate') 'a coordinator is denied CronCreate'
    $r = Invoke-Hook $preHook (& $mk 'sess-hook' $hookOk 'Read' @{ file_path = $bigFile })
    Assert-True ((Test-Denied $r) -and $r.hookSpecificOutput.permissionDecisionReason -match 'offset and limit') 'a coordinator Read of a 500-line file without a range is denied'
    Assert-True ($null -eq (Invoke-Hook $preHook (& $mk 'sess-hook' $hookOk 'Read' @{ file_path = $bigFile; offset = 1; limit = 100 }))) 'a ranged Read of the same file is allowed'
    Assert-True ($null -eq (Invoke-Hook $preHook (& $mk 'sess-hook' $hookOk 'Read' @{ file_path = $smallFile }))) 'a short file may be Read whole'
    Assert-True ($null -eq (Invoke-Hook $preHook (& $mk 'sess-hook' $hookOk 'Read' @{ file_path = $exactFile }))) 'a file of exactly 400 lines may be Read whole'
    foreach ($ext in @('png', 'JPG', 'jpeg', 'gif', 'bmp', 'webp')) {
        $r = Invoke-Hook $preHook (& $mk 'sess-hook' $hookOk 'Read' @{ file_path = (Join-Path $fixtures "shot.$ext") })
        if (-not (Test-Denied $r)) { throw "ASSERT_FAIL: image read .$ext was not denied" }
    }
    $script:passed++
    Assert-True ($null -eq (Invoke-Hook $preHook (& $mk 'sess-hook' $hookOk 'Grep' @{ pattern = 'x' }))) 'below the hard limit discretionary tools are allowed'
    # Coordinator past the hard limit.
    $r = Invoke-Hook $preHook (& $mk 'sess-hook' $hookHard 'Grep' @{ pattern = 'x' })
    Assert-True ((Test-Denied $r) -and $r.hookSpecificOutput.permissionDecisionReason -match 'request-continuation' -and $r.hookSpecificOutput.permissionDecisionReason -match 'end the turn' -and $r.hookSpecificOutput.permissionDecisionReason -match 'context: 175000 rotate') "past hard, Grep is denied with the exact next step ($($r | ConvertTo-Json -Compress -Depth 4))"
    foreach ($tool in @('Read', 'Glob', 'WebFetch', 'WebSearch', 'Agent', 'Task', 'NotebookEdit')) {
        $toolInput = if ($tool -eq 'Read') { @{ file_path = $smallFile } } else { @{ x = 'y' } }
        if (-not (Test-Denied (Invoke-Hook $preHook (& $mk 'sess-hook' $hookHard $tool $toolInput)))) { throw "ASSERT_FAIL: $tool past hard was not denied" }
    }
    $script:passed++
    $r = Invoke-Hook $preHook (& $mk 'sess-hook' $hookHard 'Bash' @{ command = "Get-Content '$bigFile'" })
    Assert-True ((Test-Denied $r) -and $r.hookSpecificOutput.permissionDecisionReason -match 'request-continuation') 'past hard, a shell read of a large log is denied'
    Assert-True (Test-Denied (Invoke-Hook $preHook (& $mk 'sess-hook' $hookHard 'PowerShell' @{ command = "cat '$bigFile'; pwsh -File dt-job.ps1 status -RunFolder x" }))) 'past hard, a shell read chained before a dt-job call is denied'
    $allowedCommands = @(
        "pwsh -NoProfile -File `"$dtJob`" request-continuation -RunFolder `"$($run.folder)`" -Reason context_rotation",
        "cd `"$tempRoot`"; pwsh -NoProfile -File `"$dtJob`" lease -RunFolder x -Action release -CoordinatorId hc1",
        'pwsh -NoProfile -File scripts/write-build-state.ps1 -Path x',
        'pwsh -NoProfile -File scripts/read-evidence.ps1 -Path x -Lines 20',
        'git status --short',
        'git -C "D:/repo" log --oneline -3',
        'git rev-parse HEAD'
    )
    foreach ($cmd in $allowedCommands) {
        if ($null -ne (Invoke-Hook $preHook (& $mk 'sess-hook' $hookHard 'Bash' @{ command = $cmd }))) { throw "ASSERT_FAIL: allowed command was denied past hard: $cmd" }
    }
    $script:passed++
    Assert-True ($null -eq (Invoke-Hook $preHook (& $mk 'sess-hook' $hookHard 'Write' @{ file_path = 'x'; content = 'state' }))) 'past hard, writing state is still allowed'
    Invoke-DtJob @('irreversible', '-RunFolder', $run.folder, '-Action', 'begin', '-Operation', 'merge') | Out-Null
    Assert-True ($null -eq (Invoke-Hook $preHook (& $mk 'sess-hook' $hookHard 'Grep' @{ pattern = 'x' }))) 'an open irreversible step defers the hard-limit denials'
    Invoke-DtJob @('irreversible', '-RunFolder', $run.folder, '-Action', 'end', '-Operation', 'merge') | Out-Null
    # Coordinator by env var only, no registered run: the ceiling applies and the fixed denials hold.
    $env:DT_BUILD_COORDINATOR_ID = 'hc-env'
    try {
        Assert-True (Test-Denied (Invoke-Hook $preHook (& $mk 'unrelated' $hookOk 'CronCreate' @{ cron = '*' }))) 'DT_BUILD_COORDINATOR_ID alone marks a coordinator session'
        Assert-True ($null -eq (Invoke-Hook $preHook (& $mk 'unrelated' $hookHard 'Grep' @{ pattern = 'x' }))) 'without a baseline, 175k is under the 200k ceiling'
    }
    finally { Remove-Item Env:DT_BUILD_COORDINATOR_ID -ErrorAction SilentlyContinue }
    # Coordinator by lease session id.
    Write-Lease -RunFolder $run.folder -CoordinatorId 'hc-lease' -LeaseHost 'claude' -SessionId 'sess-lease'
    Assert-True (Test-Denied (Invoke-Hook $preHook (& $mk 'sess-lease' $hookOk 'CronCreate' @{ cron = '*' }))) 'a session recorded in the lease is a coordinator session'
    # PostToolUse.
    Assert-True ($null -eq (Invoke-Hook $postHook (& $mk 'sess-hook' $hookOk 'Bash' @{ command = 'git status' } 'PostToolUse'))) 'PostToolUse is silent when ok'
    $r = Invoke-Hook $postHook (& $mk 'sess-hook' $hookCheck 'Bash' @{ command = 'git status' } 'PostToolUse')
    Assert-True ($null -ne $r -and $r.hookSpecificOutput.hookEventName -eq 'PostToolUse' -and $r.hookSpecificOutput.additionalContext -like 'context: 145000 checkpoint (baseline 100000, soft 140000, hard 170000)*') 'PostToolUse surfaces the line at checkpoint'
    $r = Invoke-Hook $postHook (& $mk 'sess-hook' $hookHard 'Bash' @{ command = 'git status' } 'PostToolUse')
    Assert-True ($null -ne $r -and $r.hookSpecificOutput.additionalContext -like 'context: 175000 rotate*' -and $r.hookSpecificOutput.additionalContext -match 'request-continuation') 'PostToolUse surfaces the line and next step at rotate'
    Assert-True ($null -eq (Invoke-Hook $postHook (& $mk 'other-session' $hookHard 'Bash' @{ command = 'git status' } 'PostToolUse'))) 'PostToolUse is silent for a non-coordinator session'

    # ---- static: hook files and launcher flags.
    foreach ($file in @($preHook, $postHook, $guard, (Join-Path $scriptDir 'launch-managed-coordinator.ps1'))) {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
        Assert-True (@($errors).Count -eq 0) "$(Split-Path -Leaf $file) parses"
    }
    $snippetText = Get-Content -Raw -LiteralPath (Join-Path $skillDir 'hooks\settings-snippet.json')
    $snippet = $snippetText | ConvertFrom-Json
    Assert-True ($snippet.hooks.PreToolUse[0].hooks[0].command -match '__DT_BUILD_HOOKS_DIR__/coordinator-pretooluse\.ps1' -and $snippet.hooks.PostToolUse[0].hooks[0].command -match '__DT_BUILD_HOOKS_DIR__/coordinator-posttooluse\.ps1' -and -not $snippetText.Contains('CLAUDE_PLUGIN_ROOT')) 'the settings snippet names both hooks through the absolute-path placeholder'
    $launcherText = Get-Content -Raw -LiteralPath (Join-Path $scriptDir 'launch-managed-coordinator.ps1')
    Assert-True ($launcherText.Contains('claude -p --strict-mcp-config --mcp-config') -and $launcherText.Contains('--settings') -and $launcherText.Contains('--permission-mode bypassPermissions') -and $launcherText.Contains('__DT_BUILD_HOOKS_DIR__')) 'managed Claude coordinators launch with no MCP servers, the hooks settings copy, and bypass'
    $codexChunk = Get-Content -Raw -LiteralPath (Join-Path $scriptDir 'invoke-codex-chunk.ps1')
    Assert-True ($launcherText.Contains('codex --ask-for-approval never exec') -and $launcherText.Contains('default_permissions=":danger-full-access"') -and $codexChunk.Contains("'--ask-for-approval', 'never'") -and $codexChunk.Contains('default_permissions=":danger-full-access"')) 'managed Codex coordinators use the permission flags of invoke-codex-chunk.ps1'
}
catch {
    Write-Output "FAIL: $($_.Exception.Message)"
    Write-Output $_.ScriptStackTrace
    $exitCode = 1
}
finally {
    foreach ($p in $script:spawned) { Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue | Where-Object { @("ping", "pwsh") -contains $_.ProcessName } | Stop-Process -Force -ErrorAction SilentlyContinue }
    foreach ($name in $savedEnv.Keys) { [System.Environment]::SetEnvironmentVariable($name, $savedEnv[$name]) }
    Write-Output "SUMMARY: $script:passed passed"
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
exit $exitCode
