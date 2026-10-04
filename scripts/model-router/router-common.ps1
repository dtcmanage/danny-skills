Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-platform.ps1')

function Get-RouterBenchEvidenceContext {
    $benchRoot = Join-Path $PSScriptRoot 'bench'
    $python = $null
    foreach ($name in @('python', 'python3', 'py')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $python = $cmd.Source; break }
    }
    if (-not $python) { throw 'BENCH_IDENTITY_FAILED: python not found on PATH' }
    $raw = & $python -c 'import sys,json; from pathlib import Path; sys.path.insert(0,sys.argv[1]); from review import bank_hash; p=Path(sys.argv[1])/"tasks"; print(json.dumps({"task_bank_sha256":bank_hash(p),"rubric_jobs":sorted({json.loads(t.read_text(encoding="utf-8"))["job"] for t in p.glob("*/task.json") if json.loads(t.read_text(encoding="utf-8"))["grader"]=="rubric"})}))' $benchRoot
    if ($LASTEXITCODE -ne 0) { throw 'BENCH_IDENTITY_FAILED' }
    $bank = $raw | ConvertFrom-Json
    $defaults = Get-Content (Join-Path $benchRoot 'bench-config.json') -Raw | ConvertFrom-Json
    $configPath = Join-Path (Get-RouterStatePath) 'bench/judge-config.json'
    $config = if (Test-Path -LiteralPath $configPath) { Read-RouterJsonObject $configPath } else { $defaults }
    $effort = $null; if ($config -and $config.PSObject.Properties['judge_effort']) { $effort = $config.judge_effort } elseif ($config -and $defaults.PSObject.Properties['judge_effort']) { $effort = $defaults.judge_effort }
    $pair = if ($config -and $config.PSObject.Properties['judges']) { $config.judges } else { $null }
    return [pscustomobject]@{task_bank_sha256=$bank.task_bank_sha256;rubric_jobs=@($bank.rubric_jobs);judge_pair=$pair;judge_effort=$effort;approval=(Read-RouterJsonObject (Join-Path (Get-RouterStatePath) 'bench/golden-approval.json'))}
}

function New-RouterBenchProposalEvidence {
    param([string]$Job, [object]$Bench, [object]$Context)
    if (-not $Context) { $Context = Get-RouterBenchEvidenceContext }
    if (-not $Bench.PSObject.Properties['task_bank_sha256']) { return $null }
    $rubric = $Context.rubric_jobs -contains $Job
    if ($rubric -and (-not $Bench.PSObject.Properties['judge_pair'] -or -not $Bench.PSObject.Properties['judge_effort'])) { return $null }
    $pair = if ($rubric) { [pscustomobject][ordered]@{claude=$Bench.judge_pair.claude;codex=$Bench.judge_pair.codex} } else { $null }
    return [pscustomobject][ordered]@{task_bank_sha256=$Bench.task_bank_sha256;judge_pair=$pair;judge_effort=$(if ($rubric) {$Bench.judge_effort} else {$null})}
}

function Get-RouterBenchProposalEvidenceError {
    param([string]$Job, [object]$Evidence, [object]$Context)
    if (-not $Evidence -or -not $Evidence.PSObject.Properties['task_bank_sha256']) { return 'Legacy benchmark evidence; rerun the comparison.' }
    if (-not $Context) { $Context = Get-RouterBenchEvidenceContext }
    if ($Evidence.task_bank_sha256 -cne $Context.task_bank_sha256) { return 'Task bank changed; rerun the comparison.' }
    $approval = $Context.approval
    if (-not $approval -or -not $approval.PSObject.Properties['approved'] -or $approval.approved -isnot [bool] -or -not $approval.approved -or -not $approval.PSObject.Properties['task_bank_sha256'] -or $approval.task_bank_sha256 -cne $Context.task_bank_sha256) { return 'Current task bank needs golden approval.' }
    if ($Context.rubric_jobs -contains $Job) {
        if ($Context.judge_pair -isnot [pscustomobject] -or (@($Context.judge_pair.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'claude,codex' -or $Context.judge_pair.claude -isnot [string] -or $Context.judge_pair.codex -isnot [string] -or -not $Context.judge_pair -or -not $Context.judge_pair.PSObject.Properties['claude'] -or -not $Context.judge_pair.PSObject.Properties['codex'] -or -not $Context.judge_pair.claude -or -not $Context.judge_pair.codex -or $Context.judge_pair.claude -ceq $Context.judge_pair.codex) { return 'Current judge configuration is invalid; repair it and rerun the comparison.' }
        if (-not $Evidence.PSObject.Properties['judge_pair'] -or -not $Evidence.judge_pair -or -not $Evidence.PSObject.Properties['judge_effort']) { return 'Legacy judge evidence; rerun the comparison.' }
        if ($Context.judge_effort -isnot [string] -or $Context.judge_effort -cnotin @('low','medium','high') -or $Evidence.judge_effort -cne $Context.judge_effort) { return 'Judge effort changed or invalid; rerun the comparison.' }
        foreach ($vendor in @('claude','codex')) {
            if (-not $Evidence.judge_pair.PSObject.Properties[$vendor] -or $Evidence.judge_pair.$vendor -cne $Context.judge_pair.$vendor) { return 'Judge pair changed; rerun the comparison.' }
        }
    }
    return $null
}

function Test-RouterFrontierModel {
    param([string]$Model, [object]$Frontier)
    if (-not $Frontier) { $Frontier = Get-Content (Join-Path $PSScriptRoot '../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json }
    return ($Model -match '^gpt-\d+(?:\.\d+)?-astra$' -or $Frontier.codex_models -contains $Model -or @($Frontier.claude_patterns | Where-Object { $Model -like $_ }).Count -gt 0)
}

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

function Get-RouterTierEffort {
    param([object]$Entry, [string]$Slot, [string]$Difficulty = 'standard')
    $tiers = $Entry.PSObject.Properties["${Slot}_efforts"]
    if ($tiers) { return $tiers.Value.$Difficulty }
    return $Entry.("${Slot}_effort")
}

function Test-RouterDifficulty {
    param([string]$Difficulty, [string]$DifficultyReason)
    if ($Difficulty -eq 'hard') {
        if ([string]::IsNullOrWhiteSpace($DifficultyReason) -or $DifficultyReason.Length -gt 240 -or $DifficultyReason -match '[\r\n\u0085\u2028\u2029]') { throw 'DIFFICULTY_REASON_REQUIRED: hard requires a single-line reason of at most 240 characters.' }
    } elseif ($DifficultyReason) { throw 'DIFFICULTY_REASON_REFUSED: a reason is only allowed for hard.' }
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
            $tiers = $entry.PSObject.Properties["${slot}_efforts"]
            if ($tiers) {
                if ($job -notin @('coder','deep-thinker') -or $tiers.Value -isnot [pscustomobject]) { $errors.Add("ROSTER_TIER_EFFORT: $job/$slot") }
                else {
                    foreach ($tier in @('standard','hard')) {
                        if (-not $tiers.Value.PSObject.Properties[$tier] -or $tiers.Value.$tier -cnotin @('low','medium','high')) { $errors.Add("ROSTER_TIER_EFFORT: $job/$slot/$tier") }
                    }
                    foreach ($tier in $tiers.Value.PSObject.Properties.Name) { if ($tier -cnotin @('standard','hard')) { $errors.Add("ROSTER_TIER_EFFORT_EXTRA: $job/$slot/$tier") } }
                }
            }
            if (-not $effort) { $errors.Add("ROSTER_EFFORT: $job/$slot"); continue }
            if ($effort.Value -cin @('low','medium','high') -and $tiers -and $tiers.Value -is [pscustomobject] -and $tiers.Value.PSObject.Properties['standard'] -and $effort.Value -cne $tiers.Value.standard) { $errors.Add("ROSTER_EFFORT_MISMATCH: $job/$slot") }
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

function Get-RouterTieEvidenceError {
    param([object]$Entry, [object]$Evidence, [switch]$CurrentBank)
    try {
        if (-not $Evidence -or $Evidence.tier -cnotin @('standard','hard') -or -not $Evidence.run_id -or -not $Evidence.bank_hash) { return 'Missing or unsupported tie evidence.' }
        $pair = @($Evidence.configurations.candidate, $Evidence.configurations.incumbent)
        if ($pair.Count -ne 2 -or $Entry.first -ceq $Entry.backup) { return 'Tie pair is invalid.' }
        foreach ($slot in @('first','backup')) {
            $matching = @($pair | Where-Object { $_.model -ceq $Entry.$slot -and $_.effort -ceq (Get-RouterTierEffort -Entry $Entry -Slot $slot -Difficulty $Evidence.tier) })
            if ($matching.Count -ne 1) { return 'Roster model or effort changed.' }
        }
        $bank = if ($CurrentBank) { Get-RouterBenchEvidenceContext } else {
            Read-RouterJsonObject -Path (Join-Path (Get-RouterStatePath) 'bench/bank-hash.json')
        }
        if (-not $bank -or -not $bank.task_bank_sha256 -or $Evidence.bank_hash -cne $bank.task_bank_sha256) { return 'Task bank changed or hash unavailable.' }
    } catch { return 'Malformed or unverifiable tie evidence.' }
    return $null
}
