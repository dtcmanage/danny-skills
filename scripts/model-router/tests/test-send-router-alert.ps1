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
    $script:failPage = 0
    $script:pagePosts = 0
    $script:inspectKey = ''
    $script:earlyDelivery = $false
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
            if ($script:inspectKey) {
                $existing = @(Get-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'alert-log.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
                if (@($existing | Where-Object { $_.key -ceq $script:inspectKey -and $_.event -eq 'delivered' }).Count) { $script:earlyDelivery = $true }
            }
            $script:pagePosts++
            if ($script:failPage -eq $script:pagePosts) { return [pscustomobject]@{ id = $null } }
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

    $checks = @{ http=$true; dns=$true; status='operational' }
    $vendorKey = 'vendor-error:codex:dispatch-42'
    $vendorMessage = Get-RouterAlertMessage -Key $vendorKey -Model 'gpt-test' -Category 'routine-coding' -ErrorText "Rejected ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA`nsecond line must stay private" -Checks $checks -ArtifactPath 'state/dispatch.provenance.json'
    Assert-True ($vendorMessage -match '\[REDACTED-SECRET\]' -and $vendorMessage -notmatch 'ghp_|second line' -and $vendorMessage -match 'gpt-test.*routine-coding' -and $vendorMessage -match '"http":true' -and $vendorMessage -match '"dns":true' -and $vendorMessage -match '"status":"operational"' -and $vendorMessage -match 'dispatch.provenance.json') 'vendor template redacts first error line and includes model, category, checks and record'
    Assert-True ($vendorMessage.EndsWith("-Acknowledge '$vendorKey'")) 'vendor text ends with acknowledge command'
    $ackPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../send-router-alert.ps1')).Replace("'", "''")
    Assert-True ($vendorMessage.EndsWith("Acknowledge: pwsh -NoProfile -File '$ackPath' -Acknowledge '$vendorKey'")) 'acknowledge command quotes the absolute script path'
    $quotedKey = "vendor-error:codex:dispatch'42"
    Assert-True ((Get-RouterAlertMessage -Key $quotedKey).EndsWith("-Acknowledge 'vendor-error:codex:dispatch''42'")) 'acknowledge command doubles key quotes'
    $secretKey = 'vendor-error:codex:sk-ant-api03-Example_0123456789-ABC'
    $safeKeyMessage = Get-RouterAlertMessage -Key $secretKey
    Assert-True ($safeKeyMessage.EndsWith("-Acknowledge 'vendor-error:codex:[REDACTED-SECRET]'")) 'key text in acknowledge command is redacted'
    Assert-True ((Get-RouterAlertMessage -Key $vendorKey) -match 'model: unknown; category: unknown') 'missing model and category render unknown'
    $nonblank = Get-RouterAlertMessage -Key $vendorKey -ErrorText "`r`n  `r`nService failed`r`nlater details"
    Assert-True ($nonblank -match 'Error: Service failed' -and $nonblank -notmatch 'later details') 'first non-blank error line is used'
    foreach ($credential in @('sk-ant-api03-Example_0123456789-ABC','sk-proj-Example_0123456789-ABC','sk-0123456789abcdefghij','Bearer Example_0123456789-ABC')) {
        $safeError = Get-RouterAlertMessage -Key $vendorKey -ErrorText "Rejected $credential"
        Assert-True ($safeError.Contains('[REDACTED-SECRET]') -and -not $safeError.Contains($credential)) 'vendor error path redacts vendor credentials'
    }
    $longError = Get-RouterAlertMessage -Key $vendorKey -ErrorText ('x' * 299 + 'ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')
    $description = (($longError -split "`n")[0] -split 'Error: ',2)[1]
    Assert-True ($description.Length -eq 300 -and $description -eq ('x' * 299 + '[')) 'error is redacted before the 300 character cap'
    $prompt = 'private work instructions with customer data'
    foreach ($errorCase in @("Prompt: $prompt", "codex exec --model gpt-test '$prompt'", "Call failed`ninvocation: claude -p '$prompt'", $prompt)) {
        $echo = Get-RouterAlertMessage -Key $vendorKey -ErrorText $errorCase -PromptText $prompt
        Assert-True ($echo -match 'Error text omitted' -and $echo -notmatch [regex]::Escape($prompt) -and $echo -notmatch 'codex exec|claude -p') 'prompt and invocation echoes use generic description'
    }
    $echo = Get-RouterAlertMessage -Key $vendorKey -ErrorText 'execute private contents' -InvocationText 'execute private contents'
    Assert-True ($echo -match 'Error text omitted') 'known invocation echo uses generic description'
    $echo = Get-RouterAlertMessage -Key $vendorKey -ErrorText 'private partial echo' -ErrorEchoesInput
    Assert-True ($echo -match 'Error text omitted' -and $echo -notmatch 'private partial echo') 'caller can flag a partial prompt echo'
    $prompt = 'Private customer "records" require careful review of every entry before responding.'
    $partial = $prompt.Substring(0, 40)
    foreach ($errorCase in @("Rejected: $partial", ("Rejected: $partial").ToUpperInvariant(), ("Rejected: $partial" -replace ' ', "`n  "), ('Rejected: ' + (ConvertTo-Json -InputObject $partial -Compress)), ('Rejected: ' + ($partial.Replace(' ', '\n').Replace('"', '\"'))))) {
        $echo = Get-RouterAlertMessage -Key $vendorKey -ErrorText $errorCase -PromptText $prompt
        Assert-True ($echo -match 'Error text omitted' -and $echo -notmatch 'Private customer') 'partial reflowed and JSON-escaped input echoes use generic text'
    }
    $echo = Get-RouterAlertMessage -Key $vendorKey -ErrorText ('Rejected: ' + $prompt.Substring(15, 24)) -InvocationText $prompt
    Assert-True ($echo -match 'Error text omitted') 'any shared 24 character invocation run is suppressed'
    $short = Get-RouterAlertMessage -Key $vendorKey -ErrorText $prompt.Substring(15, 23) -PromptText $prompt
    Assert-True ($short -notmatch 'Error text omitted') '23 character partial match does not meet the echo threshold'
    $pathPrompt = 'D:\new\tmp\rpt\fin\bank\nov\a.txt'
    $pathEcho = Get-RouterAlertMessage -Key $vendorKey -ErrorText 'cannot open "D:\\new\\tmp\\rpt\\fin\\bank\\nov\\a.txt"' -PromptText $pathPrompt
    Assert-True ($pathEcho -match 'Error text omitted') 'JSON-escaped echo of a prompt holding backslash sequences is suppressed'
    $rawPathEcho = Get-RouterAlertMessage -Key $vendorKey -ErrorText ('cannot open ' + $pathPrompt) -PromptText $pathPrompt
    Assert-True ($rawPathEcho -match 'Error text omitted') 'raw echo of a prompt holding backslash sequences is suppressed'
    Assert-True ((Get-RouterAlertMessage -Key 'research-failure:planning:2026-09-30') -match 'planning.*2026-09-30 ET') 'research episode template carries first failure ET date'
    Assert-True ((Get-RouterAlertMessage -Key 'router-offline:2026-09-30 23:58 ET') -match 'connectivity has returned.*2026-09-30 23:58 ET') 'reconnect template carries outage start with ET minutes'
    Assert-True ((Get-RouterAlertMessage -Key 'vendor-error:claude:research-pass-42' -ArtifactPath 'research-failures/planning.json') -match 'stopped on claude' ) 'research vendor error template'
    Assert-True ((Get-RouterAlertMessage -Key 'vendor-error:codex:canary-run-42:gpt-test') -match 'model: gpt-test') 'canary template extracts model from per run key'
    $keys = @($vendorKey, 'vendor-error:codex:dispatch-43', 'vendor-error:claude:research-pass-42', 'vendor-error:codex:canary-run-42:gpt-test', 'vendor-error:codex:canary-run-42:gpt-other', 'research-failure:planning:2026-09-30', 'research-failure:planning:2026-10-01', 'router-offline:2026-09-30 23:58 ET', 'router-offline:2026-10-01 00:05 ET')
    foreach ($key in $keys) {
        $message = if ($key -eq $vendorKey) { $vendorMessage } else { Get-RouterAlertMessage -Key $key }
        $sent = @(Send-RouterAlert -Key $key -Message $message -Transport $fake 6>&1 | Where-Object { $_ -is [pscustomobject] })[-1]
        $requestCount = $script:requests.Count
        $repeated = Send-RouterAlert -Key $key -Message $message -Transport $fake
        Assert-True ($sent.sent -and -not $sent.deduped -and $repeated.deduped -and $script:requests.Count -eq $requestCount) "observability key delivers independently and dedupes: $key"
    }
    $requestCount = $script:requests.Count
    $ackLines = @(& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../send-router-alert.ps1') -Acknowledge $vendorKey -Json)
    $ackExit = $LASTEXITCODE
    $ack = $ackLines[0] | ConvertFrom-Json
    $events = @(Get-Content -LiteralPath (Join-Path $temp 'alert-log.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($ackExit -eq 0 -and $ackLines.Count -eq 1 -and $ack.acknowledged -and $ack.key -ceq $vendorKey -and @($events | Where-Object { $_.event -eq 'acknowledged' -and $_.key -ceq $vendorKey -and $_.at }).Count -eq 1 -and $script:requests.Count -eq $requestCount) 'acknowledge CLI appends timestamped event without delivery'
    $ackedSend = Send-RouterAlert -Key $vendorKey -Message $vendorMessage -Transport $fake
    Assert-True ($ackedSend.deduped -and $script:requests.Count -eq $requestCount) 'acknowledgement preserves delivered dedup'
    $null = Acknowledge-RouterAlert -Key 'ack-before-delivery'
    $afterAck = @(Send-RouterAlert -Key 'ack-before-delivery' -Message 'New alert' -Transport $fake 6>&1 | Where-Object { $_ -is [pscustomobject] })[-1]
    Assert-True ($afterAck.sent -and -not $afterAck.deduped) 'acknowledged event alone does not dedup delivery'
    $body = @($script:requests | Where-Object { $_.kind -eq 'http' -and $_.uri -like '*/channels/*/messages' -and $_.body -match 'dispatch.provenance.json' })[0].body
    Assert-True ($body -notmatch 'ghp_' -and $body -match 'REDACTED-SECRET' -and (Get-Content -LiteralPath (Join-Path $temp 'alert-log.jsonl') -Raw) -notmatch 'ghp_') 'vendor secret stays redacted in transport and persisted log'

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
    $script:requests.Clear()
    $longResult = @(Send-RouterAlert -Key 'long-message' -Message $longText -Transport $fake 6>&1 | Where-Object { $_ -is [pscustomobject] })[-1]
    $longBodies = @($script:requests | Where-Object { $_.kind -eq 'http' -and $_.uri -like '*/channels/*/messages' } | ForEach-Object { $_.body | ConvertFrom-Json })
    Assert-True ($longResult.sent -and $longBodies.Count -eq 2 -and ($longBodies.content -join '') -ceq $longText) 'oversized line is paginated without dropping content'
    Assert-True (@($longBodies | Where-Object { $_.content.Length -gt 1900 -or @($_.allowed_mentions.parse).Count -ne 0 }).Count -eq 0) 'every oversized-line page stays within limit with mentions disabled'
    $script:requests.Clear()
    $boundaryText = 'b' * 1900
    $boundaryResult = @(Send-RouterAlert -Key 'one-page-boundary' -Message $boundaryText -Transport $fake 6>&1 | Where-Object { $_ -is [pscustomobject] })[-1]
    $boundaryBodies = @($script:requests | Where-Object { $_.kind -eq 'http' -and $_.uri -like '*/channels/*/messages' } | ForEach-Object { $_.body | ConvertFrom-Json })
    Assert-True ($boundaryResult.sent -and $boundaryBodies.Count -eq 1 -and $boundaryBodies[0].content -ceq $boundaryText) '1900-character message preserves single-page behavior'

    $ackCommand = "Acknowledge: pwsh -NoProfile -File '$ackPath' -Acknowledge '$vendorKey'"
    $pagedText = (($vendorMessage + "`r`n") * 6) + ('z' * 1899) + [char]::ConvertFromUtf32(0x1F600) + ('y' * 2100) + "`r`n" + $ackCommand
    $script:requests.Clear(); $script:pagePosts = 0
    $script:inspectKey = 'weekly-report:paged'
    $pagedResult = Send-RouterAlert -Key 'weekly-report:paged' -Message $pagedText -Transport $fake -ChatToStderr
    $pages = @($script:requests | Where-Object { $_.kind -eq 'http' -and $_.uri -like '*/channels/*/messages' } | ForEach-Object { $_.body | ConvertFrom-Json })
    Assert-True ($pagedResult.sent -and $pagedResult.channel -eq 'discord' -and $pages.Count -gt 2 -and ($pages.content -join '') -ceq $pagedText) 'multi-page DM preserves complete redacted content and line endings'
    Assert-True (@($pages | Where-Object { $_.content.Length -gt 1900 -or $_.content.Length -eq 0 -or @($_.allowed_mentions.parse).Count -ne 0 }).Count -eq 0) 'all multi-page bodies fit the limit and disable mentions'
    $ackCount = ($pages | ForEach-Object { [regex]::Matches($_.content, [regex]::Escape($ackCommand)).Count } | Measure-Object -Sum).Sum
    Assert-True ($ackCount -eq 7) 'ordinary acknowledgement commands stay intact on pages'
    Assert-True (@($pages | Where-Object { [char]::IsHighSurrogate($_.content[$_.content.Length - 1]) -or [char]::IsLowSurrogate($_.content[0]) -or $_.content.EndsWith("`r") }).Count -eq 0) 'oversized lines keep Unicode pairs and CRLF boundaries intact'
    Assert-True (@($script:requests | Where-Object { $_.kind -eq 'http' -and $_.uri -like '*/users/@me/channels' }).Count -eq 1) 'all pages use one DM channel'
    $events = @(Get-Content -LiteralPath (Join-Path $temp 'alert-log.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($events | Where-Object { $_.key -ceq 'weekly-report:paged' -and $_.event -eq 'delivered' }).Count -eq 1) 'all pages produce one delivered logical key'
    Assert-True (-not $script:earlyDelivery) 'logical delivery is not recorded before all page POSTs finish'
    $script:inspectKey = ''
    $requestCount = $script:requests.Count
    $pagedAgain = Send-RouterAlert -Key 'weekly-report:paged' -Message $pagedText -Transport $fake
    Assert-True ($pagedAgain.deduped -and $script:requests.Count -eq $requestCount) 'multi-page logical key dedupes without page requests'

    $script:requests.Clear(); $script:pagePosts = 0; $script:failPage = 2; $script:failEmail = $false
    $partial = Send-RouterAlert -Key 'paged-fallback' -Message $pagedText -Transport $fake -ChatToStderr
    $email = @($script:requests | Where-Object { $_.kind -eq 'http' -and $_.uri -eq 'https://api.resend.com/emails' })[-1]
    Assert-True ($partial.sent -and $partial.channel -eq 'email' -and $script:pagePosts -eq 2 -and ($email.body | ConvertFrom-Json).text -ceq $pagedText) 'partial page failure stops Discord and falls back with the full message'
    $events = @(Get-Content -LiteralPath (Join-Path $temp 'alert-log.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    $fallbackEvents = @($events | Where-Object { $_.key -ceq 'paged-fallback' -and $_.event -eq 'delivered' })
    Assert-True ($fallbackEvents.Count -eq 1 -and $fallbackEvents[0].channel -eq 'email') 'partial Discord success is never logged as delivered'
    $requestCount = $script:requests.Count
    $partialAgain = Send-RouterAlert -Key 'paged-fallback' -Message $pagedText -Transport $fake
    Assert-True ($partialAgain.deduped -and $script:requests.Count -eq $requestCount) 'successful fallback dedupes the same logical key'

    $script:requests.Clear(); $script:pagePosts = 0; $script:failEmail = $true
    $partialFailed = Send-RouterAlert -Key 'paged-retry' -Message $pagedText -Transport $fake -ChatToStderr
    $events = @(Get-Content -LiteralPath (Join-Path $temp 'alert-log.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    $retryEvents = @($events | Where-Object { $_.key -ceq 'paged-retry' })
    Assert-True (-not $partialFailed.sent -and $retryEvents.Count -eq 1 -and $retryEvents[0].event -eq 'delivery_failed') 'partial Discord and email failure leaves the logical key undelivered'
    $script:requests.Clear(); $script:pagePosts = 0; $script:failPage = 0; $script:failEmail = $false
    $partialRetry = Send-RouterAlert -Key 'paged-retry' -Message $pagedText -Transport $fake -ChatToStderr
    $retryPages = @($script:requests | Where-Object { $_.kind -eq 'http' -and $_.uri -like '*/channels/*/messages' } | ForEach-Object { $_.body | ConvertFrom-Json })
    Assert-True ($partialRetry.sent -and -not $partialRetry.deduped -and ($retryPages.content -join '') -ceq $pagedText) 'failed logical key retries every page from the beginning'
    $events = @(Get-Content -LiteralPath (Join-Path $temp 'alert-log.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($events | Where-Object { $_.key -ceq 'paged-retry' -and $_.event -eq 'delivered' }).Count -eq 1) 'retry records exactly one delivered logical key'
    $requestCount = $script:requests.Count
    $retryAgain = Send-RouterAlert -Key 'paged-retry' -Message $pagedText -Transport $fake
    Assert-True ($retryAgain.deduped -and $script:requests.Count -eq $requestCount) 'successful retry dedupes all pages'
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
