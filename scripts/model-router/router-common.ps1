Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-platform.ps1')

function Get-RouterCategories {
    return @('complex-coding','routine-coding','code-review','ui-frontend','planning','deep-research','long-form-writing','mechanical','image-generation')
}

function Get-RouterDispatchCategories {
    return @('complex-coding','routine-coding','code-review','ui-frontend','planning','deep-research','math','analysis','long-form-writing','mechanical','image-generation')
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

function Get-RouterJobEffort {
    param([Parameter(Mandatory)][ValidateSet('fast','coder','deep-thinker','writer','illustrator')][string]$Job)
    switch ($Job) {
        'fast' { return 'low' }
        'coder' { return 'medium' }
        'deep-thinker' { return 'high' }
        'writer' { return 'medium' }
        'illustrator' { return $null }
    }
}

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
        foreach ($slot in @('first','backup')) {
            $effort = $entry.PSObject.Properties["${slot}_effort"]
            if (-not $effort) { $errors.Add("ROSTER_EFFORT: $job/$slot"); continue }
            if ($job -eq 'illustrator') {
                if ($null -ne $effort.Value) { $errors.Add('ROSTER_EFFORT_ILLUSTRATOR: must be null') }
            } elseif ($effort.Value -cnotin @('low','medium','high')) { $errors.Add("ROSTER_EFFORT: $job/$slot") }
        }
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
    param([string]$Platform = (Get-RouterPlatform))
    $defaultPath = Join-Path $PSScriptRoot '../../references/model-router/default-roster.json'
    $statePath = if ($Platform -eq 'MacOS') { Join-Path (Get-RouterSharedDir) 'roster.json' } else { Join-Path (Get-RouterStatePath -Platform $Platform) 'roster.json' }
    $validationError = $null
    if (Test-Path -LiteralPath $statePath) {
        try {
            $roster = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -Depth 20
            $errors = @(Test-RouterRoster -Roster $roster)
            if (-not $errors.Count -and $roster.approved -eq $true) { return [pscustomobject]@{ roster=$roster; source=$(if ($Platform -eq 'MacOS') { 'shared' } else { 'state' }); validation_error=$null; path=$statePath } }
            if ($errors.Count) { $validationError = $errors -join '; ' }
        } catch { $validationError = "ROSTER_PARSE: $($_.Exception.Message)" }
    }
    $roster = Get-Content -LiteralPath $defaultPath -Raw | ConvertFrom-Json -Depth 20
    $errors = @(Test-RouterRoster -Roster $roster)
    if ($errors.Count) { throw "DEFAULT_ROSTER_INVALID: $($errors -join '; ')" }
    return [pscustomobject]@{ roster=$roster; source='default'; validation_error=$validationError; path=$statePath }
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

function Get-RouterModelTier {
    # Fixed size order used where "stronger" must not depend on per-category research scores:
    # protected work may only move up this order, and drift demotion steps up it.
    param([string]$Model)
    if ($Model -match '^claude-(haiku|sonnet|opus|fable)-') { return @{ haiku = 0; sonnet = 1; opus = 2; fable = 3 }[$Matches[1]] }
    if ($Model -match '^gpt-[0-9.]+-(luna|terra|sol|astra)$') { return @{ luna = 0; terra = 1; sol = 2; astra = 3 }[$Matches[1]] }
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
    $state = Get-RouterStatePath
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

function Write-RouterJsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value)
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temp = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth 20
        [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $Path, $true)
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Use-RouterOutcomeMutex {
    # Keep the file in place: unlinking a lock file can let waiters lock different inodes on Unix.
    # The OS releases the exclusive handle on process exit, including a crash.
    param([Parameter(Mandatory)][string]$StateDir, [Parameter(Mandatory)][scriptblock]$Action, [int]$TimeoutMs = 30000)
    [IO.Directory]::CreateDirectory($StateDir) | Out-Null
    $path = Join-Path $StateDir 'outcomes.mutex'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $handle = $null
    while ($null -eq $handle) {
        try { $handle = [IO.FileStream]::new($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if ($watch.ElapsedMilliseconds -ge $TimeoutMs) { throw 'ROUTER_OUTCOME_MUTEX_TIMEOUT' }
            Start-Sleep -Milliseconds 50
        }
    }
    try { & $Action } finally { $handle.Dispose() }
}

function Add-RouterOutcome {
    param([Parameter(Mandatory)][object]$Row, [string]$StateDir = (Get-RouterStateDir))
    Use-RouterOutcomeMutex -StateDir $StateDir -Action {
        [IO.File]::AppendAllText((Join-Path $StateDir 'outcomes.jsonl'), ((ConvertTo-Json -InputObject $Row -Compress -Depth 20) + "`n"), [Text.UTF8Encoding]::new($false))
    }
}
