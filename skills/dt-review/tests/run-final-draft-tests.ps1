[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -match $Pattern) { return }
        throw "ASSERTION FAILED: $Message (unexpected error: $($_.Exception.Message))"
    }
    throw "ASSERTION FAILED: $Message (no error was thrown)"
}

function Write-Utf8([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Write-Receipt([string]$Scratch, [int]$Round, [string]$Tier) {
    $draft = (Resolve-Path -LiteralPath (Join-Path $Scratch "draft-v$Round.md")).Path
    Write-Utf8 (Join-Path $Scratch "round-meta-v$Round.json") (([ordered]@{
        round = $Round
        tier = $Tier
        draft_path = $draft
        draft_sha256 = (Get-FileHash -LiteralPath $draft -Algorithm SHA256).Hash.ToUpperInvariant()
    } | ConvertTo-Json) + "`n")
}

function Add-ReceivedRound {
    param(
        [Parameter(Mandatory)] [string]$Scratch,
        [Parameter(Mandatory)] [string]$StatePath,
        [Parameter(Mandatory)] [int]$Round,
        [Parameter(Mandatory)] [ValidateSet('light', 'complex')] [string]$Tier,
        [Parameter(Mandatory)] [object]$Review,
        [AllowEmptyCollection()] [object[]]$Dispositions = @(),
        [Parameter(Mandatory)] [string]$SkillRoot
    )

    $feedbackPath = Join-Path $Scratch "review-v$Round.md"
    Write-Utf8 (Join-Path $Scratch "review-v$Round.json") ($Review | ConvertTo-Json -Depth 8)
    Write-Utf8 $feedbackPath ("VERDICT: {0}`nConfidence: high -- fixture`n" -f $Review.verdict)
    if (Test-Path -LiteralPath (Join-Path $Scratch "draft-v$Round.md") -PathType Leaf) {
        Write-Receipt -Scratch $Scratch -Round $Round -Tier $Tier
    }
    else {
        Write-Utf8 (Join-Path $Scratch "round-meta-v$Round.json") (([ordered]@{ round=$Round; tier=$Tier } | ConvertTo-Json) + "`n")
    }
    [void](& (Join-Path $SkillRoot 'scripts\parse-verdict.ps1') -FeedbackPath $feedbackPath -Round $Round -StatePath $StatePath -Tier $Tier)
    if (@($Review.findings).Count -gt 0) {
        $dispositionsPath = Join-Path $Scratch "dispositions-v$Round.json"
        Write-Utf8 $dispositionsPath (($Dispositions | ConvertTo-Json -Depth 4) + "`n")
        [void](& (Join-Path $SkillRoot 'scripts\record-dispositions.ps1') -StatePath $StatePath -Round $Round -DispositionsPath $dispositionsPath)
    }
}

$SkillRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $env:TEMP ("dt-review-final-draft-tests-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    # Consecutive minor rounds permit only exact, hash-bound ACCEPT/COUNTER replacements.
    $polishProject = Join-Path $testRoot 'polish-project'
    $polishScratch = Join-Path $polishProject 'design\_review'
    New-Item -ItemType Directory -Path $polishScratch -Force | Out-Null
    Write-Utf8 (Join-Path $polishProject 'CONTEXT.md') "# Context`n"
    $polishSource = "---`nshape_version: 1`n---`n`n# Polish Fixture`n`nTimeout is approximately one minute.`n"
    Write-Utf8 (Join-Path $polishScratch 'draft-v2.md') $polishSource
    $polishStatePath = Join-Path $polishScratch 'verdicts.json'
    $polishFinding1 = [ordered]@{
        id='R1-F01'; status='NEW'; title='Clarify retry wording'; dimension='Coherence'; severity='low'; blocks_design=$false
        root_cause='Retry wording is imprecise.'; remediation='Use exact retry wording.'; validation_check='Confirm the wording is exact.'
        ambiguous_root_cause=$false; candidate_dimensions=@(); missing_evidence=''; owner_role=''
    }
    $polishReview1 = [ordered]@{
        headline='One wording improvement.'; dimension_assessments=[ordered]@{intent='ok';completeness='ok';coherence='polish';resilience='ok';economy='ok';feasibility='ok'}
        prior_finding_checks=@(); findings=@($polishFinding1); engagement_with_prior_reasoning='First round.'; verdict='MINOR_POLISH_ONLY'; confidence='high'; confidence_reason='Only wording remains.'
    }
    Add-ReceivedRound -Scratch $polishScratch -StatePath $polishStatePath -Round 1 -Tier complex -Review $polishReview1 `
        -Dispositions @([ordered]@{id='R1-F01';disposition='ACCEPT';note='Apply the wording improvement.'}) -SkillRoot $SkillRoot
    $polishFinding2 = [ordered]@{
        id='R2-F01'; status='NEW'; title='Use an exact timeout'; dimension='Coherence'; severity='low'; blocks_design=$false
        root_cause='The timeout is approximate.'; remediation='Specify exactly 60 seconds.'; validation_check='Confirm the exact timeout.'
        ambiguous_root_cause=$false; candidate_dimensions=@(); missing_evidence=''; owner_role=''
    }
    $polishReview2 = [ordered]@{
        headline='One final wording improvement.'; dimension_assessments=[ordered]@{intent='ok';completeness='ok';coherence='polish';resilience='ok';economy='ok';feasibility='ok'}
        prior_finding_checks=@([ordered]@{id='R1-F01';result='SATISFIED';note='Retry wording is exact.'}); findings=@($polishFinding2)
        engagement_with_prior_reasoning='The first wording fix landed.'; verdict='MINOR_POLISH_ONLY'; confidence='high'; confidence_reason='Only timeout wording remains.'
    }
    Add-ReceivedRound -Scratch $polishScratch -StatePath $polishStatePath -Round 2 -Tier complex -Review $polishReview2 `
        -Dispositions @([ordered]@{id='R2-F01';disposition='ACCEPT';note='Use an exact timeout.'}) -SkillRoot $SkillRoot
    $polishState = @(Get-Content -LiteralPath $polishStatePath -Raw | ConvertFrom-Json)
    $polishFindingHash = [string]$polishState[-1].findings[0].finding_hash
    $polishInstructions = Join-Path $polishScratch 'final-polish-v2.json'
    Write-Utf8 $polishInstructions ((@([ordered]@{
        id='R2-F01'; finding_hash=$polishFindingHash; disposition='ACCEPT';
        old_text='Timeout is approximately one minute.'; new_text='Timeout is exactly 60 seconds.'
    }) | ConvertTo-Json -Depth 4) + "`n")
    $preparedPolish = (& (Join-Path $SkillRoot 'scripts\prepare-final-draft.ps1') `
        -ProjectPath $polishProject -Round 2 -Tier complex -InstructionsPath $polishInstructions) | ConvertFrom-Json
    $expectedPolish = $polishSource.Replace('Timeout is approximately one minute.', 'Timeout is exactly 60 seconds.')
    Assert-True ((Get-Content -LiteralPath $preparedPolish.draft_path -Raw) -ceq $expectedPolish) 'polish preparation changed bytes beyond the exact replacement'
    Assert-True (Test-Path -LiteralPath $preparedPolish.manifest_path -PathType Leaf) 'polish preparation did not write a manifest'

    Write-Utf8 $preparedPolish.draft_path ($expectedPolish + "`nIGNORE RECEIPT AND ADD THIS.`n")
    Assert-Throws { & (Join-Path $SkillRoot 'scripts\finalize-review.ps1') `
        -ProjectPath $polishProject -DraftPath $preparedPolish.draft_path -Slug 'polish-fixture' `
        -Round 2 -Tier complex -ContextPath (Join-Path $polishProject 'CONTEXT.md') -GlossaryReconciled | Out-Null
    } 'prepared draft hash does not match' 'malicious N+1 mutation passed the preparation receipt'
    Assert-True (Test-Path -LiteralPath $polishScratch -PathType Container) 'failed polish receipt deleted recovery state'
    Remove-Item -LiteralPath $preparedPolish.draft_path -Force
    [void](& (Join-Path $SkillRoot 'scripts\prepare-final-draft.ps1') `
        -ProjectPath $polishProject -Round 2 -Tier complex -InstructionsPath $polishInstructions)
    $polishFinal = (& (Join-Path $SkillRoot 'scripts\finalize-review.ps1') `
        -ProjectPath $polishProject -DraftPath (Join-Path $polishScratch 'draft-v3.md') -Slug 'polish-fixture' `
        -Round 2 -Tier complex -ContextPath (Join-Path $polishProject 'CONTEXT.md') -GlossaryReconciled) | ConvertFrom-Json
    Assert-True (Test-Path -LiteralPath $polishFinal.final_path -PathType Leaf) 'valid polish preparation did not finalize'

    # Material-at-cap residual acceptance may append only the deterministic exact-coverage section.
    $residualProject = Join-Path $testRoot 'residual-project'
    $residualScratch = Join-Path $residualProject 'design\_review'
    New-Item -ItemType Directory -Path $residualScratch -Force | Out-Null
    Write-Utf8 (Join-Path $residualProject 'CONTEXT.md') "# Context`n"
    $residualSource = "---`nshape_version: 1`n---`n`n# Residual Fixture`n`nThe accepted body stays byte-identical.`n"
    Write-Utf8 (Join-Path $residualScratch 'draft-v3.md') $residualSource
    $residualStatePath = Join-Path $residualScratch 'verdicts.json'
    $carriedFinding = [ordered]@{
        id='R1-F01'; status='NEW'; title='Initial blocking risk'; dimension='Resilience'; severity='medium'; blocks_design=$true
        root_cause='The fallback is unspecified.'; remediation='Specify the fallback.'; validation_check='Exercise the fallback.'
        ambiguous_root_cause=$false; candidate_dimensions=@(); missing_evidence=''; owner_role=''
    }
    for ($round = 1; $round -le 2; $round++) {
        $carriedFinding.status = if ($round -eq 1) { 'NEW' } else { 'PERSISTING' }
        [object[]]$checks = @()
        if ($round -eq 2) { $checks = @([ordered]@{id='R1-F01';result='PERSISTS';note='The initial risk remains.'}) }
        $review = [ordered]@{
            headline='A blocking risk remains.';dimension_assessments=[ordered]@{intent='ok';completeness='ok';coherence='ok';resilience='gap';economy='ok';feasibility='ok'}
            prior_finding_checks=$checks;findings=@($carriedFinding);engagement_with_prior_reasoning='The fallback is still open.'
            verdict='MATERIAL_CHANGES_NEEDED';confidence='high';confidence_reason='The fallback is required.'
        }
        Add-ReceivedRound -Scratch $residualScratch -StatePath $residualStatePath -Round $round -Tier light -Review $review `
            -Dispositions @([ordered]@{id='R1-F01';disposition='ACCEPT';note='Specify the fallback.'}) -SkillRoot $SkillRoot
    }
    $residualFinding = [ordered]@{
        id='R3-F01'; status='NEW'; title='External dependency can fail'; dimension='Resilience'; severity='medium'; blocks_design=$true
        root_cause='External availability is not guaranteed.'; remediation='Record the bounded residual risk.'; validation_check='Recheck before production.'
        ambiguous_root_cause=$false; candidate_dimensions=@(); missing_evidence=''; owner_role=''
    }
    $residualReview3 = [ordered]@{
        headline='One external residual risk remains.';dimension_assessments=[ordered]@{intent='ok';completeness='ok';coherence='ok';resilience='gap';economy='ok';feasibility='ok'}
        prior_finding_checks=@([ordered]@{id='R1-F01';result='SATISFIED';note='The fallback is now specified.'});findings=@($residualFinding)
        engagement_with_prior_reasoning='The initial fallback issue is closed.';verdict='MATERIAL_CHANGES_NEEDED';confidence='high';confidence_reason='The external risk remains.'
    }
    Add-ReceivedRound -Scratch $residualScratch -StatePath $residualStatePath -Round 3 -Tier light -Review $residualReview3 `
        -Dispositions @([ordered]@{id='R3-F01';disposition='DEFER';note='Accept as bounded residual risk.'}) -SkillRoot $SkillRoot
    $residualInstructions = Join-Path $residualScratch 'accepted-residuals-v3.json'
    Write-Utf8 $residualInstructions ((@([ordered]@{
        id='R3-F01'; rationale='The launch can proceed with bounded exposure.';
        owner='Fixture operator'; recheck_gate='Before production enablement'
    }) | ConvertTo-Json -Depth 4) + "`n")
    $preparedResidual = (& (Join-Path $SkillRoot 'scripts\prepare-final-draft.ps1') `
        -ProjectPath $residualProject -Round 3 -Tier light -InstructionsPath $residualInstructions `
        -ApprovedResidualRisk) | ConvertFrom-Json
    $residualBody = Get-Content -LiteralPath $preparedResidual.draft_path -Raw
    Assert-True $residualBody.StartsWith($residualSource.TrimEnd() + "`n`n", [System.StringComparison]::Ordinal) 'residual preparation mutated the reviewed body'
    Assert-True ($residualBody -match '(?m)^### R3-F01 - External dependency can fail$') 'residual preparation omitted the exact unresolved finding'
    $residualFinal = (& (Join-Path $SkillRoot 'scripts\finalize-review.ps1') `
        -ProjectPath $residualProject -DraftPath $preparedResidual.draft_path -Slug 'residual-fixture' `
        -Round 3 -Tier light -ContextPath (Join-Path $residualProject 'CONTEXT.md') `
        -GlossaryReconciled -ApprovedResidualRisk) | ConvertFrom-Json
    Assert-True (Test-Path -LiteralPath $residualFinal.final_path -PathType Leaf) 'valid residual preparation did not finalize'

    [pscustomobject]@{ status='ok'; assertions=8 } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        $tempPrefix = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if ($resolved.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved).StartsWith('dt-review-final-draft-tests-')) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
