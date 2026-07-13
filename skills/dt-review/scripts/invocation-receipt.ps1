Set-StrictMode -Version Latest

function Assert-DtReviewInvocationReceipt {
    param(
        [Parameter(Mandatory)] [object]$Receipt,
        [Parameter(Mandatory)] [ValidateRange(1, 99)] [int]$Round,
        [Parameter(Mandatory)] [ValidateSet('light', 'complex')] [string]$Tier
    )

    if ([int]$Receipt.round -ne $Round -or [string]$Receipt.tier -cne $Tier) {
        throw "Invocation receipt does not match round $Round and tier $Tier."
    }
    foreach ($pair in @(
        @{ Label='prompt'; Path=[string]$Receipt.prompt_path; Expected=[string]$Receipt.prompt_sha256 },
        @{ Label='draft'; Path=[string]$Receipt.draft_path; Expected=[string]$Receipt.draft_sha256 }
    )) {
        if (-not (Test-Path -LiteralPath $pair.Path -PathType Leaf)) {
            throw "Invocation receipt $($pair.Label) input not found: $($pair.Path)"
        }
        $actual = (Get-FileHash -LiteralPath $pair.Path -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -cne $pair.Expected) {
            throw "Invocation receipt $($pair.Label) SHA-256 mismatch; input changed after canonical assembly."
        }
    }

    $stateExists = Test-Path -LiteralPath ([string]$Receipt.state_path) -PathType Leaf
    if ([bool]$Receipt.state_present -ne $stateExists) {
        throw 'Invocation receipt state presence changed after canonical assembly.'
    }
    if ($stateExists) {
        $actualState = (Get-FileHash -LiteralPath ([string]$Receipt.state_path) -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualState -cne [string]$Receipt.state_sha256) {
            throw 'Invocation receipt state SHA-256 mismatch; review state changed after canonical assembly.'
        }
    }

    if ([bool]$Receipt.authorization_required) {
        if (-not (Test-Path -LiteralPath ([string]$Receipt.authorization_path) -PathType Leaf)) {
            throw 'Invocation receipt authorization disappeared after canonical assembly.'
        }
        $actualAuthorization = (Get-FileHash -LiteralPath ([string]$Receipt.authorization_path) -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualAuthorization -cne [string]$Receipt.authorization_sha256) {
            throw 'Invocation receipt authorization SHA-256 mismatch after canonical assembly.'
        }
    }
}

function Get-DtReviewInvocationReceipt {
    param(
        [Parameter(Mandatory)] [string]$ProjectPath,
        [Parameter(Mandatory)] [ValidateRange(1, 99)] [int]$Round,
        [Parameter(Mandatory)] [ValidateSet('light', 'complex')] [string]$Tier,
        [Parameter(Mandatory)] [string]$PromptPath,
        [Parameter(Mandatory)] [string]$AssemblerPath
    )

    $assembly = (& $AssemblerPath -ProjectPath $ProjectPath -Round $Round -Tier $Tier) | ConvertFrom-Json
    $provided = (Resolve-Path -LiteralPath $PromptPath).Path
    $canonical = (Resolve-Path -LiteralPath ([string]$assembly.prompt_path)).Path
    if (-not $provided.Equals($canonical, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "PromptPath is not the canonical Round $Round prompt: $canonical"
    }
    Assert-DtReviewInvocationReceipt -Receipt $assembly -Round $Round -Tier $Tier
    return $assembly
}
