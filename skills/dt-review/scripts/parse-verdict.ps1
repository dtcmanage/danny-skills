param(
    [Parameter(Mandatory)]
    [string]$FeedbackPath,

    # Optional deterministic round-state persistence. When both -Round and
    # -StatePath are supplied, the parsed verdict is upserted into the scratch
    # verdicts.json (one entry per round, replace-on-rerun) so round N can diff
    # against round N-1 by file read instead of conversation memory. Claude
    # fills each round entry's `findings` array (finding / disposition / note)
    # after reconciliation.
    [int]$Round = 0,

    [string]$StatePath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $FeedbackPath)) {
    throw "Feedback file not found: $FeedbackPath"
}

$raw = Get-Content -LiteralPath $FeedbackPath -Raw
$verdict = $null
$confidence = $null

$verdictMatch = [regex]::Match($raw, '(?mi)^\s*VERDICT\s*:\s*([A-Z_]+)\s*$')
if ($verdictMatch.Success) {
    $verdict = $verdictMatch.Groups[1].Value.Trim()
}

$confidenceMatch = [regex]::Match($raw, '(?mi)^\s*Confidence\s*:\s*(high|medium|low)\b\s*(?:--\s*(.*))?$')
if ($confidenceMatch.Success) {
    $confidence = $confidenceMatch.Groups[1].Value.Trim().ToLowerInvariant()
}

$allowed = @('NOTHING_TO_ADD', 'MINOR_POLISH_ONLY', 'MATERIAL_CHANGES_NEEDED')
$isRecognized = $false
if ($verdict) {
    $isRecognized = $allowed -contains $verdict
}

$statePersisted = $false
if ($Round -gt 0 -and -not [string]::IsNullOrWhiteSpace($StatePath)) {
    $entries = @()
    if (Test-Path -LiteralPath $StatePath) {
        $existingRaw = Get-Content -LiteralPath $StatePath -Raw
        if (-not [string]::IsNullOrWhiteSpace($existingRaw)) {
            $entries = @($existingRaw | ConvertFrom-Json)
        }
    }
    # Preserve any findings Claude already recorded for this round on a rerun.
    $priorEntry = $entries | Where-Object { $_.round -eq $Round } | Select-Object -First 1
    $priorFindings = @()
    if ($null -ne $priorEntry -and $priorEntry.PSObject.Properties['findings']) {
        $priorFindings = @($priorEntry.findings)
    }
    $entries = @($entries | Where-Object { $_.round -ne $Round })
    $entries += [pscustomobject]@{
        round = $Round
        feedback_path = (Resolve-Path -LiteralPath $FeedbackPath).Path
        verdict = $verdict
        confidence = $confidence
        is_recognized_verdict = $isRecognized
        parsed_at_utc = (Get-Date).ToUniversalTime().ToString('o')
        findings = $priorFindings
    }
    $entries = @($entries | Sort-Object -Property round)
    $stateDir = Split-Path -Parent $StatePath
    if ($stateDir -and -not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    ConvertTo-Json -InputObject $entries -Depth 6 | Set-Content -LiteralPath $StatePath -Encoding UTF8
    $statePersisted = $true
}

[pscustomobject]@{
    verdict = $verdict
    confidence = $confidence
    is_recognized_verdict = $isRecognized
    state_persisted = $statePersisted
    state_path = if ($statePersisted) { (Resolve-Path -LiteralPath $StatePath).Path } else { $null }
} | ConvertTo-Json -Compress
