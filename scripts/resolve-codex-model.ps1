# Shared Codex model resolver. Dot-source this file, then call Resolve-CodexModel.
#
# Why this exists: dt-review (and any other Codex consumer) pins explicit model
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
        [ValidateSet('complex', 'light')]
        [string]$Tier,
        # The caller's preferred pin (from the skill's operating constants). Always
        # wins when it is selectable on the current auth.
        [string]$PreferredModel,
        # Override the cache location (tests). Defaults to the live Codex cache.
        [string]$CachePath
    )

    # Curated, ordered allowlists per tier. Frontier/codex-tuned first; both lists
    # end on general deep-reasoning models so resolution never hard-fails while any
    # gpt-5.x model is alive. Update these (and the SKILL.md operating constants)
    # when OpenAI rotates the model line -- the matrix in
    # _Claude-Workspace\00_Resources\codex-cli-usage.md is the human-readable mirror.
    $fallbacks = @{
        complex = @('gpt-5.5', 'gpt-5.4', 'gpt-5.2')
        light   = @('gpt-5.3-codex', 'gpt-5.3-codex-spark', 'gpt-5.4-mini', 'gpt-5.4', 'gpt-5.5')
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

    # No cache or unparseable cache: trust the first candidate (the pin) unverified.
    # The downstream preflight still actually exercises the model, so a dead pin is
    # caught there with a loud throw -- this is a soft degrade, not a silent pass.
    if (-not (Test-Path -LiteralPath $CachePath)) {
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
        Write-Warning "Could not parse Codex model cache ($($_.Exception.Message)); using unverified model '$($candidates[0])'."
        return $candidates[0]
    }

    if ($selectable.Count -eq 0) {
        Write-Warning "Codex model cache listed no selectable models; using unverified model '$($candidates[0])'."
        return $candidates[0]
    }

    foreach ($cand in $candidates) {
        if ($selectable -contains $cand) {
            if ($PreferredModel -and $cand -ne $PreferredModel) {
                Write-Warning "Preferred Codex model '$PreferredModel' is not selectable on this auth; falling back to '$cand'. Update the dt-review pins (SKILL.md operating constants + script defaults) and the codex-cli-usage.md matrix."
            }
            return $cand
        }
    }

    throw "No usable Codex model for tier '$Tier'. Tried: $($candidates -join ', '). Selectable on this auth: $($selectable -join ', '). Update the dt-review model pins (SKILL.md operating constants + script defaults) and the codex-cli-usage.md matrix."
}
