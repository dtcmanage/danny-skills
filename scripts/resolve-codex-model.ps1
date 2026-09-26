# Shared Codex model resolver. Dot-source this file, then call Resolve-CodexModel.
#
# Why this exists: dt-review, dt-build, and other Codex consumers need an explicit model per
# tier. A hand-rolled codex call that omits --model silently inherits ~/.codex/config.toml,
# and hardcoded slugs rot on every OpenAI model rotation. Hardcoded slugs failed twice:
# the older generation stays selectable after a new one ships (5.6 kept winning after 6.0
# shipped), and tier names do not keep their meaning across generations (Sol was 5.6's top
# model and is 6.0's middle one).
#
# So this file holds no model names. It ranks the live per-account catalog deterministically:
#   1. Refresh the catalog with `codex debug models` (Update-CodexModelCatalog), or read
#      Codex's models_cache.json when the caller supplies no catalog.
#   2. Keep selectable rows: visibility 'list', a gpt-<major>[.<minor>] slug, no retirement
#      notice ('upgrade'), and never a Spark model (Danny's no-Spark direction).
#   3. Take the newest generation and order it by the catalog's own 'priority' (the order
#      Codex's model picker shows, best first).
#   4. complex = first rung, standard = second rung (first when only one), light = last rung.
# An explicit -PreferredModel override wins only when it is selectable; strict callers fail
# loudly otherwise instead of silently substituting.

function Get-CodexCachePath {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    return (Join-Path $codexHome 'models_cache.json')
}

function Update-CodexModelCatalog {
    # Asks the Codex CLI for the live account catalog (it refreshes models_cache.json as a
    # side effect) and returns the parsed catalog. Throws on any failure.
    param(
        [Parameter(Mandatory)][string]$CodexCliPath,
        [ValidateRange(1000, 120000)][int]$TimeoutMs = 15000
    )
    if (-not (Get-Command Invoke-CodexProcess -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'invoke-codex-process.ps1')
    }
    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-models-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    try {
        $result = Invoke-CodexProcess -CodexPath $CodexCliPath -Arguments @('debug', 'models') -Prompt '' -WorkingDirectory $workDir -TimeoutMs $TimeoutMs
    }
    finally {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($result.timed_out -or $result.exit_code -ne 0) {
        throw "Codex model catalog refresh failed (exit $($result.exit_code), timed_out $($result.timed_out)): $(([string]$result.stderr).Trim())"
    }
    try { $catalog = [string]$result.stdout | ConvertFrom-Json }
    catch { throw "Codex model catalog refresh returned unparseable JSON: $($_.Exception.Message)" }
    if (-not $catalog.PSObject.Properties['models'] -or @($catalog.models).Count -eq 0) {
        throw 'Codex model catalog refresh returned no models.'
    }
    return $catalog
}

function Get-CodexModelCatalog {
    param([object]$Catalog, [string]$CachePath)
    if ($Catalog) { return $Catalog }
    if (-not $CachePath) { $CachePath = Get-CodexCachePath }
    if (-not (Test-Path -LiteralPath $CachePath)) { throw "Codex model cache not found at $CachePath" }
    try { return (Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json) }
    catch { throw "Could not parse Codex model cache at ${CachePath}: $($_.Exception.Message)" }
}

function Get-CodexModelLadder {
    # Returns the newest selectable generation's slugs, best first. Empty when none qualify.
    param([Parameter(Mandatory)][object]$Catalog)
    $rows = foreach ($m in @($Catalog.models)) {
        $slugProp = $m.PSObject.Properties['slug']
        $visProp = $m.PSObject.Properties['visibility']
        if (-not $slugProp -or -not $visProp -or [string]$visProp.Value -ne 'list') { continue }
        $slug = [string]$slugProp.Value
        if ($slug -match 'spark') { continue }
        $upgradeProp = $m.PSObject.Properties['upgrade']
        if ($upgradeProp -and $null -ne $upgradeProp.Value) { continue }
        $gen = [regex]::Match($slug, '^gpt-(\d+)(?:\.(\d+))?(?:-|$)')
        if (-not $gen.Success) { continue }
        $prioProp = $m.PSObject.Properties['priority']
        $prio = if ($prioProp -and $null -ne $prioProp.Value) { [int]$prioProp.Value } else { [int]::MaxValue }
        [pscustomobject]@{
            slug     = $slug
            major    = [int]$gen.Groups[1].Value
            minor    = if ($gen.Groups[2].Success) { [int]$gen.Groups[2].Value } else { 0 }
            priority = $prio
        }
    }
    $rows = @($rows)
    if ($rows.Count -eq 0) { return @() }
    $newest = $rows | Sort-Object -Property @{ Expression = 'major'; Descending = $true }, @{ Expression = 'minor'; Descending = $true } | Select-Object -First 1
    return @(
        $rows |
            Where-Object { $_.major -eq $newest.major -and $_.minor -eq $newest.minor } |
            Sort-Object -Property priority, slug |
            ForEach-Object { $_.slug }
    )
}

function Resolve-CodexModel {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('complex', 'standard', 'light')]
        [string]$Tier,
        # Explicit override only. Leave empty for automatic newest-generation selection.
        [string]$PreferredModel,
        # A catalog from Update-CodexModelCatalog. When absent, the cache file is read.
        [object]$Catalog,
        # Override the cache location (tests). Defaults to the live Codex cache.
        [string]$CachePath,
        # Automation fails closed when the catalog cannot verify the selection.
        [switch]$Strict
    )

    try { $parsed = Get-CodexModelCatalog -Catalog $Catalog -CachePath $CachePath }
    catch {
        if ($Strict -or -not $PreferredModel) { throw "Cannot resolve Codex tier '$Tier': $($_.Exception.Message)" }
        Write-Warning "$($_.Exception.Message); using unverified override '$PreferredModel'."
        return $PreferredModel
    }

    $selectable = @(
        @($parsed.models) | ForEach-Object {
            $slug = $_.PSObject.Properties['slug']
            $vis = $_.PSObject.Properties['visibility']
            if ($slug -and $vis -and $vis.Value -eq 'list') { [string]$slug.Value }
        }
    )
    $ladder = @(Get-CodexModelLadder -Catalog $parsed)

    if ($PreferredModel) {
        if ($selectable -contains $PreferredModel) {
            if ($ladder.Count -gt 0 -and $ladder -notcontains $PreferredModel) {
                Write-Warning "Override '$PreferredModel' is not in the newest Codex generation ($($ladder -join ', '))."
            }
            return $PreferredModel
        }
        if ($Strict) {
            throw "Codex model override '$PreferredModel' is not selectable on this auth. Selectable: $($selectable -join ', '). Drop the override to auto-select the newest generation."
        }
        Write-Warning "Override '$PreferredModel' is not selectable; auto-selecting tier '$Tier' instead."
    }

    if ($ladder.Count -eq 0) {
        throw "No usable Codex model for tier '$Tier': the catalog lists no selectable gpt-<version> model. Selectable: $($selectable -join ', ')."
    }
    switch ($Tier) {
        'complex'  { return $ladder[0] }
        'standard' { return $ladder[[Math]::Min(1, $ladder.Count - 1)] }
        'light'    { return $ladder[$ladder.Count - 1] }
    }
}

function Assert-CodexReasoningEffort {
    param(
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Effort,
        [object]$Catalog,
        [string]$CachePath,
        [switch]$Strict
    )
    try {
        $parsed = Get-CodexModelCatalog -Catalog $Catalog -CachePath $CachePath
        $row = @($parsed.models | Where-Object { [string]$_.slug -eq $Model }) | Select-Object -First 1
        if (-not $row) { throw "model '$Model' is absent from the catalog" }
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
