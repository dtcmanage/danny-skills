# Dot-source this file, then call Convert-ReviewToMarkdown.
# Single renderer for the structured review JSON, shared by both lane wrappers
# (invoke-codex-round.ps1 and invoke-claude-round.ps1).

Set-StrictMode -Version Latest

function Convert-ReviewToMarkdown([object]$Review) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('## Headline')
    $lines.Add('')
    $lines.Add([string]$Review.headline)
    $lines.Add('')
    $lines.Add('## Dimension Assessments')

    foreach ($pair in @(
        @('Intent', 'intent'),
        @('Completeness', 'completeness'),
        @('Coherence', 'coherence'),
        @('Resilience', 'resilience'),
        @('Economy', 'economy'),
        @('Feasibility', 'feasibility')
    )) {
        $lines.Add('')
        $lines.Add("### $($pair[0])")
        $lines.Add('')
        $lines.Add([string]$Review.dimension_assessments.($pair[1]))
    }

    $lines.Add('')
    $lines.Add('## Prior Finding Checks')
    if (@($Review.prior_finding_checks).Count -eq 0) {
        $lines.Add('')
        $lines.Add('- None (first round).')
    }
    else {
        foreach ($check in @($Review.prior_finding_checks)) {
            $lines.Add('')
            $lines.Add("- $($check.id): $($check.result) - $($check.note)")
        }
    }

    $lines.Add('')
    $lines.Add('## Findings')
    if (@($Review.findings).Count -eq 0) {
        $lines.Add('')
        $lines.Add('- None.')
    }
    else {
        foreach ($finding in @($Review.findings)) {
            $lines.Add('')
            $lines.Add("### $($finding.id) - $($finding.title)")
            $lines.Add('')
            $lines.Add("- Status: $($finding.status)")
            $lines.Add("- Dimension: $($finding.dimension)")
            $lines.Add("- Severity: $($finding.severity)")
            $lines.Add("- Blocks design: $(([string]$finding.blocks_design).ToLowerInvariant())")
            $lines.Add("- Root cause: $($finding.root_cause)")
            $lines.Add("- Remediation: $($finding.remediation)")
            $lines.Add("- Validation check: $($finding.validation_check)")
            $lines.Add("- AMBIGUOUS_ROOT_CAUSE: $(([string]$finding.ambiguous_root_cause).ToLowerInvariant())")
            if (@($finding.candidate_dimensions).Count -gt 0) {
                $lines.Add("- Candidate dimensions: $(@($finding.candidate_dimensions) -join ', ')")
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$finding.missing_evidence)) {
                $lines.Add("- Missing evidence: $($finding.missing_evidence)")
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$finding.owner_role)) {
                $lines.Add("- Owner role: $($finding.owner_role)")
            }
        }
    }

    $lines.Add('')
    $lines.Add("## Engagement with Prior Reasoning")
    $lines.Add('')
    $lines.Add([string]$Review.engagement_with_prior_reasoning)
    $lines.Add('')
    $lines.Add('## Verdict')
    $lines.Add('')
    $lines.Add("VERDICT: $($Review.verdict)")
    $lines.Add("Confidence: $($Review.confidence) -- $($Review.confidence_reason)")
    $lines.Add('')
    return ($lines -join "`n")
}
