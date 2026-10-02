param([switch]$Json)
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'router-credentials.ps1')

function Get-RouterStateInventory {
    param([string]$Platform = (Get-RouterPlatform), [string]$UserHome = $HOME,
        [scriptblock]$Process = { param($File,$Arguments) Invoke-RouterBoundedProcess -FilePath $File -Arguments $Arguments -TimeoutMs 5000 })
    $locator = Get-RouterClaudeCredentialLocator -Platform $Platform -UserHome $UserHome
    $sessions = if ($env:DT_MODEL_ROUTER_CODEX_SESSIONS) { $env:DT_MODEL_ROUTER_CODEX_SESSIONS }
        elseif ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME 'sessions' } else { Join-Path $UserHome '.codex/sessions' }
    $plist = Join-Path $UserHome 'Library/LaunchAgents/com.danny.model-router.observer.plist'
    $installation = 'UNVERIFIED'
    # Real native readback only; fixture platform selection never invokes native commands.
    if ($Platform -eq 'MacOS' -and [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        $uid = & $Process '/usr/bin/id' @('-u')
        if ($uid.status -eq 'completed' -and $uid.exit_code -eq 0 -and $uid.output.Trim() -match '^\d+$') {
            $readback = & $Process '/bin/launchctl' @('print',('gui/' + $uid.output.Trim() + '/com.danny.model-router.observer'))
            $installation = if ($readback.status -eq 'completed' -and $readback.exit_code -eq 0) { 'loaded' } else { 'unavailable-or-unloaded' }
        }
    }
    [pscustomobject]@{
        platform=$Platform; machine_role=$(if ($Platform -eq 'Windows') { 'roster-authority' } else { 'local-observer' })
        runtime_path=(Get-RouterStatePath -Platform $Platform -UserHome $UserHome)
        runtime_provenance=$(if ($env:DT_MODEL_ROUTER_STATE) { 'explicit' } else { 'platform-default' })
        shared_path=(Get-RouterSharedDir)
        shared_provenance=$(if ($env:DT_MODEL_ROUTER_SHARED) { 'explicit' } elseif ($env:DT_MODEL_ROUTER_STATE) { 'runtime-override' } else { 'main-checkout' })
        claude_credentials=$locator; codex_sessions_path=[IO.Path]::GetFullPath($sessions)
        cli_availability=[pscustomobject]@{ pwsh=[bool](Get-Command pwsh -ErrorAction SilentlyContinue); codex=[bool](Get-Command codex -ErrorAction SilentlyContinue); claude=[bool](Get-Command claude -ErrorAction SilentlyContinue) }
        plist_path=$plist; plist_present=(Test-Path -LiteralPath $plist -PathType Leaf)
        native_installation_status=$installation; native_credential_status='UNVERIFIED'
    }
}
if ($MyInvocation.InvocationName -ne '.') {
    $inventory = Get-RouterStateInventory
    if ($Json) { $inventory | ConvertTo-Json -Depth 6 } else { $inventory }
}
