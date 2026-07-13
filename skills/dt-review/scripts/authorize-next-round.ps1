[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectPath,

    [Parameter(Mandatory)]
    [ValidateRange(2, 99)]
    [int]$Round,

    [Parameter(Mandatory)]
    [ValidateSet('light', 'complex')]
    [string]$Tier,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AuthorizedBy,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Reason
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

. (Join-Path $PSScriptRoot 'round-transition.ps1')
$transition = Get-DtReviewRoundTransition `
    -ProjectPath $ProjectPath `
    -Round $Round `
    -Tier $Tier `
    -EvaluatorPath (Join-Path $PSScriptRoot 'evaluate-termination.ps1')

if (-not $transition.authorization_required) {
    throw "Round $Round follows '$($transition.source_action)' and is already authorized automatically."
}

$projectRoot = (Resolve-Path -LiteralPath $ProjectPath).Path
$scratchDir = Join-Path $projectRoot 'design\_review'
$authorizationPath = Join-Path $scratchDir 'round-authorizations.json'
$nextDraftPath = Join-Path $scratchDir ("draft-v{0}.md" -f $Round)

switch ([string]$transition.source_action) {
    'FINALIZE_CURRENT' {
        # A named confirmation after a clean verdict reviews the exact same bytes.
        $sourceDraftPath = Join-Path $scratchDir ("draft-v{0}.md" -f $transition.source_round)
        $metadataPath = Join-Path $scratchDir ("round-meta-v{0}.json" -f $transition.source_round)
        foreach ($required in @($sourceDraftPath, $metadataPath)) {
            if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
                throw "Confirmation source receipt input not found: $required"
            }
        }
        try { $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json }
        catch { throw "Confirmation source receipt is invalid JSON: $metadataPath. $($_.Exception.Message)" }
        if (-not $metadata.PSObject.Properties['round'] -or [int]$metadata.round -ne [int]$transition.source_round -or
            -not $metadata.PSObject.Properties['tier'] -or [string]$metadata.tier -cne $Tier -or
            -not $metadata.PSObject.Properties['draft_path'] -or
            -not ([System.IO.Path]::GetFullPath([string]$metadata.draft_path)).Equals($sourceDraftPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Confirmation source receipt does not match source round, tier, or draft path: $metadataPath"
        }
        $sourceHash = (Get-FileHash -LiteralPath $sourceDraftPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if (-not $metadata.PSObject.Properties['draft_sha256'] -or
            $sourceHash -cne ([string]$metadata.draft_sha256).ToUpperInvariant()) {
            throw "Confirmation source draft does not match its review receipt: $sourceDraftPath"
        }
        $sourceContent = [System.IO.File]::ReadAllText($sourceDraftPath)
        if (Test-Path -LiteralPath $nextDraftPath -PathType Leaf) {
            if ([System.IO.File]::ReadAllText($nextDraftPath) -cne $sourceContent) {
                throw "Post-terminal confirmation draft must be byte-identical to its source: $nextDraftPath"
            }
        }
        else {
            Write-Atomic -Path $nextDraftPath -Content $sourceContent
        }
    }
    'APPLY_POLISH_AND_FINALIZE' {
        # The final-draft preparer owns this N+1; replay it before authorization.
        $manifestPath = Join-Path $scratchDir ("finalization-manifest-v{0}.json" -f $Round)
        if (-not (Test-Path -LiteralPath $nextDraftPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Prepare the polish N+1 draft and manifest before authorizing its confirmation review: $manifestPath"
        }
        try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
        catch { throw "Finalization manifest is invalid JSON: $manifestPath. $($_.Exception.Message)" }
        if (-not $manifest.PSObject.Properties['instructions_path']) {
            throw "Finalization manifest has no instructions_path: $manifestPath"
        }
        [void](& (Join-Path $PSScriptRoot 'prepare-final-draft.ps1') `
            -ProjectPath $projectRoot `
            -Round $transition.source_round `
            -Tier $Tier `
            -InstructionsPath ([string]$manifest.instructions_path))
    }
    'USER_DECISION' {
        if (-not (Test-Path -LiteralPath $nextDraftPath -PathType Leaf)) {
            throw "A cap extension requires the reconciled immutable next draft before authorization: $nextDraftPath"
        }
    }
}

$existing = if (Test-Path -LiteralPath $authorizationPath -PathType Leaf) {
    @(Get-Content -LiteralPath $authorizationPath -Raw | ConvertFrom-Json)
}
else { @() }

$sameRound = @($existing | Where-Object { [int]$_.round -eq $Round })
$record = [ordered]@{
    round = $Round
    source_round = [int]$transition.source_round
    source_action = [string]$transition.source_action
    tier = $Tier
    authorization_kind = [string]$transition.authorization_kind
    state_sha256 = [string]$transition.state_sha256
    authorized_by = $AuthorizedBy.Trim()
    reason = $Reason.Trim()
    authorized_at_utc = [DateTime]::UtcNow.ToString('o')
}

if ($sameRound.Count -gt 0) {
    if ($sameRound.Count -ne 1) {
        throw "Round $Round has duplicate authorization records: $authorizationPath"
    }
    $current = $sameRound[0]
    $matches = $true
    foreach ($field in @('source_round', 'source_action', 'tier', 'authorization_kind', 'state_sha256', 'authorized_by', 'reason')) {
        if ([string]$current.$field -cne [string]$record[$field]) { $matches = $false; break }
    }
    if (-not $matches) {
        throw "Round $Round already has a different authorization record. Remove it only after an explicit renewed user decision."
    }
    $status = 'already_authorized'
}
else {
    $updated = @($existing) + [pscustomobject]$record
    Write-Atomic -Path $authorizationPath -Content (($updated | ConvertTo-Json -Depth 5) + "`n")
    $status = 'authorized'
}

[pscustomobject]@{
    status = $status
    round = $Round
    authorization_kind = [string]$transition.authorization_kind
    authorization_path = (Resolve-Path -LiteralPath $authorizationPath).Path
    draft_path = (Resolve-Path -LiteralPath $nextDraftPath).Path
} | ConvertTo-Json -Compress
