param([Alias('Now')][datetime]$RouterOutcomesCliNow = (Get-Date), [Alias('SourcesPath')][string]$RouterOutcomesCliSourcesPath, [Alias('Json')][switch]$RouterOutcomesCliJson)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot 'send-router-alert.ps1')
. (Join-Path $PSScriptRoot 'dispatch-evidence.ps1')

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

function ConvertTo-RouterOutcomeAttempt {
    # Hand-written rows sometimes label a remediation attempt with text; any non-numeric label counts as a later attempt.
    param([object]$Attempt)
    $number = 0
    if ([int]::TryParse([string]$Attempt, [ref]$number) -and $number -gt 0) { return $number }
    return 2
}

function Update-RouterOutcomesLocked {
    param([datetime]$Now = (Get-Date), [string]$SourcesPath, [switch]$SendAlerts, [scriptblock]$BenchInvoker)
    $state = Get-RouterStateDir
    [IO.Directory]::CreateDirectory($state) | Out-Null
    if (-not $SourcesPath) { $SourcesPath = Join-Path $PSScriptRoot '../../references/model-router/outcome-sources.json' }
    $roots = @([IO.File]::ReadAllText($SourcesPath) | ConvertFrom-Json)
    $rosterRead = Read-RouterRoster
    $outcomePath = Join-Path $state 'outcomes.jsonl'
    $ledger = Read-RouterOutcomeLedger $outcomePath
    $records = $ledger.records
    $before = @{}
    foreach ($key in $records.Keys) { $before[$key] = $records[$key] | ConvertTo-Json -Depth 40 -Compress }
    # Archives are the retained identity index: do not resurrect aged provenance.
    $archivedKeys = @{}
    $archivedDispatchRows = [Collections.Generic.List[object]]::new()
    $archiveDir = Join-Path $state '_archive'
    if (Test-Path -LiteralPath $archiveDir) {
        foreach ($file in @(Get-ChildItem -LiteralPath $archiveDir -Filter 'outcomes-*.jsonl' -File)) {
            $archived = Read-RouterOutcomeLedger $file.FullName
            foreach ($key in $archived.records.Keys) { $archivedKeys[$key] = $true }
            foreach ($row in $archived.records.Values) { if (Get-DispatchValue $row 'dispatch_id') { $archivedDispatchRows.Add($row) } }
        }
    }
    # dt-build keeps run provenance in the worktree it built in, so scan each root's linked worktrees too;
    # their rows carry the root's repo name.
    $scanRoots = [System.Collections.Generic.List[object]]::new()
    foreach ($root in $roots) {
        $rootPath = [string]$root
        $scanRoots.Add([pscustomobject]@{ path = $rootPath; repo = (Split-Path -Leaf $rootPath) })
        if (-not (Test-Path -LiteralPath (Join-Path $rootPath '.git'))) { continue }
        $listing = @(& git -C $rootPath worktree list --porcelain 2>$null)
        if ($LASTEXITCODE -ne 0) { continue }
        foreach ($line in $listing) {
            if ($line -notmatch '^worktree (.+)$') { continue }
            $worktreePath = [IO.Path]::GetFullPath($Matches[1])
            if ($worktreePath.TrimEnd('\', '/') -ieq [IO.Path]::GetFullPath($rootPath).TrimEnd('\', '/')) { continue }
            $scanRoots.Add([pscustomobject]@{ path = $worktreePath; repo = (Split-Path -Leaf $rootPath) })
        }
    }
    # Collect all dispatch identities before considering legacy acceptance rows,
    # including indexed output paths outside every configured source root.
    $provenancePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($existing in $records.Values) {
        $indexed = Get-DispatchValue $existing 'provenance_path'
        if ((Get-DispatchValue $existing 'dispatch_id') -and $indexed -and (Test-Path -LiteralPath $indexed)) { [void]$provenancePaths.Add($indexed) }
    }
    $pending = @(Get-RouterPendingOutcomes -StateDir $state)
    $drained = @(Import-RouterPendingOutcomes -StateDir $state -Pending $pending -Rows $records -ArchivedKeys $archivedKeys)
    foreach ($filePath in $provenancePaths) {
                try { $item = Read-RouterDispatchEvidence -Path $filePath } catch { continue }
                $id = Get-DispatchValue $item 'dispatch_id'
                if (-not $id -or -not (Get-DispatchValue $item 'logical_task_id')) { continue }
                $key = 'dispatch:' + $id
                if (-not $records.Contains($key) -and $archivedKeys.ContainsKey($key)) { continue }
                $row = ConvertTo-DispatchOutcome $item $filePath
                # Imported snapshots must not regress terminal or verifier evidence.
                if ($records.Contains($key)) {
                    $prior = $records[$key]
                    if ((Get-DispatchValue $prior 'finished_utc') -and -not $row.finished_utc) { continue }
                    $row.provenance_path = $prior.provenance_path
                    if ($prior.PSObject.Properties['retry_count']) { $row | Add-Member -NotePropertyName retry_count -NotePropertyValue $prior.retry_count }
                    if ($null -ne (Get-DispatchValue $prior 'independent_acceptance') -and $null -eq $row.independent_acceptance) { $row.independent_acceptance = $prior.independent_acceptance; $row.pass = $prior.independent_acceptance }
                }
                if ($records.Contains($key) -and (($records[$key] | ConvertTo-Json -Depth 40 -Compress) -ceq ([pscustomobject]$row | ConvertTo-Json -Depth 40 -Compress))) { continue }
                $records[$key] = [pscustomobject]$row
    }
    foreach ($scanRoot in $scanRoots) {
        $build = Join-Path ([string]$scanRoot.path) '.dt-build'
        if (-not (Test-Path -LiteralPath $build -PathType Container)) { continue }
        $repo = [string]$scanRoot.repo
        foreach ($run in @(Get-ChildItem -LiteralPath $build -Directory)) {
            $folders = [System.Collections.Generic.List[string]]::new()
            $folders.Add($run.FullName)
            $milestones = Join-Path $run.FullName 'milestones'
            if (Test-Path -LiteralPath $milestones -PathType Container) {
                foreach ($milestone in @(Get-ChildItem -LiteralPath $milestones -Directory)) { $folders.Add($milestone.FullName) }
            }
            foreach ($folder in $folders) {
                foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Filter '*.provenance.json')) {
                    try { $item = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -Depth 20 -DateKind String } catch { continue }
                    if ((Get-DispatchValue $item 'dispatch_id') -and (Get-DispatchValue $item 'logical_task_id')) { continue }
                    $model = ConvertTo-RouterOutcomeModel ([string](Get-RouterOutcomeValue $item @('resolved_model','model','requested_model'))) $rosterRead.roster
                    if (-not $model) { continue }
                    $chunk = Get-RouterOutcomeValue $item @('chunk_id','milestone_id')
                    if (-not $chunk) { $chunk = if ($folder -ne $run.FullName) { Split-Path -Leaf $folder } else { $file.BaseName -replace '(?i)(-output|-result|\.md\.provenance).*$', '' } }
                    $attempt = Get-RouterOutcomeValue $item @('attempt')
                    if (-not $attempt) { $attempt = if ($file.Name -match '(?i)(?:-|_)(?:a|attempt)(\d+)') { [int]$Matches[1] } elseif ($file.Name -match '(?i)(?:-|_)(retry|fix|resume)') { 2 } else { 1 } }
                    $key = "$($run.Name):$chunk`:$attempt"
                    if ($records.Contains($key) -or $archivedKeys.ContainsKey($key)) { continue }
                    $at = Get-RouterOutcomeValue $item @('at','accepted_at_utc','recorded_at_utc','model_cache_fetched_at')
                    if (-not $at) { $at = $file.LastWriteTimeUtc.ToString('o') }
                    try { $at = ConvertTo-RouterOutcomeUtcTimestamp $at } catch { $at = $file.LastWriteTimeUtc.ToString('o') }
                    $tier = [string](Get-RouterOutcomeValue $item @('tier'))
                    $lane = [string](Get-RouterOutcomeValue $item @('lane'))
                    if ($lane -notin @('codex','claude')) { $lane = if ($model -match '^claude-') { 'claude' } else { 'codex' } }
                    $pass = Get-RouterOutcomeValue $item @('pass')
                    $failureCategory = Get-RouterOutcomeValue $item @('failure_category')
                    $diagnosis = Get-RouterOutcomeValue $item @('diagnosis')
                    if ($failureCategory -ne 'environment' -or $diagnosis -cnotin @('offline','vendor_incident','unexplained')) { $diagnosis = $null }
                    $records[$key] = [pscustomobject]@{ key=$key; run_id=$run.Name; repo=$repo; at=$at; lane=$lane; model=$model; category=(Get-RouterOutcomeCategory $item $tier $file.Name); attempt=(ConvertTo-RouterOutcomeAttempt $attempt); pass=($pass -eq $true -or [string]$pass -eq 'true'); escalated=($file.Name -match '(?i)(?:-|_)(retry|fix|resume)'); failure_category=$failureCategory; diagnosis=$diagnosis; source='dt-build'; tier=$tier }
                    $records[$key] | Add-Member -NotePropertyName provenance_path -NotePropertyValue $file.FullName
                    $records[$key] | Add-Member -NotePropertyName failure_detail -NotePropertyValue $(if ($failureCategory -in @('environment','capacity')) { Get-RouterOutcomeValue $item @('failure_detail') } else { $null })
                    $records[$key] | Add-Member -NotePropertyName workstation -NotePropertyValue $(if ([string]$scanRoot.path -match '[/\\]_Claude-Workspace[/\\]([^/\\]+)') { $Matches[1] } else { Split-Path -Leaf (Split-Path -Parent $scanRoot.path) })

                }
                $acceptance = Join-Path $folder 'acceptance-rows.jsonl'
                if (-not (Test-Path -LiteralPath $acceptance)) { continue }
                foreach ($line in [IO.File]::ReadAllLines($acceptance)) {
                    try { $item = $line | ConvertFrom-Json -Depth 20 -DateKind String } catch { continue }
                    $acceptanceId = Get-DispatchValue $item 'dispatch_id'
                    $acceptancePath = Get-DispatchValue $item 'provenance_path'
                    if (-not $acceptanceId -and $acceptancePath -and (Test-Path -LiteralPath $acceptancePath)) {
                        $acceptanceEvidence = Get-Content -LiteralPath $acceptancePath -Raw | ConvertFrom-Json -Depth 40 -DateKind String
                        $acceptanceId = Get-DispatchValue $acceptanceEvidence 'dispatch_id'
                    }
                    if ($acceptanceId) {
                        $dispatchKey = 'dispatch:' + $acceptanceId
                        if ($records.Contains($dispatchKey)) {
                            $accepted = (Get-DispatchValue $item 'status') -eq 'PASS' -and
                                (Get-DispatchValue $item 'accepted') -ne $false -and
                                (Get-DispatchValue $item 'downgrade_status') -notin @('downgraded','blocked','fail') -and
                                (Get-DispatchValue $records[$dispatchKey] 'independent_acceptance') -ne $false
                            $records[$dispatchKey].independent_acceptance = $accepted
                            $records[$dispatchKey].pass = $accepted
                        }
                        continue
                    }
                    # With correlated provenance present, an unkeyed legacy acceptance is
                    # ambiguous (builder/reviewer). Keep it unknown; never invent a second attempt.
                    $legacyAttempt = Get-DispatchValue $item 'attempt'
                    if (-not $legacyAttempt) { $legacyAttempt = 1 }
                    $correlated = @(@($records.Values) + @($archivedDispatchRows.ToArray()) | Where-Object {
                        (Get-DispatchValue $_ 'dispatch_id') -and
                        ((Get-DispatchValue $_ 'logical_task_id') -like ($run.Name + ':*') -or (Get-DispatchValue $_ 'provenance_path') -like ($run.FullName + [IO.Path]::DirectorySeparatorChar + '*')) -and
                        ((Get-DispatchValue $_ 'attempt') -eq $legacyAttempt -or -not (Get-DispatchValue $item 'attempt'))
                    })
                    if ($correlated.Count) { continue }
                    $chunk = Get-RouterOutcomeValue $item @('chunk_id','milestone_id')
                    if (-not $chunk) { continue }
                    $attempt = Get-RouterOutcomeValue $item @('attempt')
                    if (-not $attempt) { $attempt = 1 }
                    $key = "$($run.Name):$chunk`:$attempt"
                    if ($records.Contains($key) -or $archivedKeys.ContainsKey($key)) { continue }
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
                    $failureCategory = Get-RouterOutcomeValue $item @('failure_category')
                    $diagnosis = Get-RouterOutcomeValue $item @('diagnosis')
                    if ($failureCategory -ne 'environment' -or $diagnosis -cnotin @('offline','vendor_incident','unexplained')) { $diagnosis = $null }
                    $records[$key] = [pscustomobject]@{ key=$key; run_id=$run.Name; repo=$repo; at=$at; lane=$lane; model=$model; category=(Get-RouterOutcomeCategory $item $tier ([string]$chunk)); attempt=(ConvertTo-RouterOutcomeAttempt $attempt); pass=([string](Get-RouterOutcomeValue $item @('status')) -eq 'PASS'); escalated=$false; failure_category=$failureCategory; diagnosis=$diagnosis; source='dt-build'; tier=$tier }
                    $records[$key] | Add-Member -NotePropertyName failure_detail -NotePropertyValue $(if ($failureCategory -in @('environment','capacity')) { Get-RouterOutcomeValue $item @('failure_detail') } else { $null })
                }
            }
        }
    }
    $values = @($records.Values) + @($ledger.raw | Where-Object { -not $_.key -and $_.row } | ForEach-Object row)
    $dispatchRows = @($values | Where-Object { Get-DispatchValue $_ 'logical_task_id' })
    foreach ($row in $dispatchRows) {
        $later = @($dispatchRows | Where-Object { $_.logical_task_id -eq $row.logical_task_id -and $_.attempt -gt $row.attempt })
        $row | Add-Member -Force -NotePropertyName retry_count -NotePropertyValue $later.Count
    }
    foreach ($row in $values) {
        if (-not (Get-DispatchValue $row 'key') -or (Get-DispatchValue $row 'dispatch_id') -or (Get-DispatchValue $row 'attempt') -ne 1) { continue }
        $later = @($values | Where-Object { (Get-DispatchValue $_ 'run_id') -eq (Get-DispatchValue $row 'run_id') -and (Get-DispatchValue $_ 'repo') -eq (Get-DispatchValue $row 'repo') -and (Get-DispatchValue $_ 'key') -match '^(.+):[^:]+:[^:]+$' -and ($_.key -replace ':[^:]+$','') -eq ($row.key -replace ':[^:]+$','') -and $_.attempt -gt 1 -and ((Get-DispatchValue $_ 'model') -ne (Get-DispatchValue $row 'model') -or (Get-DispatchValue $_ 'tier') -ne (Get-DispatchValue $row 'tier')) })
        if ($later.Count) { $row.escalated = $true }
    }
    # Retain the full 120-day comparison window; keep older evidence in dated
    # archives, rather than dropping it at an arbitrary ledger byte threshold.
    $aged = @($records.Values | Where-Object { (Get-DispatchValue $_ 'at') -and ([datetimeoffset]$_.at) -lt ([datetimeoffset]$Now).AddDays(-120) })
    if ($aged.Count) {
        [IO.Directory]::CreateDirectory($archiveDir) | Out-Null
        $archivePath = Join-Path $archiveDir ('outcomes-' + $Now.ToString('yyyy-MM-dd') + '.jsonl')
        $archive = Read-RouterOutcomeLedger $archivePath
        foreach ($row in $aged) {
            if (-not $archivedKeys.ContainsKey($row.key)) { $archive.records[$row.key] = $row }
            $records.Remove($row.key)
        }
        if ($archive.records.Count) { Write-RouterOutcomeLedger $archivePath $archive $archive.records }
        $values = @($values | Where-Object { (Get-DispatchValue $_ 'key') -notin @($aged.key) })
    }
    # Count final changes, not intermediate merge operations. Repeated imports are no-ops.
    $newCount = 0
    foreach ($key in $records.Keys) {
        if (-not $before.ContainsKey($key) -or $before[$key] -cne ($records[$key] | ConvertTo-Json -Depth 40 -Compress)) { $newCount++ }
    }
    Write-RouterOutcomeLedger $outcomePath $ledger $records
    foreach ($pointer in $drained) { Remove-Item -LiteralPath $pointer.FullName -Force -ErrorAction SilentlyContinue }
    $unresolvedFolder = Join-Path $state 'outcome-pending/unresolved'
    $unresolved = if (Test-Path -LiteralPath $unresolvedFolder -PathType Container) { @(Get-ChildItem -LiteralPath $unresolvedFolder -Filter '*.txt' -File).Count } else { 0 }
    $nowUtc = $Now.ToUniversalTime()
    $verifiedTasks = @{}
    foreach ($row in $dispatchRows) {
        if ($null -ne (Get-DispatchValue $row 'independent_acceptance')) { $verifiedTasks[$row.logical_task_id] = $true }
    }
    # First-attempt acceptance is per logical task with an independent verifier result,
    # including a later accepted retry; unverified work and bench evidence stay separate.
    $eligible = @($values | Where-Object { (Get-RouterOutcomeValue $_ 'source') -notin @('canary','bench','dispatch-event') -and (Get-DispatchValue $_ 'attempt') -eq 1 -and (Get-DispatchValue $_ 'failure_category') -notin @('environment','tooling','capacity') -and (-not (Get-DispatchValue $_ 'dispatch_id') -or $verifiedTasks.ContainsKey($_.logical_task_id)) })
    $firstAttempt = [pscustomobject]@{accepted=@($eligible | Where-Object { (Get-DispatchValue $_ 'pass') -eq $true }).Count; total=$eligible.Count; retries=(@($eligible | ForEach-Object { [int](Get-DispatchValue $_ 'retry_count') }) | Measure-Object -Sum).Sum}
    if ($rosterRead.source -ne 'state') { return [pscustomobject]@{ unresolved_count=$unresolved; new_records=$newCount; total_records=$values.Count; first_attempt=$firstAttempt; alerts=@(); proposal=$null } }
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
    if (-not $marks.Count) {
        $latestPath = Join-Path $state 'roster-proposals/latest.json'
        $latest = Read-RouterJsonObject $latestPath
        if ($latest -and $latest.PSObject.Properties['proposal'] -and [string]$latest.proposal -like '*-drift.json') { Remove-Item -LiteralPath $latestPath -Force }
    }
    $requests = @($marks | Where-Object { $newMarks -gt 0 -and $roster.jobs.($_.job).backup } | ForEach-Object {
        $entry = $roster.jobs.($_.job)
        [pscustomobject]@{job=$_.job;candidate=$entry.backup;incumbent=$entry.first;effort=$entry.first_effort}
    })
    return [pscustomobject]@{ unresolved_count=$unresolved; new_records=$newCount; total_records=$values.Count; first_attempt=$firstAttempt; alerts=@($alerts.ToArray()); proposal=$null; requests=$requests; identity=(ConvertTo-Json $roster.jobs -Compress -Depth 30) }

}


function Complete-RouterDriftBench {
    param($Staged, $BenchResults, [datetime]$Now)
    $state = Get-RouterStateDir
    $roster = (Read-RouterRoster).roster
    if ((ConvertTo-Json $roster.jobs -Compress -Depth 30) -cne $Staged.identity) { throw 'BENCH_STALE_ROSTER: drift model or effort changed' }
    $nowUtc = $Now.ToUniversalTime()
    $declines = @(Read-RouterJsonArray (Join-Path $state 'drift-declines.json'))
    $marks = @(Read-RouterJsonArray (Join-Path $state 'drift-marks.json') | Where-Object {
        $mark = $_
        -not @($declines | Where-Object { $_.job -eq $mark.job -and $_.model -eq $mark.model }).Count -and
        $BenchResults.ContainsKey($_.job) -and $BenchResults[$_.job].raw_gate -ne 'unknown' -and $BenchResults[$_.job].gate -notin @('fail','unknown') -and -not ($_.job -in @('fast','coder','deep-thinker') -and $BenchResults[$_.job].raw_gate -eq 'fail') -and -not $BenchResults[$_.job].tied -and $BenchResults[$_.job].better -eq $roster.jobs.($_.job).backup
    })
    # Drift swaps use the same per-tier quality veto as research swaps.
    $marks = @($marks | Where-Object {
        $bench = $BenchResults[$_.job]
        $measured = @(if ($bench.PSObject.Properties['tiers']) { $bench.tiers | ForEach-Object { [pscustomobject]$_ } } else { $bench })
        -not ($bench.PSObject.Properties['halted'] -and $bench.halted) -and
        -not @($measured | Where-Object { $_.PSObject.Properties['quality_verdict'] -and $_.quality_verdict -and $_.quality_verdict.verdict -ceq 'incumbent_better' }).Count
    })
    $marks = @($marks | Where-Object { -not (Get-RouterBenchProposalEvidenceError -Job $_.job -Evidence (New-RouterBenchProposalEvidence -Job $_.job -Bench $BenchResults[$_.job])) })
    $proposalPath = $null
    if ($marks.Count -gt 0 -and @($marks | Where-Object { $roster.jobs.($_.job).backup }).Count) {
        $proposal = $roster | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        foreach ($name in @(Get-RouterJobs)) {
            foreach ($slot in @('first','backup')) {
                $proposal.jobs.$name | Add-Member -NotePropertyName "${slot}_effort" -NotePropertyValue $roster.jobs.$name."${slot}_effort" -Force
            }
        }
        $proposal.generated_at = $nowUtc.ToString('o'); $proposal.approved = $false; $proposal.approved_at = $null
        $changes = @()
        foreach ($mark in $marks) {
            $target = $proposal.jobs.($mark.job)
            if (-not $target.backup) { continue }
            $first = $target.first; $vendor = $target.first_vendor; $effort = $target.first_effort
            $target.first = $target.backup; $target.first_vendor = $target.backup_vendor
            $target.first_effort = $effort
            $target.backup = $first; $target.backup_vendor = $vendor; $target.backup_effort = $effort
            foreach ($slot in @('first','backup')) { if ($target.PSObject.Properties["${slot}_efforts"]) { $target.("${slot}_efforts").standard = $target.("${slot}_effort") } }
            $changes += [pscustomobject]@{job=$mark.job;slot='first';from=$first;to=$target.first;evidence='Drift; Bench comparison';bench_evidence=(New-RouterBenchProposalEvidence -Job $mark.job -Bench $BenchResults[$mark.job])}
            $bench = $BenchResults[$mark.job]
            $measured = @(if ($bench.PSObject.Properties['tiers']) { $bench.tiers | ForEach-Object { [pscustomobject]$_ } } else { $bench })
            $quality = @($measured | Where-Object { $_.PSObject.Properties['quality_evidence'] -and $_.quality_evidence } | ForEach-Object quality_evidence)
            if ($quality.Count) { $changes[-1] | Add-Member -NotePropertyName quality_evidence -NotePropertyValue $quality }
        }
        $proposal | Add-Member -NotePropertyName changes -NotePropertyValue $changes -Force
        $dir = Join-Path $state 'roster-proposals'; [IO.Directory]::CreateDirectory($dir) | Out-Null
        $stem = $nowUtc.ToString('yyyy-MM-ddTHHmmss') + '-drift'
        $proposalPath = Join-Path $dir ($stem + '.json'); $reportPath = Join-Path $dir ($stem + '.md')
        [IO.File]::WriteAllText($proposalPath,(ConvertTo-Json -InputObject $proposal -Depth 30),[Text.UTF8Encoding]::new($false))
        $lines = @('# Model list proposal','','| Job | Current | Proposed | Evidence summary | Backup |','| --- | --- | --- | --- | --- |')
        foreach ($job in @(Get-RouterJobs)) {
            $mark = @($marks | Where-Object job -eq $job)
            $evidence = if ($mark.Count) { "Pass rate $($mark[0].prior_rate) to $($mark[0].recent_rate); drift threshold met; Bench $($BenchResults[$job].gate); shortfall $($BenchResults[$job].shortfall_tasks); report $($BenchResults[$job].report_paths.markdown)" } else { 'No change' }
            $lines += "| $job | $($roster.jobs.$job.first) | $($proposal.jobs.$job.first) (effort $($proposal.jobs.$job.first_effort)) | $evidence | $($proposal.jobs.$job.backup) (effort $($proposal.jobs.$job.backup_effort)) |"
        }
        $lines += @('','## Benchmark basis','')
        $lines += @($changes | ForEach-Object { "- $($_.job)/$($_.slot): $(ConvertTo-Json $_.bench_evidence -Compress -Depth 10)" })
        [IO.File]::WriteAllText($reportPath,(($lines -join "`n") + "`n"),[Text.UTF8Encoding]::new($false))
        Write-RouterOutcomeJson (Join-Path $dir 'latest.json') ([pscustomobject]@{proposal=$proposalPath;report=$reportPath})
    } elseif (@($marks | Where-Object { $roster.jobs.($_.job).backup }).Count -eq 0) {
        # Drift has cleared: a pending drift swap must not stay approvable.
        $latestPath = Join-Path (Join-Path $state 'roster-proposals') 'latest.json'
        $latest = Read-RouterJsonObject -Path $latestPath
        if ($latest -and $latest.PSObject.Properties['proposal'] -and [string]$latest.proposal -like '*-drift.json') { Remove-Item -LiteralPath $latestPath -Force }
    }
    return $proposalPath
}

function Update-RouterOutcomes {
    param([datetime]$Now = (Get-Date), [string]$SourcesPath, [switch]$SendAlerts, [scriptblock]$BenchInvoker)
    Assert-RouterWindowsOwner -Action 'Outcome import and drift proposal construction'
    . (Join-Path $PSScriptRoot 'build-roster.ps1')
    # Reread outcomes, roster, marks and declines only after obtaining the shared writer lock.
    $state = Get-RouterStateDir
    $result = Use-RouterOutcomeMutex -StateDir $state -Action { Update-RouterOutcomesLocked -Now $Now -SourcesPath $SourcesPath }
    if ($result.PSObject.Properties['requests'] -and $result.requests.Count) {
        $benchResults = @{}
        foreach ($request in $result.requests) { $benchResults[$request.job] = Invoke-RouterTriggeredComparison -Request $request -Trigger drift -BenchInvoker $BenchInvoker -SendAlerts:$SendAlerts }
        $result.proposal = Use-RouterOutcomeMutex -StateDir $state -Action {
            foreach ($request in $result.requests) { Save-RouterEffortProposal $request $benchResults[$request.job] }
            Complete-RouterDriftBench -Staged $result -BenchResults $benchResults -Now $Now
        }
    }
    if ($SendAlerts) { Send-RouterEffortAlerts }
    if ($SendAlerts -and $result.alerts.Count) { Send-RouterAlerts -Alerts @($result.alerts) -ChatToStderr:$RouterOutcomesCliJson | Out-Null }
    return $result
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Update-RouterOutcomes -Now $RouterOutcomesCliNow -SourcesPath $RouterOutcomesCliSourcesPath -SendAlerts
    if ($RouterOutcomesCliJson) { $result | ConvertTo-Json -Compress -Depth 10 } else { $result }
}
