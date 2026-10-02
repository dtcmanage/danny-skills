Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'router-platform.ps1')

function Get-RouterClaudeCredentialLocator {
    param([string]$Platform = (Get-RouterPlatform), [string]$UserHome = $HOME)
    $explicit = [bool]$env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS
    $custom = [bool]$env:CLAUDE_CONFIG_DIR
    $file = if ($explicit) { $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS }
        elseif ($custom) { Join-Path $env:CLAUDE_CONFIG_DIR '.credentials.json' }
        else { Join-Path $UserHome '.claude/.credentials.json' }
    $service = $env:DT_MODEL_ROUTER_CLAUDE_KEYCHAIN_SERVICE
    $native = if ($Platform -ne 'MacOS') { 'UNVERIFIED' }
        elseif ($explicit) { 'explicit-file-only' }
        elseif ($service) { 'configured-exact-service' }
        elseif ($custom) { 'unsupported-custom-config' }
        else { 'UNVERIFIED-service' }
    [pscustomobject]@{ file=[IO.Path]::GetFullPath($file); file_source=$(if ($explicit) { 'explicit' } elseif ($custom) { 'custom-config' } else { 'default-config' });
        keychain_service=$service; keychain_status=$native; file_present=(Test-Path -LiteralPath $file -PathType Leaf) }
}

function Get-RouterClaudeCredentialIdentity {
    # Bind quota caches to configuration, never token bytes or credential contents.
    $locator = Get-RouterClaudeCredentialLocator
    $identity = @((Get-RouterPlatform),$locator.file_source,$locator.file,
        $(if ($locator.file_source -ne 'explicit') { $locator.keychain_service } else { '' })) | ConvertTo-Json -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
}

function ConvertTo-RouterOAuthSource {
    param([string]$Text)
    try {
        $data = $Text | ConvertFrom-Json -ErrorAction Stop
        $oauth = $data.claudeAiOauth
        if ([string]::IsNullOrWhiteSpace([string]$oauth.accessToken)) { throw 'invalid' }
        if ([datetimeoffset]::FromUnixTimeMilliseconds([long]$oauth.expiresAt) -le [datetimeoffset]::UtcNow) {
            return [pscustomobject]@{ status='expired'; token=$null }
        }
        return [pscustomobject]@{ status='available'; token=[string]$oauth.accessToken }
    } catch { return [pscustomobject]@{ status='invalid'; token=$null } }
}

# The service override is an operator-verified exact account locator; no guessed default.
# Explicit file configuration is exclusive. Custom config never falls back to the default account.
function Get-RouterClaudeCredential {
    param([string]$Platform = (Get-RouterPlatform), [string]$UserHome = $HOME,
        [scriptblock]$Process = { param($File,$Arguments,$Timeout) Invoke-RouterBoundedProcess -FilePath $File -Arguments $Arguments -TimeoutMs $Timeout })
    $locator = Get-RouterClaudeCredentialLocator -Platform $Platform -UserHome $UserHome
    $file = [pscustomobject]@{ status='missing'; token=$null }
    if ($locator.file_present) {
        try { $file = ConvertTo-RouterOAuthSource -Text ([IO.File]::ReadAllText($locator.file)) }
        catch { $file = [pscustomobject]@{ status='unavailable'; token=$null } }
    }
    $native = [pscustomobject]@{ status=$locator.keychain_status; token=$null }
    if ($Platform -eq 'MacOS' -and $locator.file_source -ne 'explicit' -and $locator.keychain_service) {
        try {
            $result = & $Process '/usr/bin/security' @('find-generic-password','-s',$locator.keychain_service,'-w') 5000
            if ($result.status -eq 'completed' -and $result.exit_code -eq 0) { $native = ConvertTo-RouterOAuthSource -Text $result.output }
            else { $native = [pscustomobject]@{ status='unavailable'; token=$null } }
        } catch { $native = [pscustomobject]@{ status='unavailable'; token=$null } }
    }
    $status = $file.status; $source = 'file'; $token = $file.token
    if ($file.status -eq 'available' -and $native.status -eq 'available' -and $file.token -cne $native.token) {
        $status='source-disagreement'; $source='none'; $token=$null
    } elseif ($file.status -ne 'available' -and $native.status -eq 'available') {
        $status='available'; $source='keychain'; $token=$native.token
    } elseif ($file.status -ne 'available') {
        $source='none'
        # Preserve a verified native expiry so the quota reader can retain a
        # same-locator observed ceiling until reset, without using an old token.
        if ($file.status -eq 'missing' -and $native.status -eq 'expired') { $status='expired' }
    }
    [pscustomobject]@{ status=$status; source=$source; file_status=$file.status; keychain_status=$native.status; token=$token }
}
