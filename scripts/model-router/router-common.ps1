Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RouterCategories {
    return @('complex-coding','routine-coding','code-review','ui-frontend','planning','deep-research','long-form-writing','mechanical','image-generation')
}

function Get-RouterStateDir {
    if ($env:DT_MODEL_ROUTER_STATE) { return [System.IO.Path]::GetFullPath($env:DT_MODEL_ROUTER_STATE) }
    $common = (& git rev-parse --path-format=absolute --git-common-dir 2>$null | Select-Object -First 1).Trim()
    if (-not $common) { throw 'ROUTER_GIT_COMMON_DIR: Cannot locate main checkout.' }
    $main = Split-Path -Parent $common
    return [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $main) 'model-router/state'))
}

function Test-RouterTable {
    param([Parameter(Mandatory)][object]$Table)
    $errors = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Table -or $Table -isnot [pscustomobject]) { return @('ROOT_OBJECT: table must be an object') }
    foreach ($field in @('schema_version','generated_at','source','categories')) {
        if (-not $Table.PSObject.Properties[$field]) { $errors.Add("ROOT_FIELD: missing $field") }
    }
    if ($errors.Count -gt 0) { return $errors.ToArray() }
    if ($Table.schema_version -isnot [long] -or $Table.schema_version -ne 1) { $errors.Add('SCHEMA_VERSION: expected integer 1') }
    $date = [datetimeoffset]::MinValue
    if ($Table.generated_at -isnot [string] -or -not [datetimeoffset]::TryParse($Table.generated_at, [ref]$date)) { $errors.Add('GENERATED_AT: expected ISO date') }
    if ($Table.source -notin @('seed','research')) { $errors.Add('SOURCE: expected seed or research') }
    if ($Table.categories -isnot [pscustomobject]) { $errors.Add('CATEGORIES: expected object'); return $errors.ToArray() }
    $expected = @(Get-RouterCategories)
    foreach ($category in $expected) {
        $cp = $Table.categories.PSObject.Properties[$category]
        if (-not $cp -or $cp.Value -isnot [pscustomobject]) { $errors.Add("CATEGORY: missing or invalid $category"); continue }
        $lanes = if ($category -eq 'image-generation') { @('codex') } else { @('codex','claude') }
        foreach ($lane in $lanes) {
            $lp = $cp.Value.PSObject.Properties[$lane]
            if (-not $lp -or $lp.Value -isnot [pscustomobject]) { $errors.Add("LANE: missing or invalid $category/$lane"); continue }
            $entry = $lp.Value
            if ($entry.PSObject.Properties['fallback'] -and $entry.fallback -is [string] -and $entry.fallback) { $fallback = $entry.fallback } else { $errors.Add("FALLBACK: missing $category/$lane"); $fallback = '' }
            if (-not $entry.PSObject.Properties['candidates'] -or $entry.candidates -isnot [array] -or @($entry.candidates).Count -eq 0) { $errors.Add("CANDIDATES: missing $category/$lane"); continue }
            $ids = @{}; $ranks = @{}; $fallbackFound = $false
            foreach ($candidate in $entry.candidates) {
                $where = "$category/$lane"
                if ($candidate -isnot [pscustomobject]) { $errors.Add("CANDIDATE: invalid $where"); continue }
                $fields = @('model','frontier','strength_rank','grade','citations','est_burn','est_seconds','pass_rate','pass_samples')
                $missing = @($fields | Where-Object { -not $candidate.PSObject.Properties[$_] })
                if ($missing.Count) { $errors.Add("CANDIDATE_FIELDS: $where missing $($missing -join ',')"); continue }
                $id = [string]$candidate.model
                if (-not $id -or $ids.ContainsKey($id)) { $errors.Add("MODEL_ID: blank or duplicate $where/$id") } else { $ids[$id] = $true }
                if ($candidate.frontier -isnot [bool]) { $errors.Add("FRONTIER: $where/$id") }
                if ($candidate.strength_rank -isnot [long] -or $candidate.strength_rank -lt 1 -or $ranks.ContainsKey([string]$candidate.strength_rank)) { $errors.Add("STRENGTH_RANK: $where/$id") } else { $ranks[[string]$candidate.strength_rank] = $true }
                if ($candidate.grade -notin @('strong','capable','weak','unknown')) { $errors.Add("GRADE: $where/$id") }
                if ($candidate.citations -isnot [array]) { $errors.Add("CITATIONS: $where/$id") } else {
                    foreach ($citation in $candidate.citations) {
                        if ($citation -isnot [pscustomobject] -or -not $citation.PSObject.Properties['source'] -or -not $citation.PSObject.Properties['url'] -or -not $citation.PSObject.Properties['independent'] -or -not $citation.PSObject.Properties['note'] -or -not $citation.source -or -not ([uri]::IsWellFormedUriString([string]$citation.url,[System.UriKind]::Absolute)) -or $citation.independent -isnot [bool] -or $citation.note -isnot [string]) { $errors.Add("CITATION: $where/$id") }
                    }
                }
                foreach ($number in @('est_burn','est_seconds','pass_rate')) {
                    $value = $candidate.$number
                    if ($null -ne $value -and ($value -isnot [valuetype] -or $value -is [bool] -or [double]$value -lt 0 -or ($number -eq 'pass_rate' -and [double]$value -gt 1))) { $errors.Add("$($number.ToUpper()): $where/$id") }
                }
                if ($candidate.pass_samples -isnot [long] -or $candidate.pass_samples -lt 0) { $errors.Add("PASS_SAMPLES: $where/$id") }
                if ($id -eq $fallback -and $candidate.frontier -eq $false) { $fallbackFound = $true }
            }
            if (-not $fallbackFound) { $errors.Add("FALLBACK_MODEL: $category/$lane fallback must be a non-frontier candidate") }
            $top = @($entry.candidates | Where-Object { $_.PSObject.Properties['frontier'] -and $_.frontier -eq $false } | Sort-Object strength_rank | Select-Object -First 1)
            if ($top.Count -gt 0 -and $fallback -ne $top[0].model) { $errors.Add("FALLBACK_RANK: $category/$lane fallback is not strongest non-frontier") }
        }
        foreach ($actual in $cp.Value.PSObject.Properties.Name) { if ($actual -notin $lanes) { $errors.Add("LANE_EXTRA: $category/$actual") } }
    }
    foreach ($actual in $Table.categories.PSObject.Properties.Name) { if ($actual -notin $expected) { $errors.Add("CATEGORY_EXTRA: $actual") } }
    return $errors.ToArray()
}

function Read-RouterTable {
    param([string]$TablePath)
    $seed = Join-Path $PSScriptRoot '../../references/model-router/seed-table.json'
    $live = if ($TablePath) { $TablePath } else { Join-Path (Get-RouterStateDir) 'router-table.json' }
    if (Test-Path -LiteralPath $live) {
        try {
            $table = Get-Content -LiteralPath $live -Raw | ConvertFrom-Json -Depth 30
            if (@(Test-RouterTable -Table $table).Count -eq 0) { return [pscustomobject]@{ table = $table; source = 'live' } }
        } catch { }
    }
    $table = Get-Content -LiteralPath $seed -Raw | ConvertFrom-Json -Depth 30
    $errors = @(Test-RouterTable -Table $table)
    if ($errors.Count) { throw "SEED_TABLE_INVALID: $($errors -join '; ')" }
    return [pscustomobject]@{ table = $table; source = 'seed' }
}
