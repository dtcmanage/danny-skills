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
    return ($Frontier.codex_models -contains $Model -or @($Frontier.claude_patterns | Where-Object { $Model -like $_ }).Count -gt 0)
}

function Get-RouterProposalComparison {
    param([object]$Data, [string]$Challenger, [string]$Incumbent)
    $groups = @{}
    foreach ($reading in @($Data.readings)) {
        $key = @($reading.benchmark,$reading.version,$reading.harness,$reading.effort_class) -join "`n"
        if (-not $groups.ContainsKey($key)) { $groups[$key] = [pscustomobject]@{ results=@{}; benchmark=$reading.benchmark } }
        foreach ($result in @($reading.results)) {
            $model = [string]$result.model
            if (-not $groups[$key].results.ContainsKey($model) -or $reading.independent -or -not $groups[$key].results[$model].independent) {
                $groups[$key].results[$model] = [pscustomobject]@{ value=$result; independent=[bool]$reading.independent }
            }
        }
    }
    $leads = 0; $trails = 0; $comparable = 0; $names = @()
    foreach ($key in @($groups.Keys | Sort-Object)) {
        $g = $groups[$key]
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
    return [pscustomobject]@{ verdict=$verdict; leads=$leads; trails=$trails; comparable=$comparable; benchmarks=@($names) }
}

function Get-RouterProposalJobVerdict {
    param([string]$Job, [string]$Incumbent, [string]$Vendor, [hashtable]$Readings, [object]$Prices, [object]$Frontier)
    $primary = @{ fast='mechanical'; coder='complex-coding'; 'deep-thinker'='analysis'; writer='long-form-writing'; illustrator='image-generation' }[$Job]
    $categories = @{ fast=@('mechanical'); coder=@('routine-coding','complex-coding','ui-frontend'); 'deep-thinker'=@('code-review','planning','deep-research','math','analysis'); writer=@('long-form-writing'); illustrator=@('image-generation') }[$Job]
    $models = @($categories | ForEach-Object { if ($Readings.ContainsKey($_)) { $Readings[$_].readings | ForEach-Object { $_.results | ForEach-Object model } } } | Where-Object { $_ -and $_ -ne $Incumbent } | Sort-Object -Unique)
    $qualified = @(); $tradeoffs = @(); $hasFloorClearer = $false
    foreach ($model in $models) {
        if ($Vendor -and (Get-RouterProposalVendor $model) -ne $Vendor) { continue }
        if (Test-RouterProposalFrontier $model $Frontier) { continue }
        $comparisons = @{}; $won = @(); $trailed = @()
        foreach ($category in $categories) {
            if (-not $Readings.ContainsKey($category)) { continue }
            $comparison = Get-RouterProposalComparison -Data $Readings[$category] -Challenger $model -Incumbent $Incumbent
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
        $evidence = "$model`: primary $($p.verdict) ($($p.leads) independent leads, $($p.comparable) comparable); won [$($won -join ', ')]; trailed [$($trailed -join ', ')]"
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

function Build-RouterRosterProposal {
    param([datetime]$Now = (Get-Date))
    $state = Get-RouterStateDir
    $current = (Read-RouterRoster).roster
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
    $proposed.generated_at = $Now.ToString('o'); $proposed.approved = $false; $proposed.approved_at = $null
    $changes = @(); $tradeoffs = @()
    foreach ($job in @(Get-RouterJobs)) {
        if ($coveredJobs -notcontains $job) { continue }
        foreach ($slot in @('first','backup')) {
            if ($job -eq 'illustrator' -and $slot -eq 'backup') { continue }
            $entry = $proposed.jobs.$job
            $currentEntry = $current.jobs.$job
            $proposedVendor = Get-RouterProposalVendor $entry.first
            $flipped = $slot -eq 'backup' -and $proposedVendor -ne $currentEntry.first_vendor
            $incumbent = if ($flipped) { $currentEntry.first } else { $currentEntry.$slot }
            $vendor = if ($slot -eq 'backup') { if ($proposedVendor -eq 'codex') {'claude'} else {'codex'} } else { $null }
            $verdict = Get-RouterProposalJobVerdict -Job $job -Incumbent $incumbent -Vendor $vendor -Readings $readings -Prices $prices -Frontier $frontier
            if ($flipped -and $verdict.result -in @('keep','not-enough-evidence')) {
                $verdict.result = $incumbent
                $verdict.evidence = "Other-vendor incumbent after first-choice flip: $incumbent. $($verdict.evidence)"
            }
            if (-not @($history | Where-Object { $_.pass_id -eq $passId -and $_.job -eq $job -and $_.slot -eq $slot }).Count) {
                $record = [pscustomobject]@{pass_id=$passId;job=$job;slot=$slot;result=$verdict.result}
                [IO.File]::AppendAllText($verdictPath,((ConvertTo-Json -InputObject $record -Compress) + "`n"),[Text.UTF8Encoding]::new($false))
                $history += $record
            }
            $eligible = @($history | Where-Object { $_.job -eq $job -and $_.slot -eq $slot -and $_.result -ne 'not-enough-evidence' } | Select-Object -Last 2)
            $target = if ($eligible.Count -eq 2 -and $eligible[0].result -eq $eligible[1].result -and $eligible[1].result -notin @('keep',$currentEntry.$slot)) { [string]$eligible[1].result } else { $null }
            if ($flipped) { $target = if ($verdict.result -notin @('keep','not-enough-evidence')) { [string]$verdict.result } else { [string]$incumbent } }
            if ($target -and $target -ne $currentEntry.$slot -and -not (Test-RouterProposalFrontier $target $frontier)) {
                $entry.$slot = $target; $entry."${slot}_vendor" = Get-RouterProposalVendor $target
                $changes += [pscustomobject]@{job=$job;slot=$slot;from=$currentEntry.$slot;to=$target;evidence=$verdict.evidence}
            } elseif ($verdict.result -eq 'keep') { $tradeoffs += "$job/$slot`: $($verdict.evidence)" }
        }
    }
    if (-not $changes.Count) { return [pscustomobject]@{changed=$false;pass_id=$passId;changes=@();proposal=$null;report=$null} }
    $latest = Read-RouterJsonObject -Path (Join-Path $dir 'latest.json')
    if ($latest -and $latest.PSObject.Properties['proposal']) {
        $previous = Read-RouterJsonObject -Path ([string]$latest.proposal)
        if ($previous -and $previous.PSObject.Properties['pass_id'] -and $previous.pass_id -eq $passId -and (ConvertTo-Json -InputObject @($previous.changes) -Compress -Depth 20) -ceq (ConvertTo-Json -InputObject @($changes) -Compress -Depth 20)) {
            return [pscustomobject]@{changed=$false;pass_id=$passId;changes=@();proposal=$null;report=$null}
        }
    }
    $ids = @($proposed.jobs.PSObject.Properties | ForEach-Object { @($_.Value.first,$_.Value.backup) } | Where-Object { $_ } | Sort-Object -Unique)
    $overCap = $ids.Count -gt 5
    $priorIds = @($current.jobs.PSObject.Properties | ForEach-Object { @($_.Value.first,$_.Value.backup) } | Where-Object { $_ } | Sort-Object -Unique)
    $conflicts = @(if ($overCap) { $changes | Where-Object { $priorIds -notcontains $_.to } | ForEach-Object { [pscustomobject]@{job=$_.job;slot=$_.slot;from=$_.from;to=$_.to;evidence=$_.evidence} } })
    $proposed | Add-Member -NotePropertyName changes -NotePropertyValue @($changes)
    $proposed | Add-Member -NotePropertyName over_cap -NotePropertyValue $overCap
    $proposed | Add-Member -NotePropertyName conflicts -NotePropertyValue $conflicts
    $proposed | Add-Member -NotePropertyName pass_id -NotePropertyValue $passId
    $errors = @(Test-RouterRoster $proposed)
    $proposed | Add-Member -NotePropertyName validation_errors -NotePropertyValue $errors
    if ($errors.Count -and -not $overCap) { throw "PROPOSAL_INVALID: $($errors -join '; ')" }
    $stem = $Now.ToString('yyyy-MM-ddTHHmmss'); $jsonPath = Join-Path $dir ($stem + '.json'); $reportPath = Join-Path $dir ($stem + '.md')
    [IO.File]::WriteAllText($jsonPath,($proposed | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    $lines = @('# Model list proposal','','| Job | Current | Proposed | Evidence summary | Backup |','| --- | --- | --- | --- | --- |')
    foreach ($job in @(Get-RouterJobs)) {
        $evidence = @($changes | Where-Object job -eq $job | ForEach-Object evidence) -join '; '
        $lines += "| $job | $($current.jobs.$job.first) | $($proposed.jobs.$job.first) | $evidence | $($proposed.jobs.$job.backup) |"
    }
    $lines += @('','## Conflicts','')
    if ($conflicts.Count) { $lines += @($conflicts | ForEach-Object { "- $($_.job)/$($_.slot): $($_.from) -> $($_.to). $($_.evidence)" }) } else { $lines += 'None.' }
    $lines += @('','## Tradeoffs for keep jobs','')
    if ($tradeoffs.Count) { $lines += @($tradeoffs | ForEach-Object { "- $_" }) } else { $lines += 'None.' }
    [IO.File]::WriteAllText($reportPath,(($lines -join "`n") + "`n"),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $dir 'latest.json'),(ConvertTo-Json -InputObject ([pscustomobject]@{proposal=$jsonPath;report=$reportPath}) -Compress),[Text.UTF8Encoding]::new($false))
    $alertChanges = @($changes | ForEach-Object { [pscustomobject]@{job=$_.job;slot=$_.slot;from=$_.from;to=$_.to} })
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $alertChanges -Compress -Depth 20)))).ToLowerInvariant()
    $first = $changes[0]
    $alertMessage = "Model list change proposed: $($first.job) $($first.from) -> $($first.to). Report: $reportPath"
    if ($overCap) {
        $jobs = @($conflicts | ForEach-Object job | Sort-Object -Unique) -join ','
        $alertMessage += " Over the 5-model cap; choose which of these jobs to change: $jobs. Approve your pick with approve-router-table.ps1 -Roster -Approve -Jobs <job,...> (the full list exceeds the cap)."
    }
    Send-RouterAlerts -Alerts @([pscustomobject]@{key="roster-proposal:$hash";message=$alertMessage}) | Out-Null
    return [pscustomobject]@{changed=$true;pass_id=$passId;changes=@($changes);proposal=$jsonPath;report=$reportPath;over_cap=$overCap;conflicts=$conflicts;validation_errors=$errors}
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Build-RouterRosterProposal -Now $RouterBuildCliNow
    if ($RouterBuildCliJson) { $result | ConvertTo-Json -Compress -Depth 30 } else { $result }
}
