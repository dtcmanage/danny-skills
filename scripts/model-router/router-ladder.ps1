Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The per-lane ladders, with each frontier rung that tracks the latest release
# resolved to the newest version the router has seen (Danny, 2026-11-26: "fable"
# and "astra" mean the latest version; a regression is pinned by setting the
# rung's track_latest to false). Frontier models stay by-name or approved-request
# only; this changes which version a name means, never when a frontier model runs.

if (-not (Get-Command Get-RouterStatePath -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'router-platform.ps1')
}

function Get-RouterFrontierVersion {
    # [major, minor] for a frontier family id, or $null when the id is not that family.
    param([string]$Model, [string]$Family)
    $pattern = switch ($Family) {
        'fable' { '^claude-fable-(\d+)(?:-(\d{1,2}))?$' }
        'astra' { '^gpt-(\d+)(?:\.(\d+))?-astra$' }
        default { return $null }
    }
    if ($Model -notmatch $pattern) { return $null }
    return @([int]$Matches[1], $(if ($Matches[2]) { [int]$Matches[2] } else { 0 }))
}

function Get-RouterSeenModelIds {
    # Model ids the router has seen and not marked missing: the vendor release
    # check's known-models.json, plus a Codex catalog's listed slugs when the
    # caller already holds one (never fetched here, to keep dispatch fast).
    param([string]$Lane, [string]$KnownModelsPath, [object]$Catalog)
    $ids = [System.Collections.Generic.List[string]]::new()
    if (-not $KnownModelsPath) {
        try { $KnownModelsPath = Join-Path (Get-RouterStatePath) 'known-models.json' } catch { $KnownModelsPath = $null }
    }
    if ($KnownModelsPath -and (Test-Path -LiteralPath $KnownModelsPath)) {
        try {
            foreach ($entry in @(Get-Content -LiteralPath $KnownModelsPath -Raw | ConvertFrom-Json)) {
                if ($entry.lane -eq $Lane -and $entry.status -ne 'missing' -and $entry.id) { $ids.Add([string]$entry.id) }
            }
        } catch { } # An unreadable list adds nothing; the ladder file's model stays.
    }
    if ($Lane -eq 'codex') {
        if ($Catalog) { foreach ($entry in @($Catalog.models)) { if ($entry.visibility -eq 'list' -and $entry.slug) { $ids.Add([string]$entry.slug) } } }
    }
    return @($ids | Sort-Object -Unique)
}

function Get-RouterLadderMap {
    param([string]$KnownModelsPath, [object]$Catalog, [string]$LadderPath = (Join-Path $PSScriptRoot '../../references/model-router/ladders.json'))
    $map = Get-Content -LiteralPath $LadderPath -Raw | ConvertFrom-Json -Depth 10
    foreach ($lane in $map.lanes.PSObject.Properties) {
        foreach ($entry in @($lane.Value.ladder)) {
            if (-not $entry.frontier -or -not $entry.PSObject.Properties['track_latest'] -or -not $entry.track_latest) { continue }
            $family = if ($entry.model -match '^claude-([a-z]+)-') { $Matches[1] } else { $entry.model -replace '^gpt-[\d.]+-', '' }
            $best = [string]$entry.model
            $bestVersion = Get-RouterFrontierVersion $best $family
            if ($null -eq $bestVersion) { continue }
            foreach ($id in (Get-RouterSeenModelIds -Lane $lane.Name -KnownModelsPath $KnownModelsPath -Catalog $Catalog)) {
                $version = Get-RouterFrontierVersion $id $family
                if ($null -eq $version) { continue }
                if ($version[0] -gt $bestVersion[0] -or ($version[0] -eq $bestVersion[0] -and $version[1] -gt $bestVersion[1])) {
                    $best = $id; $bestVersion = $version
                }
            }
            $entry | Add-Member -NotePropertyName ladder_model -NotePropertyValue ([string]$entry.model) -Force
            $entry.model = $best
        }
    }
    return $map
}
