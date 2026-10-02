param([switch]$Apply, [switch]$Remove, [string]$RepoPath, [string]$PwshPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-platform.ps1')

function Get-RouterLaunchEnvironment {
    param([string]$UserHome = $HOME)
    $values = [ordered]@{ CODEX_HOME=(Join-Path $UserHome '.codex'); TEMP=[IO.Path]::GetTempPath() }
    foreach ($name in @('CODEX_HOME','TEMP','CLAUDE_CONFIG_DIR','DT_MODEL_ROUTER_CLAUDE_KEYCHAIN_SERVICE',
        'DT_MODEL_ROUTER_CLAUDE_CREDENTIALS','DT_MODEL_ROUTER_CODEX_SESSIONS','DT_MODEL_ROUTER_STATE','DT_MODEL_ROUTER_SHARED')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $values[$name] = $value }
    }
    return $values
}

function Assert-RouterLaunchMainCheckout {
    param([Parameter(Mandatory)][string]$RepoPath)
    if (-not [IO.Path]::IsPathFullyQualified($RepoPath)) { throw 'ROUTER_LAUNCH_PATH: Absolute paths required.' }
    $repo = [IO.Path]::GetFullPath($RepoPath)
    $main = Get-RouterMainCheckout -ScriptRoot $repo
    if ($main -ne $repo -or -not (Test-Path -LiteralPath (Join-Path $repo '.git') -PathType Container)) {
        throw 'ROUTER_LAUNCH_WORKTREE: Install only from the permanent main checkout.'
    }
    $headPath = Join-Path $repo '.git/HEAD'
    if (-not (Test-Path -LiteralPath $headPath -PathType Leaf) -or [IO.File]::ReadAllText($headPath).Trim() -cne 'ref: refs/heads/main') {
        throw 'ROUTER_LAUNCH_MAIN: The permanent checkout must be on main.'
    }
}

function New-RouterLaunchAgent {
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$PwshPath,
        [string]$UserHome = $HOME, [string]$StatePath = (Get-RouterStatePath -Platform MacOS))
    foreach ($path in @($RepoPath,$PwshPath,$StatePath,$UserHome)) {
        if (-not [IO.Path]::IsPathFullyQualified($path)) { throw 'ROUTER_LAUNCH_PATH: Absolute paths required.' }
    }
    $repo = [IO.Path]::GetFullPath($RepoPath)
    Assert-RouterLaunchMainCheckout -RepoPath $repo
    $scriptPath = Join-Path $repo 'scripts/model-router/run-mac-observer.ps1'
    $escape = { param($Value) [Security.SecurityElement]::Escape([string]$Value) }
    $arguments = @($PwshPath,'-NoProfile','-NonInteractive','-File',$scriptPath)
    $argumentXml = ($arguments | ForEach-Object { '<string>' + (& $escape $_) + '</string>' }) -join ''
    $environment = Get-RouterLaunchEnvironment -UserHome $UserHome
    $environmentXml = ($environment.Keys | ForEach-Object { '<key>' + (& $escape $_) + '</key><string>' + (& $escape $environment[$_]) + '</string>' }) -join ''
    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.danny.model-router.observer</string>
<key>ProgramArguments</key><array>$argumentXml</array>
<key>WorkingDirectory</key><string>$(& $escape $repo)</string>
<key>EnvironmentVariables</key><dict>$environmentXml</dict>
<key>RunAtLoad</key><true/><key>StartInterval</key><integer>14400</integer>
<key>StandardOutPath</key><string>$(& $escape (Join-Path $StatePath 'observer.stdout.log'))</string>
<key>StandardErrorPath</key><string>$(& $escape (Join-Path $StatePath 'observer.stderr.log'))</string>
</dict></plist>
"@
    [pscustomobject]@{ label='com.danny.model-router.observer'; repo_path=$repo; plist_path=(Join-Path $UserHome 'Library/LaunchAgents/com.danny.model-router.observer.plist'); state_path=$StatePath; xml=$xml; script_path=$scriptPath; pwsh_path=$PwshPath }
}

# Test fixtures invoke this operation with their own paths and command seam. CLI writes below
# have a separate real-OS guard; a platform fixture cannot enable live installation.
function Invoke-RouterLaunchAgentOperation {
    param([Parameter(Mandatory)]$Agent, [switch]$Remove, [Parameter(Mandatory)][string]$Domain,
        [scriptblock]$Command = { param($File,$Arguments) Invoke-RouterBoundedProcess -FilePath $File -Arguments $Arguments -TimeoutMs 5000 })
    if ($Agent.label -cne 'com.danny.model-router.observer' -or
        [IO.Path]::GetFileName($Agent.plist_path) -cne 'com.danny.model-router.observer.plist') { throw 'ROUTER_LAUNCH_OWNERSHIP' }
    if (-not $Remove) {
        if (-not $Agent.PSObject.Properties['repo_path']) { throw 'ROUTER_LAUNCH_MAIN: Missing permanent checkout.' }
        Assert-RouterLaunchMainCheckout -RepoPath $Agent.repo_path
    }
    if (Test-Path -LiteralPath $Agent.plist_path) {
        $item = Get-Item -LiteralPath $Agent.plist_path
        if ($item.LinkType) { throw 'ROUTER_LAUNCH_OWNERSHIP: Linked plist refused.' }
        try {
            $existing = [xml][IO.File]::ReadAllText($Agent.plist_path)
            $label = $existing.SelectSingleNode('/plist/dict/key[text()="Label"]/following-sibling::*[1]')
            if ($null -eq $label -or $label.InnerText -cne $Agent.label) { throw 'foreign' }
        } catch { throw 'ROUTER_LAUNCH_OWNERSHIP: Existing plist has another owner or invalid XML.' }
    }
    $target = "$Domain/$($Agent.label)"
    if ($Remove) {
        $before = & $Command '/bin/launchctl' @('print',$target)
        if ($before.status -ne 'completed') { return [pscustomobject]@{ status='verification-failed'; action='remove' } }
        if ($before.exit_code -eq 0) {
            $bootout = & $Command '/bin/launchctl' @('bootout',$target)
            if ($bootout.status -ne 'completed' -or $bootout.exit_code -ne 0) { return [pscustomobject]@{ status='verification-failed'; action='remove' } }
        }
        $after = & $Command '/bin/launchctl' @('print',$target)
        if ($after.status -ne 'completed' -or $after.exit_code -eq 0) { return [pscustomobject]@{ status='verification-failed'; action='remove' } }
        if (Test-Path -LiteralPath $Agent.plist_path) { Remove-Item -LiteralPath $Agent.plist_path -Force }
        return [pscustomobject]@{ status='removed'; action='remove' }
    }
    if (-not (Test-Path -LiteralPath $Agent.pwsh_path -PathType Leaf) -or -not (Test-Path -LiteralPath $Agent.script_path -PathType Leaf)) { throw 'ROUTER_LAUNCH_PATH: Executable or runner missing.' }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Agent.plist_path)) | Out-Null
    [IO.Directory]::CreateDirectory($Agent.state_path) | Out-Null
    $temporary = $Agent.plist_path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary,$Agent.xml,[Text.UTF8Encoding]::new($false))
        $lint = & $Command '/usr/bin/plutil' @('-lint',$temporary)
        if ($lint.status -ne 'completed' -or $lint.exit_code -ne 0) { throw 'ROUTER_LAUNCH_PLIST: Native lint failed.' }
        $before = & $Command '/bin/launchctl' @('print',$target)
        if ($before.status -ne 'completed') { throw 'ROUTER_LAUNCH_VERIFY: Cannot inspect existing agent.' }
        if ($before.exit_code -eq 0) {
            $bootout = & $Command '/bin/launchctl' @('bootout',$target)
            if ($bootout.status -ne 'completed' -or $bootout.exit_code -ne 0) { throw 'ROUTER_LAUNCH_BOOTOUT' }
        }
        [IO.File]::Move($temporary,$Agent.plist_path,$true)
        $bootstrap = & $Command '/bin/launchctl' @('bootstrap',$Domain,$Agent.plist_path)
        $readback = & $Command '/bin/launchctl' @('print',$target)
        $verified = $bootstrap.status -eq 'completed' -and $bootstrap.exit_code -eq 0 -and $readback.status -eq 'completed' -and $readback.exit_code -eq 0
        [pscustomobject]@{ status=$(if ($verified) { 'installed' } else { 'verification-failed' }); action='apply' }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Apply -and $Remove) { throw 'Choose Apply or Remove.' }
    if (($Apply -or $Remove) -and -not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) { throw 'ROUTER_LAUNCH_MAC_ONLY: Apply/Remove require the actual Mac.' }
    if (-not $RepoPath) { $RepoPath = Get-RouterMainCheckout }
    if (-not $PwshPath) { $PwshPath = (Get-Process -Id $PID).Path }
    if ($Remove) {
        $agent = [pscustomobject]@{ label='com.danny.model-router.observer'; plist_path=(Join-Path $HOME 'Library/LaunchAgents/com.danny.model-router.observer.plist') }
    } else { $agent = New-RouterLaunchAgent -RepoPath $RepoPath -PwshPath $PwshPath }
    if ($Apply -or $Remove) {
        $uid = Invoke-RouterBoundedProcess -FilePath '/usr/bin/id' -Arguments @('-u')
        if ($uid.status -ne 'completed' -or $uid.exit_code -ne 0 -or $uid.output.Trim() -notmatch '^\d+$') { throw 'ROUTER_LAUNCH_UID' }
        $result = Invoke-RouterLaunchAgentOperation -Agent $agent -Remove:$Remove -Domain ('gui/' + $uid.output.Trim())
        $result
        if ($result.status -eq 'verification-failed') { exit 1 }
    } else { $agent }
}
