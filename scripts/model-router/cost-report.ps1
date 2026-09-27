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

try {
    $python = $null
    foreach ($name in @('python', 'python3', 'py')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $python = $cmd.Source; break }
    }
    if (-not $python) { throw "python not found on PATH" }

    $sweep = if ($env:DT_MODEL_ROUTER_USAGE_SWEEP) { $env:DT_MODEL_ROUTER_USAGE_SWEEP } else { Join-Path $PSScriptRoot '../../skills/dt-build/scripts/collect-usage.py' }
    try {
        & $python $sweep --all-sessions --quiet *> $null
        if ($LASTEXITCODE -ne 0) { throw "usage sweep exited $LASTEXITCODE" }
    } catch { Write-Output "DT_MODEL_ROUTER_COST_REPORT: usage sweep failed ($($_.Exception.Message)); reporting existing data" }

    $script = Join-Path (Split-Path -Parent $PSCommandPath) 'cost_report.py'
    $pyArgs = @($script)
    if (-not [string]::IsNullOrWhiteSpace($StateDir)) { $pyArgs += @('--state-dir', $StateDir) }
    if (-not [string]::IsNullOrWhiteSpace($Prices)) { $pyArgs += @('--prices', $Prices) }
    & $python @pyArgs
    if ($LASTEXITCODE -ne 0) { throw "cost_report.py exited $LASTEXITCODE" }
}
catch {
    Write-Output "DT_MODEL_ROUTER_COST_REPORT: skipped ($($_.Exception.Message))"
}
exit 0
