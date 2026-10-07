Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../build-roster.ps1')
. (Join-Path $PSScriptRoot '../bench/run-bench.ps1')
. (Join-Path $PSScriptRoot 'fixtures/bench-proposal-evidence.ps1')
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixtureCodexHome=Enter-RouterTestCodexHome
$priorState=$env:DT_MODEL_ROUTER_STATE
$root=Join-Path ([IO.Path]::GetTempPath()) ('router-quality-'+[guid]::NewGuid().ToString('N'))
$env:DT_MODEL_ROUTER_STATE=$root
[void][IO.Directory]::CreateDirectory($root)
$script:checks=0
function Assert([bool]$Condition,[string]$Message) {if(-not $Condition){throw $Message};$script:checks++}
function Quality($Job,$Tier,$Candidate,$Incumbent,$Value) {
    [pscustomobject]@{job=$Job;tier=$Tier;configurations=[pscustomobject]@{candidate=$Candidate;incumbent=$Incumbent};verdict=$Value;run_id='synthetic-quality'}
}
function DecidedQuality($Record) {
    $verdict=$Record | ConvertTo-Json -Depth 15 | ConvertFrom-Json
    $verdict | Add-Member -NotePropertyName tasks -NotePropertyValue @([pscustomobject]@{candidate_wins=1;incumbent_wins=0;reps=@()})
    return $verdict
}
try {
    $roster=Get-Content (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 30
    $roster.approved=$true;$roster.approved_at='2026-10-05T12:00:00Z'
    Write-RouterJsonAtomic (Join-Path $root 'roster.json') $roster
    Initialize-TestBenchEvidence
    foreach($job in @('coder','deep-thinker','writer')) {
        $entry=$roster.jobs.$job
        $base=[pscustomobject]@{model=$entry.first;effort='medium'}
        $higher=[pscustomobject]@{model=$entry.first;effort='high'}
        $lower=[pscustomobject]@{model=$entry.first;effort='low'}
        $request=[pscustomobject]@{job=$job;candidate=$entry.first;incumbent=$entry.first;effort='medium'}
        $standard=Add-TestBenchEvidence ([pscustomobject]@{job=$job;tier='standard';shadow=$false;raw_gate='pass';effort_down_qualified=$false;effort_up_qualified=$true;incumbent=$base;effort_up=$higher;effort_down=$lower;quality_verdict=$null;effort_up_quality_evidence=(Quality $job standard $higher $base candidate_better);report_paths=[pscustomobject]@{markdown='synthetic.md'}})
        $hard=Add-TestBenchEvidence ([pscustomobject]@{job=$job;tier='hard';shadow=$false;raw_gate='pass';effort_down_qualified=$false;effort_up_qualified=$false;incumbent=$higher;report_paths=[pscustomobject]@{markdown='synthetic-hard.md'}})
        $bench=if($job -eq 'writer'){$standard}else{[pscustomobject]@{tiers=@($standard,$hard);quality_verdict=$null}}
        Save-RouterEffortProposal $request $bench
        $path=Join-Path $root ('effort-proposals/'+$job+$(if($job -ne 'writer'){'-standard'})+'.json')
        $proposal=Read-RouterJsonObject $path
        Assert ($proposal.proposed_effort -ceq 'high' -and $proposal.quality_evidence.verdict -ceq 'candidate_better' -and $proposal.quality_evidence.tier -ceq 'standard') "$job standard quality effort-up must be filed"
        Assert (-not(Test-Path (Join-Path $root ('effort-proposals/'+$job+'-hard.json')))) "$job effort-up must not leak to hard"
        # An insufficient pass-fail gate can still use a decided quality win.
        $standard | Add-Member -NotePropertyName effort_up_quality_verdict -NotePropertyValue (DecidedQuality $standard.effort_up_quality_evidence)
        # IPC verdicts arrive as hashtables, unlike objects read from proposal files.
        $standard.effort_up_quality_verdict=$standard.effort_up_quality_verdict | ConvertTo-Json -Depth 15 | ConvertFrom-Json -AsHashtable
        Remove-Item -LiteralPath $path
        $standard.raw_gate='unknown'; Save-RouterEffortProposal $request $standard
        Assert ((Read-RouterJsonObject $path).proposed_effort -ceq 'high') "$job decided quality establishes effort evidence"
        Remove-Item -LiteralPath $path
        $standard.raw_gate='pass';$standard.effort_up_qualified=$false;$standard.effort_down_qualified=$true
        $standard | Add-Member -NotePropertyName effort_down_quality_evidence -NotePropertyValue (Quality $job standard $lower $base incumbent_better)
        Save-RouterEffortProposal $request $standard
        Assert (-not(Test-Path $path)) "$job quality-losing lower effort must not be filed"
        $standard.effort_down_quality_evidence.verdict='candidate_better'
        Save-RouterEffortProposal $request $standard
        Assert ((Test-Path $path) -eq ($job -ne 'writer')) "$job lower quality-winning side or writer prohibition"
        if(Test-Path $path){Remove-Item -LiteralPath $path}
        $standard.effort_down_quality_evidence=$null
        Save-RouterEffortProposal $request $standard
        Assert ((Test-Path $path) -eq ($job -ne 'writer')) "$job null quality retains prior effort behavior"
        if(Test-Path $path){Remove-Item -LiteralPath $path}
        $standard.raw_gate='unknown'
        $standard.effort_down_quality_evidence=Quality $job standard $lower $base no_difference
        $undecided=DecidedQuality $standard.effort_down_quality_evidence
        $undecided.tasks[0].candidate_wins=0
        $standard | Add-Member -NotePropertyName effort_down_quality_verdict -NotePropertyValue $undecided
        Save-RouterEffortProposal $request $standard
        Assert (-not(Test-Path $path)) "$job undecided quality with unknown raw gate must not be filed"
    }

    # Exercise the actual roster builder with synthetic research history and bench results.
    $readDir=Join-Path $root 'readings';[void][IO.Directory]::CreateDirectory($readDir)
    [IO.File]::WriteAllText((Join-Path $readDir 'passes.jsonl'),'{"pass_id":"quality-pass","categories":["routine-coding"]}'+"`n")
    $dir=Join-Path $root 'roster-proposals';[void][IO.Directory]::CreateDirectory($dir)
    $incumbent=$roster.jobs.coder.first;$target=$roster.jobs.fast.first
    [IO.File]::WriteAllText((Join-Path $dir 'verdicts.jsonl'),(@{pass_id='previous';job='coder';slot='first';result=$target}|ConvertTo-Json -Compress)+"`n"+(@{pass_id='quality-pass';job='coder';slot='first';result=$target}|ConvertTo-Json -Compress)+"`n")
    function Get-RouterProposalJobVerdict {
        param($Job,$Incumbent,$Vendor,$Readings,$Prices,$Frontier)
        [pscustomobject]@{result=$(if(-not $Vendor -and $Job -eq 'coder'){$target}else{'keep'});evidence='Synthetic independent research';tradeoffs=@()}
    }
    foreach($verdict in @('incumbent_better','candidate_better','no_difference','null')) {
        $tiers=@(foreach($tier in @('standard','hard')) {
            $level=Get-RouterTierEffort $roster.jobs.coder first $tier
            $q=Quality coder $tier ([pscustomobject]@{model=$target;effort=$level}) ([pscustomobject]@{model=$incumbent;effort=$level}) $verdict
            if($verdict -eq 'null'){$q=$null}
            [pscustomobject]@{tier=$tier;quality_verdict=$q;quality_evidence=$q}
        })
        $bench=Add-TestBenchEvidence ([pscustomobject]@{raw_gate='pass';gate='pass';tied=$false;better=$target;shortfall_tasks=0;tiers=$tiers;quality_verdict=$null;report_paths=[pscustomobject]@{markdown='synthetic.md'}})
        $built=Build-RouterRosterProposalLocked -Now (Get-Date) -BenchResults @{"coder/first/$target/$incumbent"=$bench} -Notification ([pscustomobject]@{alert=$null})
        Assert ($built.changed -eq ($verdict -ne 'incumbent_better')) "Swap quality rule: $verdict"
        if($built.changed -and $verdict -ne 'null') {
            $change=(Read-RouterJsonObject $built.proposal).changes[0]
            Assert (@($change.quality_evidence).Count -eq 2 -and $change.quality_evidence[1].tier -ceq 'hard') 'Swap must record quality from both measured tiers'
        }
    }

    # The drift swap publisher must also retain the same quality veto and record.
    . (Join-Path $PSScriptRoot '../update-outcomes.ps1')
    $entry=$roster.jobs.coder
    Write-RouterJsonAtomic (Join-Path $root 'drift-marks.json') @([pscustomobject]@{job='coder';model=$entry.first;prior_rate=1;recent_rate=0.5})
    $staged=[pscustomobject]@{identity=(ConvertTo-Json $roster.jobs -Compress -Depth 30)}
    foreach($verdict in @('incumbent_better','candidate_better','no_difference','null')) {
        $quality=Quality coder standard ([pscustomobject]@{model=$entry.backup;effort='medium'}) ([pscustomobject]@{model=$entry.first;effort='medium'}) $verdict
        if($verdict -eq 'null'){$quality=$null}
        $bench=Add-TestBenchEvidence ([pscustomobject]@{raw_gate='pass';gate='pass';tied=$false;better=$entry.backup;shortfall_tasks=0;report_paths=[pscustomobject]@{markdown='synthetic.md'};quality_verdict=$quality;quality_evidence=$quality})
        $path=Complete-RouterDriftBench -Staged $staged -BenchResults @{coder=$bench} -Now (Get-Date)
        Assert ([bool]$path -eq ($verdict -ne 'incumbent_better')) "Drift swap quality rule: $verdict"
        if($path -and $quality){Assert ((Read-RouterJsonObject $path).changes[0].quality_evidence[0].verdict -ceq $verdict) 'Drift swap records quality evidence'}
    }

    # Runner comparison budget: fake vendor readings/dispatchers, no vendor calls.
    $script:spentCalls=0
    $spent=Invoke-RouterBench -Job fast -Candidate $roster.jobs.fast.first -Incumbent $roster.jobs.fast.first -StateDir (Join-Path $root 'spent') -NoAlerts -Limits {param($v) @{blocked=$false;used_percent=$(if($v -eq 'claude' -and $script:spentCalls -ge 3){15.1}else{10})}} -CliInvoker {param($r) $script:spentCalls++;@{status='ok';answer='ok'}} -Outcome {param($r)}
    Assert ($spent.halted -and $spent.spend.model_calls -eq 3 -and $spent.spend.latest.claude.used_percent -eq 15.1) 'Host spend stop must halt between tasks above five points'
    Assert (-not(Test-Path (Join-Path $root 'spent/effort-proposals')) -and -not(Test-Path (Join-Path $root 'spent/tie-proposals'))) 'Halted host comparison must file no proposal'
    $next=Invoke-RouterBench -Job fast -Candidate $roster.jobs.fast.first -Incumbent $roster.jobs.fast.first -StateDir (Join-Path $root 'next') -NoAlerts -Limits {param($v) @{blocked=$false;used_percent=10}} -CliInvoker {param($r) @{status='ok';answer='ok'}} -Outcome {param($r)}
    Assert (-not $next.PSObject.Properties['halted'] -and (Test-Path $next.report_paths.json)) 'Next comparison continues after halted job'

    # Exercise the default reader with both Codex windows; only weekly movement stops spend.
    $sessionDir=Join-Path $env:DT_MODEL_ROUTER_CODEX_SESSIONS '2026/10/05'
    [void][IO.Directory]::CreateDirectory($sessionDir)
    $script:sessionFile=Join-Path $sessionDir 'synthetic.jsonl'
    function Write-WeeklySession([double]$Weekly,[double]$Short) {
        $reset=[datetimeoffset]::UtcNow.AddDays(2).ToUnixTimeSeconds()
        $row=@{timestamp=[datetimeoffset]::UtcNow.ToString('o');type='event_msg';payload=@{type='token_count';rate_limits=@{primary=@{used_percent=$Short;window_minutes=300;resets_at=$reset};secondary=@{used_percent=$Weekly;window_minutes=10080;resets_at=$reset}}}}
        [IO.File]::WriteAllText($script:sessionFile,($row | ConvertTo-Json -Depth 10 -Compress)+"`n")
    }
    function Get-RouterClaudeUsage { [pscustomobject]@{used_percent=10;observed_at_utc=[datetimeoffset]::UtcNow.ToString('o');source='synthetic'} }
    Write-WeeklySession 20 90
    $script:weeklyCalls=0
    $weekly=Invoke-RouterBench -Job fast -Candidate $roster.jobs.fast.first -Incumbent $roster.jobs.fast.first -StateDir (Join-Path $root 'weekly') -NoAlerts -CliInvoker {param($r) $script:weeklyCalls++;if($script:weeklyCalls -ge 3){Write-WeeklySession 25.1 1};@{status='ok';answer='ok'}} -Outcome {param($r)}
    Assert ($weekly.halted -and $weekly.spend.model_calls -eq 3 -and $weekly.halt_reason -match 'codex weekly use moved') 'Weekly Codex movement must halt despite a falling 300-minute window'
    Assert ($weekly.spend.start.codex.usage.used_percent -eq 20 -and $weekly.spend.latest.codex.usage.used_percent -eq 25.1) 'Spend compares the 10080-minute values, not the 300-minute values'
    # A persisted judge catalog without spend keys takes them from the shipped config; its own keys win.
    $shippedConfig=Join-Path $root 'shipped-config.json'
    @{spend_stop_points=7;spend_stop_model_calls=4;spend_reading_stale_hours=2} | ConvertTo-Json | Set-Content -LiteralPath $shippedConfig -Encoding utf8
    $catalog=@{judge_effort='high';spend_stop_points=9}
    Add-BenchSpendDefaults -Config $catalog -ShippedPath $shippedConfig
    Assert ($catalog.spend_stop_points -eq 9 -and $catalog.spend_stop_model_calls -eq 4 -and $catalog.spend_reading_stale_hours -eq 2) 'Missing spend thresholds come from the shipped config; present ones are kept'
    $catalogState=Join-Path $root 'catalog'
    [IO.Directory]::CreateDirectory((Join-Path $catalogState 'bench')) | Out-Null
    $persisted=Get-Content (Join-Path $PSScriptRoot '../bench/bench-config.json') -Raw | ConvertFrom-Json -AsHashtable
    foreach($key in @('spend_stop_points','spend_stop_model_calls','spend_reading_stale_hours')){$persisted.Remove($key)}
    $persisted | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $catalogState 'bench/judge-config.json') -Encoding utf8
    $filled=Invoke-RouterBench -Job fast -Candidate $roster.jobs.fast.first -Incumbent $roster.jobs.fast.first -StateDir $catalogState -NoAlerts -Limits {param($v) @{blocked=$false;used_percent=10}} -CliInvoker {param($r) @{status='ok';answer='ok'}} -Outcome {param($r)}
    Assert ($filled.spend.point_limit -eq 5 -and $filled.spend.call_limit -eq 700 -and $filled.spend.reading_stale_hours -eq 6) 'Runner with a persisted judge catalog reports the shipped spend thresholds'

    $usageFiles=@(Get-ChildItem -LiteralPath $root -Recurse -Filter 'claude-usage.json' | Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).source -ceq 'oauth-usage' })
    Assert ($usageFiles.Count -eq 0) 'Synthetic tests must never write live OAuth usage'
    Write-Output "SUMMARY: $script:checks passed; 0 failed"
} finally {
    $env:DT_MODEL_ROUTER_STATE=$priorState
    Exit-RouterTestCodexHome $fixtureCodexHome
    Remove-CodexTempDirectory -Path $root -ExpectedLeafPrefix 'router-quality-'
}
