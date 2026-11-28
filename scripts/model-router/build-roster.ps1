param([Alias('Now')][datetime]$RouterBuildCliNow = (Get-Date), [Alias('Json')][switch]$RouterBuildCliJson)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot 'resolve-model.ps1')

function Get-RouterProposalVendor {
    param([string]$Model)
    if ($Model -like 'claude-*') { return 'claude' }
    if ($Model -like 'gpt-*') { return 'codex' }
    return $null
}

function Get-RouterProposalPrice {
    param([string]$Model, [object]$Prices)
    $key = Get-RouterPriceKey -Model $Model -Models $Prices.models
    $row = if ($key) { $Prices.models.PSObject.Properties[$key] } else { $null }
    if (-not $row) { return $null }
    $p = $row.Value.prices_usd_per_mtok
    if ($null -eq $p.input -or $null -eq $p.output) { return $null }
    return ([double]$p.input + [double]$p.output) / 2.0
}

function Test-RouterProposalFrontier {
    param([string]$Model, [object]$Frontier)
    return (Test-RouterFrontierModel -Model $Model -Frontier $Frontier)
}

function Get-RouterProposalComparison {
    param([object]$Data, [string]$Challenger, [string]$Incumbent, [string]$FloorEffort = $null)
    $effortOrder = @('low','medium','high','xhigh','max')
    $floorRank = $effortOrder.IndexOf($FloorEffort)
    $groups = @{}
    foreach ($reading in @($Data.readings)) {
        $key = @($reading.benchmark,$reading.version,$reading.harness,$reading.effort_class) -join "`n"
        if (-not $groups.ContainsKey($key)) { $groups[$key] = [pscustomobject]@{ results=@{}; benchmark=$reading.benchmark; effort_class=$reading.effort_class } }
        foreach ($result in @($reading.results)) {
            $model = [string]$result.model
            if (-not $groups[$key].results.ContainsKey($model) -or $reading.independent -or -not $groups[$key].results[$model].independent) {
                $groups[$key].results[$model] = [pscustomobject]@{ value=$result; independent=[bool]$reading.independent }
            }
        }
    }
    $leads = 0; $trails = 0; $comparable = 0; $names = @(); $skipped = 0; $skippedNames = @()
    foreach ($key in @($groups.Keys | Sort-Object)) {
        $g = $groups[$key]
        $effortRank = $effortOrder.IndexOf(([string]$g.effort_class).Trim().ToLowerInvariant())
        if ($effortRank -ge 0 -and $effortRank -lt $floorRank) {
            $skipped++; $skippedNames += $g.benchmark
            continue
        }
        if (-not $g.results.ContainsKey($Challenger) -or -not $g.results.ContainsKey($Incumbent)) { continue }
        $comparable++
        $a = $g.results[$Challenger].value; $b = $g.results[$Incumbent].value
        $margin = [Math]::Max([double]$(if ($null -ne $a.margin) { $a.margin } else { 0 }),[double]$(if ($null -ne $b.margin) { $b.margin } else { 0 }))
        if ($null -eq $a.margin -and $null -eq $b.margin) { $margin = 1.0 }
        $gap = [double]$a.score - [double]$b.score
        if ($gap -gt $margin -and $g.results[$Challenger].independent -and $g.results[$Incumbent].independent -and $names -notcontains $g.benchmark) { $leads++; $names += $g.benchmark }
        if ($gap -lt -$margin) { $trails++ }
    }
    $verdict = if ($trails) { 'trail' } elseif ($leads -ge 2) { 'win' } else { 'not-enough-evidence' }
    return [pscustomobject]@{ verdict=$verdict; leads=$leads; trails=$trails; comparable=$comparable; benchmarks=@($names); skipped=$skipped; skipped_benchmarks=@($skippedNames) }
}

function Get-RouterProposalJobVerdict {
    param([string]$Job, [string]$Incumbent, [string]$Vendor, [hashtable]$Readings, [object]$Prices, [object]$Frontier, [string]$FloorEffort = $null)
    $primary = @{ fast='mechanical'; coder='complex-coding'; 'deep-thinker'='analysis'; writer='long-form-writing'; illustrator='image-generation' }[$Job]
    $categories = @{ fast=@('mechanical'); coder=@('routine-coding','complex-coding','ui-frontend'); 'deep-thinker'=@('code-review','planning','deep-research','math','analysis','classification-escalation'); writer=@('long-form-writing'); illustrator=@('image-generation') }[$Job]
    $models = @($categories | ForEach-Object { if ($Readings.ContainsKey($_)) { $Readings[$_].readings | ForEach-Object { $_.results | ForEach-Object model } } } | Where-Object { $_ -and $_ -ne $Incumbent } | Sort-Object -Unique)
    $qualified = @(); $tradeoffs = @(); $hasFloorClearer = $false
    foreach ($model in $models) {
        if ($Vendor -and (Get-RouterProposalVendor $model) -ne $Vendor) { continue }
        if (Test-RouterProposalFrontier $model $Frontier) { continue }
        $comparisons = @{}; $won = @(); $trailed = @(); $skipped = 0
        foreach ($category in $categories) {
            if (-not $Readings.ContainsKey($category)) { continue }
            $comparison = Get-RouterProposalComparison -Data $Readings[$category] -Challenger $model -Incumbent $Incumbent -FloorEffort $FloorEffort
            $skipped += $comparison.skipped
            $comparisons[$category] = $comparison
            if ($comparison.verdict -eq 'win') { $won += $category }
            if ($comparison.verdict -eq 'trail') { $trailed += $category }
        }
        $p = if ($comparisons.ContainsKey($primary)) { $comparisons[$primary] } else { [pscustomobject]@{verdict='not-enough-evidence';leads=0;trails=0;comparable=0;benchmarks=@()} }
        $price = Get-RouterProposalPrice $model $Prices
        $oldGen = Get-RouterModelGeneration $Incumbent; $newGen = Get-RouterModelGeneration $model
        $older = $oldGen -and $newGen -and $oldGen.vendor -eq $newGen.vendor -and ($newGen.major -lt $oldGen.major -or ($newGen.major -eq $oldGen.major -and $newGen.minor -lt $oldGen.minor))
        $lowerTier = $false
        if ($Job -in @('coder','deep-thinker','writer') -and (Get-RouterProposalVendor $model) -eq (Get-RouterProposalVendor $Incumbent)) {
            $oldTier = Get-RouterModelTier $Incumbent; $newTier = Get-RouterModelTier $model
            $lowerTier = $null -ne $oldTier -and $null -ne $newTier -and $newTier -lt $oldTier
        }
        $quality = $p.verdict -eq 'win' -and $trailed.Count -eq 0
        $floor = $p.comparable -ge 2 -and $p.trails -eq 0
        if ($Job -eq 'fast' -and $floor) { $hasFloorClearer = $true }
        $eligible = if ($Job -eq 'fast') { $floor -and -not $older -and $null -ne $price } else { $quality -and -not $lowerTier }
        $evidence = "$model`: primary $($p.verdict) ($($p.leads) independent leads, $($p.comparable) comparable); skipped $skipped; won [$($won -join ', ')]; trailed [$($trailed -join ', ')]"
        if ($lowerTier) { $evidence += '; lower same-vendor tier' }
        if ($older -and $Job -eq 'fast') { $evidence += '; older generation cannot win on price' }
        $tradeoffs += $evidence
        if ($eligible) { $qualified += [pscustomobject]@{ model=$model; leads=$p.leads; price=$price; evidence=$evidence } }
    }
    $winner = $null
    if ($Job -eq 'fast') {
        $incPrice = Get-RouterProposalPrice $Incumbent $Prices
        $qualified = @($qualified | Where-Object { $null -ne $incPrice -and $null -ne $_.price -and $_.price -lt $incPrice } | Sort-Object price,model)
    } else { $qualified = @($qualified | Sort-Object @{Expression='leads';Descending=$true},@{Expression={if ($null -eq $_.price) {[double]::PositiveInfinity} else {$_.price}}},model) }
    if ($qualified.Count) { $winner = $qualified[0] }
    $result = if ($winner) { $winner.model } elseif ($Job -eq 'fast' -and $hasFloorClearer) { 'keep' } elseif ($tradeoffs.Count -and @($tradeoffs | Where-Object { $_ -match 'trailed \[[^]]+\]' }).Count) { 'keep' } else { 'not-enough-evidence' }
    return [pscustomobject]@{ result=$result; evidence=$(if ($winner) {$winner.evidence} else {$tradeoffs -join '; '}); tradeoffs=@($tradeoffs) }
}

function Get-RouterProposalCategories {
    param([string]$Job)
    return @(Get-RouterDispatchCategories | Where-Object { (Get-RouterCategoryJob $_) -eq $Job })
}

function Get-RouterProposalCategoryVerdict {
    param([string]$Job, [string]$Category, [string]$Slot, [string]$Holder, [string]$Vendor,
        [hashtable]$Readings, [object]$Prices, [object]$Frontier, [string]$FloorEffort = $null)
    $qualified = @(); $tradeoffs = @(); $trailed = $false
    $models = @(if ($Readings.ContainsKey($Category)) {
        $Readings[$Category].readings | ForEach-Object { $_.results | ForEach-Object model } |
            Where-Object { $_ -and $_ -ne $Holder } | Sort-Object -Unique
    })
    foreach ($model in $models) {
        if ($Vendor -and (Get-RouterProposalVendor $model) -ne $Vendor) { continue }
        if (Test-RouterProposalFrontier $model $Frontier) { continue }
        if ((Get-RouterProposalVendor $model) -eq (Get-RouterProposalVendor $Holder)) {
            $oldTier = Get-RouterModelTier $Holder; $newTier = Get-RouterModelTier $model
            if ($null -ne $oldTier -and $null -ne $newTier -and $newTier -lt $oldTier) { continue }
        }
        $comparison = Get-RouterProposalComparison -Data $Readings[$Category] -Challenger $model -Incumbent $Holder -FloorEffort $FloorEffort
        $evidence = "$model`: $Category $($comparison.verdict) ($($comparison.leads) independent leads, $($comparison.trails) trails, $($comparison.comparable) comparable); skipped $($comparison.skipped); benchmarks [$($comparison.benchmarks -join ', ')]"
        $tradeoffs += $evidence
        if ($comparison.verdict -eq 'trail') { $trailed = $true }
        if ($comparison.verdict -eq 'win') {
            $qualified += [pscustomobject]@{model=$model;leads=$comparison.leads;price=(Get-RouterProposalPrice $model $Prices);evidence=$evidence;comparison=$comparison}
        }
    }
    $qualified = @($qualified | Sort-Object @{Expression='leads';Descending=$true},@{Expression={if ($null -eq $_.price) {[double]::PositiveInfinity} else {$_.price}}},model)
    $winner = if ($qualified.Count) { $qualified[0] } else { $null }
    return [pscustomobject]@{
        result=$(if ($winner) {$winner.model} elseif ($trailed) {'keep'} else {'not-enough-evidence'})
        evidence=$(if ($winner) {$winner.evidence} else {$tradeoffs -join '; '})
        comparison=$(if ($winner) {$winner.comparison} else {$null}); tradeoffs=@($tradeoffs)
    }
}

function Write-RouterProposalCategoryRecord {
    param([string]$Path, [array]$History, [string]$PassId, [string]$Job, [string]$Slot,
        [string]$Category, [string]$Result, [string]$Holder)
    if (@($History | Where-Object { $_.PSObject.Properties['category'] -and $_.pass_id -eq $PassId -and $_.job -eq $Job -and $_.slot -eq $Slot -and $_.category -eq $Category }).Count) { return }
    $record = [pscustomobject]@{pass_id=$PassId;job=$Job;slot=$Slot;category=$Category;result=$Result;holder=$Holder}
    [IO.File]::AppendAllText($Path, (($record | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    return $record
}

function Get-RouterProposalCategoryTarget {
    param([array]$History, [string]$Job, [string]$Slot, [string]$Category, [string]$Holder)
    $eligible = @($History | Where-Object { $_.PSObject.Properties['category'] -and $_.job -eq $Job -and $_.slot -eq $Slot -and $_.category -eq $Category -and $_.result -ne 'not-enough-evidence' } | Select-Object -Last 2)
    if ($eligible.Count -eq 2 -and $eligible[0].pass_id -ne $eligible[1].pass_id -and $eligible[0].result -eq $eligible[1].result -and $eligible[1].result -notin @('keep',$Holder)) { return [string]$eligible[1].result }
}

function Set-RouterProposalSlotHolders {
    param([object]$Entry, [object]$CurrentEntry, [string]$Job, [string]$Slot, [hashtable]$Holders)
    $categories = @(Get-RouterProposalCategories $Job)
    $changed = @($categories | Where-Object { $Holders[$_] -ne (Get-RouterEffectiveSlots -Entry $CurrentEntry -Category $_).$Slot })
    # Restore the original slot shape too when a tentative change is withdrawn.
    $Entry.$Slot = $CurrentEntry.$Slot; $Entry."${Slot}_vendor" = $CurrentEntry."${Slot}_vendor"
    if ($Entry.PSObject.Properties['category_overrides']) {
        foreach ($category in @($Entry.category_overrides.PSObject.Properties.Name)) {
            $Entry.category_overrides.$category.PSObject.Properties.Remove($Slot)
            if (-not @($Entry.category_overrides.$category.PSObject.Properties).Count) { $Entry.category_overrides.PSObject.Properties.Remove($category) }
        }
    }
    $default = $CurrentEntry.$Slot
    if ($changed.Count) {
        $primary = @{fast='mechanical';coder='complex-coding';'deep-thinker'='analysis';writer='long-form-writing';illustrator='image-generation'}[$Job]
        if ($changed -contains $primary) { $default = $Holders[$primary] }
        else {
            $counts = @($categories | ForEach-Object { $Holders[$_] } | Group-Object | Sort-Object Count -Descending)
            if ($counts.Count -eq 1 -or $counts[0].Count -gt $counts[1].Count) { $default = $counts[0].Name }
        }
        $Entry.$Slot = $default; $Entry."${Slot}_vendor" = Get-RouterProposalVendor $default
    }
    foreach ($category in $categories) {
        if ($Holders[$category] -eq $default) { continue }
        if (-not $Entry.PSObject.Properties['category_overrides']) { $Entry | Add-Member -NotePropertyName category_overrides -NotePropertyValue ([pscustomobject]@{}) }
        if (-not $Entry.category_overrides.PSObject.Properties[$category]) { $Entry.category_overrides | Add-Member -NotePropertyName $category -NotePropertyValue ([pscustomobject]@{}) }
        $Entry.category_overrides.$category | Add-Member -NotePropertyName $Slot -NotePropertyValue ([pscustomobject]@{model=$Holders[$category];vendor=(Get-RouterProposalVendor $Holders[$category])}) -Force
    }
    if ($Entry.PSObject.Properties['category_overrides'] -and -not @($Entry.category_overrides.PSObject.Properties).Count) { $Entry.PSObject.Properties.Remove('category_overrides') }
}

function Build-RouterRosterProposalLocked {
    param([datetime]$Now = (Get-Date), [object]$Notification, [switch]$StageOnly,
        [hashtable]$BenchResults, [string]$RosterIdentity)
    $state = Get-RouterStateDir
    $current = (Read-RouterRoster).roster
    $identity = ConvertTo-Json -InputObject $current.jobs -Compress -Depth 30
    if ($RosterIdentity -and $RosterIdentity -cne $identity) { throw 'BENCH_STALE_ROSTER: model or effort changed during comparison' }
    $requests = @()
    $readDir = Join-Path $state 'readings'
    $passesPath = Join-Path $readDir 'passes.jsonl'
    $passes = @(if (Test-Path -LiteralPath $passesPath) { Get-Content -LiteralPath $passesPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } })
    if (-not $passes.Count) { return [pscustomobject]@{changed=$false;pass_id=$null;changes=@();proposal=$null;report=$null} }
    $passId = [string]$passes[-1].pass_id
    # Map through the 11-category job map (not the v1 table's category list, which lacks math and analysis); unknown names are skipped.
    $passCategories = if ($passes[-1].PSObject.Properties['categories']) { @($passes[-1].categories) } else { @() }
    $coveredJobs = @($passCategories | ForEach-Object { try { Get-RouterCategoryJob -Category ([string]$_) } catch { } } | Where-Object { $_ } | Sort-Object -Unique)
    $readings = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $readDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) { $data = Read-RouterJsonObject $file.FullName; if ($data -and $data.PSObject.Properties['readings']) { $readings[$file.BaseName] = $data } }
    $prices = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/api-prices.json') -Raw | ConvertFrom-Json -Depth 20
    $frontier = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json -Depth 20
    $dir = Join-Path $state 'roster-proposals'; [IO.Directory]::CreateDirectory($dir) | Out-Null
    $verdictPath = Join-Path $dir 'verdicts.jsonl'
    $history = @(if (Test-Path -LiteralPath $verdictPath) { Get-Content -LiteralPath $verdictPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } })
    $proposed = $current | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $proposed.jobs.coder | Add-Member -NotePropertyName first_vendor_pin -NotePropertyValue codex -Force
    $proposed.generated_at = $Now.ToString('o'); $proposed.approved = $false; $proposed.approved_at = $null
    $changes = @(); $tradeoffs = @(); $conflicts = @()
    foreach ($job in @(Get-RouterJobs)) {
        if ($coveredJobs -notcontains $job) { continue }
        $entry = $proposed.jobs.$job
        $currentEntry = $current.jobs.$job
        $categories = @(Get-RouterProposalCategories $job)
        foreach ($slot in @('first','backup')) {
            if ($job -eq 'illustrator' -and $slot -eq 'backup') { continue }
            $holders = @{}
            foreach ($category in $categories) { $holders[$category] = (Get-RouterEffectiveSlots -Entry $currentEntry -Category $category).$slot }
            $floorEffort = Get-RouterTierEffort -Entry $currentEntry -Slot $slot -Difficulty standard
            $slotChanged = $false
            foreach ($category in $categories) {
                $old = Get-RouterEffectiveSlots -Entry $currentEntry -Category $category
                $next = Get-RouterEffectiveSlots -Entry $entry -Category $category
                $holder = [string]$old.$slot
                $flipped = $slot -eq 'backup' -and $old.backup_vendor -eq $next.first_vendor
                $incumbent = if ($flipped) { $old.first } else { $holder }
                $vendor = if ($slot -eq 'backup') { if ($next.first_vendor -eq 'codex') {'claude'} else {'codex'} } else { $null }
                $pin = $entry.PSObject.Properties["${slot}_vendor_pin"]
                if ($pin) {
                    if ($vendor -and $vendor -ne $pin.Value) {
                        $record = Write-RouterProposalCategoryRecord -Path $verdictPath -History $history -PassId $passId -Job $job -Slot $slot -Category $category -Result keep -Holder $holder
                        if ($record) { $history += $record }
                        continue
                    }
                    $vendor = [string]$pin.Value
                }
                if ($job -in @('fast','illustrator')) {
                    $verdict = Get-RouterProposalJobVerdict -Job $job -Incumbent $incumbent -Vendor $vendor -Readings $readings -Prices $prices -Frontier $frontier -FloorEffort $floorEffort
                } else {
                    $verdict = Get-RouterProposalCategoryVerdict -Job $job -Category $category -Slot $slot -Holder $incumbent -Vendor $vendor -Readings $readings -Prices $prices -Frontier $frontier -FloorEffort $floorEffort
                }
                if ($flipped -and $verdict.result -in @('keep','not-enough-evidence')) {
                    $verdict.result = $incumbent
                    $verdict.evidence = "Other-vendor incumbent after first-choice flip: $incumbent. $($verdict.evidence)"
                }
                $record = Write-RouterProposalCategoryRecord -Path $verdictPath -History $history -PassId $passId -Job $job -Slot $slot -Category $category -Result $verdict.result -Holder $holder
                if ($record) { $history += $record }
                $target = Get-RouterProposalCategoryTarget -History $history -Job $job -Slot $slot -Category $category -Holder $holder
                if ($flipped) { $target = [string]$verdict.result }
                if (-not $target -or $target -eq $holder -or (Test-RouterProposalFrontier $target $frontier)) {
                    if ($verdict.result -eq 'keep') { $tradeoffs += "$job/$slot/$category`: $($verdict.evidence)" }
                    continue
                }
                # Older histories cannot bypass a newly introduced vendor pin or backup constraint.
                if ($vendor -and (Get-RouterProposalVendor $target) -ne $vendor) { continue }
                $key = "$job/$slot/$target/$holder"
                if (-not @($requests | Where-Object key -eq $key).Count) {
                    $requests += [pscustomobject]@{key=$key;job=$job;candidate=$target;incumbent=$holder;effort=$currentEntry."${slot}_effort"}
                }
                if (-not $StageOnly) {
                    if (-not $BenchResults -or -not $BenchResults.ContainsKey($key)) { continue }
                    $bench = $BenchResults[$key]
                    if ($bench.PSObject.Properties['halted'] -and $bench.halted) { continue }
                    if ($bench.raw_gate -eq 'unknown' -or $bench.gate -in @('unknown','fail') -or ($job -in @('fast','coder','deep-thinker') -and $bench.raw_gate -eq 'fail')) { continue }
                    $measured = @(if ($bench.PSObject.Properties['tiers']) { $bench.tiers | ForEach-Object { [pscustomobject]$_ } } else { $bench })
                    if (@($measured | Where-Object { $_.PSObject.Properties['quality_verdict'] -and $_.quality_verdict -and $_.quality_verdict.verdict -ceq 'incumbent_better' }).Count) { continue }
                    if ($bench.tied -or $bench.better -ne $target) { continue }
                    $benchEvidence = New-RouterBenchProposalEvidence -Job $job -Bench $bench
                    if (Get-RouterBenchProposalEvidenceError -Job $job -Evidence $benchEvidence) { continue }
                    $verdict.evidence += "; Bench $($bench.gate); shortfall $($bench.shortfall_tasks) task(s); report $($bench.report_paths.markdown)"
                }
                $holders[$category] = $target; $slotChanged = $true
                $comparison = if ($readings.ContainsKey($category)) { Get-RouterProposalComparison -Data $readings[$category] -Challenger $target -Incumbent $incumbent -FloorEffort $floorEffort } else { [pscustomobject]@{leads=0;trails=0;comparable=0;skipped=0} }
                $changes += [pscustomobject]@{job=$job;slot=$slot;category=$category;from=$holder;to=$target;evidence=$verdict.evidence;leads=$comparison.leads;trails=$comparison.trails;comparable=$comparison.comparable;skipped=$comparison.skipped}
                if (-not $StageOnly) {
                    $changes[-1] | Add-Member -NotePropertyName bench_evidence -NotePropertyValue $benchEvidence
                    $quality = @($measured | Where-Object { $_.PSObject.Properties['quality_evidence'] -and $_.quality_evidence } | ForEach-Object quality_evidence)
                    if ($quality.Count) { $changes[-1] | Add-Member -NotePropertyName quality_evidence -NotePropertyValue $quality }
                }
            }
            if ($slotChanged) { Set-RouterProposalSlotHolders -Entry $entry -CurrentEntry $currentEntry -Job $job -Slot $slot -Holders $holders }
        }
        $firstHolders = @{}; $withdrawn = $false
        foreach ($category in $categories) {
            $next = Get-RouterEffectiveSlots -Entry $entry -Category $category
            $firstHolders[$category] = $next.first
            if ($next.backup -and $next.first_vendor -eq $next.backup_vendor) {
                $change = @($changes | Where-Object { $_.job -eq $job -and $_.slot -eq 'first' -and $_.category -eq $category })
                if ($change.Count) {
                    $conflicts += [pscustomobject]@{job=$job;slot='first';category=$category;from=$change[0].from;to=$change[0].to;evidence='First change withdrawn: other-vendor backup did not pass its bench.'}
                    $changes = @($changes | Where-Object { -not ($_.job -eq $job -and $_.slot -eq 'first' -and $_.category -eq $category) })
                    $firstHolders[$category] = (Get-RouterEffectiveSlots -Entry $currentEntry -Category $category).first
                    $withdrawn = $true
                }
            }
        }
        if ($withdrawn) { Set-RouterProposalSlotHolders -Entry $entry -CurrentEntry $currentEntry -Job $job -Slot first -Holders $firstHolders }
    }
    if ($StageOnly) {
        foreach ($job in $coveredJobs) {
            $entry = $current.jobs.$job
            if ($entry.first_effort -ne 'low' -and -not @($requests | Where-Object { $_.job -eq $job -and $_.incumbent -eq $entry.first }).Count) {
                $requests += [pscustomobject]@{key="$job/effort";job=$job;candidate=$entry.first;incumbent=$entry.first;effort=$entry.first_effort}
            }
        }
    }
    if ($StageOnly) { return [pscustomobject]@{requests=@($requests);identity=$identity} }
    if (-not $changes.Count -and -not $conflicts.Count) { return [pscustomobject]@{changed=$false;pass_id=$passId;changes=@();proposal=$null;report=$null} }
    $latest = Read-RouterJsonObject -Path (Join-Path $dir 'latest.json')
    if ($latest -and $latest.PSObject.Properties['proposal']) {
        $previous = Read-RouterJsonObject -Path ([string]$latest.proposal)
        if ($previous -and $previous.PSObject.Properties['pass_id'] -and $previous.pass_id -eq $passId -and (ConvertTo-Json $previous.jobs -Compress -Depth 30) -ceq (ConvertTo-Json $proposed.jobs -Compress -Depth 30) -and (ConvertTo-Json -InputObject @($previous.changes) -Compress -Depth 20) -ceq (ConvertTo-Json -InputObject @($changes) -Compress -Depth 20)) {
            return [pscustomobject]@{changed=$false;pass_id=$passId;changes=@();proposal=$null;report=$null}
        }
    }
    $counts = Get-RouterRosterModelCounts -Roster $proposed
    $overCap = $counts.job_defaults -gt 5
    $priorIds = @($current.jobs.PSObject.Properties | ForEach-Object { @($_.Value.first,$_.Value.backup) } | Where-Object { $_ } | Sort-Object -Unique)
    if ($overCap) { $conflicts += @($changes | Where-Object { $priorIds -notcontains $_.to } | ForEach-Object { [pscustomobject]@{job=$_.job;slot=$_.slot;category=$_.category;from=$_.from;to=$_.to;evidence=$_.evidence} }) }
    $capFits = @()
    foreach ($job in @($changes | ForEach-Object job | Sort-Object -Unique)) {
        $partial = $current | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $partial.jobs.$job = $proposed.jobs.$job
        $partialCount = (Get-RouterRosterModelCounts -Roster $partial).job_defaults
        $capFits += [pscustomobject]@{job=$job;fits=($partialCount -le 5);count=$partialCount}
    }
    $capLine = (@($capFits | ForEach-Object { "$($_.job) alone: $(if ($_.fits) {'fits'} else {'exceeds'}) the five-model cap ($($_.count) job-default models)." }) -join ' ')
    if (-not $capFits.Count) { $capLine = 'No model changes remain after conflicts.' }
    if ($capFits.Count -and -not @($capFits | Where-Object fits).Count) { $capLine += ' No single-job approval fits the five-model cap.' }
    $proposed | Add-Member -Force -NotePropertyName changes -NotePropertyValue @($changes)
    $proposed | Add-Member -Force -NotePropertyName over_cap -NotePropertyValue $overCap
    $proposed | Add-Member -Force -NotePropertyName conflicts -NotePropertyValue $conflicts
    $proposed | Add-Member -Force -NotePropertyName pass_id -NotePropertyValue $passId
    $proposed | Add-Member -Force -NotePropertyName dimension_framework -NotePropertyValue provisional
    $errors = @(Test-RouterRoster $proposed)
    $proposed | Add-Member -Force -NotePropertyName validation_errors -NotePropertyValue $errors
    if ($errors.Count -and -not $overCap) { throw "PROPOSAL_INVALID: $($errors -join '; ')" }
    $stem = $Now.ToString('yyyy-MM-ddTHHmmss'); $jsonPath = Join-Path $dir ($stem + '.json'); $reportPath = Join-Path $dir ($stem + '.md')
    [IO.File]::WriteAllText($jsonPath,($proposed | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    $lines = @('# Model list proposal','','| Job | Current | Proposed | Evidence summary | Backup |','| --- | --- | --- | --- | --- |')
    foreach ($job in @(Get-RouterJobs)) {
        $evidence = @($changes | Where-Object job -eq $job | ForEach-Object evidence) -join '; '
        $lines += "| $job | $($current.jobs.$job.first) | $($proposed.jobs.$job.first) (effort $($proposed.jobs.$job.first_effort)) | $evidence | $($proposed.jobs.$job.backup) (effort $($proposed.jobs.$job.backup_effort)) |"
    }
    $lines += @('',"Distinct models (job defaults only): $($counts.job_defaults).", "Distinct models (all models including exceptions): $($counts.all_models).", "Cap fit: $capLine",'',
        '## Per-category changes','', '| Job/slot | Category | From | To | Leads | Trails | Skipped below slot effort | Evidence |', '| --- | --- | --- | --- | --- | --- | --- | --- |')
    foreach ($change in $changes) {
        $lines += "| $($change.job)/$($change.slot) | $($change.category) | $($change.from) | $($change.to) | $($change.leads) | $($change.trails) | $($change.skipped) | $($change.evidence) |"
    }
    $lines += @('','## Category exceptions','')
    $exceptions = @($proposed.jobs.PSObject.Properties | Where-Object { $_.Value.PSObject.Properties['category_overrides'] })
    if (-not $exceptions.Count) { $lines += 'None.' }
    foreach ($jobProperty in $exceptions) {
        foreach ($categoryProperty in $jobProperty.Value.category_overrides.PSObject.Properties) {
            foreach ($pick in $categoryProperty.Value.PSObject.Properties) { $lines += "- $($jobProperty.Name)/$($pick.Name)/$($categoryProperty.Name): $($pick.Value.model) ($($pick.Value.vendor))." }
        }
    }
    $lines += @('','## Benchmark basis','')
    $lines += @($changes | ForEach-Object { "- $($_.job)/$($_.slot): $(ConvertTo-Json $_.bench_evidence -Compress -Depth 10)" })
    $lines += @('','## Conflicts','')
    if ($conflicts.Count) { $lines += @($conflicts | ForEach-Object { "- $($_.job)/$($_.slot)/$($_.category): $($_.from) -> $($_.to). $($_.evidence)" }) } else { $lines += 'None.' }
    $lines += @('','## Tradeoffs for keep jobs','')
    if ($tradeoffs.Count) { $lines += @($tradeoffs | ForEach-Object { "- $_" }) } else { $lines += 'None.' }
    [IO.File]::WriteAllText($reportPath,(($lines -join "`n") + "`n"),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $dir 'latest.json'),(ConvertTo-Json -InputObject ([pscustomobject]@{proposal=$jsonPath;report=$reportPath}) -Compress),[Text.UTF8Encoding]::new($false))
    $alertChanges = @($changes | ForEach-Object { [pscustomobject]@{job=$_.job;slot=$_.slot;category=$_.category;from=$_.from;to=$_.to;bench_evidence=$_.bench_evidence} })
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $alertChanges -Compress -Depth 20)))).ToLowerInvariant()
    $first = if ($changes.Count) { $changes[0] } else { $conflicts[0] }
    $alertMessage = "Model list change proposed: $($first.job)/$($first.category) $($first.from) -> $($first.to). Report: $reportPath Cap fit: $capLine"
    if ($overCap) {
        $jobs = @($conflicts | ForEach-Object job | Sort-Object -Unique) -join ','
        $alertMessage += " Over the 5-model cap; choose which of these jobs to change: $jobs. Approve your pick with approve-roster.ps1 -Approve -Jobs <job,...> (the full list exceeds the cap)."
    }
    $Notification.alert = [pscustomobject]@{key="roster-proposal:$hash";message=$alertMessage}
    return [pscustomobject]@{changed=$true;pass_id=$passId;changes=@($changes);proposal=$jsonPath;report=$reportPath;over_cap=$overCap;conflicts=$conflicts;validation_errors=$errors}
}

function Test-RouterQualityDecided {
    param([object]$Verdict)
    $Verdict = [pscustomobject]$Verdict
    if (-not $Verdict -or -not $Verdict.PSObject.Properties['tasks']) { return $false }
    return @($Verdict.tasks | Where-Object {
        $_.candidate_wins -gt 0 -or $_.incumbent_wins -gt 0 -or
        @($_.reps | Where-Object { @($_.judges).Count -eq 2 -and @($_.judges | Where-Object reply -CEQ 'no_difference').Count -eq 2 }).Count -gt 0
    }).Count -gt 0
}

function Save-RouterEffortProposal {
    param([object]$Request, [object]$Bench)
    # Caller holds the outcome lock and has revalidated the roster snapshot.
    if ($Bench.PSObject.Properties['halted'] -and $Bench.halted) { return }
    if ($Bench.PSObject.Properties['tiers']) {
        foreach ($tierResult in @($Bench.tiers)) {
            $tierRequest = [pscustomobject]@{job=$Request.job;candidate=$Request.candidate;incumbent=$tierResult.incumbent.model;effort=$tierResult.incumbent.effort}
            Save-RouterEffortProposal -Request $tierRequest -Bench ([pscustomobject]$tierResult)
        }
        return
    }
    $tier = if ($Bench.PSObject.Properties['tier']) { $Bench.tier } else { 'standard' }
    if (-not $Bench.PSObject.Properties['shadow'] -or $Bench.shadow -isnot [bool] -or $Bench.shadow) { return }
    $writer = $Request.job -eq 'writer'
    $raising = $Bench.PSObject.Properties['effort_up_qualified'] -and $Bench.effort_up_qualified
    $qualification = if ($raising) { 'effort_up_qualified' } else { 'effort_down_qualified' }
    if ($writer -and -not $raising) { return }
    if (-not $Bench.PSObject.Properties[$qualification] -or -not $Bench.$qualification) { return }
    $qualityName = if ($raising) { 'effort_up_quality_evidence' } else { 'effort_down_quality_evidence' }
    $quality = if ($Bench.PSObject.Properties[$qualityName]) { $Bench.$qualityName } else { $null }
    if ($raising -and -not $writer -and -not $quality) { return }
    $verdictName = if ($raising) { 'effort_up_quality_verdict' } else { 'effort_down_quality_verdict' }
    $verdict = if ($Bench.PSObject.Properties[$verdictName]) { $Bench.$verdictName } else { $null }
    if ($Bench.raw_gate -eq 'unknown' -and -not (Test-RouterQualityDecided $verdict)) { return }
    if ($quality -and (($raising -and $quality.verdict -cne 'candidate_better') -or (-not $raising -and $quality.verdict -ceq 'incumbent_better'))) { return }
    $current = (Read-RouterRoster).roster.jobs.($Request.job)
    # Without tier objects the scalar drives both tiers; neither tier may change it independently.
    if ($Request.job -in @('coder','deep-thinker') -and -not $current.PSObject.Properties['first_efforts']) { return }
    if ($current.first -cne $Request.incumbent -or (Get-RouterTierEffort $current first $tier) -cne $Request.effort) { return }
    $next = if ($raising) { $(if ($writer) { @{low='medium';medium='high';high='xhigh'} } else { @{low='medium';medium='high'} })[[string]$Request.effort] } else { @{medium='low';high='medium'}[[string]$Request.effort] }
    $laneName = if ($raising) { 'effort_up' } else { 'effort_down' }
    $lane = $Bench.$laneName
    if (-not $next -or $lane.model -cne $current.first -or $lane.effort -cne $next) { return }
    $evidence = New-RouterBenchProposalEvidence -Job $Request.job -Bench $Bench
    if (Get-RouterBenchProposalEvidenceError -Job $Request.job -Evidence $evidence) { return }
    # A swap Danny declined under this evidence identity is never re-filed, whichever file now sits at the path.
    $key = Get-RouterEffortProposalKey -Proposal ([pscustomobject]@{job=$Request.job;tier=$tier;model=$current.first;current_effort=$Request.effort;proposed_effort=$next;bench_evidence=$evidence})
    if (Test-RouterEffortDeclined -Key $key) { return }
    $dir = Join-Path (Get-RouterStateDir) 'effort-proposals'
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $path = Join-Path $dir ($Request.job + $(if ($Request.job -in @('coder','deep-thinker')) { '-' + $tier } else { '' }) + '.json')
    $old = Read-RouterJsonObject $path
    if ($old -and $old.model -ceq $current.first -and $old.current_effort -ceq $Request.effort -and $old.proposed_effort -ceq $next -and $old.PSObject.Properties['bench_evidence'] -and (ConvertTo-Json $old.bench_evidence -Compress -Depth 10) -ceq (ConvertTo-Json $evidence -Compress -Depth 10)) { return }
    $proposal = [pscustomobject]@{type='effort-swap';job=$Request.job;tier=$tier;model=$current.first;current_effort=$Request.effort;proposed_effort=$next;status='pending';bench_evidence=$evidence;incumbent=$Bench.incumbent;report=$Bench.report_paths.markdown;dimension_framework='provisional'}
    $proposal | Add-Member -NotePropertyName $laneName -NotePropertyValue $lane
    if ($quality) { $proposal | Add-Member -NotePropertyName quality_evidence -NotePropertyValue $quality }
    Write-RouterJsonAtomic -Path $path -Value $proposal
}


function Send-RouterEffortAlerts {
    $dir = Join-Path (Get-RouterStateDir) 'effort-proposals'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.json')) {
        $swap = Read-RouterJsonObject $file.FullName
        $evidence = if ($swap.PSObject.Properties['bench_evidence']) { $swap.bench_evidence } else { $null }
        if ($swap.status -eq 'pending' -and -not (Get-RouterBenchProposalEvidenceError -Job $swap.job -Evidence $evidence)) {
            $identity = ConvertTo-Json $evidence -Compress -Depth 10
            Send-RouterAlerts -Alerts @([pscustomobject]@{key="effort-swap:$($swap.job)/$($swap.model)/$($swap.current_effort)/$($swap.proposed_effort)/$identity";message="Effort swap for $($swap.job): $($swap.model), $($swap.current_effort) -> $($swap.proposed_effort). Review $($swap.report)."}) | Out-Null
        }
    }
}

function Invoke-RouterTriggeredComparison {
    param($Request, [ValidateSet('research','drift','new-model')][string]$Trigger, [scriptblock]$BenchInvoker, [bool]$SendAlerts = $true)
    if (-not $BenchInvoker) {
        . (Join-Path $PSScriptRoot 'bench/run-bench.ps1')
        $BenchInvoker = { param($r) Invoke-RouterBench -Job $r.job -Candidate $r.candidate -Incumbent $r.incumbent -EffortOverride $r.effort -Trigger $Trigger }
    }
    # Resolve evidence before dispatch so exceptions retain the effective identity.
    $state = Get-RouterStateDir
    $configPath = Join-Path $state 'bench/judge-config.json'
    if (-not (Test-Path -LiteralPath $configPath)) { $configPath = Join-Path $PSScriptRoot 'bench/bench-config.json' }
    $judgeConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $judges = $judgeConfig.judges
    $judgeEffort = if ($judgeConfig.PSObject.Properties['judge_effort']) { $judgeConfig.judge_effort } else { (Get-Content (Join-Path $PSScriptRoot 'bench/bench-config.json') -Raw | ConvertFrom-Json).judge_effort }
    $digest = & python -c 'import sys; from pathlib import Path; sys.path.insert(0,sys.argv[1]); from review import bank_hash, private_bank_path; print(bank_hash(Path(sys.argv[1])/"tasks",private_bank_path(Path(sys.argv[2]))))' (Join-Path $PSScriptRoot 'bench') $state
    if ($LASTEXITCODE -ne 0) { throw 'BENCH_IDENTITY_FAILED' }
    $identityOf = { param($d, $j, $e) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$d/$($j.claude)/$($j.codex)/$e"))).ToLowerInvariant() }
    $requested = & $identityOf $digest $judges $judgeEffort
    $identity = $requested
    $logPath = Join-Path $state 'bench/trigger-log.jsonl'
    # The same comparison (job, models, effort, bank, judges) is run once; a repeat reuses the saved
    # result. Every research pass used to re-run it: six identical deep-thinker comparisons a night on
    # 2026-10-03 to 10-05.
    $requestKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$($Request.job)/$($Request.candidate)/$($Request.incumbent)/$($Request.effort)/$requested"))).ToLowerInvariant()
    $cachePath = Join-Path $state "bench/triggered/$requestKey.json"
    $reusable = { param($value)
        if (-not $value -or $value.gate -in @('unknown','duplicate')) { return $false }
        $tiers = @($value)
        if ($value.PSObject.Properties['tiers']) { $tiers += @($value.tiers) }
        foreach ($tierResult in $tiers) {
            if ($tierResult.PSObject.Properties['halted'] -and $tierResult.halted) { return $false }
            if ($tierResult.PSObject.Properties['quality_verdict'] -and $null -ne $tierResult.quality_verdict) {
                $quality = $tierResult.quality_verdict
                $hasVerdict = if ($quality -is [Collections.IDictionary]) { $quality.Contains('verdict') } else { [bool]$quality.PSObject.Properties['verdict'] }
                if ($quality -eq 'unknown' -or ($hasVerdict -and $quality.verdict -eq 'unknown')) { return $false }
                # Match bench_ledger.scored_ranked_rounds and bench_engine's minimum:
                # a round counts only when both judges returned scored replies.
                $quality = [pscustomobject]$quality
                $scored = 0
                if ($quality.PSObject.Properties['tasks']) {
                    foreach ($task in $quality.tasks) {
                        $task = [pscustomobject]$task
                        if (-not $task.PSObject.Properties['reps']) { continue }
                        foreach ($rep in $task.reps) {
                            $rep = [pscustomobject]$rep
                            if (-not $rep.PSObject.Properties['judges']) { continue }
                            $judgesInRound = @($rep.judges)
                            if ($judgesInRound.Count -ne 2) { continue }
                            $scoredReplies = @($judgesInRound | Where-Object {
                                $judge = [pscustomobject]$_
                                $judge.PSObject.Properties['reply'] -and $judge.reply -cin @('a','b','no_difference')
                            })
                            if ($scoredReplies.Count -eq 2) { $scored++ }
                        }
                    }
                }
                if ($scored -lt 3) { return $false }
            }
        }
        return $true
    }
    $previous = @(if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -Depth 10 } | Where-Object {
        $_.PSObject.Properties['requested_identity'] -and $_.requested_identity -ceq $requested -and $_.gate -notin @('unknown','duplicate') -and
        $_.job -ceq $Request.job -and $_.candidate -ceq $Request.candidate -and $_.incumbent -ceq $Request.incumbent -and [string]$_.effort -ceq [string]$Request.effort } })
    # Recheck saved evidence too: older runs could log gate=pass during a judge
    # outage. Such a cache must never suppress a later corrected comparison.
    $cached = Read-RouterJsonObject -Path $cachePath
    $duplicate = $previous.Count -gt 0 -and (& $reusable $cached)
    if ($duplicate) {
        $bench = $cached
        $bench | Add-Member -NotePropertyName duplicate_of -NotePropertyValue $previous[-1].at -Force
    } else {
        try { $bench = & $BenchInvoker $Request }
        catch { $bench = [pscustomobject]@{raw_gate='unknown';gate='unknown';effort_down_qualified=$false;error=$_.Exception.Message} }
        if ($bench.PSObject.Properties['task_bank_sha256']) { $digest = $bench.task_bank_sha256 }
        if ($bench.PSObject.Properties['judge_pair']) { $judges = $bench.judge_pair }
        if ($bench.PSObject.Properties['judge_effort']) { $judgeEffort = $bench.judge_effort }
        $identity = & $identityOf $digest $judges $judgeEffort
    }
    Use-RouterOutcomeMutex -StateDir $state -Action {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $logPath))
        if (-not $duplicate -and (& $reusable $bench)) { Write-RouterJsonAtomic -Path $cachePath -Value $bench }
        $row = [pscustomobject]@{trigger=$Trigger;job=$Request.job;candidate=$Request.candidate;incumbent=$Request.incumbent;effort=$Request.effort;judge_effort=$judgeEffort;gate=$(if ($duplicate) { 'duplicate' } else { $bench.gate });identity=$identity;requested_identity=$requested;at=(Get-Date).ToUniversalTime().ToString('o')}
        [IO.File]::AppendAllText($logPath, (($row | ConvertTo-Json -Compress)+"`n"), [Text.UTF8Encoding]::new($false))
    } | Out-Null
    if ($SendAlerts -and $bench.gate -eq 'unknown') {
        Send-RouterAlerts -Alerts @([pscustomobject]@{key="bench-unknown:$Trigger/$($Request.job)/$($Request.candidate)/$($Request.incumbent)/$($Request.effort)/$identity";message="Bench comparison could not run for $($Request.job). No model change proposed; see bench/trigger-log.jsonl."}) | Out-Null
    }
    return $bench
}

function Build-RouterRosterProposal {
    param([datetime]$Now = (Get-Date), [scriptblock]$BenchInvoker)
    Assert-RouterOwner -Action 'Roster proposal construction'
    $notification = [pscustomobject]@{ alert=$null }
    $staged = Use-RouterOutcomeMutex -StateDir (Get-RouterStateDir) -Action { Build-RouterRosterProposalLocked -Now $Now -Notification $notification -StageOnly }
    if (-not $staged.PSObject.Properties['requests']) { return $staged }
    if (-not $BenchInvoker) {
        . (Join-Path $PSScriptRoot 'bench/run-bench.ps1')
        $BenchInvoker = { param($r) Invoke-RouterBench -Job $r.job -Candidate $r.candidate -Incumbent $r.incumbent -EffortOverride $r.effort -Trigger research }
    }
    $benchResults = @{}
    foreach ($request in $staged.requests) { $benchResults[$request.key] = Invoke-RouterTriggeredComparison -Request $request -Trigger research -BenchInvoker $BenchInvoker }
    $result = Use-RouterOutcomeMutex -StateDir (Get-RouterStateDir) -Action {
        $built = Build-RouterRosterProposalLocked -Now $Now -Notification $notification -BenchResults $benchResults -RosterIdentity $staged.identity
        foreach ($request in $staged.requests) { Save-RouterEffortProposal -Request $request -Bench $benchResults[$request.key] }
        $built
    }
    Send-RouterEffortAlerts
    if ($notification.alert) { Send-RouterAlerts -Alerts @($notification.alert) | Out-Null }
    return $result
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Build-RouterRosterProposal -Now $RouterBuildCliNow
    if ($RouterBuildCliJson) { $result | ConvertTo-Json -Compress -Depth 30 } else { $result }
}
