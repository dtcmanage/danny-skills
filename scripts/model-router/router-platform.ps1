Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Function seam for portable fixtures; never infer the platform from environment config.
if (-not (Get-Command Get-RouterPlatform -CommandType Function -ErrorAction SilentlyContinue)) {
    function Get-RouterPlatform {
        if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { return 'Windows' }
        if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) { return 'MacOS' }
        return 'Other'
    }
}

function Assert-RouterWindowsOwner {
    param([string]$Action, [string]$Platform = (Get-RouterPlatform))
    if ($Platform -ne 'Windows') { throw "ROUTER_WINDOWS_OWNER: $Action is owned by Windows." }
}

function Use-RouterRosterMutex {
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$StateDir = (Get-RouterStatePath),
        [ValidateRange(1, 60000)][int]$TimeoutMs = 15000)
    Assert-RouterWindowsOwner -Action 'Roster mutation and publication'
    $identity = [IO.Path]::GetFullPath($StateDir).TrimEnd('\','/').ToUpperInvariant()
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity)))
    $mutex = [Threading.Mutex]::new($false, "Local\DannyModelRouterRoster.$hash")
    $held = $false
    try {
        try { $held = $mutex.WaitOne($TimeoutMs) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'ROUTER_ROSTER_LOCK_TIMEOUT: Another roster writer is active.' }
        & $Body
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-RouterMainCheckout {
    param([string]$ScriptRoot = $PSScriptRoot)
    # Read Git's common-dir metadata locally, including linked worktrees, without spawning Git.
    $directory = [IO.Path]::GetFullPath($ScriptRoot)
    while ($directory) {
        $dotGit = Join-Path $directory '.git'
        if (Test-Path -LiteralPath $dotGit) {
            $common = $dotGit
            if (-not (Test-Path -LiteralPath $dotGit -PathType Container)) {
                $pointer = [IO.File]::ReadAllText($dotGit).Trim()
                if ($pointer -notmatch '^gitdir: (.+)$') { throw 'ROUTER_GIT_COMMON_DIR: Invalid gitdir pointer.' }
                $gitDir = [IO.Path]::GetFullPath($Matches[1], $directory)
                $commonFile = Join-Path $gitDir 'commondir'
                if (-not (Test-Path -LiteralPath $commonFile)) { throw 'ROUTER_GIT_COMMON_DIR: Missing commondir.' }
                $common = [IO.Path]::GetFullPath([IO.File]::ReadAllText($commonFile).Trim(), $gitDir)
            }
            return (Split-Path -Parent $common)
        }
        $directory = Split-Path -Parent $directory
    }
    throw 'ROUTER_GIT_COMMON_DIR: Cannot locate main checkout.'
}

# Pure lookups: callers choose whether to create runtime state.
function Get-RouterStatePath {
    param([string]$Platform = (Get-RouterPlatform), [string]$MainCheckout,
        [string]$UserHome = $HOME, [string]$StateOverride = $env:DT_MODEL_ROUTER_STATE)
    if ($StateOverride) { return [IO.Path]::GetFullPath($StateOverride) }
    if ($Platform -eq 'MacOS') { return [IO.Path]::GetFullPath((Join-Path $UserHome 'Library/Application Support/DannyModelRouter')) }
    if (-not $MainCheckout) { $MainCheckout = Get-RouterMainCheckout }
    return [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MainCheckout) 'model-router/state'))
}

function Get-RouterSharedDir {
    param([string]$MainCheckout, [string]$SharedOverride = $env:DT_MODEL_ROUTER_SHARED,
        [string]$StateOverride = $env:DT_MODEL_ROUTER_STATE)
    if ($SharedOverride) { return [IO.Path]::GetFullPath($SharedOverride) }
    if ($StateOverride) { return [IO.Path]::GetFullPath((Join-Path $StateOverride 'shared')) }
    if (-not $MainCheckout) { $MainCheckout = Get-RouterMainCheckout }
    return [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MainCheckout) 'model-router/shared'))
}
