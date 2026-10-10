#Requires -Version 7.0
# Read-only comparison of collect-usage ledger rows and retained run artifacts.
# RunId defaults to the run folder's name. Old runs without reads/launches have unknown counts.
param(
    [Parameter(Mandatory)][string]$OldRunFolder,
    [Parameter(Mandatory)][string]$NewRunFolder,
    [Parameter(Mandatory)][string]$UsageLedgerPath,
    [string]$OldRunId,
    [string]$NewRunId,
    [Parameter(Mandatory)][string]$OutputDir
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Read-Rows([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            if ($line.Trim()) { $line | ConvertFrom-Json }
        }
    }
}
function Metric($Value, [bool]$Estimate, [string]$Basis) {
    [ordered]@{ value = $Value; estimate = $Estimate; basis = $Basis }
}
$ledger = @(Read-Rows $UsageLedgerPath)
function Compare-Run([string]$Folder, [string]$Id, [string]$Style) {
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw "Missing run folder: $Folder" }
    if (-not $Id) { $Id = Split-Path -Leaf ([System.IO.Path]::GetFullPath($Folder).TrimEnd('\','/')) }
    $rows = @($ledger | Where-Object { $_.run_id -ceq $Id })
    if (-not $rows.Count) { throw "No collect-usage ledger rows for run $Id" }
    $coordinators = @($rows | Where-Object { $_.role -eq 'orchestrator' } | Sort-Object started)
    $peak = if ($coordinators.Count) { ($coordinators | Measure-Object ctx_max -Maximum).Maximum } else { $null }
    $usage = ($rows | Measure-Object weighted_total -Sum).Sum
    # collect-usage calls count coordinator turns, including turns within the same session.
    $turns = @($coordinators | ForEach-Object {
        if ($_.PSObject.Properties['calls']) { $_.calls }
        elseif ($_.PSObject.Properties['turns']) { $_.turns }
        else { $null }
    })
    $wakes = if ($turns.Count -eq $coordinators.Count -and @($turns | Where-Object { $null -eq $_ }).Count -eq 0) {
        ($turns | Measure-Object -Sum).Sum
    } else { $null }
    $readsPath = Join-Path $Folder 'jobs/reads.jsonl'
    $rereads = $null
    if (Test-Path -LiteralPath $readsPath) {
        $seen = @{}; $rereads = 0
        foreach ($row in @(Read-Rows $readsPath)) {
            $key = @($row.path, $row.sha256, ($row.selector | ConvertTo-Json -Compress -Depth 5)) -join '|'
            if ($seen.ContainsKey($key)) { $rereads++ } else { $seen[$key] = $true }
        }
    }
    $rotations = @(Read-Rows (Join-Path $Folder 'rotations.jsonl'))
    $rotationEvents = @(Read-Rows (Join-Path $Folder 'jobs/events.jsonl') | Where-Object { $_.type -eq 'continuation_requested' -and $_.reason -eq 'context_rotation' })
    $hasRotation = ($rotations.Count -gt 0 -or $rotationEvents.Count -gt 0)
    # The ledger has session totals, not per-request bootstrap cost. The replacement sessions' full
    # usage is an upper-bound proxy, explicitly not an isolated measurement of rotation overhead.
    $rotationCost = if ($hasRotation -and $coordinators.Count -gt 1) {
        ($coordinators | Select-Object -Skip 1 | Measure-Object weighted_total -Sum).Sum
    } elseif (-not $hasRotation) { 0 } else { $null }
    [ordered]@{
        run_id = $Id; style = $Style; run_folder = [System.IO.Path]::GetFullPath($Folder)
        coordinator_peak_context = Metric $peak $true 'Maximum observed orchestrator ctx_max; unsampled peaks unknown'
        total_weighted_usage = Metric $usage $true 'Sum of collect-usage weighted_total; input-equivalent tokens, not subscription cost'
        wake_count = Metric $wakes $true 'Sum of ledger orchestrator calls/turns; null when turn counts are missing; unrecorded turns unknown'
        coordinator_sessions = Metric $coordinators.Count $true 'Ledger orchestrator session count; missing sessions unknown'
        rereads = Metric $rereads $false 'Repeated path/hash/selection in jobs/reads.jsonl; null when absent'
        rotation_cost = Metric $rotationCost $true 'Replacement coordinator session totals; upper-bound proxy for rotation overhead'
    }
}
$runs = @((Compare-Run $OldRunFolder $OldRunId 'old-style'), (Compare-Run $NewRunFolder $NewRunId 'new-style'))
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$result = [ordered]@{ runs = $runs; adoption = 'Per host: peak below hard limit and weighted usage no worse; regressions require Danny recorded acceptance. This comparison does not grant acceptance.' }
$jsonPath = Join-Path $OutputDir 'comparison.json'
$mdPath = Join-Path $OutputDir 'comparison.md'
[System.IO.File]::WriteAllText($jsonPath, ($result | ConvertTo-Json -Depth 8))
$table = @('| Run | Peak context (estimate) | Weighted usage (estimate) | Wakes / turns (estimate) | Coordinator sessions (estimate) | Rereads | Rotation cost (estimate) |', '| :-- | --: | --: | --: | --: | --: | --: |')
foreach ($run in $runs) {
    $values = foreach ($name in @('coordinator_peak_context','total_weighted_usage','wake_count','coordinator_sessions','rereads','rotation_cost')) {
        if ($null -eq $run[$name].value) { 'unknown' } else { [string]$run[$name].value }
    }
    $table += '| ' + $run.run_id + ' | ' + ($values -join ' | ') + ' |'
}
$table += @('', 'Peak is sampled; wakes estimate coordinator turns from ledger calls/turns. Coordinator sessions are reported separately. Rotation cost uses all replacement-session usage as an upper-bound estimate. Missing instrumentation is unknown, never zero.', '', $result.adoption)
[System.IO.File]::WriteAllText($mdPath, ($table -join "`n"))
[ordered]@{ json = $jsonPath; markdown = $mdPath } | ConvertTo-Json -Compress
