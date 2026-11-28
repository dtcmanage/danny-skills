Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../check-ai-item-exits.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ai-item-exits-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$transcript = Join-Path $fixture 'session.jsonl'
$passed = 0
$failed = 0
$originalConfigDir = $env:CLAUDE_CONFIG_DIR
$originalSessionIds = @($env:CLAUDE_SESSION_ID, $env:CLAUDE_CODE_SESSION_ID)
# The suite itself may run inside a Claude session; start with no ambient session id.
$env:CLAUDE_SESSION_ID = $null
$env:CLAUDE_CODE_SESSION_ID = $null

function Assert-Check([bool]$Condition, [string]$Name) {
    if ($Condition) { $script:passed++; "PASS: $Name" }
    else { $script:failed++; "FAIL: $Name" }
}
function Set-Transcript([object[]]$Records) {
    $lines = @($Records | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress })
    [IO.File]::WriteAllLines($transcript, $lines)
}
function Invoke-Check {
    & $scriptPath -TranscriptPath $transcript -BaseUrl $baseUrl -Json | ConvertFrom-Json
}

$listener = [Net.HttpListener]::new()
$server = $null
try {
    # OS-allocated loopback port; each run has isolated files and listener state.
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = $probe.LocalEndpoint.Port
    $probe.Stop()
    $baseUrl = "http://127.0.0.1:$port"
    $listener.Prefixes.Add("$baseUrl/")
    $listener.Start()
    $rows = @(
        @{ num=12; title='Starter item'; lane='ai'; updated_at='2026-11-15T23:00:00Z' },
        @{ num=13; title='Already noted'; lane='ai'; updated_at='2026-11-16T10:01:00Z' },
        @{ num=14; title='Echoed add'; lane='ai'; updated_at='2026-11-15T23:00:00Z' },
        @{ num=15; title='Other workstation command'; lane='ai'; updated_at='2026-11-15T23:00:00Z' },
        @{ num=16; title='Untouched'; lane='ai'; updated_at='2026-11-15T23:00:00Z' },
        @{ num=17; title='Human lane'; lane='yours'; updated_at='2026-11-15T23:00:00Z' },
        @{ num=18; title='At start'; lane='ai'; updated_at='2026-11-16T10:00:00Z' }
    ) | ConvertTo-Json -Compress
    $requests = Join-Path $fixture 'requests.txt'
    $server = [PowerShell]::Create()
    [void]$server.AddScript({
        param($Http, $Body, $Log)
        try {
            while ($Http.IsListening) {
                $context = $Http.GetContext()
                [IO.File]::AppendAllText($Log, $context.Request.RawUrl + "`n")
                $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
                $context.Response.ContentType = 'application/json'
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.Close()
            }
        } catch { if ($Http.IsListening) { throw } }
    }).AddArgument($listener).AddArgument($rows).AddArgument($requests)
    $serverRun = $server.BeginInvoke()

    Set-Transcript @(
        @{ timestamp='2026-11-16T10:00:00Z'; type='user'; message=@{role='user'; content='Work on #12 Starter item.'} },
        @{ message=@{role='assistant'; content=@(@{type='tool_use'; input=@{command='pwsh -File "D:\Command Center\cc.ps1" update 13 --context "note"'}})} },
        @{ message=@{role='user'; content=@(@{type='tool_result'; content="#14 Echoed add`n#17 Human lane`n#18 At start"})} },
        @{ payload=@{type='function_call'; arguments='{"cmd":"pwsh -File cc.ps1 attempt 15 --note reason"}'} },
        @{ message=@{role='assistant'; content='Ordinary prose about #16 is not a command or echo.'} }
    )
    $result = Invoke-Check
    Assert-Check (($result.findings.num -join ',') -eq '12,14,15') 'flags starter, write echo and command across workstations'
    Assert-Check (-not $result.could_not_check) 'reachable server checked'
    Assert-Check (($result.touched_items -join ',') -eq '12,13,14,15,17,18') 'deduplicated touched numbers without incidental prose'
    Assert-Check (@($result.findings | Where-Object num -eq 13).Count -eq 0) 'updated after start is not flagged'
    Assert-Check (@($result.findings | Where-Object num -eq 18).Count -eq 0) 'updated exactly at start is not before start'
    Assert-Check ($result.findings[0].allowed_exits.Count -eq 3) 'three allowed exits in JSON'
    Assert-Check ((Get-Content $requests -Raw).Trim() -eq '/items/ready') 'all-workstation unauthenticated ready URL'
    $plain = @(& $scriptPath -TranscriptPath $transcript -BaseUrl $baseUrl)
    Assert-Check ($plain.Count -eq 3 -and $plain[0] -match '^#12 Starter item.*done.*--run-on/--after-item.*--next-action') 'plain output identifies item and exit choices'
    $override = & $scriptPath -TranscriptPath $transcript -SessionStartUtc '2026-11-15T22:00:00Z' -BaseUrl $baseUrl -Json | ConvertFrom-Json
    Assert-Check ($override.findings.Count -eq 0) 'explicit session start overrides transcript timestamp'

    Set-Transcript @(
        @{ timestamp='2026-11-16T10:00:00Z'; payload=@{role='user'; content=@(@{type='input_text'; text='Pick up #12 Starter item.'})} },
        @{ payload=@{type='function_call'; arguments='{"cmd":"cc.ps1 keep 12"}'} }
    )
    Assert-Check ((Invoke-Check).findings.Count -eq 1) 'Codex starter content and repeated command deduplicate'
    Set-Transcript @(@{timestamp='2026-11-16T10:00:00Z'; role='user'; content='No tracked work this session.'})
    $requestCount = @(Get-Content $requests).Count
    $empty = Invoke-Check
    Assert-Check ($empty.findings.Count -eq 0 -and $empty.touched_items.Count -eq 0) 'no touched items is clean'
    Assert-Check (@(Get-Content $requests).Count -eq $requestCount) 'no touched items skips HTTP'

    # Discover from an isolated config root and a cwd containing punctuation.
    $env:CLAUDE_CONFIG_DIR = Join-Path $fixture 'config'
    $projectCwd = Join-Path $fixture 'project with.dots'
    [void][IO.Directory]::CreateDirectory($projectCwd)
    Push-Location $projectCwd
    try {
        $projectName = (Get-Location).Path -replace '[^a-zA-Z0-9]', '-'
        $projectDir = Join-Path "$env:CLAUDE_CONFIG_DIR/projects" $projectName
        [void][IO.Directory]::CreateDirectory((Join-Path $projectDir 'nested'))
        $old = Join-Path $projectDir 'old.jsonl'
        $current = Join-Path $projectDir 'current.jsonl'
        Set-Transcript @(@{timestamp='2026-11-16T10:00:00Z'; role='user'; content='No tracked work.'})
        Copy-Item $transcript $old
        Set-Transcript @(@{timestamp='2026-11-16T10:00:00Z'; role='user'; content="Command Center item #12 (permanent id 123), workstation Tech HQ.`nContinue."})
        Copy-Item $transcript $current
        (Get-Item $old).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-10)
        (Get-Item $current).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-5)
        Set-Transcript @(@{timestamp='2026-11-16T10:00:00Z'; role='user'; content='Work on #16.'})
        Copy-Item $transcript (Join-Path $projectDir 'nested/newest.jsonl')
        $discoveredErr = Join-Path $fixture 'discover.err'
        $discovered = & pwsh -NoProfile -File $scriptPath -BaseUrl $baseUrl -Json 2> $discoveredErr | ConvertFrom-Json
        Assert-Check (($discovered.touched_items -join ',') -eq '12' -and $discovered.findings.Count -eq 1) 'without a session id, discovers newest main transcript, Run header and encoded cwd; excludes a newer nested transcript'
        Assert-Check ([string](Get-Content $discoveredErr -Raw) -match '(?s)WARNING: no session id.*current\.jsonl') 'newest-file fallback warns and names the chosen file'
        $explicit = Invoke-Check
        Assert-Check (($explicit.touched_items -join ',') -eq '16') 'explicit path overrides automatic discovery'

        # A session id picks its own transcript even when another session's file is newer.
        $mine = Join-Path $projectDir 'aaaa1111-2222-3333-4444-555566667777.jsonl'
        Copy-Item $old $mine
        (Get-Item $mine).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-30)
        foreach ($var in @('CLAUDE_SESSION_ID', 'CLAUDE_CODE_SESSION_ID')) {
            Set-Item "env:$var" 'aaaa1111-2222-3333-4444-555566667777'
            $byId = & $scriptPath -BaseUrl $baseUrl -Json | ConvertFrom-Json
            Assert-Check ($byId.touched_items.Count -eq 0) "$var selects the session's own transcript over a newer one"
            Set-Item "env:$var" $null
        }
        # Run from another directory (e.g. the skill folder): the id still finds the transcript.
        Push-Location $fixture
        try {
            $env:CLAUDE_CODE_SESSION_ID = 'aaaa1111-2222-3333-4444-555566667777'
            $elsewhere = & $scriptPath -BaseUrl $baseUrl -Json | ConvertFrom-Json
            Assert-Check ($elsewhere.touched_items.Count -eq 0) 'session id finds the transcript from another working directory'
            $env:CLAUDE_CODE_SESSION_ID = 'ffff0000-0000-0000-0000-000000000000'
            $unknown = @(& pwsh -NoProfile -File $scriptPath -BaseUrl $baseUrl -Json 2>&1)
            Assert-Check ($LASTEXITCODE -ne 0 -and ($unknown -join ' ') -match 'TRANSCRIPT_NOT_FOUND.*ffff0000') 'unknown session id fails with TRANSCRIPT_NOT_FOUND, never another file'
        } finally { Pop-Location; $env:CLAUDE_CODE_SESSION_ID = $null }

        Remove-Item -LiteralPath $old, $current, $mine
        $missing = @(& pwsh -NoProfile -File $scriptPath -BaseUrl $baseUrl 2>&1)
        Assert-Check ($LASTEXITCODE -ne 0 -and ($missing -join ' ') -match 'TRANSCRIPT_NOT_FOUND') 'nested-only folder fails with TRANSCRIPT_NOT_FOUND'
        $env:CLAUDE_CONFIG_DIR = Join-Path $fixture 'missing-config'
        $missing = @(& pwsh -NoProfile -File $scriptPath -BaseUrl $baseUrl 2>&1)
        Assert-Check ($LASTEXITCODE -ne 0 -and ($missing -join ' ') -match 'TRANSCRIPT_NOT_FOUND') 'missing project folder fails with TRANSCRIPT_NOT_FOUND'
        $missing = @(& pwsh -NoProfile -File $scriptPath -TranscriptPath (Join-Path $fixture 'nope.jsonl') -BaseUrl $baseUrl 2>&1)
        Assert-Check ($LASTEXITCODE -ne 0 -and ($missing -join ' ') -match 'TRANSCRIPT_NOT_FOUND') 'missing explicit transcript fails with TRANSCRIPT_NOT_FOUND'
    } finally { Pop-Location }

    $listener.Stop()
    $server.EndInvoke($serverRun)
    Set-Transcript @(@{timestamp='2026-11-16T10:00:00Z'; role='user'; content='Finish #12 Starter item.'})
    $unreachable = Invoke-Check
    Assert-Check ($unreachable.could_not_check -and $unreachable.findings.Count -eq 0) 'unreachable returns explicit unknown, no findings'
    $output = @(& pwsh -NoProfile -File $scriptPath -TranscriptPath $transcript -BaseUrl $baseUrl)
    Assert-Check ($LASTEXITCODE -eq 0 -and $output.Count -eq 1 -and $output[0] -match 'could not check') 'unreachable prints one line and exits zero'
} finally {
    $env:CLAUDE_CONFIG_DIR = $originalConfigDir
    $env:CLAUDE_SESSION_ID = $originalSessionIds[0]
    $env:CLAUDE_CODE_SESSION_ID = $originalSessionIds[1]
    $listener.Close()
    if ($null -ne $server) { $server.Dispose() }
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped temp root.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
# The backstop that runs this check must consult the full open-item and owner inventory.
$skillText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../SKILL.md')).Replace("`r`n", "`n")
$backstop = [regex]::Match($skillText, '(?s)7\. \*\*Command Center backstop:\*\*.*?(?=\n8\. )').Value
$ownership = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../references/hygiene-ownership.md'))
Assert-Check ($backstop.Contains('references/hygiene-ownership.md') -and $backstop.Contains('cc.ps1" list` (no `--workstation` filter') -and $backstop.Contains('live session owners') -and $backstop.Contains('blocks creation')) 'backstop lists all open items and live owners before any write'
Assert-Check (-not ($backstop -match 'list --workstation') -and $backstop.Contains('rather than add a duplicate') -and $backstop.Contains('keep its owner') -and $backstop.Contains('to the master once')) 'backstop never narrows its inventory and keeps owner, no-duplicate and once-only rules'
Assert-Check ($ownership.Contains('SKILL step 7') -and $ownership.Contains('no `--workstation` filter')) 'ownership reference covers the backstop with an unfiltered inventory'
"SUMMARY: $passed passed; $failed failed"
if ($failed) { exit 1 }
