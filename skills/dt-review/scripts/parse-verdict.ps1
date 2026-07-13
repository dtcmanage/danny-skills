[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FeedbackPath,

    [int]$Round = 0,

    [string]$StatePath = '',

    [ValidateSet('', 'light', 'complex')]
    [string]$Tier = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Atomic([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = Join-Path $dir ((Split-Path -Leaf $Path) + '.tmp.' + $PID)
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

if (-not (Test-Path -LiteralPath $FeedbackPath -PathType Leaf)) {
    throw "Feedback file not found: $FeedbackPath"
}

$raw = Get-Content -LiteralPath $FeedbackPath -Raw
$verdict = $null
$confidence = $null
$findings = @()
$structured = $null
$structuredPath = [System.IO.Path]::ChangeExtension($FeedbackPath, '.json')

if (Test-Path -LiteralPath $structuredPath -PathType Leaf) {
    try {
        $structured = Get-Content -LiteralPath $structuredPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Structured review JSON is malformed: $structuredPath ($($_.Exception.Message))"
    }
    $verdict = [string]$structured.verdict
    $confidence = [string]$structured.confidence
    $findings = @($structured.findings)
}
else {
    # Read-only compatibility for legacy reviews. Durable state recovery requires
    # the structured artifact because lifecycle semantics cannot be reconstructed
    # safely from rendered Markdown.
    $verdictMatch = [regex]::Match($raw, '(?mi)^\s*VERDICT\s*:\s*([A-Z_]+)\s*$')
    if ($verdictMatch.Success) {
        $verdict = $verdictMatch.Groups[1].Value.Trim()
    }
    $confidenceMatch = [regex]::Match($raw, '(?mi)^\s*Confidence\s*:\s*(high|medium|low)\b')
    if ($confidenceMatch.Success) {
        $confidence = $confidenceMatch.Groups[1].Value.Trim().ToLowerInvariant()
    }
}

$allowed = @('NOTHING_TO_ADD', 'MINOR_POLISH_ONLY', 'MATERIAL_CHANGES_NEEDED')
$isRecognized = $allowed -contains $verdict
$statePersisted = $false
$reparsedIdentical = $false
$reRaisedRejections = @()

if ($Round -gt 0) {
    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        throw 'StatePath is required when parsing a numbered review round.'
    }
    if ([string]::IsNullOrWhiteSpace($Tier)) {
        throw 'Tier is required when parsing a numbered review round so the round budget cannot change mid-review.'
    }
    $Tier = $Tier.ToLowerInvariant()
    if ($null -eq $structured) {
        throw "Round $Round cannot be persisted from Markdown alone. Restore or regenerate the structured review JSON: $structuredPath"
    }

    # The invocation receipt, rather than the caller alone, binds the review to
    # its initial tier. Recheck it on every parse, including an identical
    # same-round recovery parse, so a missing or edited receipt cannot silently
    # change the round budget.
    $metadataPath = Join-Path (Split-Path -Parent $FeedbackPath) ("round-meta-v{0}.json" -f $Round)
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Round metadata not found for numbered review round ${Round}: $metadataPath"
    }
    try {
        $runtimeMetadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Round metadata is not valid JSON: $metadataPath. $($_.Exception.Message)"
    }
    if (-not $runtimeMetadata.PSObject.Properties['round']) {
        throw "Round metadata is missing required property 'round': $metadataPath"
    }
    if (-not $runtimeMetadata.PSObject.Properties['tier'] -or
        [string]::IsNullOrWhiteSpace([string]$runtimeMetadata.tier)) {
        throw "Round metadata is missing required property 'tier': $metadataPath"
    }
    $metadataRound = 0
    if (-not [int]::TryParse([string]$runtimeMetadata.round, [ref]$metadataRound) -or $metadataRound -ne $Round) {
        throw "Round metadata round mismatch: receipt is '$($runtimeMetadata.round)', caller requested '$Round'."
    }
    $metadataTier = [string]$runtimeMetadata.tier
    if (-not [string]::Equals($metadataTier, $Tier, [System.StringComparison]::Ordinal)) {
        throw "Round metadata tier mismatch: receipt is '$metadataTier', caller requested '$Tier'."
    }
    $Tier = $metadataTier

    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    . (Join-Path $ScriptDir 'validate-review-semantics.ps1')
    . (Join-Path $ScriptDir 'round-transition.ps1')

    $entries = @()
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try {
            $existingRaw = Get-Content -LiteralPath $StatePath -Raw
            if (-not [string]::IsNullOrWhiteSpace($existingRaw)) {
                $entries = @($existingRaw | ConvertFrom-Json)
            }
        }
        catch {
            throw "Review state is not valid JSON: $StatePath. $($_.Exception.Message)"
        }
    }
    Assert-DtReviewStateTier -Entries $entries -ExpectedTier $Tier -StatePath $StatePath

    $laterEntries = @($entries | Where-Object { [int]$_.round -gt $Round })
    if ($laterEntries.Count -gt 0) {
        throw "Round $Round cannot be reparsed because later review state already exists."
    }
    $sameRoundEntries = @($entries | Where-Object { [int]$_.round -eq $Round })
    if ($sameRoundEntries.Count -gt 1) {
        throw "Review state contains duplicate round $Round entries."
    }
    $priorEntries = @($entries | Where-Object { [int]$_.round -lt $Round } | Sort-Object { [int]$_.round })
    Assert-DtReviewSemanticHistory -Entries $priorEntries
    $semanticResult = Assert-DtReviewSemantics -Review $structured -Round $Round -PriorEntries $priorEntries
    $reRaisedRejections = @($semanticResult.re_raised_rejections)

    $structuredHash = (Get-FileHash -LiteralPath $structuredPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($sameRoundEntries.Count -eq 1) {
        $priorEntry = $sameRoundEntries[0]
        if (-not $priorEntry.PSObject.Properties['structured_review_sha256'] -or
            [string]::IsNullOrWhiteSpace([string]$priorEntry.structured_review_sha256)) {
            throw "Round $Round state already exists without an immutable structured-review receipt. Refusing recovery overwrite."
        }
        if ([string]$priorEntry.structured_review_sha256 -cne $structuredHash) {
            throw "Round $Round state already exists and review-v$Round.json has changed. Reviewer replay/overwrite is refused; only reparsing the identical structured artifact may preserve state."
        }
        $statePersisted = $true
        $reparsedIdentical = $true
    }
    else {
        $normalizedFindings = foreach ($finding in $findings) {
            [pscustomobject]@{
                id = [string]$finding.id
                status = [string]$finding.status
                title = [string]$finding.title
                dimension = [string]$finding.dimension
                severity = [string]$finding.severity
                blocks_design = [bool]$finding.blocks_design
                root_cause = [string]$finding.root_cause
                remediation = [string]$finding.remediation
                validation_check = [string]$finding.validation_check
                ambiguous_root_cause = [bool]$finding.ambiguous_root_cause
                candidate_dimensions = @($finding.candidate_dimensions)
                missing_evidence = [string]$finding.missing_evidence
                owner_role = [string]$finding.owner_role
                finding_hash = Get-DtReviewFindingHash -Finding $finding
                disposition = ''
                note = ''
                ambiguity_resolution = ''
                user_adjudication = ''
            }
        }

        $entries += [pscustomobject]@{
            round = $Round
            tier = $Tier
            feedback_path = (Resolve-Path -LiteralPath $FeedbackPath).Path
            structured_review_path = (Resolve-Path -LiteralPath $structuredPath).Path
            structured_review_sha256 = $structuredHash
            verdict = $verdict
            confidence = $confidence
            headline = [string]$structured.headline
            dimension_assessments = $structured.dimension_assessments
            engagement_with_prior_reasoning = [string]$structured.engagement_with_prior_reasoning
            confidence_reason = [string]$structured.confidence_reason
            is_recognized_verdict = $isRecognized
            parsed_at_utc = (Get-Date).ToUniversalTime().ToString('o')
            runtime = $runtimeMetadata
            prior_finding_checks = @($structured.prior_finding_checks)
            adjudication_required = $reRaisedRejections.Count -gt 0
            re_raised_rejections = $reRaisedRejections
            adjudication_resolved = $false
            findings = @($normalizedFindings)
        }
        $json = ConvertTo-Json -InputObject @($entries | Sort-Object { [int]$_.round }) -Depth 10
        Write-Atomic -Path $StatePath -Content ($json + "`n")
        $statePersisted = $true
    }
}

[pscustomobject]@{
    verdict = $verdict
    confidence = $confidence
    is_recognized_verdict = $isRecognized
    findings = @($findings).Count
    state_persisted = $statePersisted
    state_path = if ($statePersisted) { (Resolve-Path -LiteralPath $StatePath).Path } else { $null }
    reparsed_identical = $reparsedIdentical
    adjudication_required = $reRaisedRejections.Count -gt 0
    re_raised_rejections = $reRaisedRejections
} | ConvertTo-Json -Depth 4 -Compress
