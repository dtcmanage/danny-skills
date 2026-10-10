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
    param([string]$RunFolder, [string]$CoordinatorId, [string]$BaselineHost, [string]$TranscriptPath, [long]$Baseline, [string]$SessionId = $null, [string]$Source = 'explicit')
    $path = Join-Path $RunFolder 'context-baseline.json'
    $all = if (Test-Path -LiteralPath $path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } else { [pscustomobject]@{ coordinators = [pscustomobject]@{} } }
    $all.coordinators | Add-Member -NotePropertyName $CoordinatorId -NotePropertyValue ([pscustomobject][ordered]@{ coordinator_id = $CoordinatorId; host = $BaselineHost; transcript_path = $TranscriptPath; session_id = $(if ($SessionId) { $SessionId } else { $null }); transcript_source = $Source; baseline_tokens = $Baseline; marked_utc = [DateTime]::UtcNow.ToString('o') }) -Force
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
    # The caller's session has its mark-bootstrap call among its newest lines.
    Add-Line $mineClaude ([ordered]@{ type = 'assistant'; cwd = $work; isSidechain = $false; message = [ordered]@{ role = 'assistant'; content = @([ordered]@{ type = 'tool_use'; name = 'Bash'; input = [ordered]@{ command = "pwsh -NoProfile -File dt-job.ps1 mark-bootstrap -RunFolder x -CoordinatorId disc-claude -Host claude" } }) } })
    # Newer than it, all in the same cwd: a second interactive session, a subagent transcript, and a
    # sidechain-only file outside a subagents folder.
    $secondClaude = Join-Path $env:CLAUDE_CONFIG_DIR "projects/$slug/second-session.jsonl"
    New-ClaudeTranscript -Path $secondClaude -Totals @(22222) -Cwd $work
    $subagentClaude = Join-Path $env:CLAUDE_CONFIG_DIR "projects/$slug/sess-disc/subagents/agent-1.jsonl"
    # The subagent file carries no isSidechain flag here, so only its folder rules it out.
    Add-Line $subagentClaude ([ordered]@{ type = 'user'; cwd = $work; message = [ordered]@{ role = 'user'; content = 'mark-bootstrap the run' } })
    Add-ClaudeUsage -Path $subagentClaude -Total 33333 -Cwd $work
    $sidechainClaude = Join-Path $env:CLAUDE_CONFIG_DIR "projects/$slug/sidechain-only.jsonl"
    Add-Line $sidechainClaude ([ordered]@{ type = 'user'; cwd = $work; isSidechain = $true; message = [ordered]@{ role = 'user'; content = 'mark-bootstrap the run' } })
    Add-ClaudeUsage -Path $sidechainClaude -Total 44444 -Cwd $work
    $stamp = [DateTime]::UtcNow
    (Get-Item -LiteralPath $mineClaude).LastWriteTimeUtc = $stamp.AddSeconds(10)
    (Get-Item -LiteralPath $secondClaude).LastWriteTimeUtc = $stamp.AddSeconds(20)
    (Get-Item -LiteralPath $subagentClaude).LastWriteTimeUtc = $stamp.AddSeconds(30)
    (Get-Item -LiteralPath $sidechainClaude).LastWriteTimeUtc = $stamp.AddSeconds(40)
    (Get-Item -LiteralPath $otherClaude).LastWriteTimeUtc = $stamp.AddSeconds(50)
    $mineCodex = Join-Path $env:CODEX_HOME 'sessions/2026/10/10/rollout-2026-10-10T01-00-00-mine.jsonl'
    New-CodexRollout -Path $mineCodex -Inputs @(42000) -Cwd $work -SessionId 'codex-sess-1'
    $otherCodex = Join-Path $env:CODEX_HOME 'sessions/2026/10/10/rollout-2026-10-10T02-00-00-other.jsonl'
    New-CodexRollout -Path $otherCodex -Inputs @(1000) -Cwd 'C:\elsewhere'
    # Newer, same cwd: a rollout a dt-build chunk wrapper started (its prompt opens with RUN_ID and
    # chunk_id headers, as in a real rollout), and a Codex subagent thread.
    $chunkCodex = Join-Path $env:CODEX_HOME 'sessions/2026/10/10/rollout-2026-10-10T03-00-00-chunk.jsonl'
    Add-Line $chunkCodex ([ordered]@{ timestamp = [DateTime]::UtcNow.ToString('o'); type = 'session_meta'; payload = [ordered]@{ id = 'codex-chunk'; cwd = $work; originator = 'codex_exec'; source = 'exec'; thread_source = 'user'; cli_version = '0.0.0' } })
    Add-Line $chunkCodex ([ordered]@{ type = 'event_msg'; payload = [ordered]@{ type = 'task_started' } })
    Add-Line $chunkCodex ([ordered]@{ type = 'response_item'; payload = [ordered]@{ type = 'message'; role = 'developer'; content = @([ordered]@{ type = 'input_text'; text = 'instructions' }) } })
    Add-Line $chunkCodex ([ordered]@{ type = 'response_item'; payload = [ordered]@{ type = 'message'; role = 'user'; content = @([ordered]@{ type = 'input_text'; text = "<environment_context>cwd</environment_context>" }) } })
    Add-Line $chunkCodex ([ordered]@{ type = 'turn_context'; payload = [ordered]@{ cwd = $work } })
    Add-Line $chunkCodex ([ordered]@{ type = 'response_item'; payload = [ordered]@{ type = 'message'; role = 'user'; content = @([ordered]@{ type = 'input_text'; text = "RUN_ID: run-x`r`nchunk_id: M01-chunk-a`r`nattempt: 1`r`n`r`nRun dt-job.ps1 mark-bootstrap when told." }) } })
    Add-CodexTokens -Path $chunkCodex -InputTokens 55555
    $subCodex = Join-Path $env:CODEX_HOME 'sessions/2026/10/10/rollout-2026-10-10T04-00-00-sub.jsonl'
    Add-Line $subCodex ([ordered]@{ timestamp = [DateTime]::UtcNow.ToString('o'); type = 'session_meta'; payload = [ordered]@{ id = 'codex-sub'; cwd = $work; originator = 'codex_exec'; source = [ordered]@{ subagent = [ordered]@{ thread_spawn = [ordered]@{ parent_thread_id = 'codex-sess-1' } } }; thread_source = 'subagent' } })
    Add-CodexTokens -Path $subCodex -InputTokens 66666
    (Get-Item -LiteralPath $mineCodex).LastWriteTimeUtc = $stamp.AddSeconds(10)
    (Get-Item -LiteralPath $chunkCodex).LastWriteTimeUtc = $stamp.AddSeconds(20)
    (Get-Item -LiteralPath $subCodex).LastWriteTimeUtc = $stamp.AddSeconds(30)
    (Get-Item -LiteralPath $otherCodex).LastWriteTimeUtc = $stamp.AddSeconds(40)
    Push-Location -LiteralPath $work
    try {
        $dc = Invoke-DtJob @('mark-bootstrap', '-RunFolder', $run.folder, '-CoordinatorId', 'disc-claude', '-Host', 'claude')
        $dx = Invoke-DtJob @('mark-bootstrap', '-RunFolder', $run.folder, '-CoordinatorId', 'disc-codex', '-Host', 'codex')
    }
    finally { Pop-Location }
    $stored = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'context-baseline.json') | ConvertFrom-Json
    Assert-True ($dc.transcript_path -eq $mineClaude -and [long]$dc.baseline_tokens -eq 88000) "claude discovery picks the caller's session over a newer same-cwd session, a subagent transcript, and a sidechain file ($($dc.transcript_path))"
    Assert-True ($null -eq $stored.coordinators.'disc-claude'.session_id -and $stored.coordinators.'disc-claude'.transcript_source -eq 'discovered') 'a discovered transcript records no session id and is marked discovered'
    Assert-True ($dx.transcript_path -eq $mineCodex -and [long]$dx.baseline_tokens -eq 42000 -and $null -eq $stored.coordinators.'disc-codex'.session_id -and $stored.coordinators.'disc-codex'.transcript_source -eq 'discovered') "codex discovery matches session_meta cwd and skips chunk-wrapper and subagent rollouts ($($dx.transcript_path))"
    Assert-True ($stored.coordinators.c1.transcript_source -eq 'explicit') 'a named transcript is marked explicit'
    # With no session carrying the call, the newest qualifying one is used; subagent and sidechain files never are.
    $guessed = & pwsh -NoProfile -Command ". '$guard'; Find-DtCtxTranscript -TranscriptHost claude -Cwd '$work'; Remove-Item -LiteralPath '$mineClaude'; Find-DtCtxTranscript -TranscriptHost claude -Cwd '$work'"
    Assert-True (@($guessed)[0] -eq $mineClaude -and @($guessed)[1] -eq $secondClaude) "without the call in any tail, the newest non-subagent same-cwd session is the guess ($(@($guessed) -join ', '))"
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

        # An irreversible step the lease holder opened defers the refusal; ending it restores it.
        Invoke-DtJob @('lease', '-RunFolder', $run.folder, '-Action', 'acquire', '-CoordinatorId', 'cv', '-Host', 'claude') | Out-Null
        Invoke-DtJob @('irreversible', '-RunFolder', $run.folder, '-Action', 'begin', '-Operation', 'merge') | Out-Null
        $deferred = Invoke-DtJob @('start', '-RunFolder', $run.folder, '-Command', 'Write-Output during-merge')
        Assert-True ($deferred.job_id -eq 'j-0002' -and $deferred.context -match 'rotation deferred: irreversible merge open') "an open irreversible step defers ROTATE_REQUIRED ($($deferred.context))"
        $ir = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'irreversible.json') | ConvertFrom-Json
        Assert-True (@($ir.open).Count -eq 1 -and $ir.open[0].operation -eq 'merge' -and $ir.open[0].coordinator_id -eq 'cv') 'irreversible.json records the open step'
        # Once cv no longer holds the lease its step is stale and defers nothing.
        Write-Lease -RunFolder $run.folder -CoordinatorId 'cv-next' -LeaseHost 'claude'
        $staleStart = Invoke-DtJobRaw @('start', '-RunFolder', $run.folder, '-Command', 'Write-Output stale')
        Assert-True ($staleStart.exit -ne 0 -and $staleStart.text -match 'ROTATE_REQUIRED' -and $staleStart.text -notmatch 'rotation deferred') "a step whose coordinator no longer holds the lease does not defer ROTATE_REQUIRED ($($staleStart.text))"
        Write-Lease -RunFolder $run.folder -CoordinatorId 'cv' -LeaseHost 'claude'
        Invoke-DtJob @('lease', '-RunFolder', $run.folder, '-Action', 'release', '-CoordinatorId', 'cv') | Out-Null
        $releasedStart = Invoke-DtJobRaw @('start', '-RunFolder', $run.folder, '-Command', 'Write-Output released')
        Assert-True ($releasedStart.exit -ne 0 -and $releasedStart.text -match 'ROTATE_REQUIRED') 'a released lease has no holder, so no step defers'
        Invoke-DtJob @('irreversible', '-RunFolder', $run.folder, '-Action', 'end', '-Operation', 'merge') | Out-Null
        $again = Invoke-DtJobRaw @('start', '-RunFolder', $run.folder, '-Command', 'Write-Output after-merge')
        Assert-True ($again.exit -ne 0 -and $again.text -match 'ROTATE_REQUIRED') 'ending the step restores the refusal'
        Invoke-DtJob @('wait', '-RunFolder', $run.folder, '-JobId', 'j-0002', '-All', '-TimeoutSec', '60') | Out-Null

        # The text-mode context line fits the bytes reserved for it, so wait output stays inside the envelope cap.
        $longMissing = Join-Path $tempRoot (('deep-folder-name-' * 25) + 'transcript.jsonl')
        Write-Baseline -RunFolder $run.folder -CoordinatorId 'clong' -BaselineHost 'claude' -TranscriptPath $longMissing -Baseline 100000
        $env:DT_BUILD_COORDINATOR_ID = 'clong'
        $longWait = Invoke-DtJobRaw @('wait', '-RunFolder', $run.folder, '-JobId', 'j-0001', '-All', '-TimeoutSec', '5') -Text
        $utf8 = [System.Text.Encoding]::UTF8
        $ctxLine = $longWait.lines[-1]
        $waitBytes = $utf8.GetByteCount(($longWait.lines -join "`r`n") + "`r`n")
        Assert-True ($longWait.exit -eq 0 -and $ctxLine -like 'context: unavailable (*' -and $ctxLine.EndsWith('...[truncated]') -and $utf8.GetByteCount($ctxLine) + 2 -le 256 -and $waitBytes -le 8192) "an overlong context line is capped to its 256-byte reserve ($($utf8.GetByteCount($ctxLine)) bytes, wait output $waitBytes bytes)"
        $wide = & pwsh -NoProfile -Command ". '$dtJob'; `$l = Limit-DtJobContextLine ('context: ' + ([string][char]0x00E9 * 200) + ([char]::ConvertFromUtf32(0x1F600) * 40)); [System.Text.Encoding]::UTF8.GetByteCount(`$l); `$l.EndsWith('...[truncated]')"
        Assert-True ([int]@($wide)[0] -le 254 -and @($wide)[1] -eq 'True') "multi-byte context lines are capped by bytes ($(@($wide)[0]))"
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
    Invoke-DtJob @('irreversible', '-RunFolder', $run.folder, '-Action', 'begin', '-Operation', 'push', '-CoordinatorId', 'mc-codex') | Out-Null
    $tick = @(Invoke-Tick | Where-Object { $_.run_id -eq 'codex-rot' })[0]
    Assert-True ((Test-Alive $tree.child) -and (Test-Alive $tree.grandchild) -and [string]$tick.rotation -match 'rotation deferred' -and -not (Test-Path -LiteralPath (Join-Path $run.folder 'rotations.jsonl'))) "an irreversible step the lease holder opened defers the watcher kill ($($tick.rotation))"
    Invoke-DtJob @('irreversible', '-RunFolder', $run.folder, '-Action', 'end', '-Operation', 'push') | Out-Null
    # A step left open by an earlier coordinator is stale: it defers nothing, and Danny gets one DM for it.
    Invoke-DtJob @('irreversible', '-RunFolder', $run.folder, '-Action', 'begin', '-Operation', 'old-merge', '-CoordinatorId', 'mc-old') | Out-Null
    $tick = @(Invoke-Tick | Where-Object { $_.run_id -eq 'codex-rot' })[0]
    Start-Sleep -Milliseconds 500
    Assert-True (-not (Test-Alive $tree.child) -and -not (Test-Alive $tree.grandchild)) 'past the hard limit the watcher kills the coordinator and its child process, despite a stale irreversible step'
    $staleDms = @(Get-Content -LiteralPath $env:DT_TEST_DM_LOG | Where-Object { $_ -match 'old-merge' })
    $staleKey = @(Get-Content -LiteralPath (Join-Path $run.folder 'notifications.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { [string]$_.key -like 'dt-build:codex-rot:stale-irreversible:old-merge:*' })
    Assert-True ($staleDms.Count -eq 1 -and $staleDms[0] -match 'mc-old' -and $staleDms[0] -match 'irreversible -RunFolder' -and $staleKey.Count -eq 1 -and @($tick.stale_irreversible)[0].alert -eq 'sent') "a stale irreversible step sends one DM keyed by operation and opened time ($($staleKey | ConvertTo-Json -Compress))"
    $rot = @(Get-Content -LiteralPath (Join-Path $run.folder 'rotations.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($rot.Count -eq 1 -and $rot[0].coordinator_id -eq 'mc-codex' -and [long]$rot[0].tokens_at_kill -eq 130000 -and [long]$rot[0].hard_limit -eq 120000 -and [long]$rot[0].overshoot -eq 10000) "rotations.jsonl records tokens, hard limit, and overshoot ($($rot | ConvertTo-Json -Compress))"
    $events = @(Get-Content -LiteralPath (Join-Path $run.folder 'jobs/events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($events | Where-Object { $_.type -eq 'continuation_requested' -and $_.reason -eq 'context_rotation' }).Count -eq 1) 'the rotation appends one continuation_requested (context_rotation)'
    $lease = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'coordinator.lease') | ConvertFrom-Json
    $launched = @(if (Test-Path -LiteralPath $env:DT_TEST_LAUNCH_LOG) { Get-Content -LiteralPath $env:DT_TEST_LAUNCH_LOG | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.run_id -eq 'codex-rot' } })
    Assert-True ($lease.coordinator_id -eq 'mc-codex' -and $lease.released_utc -and $tick.action -eq 'launch' -and $launched.Count -eq 1 -and $launched[0].host -eq 'codex') "the lease is released and the relaunch rules start a fresh coordinator ($($tick.action))"
    $tick = @(Invoke-Tick | Where-Object { $_.run_id -eq 'codex-rot' })[0]
    Assert-True (@(Get-Content -LiteralPath (Join-Path $run.folder 'rotations.jsonl')).Count -eq 1 -and -not $tick.PSObject.Properties['rotation']) 'a released lease is not rotated again'
    Assert-True (@(Get-Content -LiteralPath $env:DT_TEST_DM_LOG | Where-Object { $_ -match 'old-merge' }).Count -eq 1 -and @($tick.stale_irreversible)[0].alert -eq 'already_sent') 'the stale step is not reported twice'
    # A second stale step opened at another time is its own DM.
    $irPath = Join-Path $run.folder 'irreversible.json'
    $irDoc = Get-Content -Raw -LiteralPath $irPath | ConvertFrom-Json
    $irDoc.open = @($irDoc.open) + @([pscustomobject][ordered]@{ operation = 'old-merge'; coordinator_id = 'mc-older'; began_utc = '2026-10-09T12:00:00.0000000Z' })
    Write-Utf8 -Path $irPath -Content ($irDoc | ConvertTo-Json -Depth 4)
    Invoke-Tick | Out-Null
    Assert-True (@(Get-Content -LiteralPath $env:DT_TEST_DM_LOG | Where-Object { $_ -match 'old-merge' }).Count -eq 2) 'each stale step, by operation and opened time, gets its own DM'
    Invoke-DtJob @('irreversible', '-RunFolder', $run.folder, '-Action', 'end', '-Operation', 'old-merge') | Out-Null

    # ---- watcher: a kill that leaves the coordinator running changes nothing and tells Danny once.
    $run = New-Run -Name 'kill-fail' -PinnedHost 'codex' -Managed
    $kfT = Join-Path $fixtures 'codex-kill-fail.jsonl'
    New-CodexRollout -Path $kfT -Inputs @(50000, 130000)
    $kfTree = Start-FakeTree -Name 'kill-fail'
    Write-Lease -RunFolder $run.folder -CoordinatorId 'mc-stuck' -LeaseHost 'codex' -LaunchedBy 'watcher' -LeasePid $kfTree.child -PidStartUtc $kfTree.start_utc
    Write-Baseline -RunFolder $run.folder -CoordinatorId 'mc-stuck' -BaselineHost 'codex' -TranscriptPath $kfT -Baseline 50000
    $leaseBefore = Get-Content -Raw -LiteralPath (Join-Path $run.folder 'coordinator.lease')
    $eventsPath = Join-Path $run.folder 'jobs/events.jsonl'
    $eventsBefore = if (Test-Path -LiteralPath $eventsPath) { Get-Content -Raw -LiteralPath $eventsPath } else { '' }
    $stubbed = & pwsh -NoProfile -Command ". '$watcher'; function Stop-WatcherProcessTree { param([int]`$ProcessId) throw 'Access is denied' }; `$entry = Get-DtJobRegistryEntry -RunFolder '$($run.folder)'; Invoke-WatcherContextRotation -Entry `$entry -NowUtc ([DateTime]::UtcNow); Invoke-WatcherContextRotation -Entry `$entry -NowUtc ([DateTime]::UtcNow)"
    $eventsAfter = if (Test-Path -LiteralPath $eventsPath) { Get-Content -Raw -LiteralPath $eventsPath } else { '' }
    Assert-True ([string]@($stubbed)[0] -match '^rotation kill failed: mc-stuck' -and [string]@($stubbed)[0] -match 'Access is denied' -and (Test-Alive $kfTree.child)) "a kill that throws is reported as rotation kill failed ($(@($stubbed) -join ' | '))"
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $run.folder 'coordinator.lease')) -eq $leaseBefore -and $eventsAfter -eq $eventsBefore -and -not (Test-Path -LiteralPath (Join-Path $run.folder 'rotations.jsonl'))) 'a failed kill leaves the lease, the events, and rotations.jsonl untouched'
    $kfDms = @(Get-Content -LiteralPath $env:DT_TEST_DM_LOG | Where-Object { $_ -match 'kill-fail' -and $_ -match 'could not stop it' })
    Assert-True ($kfDms.Count -eq 1 -and $kfDms[0] -match "Stop-Process -Id $($kfTree.child)" -and [string]@($stubbed)[0] -match 'alert sent' -and [string]@($stubbed)[1] -match 'alert already_sent') "a failed kill sends one DM with the stop command ($($kfDms.Count))"
    Get-Process -Id $kfTree.child, $kfTree.grandchild -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

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
        "git status; pwsh -NoProfile -File `"$dtJob`" lease -RunFolder x -Action release -CoordinatorId hc1",
        "& `"$dtJob`" status -RunFolder x 2>&1",
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
    Write-Lease -RunFolder $run.folder -CoordinatorId 'hc1' -LeaseHost 'claude'
    Invoke-DtJob @('irreversible', '-RunFolder', $run.folder, '-Action', 'begin', '-Operation', 'merge', '-CoordinatorId', 'hc1') | Out-Null
    Assert-True ($null -eq (Invoke-Hook $preHook (& $mk 'sess-hook' $hookHard 'Grep' @{ pattern = 'x' }))) 'an irreversible step the lease holder opened defers the hard-limit denials'
    Write-Lease -RunFolder $run.folder -CoordinatorId 'hc-other' -LeaseHost 'claude'
    Assert-True (Test-Denied (Invoke-Hook $preHook (& $mk 'sess-hook' $hookHard 'Grep' @{ pattern = 'x' }))) 'once hc1 no longer holds the lease its step defers nothing'
    Invoke-DtJob @('irreversible', '-RunFolder', $run.folder, '-Action', 'end', '-Operation', 'merge') | Out-Null
    # Past-hard shell allowlist, segment by segment.
    $deniedProbe = @(
        'Get-Content skills/dt-build/scripts/dt-job.ps1',
        'cat big.log | pwsh -File dt-job.ps1 status',
        'pwsh -File dt-job.ps1 status & cat big.log',
        'cat big.log # dt-job.ps1',
        'cat big.log | head -5000 # dt-job.ps1',
        'pwsh -Command Get-Content big.log -File dt-job.ps1',
        'pwsh -File my-dt-job.ps1 status',
        '& cat dt-job.ps1',
        'type dt-job.ps1',
        'git status && cat big.log',
        'git status || Get-Content big.log',
        "pwsh -File dt-job.ps1 status`ncat big.log",
        'git show HEAD:skills/dt-build/scripts/dt-job.ps1'
    )
    $allowedProbe = @(
        'pwsh -File dt-job.ps1 status',
        'pwsh -NoProfile -NonInteractive -File "D:/x y/scripts/dt-job.ps1" wait -RunFolder x -JobId j-0001 -All -TimeoutSec 5',
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\s\read-evidence.ps1' -Path x",
        '& "D:/x/scripts/dt-job.ps1" status -RunFolder x',
        '. ./scripts/write-build-state.ps1 -Path x',
        'pwsh -File dt-job.ps1 status 2>&1',
        'git status --short',
        'git -C "D:/repo" log --oneline -3',
        'git rev-parse HEAD',
        'git status; pwsh -File dt-job.ps1 status',
        "pwsh -NoProfile -File `"$dtJob`" request-continuation -RunFolder `"$($run.folder)`" -Reason context_rotation"
    )
    $probeFile = Join-Path $tempRoot 'shell-probe.json'
    Write-Utf8 -Path $probeFile -Content (([ordered]@{ denied = $deniedProbe; allowed = $allowedProbe }) | ConvertTo-Json)
    $probe = (& pwsh -NoProfile -Command ". '$preHook'; `$p = Get-Content -Raw -LiteralPath '$probeFile' | ConvertFrom-Json; [ordered]@{ denied = @(`$p.denied | Where-Object { Test-HookShellAllowed `$_ }); allowed = @(`$p.allowed | Where-Object { -not (Test-HookShellAllowed `$_) }) } | ConvertTo-Json -Compress") | ConvertFrom-Json
    Assert-True (@($probe.denied).Count -eq 0) "script names as arguments or comments, and pipes or & after an allowed call, are denied (wrongly allowed: $(@($probe.denied) -join ' || '))"
    Assert-True (@($probe.allowed).Count -eq 0) "pwsh -File, & and . calls of the state scripts and git status/log/rev-parse are allowed (wrongly denied: $(@($probe.allowed) -join ' || '))"
    Assert-True (Test-Denied (Invoke-Hook $preHook (& $mk 'sess-hook' $hookHard 'Bash' @{ command = 'Get-Content skills/dt-build/scripts/dt-job.ps1' }))) 'past hard, reading dt-job.ps1 through the shell is denied end to end'
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

    # ---- coordinator identity: a discovered guess never marks a session; the PostToolUse capture is authoritative.
    $run = New-Run -Name 'capture'
    $wrongT = Join-Path $fixtures 'capture-wrong-session.jsonl'
    New-ClaudeTranscript -Path $wrongT -Totals @(50000)
    $capT = Join-Path $fixtures 'capture-own-session.jsonl'
    New-ClaudeTranscript -Path $capT -Totals @(60000, 90000)
    Write-Baseline -RunFolder $run.folder -CoordinatorId 'cap1' -BaselineHost 'claude' -TranscriptPath $wrongT -Baseline 50000 -Source 'discovered'
    Assert-True ($null -eq (Invoke-Hook $preHook (& $mk 'capture-wrong-session' $wrongT 'CronCreate' @{ cron = '*' }))) 'the session whose transcript discovery guessed is not treated as a coordinator'
    $mkBoot = { param([string]$Command) @{ session_id = 'capture-own-session'; transcript_path = $capT; cwd = $tempRoot; hook_event_name = 'PostToolUse'; tool_name = 'Bash'; tool_input = @{ command = $Command }; tool_response = @{ stdout = 'ok' } } }
    Invoke-Hook $postHook (& $mkBoot "Get-Content `"$dtJob`" # mark-bootstrap -RunFolder `"$($run.folder)`" -CoordinatorId cap1") | Out-Null
    $stored = (Get-Content -Raw -LiteralPath (Join-Path $run.folder 'context-baseline.json') | ConvertFrom-Json).coordinators.cap1
    Assert-True ($stored.transcript_source -eq 'discovered' -and $stored.transcript_path -eq $wrongT) 'a shell call that only mentions mark-bootstrap captures nothing'
    Invoke-Hook $postHook (& $mkBoot "pwsh -NoProfile -File `"$dtJob`" mark-bootstrap -RunFolder `"$($run.folder)`" -CoordinatorId cap1 -Host claude") | Out-Null
    $stored = (Get-Content -Raw -LiteralPath (Join-Path $run.folder 'context-baseline.json') | ConvertFrom-Json).coordinators.cap1
    Assert-True ($stored.transcript_source -eq 'hook' -and $stored.session_id -eq 'capture-own-session' -and $stored.transcript_path -eq [System.IO.Path]::GetFullPath($capT) -and [long]$stored.baseline_tokens -eq 90000) "the PostToolUse hook replaces a discovered transcript with its own session and re-reads the baseline ($($stored | ConvertTo-Json -Compress))"
    Assert-True (Test-Denied (Invoke-Hook $preHook (& $mk 'capture-own-session' $capT 'CronCreate' @{ cron = '*' }))) 'after the capture the calling session is a coordinator session'
    Assert-True ($null -eq (Invoke-Hook $preHook (& $mk 'capture-wrong-session' $wrongT 'CronCreate' @{ cron = '*' }))) 'after the capture the guessed session is still left alone'
    # The coordinator id may come from the env var, and a repeat capture changes nothing.
    Write-Baseline -RunFolder $run.folder -CoordinatorId 'cap2' -BaselineHost 'claude' -TranscriptPath $wrongT -Baseline 50000 -Source 'discovered'
    $env:DT_BUILD_COORDINATOR_ID = 'cap2'
    try { Invoke-Hook $postHook (& $mkBoot "& `"$dtJob`" mark-bootstrap -RunFolder `"$($run.folder)`" -Host claude") | Out-Null }
    finally { Remove-Item Env:DT_BUILD_COORDINATOR_ID -ErrorAction SilentlyContinue }
    $all = (Get-Content -Raw -LiteralPath (Join-Path $run.folder 'context-baseline.json') | ConvertFrom-Json).coordinators
    Assert-True ($all.cap2.transcript_source -eq 'hook' -and $all.cap2.transcript_path -eq [System.IO.Path]::GetFullPath($capT) -and $all.cap1.captured_utc) 'the capture takes the coordinator id from DT_BUILD_COORDINATOR_ID when the command does not name it'
    $capturedAt = [string]$all.cap1.captured_utc
    Invoke-Hook $postHook (& $mkBoot "pwsh -NoProfile -File `"$dtJob`" mark-bootstrap -RunFolder `"$($run.folder)`" -CoordinatorId cap1 -Host claude") | Out-Null
    Assert-True ([string]((Get-Content -Raw -LiteralPath (Join-Path $run.folder 'context-baseline.json') | ConvertFrom-Json).coordinators.cap1.captured_utc) -eq $capturedAt) 'a repeat capture for the same session writes nothing'

    # ---- hook cost: with the env var unset and no registered run, both hooks exit before loading any dt-build script.
    $savedState = $env:DT_BUILD_STATE_DIR
    $env:DT_BUILD_STATE_DIR = Join-Path $tempRoot 'empty-state'
    try {
        Assert-True ($null -eq (Invoke-Hook $preHook (& $mk 'capture-own-session' $capT 'CronCreate' @{ cron = '*' }))) 'with no registered run a recorded session is not looked up'
        Assert-True ($null -eq (Invoke-Hook $postHook (& $mk 'capture-own-session' $capT 'Bash' @{ command = 'git status' } 'PostToolUse'))) 'PostToolUse exits the same way'
        Write-Utf8 -Path (Join-Path $env:DT_BUILD_STATE_DIR 'active-runs.json') -Content '{ "runs": [] }'
        Assert-True ($null -eq (Invoke-Hook $preHook (& $mk 'capture-own-session' $capT 'CronCreate' @{ cron = '*' }))) 'a registry that lists no runs is idle too'
    }
    finally { $env:DT_BUILD_STATE_DIR = $savedState }
    $preText = Get-Content -Raw -LiteralPath $preHook
    $postText = Get-Content -Raw -LiteralPath $postHook
    $idleMark = '(Test-HookIdle)) { exit 0 }'
    $guardLoad = ". (Join-Path `$PSScriptRoot '..\scripts\context-guard.ps1')"
    $dtJobLoad = ". (Join-Path `$PSScriptRoot '..\scripts\dt-job.ps1')"
    $idleAt = $preText.IndexOf($idleMark)
    $postIdleAt = $postText.IndexOf($idleMark)
    Assert-True ($idleAt -gt 0 -and $idleAt -lt $preText.IndexOf($guardLoad) -and -not $preText.Contains($dtJobLoad) -and $postIdleAt -gt 0 -and $postIdleAt -lt $postText.IndexOf($guardLoad) -and $postIdleAt -lt $postText.IndexOf($dtJobLoad)) 'in both hooks the idle exit comes before context-guard.ps1 or dt-job.ps1 loads, and PreToolUse never loads dt-job.ps1'

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
