param(
    [string]$OutDir = "",
    [string]$Baseline = "",
    [switch]$Quiet
)

# collect-usage.ps1
# -----------------
# pwsh entry point for collect-usage.py (dt-build's allowed-tools admit pwsh, not
# python). Sweeps this machine's Claude Code and Codex session logs for dt-build
# runs and refreshes the usage ledger + dashboard. Never blocks a build: any
# failure is reported on one line and the exit code stays 0.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    $python = $null
    foreach ($name in @('python', 'python3', 'py')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $python = $cmd.Source; break }
    }
    if (-not $python) { throw "python not found on PATH" }

    $script = Join-Path (Split-Path -Parent $PSCommandPath) 'collect-usage.py'
    $pyArgs = @($script)
    if (-not [string]::IsNullOrWhiteSpace($OutDir)) { $pyArgs += @('--out', $OutDir) }
    if (-not [string]::IsNullOrWhiteSpace($Baseline)) { $pyArgs += @('--baseline', $Baseline) }
    if ($Quiet) { $pyArgs += '--quiet' }
    & $python @pyArgs
    if ($LASTEXITCODE -ne 0) { throw "collect-usage.py exited $LASTEXITCODE" }
}
catch {
    Write-Output "DT_BUILD_USAGE: collection skipped ($($_.Exception.Message))"
}

# All-sessions sweep + model-router cost report, refreshed on every dt-build run.
# Isolated: any failure here is one line and never touches the dt-build ledger/dashboard
# above or this script's exit code.
try {
    $python2 = $null
    foreach ($name in @('python', 'python3', 'py')) {
        $cmd2 = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd2) { $python2 = $cmd2.Source; break }
    }
    if (-not $python2) { throw "python not found on PATH" }
    $script2 = Join-Path (Split-Path -Parent $PSCommandPath) 'collect-usage.py'
    & $python2 $script2 --all-sessions --quiet
    if ($LASTEXITCODE -ne 0) { throw "collect-usage.py --all-sessions exited $LASTEXITCODE" }

    $reportScript = Join-Path (Split-Path -Parent $PSCommandPath) '..\..\..\scripts\model-router\cost-report.ps1'
    if (Test-Path -LiteralPath $reportScript) {
        & $reportScript | ForEach-Object { Write-Output $_ }
    }
}
catch {
    Write-Output "DT_MODEL_ROUTER_COST_REPORT: skipped ($($_.Exception.Message))"
}
exit 0
