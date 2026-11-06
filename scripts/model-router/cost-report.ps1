param(
    [string]$StateDir = "",
    [string]$Prices = "",
    [switch]$Dry
)

# cost-report.ps1
# ----------------
# pwsh entry point for cost_report.py. Builds the weekly model-router cost report
# (subscription vs API-equivalent spend, per vendor) from the all-sessions usage
# ledger. Never blocks a build: any failure is reported on one line and the exit
# code stays 0, exactly like collect-usage.ps1. Quota readings are refreshed first
# (neither refresh runs a model turn); a failed refresh keeps the older reading,
# which the report labels stale. -Dry writes the report but sends nothing.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'router-platform.ps1')
Assert-RouterWindowsOwner -Action 'Weekly cost report'

try {
    $python = $null
    foreach ($name in @('python', 'python3', 'py')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $python = $cmd.Source; break }
    }
    if (-not $python) { throw "python not found on PATH" }

    $sweep = if ($env:DT_MODEL_ROUTER_USAGE_SWEEP) { $env:DT_MODEL_ROUTER_USAGE_SWEEP } else { Join-Path $PSScriptRoot '../../skills/dt-build/scripts/collect-usage.py' }
    $priorState = $env:DT_MODEL_ROUTER_STATE
    try {
        if (-not [string]::IsNullOrWhiteSpace($StateDir)) { $env:DT_MODEL_ROUTER_STATE = $StateDir }
        & $python $sweep --all-sessions --quiet *> $null
        if ($LASTEXITCODE -ne 0) { throw "usage sweep exited $LASTEXITCODE" }
    } catch { Write-Output "DT_MODEL_ROUTER_COST_REPORT: usage sweep failed ($($_.Exception.Message)); reporting existing data" }
    finally { $env:DT_MODEL_ROUTER_STATE = $priorState }

    $refreshFailed = [Collections.Generic.List[string]]::new()
    $priorRefreshState = $env:DT_MODEL_ROUTER_STATE
    try {
        if (-not [string]::IsNullOrWhiteSpace($StateDir)) { $env:DT_MODEL_ROUTER_STATE = $StateDir }
        . (Join-Path $PSScriptRoot 'vendor-limits.ps1')
        foreach ($vendor in @('codex', 'claude')) {
            $reading = $null
            try { $reading = if ($vendor -eq 'codex') { Get-RouterCodexLiveUsage } else { Get-RouterClaudeUsage } } catch { $reading = $null }
            # Get-RouterClaudeUsage falls back to an old cache on failure; only a recent observation is a refresh.
            if ($null -eq $reading -or ([datetimeoffset]::UtcNow - [datetimeoffset]$reading.observed_at_utc).TotalMinutes -ge 10) {
                $refreshFailed.Add($vendor)
                Write-Output "DT_MODEL_ROUTER_COST_REPORT: $vendor quota refresh failed; reporting its older reading as stale or unavailable"
            }
        }
    } catch {
        foreach ($vendor in @('codex', 'claude')) { if ($vendor -notin $refreshFailed) { $refreshFailed.Add($vendor) } }
        Write-Output "DT_MODEL_ROUTER_COST_REPORT: quota refresh failed ($($_.Exception.Message))"
    }
    finally { $env:DT_MODEL_ROUTER_STATE = $priorRefreshState }

    $script = Join-Path (Split-Path -Parent $PSCommandPath) 'cost_report.py'
    $pyArgs = @($script)
    foreach ($vendor in $refreshFailed) { $pyArgs += @('--refresh-failed', $vendor) }
    if (-not [string]::IsNullOrWhiteSpace($StateDir)) { $pyArgs += @('--state-dir', $StateDir) }
    if (-not [string]::IsNullOrWhiteSpace($Prices)) { $pyArgs += @('--prices', $Prices) }
    & $python @pyArgs
    if ($LASTEXITCODE -ne 0) { throw "cost_report.py exited $LASTEXITCODE" }

    if ($Dry) {
        Write-Output "DT_MODEL_ROUTER_COST_REPORT: dry report; nothing sent"
        exit 0
    }
    try {
        $priorState2 = $env:DT_MODEL_ROUTER_STATE
        try {
            if (-not [string]::IsNullOrWhiteSpace($StateDir)) { $env:DT_MODEL_ROUTER_STATE = $StateDir }
            . (Join-Path $PSScriptRoot 'router-common.ps1')
            $resolvedState = Get-RouterStateDir
        } finally { $env:DT_MODEL_ROUTER_STATE = $priorState2 }
        $discordPath = Join-Path $resolvedState 'cost-reports/discord-summary.json'
        if (Test-Path -LiteralPath $discordPath) {
            $summary = Get-Content -LiteralPath $discordPath -Raw | ConvertFrom-Json
            . (Join-Path $PSScriptRoot 'send-router-alert.ps1')
            $result = Send-RouterAlert -Key ([string]$summary.key) -Message ([string]$summary.message) -Severity info
            if ($result.deduped) { Write-Output "DT_MODEL_ROUTER_COST_REPORT: weekly summary already sent" }
            elseif ($result.sent) { Write-Output "DT_MODEL_ROUTER_COST_REPORT: weekly summary sent (discord)" }
            else { Write-Output "DT_MODEL_ROUTER_COST_REPORT: weekly summary delivery failed" }
        }
    } catch { Write-Output "DT_MODEL_ROUTER_COST_REPORT: weekly summary delivery failed ($($_.Exception.Message))" }
}
catch {
    Write-Output "DT_MODEL_ROUTER_COST_REPORT: skipped ($($_.Exception.Message))"
}
exit 0
