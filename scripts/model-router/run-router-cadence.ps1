param([Alias('Now')][datetime]$RouterCadenceCliNow = (Get-Date), [Alias('CheckOnly')][switch]$RouterCadenceCliCheckOnly,
    [Alias('Refresh')][switch]$RouterCadenceCliRefresh, [Alias('Json')][switch]$RouterCadenceCliJson)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot 'publish-roster.ps1')
. (Join-Path $PSScriptRoot 'check-new-models.ps1')
. (Join-Path $PSScriptRoot 'run-router-research.ps1')
. (Join-Path $PSScriptRoot 'build-roster.ps1')
. (Join-Path $PSScriptRoot 'vendor-limits.ps1')

function Get-RouterCadenceCategories {
    param([Parameter(Mandatory)][string]$Model, [object]$Roster = (Read-RouterRoster).roster)
    $all = @($Roster.category_jobs.PSObject.Properties.Name)
    if ($Model -like 'claude-*' -or ($Model -like 'gpt-*' -and $Model -notmatch 'image')) { return @($all | Where-Object { $_ -ne 'image-generation' }) }
    if ($Model -like 'gpt-*' -and $Model -match 'image') { return @('image-generation') }
    return @()
}

function Get-RouterStoppedResearchFiles {
    param([string]$Model, [string[]]$Categories)
    foreach ($failure in @(Get-RouterResearchFailures)) {
        foreach ($line in @(Get-Content -LiteralPath $failure.file.FullName | Where-Object { $_ -like 'stopped_item: *' })) {
            $item = $line.Substring(14) | ConvertFrom-Json
            if ($item.model -ceq $Model -and @($item.categories | Where-Object { $_ -cin $Categories }).Count) { $failure.file; break }
        }
    }
}

function Add-RouterResearchQueueItem {
    param([Parameter(Mandatory)][string]$Model, [Parameter(Mandatory)][ValidateSet('release','confirmation','followup','refresh')][string]$Trigger,
        [Parameter(Mandatory)][string[]]$Categories, [Parameter(Mandatory)][datetime]$DueAt, [Parameter(Mandatory)][string]$Reason, [switch]$Automatic)
    $categoriesSorted = @($Categories | Sort-Object -Unique)
    if (-not $categoriesSorted.Count) { return $false }
    $state = Get-RouterStateDir
    $queuePath = Join-Path $state 'research-queue.json'
    $added = [pscustomobject]@{ value=$false }
    Use-RouterQueueMutex -StateDir $state -Action {
        $stops = @(Get-RouterStoppedResearchFiles -Model $Model -Categories $categoriesSorted)
        if ($Automatic -and $stops.Count) { return }
        foreach ($file in $stops) {
            $lines = @(Get-Content -LiteralPath $file.FullName | Where-Object { $_ -notlike 'stopped_item: *' })
            [IO.File]::WriteAllText($file.FullName, ($lines -join "`n"), [Text.UTF8Encoding]::new($false))
        }
        $queue = @(Read-RouterJsonArray -Path $queuePath)
        $key = $categoriesSorted -join '|'
        $exists = @($queue | Where-Object { $_.model -ceq $Model -and $_.trigger -ceq $Trigger -and ((@($_.categories | Sort-Object -Unique) -join '|') -ceq $key) }).Count -gt 0
        if (-not $exists) {
            $item = [pscustomobject]@{ id=[guid]::NewGuid().ToString('N'); model=$Model; trigger=$Trigger; categories=$categoriesSorted; due_at=$DueAt.ToString('o'); reason=$Reason }
            Write-RouterJsonAtomic -Path $queuePath -Value @($queue + $item)
            $added.value = $true
        }
    }
    return $added.value
}

function Get-RouterCadenceJobCategories {
    param([Parameter(Mandatory)][string]$Model, [Parameter(Mandatory)][object]$Roster)
    $jobs = @($Roster.jobs.PSObject.Properties | Where-Object { $_.Value.first -ceq $Model -or $_.Value.backup -ceq $Model } | ForEach-Object Name)
    return @($Roster.category_jobs.PSObject.Properties | Where-Object { $jobs -contains [string]$_.Value } | ForEach-Object Name | Sort-Object -Unique)
}

function Compare-RouterBenchmarkVersion {
    param([string]$Left, [string]$Right)
    $leftVersion = $null; $rightVersion = $null
    if ([version]::TryParse($Left,[ref]$leftVersion) -and [version]::TryParse($Right,[ref]$rightVersion)) { return $leftVersion.CompareTo($rightVersion) }
    $leftNumber = [decimal]0; $rightNumber = [decimal]0
    if ([decimal]::TryParse($Left,[ref]$leftNumber) -and [decimal]::TryParse($Right,[ref]$rightNumber)) { return $leftNumber.CompareTo($rightNumber) }
    return [string]::Compare($Left,$Right,[StringComparison]::OrdinalIgnoreCase)
}

function Add-RouterCadenceRefreshes {
    param([datetime]$Now = (Get-Date))
    $state = Get-RouterStateDir
    $roster = (Read-RouterRoster).roster
    $added = 0
    foreach ($mark in @(Read-RouterJsonArray -Path (Join-Path $state 'drift-marks.json'))) {
        if (-not $mark.PSObject.Properties['model'] -or -not $mark.PSObject.Properties['job']) { continue }
        $categories = @(Get-RouterCadenceJobCategories -Model ([string]$mark.model) -Roster $roster | Where-Object { (Get-RouterCategoryJob $_) -eq $mark.job })
        if (Add-RouterResearchQueueItem -Model $mark.model -Trigger refresh -Categories $categories -DueAt $Now -Reason "drift:$($mark.job)" -Automatic) { $added++ }
    }
    foreach ($model in @(Get-RouterStaleReadingModels -Months 6 -Now $Now)) {
        $categories = @(Get-RouterCadenceJobCategories -Model $model -Roster $roster)
        if (Add-RouterResearchQueueItem -Model $model -Trigger refresh -Categories $categories -DueAt $Now -Reason 'stale-reading' -Automatic) { $added++ }
    }
    $readDir = Join-Path $state 'readings'
    foreach ($category in @($roster.category_jobs.PSObject.Properties.Name)) {
        $stored = Read-RouterJsonObject -Path (Join-Path $readDir "$category.json")
        if (-not $stored -or -not $stored.PSObject.Properties['readings']) { continue }
        $models = @($roster.jobs.PSObject.Properties | Where-Object { $_.Name -eq $roster.category_jobs.$category } | ForEach-Object { @($_.Value.first,$_.Value.backup) } | Where-Object { $_ })
        foreach ($model in $models) {
            $outdated = $false
            foreach ($reading in @($stored.readings)) {
                $versions = @($stored.readings | Where-Object { $_.benchmark -ceq $reading.benchmark } | ForEach-Object version | Sort-Object -Unique)
                if (@($reading.results | Where-Object model -CEQ $model).Count -and @($versions | Where-Object { (Compare-RouterBenchmarkVersion ([string]$_) ([string]$reading.version)) -gt 0 }).Count) { $outdated = $true; break }
            }
            if ($outdated -and (Add-RouterResearchQueueItem -Model $model -Trigger refresh -Categories @($category) -DueAt $Now -Reason 'benchmark-version' -Automatic)) { $added++ }
        }
    }
    return $added
}

function Write-RouterCadenceConfirmationVerdicts {
    param([Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][string]$PassId)
    $state = Get-RouterStateDir
    $roster = (Read-RouterRoster).roster
    $readings = @{}
    foreach ($category in @($Item.categories)) {
        $data = Read-RouterJsonObject -Path (Join-Path $state "readings/$category.json")
        if ($data -and $data.PSObject.Properties['readings']) { $readings[$category] = $data }
    }
    $prices = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/api-prices.json') -Raw | ConvertFrom-Json -Depth 20
    $frontier = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json -Depth 20
    $verdictDir = Join-Path $state 'roster-proposals'
    New-Item -ItemType Directory -Path $verdictDir -Force | Out-Null
    $verdictPath = Join-Path $verdictDir 'verdicts.jsonl'
    foreach ($job in @($Item.categories | ForEach-Object { Get-RouterCategoryJob $_ } | Sort-Object -Unique)) {
        foreach ($slot in @('first','backup')) {
            if ($job -eq 'illustrator' -and $slot -eq 'backup') { continue }
            $entry = $roster.jobs.$job
            $vendor = if ($slot -eq 'backup') { if ($entry.first_vendor -eq 'codex') {'claude'} else {'codex'} } else { $null }
            $verdict = Get-RouterProposalJobVerdict -Job $job -Incumbent $entry.$slot -Vendor $vendor -Readings $readings -Prices $prices -Frontier $frontier
            $record = [pscustomobject]@{pass_id=$PassId;job=$job;slot=$slot;result=$verdict.result}
            [IO.File]::AppendAllText($verdictPath,(($record | ConvertTo-Json -Compress) + "`n"),[Text.UTF8Encoding]::new($false))
        }
    }
}

function Remove-RouterResolvedResearchFailures {
    param([datetime]$Now = (Get-Date))
    $state = Get-RouterStateDir
    $dir = Join-Path $state 'research-failures'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($failure in @(Get-RouterResearchFailures)) {
        $failedAt = $failure.at
        if ($failedAt -ge $Now.ToUniversalTime().AddDays(-30)) { continue }
        if ((Get-RouterResearchRecoveryTime -Category $failure.category) -gt $failedAt -and
            -not @(Get-Content -LiteralPath $failure.file.FullName | Where-Object { $_ -like 'stopped_item: *' }).Count) {
            Remove-Item -LiteralPath $failure.file.FullName -Force
        }
    }
}

function Invoke-RouterCadence {
    param([datetime]$Now = (Get-Date), [switch]$CheckOnly, [switch]$Refresh)
    Assert-RouterWindowsOwner -Action 'Router cadence'
    Publish-RouterRoster
    $state = Get-RouterStateDir
    $queuePath = Join-Path $state 'research-queue.json'
    $added = 0
    # Both daily runs (01:00 full, 13:00 check-only) check for new models, so releases are seen twice a day.
    # Research runs only for new frontier-vendor releases (and their confirmation and follow-up passes) or on
    # Danny's call. Refresh passes (drift, stale readings, benchmark versions) are queued only with -Refresh:
    # the automatic version re-queued the same refreshes every night (2026-10-02 to 10-05) and each pass
    # re-ran the same bench comparison.
    $check = Invoke-RouterModelCheck -Force -Now $Now; $added += @($check.new_models).Count
    if ($Refresh) { $added += Add-RouterCadenceRefreshes -Now $Now }
    $zone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
    $eastern = [TimeZoneInfo]::ConvertTime($Now,$zone)
    $ran = [Collections.Generic.List[object]]::new()
    $needsYou = [Collections.Generic.List[string]]::new()
    if (-not $CheckOnly -and $eastern.Hour -lt 6) {
        $roster = (Read-RouterRoster).roster
        foreach ($item in @(Read-RouterJsonArray -Path $queuePath | Where-Object { [datetime]$_.due_at -le $Now } | Sort-Object due_at)) {
            try {
                if (@(Get-RouterStoppedResearchFiles -Model $item.model -Categories @($item.categories)).Count) { continue }
                $jobNames = @($item.categories | ForEach-Object { Get-RouterCategoryJob $_ } | Sort-Object -Unique)
                $models = @($item.model) + @($roster.jobs.PSObject.Properties | Where-Object { $jobNames -contains $_.Name } | ForEach-Object { @($_.Value.first,$_.Value.backup) } | Where-Object { $_ -and $_ -cne $item.model } | Sort-Object -Unique)
                $usage = Get-RouterCodexUsage
                $lane = if ($usage -and [double]$usage.used_percent -gt 50) { 'claude' } else { 'codex' }
                $passPath = Join-Path $state 'readings/passes.jsonl'
                $beforeIds = @(if (Test-Path -LiteralPath $passPath) { Get-Content -LiteralPath $passPath | Where-Object { $_.Trim() } | ForEach-Object { ($_ | ConvertFrom-Json -Depth 20).pass_id } })
                $record = $null
                try {
                    $record = Invoke-RouterCategoryResearch -Categories @($item.categories) -Models $models -NewModel $(if ($item.trigger -eq 'release') { [string]$item.model } else { $null }) -Trigger $item.trigger -Lane $lane -Now $Now
                } catch {
                    Write-Warning "Research queue item $($item.id) ($($item.model)) stopped: $($_.Exception.Message)"
                    # M07 writes the interrupted record in finally before rethrowing.
                }
                $newRecords = @(if (Test-Path -LiteralPath $passPath) {
                    Get-Content -LiteralPath $passPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } | Where-Object {
                        $_.pass_id -cnotin $beforeIds -and $_.trigger -ceq $item.trigger -and
                        ((@($_.categories | Sort-Object) -join '|') -ceq (@($item.categories | Sort-Object) -join '|')) -and
                        ((@($_.models | Sort-Object) -join '|') -ceq (@($models | Sort-Object) -join '|'))
                    }
                })
                if ($record -and $record.PSObject.Properties['pass_id']) { $newRecords = @($newRecords | Where-Object pass_id -CEQ $record.pass_id) }
                if ($newRecords.Count -ne 1) { continue }
                $record = $newRecords[0]
                $interrupted = $record.PSObject.Properties['interrupted'] -and [bool]$record.interrupted
                $deferred = $record.PSObject.Properties['deferred'] -and [bool]$record.deferred
                $diagnosis = if ($record.PSObject.Properties['diagnosis']) { [string]$record.diagnosis } else { '' }
                if ($deferred -or ($interrupted -and $diagnosis -in @('quota','offline'))) { continue }
                if ($interrupted -and $diagnosis -eq 'unexplained') {
                    $quote = { param([string]$Text) "'" + $Text.Replace("'", "''") + "'" }
                    $command = '. ' + (& $quote (Join-Path $PSScriptRoot 'run-router-cadence.ps1')) + '; Add-RouterResearchQueueItem -Model ' + (& $quote $item.model) +
                        ' -Trigger ' + (& $quote $item.trigger) + ' -Categories @(' + ((@($item.categories | ForEach-Object { & $quote $_ })) -join ',') +
                        ') -DueAt (Get-Date) -Reason ' + (& $quote $item.reason)
                    $line = "Needs you: research for $($item.model) stopped unexplained. Re-enqueue: $command"
                    $needsYou.Add($line)
                    $files = @(Get-ChildItem -LiteralPath (Join-Path $state 'research-failures') -File -Filter "*-$($record.pass_id)*.txt" -ErrorAction SilentlyContinue)
                    if (-not $files.Count) {
                        $stamp = $eastern.ToString('yyyyMMddTHHmmssfff')
                        Write-RouterResearchFailure -StateDir $state -FileName "$($item.categories[0])@$stamp-$($record.pass_id).txt" -Detail 'unexplained stop'
                        $files = @(Get-ChildItem -LiteralPath (Join-Path $state 'research-failures') -File -Filter "*-$($record.pass_id)*.txt")
                    }
                    foreach ($file in $files) {
                        [IO.File]::AppendAllText($file.FullName, "`n$line`nstopped_item: " + ($item | ConvertTo-Json -Compress -Depth 10) + "`n", [Text.UTF8Encoding]::new($false))
                    }
                }
                if (-not $interrupted) {
                    if ($item.trigger -eq 'confirmation') { Write-RouterCadenceConfirmationVerdicts -Item $item -PassId $record.pass_id }
                    [void](Build-RouterRosterProposal -Now $Now)
                    if ($item.trigger -eq 'confirmation') {
                        $verdictPath = Join-Path $state 'roster-proposals/verdicts.jsonl'
                        $verdicts = @(if (Test-Path -LiteralPath $verdictPath) { Get-Content -LiteralPath $verdictPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } })
                        $current = @($verdicts | Where-Object { $_.pass_id -ceq $record.pass_id -and $_.result -ceq $item.model })
                        $firstWins = @($current | Where-Object { $win = $_; -not @($verdicts | Where-Object { $_.pass_id -cne $record.pass_id -and $_.result -ceq $item.model -and $_.job -ceq $win.job -and $_.slot -ceq $win.slot }).Count })
                        if ($firstWins.Count) {
                            if (Add-RouterResearchQueueItem -Model $item.model -Trigger followup -Categories @($item.categories) -DueAt $Now.AddDays(7) -Reason 'first-conclusive-confirmation' -Automatic) { $added++ }
                        }
                    }
                }
                Use-RouterQueueMutex -StateDir $state -Action {
                    $remaining = @(Read-RouterJsonArray -Path $queuePath | Where-Object { $_.id -cne $item.id })
                    Write-RouterJsonAtomic -Path $queuePath -Value $remaining
                }
                $ran.Add([pscustomobject]@{ id=$item.id; pass_id=$record.pass_id; lane=$lane; trigger=$item.trigger })
            } catch {
                Write-Warning "Research queue item $($item.id) ($($item.model)) failed: $($_.Exception.Message)"
            }
        }
    }
    Remove-RouterResolvedResearchFailures -Now $Now
    return [pscustomobject]@{ needs_you=@($needsYou.ToArray()); checked=$([bool]$CheckOnly); added=$added; ran=@($ran.ToArray()); pending=@(Read-RouterJsonArray -Path $queuePath).Count; eastern_time=$eastern.ToString('o') }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-RouterCadence -Now $RouterCadenceCliNow -CheckOnly:$RouterCadenceCliCheckOnly
    if ($RouterCadenceCliJson) { $result | ConvertTo-Json -Depth 12 -Compress } else { $result }
}
