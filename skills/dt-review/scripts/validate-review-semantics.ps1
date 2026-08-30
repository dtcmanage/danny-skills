Set-StrictMode -Version Latest

function Get-DtReviewFindingHash {
    param(
        [Parameter(Mandatory)]
        [object]$Finding
    )

    # Lifecycle status is deliberately excluded: it describes the relationship to
    # prior state, not the semantic body that a disposition adjudicates.
    $canonical = [ordered]@{
        id = [string]$Finding.id
        title = [string]$Finding.title
        dimension = [string]$Finding.dimension
        severity = [string]$Finding.severity
        blocks_design = [bool]$Finding.blocks_design
        root_cause = [string]$Finding.root_cause
        remediation = [string]$Finding.remediation
        validation_check = [string]$Finding.validation_check
        ambiguous_root_cause = [bool]$Finding.ambiguous_root_cause
        candidate_dimensions = @($Finding.candidate_dimensions | Sort-Object)
        missing_evidence = [string]$Finding.missing_evidence
        owner_role = [string]$Finding.owner_role
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($canonical | ConvertTo-Json -Depth 5 -Compress))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}

function Assert-DtReviewProperty {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Context
    )

    if (-not $Object.PSObject.Properties[$Name]) {
        throw "$Context is missing required property '$Name'."
    }
}

function Assert-DtReviewSemanticHistory {
    param(
        [AllowEmptyCollection()]
        [object[]]$Entries = @()
    )

    $validated = [System.Collections.Generic.List[object]]::new()
    $ordered = @($Entries | Sort-Object { [int]$_.round })
    for ($index = 0; $index -lt $ordered.Count; $index++) {
        $entry = $ordered[$index]
        Assert-DtReviewProperty -Object $entry -Name 'round' -Context 'Review state entry'
        $expectedRound = $index + 1
        if ([string]$entry.round -notmatch '^[1-9][0-9]*$' -or [int]$entry.round -ne $expectedRound) {
            throw "Review state history is noncontiguous: expected round $expectedRound but found '$($entry.round)'."
        }
        [void](Assert-DtReviewSemantics -Review $entry -Round $expectedRound -PriorEntries @($validated))
        $validated.Add($entry)
    }
}

function Assert-DtReviewSemantics {
    param(
        [Parameter(Mandatory)]
        [object]$Review,

        [Parameter(Mandatory)]
        [ValidateRange(1, 99)]
        [int]$Round,

        [AllowEmptyCollection()]
        [object[]]$PriorEntries = @()
    )

    foreach ($name in @(
        'headline', 'dimension_assessments', 'prior_finding_checks', 'findings',
        'engagement_with_prior_reasoning', 'verdict', 'confidence', 'confidence_reason'
    )) {
        Assert-DtReviewProperty -Object $Review -Name $name -Context "Round $Round review"
    }

    foreach ($name in @('headline', 'engagement_with_prior_reasoning', 'confidence_reason')) {
        if ([string]::IsNullOrWhiteSpace([string]$Review.$name)) {
            throw "Round $Round review requires non-empty '$name'."
        }
    }
    if ([string]$Review.confidence -notin @('high', 'medium', 'low')) {
        throw "Round $Round review has invalid confidence '$($Review.confidence)'."
    }
    foreach ($dimensionName in @('intent', 'completeness', 'coherence', 'resilience', 'economy', 'feasibility')) {
        Assert-DtReviewProperty -Object $Review.dimension_assessments -Name $dimensionName -Context "Round $Round dimension assessments"
        if ([string]::IsNullOrWhiteSpace([string]$Review.dimension_assessments.$dimensionName)) {
            throw "Round $Round dimension assessment '$dimensionName' must be non-empty."
        }
    }

    $orderedPrior = @($PriorEntries | Sort-Object { [int]$_.round })
    for ($index = 0; $index -lt $orderedPrior.Count; $index++) {
        $entry = $orderedPrior[$index]
        Assert-DtReviewProperty -Object $entry -Name 'round' -Context 'Prior review state entry'
        $expectedRound = $index + 1
        if ([string]$entry.round -notmatch '^[1-9][0-9]*$' -or [int]$entry.round -ne $expectedRound) {
            throw "Prior review state is noncontiguous: expected round $expectedRound but found '$($entry.round)'."
        }
        if ([int]$entry.round -ge $Round) {
            throw "Round $Round semantics must be evaluated only against rounds before the current round."
        }
    }
    if ($orderedPrior.Count -ne ($Round - 1)) {
        throw "Round $Round requires exactly $($Round - 1) prior state entries; found $($orderedPrior.Count)."
    }

    $allowedDimensions = @('Intent', 'Completeness', 'Coherence', 'Resilience', 'Economy', 'Feasibility')
    $allowedStatuses = @('NEW', 'PERSISTING', 'REOPENED', 'REGRESSION')
    $allowedSeverities = @('high', 'medium', 'low')
    $allowedResults = @('SATISFIED', 'PERSISTS', 'REGRESSED', 'SUPERSEDED')
    $allowedVerdicts = @('NOTHING_TO_ADD', 'MINOR_POLISH_ONLY', 'MATERIAL_CHANGES_NEEDED')

    $latestPriorById = @{}
    $latestPriorCheckById = @{}
    $settledById = @{}
    foreach ($entry in $orderedPrior) {
        Assert-DtReviewProperty -Object $entry -Name 'findings' -Context "Round $($entry.round) state"
        $entryIds = @{}
        foreach ($prior in @($entry.findings)) {
            Assert-DtReviewProperty -Object $prior -Name 'id' -Context "Round $($entry.round) finding"
            $id = [string]$prior.id
            if ([string]::IsNullOrWhiteSpace($id) -or $entryIds.ContainsKey($id)) {
                throw "Round $($entry.round) state contains a duplicate or empty finding ID '$id'."
            }
            $entryIds[$id] = $true
            $latestPriorById[$id] = $prior
            if ($prior.PSObject.Properties['user_adjudication'] -and
                [string]$prior.user_adjudication -in @('A', 'B', 'C')) {
                # Danny has personally adjudicated this finding. Later re-raises of it are
                # settled: they never demand a fresh adjudication round-trip.
                $settledById[$id] = [string]$prior.user_adjudication
            }
        }
        if ($entry.PSObject.Properties['prior_finding_checks']) {
            foreach ($priorCheck in @($entry.prior_finding_checks)) {
                if ($priorCheck.PSObject.Properties['id']) {
                    $latestPriorCheckById[[string]$priorCheck.id] = $priorCheck
                }
            }
        }
    }

    $findings = @($Review.findings)
    $findingById = @{}
    foreach ($finding in $findings) {
        foreach ($name in @(
            'id', 'status', 'title', 'dimension', 'severity', 'blocks_design', 'root_cause',
            'remediation', 'validation_check', 'ambiguous_root_cause', 'candidate_dimensions',
            'missing_evidence', 'owner_role'
        )) {
            Assert-DtReviewProperty -Object $finding -Name $name -Context "Round $Round finding"
        }

        $id = [string]$finding.id
        if ($id -notmatch '^R[1-9][0-9]*-F[0-9]{2}$' -or $findingById.ContainsKey($id)) {
            throw "Round $Round returned a duplicate or invalid finding ID '$id'."
        }
        $findingById[$id] = $finding

        if ($allowedStatuses -notcontains [string]$finding.status) {
            throw "Finding '$id' has invalid lifecycle status '$($finding.status)'."
        }
        if ($allowedDimensions -notcontains [string]$finding.dimension) {
            throw "Finding '$id' has invalid dimension '$($finding.dimension)'."
        }
        if ($allowedSeverities -notcontains [string]$finding.severity) {
            throw "Finding '$id' has invalid severity '$($finding.severity)'."
        }
        foreach ($name in @('title', 'root_cause', 'remediation', 'validation_check')) {
            if ([string]::IsNullOrWhiteSpace([string]$finding.$name)) {
                throw "Finding '$id' requires non-empty '$name'."
            }
        }
        if ([string]$finding.severity -eq 'high' -and [string]::IsNullOrWhiteSpace([string]$finding.owner_role)) {
            throw "High-severity finding '$id' requires a non-empty owner_role."
        }
        if ($finding.blocks_design -isnot [bool] -or $finding.ambiguous_root_cause -isnot [bool]) {
            throw "Finding '$id' requires boolean blocks_design and ambiguous_root_cause values."
        }

        $candidateDimensions = @($finding.candidate_dimensions)
        if (@($candidateDimensions | Sort-Object -Unique).Count -ne $candidateDimensions.Count) {
            throw "Finding '$id' names duplicate candidate dimensions."
        }
        if (@($candidateDimensions | Where-Object { $allowedDimensions -notcontains [string]$_ }).Count -gt 0) {
            throw "Finding '$id' names an invalid candidate dimension."
        }
        if ([bool]$finding.ambiguous_root_cause) {
            if ($candidateDimensions.Count -ne 2 -or [string]::IsNullOrWhiteSpace([string]$finding.missing_evidence)) {
                throw "Finding '$id' is AMBIGUOUS_ROOT_CAUSE and requires exactly two candidate dimensions plus missing_evidence."
            }
        }
        elseif ($candidateDimensions.Count -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$finding.missing_evidence)) {
            throw "Finding '$id' provides ambiguity evidence without AMBIGUOUS_ROOT_CAUSE."
        }
    }

    $checks = @($Review.prior_finding_checks)
    $checkById = @{}
    foreach ($check in $checks) {
        foreach ($name in @('id', 'result', 'note')) {
            Assert-DtReviewProperty -Object $check -Name $name -Context "Round $Round prior finding check"
        }
        $id = [string]$check.id
        if ($id -notmatch '^R[1-9][0-9]*-F[0-9]{2}$' -or $checkById.ContainsKey($id)) {
            throw "Round $Round returned a duplicate or invalid prior_finding_checks ID '$id'."
        }
        if ($allowedResults -notcontains [string]$check.result) {
            throw "Prior finding check '$id' has invalid result '$($check.result)'."
        }
        if ([string]::IsNullOrWhiteSpace([string]$check.note)) {
            throw "Prior finding check '$id' requires an evidence note."
        }
        $checkById[$id] = $check
    }

    $expectedPriorIds = @($latestPriorById.Keys | Sort-Object)
    $actualPriorIds = @($checkById.Keys | Sort-Object)
    $missingChecks = @($expectedPriorIds | Where-Object { -not $checkById.ContainsKey($_) })
    $extraChecks = @($actualPriorIds | Where-Object { -not $latestPriorById.ContainsKey($_) })
    if ($missingChecks.Count -gt 0 -or $extraChecks.Count -gt 0) {
        throw "Prior finding check coverage mismatch. Missing: $($missingChecks -join ', '); extra: $($extraChecks -join ', ')."
    }

    $reRaisedRejections = [System.Collections.Generic.List[string]]::new()
    $settledReRaises = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $expectedPriorIds) {
        $prior = $latestPriorById[$id]
        $check = $checkById[$id]
        $current = if ($findingById.ContainsKey($id)) { $findingById[$id] } else { $null }
        $priorDisposition = if ($prior.PSObject.Properties['disposition']) { [string]$prior.disposition } else { '' }

        switch ([string]$check.result) {
            'SATISFIED' {
                if ($null -ne $current) { throw "Satisfied prior finding '$id' must not also be emitted as current." }
            }
            'SUPERSEDED' {
                if ($null -ne $current) { throw "Superseded prior finding '$id' must not also be emitted as current." }
            }
            'PERSISTS' {
                if ($null -eq $current) { throw "Persistent prior finding '$id' must be emitted as a current finding." }
                $requiredStatus = if ($priorDisposition -eq 'REJECT') { 'REOPENED' } else { 'PERSISTING' }
                if ([string]$current.status -ne $requiredStatus) {
                    throw "Persistent prior finding '$id' with prior disposition '$priorDisposition' must be labeled $requiredStatus."
                }
                if ($priorDisposition -eq 'REJECT') {
                    if ($settledById.ContainsKey($id)) {
                        # Already adjudicated by Danny in an earlier round. The re-raise is
                        # settled: the orchestrator auto-disposes it citing the recorded
                        # adjudication instead of asking again.
                        $settledReRaises.Add($id)
                    }
                    else {
                        $reRaisedRejections.Add($id)
                    }
                }
            }
            'REGRESSED' {
                if ($priorDisposition -notin @('ACCEPT', 'COUNTER')) {
                    throw "Regressed prior finding '$id' requires a previous ACCEPT or COUNTER disposition, not '$priorDisposition'."
                }
                $latestClosure = if ($latestPriorCheckById.ContainsKey($id)) {
                    [string]$latestPriorCheckById[$id].result
                }
                else { '' }
                $immediatelyPriorHasFinding = $orderedPrior.Count -gt 0 -and
                    @($orderedPrior[-1].findings | Where-Object { [string]$_.id -eq $id }).Count -gt 0
                if ($latestClosure -notin @('SATISFIED', 'SUPERSEDED') -or $immediatelyPriorHasFinding) {
                    throw "Regressed prior finding '$id' must have been closed by a prior SATISFIED or SUPERSEDED check before it can regress."
                }
                if ($null -eq $current -or [string]$current.status -ne 'REGRESSION') {
                    throw "Regressed prior finding '$id' must be emitted once as REGRESSION."
                }
            }
        }
    }

    foreach ($finding in $findings) {
        $id = [string]$finding.id
        $isKnown = $latestPriorById.ContainsKey($id)
        if (-not $isKnown) {
            if ([string]$finding.status -ne 'NEW') {
                throw "Finding '$id' is new to state but is labeled '$($finding.status)'."
            }
            if ($id -notmatch ("^R{0}-F[0-9]{{2}}$" -f $Round)) {
                throw "New finding '$id' must use the current-round R$Round-FNN prefix."
            }
        }
        elseif (-not $checkById.ContainsKey($id)) {
            throw "Known finding '$id' has no prior_finding_checks row."
        }
    }

    $expectedVerdict = if ($findings.Count -eq 0) {
        'NOTHING_TO_ADD'
    }
    elseif (@($findings | Where-Object { [bool]$_.blocks_design }).Count -gt 0) {
        'MATERIAL_CHANGES_NEEDED'
    }
    else {
        'MINOR_POLISH_ONLY'
    }
    if ($allowedVerdicts -notcontains [string]$Review.verdict) {
        throw "Round $Round has invalid verdict '$($Review.verdict)'."
    }
    if ([string]$Review.verdict -ne $expectedVerdict) {
        throw "VERDICT_FINDING_MISMATCH: blocks_design values require '$expectedVerdict' but the review returned '$($Review.verdict)'."
    }

    return [pscustomobject]@{
        expected_verdict = $expectedVerdict
        finding_count = $findings.Count
        re_raised_rejections = @($reRaisedRejections | Sort-Object -Unique)
        settled_re_raises = @($settledReRaises | Sort-Object -Unique)
    }
}

function ConvertTo-DtReviewSemanticProjection {
    param(
        [Parameter(Mandatory)]
        [object]$Review
    )

    $dimensions = [ordered]@{}
    foreach ($name in @('intent', 'completeness', 'coherence', 'resilience', 'economy', 'feasibility')) {
        $dimensions[$name] = [string]$Review.dimension_assessments.$name
    }

    $checks = @(
        foreach ($check in @($Review.prior_finding_checks)) {
            [ordered]@{
                id = [string]$check.id
                result = [string]$check.result
                note = [string]$check.note
            }
        }
    )
    $findings = @(
        foreach ($finding in @($Review.findings)) {
            [ordered]@{
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
                candidate_dimensions = @($finding.candidate_dimensions | ForEach-Object { [string]$_ })
                missing_evidence = [string]$finding.missing_evidence
                owner_role = [string]$finding.owner_role
            }
        }
    )

    return [ordered]@{
        headline = [string]$Review.headline
        dimension_assessments = $dimensions
        prior_finding_checks = $checks
        findings = $findings
        engagement_with_prior_reasoning = [string]$Review.engagement_with_prior_reasoning
        verdict = [string]$Review.verdict
        confidence = [string]$Review.confidence
        confidence_reason = [string]$Review.confidence_reason
    }
}

function Get-DtReviewCanonicalSemanticJson {
    param(
        [Parameter(Mandatory)]
        [object]$Review
    )

    return (ConvertTo-DtReviewSemanticProjection -Review $Review | ConvertTo-Json -Depth 10 -Compress)
}

function Get-DtReviewOptionalString {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($Object.PSObject.Properties[$Name]) { return [string]$Object.$Name }
    return ''
}

function Assert-DtReviewStructuredReceipts {
    param(
        [AllowEmptyCollection()]
        [object[]]$Entries = @()
    )

    $ordered = @($Entries | Sort-Object { [int]$_.round })
    for ($index = 0; $index -lt $ordered.Count; $index++) {
        $entry = $ordered[$index]
        $round = [int]$entry.round
        foreach ($name in @('structured_review_path', 'structured_review_sha256')) {
            if (-not $entry.PSObject.Properties[$name] -or
                [string]::IsNullOrWhiteSpace([string]$entry.$name)) {
                throw "Round $round is missing immutable structured review receipt '$name'."
            }
        }

        $artifactPath = [string]$entry.structured_review_path
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw "Round $round structured review receipt artifact not found: $artifactPath"
        }
        $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ([string]$entry.structured_review_sha256 -cne $actualHash) {
            throw "Round $round structured review receipt SHA-256 mismatch. The artifact or state was changed after parsing."
        }
        try {
            $artifact = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
        }
        catch {
            throw "Round $round structured review receipt is not valid JSON: $artifactPath. $($_.Exception.Message)"
        }

        $priorEntries = if ($index -gt 0) { @($ordered[0..($index - 1)]) } else { @() }
        [void](Assert-DtReviewSemantics -Review $artifact -Round $round -PriorEntries $priorEntries)
        $artifactCanonical = Get-DtReviewCanonicalSemanticJson -Review $artifact
        $stateCanonical = Get-DtReviewCanonicalSemanticJson -Review $entry
        if ($artifactCanonical -cne $stateCanonical) {
            throw "Round $round structured review semantic body does not match persisted state. Explicit state repair is required."
        }

        foreach ($finding in @($entry.findings)) {
            if (-not $finding.PSObject.Properties['finding_hash'] -or
                [string]::IsNullOrWhiteSpace([string]$finding.finding_hash)) {
                throw "Round $round finding '$($finding.id)' is missing its semantic finding hash."
            }
            $expectedFindingHash = Get-DtReviewFindingHash -Finding $finding
            if ([string]$finding.finding_hash -cne $expectedFindingHash) {
                throw "Round $round finding '$($finding.id)' semantic hash does not match persisted state."
            }
        }
    }
}

function Assert-DtReviewDispositionReceipts {
    param(
        [AllowEmptyCollection()]
        [object[]]$Entries = @()
    )

    $allowed = @('ACCEPT', 'REJECT', 'DEFER', 'COUNTER')
    $adjudicationDisposition = @{ A = 'ACCEPT'; B = 'REJECT'; C = 'DEFER' }
    foreach ($entry in @($Entries | Sort-Object { [int]$_.round })) {
        $round = [int]$entry.round
        $findings = @($entry.findings)
        if ($findings.Count -eq 0) { continue }

        foreach ($name in @('dispositions_path', 'dispositions_sha256')) {
            if (-not $entry.PSObject.Properties[$name] -or
                [string]::IsNullOrWhiteSpace([string]$entry.$name)) {
                throw "Round $round is missing immutable disposition receipt '$name'."
            }
        }
        $artifactPath = [string]$entry.dispositions_path
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw "Round $round disposition receipt artifact not found: $artifactPath"
        }
        $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ([string]$entry.dispositions_sha256 -cne $actualHash) {
            throw "Round $round disposition receipt SHA-256 mismatch. The artifact or state was changed after reconciliation."
        }
        try {
            $artifactItems = @(Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json)
        }
        catch {
            throw "Round $round disposition receipt is not valid JSON: $artifactPath. $($_.Exception.Message)"
        }

        $byId = @{}
        foreach ($item in $artifactItems) {
            if (-not $item.PSObject.Properties['id']) {
                throw "Round $round disposition receipt contains an item without an ID."
            }
            $id = [string]$item.id
            if ([string]::IsNullOrWhiteSpace($id) -or $byId.ContainsKey($id)) {
                throw "Round $round disposition receipt contains a duplicate or empty ID '$id'."
            }
            $byId[$id] = $item
        }

        $findingIds = @($findings | ForEach-Object { [string]$_.id })
        $missing = @($findingIds | Where-Object { -not $byId.ContainsKey($_) })
        $extra = @($byId.Keys | Where-Object { $findingIds -notcontains $_ })
        if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
            throw "Round $round disposition receipt coverage mismatch. Missing: $($missing -join ', '); extra: $($extra -join ', ')."
        }

        $reRaised = if ($entry.PSObject.Properties['re_raised_rejections']) {
            @($entry.re_raised_rejections | ForEach-Object { [string]$_ })
        }
        else { @() }
        foreach ($finding in $findings) {
            $id = [string]$finding.id
            $item = $byId[$id]
            foreach ($required in @('disposition', 'note')) {
                if (-not $item.PSObject.Properties[$required]) {
                    throw "Round $round disposition receipt finding '$id' is missing '$required'."
                }
            }

            $disposition = [string]$item.disposition
            $note = [string]$item.note
            $ambiguityResolution = Get-DtReviewOptionalString -Object $item -Name 'ambiguity_resolution'
            $userAdjudication = Get-DtReviewOptionalString -Object $item -Name 'user_adjudication'
            if ($allowed -notcontains $disposition -or [string]::IsNullOrWhiteSpace($note)) {
                throw "Round $round disposition receipt finding '$id' is incomplete or invalid."
            }
            if ([bool]$finding.ambiguous_root_cause -and [string]::IsNullOrWhiteSpace($ambiguityResolution)) {
                throw "Round $round disposition receipt finding '$id' requires ambiguity_resolution."
            }
            if ($reRaised -contains $id) {
                if ($userAdjudication -notin @('A', 'B', 'C') -or
                    $disposition -cne $adjudicationDisposition[$userAdjudication]) {
                    throw "Round $round disposition receipt finding '$id' has an invalid user adjudication."
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($userAdjudication)) {
                throw "Round $round disposition receipt finding '$id' records user_adjudication without a re-raised rejection."
            }

            foreach ($comparison in ([ordered]@{
                disposition = $disposition
                note = $note
                ambiguity_resolution = $ambiguityResolution
                user_adjudication = $userAdjudication
            }).GetEnumerator()) {
                $persisted = Get-DtReviewOptionalString -Object $finding -Name ([string]$comparison.Key)
                if ($persisted -cne [string]$comparison.Value) {
                    throw "Round $round persisted disposition field '$id.$($comparison.Key)' does not match its immutable artifact receipt."
                }
            }
        }

        if ($entry.PSObject.Properties['adjudication_required'] -and [bool]$entry.adjudication_required -and
            (-not $entry.PSObject.Properties['adjudication_resolved'] -or -not [bool]$entry.adjudication_resolved)) {
            throw "Round $round has unresolved user adjudication in persisted state."
        }
    }
}

function Assert-DtReviewStateReceipts {
    param(
        [AllowEmptyCollection()]
        [object[]]$Entries = @()
    )

    Assert-DtReviewSemanticHistory -Entries $Entries
    Assert-DtReviewStructuredReceipts -Entries $Entries
    Assert-DtReviewDispositionReceipts -Entries $Entries
}
