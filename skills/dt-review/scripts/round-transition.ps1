Set-StrictMode -Version Latest

function Assert-DtReviewStateTier {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entries,

        [ValidateSet('', 'light', 'complex')]
        [string]$ExpectedTier = '',

        [string]$StatePath = 'review state'
    )

    $observedTiers = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Entries) {
        $roundLabel = if ($entry.PSObject.Properties['round']) { [string]$entry.round } else { '?' }
        if (-not $entry.PSObject.Properties['tier'] -or
            [string]::IsNullOrWhiteSpace([string]$entry.tier)) {
            throw "Review state round $roundLabel has no pinned tier: $StatePath"
        }
        $entryTier = ([string]$entry.tier).ToLowerInvariant()
        if ($entryTier -notin @('light', 'complex')) {
            throw "Review state round $roundLabel has invalid tier '$entryTier': $StatePath"
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedTier) -and $entryTier -cne $ExpectedTier.ToLowerInvariant()) {
            throw "Review state tier mismatch at round ${roundLabel}: state is '$entryTier', caller requested '$ExpectedTier'."
        }
        $observedTiers.Add($entryTier)
    }

    if (@($observedTiers | Select-Object -Unique).Count -gt 1) {
        throw "Review state contains mixed tiers and cannot continue: $StatePath"
    }
}

function Get-DtReviewStateEntries {
    param(
        [Parameter(Mandatory)]
        [string]$StatePath,

        [Nullable[int]]$RequiredLatestRound = $null,

        [ValidateSet('', 'light', 'complex')]
        [string]$ExpectedTier = ''
    )

    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw "Review state not found: $StatePath"
    }

    try {
        $entries = @(Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json)
    }
    catch {
        throw "Review state is not valid JSON: $StatePath. $($_.Exception.Message)"
    }
    if ($entries.Count -eq 0) {
        throw "Review state contains no rounds: $StatePath"
    }
    Assert-DtReviewStateTier -Entries $entries -ExpectedTier $ExpectedTier -StatePath $StatePath

    $rounds = [System.Collections.Generic.List[int]]::new()
    foreach ($entry in $entries) {
        if (-not $entry.PSObject.Properties['round'] -or [string]$entry.round -notmatch '^[1-9][0-9]*$') {
            throw "Review state contains an invalid round identifier: $StatePath"
        }
        $rounds.Add([int]$entry.round)
    }

    $sortedRounds = @($rounds | Sort-Object)
    if (@($sortedRounds | Select-Object -Unique).Count -ne $sortedRounds.Count) {
        throw "Review state contains duplicate round entries: $StatePath"
    }
    for ($index = 0; $index -lt $sortedRounds.Count; $index++) {
        $expected = $index + 1
        if ($sortedRounds[$index] -ne $expected) {
            throw "Review state is noncontiguous: expected round $expected but found round $($sortedRounds[$index])."
        }
    }

    $latestRound = $sortedRounds[-1]
    if ($null -ne $RequiredLatestRound -and $latestRound -ne [int]$RequiredLatestRound) {
        throw "Round $([int]$RequiredLatestRound) is not the latest review state; latest is round $latestRound."
    }

    return @($entries | Sort-Object { [int]$_.round })
}

function Get-DtReviewRoundTransition {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [ValidateRange(1, 99)]
        [int]$Round,

        [Parameter(Mandatory)]
        [ValidateSet('light', 'complex')]
        [string]$Tier,

        [Parameter(Mandatory)]
        [string]$EvaluatorPath
    )

    $Tier = $Tier.ToLowerInvariant()
    $projectRoot = (Resolve-Path -LiteralPath $ProjectPath).Path
    $scratchDir = Join-Path $projectRoot 'design\_review'
    $statePath = Join-Path $scratchDir 'verdicts.json'

    if ($Round -eq 1) {
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            return [pscustomobject]@{
                mode = 'FIRST_ROUND'
                round = 1
                authorization_required = $false
                state_path = $statePath
            }
        }
        $entries = @(Get-DtReviewStateEntries -StatePath $statePath -ExpectedTier $Tier)
        $latest = [int]$entries[-1].round
        if ($latest -ne 1) {
            throw "Round 1 cannot be rerun because latest review state is round $latest."
        }
        return [pscustomobject]@{
            mode = 'SAME_ROUND_RERUN'
            round = 1
            authorization_required = $false
            state_path = $statePath
        }
    }

    $entries = @(Get-DtReviewStateEntries -StatePath $statePath -ExpectedTier $Tier)
    $latest = [int]$entries[-1].round
    if ($Round -eq $latest) {
        return [pscustomobject]@{
            mode = 'SAME_ROUND_RERUN'
            round = $Round
            authorization_required = $false
            state_path = $statePath
        }
    }
    if ($Round -ne ($latest + 1)) {
        throw "Round $Round is not the next contiguous round after latest state round $latest."
    }

    $termination = (& $EvaluatorPath -StatePath $statePath -Round $latest -Tier $Tier) | ConvertFrom-Json
    $authorizationKind = switch ([string]$termination.action) {
        'CONTINUE' { $null }
        'APPLY_POLISH_AND_VERIFY' { $null }
        'USER_DECISION' { 'CAP_EXTENSION' }
        'FINALIZE_CURRENT' { 'POST_TERMINAL_CONFIRMATION' }
        'APPLY_POLISH_AND_FINALIZE' { 'POST_TERMINAL_CONFIRMATION' }
        default { throw "Termination action '$($termination.action)' does not authorize another review round." }
    }

    return [pscustomobject]@{
        mode = 'NEXT_ROUND'
        round = $Round
        source_round = $latest
        source_action = [string]$termination.action
        tier = $Tier
        authorization_required = $null -ne $authorizationKind
        authorization_kind = $authorizationKind
        state_path = $statePath
        state_sha256 = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash.ToUpperInvariant()
    }
}

function Assert-DtReviewRoundAuthorization {
    param(
        [Parameter(Mandatory)]
        [object]$Transition,

        [Parameter(Mandatory)]
        [string]$AuthorizationPath
    )

    if (-not $Transition.authorization_required) { return }
    if (-not (Test-Path -LiteralPath $AuthorizationPath -PathType Leaf)) {
        throw "Round $($Transition.round) requires explicit $($Transition.authorization_kind) authorization: $AuthorizationPath"
    }

    try {
        $authorizations = @(Get-Content -LiteralPath $AuthorizationPath -Raw | ConvertFrom-Json)
    }
    catch {
        throw "Round authorization state is not valid JSON: $AuthorizationPath. $($_.Exception.Message)"
    }
    $matching = @($authorizations | Where-Object { [int]$_.round -eq [int]$Transition.round })
    if ($matching.Count -ne 1) {
        throw "Round $($Transition.round) requires exactly one persisted authorization; found $($matching.Count)."
    }

    $authorization = $matching[0]
    $checks = [ordered]@{
        source_round = [int]$Transition.source_round
        source_action = [string]$Transition.source_action
        tier = [string]$Transition.tier
        authorization_kind = [string]$Transition.authorization_kind
        state_sha256 = [string]$Transition.state_sha256
    }
    foreach ($field in $checks.Keys) {
        if (-not $authorization.PSObject.Properties[$field] -or [string]$authorization.$field -cne [string]$checks[$field]) {
            throw "Round $($Transition.round) authorization does not match current $field. Re-authorize against current state."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$authorization.authorized_by) -or
        [string]::IsNullOrWhiteSpace([string]$authorization.reason)) {
        throw "Round $($Transition.round) authorization must record authorized_by and reason."
    }
}
