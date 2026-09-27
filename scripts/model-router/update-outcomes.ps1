param([Alias('Now')][datetime]$RouterOutcomesCliNow = (Get-Date), [Alias('SourcesPath')][string]$RouterOutcomesCliSourcesPath, [Alias('Json')][switch]$RouterOutcomesCliJson)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')

function Get-RouterOutcomeValue {
    param([object]$Row, [string[]]$Names)
    if ($null -eq $Row) { return $null }
    foreach ($name in $Names) { if ($Row.PSObject.Properties[$name] -and $null -ne $Row.$name -and [string]$Row.$name) { return $Row.$name } }
    return $null
}

function ConvertTo-RouterOutcomeModel {
    param([string]$Model, [object]$Table)
    if (-not $Model) { return '' }
    $Model = $Model -replace '\s*\(.*$',''
    if ($Model -notin @('opus','sonnet','haiku')) { return $Model }
    $ids = @($Table.categories.'routine-coding'.claude.candidates | Where-Object { $_.model -match "^claude-$Model-" } | Sort-Object strength_rank)
    if ($ids.Count) { return [string]$ids[0].model }
    return $Model
}

function Get-RouterOutcomeCategory {
    param([object]$Record, [string]$Tier, [string]$Name)
    $category = Get-RouterOutcomeValue $Record @('category')
    if ($category -in @(Get-RouterCategories)) { return [string]$category }
    if ($Name -match '(?i)(verif|review)') { return 'code-review' }
    if ($Tier -eq 'complex') { return 'complex-coding' }
    return 'routine-coding'
}

function Update-RouterOutcomes {
    param([datetime]$Now = (Get-Date), [string]$SourcesPath)
    $state = Get-RouterStateDir
    [IO.Directory]::CreateDirectory($state) | Out-Null
    if (-not $SourcesPath) { $SourcesPath = Join-Path $PSScriptRoot '../../references/model-router/outcome-sources.json' }
    $roots = @([IO.File]::ReadAllText($SourcesPath) | ConvertFrom-Json)
    $tablePath = Join-Path $state 'router-table.json'
    $table = (Read-RouterTable -TablePath $tablePath).table
    $outcomePath = Join-Path $state 'outcomes.jsonl'
    $records = [ordered]@{}
    if (Test-Path -LiteralPath $outcomePath) {
        foreach ($line in [IO.File]::ReadAllLines($outcomePath)) {
            if (-not $line.Trim()) { continue }
            try { $row = $line | ConvertFrom-Json -Depth 20; if ($row.key) { $records[[string]$row.key] = $row } } catch { }
        }
    }
    $newCount = 0
    foreach ($root in $roots) {
        $build = Join-Path ([string]$root) '.dt-build'
        if (-not (Test-Path -LiteralPath $build -PathType Container)) { continue }
        $repo = Split-Path -Leaf ([string]$root)
        foreach ($run in @(Get-ChildItem -LiteralPath $build -Directory)) {
            $folders = [System.Collections.Generic.List[string]]::new()
            $folders.Add($run.FullName)
            $milestones = Join-Path $run.FullName 'milestones'
            if (Test-Path -LiteralPath $milestones -PathType Container) {
                foreach ($milestone in @(Get-ChildItem -LiteralPath $milestones -Directory)) { $folders.Add($milestone.FullName) }
            }
            foreach ($folder in $folders) {
                foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Filter '*.provenance.json')) {
                    try { $item = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -Depth 20 } catch { continue }
                    $model = ConvertTo-RouterOutcomeModel ([string](Get-RouterOutcomeValue $item @('resolved_model','model','requested_model'))) $table
                    if (-not $model) { continue }
                    $chunk = Get-RouterOutcomeValue $item @('chunk_id','milestone_id')
                    if (-not $chunk) { $chunk = if ($folder -ne $run.FullName) { Split-Path -Leaf $folder } else { $file.BaseName -replace '(?i)(-output|-result|\.md\.provenance).*$', '' } }
                    $attempt = Get-RouterOutcomeValue $item @('attempt')
                    if (-not $attempt) { $attempt = if ($file.Name -match '(?i)(?:-|_)(?:a|attempt)(\d+)') { [int]$Matches[1] } elseif ($file.Name -match '(?i)(?:-|_)(retry|fix|resume)') { 2 } else { 1 } }
                    $key = "$($run.Name):$chunk`:$attempt"
                    if ($records.Contains($key)) { continue }
                    $at = Get-RouterOutcomeValue $item @('at','accepted_at_utc','recorded_at_utc','model_cache_fetched_at')
                    if (-not $at) { $at = $file.LastWriteTimeUtc.ToString('o') }
                    try { $at = ([datetimeoffset]::Parse([string]$at)).ToUniversalTime().ToString('o') } catch { $at = $file.LastWriteTimeUtc.ToString('o') }
                    $tier = [string](Get-RouterOutcomeValue $item @('tier'))
                    $lane = [string](Get-RouterOutcomeValue $item @('lane'))
                    if ($lane -notin @('codex','claude')) { $lane = if ($model -match '^claude-') { 'claude' } else { 'codex' } }
                    $pass = Get-RouterOutcomeValue $item @('pass')
                    $records[$key] = [pscustomobject]@{ key=$key; run_id=$run.Name; repo=$repo; at=$at; lane=$lane; model=$model; category=(Get-RouterOutcomeCategory $item $tier $file.Name); attempt=[int]$attempt; pass=($pass -eq $true -or [string]$pass -eq 'true'); escalated=($file.Name -match '(?i)(?:-|_)(retry|fix|resume)'); failure_category=(Get-RouterOutcomeValue $item @('failure_category')); source='dt-build'; tier=$tier }
                    $newCount++
                }
                $acceptance = Join-Path $folder 'acceptance-rows.jsonl'
                if (-not (Test-Path -LiteralPath $acceptance)) { continue }
                foreach ($line in [IO.File]::ReadAllLines($acceptance)) {
                    try { $item = $line | ConvertFrom-Json -Depth 20 } catch { continue }
                    $chunk = Get-RouterOutcomeValue $item @('chunk_id','milestone_id')
                    if (-not $chunk) { continue }
                    $attempt = Get-RouterOutcomeValue $item @('attempt')
                    if (-not $attempt) { $attempt = 1 }
                    $key = "$($run.Name):$chunk`:$attempt"
                    if ($records.Contains($key)) { continue }
                    $builder = Get-RouterOutcomeValue $item @('builder')
                    $model = ConvertTo-RouterOutcomeModel ([string](Get-RouterOutcomeValue $item @('resolved_model','model','requested_model'))) $table
                    if (-not $model -and $builder) { $model = ConvertTo-RouterOutcomeModel ([string](Get-RouterOutcomeValue $builder @('resolved_model','model'))) $table }
                    if (-not $model) { continue }
                    $at = Get-RouterOutcomeValue $item @('accepted_at_utc','recorded_at_utc','at')
                    if (-not $at) { $at = (Get-Item -LiteralPath $acceptance).LastWriteTimeUtc.ToString('o') }
                    try { $at = ([datetimeoffset]::Parse([string]$at)).ToUniversalTime().ToString('o') } catch { continue }
                    $tier = [string](Get-RouterOutcomeValue $item @('tier'))
                    $lane = [string](Get-RouterOutcomeValue $item @('lane'))
                    if ($lane -notin @('codex','claude')) { $lane = if ($model -match '^claude-') { 'claude' } else { 'codex' } }
                    $records[$key] = [pscustomobject]@{ key=$key; run_id=$run.Name; repo=$repo; at=$at; lane=$lane; model=$model; category=(Get-RouterOutcomeCategory $item $tier ([string]$chunk)); attempt=[int]$attempt; pass=([string](Get-RouterOutcomeValue $item @('status')) -eq 'PASS'); escalated=$false; failure_category=(Get-RouterOutcomeValue $item @('failure_category')); source='dt-build'; tier=$tier }
                    $newCount++
                }
            }
        }
    }
    $values = @($records.Values)
    foreach ($row in $values) {
        if ($row.attempt -ne 1) { continue }
        $later = @($values | Where-Object { $_.run_id -eq $row.run_id -and $_.repo -eq $row.repo -and $_.key -match '^(.+):[^:]+:[^:]+$' -and ($_.key -replace ':[^:]+$','') -eq ($row.key -replace ':[^:]+$','') -and $_.attempt -gt 1 -and ($_.model -ne $row.model -or $_.tier -ne $row.tier) })
        if ($later.Count) { $row.escalated = $true }
    }
    if ($newCount) {
        $lines = @($values | Sort-Object key | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 })
        [IO.File]::WriteAllLines($outcomePath,$lines,[Text.UTF8Encoding]::new($false))
    }
    $nowUtc = $Now.ToUniversalTime()
    $eligible = @($values | Where-Object { $_.attempt -eq 1 -and $_.failure_category -notin @('environment','tooling') })
    $updated = 0
    foreach ($cp in $table.categories.PSObject.Properties) {
        foreach ($lp in $cp.Value.PSObject.Properties) {
            foreach ($candidate in $lp.Value.candidates) {
                $sample = @($eligible | Where-Object { $_.category -eq $cp.Name -and $_.lane -eq $lp.Name -and $_.model -eq $candidate.model -and ([datetime]$_.at) -ge $nowUtc.AddDays(-90) -and ([datetime]$_.at) -le $nowUtc })
                if ($sample.Count -lt 10) { continue }
                $rate = @($sample | Where-Object pass).Count / $sample.Count
                if ($candidate.pass_samples -ne $sample.Count -or $candidate.pass_rate -ne $rate) { $candidate.pass_samples = [long]$sample.Count; $candidate.pass_rate = [double]$rate; $updated++ }
            }
        }
    }
    if ($updated) {
        $errors = @(Test-RouterTable -Table $table)
        if ($errors.Count) { throw "OUTCOME_TABLE_INVALID: $($errors -join '; ')" }
        $tmp = "$tablePath.tmp"
        [IO.File]::WriteAllText($tmp,($table | ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($tmp,$tablePath,$true)
    }
    $flagsPath = Join-Path $state 'drift-flags.json'
    $priorFlags = @(Read-RouterJsonArray -Path $flagsPath)
    $flags = [System.Collections.Generic.List[object]]::new()
    $alerts = [System.Collections.Generic.List[string]]::new()
    foreach ($cp in $table.categories.PSObject.Properties) {
        foreach ($lp in $cp.Value.PSObject.Properties) {
            foreach ($candidate in $lp.Value.candidates) {
                $group = @($eligible | Where-Object { $_.category -eq $cp.Name -and $_.lane -eq $lp.Name -and $_.model -eq $candidate.model })
                $recent = @($group | Where-Object { ([datetime]$_.at) -ge $nowUtc.AddDays(-30) -and ([datetime]$_.at) -le $nowUtc })
                $prior = @($group | Where-Object { ([datetime]$_.at) -ge $nowUtc.AddDays(-120) -and ([datetime]$_.at) -lt $nowUtc.AddDays(-30) })
                if ($recent.Count -lt 10 -or $prior.Count -lt 10) { continue }
                $recentRate = @($recent | Where-Object pass).Count / $recent.Count
                $priorRate = @($prior | Where-Object pass).Count / $prior.Count
                if (($priorRate - $recentRate) -lt (0.15 - 1e-9)) { continue }
                $old = @($priorFlags | Where-Object { $_.category -eq $cp.Name -and $_.lane -eq $lp.Name -and $_.model -eq $candidate.model })
                $flaggedAt = if ($old.Count) { $old[0].flagged_at } else { $nowUtc.ToString('o') }
                $flags.Add([pscustomobject]@{ category=$cp.Name; lane=$lp.Name; model=$candidate.model; recent_rate=$recentRate; prior_rate=$priorRate; flagged_at=$flaggedAt })
                if (-not $old.Count) { $alerts.Add("drift:$($candidate.model):$($cp.Name):$($lp.Name):$($nowUtc.ToString('yyyyMM'))") }
            }
        }
    }
    foreach ($old in $priorFlags) { if (-not @($flags | Where-Object { $_.category -eq $old.category -and $_.lane -eq $old.lane -and $_.model -eq $old.model }).Count) { $alerts.Add("drift-cleared:$($old.model):$($old.category):$($old.lane):$($nowUtc.ToString('yyyyMM'))") } }
    [IO.File]::WriteAllText($flagsPath,(ConvertTo-Json -InputObject @($flags.ToArray()) -Depth 10),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ new_records=$newCount; total_records=$values.Count; table_updates=$updated; drift_flags=$flags.Count; alerts=@($alerts.ToArray()) }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Update-RouterOutcomes -Now $RouterOutcomesCliNow -SourcesPath $RouterOutcomesCliSourcesPath
    if ($RouterOutcomesCliJson) { $result | ConvertTo-Json -Compress -Depth 10 } else { $result }
}
