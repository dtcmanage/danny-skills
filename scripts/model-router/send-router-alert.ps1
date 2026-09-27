param([Alias('Key')][string]$RouterAlertCliKey, [Alias('Message')][string]$RouterAlertCliMessage, [Alias('Severity')][ValidateSet('info','warn')][string]$RouterAlertCliSeverity = 'warn', [Alias('Json')][switch]$RouterAlertCliJson)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot '../security/redact-secrets.ps1')

function Invoke-RouterAlertTransport {
    param([object]$Request, [datetime]$Deadline = [datetime]::MaxValue)
    if ($Request.kind -eq 'secret') {
        if (-not $script:RouterAlertSecretCache) { $script:RouterAlertSecretCache = @{} }
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
    return Invoke-RouterAlertTransport -Request $Request -Deadline $Deadline
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

function Get-RouterAlertMessage {
    param([string]$Key)
    switch -Regex -CaseSensitive ($Key) {
        '^router-seed-table-in-use$' { return "Model router is using its starter table; picks use each lane's default model until the research step builds a real table." }
        '^new-model:(.+)$' { return "Model router found a new model: $($Matches[1]). Research is needed before it can be selected." }
        '^model-missing:(.+)$' { return "Model router can no longer find model $($Matches[1]) in the vendor catalog." }
        '^catalog-check-timeout$' { return 'Model router catalog check timed out; it will retry later.' }
        '^catalog-check-error:(.+)$' { return "Model router catalog check failed for $($Matches[1]); it will retry later." }
        '^no-eligible:([^:]+):([^:]+)$' { return "Model router found no eligible model for $($Matches[1]) on the $($Matches[2]) lane; it is using the fallback." }
        '^drift:' { return "Model router detected table drift: $Key" }
        '^router-live-table-invalid' { return 'Model router live table is invalid; it is using the starter table.' }
        '^fallback_unselectable' { return "Model router fallback cannot be selected: $Key" }
        default { return $Key }
    }
}

function Send-RouterAlert {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('info','warn')][string]$Severity = 'warn',
        [scriptblock]$Transport,
        [datetime]$Deadline = [datetime]::MaxValue
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
        Write-Host "ROUTER_ALERT: $Message"
        $discordError = $null
        try {
            $token = [string](Invoke-RouterAlertRequest -Transport $Transport -Deadline $Deadline -Request @{ kind = 'secret'; name = 'discord-bot-token' })
            if (-not $token) { throw 'Missing Discord token' }
            $headers = @{ Authorization = "Bot $token"; 'User-Agent' = 'DiscordBot (https://github.com/dtcmanage/danny-skills, 1)' }
            $configPath = Join-Path $state 'alert-config.json'
            $owner = $null
            if (Test-Path -LiteralPath $configPath) {
                try { $owner = [string]((Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).owner_id) } catch { $owner = $null }
            }
            if (-not $owner) {
                $guild = Invoke-RouterAlertRequest -Transport $Transport -Deadline $Deadline -Request @{ kind = 'http'; method = 'GET'; uri = 'https://discord.com/api/v10/guilds/1014307672339779674'; headers = $headers; body = $null }
                $owner = [string]$guild.owner_id
                if (-not $owner) { throw 'Guild owner unavailable' }
                [System.IO.File]::WriteAllText($configPath, (ConvertTo-Json -InputObject @{ owner_id = $owner } -Compress), [Text.UTF8Encoding]::new($false))
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
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Alerts, [scriptblock]$Transport)
    $deadline = [datetime]::UtcNow.AddSeconds(45)
    foreach ($alert in $Alerts) {
        $key = if ($alert -is [string]) { $alert } else { [string]$alert.key }
        $message = if ($alert -is [string]) { Get-RouterAlertMessage -Key $key } else { [string]$alert.message }
        if ([datetime]::UtcNow -ge $deadline) { [pscustomobject]@{ key = $key; sent = $false; channel = 'none'; deduped = $false; error = 'busy'; log_error = $null } }
        else { Send-RouterAlert -Key $key -Message $message -Transport $Transport -Deadline $deadline }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Send-RouterAlert -Key $RouterAlertCliKey -Message $RouterAlertCliMessage -Severity $RouterAlertCliSeverity
    if ($RouterAlertCliJson) { $result | ConvertTo-Json -Compress } else { $result }
}
