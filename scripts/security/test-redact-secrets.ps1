# test-redact-secrets.ps1
# Corpus test runner for redact-secrets.ps1 (Control 4 acceptance harness).
# Resolves all paths from $PSScriptRoot (never the cwd). Exits 0 only when
# leaks == 0 AND false-positive rate < 0.05; otherwise prints failures and exits 1.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# From scripts/security/, the repo root is two levels up.
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$CorpusPath = Join-Path $RepoRoot 'references\security-redaction-tests.md'

# Load the canonical redaction module from the same directory as this script.
. (Join-Path $PSScriptRoot 'redact-secrets.ps1')

if (-not (Test-Path -LiteralPath $CorpusPath)) {
    Write-Output "ERROR: corpus file not found: $CorpusPath"
    exit 1
}

$corpusLines = Get-Content -LiteralPath $CorpusPath

# Extract the non-blank, non-HTML-comment lines between a begin/end marker pair.
function Get-Fixtures {
    param(
        [string[]]$Lines,
        [string]$BeginMarker,
        [string]$EndMarker
    )

    $fixtures = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq $BeginMarker) {
            $inBlock = $true
            continue
        }
        if ($trimmed -eq $EndMarker) {
            $inBlock = $false
            continue
        }
        if (-not $inBlock) { continue }
        if ($trimmed -eq '') { continue }
        if ($trimmed.StartsWith('<!--')) { continue }
        $fixtures.Add($line)
    }
    return $fixtures
}

# A literal two-character backslash-n in a fixture encodes a real newline.
function Expand-Newlines {
    param([string]$Value)
    return $Value.Replace('\n', "`n")
}

$mustRedact = Get-Fixtures -Lines $corpusLines `
    -BeginMarker '<!-- MUST-REDACT-BEGIN -->' -EndMarker '<!-- MUST-REDACT-END -->'
$mustNotRedact = Get-Fixtures -Lines $corpusLines `
    -BeginMarker '<!-- MUST-NOT-REDACT-BEGIN -->' -EndMarker '<!-- MUST-NOT-REDACT-END -->'

$totalMustRedact = $mustRedact.Count
$totalMustNotRedact = $mustNotRedact.Count

$leaks = New-Object System.Collections.Generic.List[string]
foreach ($fixture in $mustRedact) {
    $expanded = Expand-Newlines $fixture
    $output = Invoke-SecretRedaction -Text $expanded
    if ($output -eq $expanded) {
        $leaks.Add($fixture)
    }
}

$falsePositives = New-Object System.Collections.Generic.List[string]
foreach ($fixture in $mustNotRedact) {
    $expanded = Expand-Newlines $fixture
    $output = Invoke-SecretRedaction -Text $expanded
    if ($output -ne $expanded) {
        $falsePositives.Add($fixture)
    }
}

$leakCount = $leaks.Count
$fpCount = $falsePositives.Count
if ($totalMustNotRedact -gt 0) {
    $fpRate = $fpCount / $totalMustNotRedact
} else {
    $fpRate = 0
}

Write-Output "Redaction corpus results"
Write-Output "  must-redact fixtures: $totalMustRedact  leaks: $leakCount"
Write-Output "  must-not-redact fixtures: $totalMustNotRedact  false positives: $fpCount"
Write-Output ("  false-positive rate: {0:P2}" -f $fpRate)

if ($leakCount -gt 0) {
    Write-Output "LEAKS (must-redact fixtures returned unchanged):"
    foreach ($leak in $leaks) { Write-Output "  - $leak" }
}
if ($fpCount -gt 0) {
    Write-Output "FALSE POSITIVES (safe fixtures that changed):"
    foreach ($fp in $falsePositives) { Write-Output "  - $fp" }
}

$summary = "leaks=$leakCount, false_positives=$fpCount, fp_rate=" + ("{0:P2}" -f $fpRate)
if (($leakCount -eq 0) -and ($fpRate -lt 0.05)) {
    Write-Output "$summary; PASS"
    exit 0
} else {
    Write-Output "$summary; FAIL"
    exit 1
}
