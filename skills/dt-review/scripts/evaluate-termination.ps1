[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$StatePath,

    [Parameter(Mandatory)]
    [ValidateRange(1, 99)]
    [int]$Round,

    [Parameter(Mandatory)]
    [ValidateSet('light', 'complex')]
    [string]$Tier
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Tier = $Tier.ToLowerInvariant()

if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    throw "Review state not found: $StatePath"
}

. (Join-Path $PSScriptRoot 'round-transition.ps1')
. (Join-Path $PSScriptRoot 'validate-review-semantics.ps1')
$entries = @(Get-DtReviewStateEntries -StatePath $StatePath -RequiredLatestRound $Round -ExpectedTier $Tier)
Assert-DtReviewStateReceipts -Entries $entries
$entry = $entries[-1]
if (-not $entry.is_recognized_verdict) {
    throw "Round $Round has an unrecognized verdict and cannot advance."
}
if ($entry.PSObject.Properties['adjudication_required'] -and $entry.adjudication_required -and -not $entry.adjudication_resolved) {
    throw "Round $Round has a re-raised rejected finding that still requires user adjudication."
}

$findings = @($entry.findings)
if ($findings.Count -gt 0) {
    $missingDispositions = @($findings | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.disposition) })
    if ($missingDispositions.Count -gt 0) {
        throw "Round $Round cannot advance until every finding has a disposition. Missing: $($missingDispositions.id -join ', ')."
    }
    $openAmbiguities = @($findings | Where-Object {
        $_.ambiguous_root_cause -and [string]::IsNullOrWhiteSpace([string]$_.ambiguity_resolution)
    })
    if ($openAmbiguities.Count -gt 0) {
        throw "Round $Round cannot advance with unresolved AMBIGUOUS_ROOT_CAUSE findings: $($openAmbiguities.id -join ', ')."
    }
}

$cap = if ($Tier -eq 'light') { 3 } else { 6 }
$hasDeferred = @($findings | Where-Object { $_.disposition -eq 'DEFER' }).Count -gt 0
$previous = $entries | Where-Object { $_.round -eq ($Round - 1) } | Select-Object -First 1
$previousWasMinor = $null -ne $previous -and $previous.verdict -eq 'MINOR_POLISH_ONLY'

$action = ''
$reason = ''
switch ([string]$entry.verdict) {
    'NOTHING_TO_ADD' {
        $action = 'FINALIZE_CURRENT'
        $reason = 'The structured review contains no substantive findings.'
    }
    'MINOR_POLISH_ONLY' {
        if ($hasDeferred) {
            $action = if ($Round -ge $cap) { 'USER_DECISION' } else { 'APPLY_POLISH_AND_VERIFY' }
            $reason = 'At least one non-blocking finding was deferred.'
        }
        elseif ($Round -ge $cap -or $previousWasMinor) {
            $action = 'APPLY_POLISH_AND_FINALIZE'
            $reason = if ($Round -ge $cap) {
                'Only non-blocking findings remain at the round cap.'
            }
            else {
                'Two consecutive rounds found only non-blocking polish.'
            }
        }
        else {
            $action = 'APPLY_POLISH_AND_VERIFY'
            $reason = 'Apply the non-blocking fixes, then run one closure check.'
        }
    }
    'MATERIAL_CHANGES_NEEDED' {
        if ($Round -ge $cap) {
            $action = 'USER_DECISION'
            $reason = 'Material findings remain at the round cap; automatic finalization is prohibited.'
        }
        else {
            $action = 'CONTINUE'
            $reason = 'At least one finding still blocks finalization within the round budget.'
        }
    }
}

[pscustomobject]@{
    status = 'ok'
    tier = $Tier
    round = $Round
    cap = $cap
    verdict = [string]$entry.verdict
    action = $action
    reason = $reason
} | ConvertTo-Json -Compress
