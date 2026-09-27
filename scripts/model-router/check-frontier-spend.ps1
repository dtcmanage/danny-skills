param(
    [Alias('RunStartedAt')][datetime]$RouterSpendCliRunStartedAt,
    [Alias('RunId')][string]$RouterSpendCliRunId,
    [Alias('Json')][switch]$RouterSpendCliJson
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot 'send-router-alert.ps1')

# Frontier spend alert (design section 3, alert only). Fires once per run, keyed
# frontier-spend:<run-id>, when frontier models have used 10 points of a weekly limit
# since the run started. It never changes a model.
$script:RouterFrontierSpendThresholdPoints = 10.0
# ESTIMATE, not a vendor number: Anthropic publishes no weekly token budget for the
# subscription. Weighted tokens use collect-usage.py's formula (input + 1.25 x cache
# write + 0.1 x cache read + 5 x output). Tune this from real ledger data.
$script:RouterClaudeWeeklyWeightedBudgetEstimate = 250000000.0

function Get-RouterFrontierModels {
    param([string]$TablePath)
    $table = (Read-RouterTable -TablePath $TablePath).table
    $models = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($category in $table.categories.PSObject.Properties) {
        foreach ($lane in $category.Value.PSObject.Properties) {
            foreach ($candidate in @($lane.Value.candidates)) { if ($candidate.frontier -eq $true) { [void]$models.Add([string]$candidate.model) } }
        }
    }
    return $models
}

function Test-RouterFrontierModel {
    param([string]$Model, [System.Collections.Generic.HashSet[string]]$Frontier)
    if (-not $Model) { return $false }
    $clean = ($Model -replace '\[.*\]$', '').Trim()
    foreach ($id in $Frontier) { if ($clean -ieq $id -or $clean -like "$id-*") { return $true } }
    return $false
}

function ConvertTo-RouterSpendTime {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $parsed = [datetimeoffset]::MinValue
    if ($Value -is [datetime]) { return [datetimeoffset]$Value }
    if ([datetimeoffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-RouterCodexFrontierSpend {
    # Same fields collect-usage.py reads: turn_context.payload.model and
    # token_count.payload.rate_limits.primary.used_percent (the weekly window).
    param([datetimeoffset]$Since, [string]$CodexHome, [System.Collections.Generic.HashSet[string]]$Frontier)
    $readings = [System.Collections.Generic.List[object]]::new()
    $sessions = Join-Path $CodexHome 'sessions'
    if (Test-Path -LiteralPath $sessions) {
        foreach ($file in @(Get-ChildItem -LiteralPath $sessions -Recurse -File -Filter 'rollout-*.jsonl' | Where-Object { $_.LastWriteTimeUtc -ge $Since.UtcDateTime })) {
            $model = $null
            foreach ($line in [IO.File]::ReadLines($file.FullName)) {
                try { $row = $line | ConvertFrom-Json -Depth 20 } catch { continue }
                if ($null -eq $row -or -not $row.PSObject.Properties['payload'] -or $null -eq $row.payload) { continue }
                $payload = $row.payload
                if ($row.PSObject.Properties['type'] -and $row.type -eq 'turn_context' -and $payload.PSObject.Properties['model']) { $model = [string]$payload.model; continue }
                if (-not $payload.PSObject.Properties['type'] -or $payload.type -ne 'token_count') { continue }
                $at = if ($row.PSObject.Properties['timestamp']) { ConvertTo-RouterSpendTime $row.timestamp } else { $null }
                if ($null -eq $at -or $at -lt $Since) { continue }
                if (-not $payload.PSObject.Properties['rate_limits'] -or $null -eq $payload.rate_limits) { continue }
                $primary = $payload.rate_limits.PSObject.Properties['primary']
                if (-not $primary -or $null -eq $primary.Value -or -not $primary.Value.PSObject.Properties['used_percent']) { continue }
                $readings.Add([pscustomobject]@{ at = $at; used = [double]$primary.Value.used_percent; frontier = (Test-RouterFrontierModel -Model $model -Frontier $Frontier) })
            }
        }
    }
    $ordered = @($readings | Sort-Object at)
    $frontierPoints = 0.0; $totalPoints = 0.0; $frontierTurns = 0
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        if ($ordered[$i].frontier) { $frontierTurns++ }
        if ($i -eq 0) { continue }
        $delta = $ordered[$i].used - $ordered[$i - 1].used
        if ($delta -le 0) { continue } # a window reset or an unchanged reading
        $totalPoints += $delta
        if ($ordered[$i].frontier) { $frontierPoints += $delta }
    }
    return [pscustomobject]@{ readings = $ordered.Count; frontier_turns = $frontierTurns; total_points = [Math]::Round($totalPoints, 2); frontier_points = [Math]::Round($frontierPoints, 2) }
}

function Get-RouterClaudeFrontierSpend {
    param([datetimeoffset]$Since, [string]$ClaudeHome, [System.Collections.Generic.HashSet[string]]$Frontier)
    $weighted = 0.0
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $projects = Join-Path $ClaudeHome 'projects'
    if (Test-Path -LiteralPath $projects) {
        foreach ($file in @(Get-ChildItem -LiteralPath $projects -Recurse -File -Filter '*.jsonl' | Where-Object { $_.LastWriteTimeUtc -ge $Since.UtcDateTime })) {
            foreach ($line in [IO.File]::ReadLines($file.FullName)) {
                try { $row = $line | ConvertFrom-Json -Depth 30 } catch { continue }
                if ($null -eq $row -or -not $row.PSObject.Properties['type'] -or $row.type -ne 'assistant') { continue }
                if (-not $row.PSObject.Properties['message'] -or $null -eq $row.message) { continue }
                $message = $row.message
                $at = if ($row.PSObject.Properties['timestamp']) { ConvertTo-RouterSpendTime $row.timestamp } else { $null }
                if ($null -eq $at -or $at -lt $Since) { continue }
                $model = if ($message.PSObject.Properties['model']) { [string]$message.model } else { '' }
                if (-not (Test-RouterFrontierModel -Model $model -Frontier $Frontier)) { continue }
                $id = if ($message.PSObject.Properties['id']) { [string]$message.id } else { '' }
                if ($id -and -not $seen.Add($id)) { continue }
                if (-not $message.PSObject.Properties['usage'] -or $null -eq $message.usage) { continue }
                $usage = $message.usage
                $value = { param($name) if ($usage.PSObject.Properties[$name] -and $null -ne $usage.$name) { [double]$usage.$name } else { 0.0 } }
                $weighted += (& $value 'input_tokens') + 1.25 * (& $value 'cache_creation_input_tokens') + 0.1 * (& $value 'cache_read_input_tokens') + 5 * (& $value 'output_tokens')
            }
        }
    }
    $points = 100.0 * $weighted / $script:RouterClaudeWeeklyWeightedBudgetEstimate
    return [pscustomobject]@{ weighted_tokens = [long]$weighted; estimated_points = [Math]::Round($points, 2); weekly_budget_estimate = [long]$script:RouterClaudeWeeklyWeightedBudgetEstimate }
}

function Test-FrontierSpend {
    param(
        [Parameter(Mandatory)][datetime]$RunStartedAt,
        [Parameter(Mandatory)][string]$RunId,
        [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }),
        [string]$ClaudeHome = $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }),
        [string]$TablePath,
        [scriptblock]$Transport,
        [switch]$ChatToStderr
    )
    $since = [datetimeoffset]$RunStartedAt
    $frontier = Get-RouterFrontierModels -TablePath $TablePath
    $codex = Get-RouterCodexFrontierSpend -Since $since -CodexHome $CodexHome -Frontier $frontier
    $claude = Get-RouterClaudeFrontierSpend -Since $since -ClaudeHome $ClaudeHome -Frontier $frontier
    $threshold = $script:RouterFrontierSpendThresholdPoints
    $over = [System.Collections.Generic.List[string]]::new()
    if ($codex.frontier_points -ge $threshold) { $over.Add('codex') }
    if ($claude.estimated_points -ge $threshold) { $over.Add('claude') }
    $key = "frontier-spend:$RunId"
    $alert = $null
    if ($over.Count -gt 0) {
        $message = "Frontier models have used $($codex.frontier_points) points of the weekly Codex limit and an estimated $($claude.estimated_points) points of the weekly Claude budget in run $RunId (Codex total since run start: $($codex.total_points) points). The run continues on the same models."
        $alert = Send-RouterAlert -Key $key -Message $message -Transport $Transport -ChatToStderr:$ChatToStderr
    }
    return [pscustomobject]@{
        run_id = $RunId; run_started_at = $since.ToString('o'); threshold_points = $threshold; alert_key = $key
        codex = $codex; claude = $claude; lanes_over = @($over.ToArray())
        alert_fired = ($null -ne $alert -and [bool]$alert.sent -and -not [bool]$alert.deduped)
        alert = $alert
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Test-FrontierSpend -RunStartedAt $RouterSpendCliRunStartedAt -RunId $RouterSpendCliRunId -ChatToStderr:$RouterSpendCliJson
    if ($RouterSpendCliJson) { $result | ConvertTo-Json -Depth 8 -Compress } else { $result }
}
