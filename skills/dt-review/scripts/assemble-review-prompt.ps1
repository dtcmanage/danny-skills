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
You are the independent Codex reviewer in an adversarial architecture review.
Review the embedded current draft; do not edit files or attempt to read the workspace.

Round: $Round

Review rules:
- Evaluate all six canonical dimensions. Be skeptical, concrete, and proportionate.
- Do not manufacture findings to keep the dialogue running. A clean design is a valid result.
- Surface every issue you can establish from the current evidence now; do not knowingly serialize findings across later rounds.
- For a new finding, assign the next ID in this round as R$Round-F01, R$Round-F02, and so on, with status NEW.
- Reuse the original finding ID when the same root cause persists or is raised again. Use PERSISTING when it remains unresolved, REOPENED after a prior rejection, and REGRESSION when a previously satisfied commitment later disappeared. Do not mint a new ID for rewording.
- Compare the current draft against every prior ACCEPT/COUNTER disposition in the cumulative state, not only the immediately prior review.
- Emit one prior_finding_checks row for every finding ID in cumulative state (empty in Round 1): SATISFIED, PERSISTS, REGRESSED, or SUPERSEDED, with evidence in note.
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
    # Surface it every round while the next draft is still being authored.
    if ($draft -notmatch '(?mi)^## Build-intake revalidation\s*$') {
        $buildIntakeWarning = "draft-v$Round.md has no '## Build-intake revalidation' section, but review-context.md exists. finalize-review.ps1 will refuse the final design without it, and the terminal reviewed draft cannot be edited. Carry the table into the next draft."
        Write-Warning $buildIntakeWarning
    }
}

if ($previousReviewPath) {
    $priorReview = Get-Content -LiteralPath $previousReviewPath -Raw
    $state = Get-Content -LiteralPath $statePath -Raw
    $parts.Add((New-PromptEnvelope -Label "PRIOR ROUND REVIEW AND ORCHESTRATOR RESPONSE" -Content $priorReview))
    $parts.Add((New-PromptEnvelope -Label "PRIOR FINDING DISPOSITIONS" -Content $state))
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
