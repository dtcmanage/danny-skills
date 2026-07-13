# Shared Codex model resolver. Dot-source this file, then call Resolve-CodexModel.
#
# Why this exists: dt-review, dt-build, and other Codex consumers pin explicit model
# slugs per tier. Those pins rot every time OpenAI rotates models on the ChatGPT
# subscription, and a hand-rolled codex call that omits --model silently inherits
# whatever ~/.codex/config.toml defaults to -- which has, in the past, been a model
# that became API-only ("not supported when using Codex with a ChatGPT account").
#
# Resolve-CodexModel converts both failure modes into a self-healing, loud-failing
# selection: it reads Codex's live per-account model cache, prefers the caller's
# pin, falls back through a curated per-tier candidate list when the pin is gone,
# and throws an actionable error (listing what IS selectable) when nothing resolves.

function Resolve-CodexModel {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('complex', 'standard', 'light')]
        [string]$Tier,
        # The caller's preferred pin (from the skill's operating constants). Always
        # wins when it is selectable on the current auth.
        [string]$PreferredModel,
        # Override the cache location (tests). Defaults to the live Codex cache.
        [string]$CachePath,
        # Automation should fail closed when the live account cache cannot verify
        # the requested tier. Interactive callers may omit this and rely on their
        # own downstream capability probe.
        [switch]$Strict
    )

    # Curated, ordered allowlists per tier. The live per-account cache remains the
    # runtime authority; these lists express capability preference, not entitlement.
    # gpt-5.3-codex-spark is deliberately excluded from every fallback tier per
    # Danny's no-Spark direction. Update these lists and consumer operating constants
    # together when OpenAI rotates the model line.
    $fallbacks = @{
        complex  = @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.5', 'gpt-5.4')
        standard = @('gpt-5.6-terra', 'gpt-5.6-sol', 'gpt-5.5', 'gpt-5.4')
        light    = @('gpt-5.6-luna', 'gpt-5.6-terra', 'gpt-5.4', 'gpt-5.4-mini', 'gpt-5.5', 'gpt-5.6-sol')
    }

    # Candidate order: preferred pin first, then the tier allowlist (de-duped).
    $candidates = @()
    if ($PreferredModel) { $candidates += $PreferredModel }
    foreach ($m in $fallbacks[$Tier]) {
        if ($candidates -notcontains $m) { $candidates += $m }
    }

    if (-not $CachePath) {
        $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
        $CachePath = Join-Path $codexHome 'models_cache.json'
    }

    # No cache or unparseable cache: strict automation fails closed. Interactive
    # callers may soft-degrade to the first candidate only when they run a real
    # downstream capability probe before substantive work.
    if (-not (Test-Path -LiteralPath $CachePath)) {
        if ($Strict) {
            throw "Codex model cache not found at $CachePath; cannot verify tier '$Tier' in strict mode."
        }
        Write-Warning "Codex model cache not found at $CachePath; using unverified model '$($candidates[0])'."
        return $candidates[0]
    }

    $selectable = @()
    try {
        $cache = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
        $selectable = @(
            $cache.models | ForEach-Object {
                $slug = $_.PSObject.Properties['slug']
                $vis = $_.PSObject.Properties['visibility']
                if ($slug -and $vis -and $vis.Value -eq 'list') { $slug.Value }
            }
        )
    }
    catch {
        if ($Strict) {
            throw "Could not parse Codex model cache in strict mode: $($_.Exception.Message)"
        }
        Write-Warning "Could not parse Codex model cache ($($_.Exception.Message)); using unverified model '$($candidates[0])'."
        return $candidates[0]
    }

    if ($selectable.Count -eq 0) {
        if ($Strict) {
            throw "Codex model cache listed no selectable models; cannot verify tier '$Tier' in strict mode."
        }
        Write-Warning "Codex model cache listed no selectable models; using unverified model '$($candidates[0])'."
        return $candidates[0]
    }

    foreach ($cand in $candidates) {
        if ($selectable -contains $cand) {
            if ($PreferredModel -and $cand -ne $PreferredModel) {
                Write-Warning "Preferred Codex model '$PreferredModel' is not selectable on this auth; falling back to '$cand'. Update the consumer's operating constants and shared resolver candidates."
            }
            return $cand
        }
    }

    throw "No usable Codex model for tier '$Tier'. Tried: $($candidates -join ', '). Selectable on this auth: $($selectable -join ', '). Update the consumer's operating constants and shared resolver candidates."
}

function Assert-CodexReasoningEffort {
    param(
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Effort,
        [string]$CachePath,
        [switch]$Strict
    )
    if (-not $CachePath) {
        $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
        $CachePath = Join-Path $codexHome 'models_cache.json'
    }
    try {
        $cache = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
        $row = @($cache.models | Where-Object { [string]$_.slug -eq $Model }) | Select-Object -First 1
        if (-not $row) { throw "model '$Model' is absent from the cache" }
        $supported = @($row.supported_reasoning_levels | ForEach-Object { [string]$_.effort })
        if ($supported.Count -eq 0) { throw "model '$Model' has no advertised reasoning levels" }
        if ($supported -notcontains $Effort) {
            throw "reasoning effort '$Effort' is unsupported by '$Model'; supported: $($supported -join ', ')"
        }
        return $true
    }
    catch {
        if ($Strict) { throw "Codex reasoning compatibility check failed: $($_.Exception.Message)" }
        Write-Warning "Codex reasoning compatibility was not verified: $($_.Exception.Message)"
        return $false
    }
}
