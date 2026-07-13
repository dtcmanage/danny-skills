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

    [Parameter(Mandatory)]
    [string]$InstructionsPath,

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
                throw "$Label traverses a reparse point: $current"
            }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            throw "Unable to validate $Label containment below $rootFull."
        }
        $current = [System.IO.Path]::GetFullPath($parent).TrimEnd('\', '/')
    }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Write-Atomic([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    $tmp = Join-Path $dir ((Split-Path -Leaf $Path) + '.tmp.' + $PID)
    try {
        [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

function Assert-ExactFile([string]$Path, [string]$Content, [string]$Label) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existing = [System.IO.File]::ReadAllText($Path)
        if ($existing -cne $Content) {
            throw "$Label already exists with different content: $Path"
        }
        return
    }
    Write-Atomic -Path $Path -Content $Content
}

function Assert-SingleLine([string]$Value, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -cne $Value.Trim() -or $Value -match '[\r\n]') {
        throw "$Label must be a non-empty, trimmed single line."
    }
}

foreach ($required in @($ProjectPath, $InstructionsPath)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required preparation input not found: $required" }
}
if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
    throw "Project path is not a directory: $ProjectPath"
}
if (-not (Test-Path -LiteralPath $InstructionsPath -PathType Leaf)) {
    throw "Instructions path is not a file: $InstructionsPath"
}

$projectRoot = (Resolve-Path -LiteralPath $ProjectPath).Path
$scratchDir = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'design\_review'))
$statePath = Join-Path $scratchDir 'verdicts.json'
$sourceDraftPath = Join-Path $scratchDir ("draft-v{0}.md" -f $Round)
$receiptPath = Join-Path $scratchDir ("round-meta-v{0}.json" -f $Round)
$instructions = (Resolve-Path -LiteralPath $InstructionsPath).Path
foreach ($requiredFile in @($statePath, $sourceDraftPath, $receiptPath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required preparation input not found: $requiredFile"
    }
}
foreach ($check in @(
    @{ Path=$scratchDir; Label='Scratch path' },
    @{ Path=$statePath; Label='State path' },
    @{ Path=$sourceDraftPath; Label='Source draft path' },
    @{ Path=$receiptPath; Label='Source receipt path' },
    @{ Path=$instructions; Label='Instructions path' }
)) {
    Assert-NoDescendantReparsePoint -Path $check.Path -Root $projectRoot -Label $check.Label
}
if (-not (Test-IsWithin -Child $instructions -Parent $scratchDir)) {
    throw "Instructions must be inside the active review scratch folder: $scratchDir"
}

try { $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json }
catch { throw "Source receipt is invalid JSON: $receiptPath. $($_.Exception.Message)" }
if (-not $receipt.PSObject.Properties['round'] -or [int]$receipt.round -ne $Round) {
    throw "Source receipt does not identify round ${Round}: $receiptPath"
}
if (-not $receipt.PSObject.Properties['draft_path'] -or
    -not ([System.IO.Path]::GetFullPath([string]$receipt.draft_path)).Equals($sourceDraftPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Source receipt does not identify the expected reviewed draft: $sourceDraftPath"
}
if (-not $receipt.PSObject.Properties['draft_sha256'] -or [string]::IsNullOrWhiteSpace([string]$receipt.draft_sha256)) {
    throw "Source receipt has no reviewed draft SHA256: $receiptPath"
}
$sourceSha256 = Get-Sha256 $sourceDraftPath
if ($sourceSha256 -cne ([string]$receipt.draft_sha256).ToUpperInvariant()) {
    throw "Source draft changed after review: $sourceDraftPath"
}

$termination = (& (Join-Path $PSScriptRoot 'evaluate-termination.ps1') `
    -StatePath $statePath -Round $Round -Tier $Tier) | ConvertFrom-Json
if ($termination.action -notin @('APPLY_POLISH_AND_FINALIZE', 'USER_DECISION')) {
    throw "Termination action '$($termination.action)' does not permit an unreviewed N+1 final draft."
}
if ($termination.action -eq 'USER_DECISION' -and -not $ApprovedResidualRisk) {
    throw 'Residual-risk preparation requires explicit -ApprovedResidualRisk confirmation.'
}
if ($termination.action -ne 'USER_DECISION' -and $ApprovedResidualRisk) {
    throw '-ApprovedResidualRisk is valid only for a USER_DECISION terminal state.'
}

try {
    $stateEntries = @(Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json)
    $items = @(Get-Content -LiteralPath $instructions -Raw | ConvertFrom-Json)
}
catch { throw "Preparation JSON is invalid. $($_.Exception.Message)" }
$current = @($stateEntries | Where-Object { [int]$_.round -eq $Round })
if ($current.Count -ne 1) { throw "Review state must contain exactly one round $Round entry." }
$current = $current[0]
$sourceBody = [System.IO.File]::ReadAllText($sourceDraftPath)
$preparedBody = ''

if ($termination.action -eq 'APPLY_POLISH_AND_FINALIZE') {
    $eligible = @($current.findings | Where-Object { [string]$_.disposition -in @('ACCEPT', 'COUNTER') })
    $deferred = @($current.findings | Where-Object { [string]$_.disposition -eq 'DEFER' })
    if ($deferred.Count -gt 0) { throw 'Polish finalization cannot prepare a draft while DEFER findings remain.' }

    $byId = @{}
    foreach ($item in $items) {
        $id = [string]$item.id
        if ([string]::IsNullOrWhiteSpace($id) -or $byId.ContainsKey($id)) {
            throw "Polish instruction IDs must be non-empty and unique; invalid ID '$id'."
        }
        $byId[$id] = $item
    }
    $eligibleIds = @($eligible | ForEach-Object { [string]$_.id })
    $missing = @($eligibleIds | Where-Object { -not $byId.ContainsKey($_) })
    $extra = @($byId.Keys | Where-Object { $eligibleIds -notcontains $_ })
    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        throw "Polish instruction coverage mismatch. Missing: $($missing -join ', '); extra: $($extra -join ', ')."
    }

    $replacements = @()
    foreach ($finding in $eligible) {
        $item = $byId[[string]$finding.id]
        foreach ($property in @('finding_hash', 'disposition', 'old_text', 'new_text')) {
            if (-not $item.PSObject.Properties[$property]) {
                throw "Polish instruction '$($finding.id)' requires '$property'."
            }
        }
        if (-not $finding.PSObject.Properties['finding_hash'] -or
            [string]$item.finding_hash -cne [string]$finding.finding_hash) {
            throw "Polish instruction '$($finding.id)' has a stale finding hash."
        }
        if ([string]$item.disposition -cne [string]$finding.disposition) {
            throw "Polish instruction '$($finding.id)' disposition does not match review state."
        }
        $oldText = [string]$item.old_text
        $newText = [string]$item.new_text
        if ([string]::IsNullOrEmpty($oldText) -or $oldText -ceq $newText) {
            throw "Polish instruction '$($finding.id)' requires distinct, non-empty old_text and new_text."
        }
        $matches = [regex]::Matches($sourceBody, [regex]::Escape($oldText))
        if ($matches.Count -ne 1) {
            throw "Polish instruction '$($finding.id)' old_text must occur exactly once in the reviewed draft; found $($matches.Count)."
        }
        $replacements += [pscustomobject]@{
            id = [string]$finding.id
            index = $matches[0].Index
            length = $matches[0].Length
            new_text = $newText
        }
    }
    $ascending = @($replacements | Sort-Object index)
    for ($i = 1; $i -lt $ascending.Count; $i++) {
        if ($ascending[$i].index -lt ($ascending[$i - 1].index + $ascending[$i - 1].length)) {
            throw "Polish instructions '$($ascending[$i - 1].id)' and '$($ascending[$i].id)' overlap."
        }
    }
    $preparedBody = $sourceBody
    foreach ($replacement in @($replacements | Sort-Object index -Descending)) {
        $preparedBody = $preparedBody.Substring(0, $replacement.index) +
            $replacement.new_text +
            $preparedBody.Substring($replacement.index + $replacement.length)
    }
}
else {
    $unresolved = @($current.findings | Where-Object { $_.blocks_design -or [string]$_.disposition -eq 'DEFER' })
    $byId = @{}
    foreach ($item in $items) {
        $id = [string]$item.id
        if ([string]::IsNullOrWhiteSpace($id) -or $byId.ContainsKey($id)) {
            throw "Residual-risk IDs must be non-empty and unique; invalid ID '$id'."
        }
        $byId[$id] = $item
    }
    $unresolvedIds = @($unresolved | ForEach-Object { [string]$_.id })
    $missing = @($unresolvedIds | Where-Object { -not $byId.ContainsKey($_) })
    $extra = @($byId.Keys | Where-Object { $unresolvedIds -notcontains $_ })
    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        throw "Residual-risk coverage mismatch. Missing: $($missing -join ', '); extra: $($extra -join ', ')."
    }
    if ($sourceBody -match '(?mi)^## Accepted residual risks\s*$') {
        throw 'The reviewed source draft already contains an Accepted residual risks section.'
    }
    $section = "## Accepted residual risks`n"
    foreach ($finding in @($unresolved | Sort-Object id)) {
        if (-not $finding.PSObject.Properties['title']) {
            throw "Residual finding '$($finding.id)' has no title in review state."
        }
        $title = [string]$finding.title
        Assert-SingleLine -Value $title -Label "Residual finding '$($finding.id)' title"
        $item = $byId[[string]$finding.id]
        foreach ($property in @('rationale', 'owner', 'recheck_gate')) {
            if (-not $item.PSObject.Properties[$property]) {
                throw "Residual-risk instruction '$($finding.id)' requires '$property'."
            }
            Assert-SingleLine -Value ([string]$item.$property) -Label "Residual-risk instruction '$($finding.id)' $property"
        }
        $section += "`n### $($finding.id) - $title`n`n"
        $section += "- Rationale: $($item.rationale)`n"
        $section += "- Owner: $($item.owner)`n"
        $section += "- Recheck gate: $($item.recheck_gate)`n"
    }
    $preparedBody = $sourceBody.TrimEnd() + "`n`n" + $section
}

$preparedPath = Join-Path $scratchDir ("draft-v{0}.md" -f ($Round + 1))
$manifestPath = Join-Path $scratchDir ("finalization-manifest-v{0}.json" -f ($Round + 1))
Assert-NoDescendantReparsePoint -Path $preparedPath -Root $projectRoot -Label 'Prepared draft path'
Assert-NoDescendantReparsePoint -Path $manifestPath -Root $projectRoot -Label 'Finalization manifest path'
Assert-ExactFile -Path $preparedPath -Content $preparedBody -Label 'Prepared draft'
$preparedSha256 = Get-Sha256 $preparedPath

$manifest = [ordered]@{
    schema_version = 1
    action = [string]$termination.action
    round = $Round
    tier = $Tier
    state_path = $statePath
    state_sha256 = Get-Sha256 $statePath
    source_draft_path = $sourceDraftPath
    source_draft_sha256 = $sourceSha256
    source_receipt_path = $receiptPath
    source_receipt_sha256 = Get-Sha256 $receiptPath
    instructions_path = $instructions
    instructions_sha256 = Get-Sha256 $instructions
    prepared_draft_path = $preparedPath
    prepared_draft_sha256 = $preparedSha256
}
$manifestJson = ($manifest | ConvertTo-Json -Depth 5) + "`n"
Assert-ExactFile -Path $manifestPath -Content $manifestJson -Label 'Finalization manifest'

[pscustomobject]@{
    status = 'ok'
    action = [string]$termination.action
    draft_path = (Resolve-Path -LiteralPath $preparedPath).Path
    draft_sha256 = $preparedSha256
    manifest_path = (Resolve-Path -LiteralPath $manifestPath).Path
    manifest_sha256 = Get-Sha256 $manifestPath
} | ConvertTo-Json -Compress
