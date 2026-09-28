Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../build-roster.ps1')
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
function Add-Pass { param([string]$Id)
    [IO.File]::AppendAllText((Join-Path $script:readDir 'passes.jsonl'),((ConvertTo-Json -InputObject ([pscustomobject]@{pass_id=$Id}) -Compress) + "`n"))
}
$priorState=$env:DT_MODEL_ROUTER_STATE; $priorAlert=$env:DT_MODEL_ROUTER_ALERT_TRANSPORT; $priorSessions=$env:DT_MODEL_ROUTER_CODEX_SESSIONS
$temp=Join-Path $env:TEMP ([guid]::NewGuid().ToString('N')); [IO.Directory]::CreateDirectory($temp) | Out-Null
$env:DT_MODEL_ROUTER_STATE=$temp; $env:DT_MODEL_ROUTER_ALERT_TRANSPORT=Join-Path $temp 'unused-transport.ps1'; $env:DT_MODEL_ROUTER_CODEX_SESSIONS=Join-Path $temp 'empty-sessions'
[IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_CODEX_SESSIONS) | Out-Null
$script:readDir=Join-Path $temp 'readings'; [IO.Directory]::CreateDirectory($script:readDir) | Out-Null
$script:alerts=@()
try {
    $a=New-Reading 'b1' 'gpt-6-sol' 60 'claude-opus-5-5' 55
    $b=New-Reading 'b2' 'gpt-6-sol' 60 'claude-opus-5-5' 55
    $comparison=Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($a,$b)}) -Challenger 'gpt-6-sol' -Incumbent 'claude-opus-5-5'
    Assert-True ($comparison.verdict -eq 'win' -and $comparison.leads -eq 2) 'two independent comparable leads win'
    $b.effort_class='high'
    Assert-True ((Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($a,$b)}) -Challenger 'gpt-6-sol' -Incumbent 'claude-opus-5-5').leads -eq 2) 'separate benchmark with different effort remains comparable within its pair'
    $b.results=@([pscustomobject]@{model='gpt-6-sol';score=60;margin=$null})
    Assert-True ((Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($a,$b)}) -Challenger 'gpt-6-sol' -Incumbent 'claude-opus-5-5').verdict -eq 'not-enough-evidence') 'non-comparable pair does not count'
    $split=New-Reading 'split' 'gpt-6-sol' 60 'claude-opus-5-5' 55
    $split.results=@($split.results | Where-Object model -eq 'gpt-6-sol')
    $other=New-Reading 'split' 'gpt-6-sol' 60 'claude-opus-5-5' 55
    $other.version='2'; $other.results=@($other.results | Where-Object model -eq 'claude-opus-5-5')
    Assert-True ((Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($split,$other)}) -Challenger 'gpt-6-sol' -Incumbent 'claude-opus-5-5').comparable -eq 0) 'different versions cannot form a pair'
    $b=New-Reading 'b2' 'gpt-6-sol' 60 'claude-opus-5-5' 55 $null $false
    Assert-True ((Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($a,$b)}) -Challenger 'gpt-6-sol' -Incumbent 'claude-opus-5-5').verdict -eq 'not-enough-evidence') 'vendor-only second lead does not count'
    $tie=New-Reading 'tie' 'gpt-6-sol' 60 'claude-opus-5-5' 59 2
    Assert-True ((Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($tie)}) -Challenger 'gpt-6-sol' -Incumbent 'claude-opus-5-5').leads -eq 0) 'margin tie'
    $tie=New-Reading 'tie' 'gpt-6-sol' 60 'claude-opus-5-5' 59
    Assert-True ((Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($tie)}) -Challenger 'gpt-6-sol' -Incumbent 'claude-opus-5-5').leads -eq 0) 'one point without margins ties'
    $trail=New-Reading 'b3' 'gpt-6-sol' 40 'claude-opus-5-5' 55
    Assert-True ((Get-RouterProposalComparison -Data ([pscustomobject]@{readings=@($a,(New-Reading 'b2' 'gpt-6-sol' 60 'claude-opus-5-5' 55),$trail)}) -Challenger 'gpt-6-sol' -Incumbent 'claude-opus-5-5').verdict -eq 'trail') 'any trail vetoes category'
    $prices=Get-Content (Join-Path $PSScriptRoot '../../../references/model-router/api-prices.json') -Raw | ConvertFrom-Json
    $frontier=Get-Content (Join-Path $PSScriptRoot '../../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json
    $readings=@{ 'complex-coding'=[pscustomobject]@{readings=@((New-Reading 'b1' 'claude-opus-5-5' 60 'gpt-6-sol' 55),(New-Reading 'b2' 'claude-opus-5-5' 60 'gpt-6-sol' 55))}; 'routine-coding'=[pscustomobject]@{readings=@((New-Reading 'r1' 'claude-opus-5-5' 40 'gpt-6-sol' 55))} }
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6-sol' -Readings $readings -Prices $prices -Frontier $frontier).result -eq 'keep') 'primary win with other-category trail keeps incumbent'
    $readings.Remove('routine-coding')
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6-sol' -Readings $readings -Prices $prices -Frontier $frontier).result -eq 'claude-opus-5-5') 'primary win and no trails qualifies'
    $readings['complex-coding']=[pscustomobject]@{readings=@((New-Reading 'b1' 'gpt-6-luna' 99 'gpt-6-sol' 50),(New-Reading 'b2' 'gpt-6-luna' 99 'gpt-6-sol' 50))}
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6-sol' -Readings $readings -Prices $prices -Frontier $frontier).result -ne 'gpt-6-luna') 'lower same-vendor tier excluded'
    $readings['complex-coding']=[pscustomobject]@{readings=@((New-Reading 'b1' 'gpt-6-astra' 99 'gpt-6-sol' 50),(New-Reading 'b2' 'gpt-6-astra' 99 'gpt-6-sol' 50))}
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6-sol' -Readings $readings -Prices $prices -Frontier $frontier).result -ne 'gpt-6-astra') 'frontier excluded'
    $readings['complex-coding']=[pscustomobject]@{readings=@((New-Reading 'b1' 'gpt-5.6-sol' 99 'gpt-6-sol' 50),(New-Reading 'b2' 'gpt-5.6-sol' 99 'gpt-6-sol' 50))}
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6-sol' -Readings $readings -Prices $prices -Frontier $frontier).result -eq 'gpt-5.6-sol') 'older generation may win on quality'
    $readings=@{mechanical=[pscustomobject]@{readings=@((New-Reading 'm1' 'claude-haiku-4-5-20251001' 55 'gpt-6-luna' 55),(New-Reading 'm2' 'claude-haiku-4-5-20251001' 55 'gpt-6-luna' 55))}}
    Assert-True ((Get-RouterProposalJobVerdict -Job fast -Incumbent 'gpt-6-luna' -Readings $readings -Prices $prices -Frontier $frontier).result -eq 'not-enough-evidence') 'fast floor with higher price keeps incumbent'
    $fast=@{mechanical=[pscustomobject]@{readings=@((New-Reading 'm1' 'gpt-6-luna' 55 'claude-haiku-4-5' 55),(New-Reading 'm2' 'gpt-6-luna' 55 'claude-haiku-4-5' 55))}}
    Assert-True ((Get-RouterProposalJobVerdict -Job fast -Incumbent 'claude-haiku-4-5' -Readings $fast -Prices $prices -Frontier $frontier).result -eq 'gpt-6-luna') 'fast floor then lower price wins'
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
    $backupReadings=@{'complex-coding'=[pscustomobject]@{readings=@((New-Reading 'b1' 'claude-opus-5-5' 70 'gpt-6-sol' 50),(New-Reading 'b2' 'claude-opus-5-5' 70 'gpt-6-sol' 50))}}
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6-sol' -Vendor claude -Readings $backupReadings -Prices $prices -Frontier $frontier).result -eq 'claude-opus-5-5') 'backup candidate restricted to opposite vendor'
    $multi=@((New-Reading 'q1' 'claude-opus-5-5' 70 'gpt-6-sol' 50),(New-Reading 'q2' 'claude-opus-5-5' 70 'gpt-6-sol' 50),(New-Reading 'q3' 'claude-opus-5-5' 70 'gpt-6-sol' 50))
    foreach ($row in $multi[0..1]) { $row.results += [pscustomobject]@{model='claude-sonnet-5';score=70;margin=$null} }
    $multiRead=@{'complex-coding'=[pscustomobject]@{readings=$multi}}
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6-sol' -Readings $multiRead -Prices $prices -Frontier $frontier).result -eq 'claude-opus-5-5') 'most primary independent leads wins'
    $multi[2].results += [pscustomobject]@{model='claude-sonnet-5';score=70;margin=$null}
    Assert-True ((Get-RouterProposalJobVerdict -Job coder -Incumbent 'gpt-6-sol' -Readings $multiRead -Prices $prices -Frontier $frontier).result -eq 'claude-sonnet-5') 'equal leads use lower price'
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'claude-sonnet-5' 70 'gpt-6-sol' 50),(New-Reading 'c2' 'claude-sonnet-5' 70 'gpt-6-sol' 50))
    Add-Pass 'p1'; $one=Build-RouterRosterProposal -Now ([datetime]'2026-09-28T10:00:00')
    Assert-True (-not $one.changed -and $script:alerts.Count -eq 0) 'one pass no proposal or alert'
    $created=@(Get-ChildItem -LiteralPath (Join-Path $temp 'roster-proposals') -File | Select-Object -ExpandProperty Name)
    Assert-True ($created.Count -eq 1 -and $created[0] -ceq 'verdicts.jsonl') 'no-change run writes verdicts only'
    $same=Build-RouterRosterProposal -Now ([datetime]'2026-09-28T10:00:01')
    $records=@(Get-Content (Join-Path $temp 'roster-proposals/verdicts.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (-not $same.changed -and @($records | Where-Object { $_.job -eq 'coder' -and $_.slot -eq 'first' }).Count -eq 1) 'same pass adds no verdict'
    Add-Pass 'p2'; $two=Build-RouterRosterProposal -Now ([datetime]'2026-09-28T10:00:02')
    Assert-True ($two.changed -and $script:alerts.Count -eq 1 -and (Test-Path $two.report)) 'two passes propose and alert once'
    Assert-True (@($two.changes | Where-Object { $_.job -eq 'coder' -and $_.slot -eq 'backup' -and $_.to -eq 'gpt-6-sol' }).Count -eq 1) 'vendor flip re-chooses backup from opposite vendor'
    $repeat=Build-RouterRosterProposal -Now ([datetime]'2026-09-28T10:00:02')
    Assert-True (-not $repeat.changed -and $script:alerts.Count -eq 1) 'repeat sends no alert'
    $proposal=Get-Content -LiteralPath $two.proposal -Raw | ConvertFrom-Json -Depth 30
    Assert-True ($proposal.over_cap -and @($proposal.conflicts | Where-Object job -eq 'coder').Count -ge 1 -and @((Test-RouterRoster $proposal)).Count -gt 0) 'over-cap proposal names conflict and fails roster validation'
    Assert-True ($null -eq $proposal.jobs.illustrator.backup -and $null -eq $proposal.jobs.illustrator.backup_vendor) 'illustrator backup remains null'
    $scenario=Join-Path $temp 'scenario-ne'; [IO.Directory]::CreateDirectory($scenario) | Out-Null
    $env:DT_MODEL_ROUTER_STATE=$scenario; $script:readDir=Join-Path $scenario 'readings'; [IO.Directory]::CreateDirectory($script:readDir) | Out-Null
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'claude-sonnet-5' 70 'gpt-6-sol' 50),(New-Reading 'c2' 'claude-sonnet-5' 70 'gpt-6-sol' 50))
    Add-Pass 'ne-p1'; $null=Build-RouterRosterProposal
    Save-Category -Category complex-coding -Rows @()
    Add-Pass 'ne-p2'; $null=Build-RouterRosterProposal
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'claude-sonnet-5' 70 'gpt-6-sol' 50),(New-Reading 'c2' 'claude-sonnet-5' 70 'gpt-6-sol' 50))
    Add-Pass 'ne-p3'; $afterGap=Build-RouterRosterProposal
    Assert-True ($afterGap.changed) 'winner then not-enough-evidence then winner changes'
    $scenario=Join-Path $temp 'scenario-switch'; [IO.Directory]::CreateDirectory($scenario) | Out-Null
    $env:DT_MODEL_ROUTER_STATE=$scenario; $script:readDir=Join-Path $scenario 'readings'; [IO.Directory]::CreateDirectory($script:readDir) | Out-Null
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'claude-opus-5-5' 70 'gpt-6-sol' 50),(New-Reading 'c2' 'claude-opus-5-5' 70 'gpt-6-sol' 50))
    Add-Pass 'switch-p1'; $null=Build-RouterRosterProposal
    Save-Category -Category complex-coding -Rows @((New-Reading 'c1' 'claude-sonnet-5' 70 'gpt-6-sol' 50),(New-Reading 'c2' 'claude-sonnet-5' 70 'gpt-6-sol' 50))
    Add-Pass 'switch-p2'; $switched=Build-RouterRosterProposal
    Assert-True (-not $switched.changed) 'winner A then winner B does not change'
    Write-Output "TOTAL PASS: $script:passed"
} finally {
    $env:DT_MODEL_ROUTER_STATE=$priorState; $env:DT_MODEL_ROUTER_ALERT_TRANSPORT=$priorAlert; $env:DT_MODEL_ROUTER_CODEX_SESSIONS=$priorSessions
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
