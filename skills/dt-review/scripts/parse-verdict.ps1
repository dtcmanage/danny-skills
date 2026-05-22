param(
    [Parameter(Mandatory)]
    [string]$FeedbackPath
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

[pscustomobject]@{
    verdict = $verdict
    confidence = $confidence
    is_recognized_verdict = $isRecognized
} | ConvertTo-Json -Compress
