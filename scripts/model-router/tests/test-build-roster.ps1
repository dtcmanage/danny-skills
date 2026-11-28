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
    # These legacy proposal scenarios intentionally exercise unpinned vendor flips.
    $legacyRoster = (Read-RouterRoster).roster
    if ($legacyRoster.jobs.coder.PSObject.Properties['first_vendor_pin']) {
        $legacyRoster.jobs.coder.PSObject.Properties.Remove('first_vendor_pin')
        $legacyRoster.approved = $true; $legacyRoster.approved_at = [datetimeoffset]::UtcNow.ToString('o')
        Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json') $legacyRoster
    }
    [IO.File]::AppendAllText((Join-Path $script:readDir 'passes.jsonl'),((ConvertTo-Json -InputObject ([pscustomobject]@{pass_id=$Id;categories=$Categories}) -Compress) + "`n"))
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
    $multi[2].results += [pscustomobject]@{model='claude-sonnet-5';score=70;margin=$null}
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6.1-sol' -Readings $multiRead -Prices $prices -Frontier $frontier).result -eq 'claude-sonnet-5') 'equal leads use lower price'
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'claude-sonnet-5' 70 'gpt-6.1-sol' 50),(New-Reading 'c2' 'claude-sonnet-5' 70 'gpt-6.1-sol' 50),(New-Reading 'low-trail' 'claude-sonnet-5' 40 'gpt-6.1-sol' 50 -Effort Low))
    Add-Pass 'p1'; $one=Build-RouterRosterProposal -BenchInvoker $script:fakeBench -Now ([datetime]'2026-09-28T10:00:00')
    Assert-True (-not $one.changed -and $script:alerts.Count -eq 0) 'one pass no proposal or alert'
    $created=@(Get-ChildItem -LiteralPath (Join-Path $temp 'roster-proposals') -File | Select-Object -ExpandProperty Name)
    Assert-True ($created.Count -eq 1 -and $created[0] -ceq 'verdicts.jsonl') 'no-change run writes verdicts only'
    $same=Build-RouterRosterProposal -BenchInvoker $script:fakeBench -Now ([datetime]'2026-09-28T10:00:01')
    $records=@(Get-Content (Join-Path $temp 'roster-proposals/verdicts.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (-not $same.changed -and @($records | Where-Object { $_.job -eq 'coder' -and $_.slot -eq 'first' }).Count -eq 1) 'same pass adds no verdict'
    Add-Pass 'p2'; $two=Build-RouterRosterProposal -BenchInvoker $script:fakeBench -Now ([datetime]'2026-09-28T10:00:02')
    Assert-True ($two.changed -and $script:alerts.Count -eq 1 -and (Test-Path $two.report)) 'two passes propose and alert once'
    Assert-True (@($two.changes | Where-Object { $_.job -eq 'coder' -and $_.slot -eq 'first' -and $_.evidence -match 'skipped 1' }).Count -eq 1) 'proposal caller passes slot floor and change evidence includes skipped count'
    Assert-True (@($two.changes | Where-Object { $_.job -eq 'coder' -and $_.slot -eq 'backup' -and $_.to -eq 'gpt-6.1-sol' }).Count -eq 1) 'vendor flip re-chooses backup from opposite vendor'
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
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'claude-sonnet-5' 70 'gpt-6.1-sol' 50),(New-Reading 'c2' 'claude-sonnet-5' 70 'gpt-6.1-sol' 50))
    Add-Pass 'ne-p1'; $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Save-Category -Category complex-coding -Rows @()
    Add-Pass 'ne-p2'; $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'claude-sonnet-5' 70 'gpt-6.1-sol' 50),(New-Reading 'c2' 'claude-sonnet-5' 70 'gpt-6.1-sol' 50))
    Add-Pass 'ne-p3'; $afterGap=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Assert-True ($afterGap.changed) 'winner then not-enough-evidence then winner changes'
    $scenario=Join-Path $temp 'scenario-switch'; [IO.Directory]::CreateDirectory($scenario) | Out-Null
    $env:DT_MODEL_ROUTER_STATE=$scenario; $script:readDir=Join-Path $scenario 'readings'; [IO.Directory]::CreateDirectory($script:readDir) | Out-Null
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'claude-opus-5-5' 70 'gpt-6.1-sol' 50),(New-Reading 'c2' 'claude-opus-5-5' 70 'gpt-6.1-sol' 50))
    Add-Pass 'switch-p1'; $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'claude-sonnet-5' 70 'gpt-6.1-sol' 50),(New-Reading 'c2' 'claude-sonnet-5' 70 'gpt-6.1-sol' 50))
    Add-Pass 'switch-p2'; $switched=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Assert-True (-not $switched.changed) 'winner A then winner B does not change'
    $scenario=Join-Path $temp 'scenario-coverage'; [IO.Directory]::CreateDirectory($scenario) | Out-Null
    $env:DT_MODEL_ROUTER_STATE=$scenario; $script:readDir=Join-Path $scenario 'readings'; [IO.Directory]::CreateDirectory($script:readDir) | Out-Null
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'claude-opus-5-5' 70 'gpt-6.1-sol' 50),(New-Reading 'c2' 'claude-opus-5-5' 70 'gpt-6.1-sol' 50))
    Add-Pass 'u1'; $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Add-Pass 'u2' @('mechanical'); $uncov=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    $records=@(Get-Content (Join-Path $scenario 'roster-proposals/verdicts.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (-not $uncov.changed -and @($records | Where-Object { $_.pass_id -eq 'u2' -and $_.job -eq 'coder' }).Count -eq 0) 'uncovered pass records no coder verdict or proposal'
    Add-Pass 'u3'; $covered=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Assert-True ($covered.changed -and @($covered.changes | Where-Object { $_.job -eq 'coder' -and $_.slot -eq 'first' -and $_.to -eq 'claude-opus-5-5' }).Count -eq 1) 'two coder-covered passes confirm change despite intervening mechanical pass'
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
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'claude-opus-5-5' 70 'gpt-6.1-sol' 50),(New-Reading 'c2' 'claude-opus-5-5' 70 'gpt-6.1-sol' 50))
    Add-Pass 'flip-p1'; $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    $p2Row=New-Reading 'c1' 'claude-opus-5-5' 70 'gpt-6.1-sol' 50
    $p2Row.results += [pscustomobject]@{model='claude-sonnet-5';score=60;margin=$null}
    Save-Category -Category complex-coding -Rows @($p2Row)
    Add-Pass 'flip-p2'; $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    $p2Records=@(Get-Content (Join-Path $scenario 'roster-proposals/verdicts.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($p2Records | Where-Object { $_.pass_id -eq 'flip-p2' -and $_.job -eq 'coder' -and $_.slot -eq 'backup' -and $_.result -eq 'keep' }).Count -eq 1) 'intervening pass records backup keep'
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'claude-opus-5-5' 80 'gpt-6.1-sol' 50),(New-Reading 'c2' 'claude-opus-5-5' 80 'gpt-6.1-sol' 50),(New-Reading 'c3' 'claude-opus-5-5' 80 'gpt-6.1-sol' 50))
    Add-Pass 'flip-p3'; $flipped=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    $flipProposal=Get-Content -LiteralPath $flipped.proposal -Raw | ConvertFrom-Json -Depth 30
    Assert-True ($flipped.changed -and $flipProposal.jobs.coder.first -eq 'claude-opus-5-5' -and $flipProposal.jobs.coder.backup -eq 'gpt-6.1-sol' -and @($flipProposal.validation_errors).Count -eq 0) 'confirmed vendor flip immediately recomputes valid other-vendor backup'
    Assert-True ($script:alerts[-1].key -eq $coverageAlertKey -and $flipped.changes[0].evidence -ne $coverageEvidence) 'alert key depends on job slot and models rather than evidence'
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
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'claude-sonnet-5' 70 'gpt-6.1-sol' 50),(New-Reading 'c2' 'claude-sonnet-5' 70 'gpt-6.1-sol' 50))
    Add-Pass 'seed-p1'; $null=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Add-Pass 'seed-p2'; $seedTwo=Build-RouterRosterProposal -BenchInvoker $script:fakeBench
    Assert-True ($seedTwo.changed -and (Test-Path -LiteralPath $seedTwo.proposal)) 'approved seed accepts two covered passes without optional pass_id'
    Write-Output "TOTAL PASS: $script:passed"
} finally { Exit-RouterTestCodexHome $fixtureCodexHome;
    $env:DT_MODEL_ROUTER_STATE=$priorState; $env:DT_MODEL_ROUTER_ALERT_TRANSPORT=$priorAlert; $env:DT_MODEL_ROUTER_CODEX_SESSIONS=$priorSessions
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
