[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectPath,

    [Parameter(Mandatory)]
    [ValidateRange(1, 99)]
    [int]$Round,

    [Parameter(Mandatory)]
    [ValidateSet('light', 'complex')]
    [string]$Tier,

    # Prompt budget in UTF-8 bytes. The binding constraint is the model's context window, not a
    # fixed byte count: cumulative state (verdicts.json) and the draft both grow every round, so a
    # long review legitimately produces a large prompt. The default is a runaway guard set well
    # below the pinned models' capacity - roughly 225k tokens at ~4 bytes/token - not a target.
    # Override per call, or globally with DT_REVIEW_MAX_PROMPT_BYTES.
    [ValidateRange(50000, 4000000)]
    [int]$MaxPromptBytes = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Atomic([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = Join-Path $dir ((Split-Path -Leaf $Path) + '.tmp.' + $PID)
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
    throw "Project path not found: $ProjectPath"
}

$projectRoot = (Resolve-Path -LiteralPath $ProjectPath).Path
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir
$resolved = (Get-Item -LiteralPath $SkillRoot).ResolveLinkTarget($true)
if ($resolved) { $SkillRoot = $resolved.FullName }
$RepoRoot = Split-Path -Parent (Split-Path -Parent $SkillRoot)

. (Join-Path $RepoRoot 'scripts\wrap-prompt-envelope.ps1')

$scratchDir = Join-Path $projectRoot 'design\_review'
$promptDir = Join-Path $scratchDir 'prompts'
$draftPath = Join-Path $scratchDir ("draft-v{0}.md" -f $Round)
$promptPath = Join-Path $promptDir ("codex-critique-prompt-v{0}.md" -f $Round)
$dimensionPath = Join-Path $RepoRoot 'references\canonical-dimension-contract.md'
$statePath = Join-Path $scratchDir 'verdicts.json'
$authorizationPath = Join-Path $scratchDir 'round-authorizations.json'

. (Join-Path $ScriptDir 'round-transition.ps1')
$transition = Get-DtReviewRoundTransition `
    -ProjectPath $projectRoot `
    -Round $Round `
    -Tier $Tier `
    -EvaluatorPath (Join-Path $ScriptDir 'evaluate-termination.ps1')
Assert-DtReviewRoundAuthorization -Transition $transition -AuthorizationPath $authorizationPath

foreach ($required in @($draftPath, $dimensionPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required review input not found: $required"
    }
}

$previousReviewPath = $null
if ($Round -gt 1) {
    $previousReviewPath = Join-Path $scratchDir ("review-v{0}.md" -f ($Round - 1))
    foreach ($required in @($previousReviewPath, $statePath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Round $Round cannot be assembled because prior state is missing: $required"
        }
    }
}

$draft = Get-Content -LiteralPath $draftPath -Raw
$dimensions = Get-Content -LiteralPath $dimensionPath -Raw
$draftEnvelope = New-PromptEnvelope -Label "CURRENT DRAFT V$Round" -Content $draft

$parts = [System.Collections.Generic.List[string]]::new()
$parts.Add(@"
You are the independent reviewer in an adversarial architecture review, running as the opposite
model family from the draft's author.
Review the embedded current draft; do not edit files or attempt to read the workspace.

Round: $Round

Review rules:
- Evaluate all six canonical dimensions. Be skeptical, concrete, and proportionate.
- Do not manufacture findings to keep the dialogue running. A clean design is a valid result.
- Surface every issue you can establish from the current evidence now; do not knowingly serialize findings across later rounds.
- For a new finding, assign the next ID in this round as R$Round-F01, R$Round-F02, and so on, with status NEW.
- Reuse the original finding ID when the same root cause persists or is raised again. Use PERSISTING when it remains unresolved, REOPENED after a prior rejection, and REGRESSION when a previously satisfied commitment later disappeared. Do not mint a new ID for rewording.
- Compare the current draft against every prior ACCEPT/COUNTER commitment in the cumulative finding ledger, not only the immediately prior review.
- Emit one prior_finding_checks row for every finding ID in the cumulative finding ledger (empty in Round 1): SATISFIED, PERSISTS, REGRESSED, or SUPERSEDED, with evidence in note.
- IDs in the SETTLED USER DECISIONS envelope were personally adjudicated by the user; that decision is final. Do not re-litigate one unless you hold specific new evidence the adjudication did not consider. Without such evidence, emit its prior_finding_checks row as SUPERSEDED with note 'Settled by user adjudication' and do not emit it as a finding; a re-raise without new evidence is auto-rejected citing the adjudication.
- If a prior REJECTed issue still persists, reuse its ID with status REOPENED. If an ACCEPT/COUNTER commitment disappeared, reuse its ID with status REGRESSION.
- Set ambiguous_root_cause only when the canonical tie-break genuinely cannot reduce the issue to one dimension.
- High severity requires both large impact and hard reversibility. Medium requires either. Low is limited and reversible.
- Set blocks_design when the current design should not be finalized until the finding is resolved. Severity and blocking are separate: a medium build-spec clarification may be non-blocking, while a low contradiction in a required contract can still block finalization.
- Every high-severity finding must name the accountable owner_role; otherwise use an empty string.
- Keep each dimension assessment concise. Put actionable detail in findings.
- Treat claims about live systems, current APIs, schemas, or data as unverified unless the embedded draft provides evidence. Flag a material unsupported assumption; do not invent current state.

Derive the verdict mechanically from blocks_design:
- No findings -> NOTHING_TO_ADD.
- Findings exist and none blocks the design -> MINOR_POLISH_ONLY.
- Any finding with blocks_design=true -> MATERIAL_CHANGES_NEEDED.

Return only the JSON object required by the supplied output schema.
"@.Trim())
$parts.Add("=== BEGIN CANONICAL DIMENSION CONTRACT ===`n$dimensions`n=== END CANONICAL DIMENSION CONTRACT ===")
$parts.Add($draftEnvelope)

$contextPath = Join-Path $scratchDir 'review-context.md'
$buildIntakeWarning = ''
if (Test-Path -LiteralPath $contextPath -PathType Leaf) {
    $context = Get-Content -LiteralPath $contextPath -Raw
    $parts.Add((New-PromptEnvelope -Label 'CODE AND CONSTRAINT EVIDENCE MAP' -Content $context))

    # finalize-review.ps1 refuses a final design that omits this heading whenever an evidence
    # map exists, and by then the reviewed draft is hash-bound and cannot be repaired in-flow.
    # Round 1 is the hard gate: the table is cheap to add before any review has run, and a
    # converged review can never be restarted just to import its own evidence. Later rounds
    # (a mid-review evidence map) warn while the next draft is still being authored.
    if ($draft -notmatch '(?mi)^## Build-intake revalidation\s*$') {
        $buildIntakeWarning = "draft-v$Round.md has no '## Build-intake revalidation' section, but review-context.md exists. finalize-review.ps1 will refuse the final design without it, and the terminal reviewed draft cannot be edited. Carry the table into the next draft."
        if ($Round -eq 1) {
            throw "BUILD_INTAKE_GATE: draft-v1.md must contain a '## Build-intake revalidation' section because review-context.md exists. Author the table into the draft (every live-data assumption with its verification query, observed value, and check date) before Round 1."
        }
        Write-Warning $buildIntakeWarning
    }
}

if ($previousReviewPath) {
    $priorReview = Get-Content -LiteralPath $previousReviewPath -Raw
    try {
        $stateEntries = @(Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json)
    }
    catch {
        throw "Review state is not valid JSON: $statePath. $($_.Exception.Message)"
    }

    # Rolling context: the full prior review/response is embedded verbatim, but older rounds
    # contribute only a condensed per-finding ledger. Cumulative state re-embedded whole grows
    # the prompt every round (observed 81KB -> 274KB over nine rounds) while adding no new
    # information; the ledger keeps every finding ID, lifecycle position, and open commitment
    # while dropping repeated prose.
    $latestById = [ordered]@{}
    $latestCheckById = @{}
    $settledMap = @{}
    $roundSummaries = [System.Collections.Generic.List[object]]::new()
    foreach ($stateEntry in @($stateEntries | Sort-Object { [int]$_.round })) {
        foreach ($stateFinding in @($stateEntry.findings)) {
            $latestById[[string]$stateFinding.id] = [pscustomobject]@{
                round = [int]$stateEntry.round
                finding = $stateFinding
            }
            if ($stateFinding.PSObject.Properties['user_adjudication'] -and
                [string]$stateFinding.user_adjudication -in @('B', 'C')) {
                $settledMap[[string]$stateFinding.id] = [pscustomobject]@{
                    adjudication = [string]$stateFinding.user_adjudication
                    rationale = if ($stateFinding.PSObject.Properties['note']) { [string]$stateFinding.note } else { '' }
                }
            }
        }
        if ($stateEntry.PSObject.Properties['prior_finding_checks']) {
            foreach ($stateCheck in @($stateEntry.prior_finding_checks)) {
                if ($stateCheck.PSObject.Properties['id']) {
                    $latestCheckById[[string]$stateCheck.id] = [string]$stateCheck.result
                }
            }
        }
        $roundSummaries.Add([ordered]@{
            round = [int]$stateEntry.round
            verdict = [string]$stateEntry.verdict
            findings = @($stateEntry.findings).Count
        })
    }

    $ledgerRows = [System.Collections.Generic.List[object]]::new()
    $settledRows = [System.Collections.Generic.List[object]]::new()
    foreach ($ledgerId in @($latestById.Keys)) {
        $record = $latestById[$ledgerId]
        $ledgerFinding = $record.finding
        $disposition = if ($ledgerFinding.PSObject.Properties['disposition']) { [string]$ledgerFinding.disposition } else { '' }
        $note = if ($ledgerFinding.PSObject.Properties['note']) { [string]$ledgerFinding.note } else { '' }
        $row = [ordered]@{
            id = $ledgerId
            title = [string]$ledgerFinding.title
            dimension = [string]$ledgerFinding.dimension
            severity = [string]$ledgerFinding.severity
            blocks_design = [bool]$ledgerFinding.blocks_design
            last_seen_round = [int]$record.round
            last_status = [string]$ledgerFinding.status
            latest_check = if ($latestCheckById.ContainsKey($ledgerId)) { $latestCheckById[$ledgerId] } else { '' }
            disposition = $disposition
            disposition_note = $note
        }
        if ($disposition -in @('ACCEPT', 'COUNTER')) {
            # Open or applied commitments stay regression-checkable: keep the text the
            # reviewer must verify against the draft.
            $row['remediation'] = [string]$ledgerFinding.remediation
            $row['validation_check'] = [string]$ledgerFinding.validation_check
        }
        $ledgerRows.Add([pscustomobject]$row)
        if ($settledMap.ContainsKey($ledgerId)) {
            $settled = $settledMap[$ledgerId]
            $settledRows.Add([pscustomobject][ordered]@{
                id = $ledgerId
                title = [string]$ledgerFinding.title
                adjudication = [string]$settled.adjudication
                decision = if ([string]$settled.adjudication -eq 'B') { 'rejection upheld by user' } else { 'deferred as an open question by user' }
                rationale = [string]$settled.rationale
            })
        }
    }

    $ledgerPayload = [ordered]@{
        rounds = @($roundSummaries)
        findings = @($ledgerRows)
    }
    $parts.Add((New-PromptEnvelope -Label "PRIOR ROUND REVIEW AND ORCHESTRATOR RESPONSE" -Content $priorReview))
    $parts.Add((New-PromptEnvelope -Label "CUMULATIVE FINDING LEDGER" -Content (ConvertTo-Json -InputObject $ledgerPayload -Depth 6)))
    if ($settledRows.Count -gt 0) {
        $parts.Add((New-PromptEnvelope -Label "SETTLED USER DECISIONS" -Content (ConvertTo-Json -InputObject @($settledRows) -Depth 4)))
    }
}

$prompt = ($parts -join "`n`n") + "`n"
$promptBytes = [System.Text.Encoding]::UTF8.GetByteCount($prompt)

$promptBudget = 900000
if ($MaxPromptBytes -gt 0) {
    $promptBudget = $MaxPromptBytes
}
elseif (-not [string]::IsNullOrWhiteSpace($env:DT_REVIEW_MAX_PROMPT_BYTES)) {
    $parsedBudget = 0
    if (-not [int]::TryParse($env:DT_REVIEW_MAX_PROMPT_BYTES, [ref]$parsedBudget) -or
        $parsedBudget -lt 50000 -or $parsedBudget -gt 4000000) {
        throw "DT_REVIEW_MAX_PROMPT_BYTES must be an integer between 50000 and 4000000; got '$($env:DT_REVIEW_MAX_PROMPT_BYTES)'."
    }
    $promptBudget = $parsedBudget
}

# Warn before the wall, not at it. Cumulative state grows every round, so a review that crosses
# the warning line will usually exceed the budget a round or two later - and by then the only
# compactable input (review-context.md) may not be large enough to recover the difference.
$promptBudgetWarning = ''
if ($promptBytes -gt $promptBudget) {
    throw "Review prompt is $promptBytes bytes against a $promptBudget budget. Compact review-context.md, or raise the budget with -MaxPromptBytes / DT_REVIEW_MAX_PROMPT_BYTES once you have confirmed the pinned model can carry it."
}
elseif ($promptBytes -gt [int]($promptBudget * 0.8)) {
    $promptBudgetWarning = "Review prompt is $promptBytes bytes, over 80% of the $promptBudget budget. Cumulative state grows each round; compact review-context.md or raise the budget before it becomes blocking."
    Write-Warning $promptBudgetWarning
}
Write-Atomic -Path $promptPath -Content $prompt

$promptResolvedPath = (Resolve-Path -LiteralPath $promptPath).Path
$draftResolvedPath = (Resolve-Path -LiteralPath $draftPath).Path
$statePresent = Test-Path -LiteralPath $statePath -PathType Leaf
$authorizationRequired = [bool]$transition.authorization_required

[pscustomobject]@{
    status = 'ok'
    round = $Round
    tier = $Tier
    prompt_path = $promptResolvedPath
    draft_path = $draftResolvedPath
    prompt_bytes = $promptBytes
    prompt_sha256 = (Get-FileHash -LiteralPath $promptResolvedPath -Algorithm SHA256).Hash.ToUpperInvariant()
    draft_sha256 = (Get-FileHash -LiteralPath $draftResolvedPath -Algorithm SHA256).Hash.ToUpperInvariant()
    state_path = [System.IO.Path]::GetFullPath($statePath)
    state_present = $statePresent
    state_sha256 = if ($statePresent) { (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash.ToUpperInvariant() } else { '' }
    authorization_required = $authorizationRequired
    authorization_path = [System.IO.Path]::GetFullPath($authorizationPath)
    authorization_sha256 = if ($authorizationRequired) { (Get-FileHash -LiteralPath $authorizationPath -Algorithm SHA256).Hash.ToUpperInvariant() } else { '' }
    build_intake_warning = $buildIntakeWarning
    prompt_budget_bytes = $promptBudget
    prompt_budget_warning = $promptBudgetWarning
} | ConvertTo-Json -Compress
