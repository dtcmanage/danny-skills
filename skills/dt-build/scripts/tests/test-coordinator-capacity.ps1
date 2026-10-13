#Requires -Version 7.0
# Pure watcher decision fixtures; no Python, model, grader or alert child processes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scripts = Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'dt-build-watcher.ps1')
$script:passed = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "ASSERT_FAIL: $Message" }
    $script:passed++; Write-Output "PASS: $Message"
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('capacity-fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function Save([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text) }
try {
    $state = Join-Path $root '_build-state.md'
    Save $state "run_status: runnable`nlast_consumed_event_seq: 0`n## Next step`nFixtures only."
    $entry = [pscustomobject]@{ run_folder = $root; build_state_path = $state; managed = $true }
    function Get-WatcherTriggerSeq { param([string]$RunFolder) return 1 }
    $now = [DateTime]::UtcNow
    $row = [pscustomobject]@{ type = 'launch'; coordinator_id = 'refused'; launcher_exit = 0; trigger_seq = 1; launched_utc = $now.AddMinutes(-5).ToString('o'); checkpoint_sha256 = Get-WatcherCheckpointFingerprint $state }
    Save (Join-Path $root 'coordinator-refused.log') '{"error":{"type":"overloaded_error"}}'
    Check (Test-WatcherCapacityLaunch $root $row) 'equivalent vendor overload stream is classified as capacity'
    Save (Join-Path $root 'coordinator-refused.log') 'You have hit your usage limit.'
    Check (-not (Test-WatcherCapacityLaunch $root $row)) 'quota refusal remains separate from capacity'
    Save (Join-Path $root 'coordinator-refused.exit.json') '{"coordinator_id":"refused","exit_code":1,"failure_category":"capacity"}'
    Check (Test-WatcherCapacityLaunch $root $row) 'detached launcher exit receipt classifies capacity'
    Save (Join-Path $root 'launches.jsonl') ($row | ConvertTo-Json -Compress)
    Check ((Get-WatcherDecision $entry $now).action -eq 'launch') 'capacity receipt does not consume the ordinary retry schedule'
    # Isolate all ordinary caps from the separately tested capacity wait bound. With many
    # refusals and a still-open capacity wait, no absolute/retry/thrash cap may trigger.
    $script:WatcherCapacityDelaysMin = @(0) * 40
    $script:WatcherCapacityWaitMin = 120
    $rows = @(for ($i = 0; $i -lt 35; $i++) { [pscustomobject]@{ type = 'launch'; coordinator_id = "capacity-$i"; failure_category = 'capacity'; launcher_exit = 1; trigger_seq = 1; launched_utc = $now.AddMinutes(-5).ToString('o'); checkpoint_sha256 = $row.checkpoint_sha256 } })
    Save (Join-Path $root 'launches.jsonl') (($rows | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join "`n")
    Check ((Get-WatcherDecision $entry $now).action -eq 'launch') 'thirty-five capacity failures spend none of the retry, thrash or absolute cap budgets'
    # Cross-trigger refusals share the bounded episode rather than resetting their total wait.
    $script:WatcherCapacityDelaysMin = @(5, 10, 20)
    $script:WatcherCapacityWaitMin = 35
    $rows = @($rows | Select-Object -First 2)
    $rows[0].launched_utc = $now.AddMinutes(-35).ToString('o')
    $rows[0].trigger_seq = 999
    Save (Join-Path $root 'launches.jsonl') (($rows | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join "`n")
    $decision = Get-WatcherDecision $entry $now
    Check ($decision.action -eq 'stop' -and $decision.stop_kind -eq 'capacity') 'a new trigger cannot reset the total capacity wait bound'
    $transcript = Join-Path $root 'rollout-no-usage.jsonl'
    Save $transcript '{"type":"session_meta","payload":{"cwd":"fixture"}}'
    Save (Join-Path $root 'context-baseline.json') (@{ coordinators = @{ 'capacity-1' = @{ transcript_path = $transcript; host = 'codex'; baseline_tokens = 50000 } } } | ConvertTo-Json -Depth 5)
    $wallPath = Join-Path $root 'context-wall.json'
    Save $wallPath '{"coordinator_id":"earlier-wall","reads":[]}'
    Update-WatcherContextWall -Folder $root -NowUtc $now
    Check ((Get-Content $wallPath -Raw).Contains('earlier-wall')) 'capacity transcript without usage cannot erase the prior context wall'
    Write-Output "SUMMARY: $script:passed passed"
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped temp root' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
