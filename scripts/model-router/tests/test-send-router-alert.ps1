Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../send-router-alert.ps1')
. (Join-Path $PSScriptRoot '../resolve-model.ps1')

$script:passed = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Output "PASS: $Name"
}

$priorState = $env:DT_MODEL_ROUTER_STATE
$temp = Join-Path $env:TEMP ('model-router-alert-test-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($temp) | Out-Null
$env:DT_MODEL_ROUTER_STATE = $temp
$priorClaudeCredentials = $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS
$env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = Join-Path $temp 'missing-claude-credentials.json'

try {
    Remove-Variable -Name RouterAlertSecretCache -Scope Script -ErrorAction SilentlyContinue
    $probeError = ''
    try { $null = Invoke-RouterAlertTransport -Request @{ kind = 'secret'; name = 'router-selftest-nonexistent-secret' } -Deadline ([datetime]::UtcNow.AddSeconds(-1)) } catch { $probeError = $_.Exception.Message }
    Assert-True ($probeError -eq 'Alert batch deadline exceeded') 'secret path initializes its cache under StrictMode and stops before network access'
    $script:requests = [System.Collections.Generic.List[object]]::new()
    $script:failDm = $false
    $script:failEmail = $false
    $script:fakeToken = 'ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    $fake = {
        param($request)
        $script:requests.Add($request)
        if ($request.kind -eq 'secret') {
            if ($request.name -eq 'discord-bot-token') { return $script:fakeToken }
            return 're_fake_key'
        }
        if ($request.uri -like '*/oauth2/applications/@me') { return [pscustomobject]@{ owner = [pscustomobject]@{ id = '123456789' } } }
        if ($request.uri -like '*/users/@me/channels') { return [pscustomobject]@{ id = 'dm-channel' } }
        if ($request.uri -like '*/channels/*/messages') {
            if ($script:failDm) { throw "Discord rejected $script:fakeToken" }
            return [pscustomobject]@{ id = 'discord-message' }
        }
        if ($request.uri -eq 'https://api.resend.com/emails') {
            if ($script:failEmail) { throw "Resend rejected $script:fakeToken" }
            return [pscustomobject]@{ id = 'resend-message' }
        }
        throw 'Unexpected request'
    }

    $first = Send-RouterAlert -Key 'first' -Message 'First alert' -Transport $fake 6>&1
    $firstStatus = @($first | Where-Object { $_ -is [pscustomobject] })[-1]
    Assert-True ($firstStatus.sent -and $firstStatus.channel -eq 'discord' -and -not $firstStatus.deduped) 'first send delivers by DM'
    Assert-True (@($first | ForEach-Object { [string]$_ } | Where-Object { $_ -eq 'ROUTER_ALERT: First alert' }).Count -eq 1) 'chat line format'
    $count = $script:requests.Count
    $again = Send-RouterAlert -Key 'first' -Message 'First alert' -Transport $fake 6>&1
    $againStatus = @($again | Where-Object { $_ -is [pscustomobject] })[-1]
    Assert-True ($againStatus.sent -and $againStatus.deduped -and $script:requests.Count -eq $count) 'repeat key dedupes without transport'
    $batch = @(Send-RouterAlerts -Alerts @('first'))
    Assert-True ($batch.Count -eq 1 -and $batch[0].deduped -and $script:requests.Count -eq $count) 'batch helper accepts resolver string alerts'

    $script:failDm = $true
    $fallback = Send-RouterAlert -Key 'fallback' -Message 'Fallback alert' -Transport $fake 6>&1
    $fallbackStatus = @($fallback | Where-Object { $_ -is [pscustomobject] })[-1]
    Assert-True ($fallbackStatus.sent -and $fallbackStatus.channel -eq 'email') 'DM failure falls back to email'
    Assert-True (@($script:requests | Where-Object { $_.kind -eq 'http' -and $_.uri -like '*/oauth2/applications/@me' }).Count -eq 1) 'owner ID cached after first lookup'
    Assert-True (@($script:requests | Where-Object { $_.kind -eq 'http' -and $_.uri -like 'https://discord.com/*' -and $_.headers['User-Agent'] -eq 'DiscordBot (https://github.com/dtcmanage/danny-skills, 1)' }).Count -eq 5) 'Discord requests carry User-Agent'
    $cachedCfg = Get-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'alert-config.json') -Raw | ConvertFrom-Json
    Assert-True ($cachedCfg.owner_id -eq '123456789' -and $cachedCfg.recipient_source -eq 'application-owner') 'DM recipient is the bot application owner'
    Set-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'alert-config.json') -Value '{"owner_id":"324036629440495617"}'
    $savedRequests = $script:requests; $savedFailDm = $script:failDm
    $script:requests = [System.Collections.Generic.List[object]]::new()
    $script:failDm = $false
    [void](Send-RouterAlert -Key 'stale-owner-cache' -Message 'Stale cache alert' -Transport $fake 6>&1)
    Assert-True (@($script:requests | Where-Object { $_.kind -eq 'http' -and $_.uri -like '*/oauth2/applications/@me' }).Count -eq 1 -and @($script:requests | Where-Object { $_.ContainsKey('body') -and [string]$_['body'] -like '*324036629440495617*' }).Count -eq 0) 'legacy guild-owner cache is ignored and never messaged'
    $script:requests = $savedRequests; $script:failDm = $savedFailDm
    $mailRequest = @($script:requests | Where-Object { $_.kind -eq 'http' -and $_.uri -eq 'https://api.resend.com/emails' })[-1]
    Assert-True ($mailRequest.headers['Idempotency-Key'] -like 'model-router-*' -and ($mailRequest.body | ConvertFrom-Json).from -eq 'finance@notification.thaicapital.com') 'email sender and idempotency key'

    $script:failEmail = $true
    $failed = Send-RouterAlert -Key 'retry' -Message 'Retry alert' -Transport $fake 6>&1
    $failedStatus = @($failed | Where-Object { $_ -is [pscustomobject] })[-1]
    Assert-True (-not $failedStatus.sent -and $failedStatus.channel -eq 'none' -and $failedStatus.error) 'both channels fail without throwing'
    $script:failDm = $false
    $retried = Send-RouterAlert -Key 'retry' -Message 'Retry alert' -Transport $fake 6>&1
    $retryStatus = @($retried | Where-Object { $_ -is [pscustomobject] })[-1]
    Assert-True ($retryStatus.sent -and -not $retryStatus.deduped) 'failed key remains retryable'
    $log = Get-Content -LiteralPath (Join-Path $temp 'alert-log.jsonl') -Raw
    Assert-True ($log -notmatch [regex]::Escape($script:fakeToken) -and (($first + $again + $fallback + $failed + $retried | Out-String) -notmatch [regex]::Escape($script:fakeToken))) 'log and output contain no fake token'
    Assert-True (@($log -split '\r?\n' | Where-Object { $_ -match 'delivery_failed' }).Count -eq 1) 'failed delivery logged'

    $script:logAttempts = 0
    function Write-RouterAlertLog { $script:logAttempts++; throw 'synthetic log lock' }
    $logFailure = @(Send-RouterAlert -Key 'log-failure' -Message 'Delivered despite log lock' -Transport $fake 6>&1 | Where-Object { $_ -is [pscustomobject] })[-1]
    Assert-True ($logFailure.sent -and $logFailure.channel -eq 'discord' -and $logFailure.log_error -and $script:logAttempts -eq 3) 'delivered status survives log write failure after retries'
    . (Join-Path $PSScriptRoot '../send-router-alert.ps1')

    $mutexReady = Join-Path $temp 'mutex-ready'
    $holder = Start-ThreadJob -ScriptBlock {
        param($ready)
        $mutex = [System.Threading.Mutex]::new($false, 'Local\DtModelRouterAlert')
        try { $null = $mutex.WaitOne(); [IO.File]::WriteAllText($ready, 'ready'); Start-Sleep -Seconds 7 }
        finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
    } -ArgumentList $mutexReady
    try {
        $limit = (Get-Date).AddSeconds(2)
        while (-not (Test-Path -LiteralPath $mutexReady) -and (Get-Date) -lt $limit) { Start-Sleep -Milliseconds 20 }
        Assert-True (Test-Path -LiteralPath $mutexReady) 'mutex holder starts'
        $beforeBusy = $script:requests.Count
        $busy = Send-RouterAlert -Key 'busy-key' -Message 'No delivery' -Transport $fake
        Assert-True (-not $busy.sent -and -not $busy.deduped -and $busy.error -eq 'busy' -and $script:requests.Count -eq $beforeBusy) 'mutex timeout leaves alert retryable without transport'
    } finally { Wait-Job -Job $holder | Out-Null; Remove-Job -Job $holder }

    $messageResult = @(Send-RouterAlerts -Alerts @('new-model:gpt-test-readable') -Transport $fake 6>&1 | Where-Object { $_ -is [pscustomobject] })[-1]
    $messageRequest = @($script:requests | Where-Object { $_.kind -eq 'http' -and $_.uri -like '*/channels/*/messages' })[-1]
    $messageBody = $messageRequest.body | ConvertFrom-Json
    Assert-True ($messageResult.sent -and $messageBody.content -match 'gpt-test-readable' -and @($messageBody.allowed_mentions.parse).Count -eq 0) 'key-only alert gets readable Discord text with no mentions'
    $longText = '@everyone ' + ('x' * 2000)
    $longResult = @(Send-RouterAlert -Key 'long-message' -Message $longText -Transport $fake 6>&1 | Where-Object { $_ -is [pscustomobject] })[-1]
    $longBody = (@($script:requests | Where-Object { $_.kind -eq 'http' -and $_.uri -like '*/channels/*/messages' })[-1].body | ConvertFrom-Json)
    Assert-True ($longResult.sent -and $longBody.content.Length -eq 1900 -and @($longBody.allowed_mentions.parse).Count -eq 0) 'Discord body is capped at 1900 characters without mentions'
    Assert-True ((Get-RouterAlertMessage -Key 'router-wait: resume after October 1, 2026 3:00 PM ET') -eq 'Model router: every eligible vendor is at its limit. resume after October 1, 2026 3:00 PM ET.') 'router-wait key renders the resume line'
    Assert-True ((Get-RouterAlertMessage -Key 'new-model:gpt-test') -match 'gpt-test' -and (Get-RouterAlertMessage -Key 'unknown:key') -eq 'unknown:key') 'known keys are explained and unknown keys stay intact'

    [IO.File]::AppendAllText((Join-Path $temp 'alert-log.jsonl'), '{"event":"delivered","key":"cli-json","channel":"discord"}' + [Environment]::NewLine)
    @{ checked_at = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $temp 'last-check.json')
    $cliCases = @(
        @{ name = 'resolve-model'; arguments = @('-Category','routine-coding','-Lane','claude','-SkipModelCheck','-Json'); property = 'model' },
        @{ name = 'check-new-models'; arguments = @('-Json'); property = 'skipped' },
        @{ name = 'send-router-alert'; arguments = @('-Key','cli-json','-Message','Already delivered','-Json'); property = 'deduped' }
    )
    foreach ($case in $cliCases) {
        $path = Join-Path $PSScriptRoot "../$($case.name).ps1"
        $cliArgs = $case.arguments
        $lines = @(& pwsh -NoProfile -File $path @cliArgs)
        $exitCode = $LASTEXITCODE
        $parsed = if ($lines.Count -eq 1) { $lines[0] | ConvertFrom-Json } else { $null }
        Assert-True ($exitCode -eq 0 -and $lines.Count -eq 1 -and $parsed -and $parsed.PSObject.Properties[$case.property]) "$($case.name) -Json emits exactly one parseable object"
    }

    # A real (non-deduped) send in -Json script mode keeps stdout to one JSON object; the
    # chat line goes to stderr. Child processes get the fake transport through the env seam.
    $fakeScript = Join-Path $temp 'fake-transport.ps1'
    $fakeLog = Join-Path $temp 'fake-transport.log'
    Set-Content -LiteralPath $fakeScript -Value @'
param($request)
$log = Join-Path $env:DT_MODEL_ROUTER_STATE 'fake-transport.log'
Add-Content -LiteralPath $log -Value ([string]$request['kind'] + ' ' + [string]$request['uri'])
if ($request['uri'] -like '*/channels/*/messages') { Set-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'fake-delivered-message.txt') -Value (($request['body'] | ConvertFrom-Json).content) }
if ($request['kind'] -eq 'secret') { return 'fake-secret' }
if ($request['uri'] -like '*/oauth2/applications/@me') { return [pscustomobject]@{ owner = [pscustomobject]@{ id = '123456789' } } }
if ($request['uri'] -like '*/users/@me/channels') { return [pscustomobject]@{ id = 'dm-channel' } }
return [pscustomobject]@{ id = 'fake-message' }
'@
    $priorTransport = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $fakeScript
    try {
        $jsonSendCases = @(
            @{ name = 'send-router-alert'; arguments = @('-Key','cli-json-fresh','-Message','Fresh JSON-mode alert','-Json'); property = 'sent' },
            @{ name = 'send-router-alert'; arguments = @('-Key','router-wait: resume after Thu 2026-10-01 3:00 PM ET','-Json'); property = 'sent'; messagePrefix = 'Model router: every eligible vendor is at its limit.' },
            @{ name = 'resolve-model'; arguments = @('-Category','routine-coding','-Lane','claude','-SkipModelCheck','-SendAlerts','-Json'); property = 'model' }
        )
        Remove-Item -LiteralPath (Join-Path $temp 'alert-log.jsonl') -Force -ErrorAction SilentlyContinue
        foreach ($case in $jsonSendCases) {
            $path = Join-Path $PSScriptRoot "../$($case.name).ps1"
            $cliArgs = $case.arguments
            $errPath = Join-Path $temp "$($case.name)-stderr.txt"
            $before = if (Test-Path -LiteralPath $fakeLog) { @(Get-Content -LiteralPath $fakeLog).Count } else { 0 }
            $lines = @(& pwsh -NoProfile -File $path @cliArgs 2>$errPath)
            $exitCode = $LASTEXITCODE
            $after = if (Test-Path -LiteralPath $fakeLog) { @(Get-Content -LiteralPath $fakeLog).Count } else { 0 }
            $parsed = if ($lines.Count -eq 1) { $lines[0] | ConvertFrom-Json } else { $null }
            Assert-True ($after -gt $before) "$($case.name) -Json performed a real (fake-transport) send"
            Assert-True ($exitCode -eq 0 -and $lines.Count -eq 1 -and $parsed -and $parsed.PSObject.Properties[$case.property]) "$($case.name) -Json non-deduped send emits exactly one parseable object on stdout"
            Assert-True ((Get-Content -LiteralPath $errPath -Raw) -match 'ROUTER_ALERT: ') "$($case.name) -Json chat line goes to stderr"
            if ($case.ContainsKey('messagePrefix')) {
                $deliveredMessage = Get-Content -LiteralPath (Join-Path $temp 'fake-delivered-message.txt') -Raw
                Assert-True ($exitCode -eq 0 -and $parsed.sent -and $deliveredMessage.StartsWith($case.messagePrefix)) 'key-only CLI delivers the readable router-wait message'
            }
        }
    } finally { $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorTransport }

    $before = $script:requests.Count
    $pick = Resolve-RouterModel -Category routine-coding -Lane claude -SkipModelCheck
    Assert-True ($pick.PSObject.Properties['alerts'] -and $script:requests.Count -eq $before) 'resolver SendAlerts off by default'

    # Guard: a test with no fake transport and a temp state folder must not reach real delivery.
    # PATH is emptied too, so even a broken guard cannot find az and send anything.
    $priorPath = $env:PATH; $priorLive = $env:DT_MODEL_ROUTER_LIVE_ALERT; $priorPytest = $env:PYTEST_CURRENT_TEST; $priorTransport2 = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
    try {
        $env:DT_MODEL_ROUTER_LIVE_ALERT = $null; $env:PYTEST_CURRENT_TEST = $null; $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $null
        Assert-True ((Get-RouterRealAlertBlockReason) -eq 'state folder is in the temp directory') 'guard blocks real delivery for a temp state folder'
        $guardError = ''
        $env:PATH = ''
        try { $null = Invoke-RouterAlertRequest -Request @{ kind = 'secret'; name = 'discord-bot-token' } } catch { $guardError = $_.Exception.Message }
        $env:PATH = $priorPath
        Assert-True ($guardError -like 'Real alert delivery blocked:*') 'real request refused before any transport runs'
        $env:PYTEST_CURRENT_TEST = 'x'; $env:DT_MODEL_ROUTER_STATE = 'D:\not-temp\state'
        Assert-True ((Get-RouterRealAlertBlockReason) -eq 'running under pytest') 'guard blocks real delivery under pytest'
        $env:PYTEST_CURRENT_TEST = $null
        Assert-True ($null -eq (Get-RouterRealAlertBlockReason)) 'guard allows the real state folder outside tests'
        $env:DT_MODEL_ROUTER_STATE = $temp; $env:DT_MODEL_ROUTER_LIVE_ALERT = '1'
        Assert-True ($null -eq (Get-RouterRealAlertBlockReason)) 'deliberate live self-test opts out of the guard'
    } finally {
        $env:PATH = $priorPath; $env:DT_MODEL_ROUTER_LIVE_ALERT = $priorLive; $env:PYTEST_CURRENT_TEST = $priorPytest
        $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorTransport2; $env:DT_MODEL_ROUTER_STATE = $temp
    }

    if ($env:DT_MODEL_ROUTER_LIVE_ALERT -eq '1') {
        $live = Send-RouterAlert -Key ('router-alert-selftest-' + (Get-Date -Format 'yyyyMMdd')) -Message 'Model router alert self-test: this is the one test message from the build. No action needed.'
        Assert-True ($live.sent -and $live.channel -in @('discord','email')) 'LIVE: one real alert delivered'
    } else { Write-Output 'SKIPPED: LIVE alert (set DT_MODEL_ROUTER_LIVE_ALERT=1)' }
    Write-Output "SUMMARY: $script:passed passed"
} finally {
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = $priorClaudeCredentials
    $env:DT_MODEL_ROUTER_STATE = $priorState
    Remove-Item -LiteralPath $temp -Recurse -Force
}
