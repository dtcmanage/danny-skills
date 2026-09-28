Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RouterCategories {
    return @('complex-coding','routine-coding','code-review','ui-frontend','planning','deep-research','long-form-writing','mechanical','image-generation')
}

function Test-RouterReadings {
    param([object]$Readings, [Parameter(Mandatory)][string]$Category, [Parameter(Mandatory)][string[]]$Models)
    if ($Readings -isnot [pscustomobject] -or -not $Readings.PSObject.Properties['category'] -or $Readings.category -cne $Category -or $Readings.sources_checked -isnot [array] -or $Readings.readings -isnot [array]) { return $false }
    foreach ($source in $Readings.sources_checked) {
        if ($null -eq $source) { return $false }
        if (@('name','comparable_results_found','note' | Where-Object { -not $source.PSObject.Properties[$_] }).Count) { return $false }
        if ($source -isnot [pscustomobject] -or $source.name -isnot [string] -or $source.comparable_results_found -isnot [bool] -or $source.note -isnot [string]) { return $false }
    }
    foreach ($reading in $Readings.readings) {
        if ($null -eq $reading) { return $false }
        if (@('benchmark','version','date','harness','effort_class','independent','url','results' | Where-Object { -not $reading.PSObject.Properties[$_] }).Count) { return $false }
        if ($reading -isnot [pscustomobject] -or $reading.benchmark -isnot [string] -or -not $reading.benchmark -or $reading.version -isnot [string] -or $reading.date -isnot [string] -or $reading.harness -isnot [string] -or $reading.effort_class -isnot [string] -or $reading.independent -isnot [bool] -or $reading.url -isnot [string] -or $reading.results -isnot [array]) { return $false }
        $parsed = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse($reading.date,[ref]$parsed)) { return $false }
        foreach ($result in $reading.results) {
            if ($null -eq $result) { return $false }
            if (@('model','score','tasks','margin' | Where-Object { -not $result.PSObject.Properties[$_] }).Count) { return $false }
            if ($result -isnot [pscustomobject] -or $result.model -isnot [string] -or $Models -cnotcontains $result.model) { return $false }
            if ($result.score -isnot [valuetype] -or $result.score -is [bool] -or -not [double]::IsFinite([double]$result.score)) { return $false }
            if ($null -ne $result.tasks -and ($result.tasks -isnot [long] -or $result.tasks -lt 0)) { return $false }
            if ($null -ne $result.margin -and ($result.margin -isnot [valuetype] -or $result.margin -is [bool] -or -not [double]::IsFinite([double]$result.margin))) { return $false }
        }
    }
    return $true
}

function Get-RouterJobs { return @('fast','coder','deep-thinker','writer','illustrator') }

function Get-RouterCategoryJob {
    param([Parameter(Mandatory)][string]$Category)
    $map = @{ mechanical='fast'; 'routine-coding'='coder'; 'complex-coding'='coder'; 'ui-frontend'='coder'; 'code-review'='deep-thinker'; planning='deep-thinker'; 'deep-research'='deep-thinker'; math='deep-thinker'; analysis='deep-thinker'; 'long-form-writing'='writer'; 'image-generation'='illustrator' }
    if (-not $map.ContainsKey($Category)) { throw "CATEGORY: Unknown category '$Category'" }
    return $map[$Category]
}

function Test-RouterRoster {
    param([Parameter(Mandatory)][object]$Roster)
    $errors = [System.Collections.Generic.List[string]]::new()
    if ($Roster -isnot [pscustomobject]) { return @('ROSTER_ROOT: expected object') }
    foreach ($field in @('schema_version','generated_at','approved','approved_at','category_jobs','jobs')) {
        if (-not $Roster.PSObject.Properties[$field]) { $errors.Add("ROSTER_FIELD: missing $field") }
    }
    if ($errors.Count) { return $errors.ToArray() }
    if ($Roster.schema_version -isnot [long] -or $Roster.schema_version -ne 1) { $errors.Add('ROSTER_SCHEMA_VERSION: expected integer 1') }
    $date = [datetimeoffset]::MinValue
    if ($Roster.generated_at -isnot [string] -and $Roster.generated_at -isnot [datetime] -and $Roster.generated_at -isnot [datetimeoffset]) { $errors.Add('ROSTER_GENERATED_AT: expected ISO date') }
    elseif (-not [datetimeoffset]::TryParse([string]$Roster.generated_at,[ref]$date)) { $errors.Add('ROSTER_GENERATED_AT: expected ISO date') }
    if ($Roster.approved -isnot [bool]) { $errors.Add('ROSTER_APPROVED: expected Boolean') }
    if ($null -ne $Roster.approved_at -and $Roster.approved_at -isnot [string] -and $Roster.approved_at -isnot [datetime] -and $Roster.approved_at -isnot [datetimeoffset]) { $errors.Add('ROSTER_APPROVED_AT: expected ISO date or null') }
    elseif ($null -ne $Roster.approved_at -and -not [datetimeoffset]::TryParse([string]$Roster.approved_at,[ref]$date)) { $errors.Add('ROSTER_APPROVED_AT: expected ISO date or null') }
    if ($Roster.approved -eq $true -and $null -eq $Roster.approved_at) { $errors.Add('ROSTER_APPROVED_AT: approved roster needs date') }
    if ($Roster.category_jobs -isnot [pscustomobject]) { $errors.Add('ROSTER_CATEGORY_JOBS: expected object') }
    else {
        $categories = @('mechanical','routine-coding','complex-coding','ui-frontend','code-review','planning','deep-research','math','analysis','long-form-writing','image-generation')
        foreach ($category in $categories) {
            $p = $Roster.category_jobs.PSObject.Properties[$category]
            if (-not $p -or $p.Value -cne (Get-RouterCategoryJob -Category $category)) { $errors.Add("ROSTER_CATEGORY_JOB: $category") }
        }
        foreach ($name in $Roster.category_jobs.PSObject.Properties.Name) { if ($name -notin $categories) { $errors.Add("ROSTER_CATEGORY_EXTRA: $name") } }
    }
    if ($Roster.jobs -isnot [pscustomobject]) { $errors.Add('ROSTER_JOBS: expected object'); return $errors.ToArray() }
    $models = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $frontier = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json
    foreach ($job in @(Get-RouterJobs)) {
        $p = $Roster.jobs.PSObject.Properties[$job]
        if (-not $p -or $p.Value -isnot [pscustomobject]) { $errors.Add("ROSTER_JOB: missing or invalid $job"); continue }
        $entry = $p.Value
        foreach ($field in @('first','first_vendor','backup','backup_vendor')) { if (-not $entry.PSObject.Properties[$field]) { $errors.Add("ROSTER_JOB_FIELD: $job/$field") } }
        if (@(@('first','first_vendor','backup','backup_vendor') | Where-Object { -not $entry.PSObject.Properties[$_] }).Count) { continue }
        if ($entry.first -isnot [string] -or -not $entry.first.Trim()) { $errors.Add("ROSTER_FIRST: $job") }
        if ($entry.first_vendor -cnotin @('codex','claude')) { $errors.Add("ROSTER_FIRST_VENDOR: $job") }
        if ($job -eq 'illustrator') {
            if ($null -ne $entry.backup -or $null -ne $entry.backup_vendor) { $errors.Add('ROSTER_ILLUSTRATOR_BACKUP: must be null') }
        } else {
            if ($entry.backup -isnot [string] -or -not $entry.backup.Trim()) { $errors.Add("ROSTER_BACKUP: $job") }
            if ($entry.backup_vendor -cnotin @('codex','claude')) { $errors.Add("ROSTER_BACKUP_VENDOR: $job") }
            if ($entry.first_vendor -eq $entry.backup_vendor) { $errors.Add("ROSTER_VENDOR_PAIR: $job") }
        }
        foreach ($slot in @('first','backup')) {
            $id = $entry.$slot
            if ($id -isnot [string] -or -not $id) { continue }
            [void]$models.Add($id)
            $vendor = $entry."${slot}_vendor"
            if (($id -like 'claude-*' -and $vendor -ne 'claude') -or ($id -like 'gpt-*' -and $vendor -ne 'codex') -or ($id -notlike 'claude-*' -and $id -notlike 'gpt-*')) { $errors.Add("ROSTER_MODEL_VENDOR: $job/$slot") }
            if ($frontier.codex_models -contains $id -or @($frontier.claude_patterns | Where-Object { $id -like $_ }).Count) { $errors.Add("ROSTER_FRONTIER: $job/$slot") }
        }
    }
    foreach ($name in $Roster.jobs.PSObject.Properties.Name) { if ($name -notin @(Get-RouterJobs)) { $errors.Add("ROSTER_JOB_EXTRA: $name") } }
    if ($models.Count -gt 5) { $errors.Add('ROSTER_MODEL_CAP: maximum 5 distinct models') }
    return $errors.ToArray()
}

function Read-RouterRoster {
    $defaultPath = Join-Path $PSScriptRoot '../../references/model-router/default-roster.json'
    $statePath = Join-Path (Get-RouterStateDir) 'roster.json'
    $validationError = $null
    if (Test-Path -LiteralPath $statePath) {
        try {
            $roster = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -Depth 20
            $errors = @(Test-RouterRoster -Roster $roster)
            if (-not $errors.Count -and $roster.approved -eq $true) { return [pscustomobject]@{ roster=$roster; source='state'; validation_error=$null } }
            if ($errors.Count) { $validationError = $errors -join '; ' }
        } catch { $validationError = "ROSTER_PARSE: $($_.Exception.Message)" }
    }
    $roster = Get-Content -LiteralPath $defaultPath -Raw | ConvertFrom-Json -Depth 20
    $errors = @(Test-RouterRoster -Roster $roster)
    if ($errors.Count) { throw "DEFAULT_ROSTER_INVALID: $($errors -join '; ')" }
    return [pscustomobject]@{ roster=$roster; source='default'; validation_error=$validationError }
}

function Get-RouterModelGeneration {
    param([Parameter(Mandatory)][string]$Model)
    if ($Model -match '^gpt-(\d+)(?:\.(\d+))?(?:-|$)') {
        return [pscustomobject]@{ vendor = 'gpt'; major = [long]$Matches[1]; minor = $(if ($Matches[2]) { [long]$Matches[2] } else { [long]0 }) }
    }
    if ($Model -match '^claude-(?:opus|sonnet|haiku|fable)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?$') {
        return [pscustomobject]@{ vendor = 'claude'; major = [long]$Matches[1]; minor = $(if ($Matches[2]) { [long]$Matches[2] } else { [long]0 }) }
    }
    return $null
}

function Get-RouterPriceKey {
    param([string]$Model, [object]$Models)
    if (-not $Model -or -not $Models) { return $null }
    if ($Models.PSObject.Properties[$Model]) { return $Model }
    if ($Model -match '^(.*)-\d{8}$' -and $Models.PSObject.Properties[$Matches[1]]) { return $Matches[1] }
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
    foreach ($field in @('schema_version','generated_at','source','coverage','categories')) {
        if (-not $Table.PSObject.Properties[$field]) { $errors.Add("ROOT_FIELD: missing $field") }
    }
    if ($errors.Count -gt 0) { return $errors.ToArray() }
    if ($Table.schema_version -isnot [long] -or $Table.schema_version -ne 1) { $errors.Add('SCHEMA_VERSION: expected integer 1') }
    $date = [datetimeoffset]::MinValue
    if ($Table.generated_at -isnot [string] -and $Table.generated_at -isnot [datetime] -and $Table.generated_at -isnot [datetimeoffset]) { $errors.Add('GENERATED_AT: expected ISO date') }
    elseif (-not [datetimeoffset]::TryParse([string]$Table.generated_at, [ref]$date)) { $errors.Add('GENERATED_AT: expected ISO date') }
    if ($Table.source -notin @('seed','research')) { $errors.Add('SOURCE: expected seed or research') }
    if ($Table.coverage -cnotin @('partial','full')) { $errors.Add('COVERAGE: expected partial or full') }
    if ($Table.PSObject.Properties['evidence_routing_approved'] -and $Table.evidence_routing_approved -isnot [bool]) { $errors.Add('APPROVAL: expected Boolean') }
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
                $fields = @('model','frontier','strength_rank','grade','citations','est_burn','est_seconds','pass_rate','pass_samples')
                $missing = @($fields | Where-Object { -not $candidate.PSObject.Properties[$_] })
                if ($missing.Count) { $errors.Add("CANDIDATE_FIELDS: $where missing $($missing -join ',')"); continue }
                $id = [string]$candidate.model
                if (-not $id -or $ids.ContainsKey($id)) { $errors.Add("MODEL_ID: blank or duplicate $where/$id") } else { $ids[$id] = $true }
                if ($candidate.frontier -isnot [bool]) { $errors.Add("FRONTIER: $where/$id") }
                if ($candidate.strength_rank -isnot [long] -or $candidate.strength_rank -lt 1 -or $ranks.ContainsKey([string]$candidate.strength_rank)) { $errors.Add("STRENGTH_RANK: $where/$id") } else { $ranks[[string]$candidate.strength_rank] = $true }
                if ($candidate.grade -notin @('strong','capable','weak','unknown')) { $errors.Add("GRADE: $where/$id") }
                if ($candidate.PSObject.Properties['confirmed_grade'] -and $candidate.confirmed_grade -notin @('strong','capable','weak','unknown')) { $errors.Add("CONFIRMED_GRADE: $where/$id") }
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
            if ($validation.Count -eq 0) {
                if (-not $table.PSObject.Properties['evidence_routing_approved']) { $table | Add-Member -NotePropertyName evidence_routing_approved -NotePropertyValue $false }
                $missingConfirmedGrade = $false
                foreach ($category in $table.categories.PSObject.Properties.Name) {
                    foreach ($lane in $table.categories.$category.PSObject.Properties.Name) {
                        foreach ($candidate in $table.categories.$category.$lane.candidates) {
                            if (-not $candidate.PSObject.Properties['confirmed_grade']) {
                                $candidate | Add-Member -NotePropertyName confirmed_grade -NotePropertyValue 'unknown'
                                $missingConfirmedGrade = $true
                            }
                        }
                    }
                }
                if ($missingConfirmedGrade) { $table.evidence_routing_approved = $false }
                return [pscustomobject]@{ table = $table; source = 'live'; validation_error = $null }
            }
            $liveError = $validation -join '; '
        } catch { $liveError = $_.Exception.Message }
    }
    $table = Get-Content -LiteralPath $seed -Raw | ConvertFrom-Json -Depth 30
    $errors = @(Test-RouterTable -Table $table)
    if ($errors.Count) { throw "SEED_TABLE_INVALID: $($errors -join '; ')" }
    return [pscustomobject]@{ table = $table; source = 'seed'; validation_error = $liveError }
}
