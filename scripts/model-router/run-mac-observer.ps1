Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vendor-limits.ps1')

function Invoke-RouterMacObserver {
    param([scriptblock]$CredentialProvider = { & $script:RouterClaudeCredentialProvider },
        [scriptblock]$ClaudeReader = { Get-RouterClaudeUsage }, [scriptblock]$CodexReader = { Get-RouterCodexUsage })
    if ((Get-RouterPlatform) -ne 'MacOS') { throw 'ROUTER_OBSERVER_MAC_ONLY' }
    $roster = Read-RouterRoster
    $credential = & $CredentialProvider
    $claude = & $ClaudeReader
    $codex = & $CodexReader
    # Only allowlisted statuses reach the receipt; reader objects may contain private fields.
    $receipt = [pscustomobject]@{
        observed_at_utc=[datetimeoffset]::UtcNow.ToString('o'); machine_role='local-observer'
        roster_source=$roster.source; roster_available=($roster.source -eq 'shared'); roster_valid=($null -eq $roster.validation_error)
        credential=[pscustomobject]@{ status=$credential.status; source=$credential.source; file_status=$credential.file_status; keychain_status=$credential.keychain_status }
        claude_usage_available=($null -ne $claude); codex_usage_available=($null -ne $codex)
    }
    Write-RouterJsonAtomic -Path (Join-Path (Get-RouterStateDir) 'mac-observer-receipt.json') -Value $receipt
    return $receipt
}
if ($MyInvocation.InvocationName -ne '.') { Invoke-RouterMacObserver | ConvertTo-Json -Depth 4 }
