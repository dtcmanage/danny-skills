# Timed refresh of the router's Claude usage cache (<state>/claude-usage.json): the all-models weekly
# figure and, when the server reports one, the 5-hour session figure. Command Center v2's
# /host/usage reads this file and calls it stale after 6 hours. Exits 1 when no fresh reading was
# obtained, so a failed refresh shows as a failed systemd run instead of a silently aging cache.
param([switch]$Json)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vendor-limits.ps1')
Assert-RouterOwner -Action 'Hourly quota collection'

$started = [datetimeoffset]::UtcNow
$usage = Get-RouterClaudeUsage
$fresh = $null -ne $usage -and [datetimeoffset]$usage.observed_at_utc -ge $started.AddMinutes(-5)
$claudeHistory = $script:RouterQuotaHistoryStatus
$script:RouterQuotaHistoryStatus = 'no_observation'
$codex = Get-RouterCodexLiveUsage
$codexFresh = $null -ne $codex -and [datetimeoffset]$codex.observed_at_utc -ge $started
$summary = [pscustomobject]@{
    fresh = $fresh
    used_percent = $(if ($null -ne $usage) { $usage.used_percent } else { $null })
    resets_at_utc = $(if ($null -ne $usage) { $usage.resets_at_utc } else { $null })
    session_percent = $(if ($null -ne $usage) { $usage.session_percent } else { $null })
    observed_at_utc = $(if ($null -ne $usage) { $usage.observed_at_utc } else { $null })
    source = $(if ($null -ne $usage) { $usage.source } else { $null })
    claude_status = $(if ($fresh) { 'fresh_or_cache' } else { 'unavailable_or_stale' })
    codex_status = $(if ($codexFresh) { 'fresh' } else { 'unavailable' })
    claude_history_status = $claudeHistory
    codex_history_status = $script:RouterQuotaHistoryStatus
}
if ($Json) { $summary | ConvertTo-Json -Compress } else {
    $text = if ($null -ne $usage) { Format-RouterUsageMessage -Vendor claude -Usage $usage } else { 'claude: no reading' }
    $session = if ($null -ne $usage -and $null -ne $usage.session_percent) { "; 5-hour session $($usage.session_percent)% used" } else { '; 5-hour session not reported' }
    "$text$session; source $($summary.source); $(if ($fresh) { 'fresh' } else { 'STALE (refresh failed)' })"
    "codex: $($summary.codex_status); history: Claude $claudeHistory, Codex $($summary.codex_history_status)"
}
if (-not $fresh -or -not $codexFresh -or $claudeHistory -eq 'error' -or $script:RouterQuotaHistoryStatus -eq 'error') { exit 1 }
