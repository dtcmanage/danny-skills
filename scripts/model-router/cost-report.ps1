param(
    [string]$StateDir = "",
    [string]$Prices = ""
)

# cost-report.ps1
# ----------------
# pwsh entry point for cost_report.py. Builds the weekly model-router cost report
# (subscription vs API-equivalent spend, per vendor) from the all-sessions usage
# ledger. Never blocks a build: any failure is reported on one line and the exit
# code stays 0, exactly like collect-usage.ps1.

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

    $script = Join-Path (Split-Path -Parent $PSCommandPath) 'cost_report.py'
    $pyArgs = @($script)
    if (-not [string]::IsNullOrWhiteSpace($StateDir)) { $pyArgs += @('--state-dir', $StateDir) }
    if (-not [string]::IsNullOrWhiteSpace($Prices)) { $pyArgs += @('--prices', $Prices) }
    & $python @pyArgs
    if ($LASTEXITCODE -ne 0) { throw "cost_report.py exited $LASTEXITCODE" }

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
