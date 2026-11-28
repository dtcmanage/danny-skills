Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../build-roster.ps1')
. (Join-Path $PSScriptRoot 'fixtures/bench-proposal-evidence.ps1')
$script:fakeBench = { param($r) Add-TestBenchEvidence ([pscustomobject]@{raw_gate="pass";gate="pass";better=$r.candidate;tied=$false;shortfall_tasks=0;report_paths=[pscustomobject]@{markdown="synthetic"}}) }
$script:passed = 0
function Assert-True { param([bool]$Condition,[string]$Name) if (-not $Condition) { throw "FAIL: $Name" }; $script:passed++; Write-Output "PASS: $Name" }
function Send-RouterAlerts { param([array]$Alerts) $script:alerts += @($Alerts) }
function New-Reading { param([string]$Benchmark,[string]$A,[double]$AScore,[string]$B,[double]$BScore,[object]$Margin=$null,[bool]$Independent=$true,[string]$Effort='medium')
    return [pscustomobject]@{benchmark=$Benchmark;version='1';harness='h';effort_class=$Effort;independent=$Independent;results=@([pscustomobject]@{model=$A;score=$AScore;margin=$Margin},[pscustomobject]@{model=$B;score=$BScore;margin=$Margin})}
}
function Save-Category { param([string]$Category,[array]$Rows)
    $payload = [pscustomobject]@{category=$Category;sources_checked=@();readings=$Rows}
    [IO.File]::WriteAllText((Join-Path $script:readDir "$Category.json"),($payload | ConvertTo-Json -Depth 20))
}
function Test-EffortFloorComparisons {
    $floorRows = @(
        (New-Reading 'floor-at' 'gpt-6.1-sol' 70 'claude-opus-5-5' 50 -Effort medium),
        (New-Reading 'floor-above' 'gpt-6.1-sol' 70 'claude-opus-5-5' 50 -Effort ' High '),
        (New-Reading 'floor-below' 'gpt-6.1-sol' 40 'claude-opus-5-5' 50 -Effort Low)
    )
    $script:floorData = [pscustomobject]@{readings=$floorRows}
    $unfiltered = Get-RouterProposalComparison -Data $floorData -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5' -FloorEffort $null
    Assert-True ($unfiltered.verdict -eq 'trail' -and $unfiltered.skipped -eq 0 -and $unfiltered.skipped_benchmarks.Count -eq 0) 'null floor preserves all comparisons'
    $filtered = Get-RouterProposalComparison -Data $floorData -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5' -FloorEffort medium
    Assert-True ($filtered.verdict -eq 'win' -and $filtered.leads -eq 2 -and $filtered.trails -eq 0 -and $filtered.comparable -eq 2 -and $filtered.skipped -eq 1 -and $filtered.skipped_benchmarks[0] -ceq 'floor-below') 'Low trail below floor skipped; at floor and trimmed High lead count'
    foreach ($label in @('low','medium','high','xhigh','max','High','Max','xHigh')) {
        $row = New-Reading 'known' 'gpt-6.1-sol' 70 'claude-opus-5-5' 50 -Effort $label
        $known = Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($row)}) -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5' -FloorEffort max
        $expectedSkip = if ($label.ToLowerInvariant() -eq 'max') { 0 } else { 1 }
        Assert-True ($known.skipped -eq $expectedSkip -and $known.comparable -eq (1 - $expectedSkip) -and $known.leads -eq (1 - $expectedSkip)) "known effort ordering $label"
    }
    foreach ($label in @('', 'reasoning', 'default', 'max with default fallback', 'high (Opus); max (Sol)', '32K thinking budget', 'mixed', 'unknown')) {
        $row = New-Reading 'unknown' 'gpt-6.1-sol' 40 'claude-opus-5-5' 50 -Effort $label
        $unknown = Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($row)}) -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5' -FloorEffort max
        Assert-True ($unknown.skipped -eq 0 -and $unknown.comparable -eq 1 -and $unknown.trails -eq 1) "unlabelled or non-exact effort still counts: '$label'"
    }
    $splitEffort = New-Reading 'raw' 'gpt-6.1-sol' 70 'claude-opus-5-5' 50 -Effort high
    $splitEffort.results = @($splitEffort.results[0])
    $otherEffort = New-Reading 'raw' 'gpt-6.1-sol' 70 'claude-opus-5-5' 50 -Effort ' high '
    $otherEffort.results = @($otherEffort.results[1])
    $rawGroups = Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($splitEffort,$otherEffort)}) -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5' -FloorEffort medium
    Assert-True ($rawGroups.comparable -eq 0) 'floor matching does not normalize raw grouping keys'
}
function Add-Pass { param([string]$Id,[string[]]$Categories=@('complex-coding'))
    Initialize-TestBenchEvidence
    [IO.File]::AppendAllText((Join-Path $script:readDir 'passes.jsonl'),((ConvertTo-Json -InputObject ([pscustomobject]@{pass_id=$Id;categories=$Categories}) -Compress) + "`n"))
}
function New-CategoryScenario {
    param([string]$Name)
    $env:DT_MODEL_ROUTER_STATE = Join-Path $temp $Name
    $script:readDir = Join-Path $env:DT_MODEL_ROUTER_STATE 'readings'
    [void][IO.Directory]::CreateDirectory($script:readDir)
    Initialize-TestBenchEvidence
    $fixture = Get-Content (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 30
    $fixture.approved=$true; $fixture.approved_at='2026-11-28T01:00:00Z'
    Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json') $fixture
    return $fixture
}
function Invoke-CategoryFixtureBuild {
    param([string]$Pass, [string[]]$Categories, [switch]$FailBackup)
    Add-Pass $Pass $Categories
    $notification = [pscustomobject]@{alert=$null}
    $staged = Build-RouterRosterProposalLocked -Notification $notification -StageOnly
    $script:lastRequests = @($staged.requests)
    $results = @{}
    foreach ($request in $staged.requests) {
        $bench = & $script:fakeBench $request
        if ($FailBackup -and $request.key -like '*/backup/*') { $bench.gate = 'fail' }
        $results[$request.key] = $bench
    }
    return Build-RouterRosterProposalLocked -Notification $notification -BenchResults $results -RosterIdentity $staged.identity
}
function Save-CategoryWin {
    param([string]$Category, [string]$Winner='gpt-6.2-sol', [string]$Holder='gpt-6.1-sol')
    Save-Category $Category @((New-Reading 'independent-one' $Winner 80 $Holder 50),(New-Reading 'independent-two' $Winner 80 $Holder 50))
}
function Test-CategoryProposals {
    $fixture = New-CategoryScenario 'category-split'
    # An unpinned older roster gains the mandatory pin in its proposal.
    $fixture.jobs.coder.PSObject.Properties.Remove('first_vendor_pin')
    $fixture.jobs.coder | Add-Member category_overrides ([pscustomobject]@{'routine-coding'=[pscustomobject]@{first=[pscustomobject]@{model='gpt-6.2-sol';vendor='codex'}}})
    Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json') $fixture
    $untouched = ConvertTo-Json $fixture.jobs.coder.backup_efforts -Compress
    $writerBefore = ConvertTo-Json $fixture.jobs.writer -Compress -Depth 20
    foreach ($category in @('complex-coding','analysis','long-form-writing')) { Save-CategoryWin $category }
    # A cross-vendor decoy has more leads, but cannot enter the pinned first slot.
    $data = Read-RouterJsonObject (Join-Path $script:readDir 'complex-coding.json')
    foreach ($row in $data.readings) { $row.results += [pscustomobject]@{model='claude-opus-5-5';score=99;margin=1} }
    Write-RouterJsonAtomic (Join-Path $script:readDir 'complex-coding.json') $data
    Save-Category ui-frontend @((New-Reading 'ui-trail' 'gpt-6.2-sol' 40 'gpt-6.1-sol' 50))
    $dir = Join-Path $env:DT_MODEL_ROUTER_STATE 'roster-proposals'; [void][IO.Directory]::CreateDirectory($dir)
    $legacy = [pscustomobject]@{pass_id='split-one';job='coder';slot='first';result='gpt-6.2-sol'}
    [IO.File]::WriteAllText((Join-Path $dir 'verdicts.jsonl'),(($legacy | ConvertTo-Json -Compress)+"`n"))
    $one = Invoke-CategoryFixtureBuild split-one @('complex-coding','analysis','long-form-writing')
    Assert-True (-not $one.changed) 'legacy job-wide record neither deduplicates nor confirms a category win'
    $two = Invoke-CategoryFixtureBuild split-two @('complex-coding','analysis','long-form-writing')
    $proposal = Read-RouterJsonObject $two.proposal
    Assert-True ($proposal.jobs.coder.first -eq 'gpt-6.2-sol' -and $proposal.jobs.coder.category_overrides.'ui-frontend'.first.model -eq 'gpt-6.1-sol') 'primary-won default preserves trailing UI holder as exception'
    Assert-True ($proposal.jobs.coder.first_vendor_pin -eq 'codex' -and @($proposal.changes | Where-Object { $_.job -eq 'coder' -and $_.slot -eq 'first' -and $_.to -like 'claude-*' }).Count -eq 0) 'every proposal adds coder Codex pin and filters cross-vendor default candidates'
    Assert-True (-not $proposal.jobs.coder.category_overrides.PSObject.Properties['routine-coding']) 'exception equal to new default is dropped'
    Assert-True ((ConvertTo-Json $proposal.jobs.coder.backup_efforts -Compress) -ceq $untouched) 'untouched slot efforts byte-identical'
    Assert-True (-not $proposal.over_cap -and (Get-RouterRosterModelCounts $proposal).job_defaults -eq 5 -and (Get-RouterRosterModelCounts $proposal).all_models -eq 6 -and @($proposal.validation_errors).Count -eq 0) 'exceptions can add a sixth model while job-default cap fits'
    Assert-True (-not $proposal.approved -and $proposal.dimension_framework -eq 'provisional') 'category proposal remains unapproved and records framework state'
    $report = Get-Content $two.report -Raw
    Assert-True ($report -match '## Per-category changes' -and $report -match '## Category exceptions' -and $report -match 'Distinct models \(job defaults only\): 5' -and $report -match 'Distinct models \(all models including exceptions\): 6' -and $report -match 'Cap fit:' -and $report -match 'coder alone: fits the six-model cap' -and $report -match 'Skipped below slot effort') 'report includes category evidence, exceptions, both counts and single-job cap fit'
    $records = @(Get-Content (Join-Path $dir 'verdicts.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    $categoryRecords = @($records | Where-Object { $_.PSObject.Properties['category'] })
    Assert-True (@($categoryRecords | Where-Object { $_.job -eq 'coder' -and $_.category -eq 'routine-coding' -and $_.slot -eq 'first' -and $_.holder -eq 'gpt-6.2-sol' }).Count -eq 2 -and @($categoryRecords | Group-Object pass_id,job,slot,category | Where-Object Count -gt 1).Count -eq 0) 'category record shape carries effective holder and deduplicates staging/finalization'

    $fixture = New-CategoryScenario 'category-majority'
    $fixture.jobs.coder | Add-Member category_overrides ([pscustomobject]@{'ui-frontend'=[pscustomobject]@{backup=[pscustomobject]@{model='claude-sonnet-5';vendor='claude'}}})
    Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json') $fixture
    $backupBefore = ConvertTo-Json $fixture.jobs.coder.category_overrides.'ui-frontend'.backup -Compress
    Save-CategoryWin routine-coding; Save-CategoryWin ui-frontend
    $null = Invoke-CategoryFixtureBuild majority-one @('routine-coding','ui-frontend')
    $two = Invoke-CategoryFixtureBuild majority-two @('routine-coding','ui-frontend')
    $proposal = Read-RouterJsonObject $two.proposal
    Assert-True ($proposal.jobs.coder.first -eq 'gpt-6.2-sol' -and $proposal.jobs.coder.category_overrides.'complex-coding'.first.model -eq 'gpt-6.1-sol') 'most categories becomes default when primary did not change'
    Assert-True ((ConvertTo-Json $proposal.jobs.writer -Compress -Depth 20) -ceq $writerBefore) 'untouched job retains byte-identical stored shape'
    Assert-True ((ConvertTo-Json $proposal.jobs.coder.category_overrides.'ui-frontend'.backup -Compress) -ceq $backupBefore -and $proposal.jobs.coder.backup -ceq $fixture.jobs.coder.backup) 'first-slot normalization preserves untouched backup exception byte-for-byte'
    Assert-True (@($script:lastRequests | Where-Object { $_.key -eq 'coder/first/gpt-6.2-sol/gpt-6.1-sol' }).Count -eq 1) 'bench keys deduplicated across categories sharing target and holder'

    $fixture = New-CategoryScenario 'category-tie'
    $fixture.jobs.'deep-thinker' | Add-Member backup_vendor_pin codex
    Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json') $fixture
    foreach ($category in @('code-review','planning','math')) { Save-CategoryWin $category }
    $null = Invoke-CategoryFixtureBuild tie-one @('math')
    $two = Invoke-CategoryFixtureBuild tie-two @('math')
    $proposal = Read-RouterJsonObject $two.proposal
    Assert-True ($proposal.jobs.'deep-thinker'.backup -eq 'gpt-6.1-sol' -and @($proposal.jobs.'deep-thinker'.category_overrides.PSObject.Properties).Count -eq 3) 'three-of-six tie keeps incumbent default and writes category exceptions'
    Assert-True (@($proposal.jobs.'deep-thinker'.category_overrides.PSObject.Properties | Where-Object { $_.Value.backup.vendor -ne 'codex' }).Count -eq 0) 'generic pinned backup filters every category exception'

    $fixture = New-CategoryScenario 'category-failed-backup'
    Save-CategoryWin math 'gpt-6.1-sol' 'claude-opus-5-5'
    $null = Invoke-CategoryFixtureBuild failed-one @('math')
    $two = Invoke-CategoryFixtureBuild failed-two @('math') -FailBackup
    $proposal = Read-RouterJsonObject $two.proposal
    Assert-True (@($proposal.changes).Count -eq 0 -and @($proposal.conflicts).Count -eq 1 -and $proposal.conflicts[0].category -eq 'math' -and $proposal.conflicts[0].evidence -match 'withdrawn') 'failed backup bench withdraws the first category change into Conflicts'
    Assert-True ((ConvertTo-Json $proposal.jobs.'deep-thinker' -Compress -Depth 20) -ceq (ConvertTo-Json $fixture.jobs.'deep-thinker' -Compress -Depth 20) -and @($proposal.validation_errors).Count -eq 0) 'withdrawal restores original shape and valid other-vendor pairs'

    $fixture = New-CategoryScenario 'category-pin-conflict'
    $fixture.jobs.'deep-thinker' | Add-Member backup_vendor_pin codex
    Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json') $fixture
    Save-CategoryWin math 'gpt-6.1-sol' 'claude-opus-5-5'
    $null = Invoke-CategoryFixtureBuild pin-one @('math')
    $two = Invoke-CategoryFixtureBuild pin-two @('math')
    $proposal = Read-RouterJsonObject $two.proposal
    $records = @(Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster-proposals/verdicts.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($proposal.changes).Count -eq 0 -and $proposal.conflicts[0].category -eq 'math' -and @($records | Where-Object { $_.pass_id -eq 'pin-two' -and $_.job -eq 'deep-thinker' -and $_.slot -eq 'backup' -and $_.category -eq 'math' -and $_.result -eq 'keep' }).Count -eq 1) 'backup pin blocks a conflicting vendor flip and still records the category verdict'

    $fixture = New-CategoryScenario 'category-pinned-exception'
    Save-CategoryWin ui-frontend
    $data = Read-RouterJsonObject (Join-Path $script:readDir 'ui-frontend.json')
    foreach ($row in $data.readings) { $row.results += [pscustomobject]@{model='claude-opus-5-5';score=99;margin=1} }
    Write-RouterJsonAtomic (Join-Path $script:readDir 'ui-frontend.json') $data
    $null = Invoke-CategoryFixtureBuild pinned-one @('ui-frontend')
    $two = Invoke-CategoryFixtureBuild pinned-two @('ui-frontend')
    $proposal = Read-RouterJsonObject $two.proposal
    Assert-True ($proposal.jobs.coder.first -eq 'gpt-6.1-sol' -and $proposal.jobs.coder.category_overrides.'ui-frontend'.first.model -eq 'gpt-6.2-sol' -and $proposal.jobs.coder.category_overrides.'ui-frontend'.first.vendor -eq 'codex') 'pinned slot excludes a stronger cross-vendor exception candidate'

    $history = @(
        [pscustomobject]@{pass_id='a';job='coder';slot='first';category='ui-frontend';result='gpt-6.2-sol'},
        [pscustomobject]@{pass_id='b';job='coder';slot='first';category='ui-frontend';result='keep'}
    )
    Assert-True (-not (Get-RouterProposalCategoryTarget $history coder first ui-frontend 'gpt-6.1-sol')) 'holder keep breaks consecutive category wins'
    $history[1].result='gpt-6.1-sol'; $history[0].result='gpt-6.1-sol'
    Assert-True (-not (Get-RouterProposalCategoryTarget $history coder first ui-frontend 'gpt-6.1-sol')) 'two results naming current holder do not fire'
}
$priorState=$env:DT_MODEL_ROUTER_STATE; $priorAlert=$env:DT_MODEL_ROUTER_ALERT_TRANSPORT; $priorSessions=$env:DT_MODEL_ROUTER_CODEX_SESSIONS
$temp=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N')); [IO.Directory]::CreateDirectory($temp) | Out-Null
$env:DT_MODEL_ROUTER_STATE=$temp; $env:DT_MODEL_ROUTER_ALERT_TRANSPORT=Join-Path $temp 'stub-transport.ps1'; $env:DT_MODEL_ROUTER_CODEX_SESSIONS=Join-Path $temp 'empty-sessions'
[IO.File]::WriteAllText($env:DT_MODEL_ROUTER_ALERT_TRANSPORT,'param([string]$Message)')
[IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_CODEX_SESSIONS) | Out-Null
$script:readDir=Join-Path $temp 'readings'; [IO.Directory]::CreateDirectory($script:readDir) | Out-Null
$script:alerts=@()
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixtureCodexHome = Enter-RouterTestCodexHome
try {
    Initialize-TestBenchEvidence
    Test-EffortFloorComparisons
    $a=New-Reading 'b1' 'gpt-6.1-sol' 60 'claude-opus-5-5' 55
    $b=New-Reading 'b2' 'gpt-6.1-sol' 60 'claude-opus-5-5' 55
    $comparison=Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($a,$b)}) -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5'
    Assert-True ($comparison.verdict -eq 'win' -and $comparison.leads -eq 2) 'two independent comparable leads win'
    $b.effort_class='high'
    Assert-True ((Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($a,$b)}) -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5').leads -eq 2) 'separate benchmark with different effort remains comparable within its pair'
    $b.results=@([pscustomobject]@{model='gpt-6.1-sol';score=60;margin=$null})
    Assert-True ((Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($a,$b)}) -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5').verdict -eq 'not-enough-evidence') 'non-comparable pair does not count'
    $split=New-Reading 'split' 'gpt-6.1-sol' 60 'claude-opus-5-5' 55
    $split.results=@($split.results | Where-Object model -eq 'gpt-6.1-sol')
    $other=New-Reading 'split' 'gpt-6.1-sol' 60 'claude-opus-5-5' 55
    $other.version='2'; $other.results=@($other.results | Where-Object model -eq 'claude-opus-5-5')
    Assert-True ((Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($split,$other)}) -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5').comparable -eq 0) 'different versions cannot form a pair'
    $b=New-Reading 'b2' 'gpt-6.1-sol' 60 'claude-opus-5-5' 55 $null $false
    Assert-True ((Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($a,$b)}) -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5').verdict -eq 'not-enough-evidence') 'vendor-only second lead does not count'
    $vendor=New-Reading 'shared' 'gpt-6.1-sol' 60 'claude-opus-5-5' 55 $null $false
    $independent=New-Reading 'shared' 'gpt-6.1-sol' 60 'claude-opus-5-5' 55
    $forward=Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($a,$vendor,$independent)}) -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5'
    $reverse=Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($a,$independent,$vendor)}) -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5'
    Assert-True ($forward.verdict -eq 'win' -and $reverse.verdict -eq 'win' -and $forward.leads -eq $reverse.leads) 'independent duplicate wins in either reading order'
    $tie=New-Reading 'tie' 'gpt-6.1-sol' 60 'claude-opus-5-5' 59 2
    Assert-True ((Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($tie)}) -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5').leads -eq 0) 'margin tie'
    $tie=New-Reading 'tie' 'gpt-6.1-sol' 60 'claude-opus-5-5' 59
    Assert-True ((Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($tie)}) -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5').leads -eq 0) 'one point without margins ties'
    $trail=New-Reading 'b3' 'gpt-6.1-sol' 40 'claude-opus-5-5' 55
    Assert-True ((Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($a,(New-Reading 'b2' 'gpt-6.1-sol' 60 'claude-opus-5-5' 55),$trail)}) -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5').verdict -eq 'trail') 'any trail vetoes category'
    $prices=Get-Content (Join-Path $PSScriptRoot '../../../references/model-router/api-prices.json') -Raw | ConvertFrom-Json
    $frontier=Get-Content (Join-Path $PSScriptRoot '../../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json
    $tierEntry = [pscustomobject]@{first_effort='high';first_efforts=[pscustomobject]@{standard='medium';hard='high'}}
    $jobFloor = Get-RouterProposalJobVerdict -Job coder -Incumbent 'claude-opus-5-5' -Readings @{'complex-coding'=$floorData} -Prices $prices -Frontier $frontier -FloorEffort (Get-RouterTierEffort -Entry $tierEntry -Slot first -Difficulty standard)
    Assert-True ($jobFloor.result -eq 'gpt-6.1-sol' -and $jobFloor.evidence -match 'skipped 1') 'job verdict uses standard floor and includes skipped in evidence'
    foreach ($jobCase in @(
        @{job='deep-thinker';category='analysis';effort='low';expected=0},
        @{job='writer';category='long-form-writing';effort='xhigh';expected=3},
        @{job='illustrator';category='image-generation';effort=$null;expected=0}
    )) {
        $slotEntry = [pscustomobject]@{first_effort=$jobCase.effort}
        $slotFloor = Get-RouterTierEffort -Entry $slotEntry -Slot first -Difficulty standard
        $slotComparison = Get-RouterProposalComparison -Data $floorData -Challenger 'gpt-6.1-sol' -Incumbent 'claude-opus-5-5' -FloorEffort $slotFloor
        $slotVerdict = Get-RouterProposalJobVerdict -Job $jobCase.job -Incumbent 'claude-opus-5-5' -Readings @{$jobCase.category=$floorData} -Prices $prices -Frontier $frontier -FloorEffort $slotFloor
        Assert-True ($slotComparison.skipped -eq $jobCase.expected -and $slotVerdict.evidence -match "skipped $($jobCase.expected)") "$($jobCase.job)/first slot floor"
    }
    $readings=@{ 'complex-coding'=[pscustomobject]@{readings=@((New-Reading 'b1' 'claude-opus-5-5' 60 'gpt-6.1-sol' 55),(New-Reading 'b2' 'claude-opus-5-5' 60 'gpt-6.1-sol' 55))}; 'routine-coding'=[pscustomobject]@{readings=@((New-Reading 'r1' 'claude-opus-5-5' 40 'gpt-6.1-sol' 55))} }
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6.1-sol' -Readings $readings -Prices $prices -Frontier $frontier).result -eq 'keep') 'primary win with other-category trail keeps incumbent'
    $readings.Remove('routine-coding')
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6.1-sol' -Readings $readings -Prices $prices -Frontier $frontier).result -eq 'claude-opus-5-5') 'primary win and no trails qualifies'
    $readings['complex-coding']=[pscustomobject]@{readings=@((New-Reading 'b1' 'gpt-6-luna' 99 'gpt-6.1-sol' 50),(New-Reading 'b2' 'gpt-6-luna' 99 'gpt-6.1-sol' 50))}
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6.1-sol' -Readings $readings -Prices $prices -Frontier $frontier).result -ne 'gpt-6-luna') 'lower same-vendor tier excluded'
    $readings['complex-coding']=[pscustomobject]@{readings=@((New-Reading 'b1' 'gpt-6-astra' 99 'gpt-6.1-sol' 50),(New-Reading 'b2' 'gpt-6-astra' 99 'gpt-6.1-sol' 50))}
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6.1-sol' -Readings $readings -Prices $prices -Frontier $frontier).result -ne 'gpt-6-astra') 'frontier excluded'
    $readings['complex-coding']=[pscustomobject]@{readings=@((New-Reading 'b1' 'gpt-5.6-sol' 99 'gpt-6.1-sol' 50),(New-Reading 'b2' 'gpt-5.6-sol' 99 'gpt-6.1-sol' 50))}
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6.1-sol' -Readings $readings -Prices $prices -Frontier $frontier).result -eq 'gpt-5.6-sol') 'older generation may win on quality'
    $readings=@{mechanical=[pscustomobject]@{readings=@((New-Reading 'm1' 'claude-haiku-4-5-20251001' 55 'gpt-6-luna' 55),(New-Reading 'm2' 'claude-haiku-4-5-20251001' 55 'gpt-6-luna' 55))}}
    Assert-True ((Get-RouterProposalJobVerdict -Job fast -Incumbent 'gpt-6-luna' -Readings $readings -Prices $prices -Frontier $frontier).result -eq 'keep') 'fast floor with higher price keeps incumbent'
    $fast=@{mechanical=[pscustomobject]@{readings=@((New-Reading 'm1' 'gpt-6-luna' 55 'claude-haiku-4-5' 55),(New-Reading 'm2' 'gpt-6-luna' 55 'claude-haiku-4-5' 55))}}
    Assert-True ((Get-RouterProposalJobVerdict -Job fast -Incumbent 'claude-haiku-4-5' -Readings $fast -Prices $prices -Frontier $frontier).result -eq 'gpt-6-luna') 'fast floor then lower price wins'
    Assert-True ((Get-RouterProposalPrice 'claude-haiku-4-5-20251001' $prices) -eq 3) 'dated haiku uses undated price'
    $exactPrices=$prices | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $exactPrices.models | Add-Member -NotePropertyName 'claude-haiku-4-5-20251001' -NotePropertyValue ([pscustomobject]@{prices_usd_per_mtok=[pscustomobject]@{input=2;output=8}})
    Assert-True ((Get-RouterProposalPrice 'claude-haiku-4-5-20251001' $exactPrices) -eq 5) 'exact dated price takes priority over undated fallback'
    $datedFast=@{mechanical=[pscustomobject]@{readings=@((New-Reading 'm1' 'gpt-6-luna' 55 'claude-haiku-4-5-20251001' 55),(New-Reading 'm2' 'gpt-6-luna' 55 'claude-haiku-4-5-20251001' 55))}}
    Assert-True ((Get-RouterProposalJobVerdict -Job fast -Incumbent 'claude-haiku-4-5-20251001' -Readings $datedFast -Prices $prices -Frontier $frontier).result -eq 'gpt-6-luna') 'cheaper challenger compares against dated haiku price'
    $opusFast=@{mechanical=[pscustomobject]@{readings=@((New-Reading 'm1' 'claude-opus-5-5' 55 'claude-haiku-4-5-20251001' 55),(New-Reading 'm2' 'claude-opus-5-5' 55 'claude-haiku-4-5-20251001' 55))}}
    Assert-True ((Get-RouterProposalJobVerdict -Job fast -Incumbent 'claude-haiku-4-5-20251001' -Readings $opusFast -Prices $prices -Frontier $frontier).result -eq 'keep') 'priced opus cannot displace dated haiku on a tie'
    $unpriced=$prices | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $unpriced.models.PSObject.Properties.Remove('claude-haiku-4-5')
    Assert-True ((Get-RouterProposalJobVerdict -Job fast -Incumbent 'claude-haiku-4-5-20251001' -Readings $datedFast -Prices $unpriced -Frontier $frontier).result -eq 'keep') 'unknown incumbent price prevents fast challenger win'
    $priced=$prices | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $priced.models.PSObject.Properties.Remove('gpt-6-luna')
    Assert-True ((Get-RouterProposalJobVerdict -Job fast -Incumbent 'claude-haiku-4-5' -Readings $fast -Prices $priced -Frontier $frontier).result -ne 'gpt-6-luna') 'missing price cannot win'
    $priced=$prices | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $priced.models.'gpt-6-luna'.prices_usd_per_mtok.input=1; $priced.models.'gpt-6-luna'.prices_usd_per_mtok.output=5
    Assert-True ((Get-RouterProposalJobVerdict -Job fast -Incumbent 'claude-haiku-4-5' -Readings $fast -Prices $priced -Frontier $frontier).result -ne 'gpt-6-luna') 'fast price tie keeps incumbent'
    $older=@{mechanical=[pscustomobject]@{readings=@((New-Reading 'm1' 'gpt-5.6-luna' 55 'gpt-6-luna' 55),(New-Reading 'm2' 'gpt-5.6-luna' 55 'gpt-6-luna' 55))}}
    $priced=$prices | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $priced.models.'gpt-5.6-luna'.prices_usd_per_mtok.input=0.01; $priced.models.'gpt-5.6-luna'.prices_usd_per_mtok.output=0.01
    Assert-True ((Get-RouterProposalJobVerdict -Job fast -Incumbent 'gpt-6-luna' -Readings $older -Prices $priced -Frontier $frontier).result -ne 'gpt-5.6-luna') 'older generation cannot win on price'
    $backupReadings=@{'complex-coding'=[pscustomobject]@{readings=@((New-Reading 'b1' 'claude-opus-5-5' 70 'gpt-6.1-sol' 50),(New-Reading 'b2' 'claude-opus-5-5' 70 'gpt-6.1-sol' 50))}}
    foreach ($row in $backupReadings['complex-coding'].readings) { $row.results += [pscustomobject]@{model='gpt-5.6-sol';score=99;margin=$null} }
    $decoyRow = New-Reading 'b3' 'gpt-5.6-sol' 99 'gpt-6.1-sol' 50
    $decoyRow.results += [pscustomobject]@{model='claude-opus-5-5';score=50;margin=$null}
    $backupReadings['complex-coding'].readings = @($backupReadings['complex-coding'].readings) + $decoyRow
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6.1-sol' -Readings $backupReadings -Prices $prices -Frontier $frontier).result -eq 'gpt-5.6-sol') 'same-vendor decoy wins when no vendor filter applies'
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6.1-sol' -Vendor claude -Readings $backupReadings -Prices $prices -Frontier $frontier).result -eq 'claude-opus-5-5') 'backup candidate restricted to opposite vendor'
    $multi=@((New-Reading 'q1' 'claude-opus-5-5' 70 'gpt-6.1-sol' 50),(New-Reading 'q2' 'claude-opus-5-5' 70 'gpt-6.1-sol' 50),(New-Reading 'q3' 'claude-opus-5-5' 70 'gpt-6.1-sol' 50))
    foreach ($row in $multi[0..1]) { $row.results += [pscustomobject]@{model='claude-sonnet-5';score=70;margin=$null} }
    $multiRead=@{'complex-coding'=[pscustomobject]@{readings=$multi}}
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6.1-sol' -Readings $multiRead -Prices $prices -Frontier $frontier).result -eq 'claude-opus-5-5') 'most primary independent leads wins'
    Assert-True ((Get-RouterProposalCategoryVerdict -Job coder -Category complex-coding -Slot first -Holder 'gpt-6.1-sol' -Readings $multiRead -Prices $prices -Frontier $frontier).result -eq 'claude-opus-5-5') 'category challenger ordering prioritizes independent leads'
    $multi[2].results += [pscustomobject]@{model='claude-sonnet-5';score=70;margin=$null}
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6.1-sol' -Readings $multiRead -Prices $prices -Frontier $frontier).result -eq 'claude-sonnet-5') 'equal leads use lower price'
    Assert-True ((Get-RouterProposalCategoryVerdict -Job coder -Category complex-coding -Slot first -Holder 'gpt-6.1-sol' -Readings $multiRead -Prices $prices -Frontier $frontier).result -eq 'claude-sonnet-5') 'category challenger ordering uses lower price for equal leads'
    $samePrice = $prices | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $samePrice.models.'claude-sonnet-5'.prices_usd_per_mtok = $samePrice.models.'claude-opus-5-5'.prices_usd_per_mtok
    Assert-True ((Get-RouterProposalCategoryVerdict -Job coder -Category complex-coding -Slot first -Holder 'gpt-6.1-sol' -Readings $multiRead -Prices $samePrice -Frontier $frontier).result -eq 'claude-opus-5-5') 'category challenger ordering uses model id for equal leads and price'
    foreach ($case in @(@('gpt-6-luna',$false),@('gpt-6-astra',$false),@('gpt-5.6-sol',$true))) {
        $candidateData = @{'complex-coding'=[pscustomobject]@{readings=@((New-Reading 'one' $case[0] 99 'gpt-6.1-sol' 50),(New-Reading 'two' $case[0] 99 'gpt-6.1-sol' 50))}}
        $verdict = Get-RouterProposalCategoryVerdict -Job coder -Category complex-coding -Slot first -Holder 'gpt-6.1-sol' -Readings $candidateData -Prices $prices -Frontier $frontier
        Assert-True (($verdict.result -eq $case[0]) -eq $case[1]) "category lower-tier/frontier exclusion and older quality rule: $($case[0])"
    }
    # Six incumbent defaults; the coder challenger adds the seventh default.
    $capRoster = Read-RouterJsonObject (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json')
    $capRoster.approved = $true; $capRoster.approved_at = '2026-09-28T09:00:00Z'
    $capRoster.jobs.writer.first = 'claude-sonnet-5'
    Write-RouterJsonAtomic (Join-Path $temp 'roster.json') $capRoster
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'gpt-6.2-sol' 70 'gpt-6.1-sol' 50),(New-Reading 'c2' 'gpt-6.2-sol' 70 'gpt-6.1-sol' 50),(New-Reading 'low-trail' 'gpt-6.2-sol' 40 'gpt-6.1-sol' 50 -Effort Low))
    Add-Pass 'p1'; $one=Build-RouterRosterProposal -BenchInvoker $script:fakeBench -Now ([datetime]'2026-09-28T10:00:00')
    Assert-True (-not $one.changed -and $script:alerts.Count -eq 0) 'one pass no proposal or alert'
    $created=@(Get-ChildItem -LiteralPath (Join-Path $temp 'roster-proposals') -File | Select-Object -ExpandProperty Name)
    Assert-True ($created.Count -eq 1 -and $created[0] -ceq 'verdicts.jsonl') 'no-change run writes verdicts only'
    $same=Build-RouterRosterProposal -BenchInvoker $script:fakeBench -Now ([datetime]'2026-09-28T10:00:01')
    $records=@(Get-Content (Join-Path $temp 'roster-proposals/verdicts.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (-not $same.changed -and @($records | Where-Object { $_.job -eq 'coder' -and $_.slot -eq 'first' }).Count -eq 3 -and @($records | Group-Object pass_id,job,slot,category | Where-Object Count -gt 1).Count -eq 0) 'same pass adds no per-category verdict'
    Add-Pass 'p2'; $two=Build-RouterRosterProposal -BenchInvoker $script:fakeBench -Now ([datetime]'2026-09-28T10:00:02')
    Assert-True ($two.changed -and $script:alerts.Count -eq 1 -and (Test-Path $two.report)) 'two passes propose and alert once'
    Assert-True (@($two.changes | Where-Object { $_.job -eq 'coder' -and $_.slot -eq 'first' -and $_.evidence -match 'skipped 1' }).Count -eq 1) 'proposal caller passes slot floor and change evidence includes skipped count'
    Assert-True (@($two.changes | Where-Object { $_.job -eq 'coder' -and $_.slot -eq 'backup' }).Count -eq 0) 'same-vendor change keeps backup'
    $repeat=Build-RouterRosterProposal -BenchInvoker $script:fakeBench -Now ([datetime]'2026-09-28T10:00:02')
    Assert-True (-not $repeat.changed -and $script:alerts.Count -eq 1) 'repeat sends no alert'
    $proposal=Get-Content -LiteralPath $two.proposal -Raw | ConvertFrom-Json -Depth 30
    $expectedEfforts = @{fast='low';coder='medium';'deep-thinker'='medium';writer='medium';illustrator=$null}
    foreach ($job in @(Get-RouterJobs)) { Assert-True ($proposal.jobs.$job.first_effort -ceq $expectedEfforts[$job] -and $proposal.jobs.$job.backup_effort -ceq $expectedEfforts[$job]) "proposal effort $job" }
    Assert-True (@(Test-RouterRoster $proposal | Where-Object { $_ -notlike 'ROSTER_MODEL_CAP:*' }).Count -eq 0) 'proposal schema validates apart from intentional model cap conflict'
    Assert-True ($proposal.over_cap -and @($proposal.conflicts | Where-Object job -eq 'coder').Count -ge 1 -and @($proposal.validation_errors | Where-Object { $_ -like 'ROSTER_MODEL_CAP:*' }).Count -eq 1 -and (@($proposal.validation_errors) -join ';') -ceq (@(Test-RouterRoster $proposal) -join ';')) 'over-cap proposal names conflict and reports every validation error'
    Assert-True ($script:alerts[0].message -match 'choose which of these jobs' -and $script:alerts[0].message -match 'coder' -and $script:alerts[0].message -match 'approve-roster\.ps1 -Approve -Jobs ') 'over-cap alert names jobs and approval command'
    Assert-True ($null -eq $proposal.jobs.illustrator.backup -and $null -eq $proposal.jobs.illustrator.backup_vendor) 'illustrator backup remains null'
    $scenario=Join-Path $temp 'scenario-ne'; [IO.Directory]::CreateDirectory($scenario) | Out-Null
    $env:DT_MODEL_ROUTER_STATE=$scenario; $script:readDir=Join-Path $scenario 'readings'; [IO.Directory]::CreateDirectory($script:readDir) | Out-Null
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'gpt-6.2-sol' 70 'gpt-6.1-sol' 50),(New-Reading 'c2' 'gpt-6.2-sol' 70 'gpt-6.1-sol' 50))
    Add-Pass 'ne-p1'; $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Save-Category -Category complex-coding -Rows @()
    Add-Pass 'ne-p2'; $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'gpt-6.2-sol' 70 'gpt-6.1-sol' 50),(New-Reading 'c2' 'gpt-6.2-sol' 70 'gpt-6.1-sol' 50))
    Add-Pass 'ne-p3'; $afterGap=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Assert-True ($afterGap.changed) 'winner then not-enough-evidence then winner changes'
    $scenario=Join-Path $temp 'scenario-switch'; [IO.Directory]::CreateDirectory($scenario) | Out-Null
    $env:DT_MODEL_ROUTER_STATE=$scenario; $script:readDir=Join-Path $scenario 'readings'; [IO.Directory]::CreateDirectory($script:readDir) | Out-Null
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'gpt-6.2-sol' 70 'gpt-6.1-sol' 50),(New-Reading 'c2' 'gpt-6.2-sol' 70 'gpt-6.1-sol' 50))
    Add-Pass 'switch-p1'; $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'gpt-5.6-sol' 70 'gpt-6.1-sol' 50),(New-Reading 'c2' 'gpt-5.6-sol' 70 'gpt-6.1-sol' 50))
    Add-Pass 'switch-p2'; $switched=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Assert-True (-not $switched.changed) 'winner A then winner B does not change'
    $scenario=Join-Path $temp 'scenario-coverage'; [IO.Directory]::CreateDirectory($scenario) | Out-Null
    $env:DT_MODEL_ROUTER_STATE=$scenario; $script:readDir=Join-Path $scenario 'readings'; [IO.Directory]::CreateDirectory($script:readDir) | Out-Null
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'gpt-6.2-sol' 70 'gpt-6.1-sol' 50),(New-Reading 'c2' 'gpt-6.2-sol' 70 'gpt-6.1-sol' 50))
    Add-Pass 'u1'; $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Add-Pass 'u2' @('mechanical'); $uncov=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    $records=@(Get-Content (Join-Path $scenario 'roster-proposals/verdicts.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (-not $uncov.changed -and @($records | Where-Object { $_.pass_id -eq 'u2' -and $_.job -eq 'coder' }).Count -eq 0) 'uncovered pass records no coder verdict or proposal'
    Add-Pass 'u3'; $covered=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Assert-True ($covered.changed -and @($covered.changes | Where-Object { $_.job -eq 'coder' -and $_.slot -eq 'first' -and $_.to -eq 'gpt-6.2-sol' }).Count -eq 1) 'two coder-covered passes confirm change despite intervening mechanical pass'
    $coverageAlertKey=$script:alerts[-1].key; $coverageEvidence=$covered.changes[0].evidence
    $scenario=Join-Path $temp 'scenario-analysis'; [IO.Directory]::CreateDirectory($scenario) | Out-Null
    $env:DT_MODEL_ROUTER_STATE=$scenario; $script:readDir=Join-Path $scenario 'readings'; [IO.Directory]::CreateDirectory($script:readDir) | Out-Null
    Save-Category -Category analysis -Rows @((New-Reading 'a1' 'gpt-6.1-sol' 70 'claude-opus-5-5' 50),(New-Reading 'a2' 'gpt-6.1-sol' 70 'claude-opus-5-5' 50))
    Add-Pass 'an1' @('analysis'); $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Add-Pass 'an2' @('analysis'); $analysisOnly=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Assert-True ($analysisOnly.changed -and @($analysisOnly.changes | Where-Object { $_.job -eq 'deep-thinker' -and $_.slot -eq 'first' -and $_.to -eq 'gpt-6.1-sol' }).Count -eq 1) 'analysis-only passes count for the deep-thinker job'
    [IO.File]::AppendAllText((Join-Path $script:readDir 'passes.jsonl'),((ConvertTo-Json -InputObject ([pscustomobject]@{pass_id='legacy'}) -Compress) + "`n"))
    $legacy=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Assert-True (-not $legacy.changed) 'pass record without categories covers no job and does not throw'
    $scenario=Join-Path $temp 'scenario-flip'; [IO.Directory]::CreateDirectory($scenario) | Out-Null
    $env:DT_MODEL_ROUTER_STATE=$scenario; $script:readDir=Join-Path $scenario 'readings'; [IO.Directory]::CreateDirectory($script:readDir) | Out-Null
    Save-Category -Category math -Rows @((New-Reading 'c1' 'gpt-6.1-sol' 70 'claude-opus-5-5' 50),(New-Reading 'c2' 'gpt-6.1-sol' 70 'claude-opus-5-5' 50))
    Add-Pass 'flip-p1' @('math'); $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    $p2Row=New-Reading 'c1' 'gpt-6.1-sol' 70 'claude-opus-5-5' 50
    $p2Row.results += [pscustomobject]@{model='gpt-5.6-sol';score=60;margin=$null}
    Save-Category -Category math -Rows @($p2Row)
    Add-Pass 'flip-p2' @('math'); $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    $p2Records=@(Get-Content (Join-Path $scenario 'roster-proposals/verdicts.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($p2Records | Where-Object { $_.pass_id -eq 'flip-p2' -and $_.job -eq 'deep-thinker' -and $_.slot -eq 'backup' -and $_.result -eq 'keep' }).Count -eq 1) 'intervening pass records backup keep'
    Save-Category -Category math -Rows @((New-Reading 'c1' 'gpt-6.1-sol' 80 'claude-opus-5-5' 50),(New-Reading 'c2' 'gpt-6.1-sol' 80 'claude-opus-5-5' 50),(New-Reading 'c3' 'gpt-6.1-sol' 80 'claude-opus-5-5' 50))
    Add-Pass 'flip-p3' @('math'); $flipped=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    $flipProposal=Get-Content -LiteralPath $flipped.proposal -Raw | ConvertFrom-Json -Depth 30
    Assert-True ($flipped.changed -and $flipProposal.jobs.'deep-thinker'.category_overrides.math.first.model -eq 'gpt-6.1-sol' -and $flipProposal.jobs.'deep-thinker'.category_overrides.math.backup.model -eq 'claude-opus-5-5' -and @($flipProposal.validation_errors).Count -eq 0) 'confirmed category vendor flip immediately recomputes valid other-vendor backup override'
    Assert-True ($script:alerts[-1].message -match 'deep-thinker/math') 'alert identifies changed category'
    $scenario=Join-Path $temp 'scenario-dated-fast'; [IO.Directory]::CreateDirectory($scenario) | Out-Null
    $env:DT_MODEL_ROUTER_STATE=$scenario; $script:readDir=Join-Path $scenario 'readings'; [IO.Directory]::CreateDirectory($script:readDir) | Out-Null
    $roster=(Read-RouterRoster).roster
    foreach ($job in @(Get-RouterJobs)) { $roster.jobs.$job.first_effort = Get-RouterJobEffort -Job $job; $roster.jobs.$job.backup_effort = Get-RouterJobEffort -Job $job; foreach ($slot in @('first','backup')) { if ($roster.jobs.$job.PSObject.Properties["${slot}_efforts"]) { $roster.jobs.$job.("${slot}_efforts").standard = $roster.jobs.$job.("${slot}_effort") } } }
    $roster.jobs.fast.first='claude-haiku-4-5-20251001'; $roster.jobs.fast.first_vendor='claude'; $roster.jobs.fast.backup='gpt-6-luna'; $roster.jobs.fast.backup_vendor='codex'; $roster.approved=$true; $roster.approved_at='2026-09-28T09:00:00Z'
    [IO.File]::WriteAllText((Join-Path $scenario 'roster.json'),($roster | ConvertTo-Json -Depth 30))
    Save-Category -Category mechanical -Rows @((New-Reading 'm1' 'claude-opus-5-5' 55 'claude-haiku-4-5-20251001' 55),(New-Reading 'm2' 'claude-opus-5-5' 55 'claude-haiku-4-5-20251001' 55))
    Add-Pass 'fast-p1' @('mechanical'); $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Add-Pass 'fast-p2' @('mechanical'); $fastTwo=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Assert-True (-not $fastTwo.changed) 'priced opus ties dated haiku across two mechanical passes without a proposal'
    $scenario=Join-Path $temp 'scenario-seed'; [IO.Directory]::CreateDirectory($scenario) | Out-Null
    $env:DT_MODEL_ROUTER_STATE=$scenario; $script:readDir=Join-Path $scenario 'readings'; [IO.Directory]::CreateDirectory($script:readDir) | Out-Null
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../approve-roster.ps1') -Seed | Out-Null
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../approve-roster.ps1') -Approve | Out-Null
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'gpt-6.2-sol' 70 'gpt-6.1-sol' 50),(New-Reading 'c2' 'gpt-6.2-sol' 70 'gpt-6.1-sol' 50))
    Add-Pass 'seed-p1'; $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Add-Pass 'seed-p2'; $seedTwo=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Assert-True ($seedTwo.changed -and (Test-Path -LiteralPath $seedTwo.proposal)) 'approved seed accepts two covered passes without optional pass_id'
    # A previous approval retains proposal metadata on the source roster.
    $fixture = New-CategoryScenario 'prior-proposal-envelope'
    foreach ($field in @('changes','over_cap','conflicts','pass_id','dimension_framework','validation_errors')) {
        $fixture | Add-Member -Force -NotePropertyName $field -NotePropertyValue 'stale-envelope'
    }
    Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json') $fixture
    Save-CategoryWin complex-coding
    Add-Pass 'envelope-p1'; $null = Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Add-Pass 'envelope-p2'; $replacement = Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    $envelope = Read-RouterJsonObject $replacement.proposal
    Assert-True ($replacement.changed -and $envelope.pass_id -eq 'envelope-p2' -and $envelope.dimension_framework -eq 'provisional' -and $envelope.over_cap -is [bool] -and @($envelope.validation_errors | Where-Object { $_ -eq 'stale-envelope' }).Count -eq 0 -and @($envelope.changes | Where-Object { $_.to -eq 'gpt-6.2-sol' }).Count -gt 0 -and @($envelope.conflicts | Where-Object { $_ -is [string] }).Count -eq 0) 'prior approval envelope is replaced with current proposal results'
    Test-CategoryProposals
    Write-Output "TOTAL PASS: $script:passed"
} finally { Exit-RouterTestCodexHome $fixtureCodexHome;
    $env:DT_MODEL_ROUTER_STATE=$priorState; $env:DT_MODEL_ROUTER_ALERT_TRANSPORT=$priorAlert; $env:DT_MODEL_ROUTER_CODEX_SESSIONS=$priorSessions
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
