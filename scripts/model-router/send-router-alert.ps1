param([Alias('Acknowledge')][string]$RouterAlertCliAcknowledge, [Alias('Key')][string]$RouterAlertCliKey, [Alias('Message')][string]$RouterAlertCliMessage, [Alias('Severity')][ValidateSet('info','warn')][string]$RouterAlertCliSeverity = 'warn', [Alias('Json')][switch]$RouterAlertCliJson)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot '../security/redact-secrets.ps1')

function Invoke-RouterAlertTransport {
    param([object]$Request, [datetime]$Deadline = [datetime]::MaxValue)
    if ($Request.kind -eq 'secret') {
        if (-not (Get-Variable -Name RouterAlertSecretCache -Scope Script -ErrorAction SilentlyContinue) -or $null -eq $script:RouterAlertSecretCache) { $script:RouterAlertSecretCache = @{} }
        if ($script:RouterAlertSecretCache.ContainsKey($Request.name)) {
            $cached = $script:RouterAlertSecretCache[$Request.name]
            if ($null -eq $cached) { throw 'Secret lookup failed' }
            return $cached
        }
        $remaining = [Math]::Min(20000.0, [Math]::Floor(($Deadline - [datetime]::UtcNow).TotalMilliseconds))
        if ($remaining -le 0) { throw 'Alert batch deadline exceeded' }
        $script:RouterAlertSecretCache[$Request.name] = $null
        $az = (Get-Command az -ErrorAction Stop).Source
        $start = [System.Diagnostics.ProcessStartInfo]::new()
        if ($IsWindows -and $az -match '\.(cmd|bat)$') {
            $start.FileName = $env:ComSpec
            $start.Arguments = '/d /s /c ""' + $az + '" keyvault secret show --vault-name tcm-secrets --name ' + $Request.name + ' --query value -o tsv"'
        } else {
            $start.FileName = $az
            foreach ($argument in @('keyvault','secret','show','--vault-name','tcm-secrets','--name',[string]$Request.name,'--query','value','-o','tsv')) { $start.ArgumentList.Add($argument) }
        }
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.CreateNoWindow = $true
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $start
        try {
            if (-not $process.Start()) { throw 'Secret lookup failed' }
            $output = $process.StandardOutput.ReadToEndAsync()
            $errors = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit([int]$remaining)) {
                $process.Kill($true)
                throw 'Secret lookup timed out'
            }
            $value = $output.GetAwaiter().GetResult().Trim()
            $null = $errors.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0 -or -not $value) { throw 'Secret lookup failed' }
            $script:RouterAlertSecretCache[$Request.name] = $value
            return $value
        } finally { $process.Dispose() }
    }
    $remaining = [Math]::Min(15.0, [Math]::Ceiling(($Deadline - [datetime]::UtcNow).TotalSeconds))
    if ($remaining -le 0) { throw 'Alert batch deadline exceeded' }
    return Invoke-RestMethod -Uri $Request.uri -Method $Request.method -Headers $Request.headers -Body $Request.body -ContentType 'application/json' -TimeoutSec ([int]$remaining)
}

function Invoke-RouterAlertRequest {
    param([scriptblock]$Transport, [object]$Request, [datetime]$Deadline = [datetime]::MaxValue)
    if ([datetime]::UtcNow -ge $Deadline) { throw 'Alert batch deadline exceeded' }
    if ($Transport) { return & $Transport $Request }
    # Test seam for child processes that cannot receive a scriptblock: a script path that acts as the transport.
    if ($env:DT_MODEL_ROUTER_ALERT_TRANSPORT) {
        # One stderr marker per process so a leaked test transport is visible. AppDomain data
        # survives the file being dot-sourced again in the same process.
        if (-not [AppDomain]::CurrentDomain.GetData('DtModelRouterTestTransportNoticed')) {
            [AppDomain]::CurrentDomain.SetData('DtModelRouterTestTransportNoticed', $true)
            [Console]::Error.WriteLine('ROUTER_ALERT_TEST_TRANSPORT_ACTIVE')
        }
        return & $env:DT_MODEL_ROUTER_ALERT_TRANSPORT $Request
    }
    $blocked = Get-RouterRealAlertBlockReason
    if ($blocked) { throw "Real alert delivery blocked: $blocked" }
    return Invoke-RouterAlertTransport -Request $Request -Deadline $Deadline
}

# Tests that forget a fake transport must never reach Danny's real Discord or email. Real delivery
# is refused under pytest or when the state folder lives in the temp directory, unless the one
# deliberate live self-test opts in with DT_MODEL_ROUTER_LIVE_ALERT=1.
function Get-RouterRealAlertBlockReason {
    if ($env:DT_MODEL_ROUTER_LIVE_ALERT -eq '1') { return $null }
    if ($env:PYTEST_CURRENT_TEST) { return 'running under pytest' }
    if ($env:DT_MODEL_ROUTER_STATE) {
        $state = [IO.Path]::GetFullPath($env:DT_MODEL_ROUTER_STATE).TrimEnd('\', '/')
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
        if ($state -ieq $temp -or $state.StartsWith($temp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            return 'state folder is in the temp directory'
        }
    }
    return $null
}

function Write-RouterAlertLog {
    param([string]$Path, [object]$Record)
    $json = ConvertTo-Json -InputObject $Record -Compress -Depth 8
    $safe = Invoke-SecretRedaction -Text $json
    [System.IO.File]::AppendAllText($Path, $safe + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Write-RouterAlertLogWithRetry {
    param([string]$Path, [object]$Record)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { Write-RouterAlertLog -Path $Path -Record $Record; return }
        catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
}

# Acknowledgement uses the delivery mutex so concurrent log appends stay serialized.
function Acknowledge-RouterAlert {
    param([Parameter(Mandatory)][string]$Key)
    $mutex = [System.Threading.Mutex]::new($false, 'Local\DtModelRouterAlert')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(5000) }
        catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Alert log is busy' }
        $state = Get-RouterStateDir
        [IO.Directory]::CreateDirectory($state) | Out-Null
        Write-RouterAlertLogWithRetry -Path (Join-Path $state 'alert-log.jsonl') -Record @{ event='acknowledged'; key=$Key; at=(Get-Date).ToString('o') }
        return [pscustomobject]@{ key=$Key; acknowledged=$true }
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-RouterAlertMessage {
    param(
        [string]$Key, [string]$Model, [string]$Category,
        [string]$ErrorText, [object]$Checks, [string]$ArtifactPath,
        [string]$PromptText, [string]$InvocationText, [switch]$ErrorEchoesInput
    )
    switch -Regex -CaseSensitive ($Key) {
        '^router-wait: (.+)$' { return "Model router: every eligible vendor is at its limit. $($Matches[1])." }
        '^router-roster-missing$' { return 'Model router roster is missing; it is using the default roster.' }
        '^router-roster-invalid: (.+)$' { return "Model router roster is invalid ($($Matches[1])); it is using the default roster." }
        '^router-picks-changed-needs-approval$' { return 'Model router research changed its picks; review and approve before they take effect.' }
        '^new-model:(.+)$' { return "Model router found a new model: $($Matches[1]). Research is needed before it can be selected." }
        '^model-missing:(.+)$' { return "Model router can no longer find model $($Matches[1]) in the vendor catalog." }
        '^catalog-check-timeout$' { return 'Model router catalog check timed out; it will retry later.' }
        '^catalog-check-error:(.+)$' { return "Model router catalog check failed for $($Matches[1]); it will retry later." }
        '^research-failure:([^:]+):(\d{4}-\d{2}-\d{2})$' { return "Research: the $($Matches[1]) check has failed since $($Matches[2]) ET. See the research failure record for details." }
        '^router-offline:(\d{4}-\d{2}-\d{2} \d{2}:\d{2} ET)$' { return "Model router connectivity has returned after an outage starting $($Matches[1])." }
        '^vendor-error:(codex|claude):([^:]+)(?::([^:]+))?$' {
            $vendor = $Matches[1]
            if (-not $Model -and $Matches.ContainsKey(3)) { $Model = $Matches[3] }
            $echoed = [bool]$ErrorEchoesInput
            # Compare raw and JSON-unescaped forms of both sides (whitespace collapsed, case-folded), so an
            # escaped echo matches a raw prompt and a prompt holding backslash sequences still matches its raw echo.
            $variants = {
                param([string]$Text)
                if (-not $Text) { return @() }
                $decoded = [regex]::Replace($Text, '\\u[0-9a-fA-F]{4}|\\["\\/bfnrt]', {
                    param($match)
                    return ConvertFrom-Json ('"' + $match.Value + '"')
                })
                @($Text, $decoded) | ForEach-Object { ([regex]::Replace($_, '\s+', ' ')).ToUpperInvariant() } | Select-Object -Unique
            }
            $errorForms = @(& $variants $ErrorText)
            foreach ($inputText in @(& $variants $PromptText) + @(& $variants $InvocationText)) {
                foreach ($errorForm in $errorForms) {
                    if ($echoed) { break }
                    if ($errorForm.Contains($inputText)) { $echoed = $true; break }
                    for ($offset = 0; -not $echoed -and $offset -le $inputText.Length - 24; $offset++) {
                        if ($errorForm.Contains($inputText.Substring($offset, 24))) { $echoed = $true }
                    }
                }
            }
            # Inspect the whole error: invocation/prompt echoes can appear after the first line.
            $echoed = $echoed -or $ErrorText -match '(?im)(\bprompt\b|\binvocation\b|\bcodex(?:\.exe)?\s+exec\b|\bclaude(?:\.exe)?\s+.*(?:-p\b|--print\b)|--prompt\b)'
            $description = 'The vendor call failed again after one immediate retry. Error text omitted because it may contain prompt or invocation text.'
            $firstLine = @($ErrorText -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
            if (-not $echoed -and $firstLine.Count) {
                $description = Invoke-SecretRedaction -Text $firstLine[0]
                if ($description.Length -gt 300) { $description = $description.Substring(0, 300) }
            } elseif (-not $echoed) { $description = 'The vendor call failed again after one immediate retry.' }
            $checkText = if ($null -ne $Checks) { Invoke-SecretRedaction -Text (ConvertTo-Json -InputObject $Checks -Compress -Depth 8) } else { 'connectivity: unavailable; vendor status: unavailable' }
            $pathText = if ($ArtifactPath) { Invoke-SecretRedaction -Text $ArtifactPath } else { 'unavailable' }
            $safeModel = if ([string]::IsNullOrWhiteSpace($Model)) { 'unknown' } else { Invoke-SecretRedaction -Text $Model }
            $safeCategory = if ([string]::IsNullOrWhiteSpace($Category)) { 'unknown' } else { Invoke-SecretRedaction -Text $Category }
            $safeKey = (Invoke-SecretRedaction -Text $Key).Replace("'", "''")
            $ackPath = (Join-Path $PSScriptRoot 'send-router-alert.ps1').Replace("'", "''")
            return "Work stopped on $vendor (model: $safeModel; category: $safeCategory). Error: $description`nChecks (connectivity and vendor status): $checkText`nRecord: $pathText`nAcknowledge: pwsh -NoProfile -File '$ackPath' -Acknowledge '$safeKey'"
        }
        '^drift:'  { return "Model router detected table drift: $Key" }
        '^fallback_unselectable' { return "Model router fallback cannot be selected: $Key" }
        '^UNSELECTABLE_CODEX_MODEL:\s*(.+)$' { return "Model $($Matches[1]) is not selectable in the Codex catalog; the router used the next option." }
        default { return $Key }
    }
}

function Send-RouterAlert {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('info','warn')][string]$Severity = 'warn',
        [scriptblock]$Transport,
        [datetime]$Deadline = [datetime]::MaxValue,
        # Script -Json modes keep stdout to one JSON object, so the chat line goes to stderr.
        [switch]$ChatToStderr
    )
    $status = [ordered]@{ key = $Key; sent = $false; channel = 'none'; deduped = $false; error = $null; log_error = $null }
    $mutex = [System.Threading.Mutex]::new($false, 'Local\DtModelRouterAlert')
    $owned = $false
    try {
        $waitMs = [Math]::Min(5000.0, [Math]::Max(0.0, [Math]::Floor(($Deadline - [datetime]::UtcNow).TotalMilliseconds)))
        try { $owned = $mutex.WaitOne([int]$waitMs) }
        catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { $status.error = 'busy'; return [pscustomobject]$status }
        if ([datetime]::UtcNow -ge $Deadline) { $status.error = 'busy'; return [pscustomobject]$status }
        $state = Get-RouterStateDir
        [System.IO.Directory]::CreateDirectory($state) | Out-Null
        $log = Join-Path $state 'alert-log.jsonl'
        if (Test-Path -LiteralPath $log) {
            foreach ($line in @(Get-Content -LiteralPath $log)) {
                try {
                    $row = $line | ConvertFrom-Json
                    if ($row.key -ceq $Key -and $row.event -eq 'delivered') {
                        $status.sent = $true; $status.channel = [string]$row.channel; $status.deduped = $true
                        return [pscustomobject]$status
                    }
                } catch { }
            }
        }
        if ($ChatToStderr) { [Console]::Error.WriteLine("ROUTER_ALERT: $Message") } else { Write-Host "ROUTER_ALERT: $Message" }
        $discordError = $null
        try {
            $token = [string](Invoke-RouterAlertRequest -Transport $Transport -Deadline $Deadline -Request @{ kind = 'secret'; name = 'discord-bot-token' })
            if (-not $token) { throw 'Missing Discord token' }
            $headers = @{ Authorization = "Bot $token"; 'User-Agent' = 'DiscordBot (https://github.com/dtcmanage/danny-skills, 1)' }
            $configPath = Join-Path $state 'alert-config.json'
            $owner = $null
            if (Test-Path -LiteralPath $configPath) {
                try { $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json; if ($cfg.recipient_source -eq 'application-owner') { $owner = [string]$cfg.owner_id } } catch { $owner = $null }
            }
            if (-not $owner) {
                # Danny owns the bot application; the guild owner is a different person, so never DM the guild owner.
                $app = Invoke-RouterAlertRequest -Transport $Transport -Deadline $Deadline -Request @{ kind = 'http'; method = 'GET'; uri = 'https://discord.com/api/v10/oauth2/applications/@me'; headers = $headers; body = $null }
                $owner = if ($app.PSObject.Properties['team'] -and $app.team) { [string]$app.team.owner_user_id } elseif ($app.PSObject.Properties['owner'] -and $app.owner) { [string]$app.owner.id } else { $null }
                if (-not $owner) { throw 'Bot application owner unavailable' }
                [System.IO.File]::WriteAllText($configPath, (ConvertTo-Json -InputObject @{ owner_id = $owner; recipient_source = 'application-owner' } -Compress), [Text.UTF8Encoding]::new($false))
            }
            $dm = Invoke-RouterAlertRequest -Transport $Transport -Deadline $Deadline -Request @{ kind = 'http'; method = 'POST'; uri = 'https://discord.com/api/v10/users/@me/channels'; headers = $headers; body = (ConvertTo-Json -InputObject @{ recipient_id = $owner } -Compress) }
            if (-not $dm.id) { throw 'DM channel unavailable' }
            $discordMessage = if ($Message.Length -gt 1900) { $Message.Substring(0, 1900) } else { $Message }
            $posted = Invoke-RouterAlertRequest -Transport $Transport -Deadline $Deadline -Request @{ kind = 'http'; method = 'POST'; uri = "https://discord.com/api/v10/channels/$($dm.id)/messages"; headers = $headers; body = (ConvertTo-Json -InputObject @{ content = $discordMessage; allowed_mentions = @{ parse = @() } } -Compress -Depth 5) }
            if (-not $posted.id) { throw 'DM delivery unconfirmed' }
            $status.sent = $true; $status.channel = 'discord'
        } catch { $discordError = 'Discord delivery failed' }
        if (-not $status.sent) {
            try {
                $apiKey = [string](Invoke-RouterAlertRequest -Transport $Transport -Deadline $Deadline -Request @{ kind = 'secret'; name = 'personal-finance-resend-api-key' })
                if (-not $apiKey) { throw 'Missing Resend key' }
                $digest = [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Key))
                $idempotency = 'model-router-' + [Convert]::ToHexString($digest).ToLowerInvariant()
                $headers = @{ Authorization = "Bearer $apiKey"; 'Idempotency-Key' = $idempotency }
                $body = ConvertTo-Json -InputObject @{ from = 'finance@notification.thaicapital.com'; to = @('danny@thaicapital.com'); subject = "Model router alert: $Key"; text = $Message } -Compress
                $mail = Invoke-RouterAlertRequest -Transport $Transport -Deadline $Deadline -Request @{ kind = 'http'; method = 'POST'; uri = 'https://api.resend.com/emails'; headers = $headers; body = $body }
                if (-not $mail.id) { throw 'Email delivery unconfirmed' }
                $status.sent = $true; $status.channel = 'email'
            } catch { $status.error = "$discordError; email delivery failed" }
        }
        $event = if ($status.sent) { 'delivered' } else { 'delivery_failed' }
        try { Write-RouterAlertLogWithRetry -Path $log -Record @{ event = $event; key = $Key; channel = $status.channel; severity = $Severity; message = $Message; at = (Get-Date).ToString('o') } }
        catch { $status.log_error = 'Alert log write failed' }
    } catch {
        $status.sent = $false; $status.channel = 'none'; $status.error = 'Alert delivery failed'
        try {
            $state = Get-RouterStateDir
            [System.IO.Directory]::CreateDirectory($state) | Out-Null
            Write-RouterAlertLogWithRetry -Path (Join-Path $state 'alert-log.jsonl') -Record @{ event = 'delivery_failed'; key = $Key; channel = 'none'; severity = $Severity; message = $Message; at = (Get-Date).ToString('o') }
        } catch { }
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    return [pscustomobject]$status
}

function Send-RouterAlerts {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Alerts, [scriptblock]$Transport, [switch]$ChatToStderr)
    $deadline = [datetime]::UtcNow.AddSeconds(45)
    foreach ($alert in $Alerts) {
        $key = if ($alert -is [string]) { $alert } else { [string]$alert.key }
        $message = if ($alert -is [string]) { Get-RouterAlertMessage -Key $key } else { [string]$alert.message }
        if ([datetime]::UtcNow -ge $deadline) { [pscustomobject]@{ key = $key; sent = $false; channel = 'none'; deduped = $false; error = 'busy'; log_error = $null } }
        else { Send-RouterAlert -Key $key -Message $message -Severity $(if ($key -eq 'research-stale-lock-cleared' -or $key -like 'drift-cleared:*' -or $key -like 'canary-complete:*') { 'info' } else { 'warn' }) -Transport $Transport -Deadline $deadline -ChatToStderr:$ChatToStderr }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($RouterAlertCliAcknowledge) {
        $result = Acknowledge-RouterAlert -Key $RouterAlertCliAcknowledge
        if ($RouterAlertCliJson) { $result | ConvertTo-Json -Compress } else { $result }
        return
    }
    if ([string]::IsNullOrEmpty($RouterAlertCliMessage)) {
        $RouterAlertCliMessage = Get-RouterAlertMessage -Key $RouterAlertCliKey
        if ([string]::IsNullOrEmpty($RouterAlertCliMessage)) {
            [Console]::Error.WriteLine("No alert message found for key '$RouterAlertCliKey'.")
            exit 1
        }
    }
    $result = Send-RouterAlert -Key $RouterAlertCliKey -Message $RouterAlertCliMessage -Severity $RouterAlertCliSeverity -ChatToStderr:$RouterAlertCliJson
    if ($RouterAlertCliJson) { $result | ConvertTo-Json -Compress } else { $result }
}
