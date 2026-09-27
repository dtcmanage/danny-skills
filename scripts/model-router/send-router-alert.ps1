param([string]$Key, [string]$Message, [ValidateSet('info','warn')][string]$Severity = 'warn', [switch]$Json)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot '../security/redact-secrets.ps1')

function Invoke-RouterAlertTransport {
    param([object]$Request)
    if ($Request.kind -eq 'secret') {
        $value = & az keyvault secret show --vault-name tcm-secrets --name $Request.name --query value -o tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $value) { throw 'Secret lookup failed' }
        return [string]$value
    }
    return Invoke-RestMethod -Uri $Request.uri -Method $Request.method -Headers $Request.headers -Body $Request.body -ContentType 'application/json' -TimeoutSec 15
}

function Invoke-RouterAlertRequest {
    param([scriptblock]$Transport, [object]$Request)
    if ($Transport) { return & $Transport $Request }
    return Invoke-RouterAlertTransport -Request $Request
}

function Write-RouterAlertLog {
    param([string]$Path, [object]$Record)
    $json = ConvertTo-Json -InputObject $Record -Compress -Depth 8
    $safe = Invoke-SecretRedaction -Text $json
    [System.IO.File]::AppendAllText($Path, $safe + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Send-RouterAlert {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('info','warn')][string]$Severity = 'warn',
        [scriptblock]$Transport
    )
    $status = [ordered]@{ key = $Key; sent = $false; channel = 'none'; deduped = $false; error = $null }
    try {
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
            $token = [string](Invoke-RouterAlertRequest -Transport $Transport -Request @{ kind = 'secret'; name = 'discord-bot-token' })
            if (-not $token) { throw 'Missing Discord token' }
            $headers = @{ Authorization = "Bot $token"; 'User-Agent' = 'DiscordBot (https://github.com/dtcmanage/danny-skills, 1)' }
            $configPath = Join-Path $state 'alert-config.json'
            $owner = $null
            if (Test-Path -LiteralPath $configPath) {
                try { $owner = [string]((Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).owner_id) } catch { $owner = $null }
            }
            if (-not $owner) {
                $guild = Invoke-RouterAlertRequest -Transport $Transport -Request @{ kind = 'http'; method = 'GET'; uri = 'https://discord.com/api/v10/guilds/1014307672339779674'; headers = $headers; body = $null }
                $owner = [string]$guild.owner_id
                if (-not $owner) { throw 'Guild owner unavailable' }
                [System.IO.File]::WriteAllText($configPath, (ConvertTo-Json -InputObject @{ owner_id = $owner } -Compress), [Text.UTF8Encoding]::new($false))
            }
            $dm = Invoke-RouterAlertRequest -Transport $Transport -Request @{ kind = 'http'; method = 'POST'; uri = 'https://discord.com/api/v10/users/@me/channels'; headers = $headers; body = (ConvertTo-Json -InputObject @{ recipient_id = $owner } -Compress) }
            if (-not $dm.id) { throw 'DM channel unavailable' }
            $posted = Invoke-RouterAlertRequest -Transport $Transport -Request @{ kind = 'http'; method = 'POST'; uri = "https://discord.com/api/v10/channels/$($dm.id)/messages"; headers = $headers; body = (ConvertTo-Json -InputObject @{ content = $Message } -Compress) }
            if (-not $posted.id) { throw 'DM delivery unconfirmed' }
            $status.sent = $true; $status.channel = 'discord'
        } catch { $discordError = 'Discord delivery failed' }
        if (-not $status.sent) {
            try {
                $apiKey = [string](Invoke-RouterAlertRequest -Transport $Transport -Request @{ kind = 'secret'; name = 'personal-finance-resend-api-key' })
                if (-not $apiKey) { throw 'Missing Resend key' }
                $digest = [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Key))
                $idempotency = 'model-router-' + [Convert]::ToHexString($digest).ToLowerInvariant()
                $headers = @{ Authorization = "Bearer $apiKey"; 'Idempotency-Key' = $idempotency }
                $body = ConvertTo-Json -InputObject @{ from = 'finance@notification.thaicapital.com'; to = @('danny@thaicapital.com'); subject = "Model router alert: $Key"; text = $Message } -Compress
                $mail = Invoke-RouterAlertRequest -Transport $Transport -Request @{ kind = 'http'; method = 'POST'; uri = 'https://api.resend.com/emails'; headers = $headers; body = $body }
                if (-not $mail.id) { throw 'Email delivery unconfirmed' }
                $status.sent = $true; $status.channel = 'email'
            } catch { $status.error = "$discordError; email delivery failed" }
        }
        $event = if ($status.sent) { 'delivered' } else { 'delivery_failed' }
        Write-RouterAlertLog -Path $log -Record @{ event = $event; key = $Key; channel = $status.channel; severity = $Severity; message = $Message; at = (Get-Date).ToString('o') }
    } catch {
        $status.sent = $false; $status.channel = 'none'; $status.error = 'Alert delivery failed'
        try {
            $state = Get-RouterStateDir
            [System.IO.Directory]::CreateDirectory($state) | Out-Null
            Write-RouterAlertLog -Path (Join-Path $state 'alert-log.jsonl') -Record @{ event = 'delivery_failed'; key = $Key; channel = 'none'; severity = $Severity; message = $Message; at = (Get-Date).ToString('o') }
        } catch { }
    }
    return [pscustomobject]$status
}

function Send-RouterAlerts {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Alerts)
    foreach ($alert in $Alerts) {
        if ($alert -is [string]) { Send-RouterAlert -Key $alert -Message $alert }
        else { Send-RouterAlert -Key ([string]$alert.key) -Message ([string]$alert.message) }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Send-RouterAlert -Key $Key -Message $Message -Severity $Severity
    if ($Json) { $result | ConvertTo-Json -Compress } else { $result }
}
