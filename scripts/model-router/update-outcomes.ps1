param([Alias('Now')][datetime]$RouterOutcomesCliNow = (Get-Date), [Alias('SourcesPath')][string]$RouterOutcomesCliSourcesPath, [Alias('Json')][switch]$RouterOutcomesCliJson)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot 'send-router-alert.ps1')

function Get-RouterOutcomeValue {
    param([object]$Row, [string[]]$Names)
    if ($null -eq $Row) { return $null }
    foreach ($name in $Names) { if ($Row.PSObject.Properties[$name] -and $null -ne $Row.$name -and [string]$Row.$name) { return $Row.$name } }
    return $null
}

function ConvertTo-RouterOutcomeModel {
    param([string]$Model, [object]$Roster)
    if (-not $Model) { return '' }
    $Model = $Model -replace '\s*\(.*$',''
    $Model = $Model -replace '\s*\[\d+[kKmM]\]$',''
    if ($Model -notin @('opus','sonnet','haiku')) { return $Model }
    $ids = @($Roster.jobs.PSObject.Properties | ForEach-Object { @($_.Value.first,$_.Value.backup) } | Where-Object { $_ -match "^claude-$Model-" } | Sort-Object -Unique)
    if ($ids.Count) { return [string]$ids[0] }
    return $Model
}

function ConvertTo-RouterOutcomeUtcTimestamp {
    param([object]$Value)
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime.ToString('o') }
    if ($Value -is [datetime]) {
        $date = [datetime]$Value
        if ($date.Kind -eq [DateTimeKind]::Unspecified) { $date = [datetime]::SpecifyKind($date, [DateTimeKind]::Utc) }
        return $date.ToUniversalTime().ToString('o')
    }
    return ([datetimeoffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)).UtcDateTime.ToString('o')
}

function Get-RouterOutcomeCategory {
    param([object]$Record, [string]$Tier, [string]$Name, [string[]]$Categories = @('mechanical','routine-coding','complex-coding','ui-frontend','code-review','planning','deep-research','math','analysis','long-form-writing','image-generation'))
    $category = Get-RouterOutcomeValue $Record @('category')
    if ($category -in $Categories) { return [string]$category }
    if ($Name -match '(?i)(verif|review)') { return 'code-review' }
    if ($Tier -eq 'complex') { return 'complex-coding' }
    return 'routine-coding'
}

function Write-RouterOutcomeJson {
    param([string]$Path, [object]$Value)
    $temp = Join-Path (Split-Path -Parent $Path) ('.router-outcomes.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try { [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $Value -Depth 40),[Text.UTF8Encoding]::new($false)); [IO.File]::Move($temp,$Path,$true) }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Update-RouterOutcomes {
    param([datetime]$Now = (Get-Date), [string]$SourcesPath, [switch]$SendAlerts)
    $state = Get-RouterStateDir
    [IO.Directory]::CreateDirectory($state) | Out-Null
    if (-not $SourcesPath) { $SourcesPath = Join-Path $PSScriptRoot '../../references/model-router/outcome-sources.json' }
    $roots = @([IO.File]::ReadAllText($SourcesPath) | ConvertFrom-Json)
    $rosterRead = Read-RouterRoster
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
                    $model = ConvertTo-RouterOutcomeModel ([string](Get-RouterOutcomeValue $item @('resolved_model','model','requested_model'))) $rosterRead.roster
                    if (-not $model) { continue }
                    $chunk = Get-RouterOutcomeValue $item @('chunk_id','milestone_id')
                    if (-not $chunk) { $chunk = if ($folder -ne $run.FullName) { Split-Path -Leaf $folder } else { $file.BaseName -replace '(?i)(-output|-result|\.md\.provenance).*$', '' } }
                    $attempt = Get-RouterOutcomeValue $item @('attempt')
                    if (-not $attempt) { $attempt = if ($file.Name -match '(?i)(?:-|_)(?:a|attempt)(\d+)') { [int]$Matches[1] } elseif ($file.Name -match '(?i)(?:-|_)(retry|fix|resume)') { 2 } else { 1 } }
                    $key = "$($run.Name):$chunk`:$attempt"
                    if ($records.Contains($key)) { continue }
                    $at = Get-RouterOutcomeValue $item @('at','accepted_at_utc','recorded_at_utc','model_cache_fetched_at')
                    if (-not $at) { $at = $file.LastWriteTimeUtc.ToString('o') }
                    try { $at = ConvertTo-RouterOutcomeUtcTimestamp $at } catch { $at = $file.LastWriteTimeUtc.ToString('o') }
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
                    $model = ConvertTo-RouterOutcomeModel ([string](Get-RouterOutcomeValue $item @('resolved_model','model','requested_model'))) $rosterRead.roster
                    if (-not $model -and $builder) { $model = ConvertTo-RouterOutcomeModel ([string](Get-RouterOutcomeValue $builder @('resolved_model','model'))) $rosterRead.roster }
                    if (-not $model) { continue }
                    $at = Get-RouterOutcomeValue $item @('accepted_at_utc','recorded_at_utc','at')
                    if (-not $at) { $at = (Get-Item -LiteralPath $acceptance).LastWriteTimeUtc.ToString('o') }
                    try { $at = ConvertTo-RouterOutcomeUtcTimestamp $at } catch { continue }
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
    if ($rosterRead.source -ne 'state') { return [pscustomobject]@{ new_records=$newCount; total_records=$values.Count; alerts=@(); proposal=$null } }
    $roster = $rosterRead.roster
    $marksPath = Join-Path $state 'drift-marks.json'
    $priorMarks = @(Read-RouterJsonArray -Path $marksPath)
    $declinesPath = Join-Path $state 'drift-declines.json'
    $priorDeclines = @(Read-RouterJsonArray -Path $declinesPath)
    $declines = [System.Collections.Generic.List[object]]::new()
    $marks = [System.Collections.Generic.List[object]]::new()
    $alerts = [System.Collections.Generic.List[object]]::new()
    $newMarks = 0
    foreach ($job in @(Get-RouterJobs)) {
        $entry = $roster.jobs.$job
        $categories = @($roster.category_jobs.PSObject.Properties | Where-Object { $_.Value -eq $job } | ForEach-Object Name)
        $group = @($eligible | Where-Object { $_.model -eq $entry.first -and $_.category -in $categories -and $_.lane -eq $entry.first_vendor })
        $recent = @($group | Where-Object { ([datetime]$_.at) -ge $nowUtc.AddDays(-30) -and ([datetime]$_.at) -le $nowUtc })
        $prior = @($group | Where-Object { ([datetime]$_.at) -ge $nowUtc.AddDays(-120) -and ([datetime]$_.at) -lt $nowUtc.AddDays(-30) })
        $drifting = $false
        $recentRate = if ($recent.Count -ge 10) { @($recent | Where-Object pass).Count / $recent.Count } else { $null }
        if ($recent.Count -ge 10 -and $prior.Count -ge 10) {
            $priorRate = @($prior | Where-Object pass).Count / $prior.Count
            $drifting = (($priorRate - $recentRate) -ge (0.15 - 1e-9))
        }
        $declined = @($priorDeclines | Where-Object { $_.job -eq $job -and $_.model -eq $entry.first })
        if ($declined.Count -and $drifting) { $declines.Add($declined[0]); continue }
        $old = @($priorMarks | Where-Object { $_.job -eq $job -and $_.model -eq $entry.first })
        if (-not $drifting) {
            if ($old.Count -and ($recent.Count -lt 10 -or (($old[0].prior_rate - $recentRate) -ge (0.15 - 1e-9)))) { $marks.Add($old[0]) }
            continue
        }
        $marks.Add([pscustomobject]@{ model=$entry.first; job=$job; marked_at=$(if ($old.Count) { $old[0].marked_at } else { $nowUtc.ToString('o') }); recent_rate=$recentRate; prior_rate=$priorRate })
        if (-not $old.Count) {
            $newMarks++
            $key = "drift:$($entry.first):${job}:$($nowUtc.ToString('yyyyMM'))"
            if ($entry.backup) {
                $alerts.Add([pscustomobject]@{key=$key;message="Model $($entry.first) is drifting for $job. The job now uses its backup $($entry.backup). Proposed change: swap first and backup."})
            } else { $alerts.Add([pscustomobject]@{key=$key;message="Model $($entry.first) is drifting for $job. No backup is approved; the first choice remains in use."}) }
        }
    }
    foreach ($old in $priorMarks) {
        if (-not @($marks | Where-Object { $_.job -eq $old.job -and $_.model -eq $old.model }).Count) {
            $alerts.Add([pscustomobject]@{key="drift-cleared:$($old.model):$($old.job):$($nowUtc.ToString('yyyyMM'))";message="Drift cleared for $($old.job) on $($old.model); the first choice is restored."})
        }
    }
    Write-RouterOutcomeJson $marksPath @($marks.ToArray())
    if ($priorDeclines.Count -or $declines.Count) { Write-RouterOutcomeJson $declinesPath @($declines.ToArray()) }
    $proposalPath = $null
    if ($newMarks -gt 0 -and @($marks | Where-Object { $roster.jobs.($_.job).backup }).Count) {
        $proposal = $roster | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        foreach ($name in @(Get-RouterJobs)) {
            foreach ($slot in @('first','backup')) {
                $proposal.jobs.$name | Add-Member -NotePropertyName "${slot}_effort" -NotePropertyValue (Get-RouterJobEffort -Job $name) -Force
            }
        }
        $proposal.generated_at = $nowUtc.ToString('o'); $proposal.approved = $false; $proposal.approved_at = $null
        foreach ($mark in $marks) {
            $target = $proposal.jobs.($mark.job)
            if (-not $target.backup) { continue }
            $first = $target.first; $vendor = $target.first_vendor
            $target.first = $target.backup; $target.first_vendor = $target.backup_vendor
            $target.backup = $first; $target.backup_vendor = $vendor
        }
        $dir = Join-Path $state 'roster-proposals'; [IO.Directory]::CreateDirectory($dir) | Out-Null
        $stem = $nowUtc.ToString('yyyy-MM-ddTHHmmss') + '-drift'
        $proposalPath = Join-Path $dir ($stem + '.json'); $reportPath = Join-Path $dir ($stem + '.md')
        [IO.File]::WriteAllText($proposalPath,(ConvertTo-Json -InputObject $proposal -Depth 30),[Text.UTF8Encoding]::new($false))
        $lines = @('# Model list proposal','','| Job | Current | Proposed | Evidence summary | Backup |','| --- | --- | --- | --- | --- |')
        foreach ($job in @(Get-RouterJobs)) {
            $mark = @($marks | Where-Object job -eq $job)
            $evidence = if ($mark.Count) { "Pass rate $($mark[0].prior_rate) to $($mark[0].recent_rate); drift threshold met" } else { 'No change' }
            $lines += "| $job | $($roster.jobs.$job.first) | $($proposal.jobs.$job.first) (effort $($proposal.jobs.$job.first_effort)) | $evidence | $($proposal.jobs.$job.backup) (effort $($proposal.jobs.$job.backup_effort)) |"
        }
        [IO.File]::WriteAllText($reportPath,(($lines -join "`n") + "`n"),[Text.UTF8Encoding]::new($false))
        Write-RouterOutcomeJson (Join-Path $dir 'latest.json') ([pscustomobject]@{proposal=$proposalPath;report=$reportPath})
    } elseif (@($marks | Where-Object { $roster.jobs.($_.job).backup }).Count -eq 0) {
        # Drift has cleared: a pending drift swap must not stay approvable.
        $latestPath = Join-Path (Join-Path $state 'roster-proposals') 'latest.json'
        $latest = Read-RouterJsonObject -Path $latestPath
        if ($latest -and $latest.PSObject.Properties['proposal'] -and [string]$latest.proposal -like '*-drift.json') { Remove-Item -LiteralPath $latestPath -Force }
    }
    if ($SendAlerts -and $alerts.Count) { Send-RouterAlerts -Alerts @($alerts.ToArray()) -ChatToStderr:$RouterOutcomesCliJson | Out-Null }
    return [pscustomobject]@{ new_records=$newCount; total_records=$values.Count; alerts=@($alerts.ToArray()); proposal=$proposalPath }

}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Update-RouterOutcomes -Now $RouterOutcomesCliNow -SourcesPath $RouterOutcomesCliSourcesPath -SendAlerts
    if ($RouterOutcomesCliJson) { $result | ConvertTo-Json -Compress -Depth 10 } else { $result }
}
