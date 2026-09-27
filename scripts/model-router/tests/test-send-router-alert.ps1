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
try {
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
        if ($request.uri -like '*/guilds/*') { return [pscustomobject]@{ owner_id = '123456789' } }
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
    Assert-True (@($script:requests | Where-Object { $_.kind -eq 'http' -and $_.uri -like '*/guilds/*' }).Count -eq 1) 'owner ID cached after first lookup'
    Assert-True (@($script:requests | Where-Object { $_.kind -eq 'http' -and $_.uri -like 'https://discord.com/*' -and $_.headers['User-Agent'] -eq 'DiscordBot (https://github.com/dtcmanage/danny-skills, 1)' }).Count -eq 5) 'Discord requests carry User-Agent'
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

    $before = $script:requests.Count
    $pick = Resolve-RouterModel -Category routine-coding -Lane claude -SkipModelCheck
    Assert-True ($pick.PSObject.Properties['alerts'] -and $script:requests.Count -eq $before) 'resolver SendAlerts off by default'

    if ($env:DT_MODEL_ROUTER_LIVE_ALERT -eq '1') {
        $live = Send-RouterAlert -Key ('router-alert-selftest-' + (Get-Date -Format 'yyyyMMdd')) -Message 'Model router alert self-test: this is the one test message from the build. No action needed.'
        Assert-True ($live.sent -and $live.channel -in @('discord','email')) 'LIVE: one real alert delivered'
    } else { Write-Output 'SKIPPED: LIVE alert (set DT_MODEL_ROUTER_LIVE_ALERT=1)' }
    Write-Output "SUMMARY: $script:passed passed"
} finally {
    $env:DT_MODEL_ROUTER_STATE = $priorState
    Remove-Item -LiteralPath $temp -Recurse -Force
}
