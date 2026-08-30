[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectPath,

    [Parameter(Mandatory)]
    [string]$DraftPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+){1,3}$')]
    [string]$Slug,

    [Parameter(Mandatory)]
    [ValidateRange(1, 99)]
    [int]$Round,

    [Parameter(Mandatory)]
    [ValidateSet('light', 'complex')]
    [string]$Tier,

    [Parameter(Mandatory)]
    [string]$ContextPath,

    [Parameter(Mandatory)]
    [switch]$GlossaryReconciled,

    [switch]$ApprovedResidualRisk
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-IsWithin([string]$Child, [string]$Parent) {
    $parentPrefix = $Parent.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return $Child.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoDescendantReparsePoint([string]$Path, [string]$Root, [string]$Label) {
    $current = [System.IO.Path]::GetFullPath($Path)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ($current -ne $rootFull -and -not (Test-IsWithin -Child $current -Parent $rootFull)) {
        throw "$Label escapes the project root: $current"
    }
    while ($current -ne $rootFull) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label traverses a reparse point, which is unsafe for finalization: $current"
            }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            throw "Unable to validate $Label containment below $rootFull."
        }
        $current = [System.IO.Path]::GetFullPath($parent).TrimEnd('\', '/')
    }
}

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
foreach ($requiredFile in @($DraftPath, $ContextPath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required finalization file not found: $requiredFile"
    }
}

$projectRoot = (Resolve-Path -LiteralPath $ProjectPath).Path
$draft = (Resolve-Path -LiteralPath $DraftPath).Path
$scratchDir = Join-Path $projectRoot 'design\_review'
$resolvedScratch = [System.IO.Path]::GetFullPath($scratchDir)
$statePath = Join-Path $resolvedScratch 'verdicts.json'
$context = (Resolve-Path -LiteralPath $ContextPath).Path
$expectedContext = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'CONTEXT.md'))
if (-not $context.Equals($expectedContext, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Context receipt must use the canonical project CONTEXT.md: $expectedContext"
}
Assert-NoDescendantReparsePoint -Path $draft -Root $projectRoot -Label 'Draft path'
Assert-NoDescendantReparsePoint -Path $resolvedScratch -Root $projectRoot -Label 'Scratch cleanup path'
Assert-NoDescendantReparsePoint -Path $context -Root $projectRoot -Label 'Context path'
$contextSha256 = (Get-FileHash -LiteralPath $context -Algorithm SHA256).Hash.ToUpperInvariant()

if (-not $GlossaryReconciled) {
    throw 'Finalization requires explicit confirmation that CONTEXT.md/glossary reconciliation completed.'
}
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "Review state not found: $statePath"
}

$reviewedDraftPath = Join-Path $resolvedScratch ("draft-v{0}.md" -f $Round)
$metadataPath = Join-Path $resolvedScratch ("round-meta-v{0}.json" -f $Round)
foreach ($receiptInput in @($reviewedDraftPath, $metadataPath)) {
    if (-not (Test-Path -LiteralPath $receiptInput -PathType Leaf)) {
        throw "Terminal review receipt input not found: $receiptInput"
    }
}
Assert-NoDescendantReparsePoint -Path $reviewedDraftPath -Root $projectRoot -Label 'Reviewed draft path'
try {
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
}
catch {
    throw "Terminal round metadata is invalid JSON: $metadataPath. $($_.Exception.Message)"
}
if (-not $metadata.PSObject.Properties['draft_sha256'] -or [string]::IsNullOrWhiteSpace([string]$metadata.draft_sha256)) {
    throw "Terminal round metadata has no reviewed draft SHA256 receipt: $metadataPath"
}
if (-not $metadata.PSObject.Properties['round'] -or [int]$metadata.round -ne $Round) {
    throw "Terminal round metadata does not identify round ${Round}: $metadataPath"
}
if (-not $metadata.PSObject.Properties['draft_path'] -or
    -not ([System.IO.Path]::GetFullPath([string]$metadata.draft_path)).Equals($reviewedDraftPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Terminal round metadata does not identify the expected reviewed draft: $reviewedDraftPath"
}
$reviewedDraftSha256 = (Get-FileHash -LiteralPath $reviewedDraftPath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($reviewedDraftSha256 -cne ([string]$metadata.draft_sha256).ToUpperInvariant()) {
    throw "Terminal reviewed draft changed after review: $reviewedDraftPath"
}

$terminationJson = & (Join-Path $PSScriptRoot 'evaluate-termination.ps1') `
    -StatePath $statePath `
    -Round $Round `
    -Tier $Tier
$termination = $terminationJson | ConvertFrom-Json
if ($termination.action -eq 'USER_DECISION' -and -not $ApprovedResidualRisk) {
    throw "Review state requires a user decision: $($termination.reason)"
}
if ($ApprovedResidualRisk -and $termination.action -ne 'USER_DECISION') {
    throw '-ApprovedResidualRisk is valid only for a USER_DECISION terminal state.'
}
if ($termination.action -notin @('FINALIZE_CURRENT', 'APPLY_POLISH_AND_FINALIZE', 'USER_DECISION')) {
    throw "Review state is not finalizable (action=$($termination.action)): $($termination.reason)"
}

$expectedDraftName = switch ($termination.action) {
    'FINALIZE_CURRENT' { "draft-v$Round.md" }
    'APPLY_POLISH_AND_FINALIZE' { "draft-v$($Round + 1).md" }
    'USER_DECISION' { "draft-v$($Round + 1).md" }
}
if ((Split-Path -Leaf $draft) -ne $expectedDraftName) {
    throw "Termination action '$($termination.action)' requires $expectedDraftName, not $(Split-Path -Leaf $draft)."
}

$preparationManifestSha256 = $null
if ($termination.action -ne 'FINALIZE_CURRENT') {
    $manifestPath = Join-Path $resolvedScratch ("finalization-manifest-v{0}.json" -f ($Round + 1))
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "An unreviewed N+1 final draft requires a deterministic preparation manifest: $manifestPath"
    }
    Assert-NoDescendantReparsePoint -Path $manifestPath -Root $projectRoot -Label 'Finalization manifest path'
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    catch { throw "Finalization manifest is invalid JSON: $manifestPath. $($_.Exception.Message)" }
    foreach ($property in @(
        'schema_version', 'action', 'round', 'tier', 'state_path', 'state_sha256',
        'source_draft_path', 'source_draft_sha256', 'source_receipt_path', 'source_receipt_sha256',
        'instructions_path', 'instructions_sha256', 'prepared_draft_path', 'prepared_draft_sha256'
    )) {
        if (-not $manifest.PSObject.Properties[$property] -or [string]::IsNullOrWhiteSpace([string]$manifest.$property)) {
            throw "Finalization manifest requires '$property': $manifestPath"
        }
    }
    if ([int]$manifest.schema_version -ne 1 -or [int]$manifest.round -ne $Round -or
        [string]$manifest.action -cne [string]$termination.action -or [string]$manifest.tier -cne $Tier) {
        throw 'Finalization manifest action, round, tier, or schema does not match current terminal state.'
    }
    $manifestPaths = @{
        state_path = $statePath
        source_draft_path = $reviewedDraftPath
        source_receipt_path = $metadataPath
        prepared_draft_path = $draft
    }
    foreach ($name in $manifestPaths.Keys) {
        $actual = [System.IO.Path]::GetFullPath([string]$manifest.$name)
        $expected = [System.IO.Path]::GetFullPath([string]$manifestPaths[$name])
        if (-not $actual.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Finalization manifest '$name' does not identify the expected file: $expected"
        }
    }
    $instructionsPath = [System.IO.Path]::GetFullPath([string]$manifest.instructions_path)
    if (-not (Test-Path -LiteralPath $instructionsPath -PathType Leaf)) {
        throw "Finalization instructions not found: $instructionsPath"
    }
    Assert-NoDescendantReparsePoint -Path $instructionsPath -Root $projectRoot -Label 'Finalization instructions path'
    if (-not (Test-IsWithin -Child $instructionsPath -Parent $resolvedScratch)) {
        throw "Finalization instructions must remain inside the active review scratch folder: $resolvedScratch"
    }
    $hashChecks = @(
        @{ Label='state'; Path=$statePath; Expected=[string]$manifest.state_sha256 },
        @{ Label='source draft'; Path=$reviewedDraftPath; Expected=[string]$manifest.source_draft_sha256 },
        @{ Label='source receipt'; Path=$metadataPath; Expected=[string]$manifest.source_receipt_sha256 },
        @{ Label='instructions'; Path=$instructionsPath; Expected=[string]$manifest.instructions_sha256 },
        @{ Label='prepared draft'; Path=$draft; Expected=[string]$manifest.prepared_draft_sha256 }
    )
    foreach ($check in $hashChecks) {
        $actualHash = (Get-FileHash -LiteralPath $check.Path -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -cne $check.Expected.ToUpperInvariant()) {
            throw "Finalization manifest $($check.Label) hash does not match current content: $($check.Path)"
        }
    }

    # Re-run deterministic preparation as a receipt check. Existing outputs are accepted
    # only when they are byte-identical to the state/source/instructions-derived result.
    $prepareArgs = @{
        ProjectPath = $projectRoot
        Round = $Round
        Tier = $Tier
        InstructionsPath = $instructionsPath
    }
    if ($termination.action -eq 'USER_DECISION') { $prepareArgs.ApprovedResidualRisk = $true }
    [void](& (Join-Path $PSScriptRoot 'prepare-final-draft.ps1') @prepareArgs)
    $preparationManifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToUpperInvariant()
}

if (-not (Test-IsWithin -Child $draft -Parent $resolvedScratch)) {
    throw "Draft must be inside the active review scratch folder: $resolvedScratch"
}
if (-not (Test-IsWithin -Child $resolvedScratch -Parent $projectRoot) -or (Split-Path -Leaf $resolvedScratch) -ne '_review') {
    throw "Refusing unsafe scratch cleanup target: $resolvedScratch"
}

$wordCount = @($Slug -split '-').Count
if ($wordCount -lt 2 -or $wordCount -gt 4) {
    throw 'Design slug must contain 2-4 kebab-case words.'
}

$body = Get-Content -LiteralPath $draft -Raw
if ($body -match '\bdesign[\\/]_review[\\/]') {
    throw 'Final draft contains a reference to scratch review state. Remove the dependency before finalization.'
}
if ($termination.action -eq 'USER_DECISION') {
    $residualMatch = [regex]::Match($body, '(?ims)^## Accepted residual risks\s*\r?\n(?<body>.*?)(?=^##\s|\z)')
    if (-not $residualMatch.Success) {
        throw 'User-approved finalization after a material cap requires an Accepted residual risks section.'
    }
    $entries = @(Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json)
    $currentEntry = $entries | Where-Object { $_.round -eq $Round } | Select-Object -First 1
    $unresolvedIds = @($currentEntry.findings | Where-Object { $_.blocks_design -or $_.disposition -eq 'DEFER' } | ForEach-Object { [string]$_.id } | Sort-Object -Unique)
    $residualBody = $residualMatch.Groups['body'].Value
    $declaredIds = @([regex]::Matches($residualBody, '(?mi)^###\s+(R[1-9][0-9]*-F[0-9]{2})\b') | ForEach-Object { $_.Groups[1].Value })
    $missingResiduals = @($unresolvedIds | Where-Object { $declaredIds -notcontains $_ })
    $extraResiduals = @($declaredIds | Where-Object { $unresolvedIds -notcontains $_ })
    if ($declaredIds.Count -ne @($declaredIds | Sort-Object -Unique).Count -or $missingResiduals.Count -gt 0 -or $extraResiduals.Count -gt 0) {
        throw "Accepted residual risk coverage mismatch. Missing: $($missingResiduals -join ', '); extra/duplicate: $($extraResiduals -join ', ')."
    }
    foreach ($id in $unresolvedIds) {
        $blockMatch = [regex]::Match($residualBody, "(?ims)^###\s+$([regex]::Escape($id))\b(?<block>.*?)(?=^###\s|\z)")
        foreach ($field in @('Rationale', 'Owner', 'Recheck gate')) {
            if (-not [regex]::IsMatch($blockMatch.Groups['block'].Value, "(?mi)^-\s+$([regex]::Escape($field)):\s+\S")) {
                throw "Accepted residual risk '$id' requires a non-empty '$field' field."
            }
        }
    }
}

$reviewContextPath = Join-Path $resolvedScratch 'review-context.md'
if ((Test-Path -LiteralPath $reviewContextPath -PathType Leaf) -and $body -notmatch '(?mi)^## Build-intake revalidation\s*$') {
    throw 'A review-context.md evidence map exists, so the final design must include a Build-intake revalidation section.'
}

if ($body -match '(?s)^---\s*\r?\n.*?\r?\n---\s*\r?\n') {
    $frontmatter = $Matches[0]
    if ($frontmatter -match '(?m)^shape_version\s*:\s*1\s*$') {
        $finalBody = $body
    }
    else {
        throw 'Final draft frontmatter exists but does not declare shape_version: 1.'
    }
}
else {
    $finalBody = "---`nshape_version: 1`n---`n`n" + $body.TrimStart()
}

$withoutFrontmatter = [regex]::Replace($finalBody, '(?s)^---\s*\r?\n.*?\r?\n---\s*\r?\n', '')
$firstContentLine = @($withoutFrontmatter -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
if ($firstContentLine.Count -ne 1 -or $firstContentLine[0] -notmatch '^#\s+\S') {
    throw 'Final design must start with a level-1 title after frontmatter.'
}
if ($finalBody -match '(?mi)^\s*VERDICT\s*:' -or
    $finalBody -match '(?mi)^##\s+(Dialogue Log|Claude Response|Prior Finding Checks|Round\s+\d+)\s*$' -or
    $finalBody -match '(?i)codex-stream-v\d+|claude-stream-v\d+|review-v\d+\.md') {
    throw 'Final design contains forbidden review archaeology.'
}

$finalPath = Join-Path (Join-Path $projectRoot 'design') ("design-final-{0}.md" -f $Slug)
Assert-NoDescendantReparsePoint -Path (Split-Path -Parent $finalPath) -Root $projectRoot -Label 'Final design directory'
if (Test-Path -LiteralPath $finalPath) {
    Assert-NoDescendantReparsePoint -Path $finalPath -Root $projectRoot -Label 'Final design path'
}
$finalContent = $finalBody.TrimEnd() + "`n"
if (Test-Path -LiteralPath $finalPath -PathType Leaf) {
    $existingFinal = Get-Content -LiteralPath $finalPath -Raw
    if ($existingFinal -cne $finalContent) {
        throw "A different final design already exists; refusing overwrite: $finalPath"
    }
}
else {
    Write-Atomic -Path $finalPath -Content $finalContent
}

if (-not (Test-Path -LiteralPath $finalPath -PathType Leaf) -or (Get-Item -LiteralPath $finalPath).Length -eq 0) {
    throw "Final design write did not verify: $finalPath"
}

# Delete only the exact, verified <project>\design\_review target.
Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
if (Test-Path -LiteralPath $resolvedScratch) {
    throw "Scratch cleanup failed: $resolvedScratch"
}

[pscustomobject]@{
    status = 'ok'
    final_path = (Resolve-Path -LiteralPath $finalPath).Path
    context_path = $context
    context_sha256 = $contextSha256
    reviewed_draft_sha256 = $reviewedDraftSha256
    preparation_manifest_sha256 = $preparationManifestSha256
    residual_risk_approved = [bool]$ApprovedResidualRisk
    scratch_removed = $resolvedScratch
} | ConvertTo-Json -Compress
