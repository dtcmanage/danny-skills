Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RouterCategories {
    return @('complex-coding','routine-coding','code-review','ui-frontend','planning','deep-research','long-form-writing','mechanical','image-generation')
}

function Get-RouterModelGeneration {
    param([Parameter(Mandatory)][string]$Model)
    if ($Model -match '^gpt-(\d+)(?:\.(\d+))?(?:-|$)') {
        return [pscustomobject]@{ vendor = 'gpt'; major = [long]$Matches[1]; minor = $(if ($Matches[2]) { [long]$Matches[2] } else { [long]0 }) }
    }
    if ($Model -match '^claude-(?:opus|sonnet|haiku|fable)-(\d+)-(\d+)(?:-|$)') {
        return [pscustomobject]@{ vendor = 'claude'; major = [long]$Matches[1]; minor = [long]$Matches[2] }
    }
    return $null
}

function Get-RouterGradeRank {
    param([string]$Grade)
    switch ($Grade) { 'strong' { return 3 }; 'capable' { return 2 }; 'weak' { return 1 }; default { return 0 } }
}

function Get-RouterStateDir {
    if ($env:DT_MODEL_ROUTER_STATE) { $state = [System.IO.Path]::GetFullPath($env:DT_MODEL_ROUTER_STATE) }
    else {
        $common = & git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir 2>$null | Select-Object -First 1
        if (-not $common) { throw 'ROUTER_GIT_COMMON_DIR: Cannot locate main checkout.' }
        $common = $common.Trim()
        $main = Split-Path -Parent $common
        $state = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $main) 'model-router/state'))
    }
    [IO.Directory]::CreateDirectory($state) | Out-Null
    $ignore = Join-Path $state '.gitignore'
    if (-not (Test-Path -LiteralPath $ignore)) {
        try { [IO.File]::WriteAllText($ignore, "*`n", [Text.UTF8Encoding]::new($false)) }
        catch [IO.IOException] { if (-not (Test-Path -LiteralPath $ignore)) { throw } }
    }
    return $state
}

function Read-RouterJsonArray {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $raw = [IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        return @($raw | ConvertFrom-Json -Depth 20 | Where-Object { $null -ne $_ })
    } catch { return @() }
}

function Read-RouterJsonObject {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -Depth 20)
    } catch { return $null }
}

function Use-RouterQueueMutex {
    param([Parameter(Mandatory)][string]$StateDir, [Parameter(Mandatory)][scriptblock]$Action, [int]$TimeoutMs = 30000)
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $path = Join-Path $StateDir 'pending-research.mutex'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $handle = $null
    while ($null -eq $handle) {
        try { $handle = [IO.FileStream]::new($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,1,[IO.FileOptions]::DeleteOnClose) }
        catch [IO.IOException], [UnauthorizedAccessException] {
            if ($watch.ElapsedMilliseconds -ge $TimeoutMs) { throw 'ROUTER_QUEUE_MUTEX_TIMEOUT' }
            Start-Sleep -Milliseconds 50
        }
    }
    try { & $Action } finally { $handle.Dispose() }
}

function Test-RouterTable {
    param([Parameter(Mandatory)][object]$Table)
    $errors = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Table -or $Table -isnot [pscustomobject]) { return @('ROOT_OBJECT: table must be an object') }
    foreach ($field in @('schema_version','generated_at','source','coverage','evidence_routing_approved','categories')) {
        if (-not $Table.PSObject.Properties[$field]) { $errors.Add("ROOT_FIELD: missing $field") }
    }
    if ($errors.Count -gt 0) { return $errors.ToArray() }
    if ($Table.schema_version -isnot [long] -or $Table.schema_version -ne 1) { $errors.Add('SCHEMA_VERSION: expected integer 1') }
    $date = [datetimeoffset]::MinValue
    if ($Table.generated_at -isnot [string] -and $Table.generated_at -isnot [datetime] -and $Table.generated_at -isnot [datetimeoffset]) { $errors.Add('GENERATED_AT: expected ISO date') }
    elseif (-not [datetimeoffset]::TryParse([string]$Table.generated_at, [ref]$date)) { $errors.Add('GENERATED_AT: expected ISO date') }
    if ($Table.source -notin @('seed','research')) { $errors.Add('SOURCE: expected seed or research') }
    if ($Table.coverage -cnotin @('partial','full')) { $errors.Add('COVERAGE: expected partial or full') }
    if ($Table.evidence_routing_approved -isnot [bool]) { $errors.Add('APPROVAL: expected Boolean') }
    if ($Table.PSObject.Properties['approved_picks'] -and $null -ne $Table.approved_picks -and $Table.approved_picks -isnot [array]) { $errors.Add('APPROVED_PICKS: expected array') }
    if ($Table.source -eq 'seed' -and $Table.coverage -cne 'partial') { $errors.Add('COVERAGE: seed must be partial') }
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
                $fields = @('model','frontier','strength_rank','grade','confirmed_grade','citations','est_burn','est_seconds','pass_rate','pass_samples')
                $missing = @($fields | Where-Object { -not $candidate.PSObject.Properties[$_] })
                if ($missing.Count) { $errors.Add("CANDIDATE_FIELDS: $where missing $($missing -join ',')"); continue }
                $id = [string]$candidate.model
                if (-not $id -or $ids.ContainsKey($id)) { $errors.Add("MODEL_ID: blank or duplicate $where/$id") } else { $ids[$id] = $true }
                if ($candidate.frontier -isnot [bool]) { $errors.Add("FRONTIER: $where/$id") }
                if ($candidate.strength_rank -isnot [long] -or $candidate.strength_rank -lt 1 -or $ranks.ContainsKey([string]$candidate.strength_rank)) { $errors.Add("STRENGTH_RANK: $where/$id") } else { $ranks[[string]$candidate.strength_rank] = $true }
                if ($candidate.grade -notin @('strong','capable','weak','unknown')) { $errors.Add("GRADE: $where/$id") }
                if ($candidate.confirmed_grade -notin @('strong','capable','weak','unknown')) { $errors.Add("CONFIRMED_GRADE: $where/$id") }
                if ($candidate.citations -isnot [array]) { $errors.Add("CITATIONS: $where/$id") } else {
                    foreach ($citation in $candidate.citations) {
                        if ($citation -isnot [pscustomobject] -or -not $citation.PSObject.Properties['source'] -or -not $citation.PSObject.Properties['url'] -or -not $citation.PSObject.Properties['independent'] -or -not $citation.PSObject.Properties['note'] -or -not $citation.source -or -not ([uri]::IsWellFormedUriString([string]$citation.url,[System.UriKind]::Absolute)) -or $citation.independent -isnot [bool] -or $citation.note -isnot [string]) { $errors.Add("CITATION: $where/$id") }
                    }
                }
                foreach ($number in @('est_burn','est_seconds','pass_rate')) {
                    $value = $candidate.$number
                    if ($null -ne $value -and ($value -isnot [valuetype] -or $value -is [bool] -or -not [double]::IsFinite([double]$value) -or [double]$value -lt 0 -or [double]$value -gt 1000000000000.0 -or ($number -eq 'pass_rate' -and [double]$value -gt 1))) { $errors.Add("$($number.ToUpper()): $where/$id") }
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
    $liveError = $null
    if (Test-Path -LiteralPath $live) {
        try {
            $table = Get-Content -LiteralPath $live -Raw | ConvertFrom-Json -Depth 30
            $validation = @(Test-RouterTable -Table $table)
            if ($validation.Count -eq 0) { return [pscustomobject]@{ table = $table; source = 'live'; validation_error = $null } }
            $liveError = $validation -join '; '
        } catch { $liveError = $_.Exception.Message }
    }
    $table = Get-Content -LiteralPath $seed -Raw | ConvertFrom-Json -Depth 30
    $errors = @(Test-RouterTable -Table $table)
    if ($errors.Count) { throw "SEED_TABLE_INVALID: $($errors -join '; ')" }
    return [pscustomobject]@{ table = $table; source = 'seed'; validation_error = $liveError }
}
