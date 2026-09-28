param([Alias('Now')][datetime]$RouterCadenceCliNow = (Get-Date), [Alias('CheckOnly')][switch]$RouterCadenceCliCheckOnly, [Alias('Json')][switch]$RouterCadenceCliJson)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
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

function Add-RouterResearchQueueItem {
    param([Parameter(Mandatory)][string]$Model, [Parameter(Mandatory)][ValidateSet('release','confirmation','followup','refresh')][string]$Trigger,
        [Parameter(Mandatory)][string[]]$Categories, [Parameter(Mandatory)][datetime]$DueAt, [Parameter(Mandatory)][string]$Reason)
    $categoriesSorted = @($Categories | Sort-Object -Unique)
    if (-not $categoriesSorted.Count) { return $false }
    $state = Get-RouterStateDir
    $queuePath = Join-Path $state 'research-queue.json'
    $added = $false
    Use-RouterQueueMutex -StateDir $state -Action {
        $queue = @(Read-RouterJsonArray -Path $queuePath)
        $key = $categoriesSorted -join '|'
        $exists = @($queue | Where-Object { $_.model -ceq $Model -and $_.trigger -ceq $Trigger -and ((@($_.categories | Sort-Object -Unique) -join '|') -ceq $key) }).Count -gt 0
        if (-not $exists) {
            $item = [pscustomobject]@{ id=[guid]::NewGuid().ToString('N'); model=$Model; trigger=$Trigger; categories=$categoriesSorted; due_at=$DueAt.ToString('o'); reason=$Reason }
            Write-RouterJsonAtomic -Path $queuePath -Value @($queue + $item)
            $added = $true
        }
    }
    return $added
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
        if (Add-RouterResearchQueueItem -Model $mark.model -Trigger refresh -Categories $categories -DueAt $Now -Reason "drift:$($mark.job)") { $added++ }
    }
    foreach ($model in @(Get-RouterStaleReadingModels -Months 6 -Now $Now)) {
        $categories = @(Get-RouterCadenceJobCategories -Model $model -Roster $roster)
        if (Add-RouterResearchQueueItem -Model $model -Trigger refresh -Categories $categories -DueAt $Now -Reason 'stale-reading') { $added++ }
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
            if ($outdated -and (Add-RouterResearchQueueItem -Model $model -Trigger refresh -Categories @($category) -DueAt $Now -Reason 'benchmark-version')) { $added++ }
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

function Invoke-RouterCadence {
    param([datetime]$Now = (Get-Date), [switch]$CheckOnly)
    $state = Get-RouterStateDir
    $queuePath = Join-Path $state 'research-queue.json'
    $added = 0
    # Both daily runs (01:00 full, 13:00 check-only) check for new models, so releases are seen twice a day.
    $check = Invoke-RouterModelCheck -Force -Now $Now; $added += @($check.new_models).Count
    $added += Add-RouterCadenceRefreshes -Now $Now
    $zone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
    $eastern = [TimeZoneInfo]::ConvertTime($Now,$zone)
    $ran = [Collections.Generic.List[object]]::new()
    if (-not $CheckOnly -and $eastern.Hour -lt 6) {
        $roster = (Read-RouterRoster).roster
        foreach ($item in @(Read-RouterJsonArray -Path $queuePath | Where-Object { [datetime]$_.due_at -le $Now } | Sort-Object due_at)) {
            $jobNames = @($item.categories | ForEach-Object { Get-RouterCategoryJob $_ } | Sort-Object -Unique)
            $models = @($item.model) + @($roster.jobs.PSObject.Properties | Where-Object { $jobNames -contains $_.Name } | ForEach-Object { @($_.Value.first,$_.Value.backup) } | Where-Object { $_ -and $_ -cne $item.model } | Sort-Object -Unique)
            $usage = Get-RouterCodexUsage
            $lane = if ($usage -and [double]$usage.used_percent -gt 50) { 'claude' } else { 'codex' }
            $record = Invoke-RouterCategoryResearch -Categories @($item.categories) -Models $models -NewModel $(if ($item.trigger -eq 'release') { [string]$item.model } else { $null }) -Trigger $item.trigger -Lane $lane -Now $Now
            $passPath = Join-Path $state 'readings/passes.jsonl'
            $written = $record -and $record.PSObject.Properties['pass_id'] -and (Test-Path -LiteralPath $passPath) -and
                @((Get-Content -LiteralPath $passPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 }) | Where-Object pass_id -EQ $record.pass_id).Count -gt 0
            if (-not $written) { continue }
            if ($item.trigger -eq 'confirmation') { Write-RouterCadenceConfirmationVerdicts -Item $item -PassId $record.pass_id }
            [void](Build-RouterRosterProposal -Now $Now)
            if ($item.trigger -eq 'confirmation') {
                $verdictPath = Join-Path $state 'roster-proposals/verdicts.jsonl'
                $verdicts = @(if (Test-Path -LiteralPath $verdictPath) { Get-Content -LiteralPath $verdictPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } })
                $current = @($verdicts | Where-Object { $_.pass_id -ceq $record.pass_id -and $_.result -ceq $item.model })
                $firstWins = @($current | Where-Object { $win = $_; -not @($verdicts | Where-Object { $_.pass_id -cne $record.pass_id -and $_.result -ceq $item.model -and $_.job -ceq $win.job -and $_.slot -ceq $win.slot }).Count })
                if ($firstWins.Count) {
                    if (Add-RouterResearchQueueItem -Model $item.model -Trigger followup -Categories @($item.categories) -DueAt $Now.AddDays(7) -Reason 'first-conclusive-confirmation') { $added++ }
                }
            }
            Use-RouterQueueMutex -StateDir $state -Action {
                $remaining = @(Read-RouterJsonArray -Path $queuePath | Where-Object { $_.id -cne $item.id })
                Write-RouterJsonAtomic -Path $queuePath -Value $remaining
            }
            $ran.Add([pscustomobject]@{ id=$item.id; pass_id=$record.pass_id; lane=$lane; trigger=$item.trigger })
        }
    }
    return [pscustomobject]@{ checked=$([bool]$CheckOnly); added=$added; ran=@($ran.ToArray()); pending=@(Read-RouterJsonArray -Path $queuePath).Count; eastern_time=$eastern.ToString('o') }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-RouterCadence -Now $RouterCadenceCliNow -CheckOnly:$RouterCadenceCliCheckOnly
    if ($RouterCadenceCliJson) { $result | ConvertTo-Json -Depth 12 -Compress } else { $result }
}
