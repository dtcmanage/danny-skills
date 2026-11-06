Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../build-roster.ps1')
. (Join-Path $PSScriptRoot '../update-outcomes.ps1')
. (Join-Path $PSScriptRoot '../check-new-models.ps1')
. (Join-Path $PSScriptRoot '../run-router-cadence.ps1')
. (Join-Path $PSScriptRoot '../bench/run-bench.ps1')
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
. (Join-Path $PSScriptRoot 'fixtures/bench-proposal-evidence.ps1')
$fixture=Enter-RouterTestCodexHome
$prior=$env:DT_MODEL_ROUTER_STATE
$priorTransport=$env:DT_MODEL_ROUTER_ALERT_TRANSPORT
$root=Join-Path $fixture.root 'repair'
$script:checks=0
function Check($ok,$name) { if(-not $ok){throw "FAIL $name"}; $script:checks++ }
function New-ScoredQuality([int]$Rounds = 3) {
    $reps=@(for($i=0;$i -lt $Rounds;$i++) { @{judges=@(@{reply='a'},@{reply='no_difference'})} })
    return @{verdict='no_difference';tasks=@(@{reps=$reps})}
}
$script:sent=@{}
function Send-RouterAlerts { param($Alerts)
    foreach($alert in $Alerts){
        $lock=Join-Path (Get-RouterStateDir) 'outcomes.mutex'
        $probe=[IO.File]::Open($lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $probe.Dispose()
        $script:sent[$alert.key]=$alert.message
    }
}
try {
    $a=Join-Path $root 'a'; $b=Join-Path $root 'b'
    [void][IO.Directory]::CreateDirectory($a); [void][IO.Directory]::CreateDirectory($b)
    $env:DT_MODEL_ROUTER_STATE=$b
    $roster=(Read-RouterRoster).roster; $roster.approved=$true; $roster.approved_at='2026-10-02T12:00:00Z'
    $roster.jobs.fast.first='gpt-6.1-sol'; $roster.jobs.fast.first_effort='medium'
    Write-RouterJsonAtomic (Join-Path $a 'roster.json') $roster; Write-RouterJsonAtomic (Join-Path $b 'roster.json') $roster
    $before=(Get-FileHash (Join-Path $b 'roster.json')).Hash
    # Approve only this disposable bank before the positive proposal-scope test.
    & python -B -c 'import sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);from review import Review;r=Review(Path(sys.argv[1])/"tasks",Path(sys.argv[2])/"bench");a=r.refresh();[r.choose(i,"approved",a["task_bank_sha256"]) for i in r.ids]' (Join-Path $PSScriptRoot '../bench') $a
    if($LASTEXITCODE -ne 0){throw 'Fixture golden approval failed'}
    $fake={param($r) $id=if($r.prompt.Contains('fee table')){'mechanical-extract-table'}else{'mechanical-rename-sweep'}; @{status='ok';answer=(Get-Content (Join-Path $PSScriptRoot "../bench/tasks/$id/known-good.txt") -Raw);usage=@{input=100;output=10};resolved_model=$r.model}}
    $result=Invoke-RouterBench -Job fast -Candidate gpt-6-luna -Incumbent gpt-6.1-sol -StateDir $a -CliInvoker $fake -Limits {param($v) @{blocked=$false}} -NoAlerts
    Check ($result.effort_down_qualified -and (Test-Path (Join-Path $a 'effort-proposals/fast.json'))) 'F1 explicit proposal'
    Check (@(Get-ChildItem $b -File -Recurse).Count -eq 1 -and (Get-FileHash (Join-Path $b 'roster.json')).Hash -eq $before) 'F1 environment unchanged'
    Check (Test-Path (Join-Path $a 'outcomes.mutex')) 'F1 explicit lock'
    Remove-Item (Join-Path $a 'effort-proposals/fast.json')
    $script:changed=$false
    $stale={param($r) if(-not $script:changed){$live=Read-RouterJsonObject (Join-Path $a 'roster.json');$live.jobs.fast.first='gpt-6-luna';Write-RouterJsonAtomic (Join-Path $a 'roster.json') $live;$script:changed=$true}; & $fake $r}
    $null=Invoke-RouterBench -Job fast -Candidate gpt-6-luna -Incumbent gpt-6.1-sol -StateDir $a -CliInvoker $stale -Limits {param($v) @{blocked=$false}} -NoAlerts
    Check (-not(Test-Path (Join-Path $a 'effort-proposals/fast.json'))) 'F1 stale dispatch'
    $env:DT_MODEL_ROUTER_STATE=$a; Write-RouterJsonAtomic (Join-Path $a 'roster.json') $roster
    foreach($job in @('fast','coder','deep-thinker','writer')) {
        foreach($raw in @('fail','unknown')) {
            $mark=[pscustomobject]@{job=$job;model=$roster.jobs.$job.first;prior_rate=1;recent_rate=0}
            Write-RouterJsonAtomic (Join-Path $a 'drift-marks.json') @($mark)
            $bench=[pscustomobject]@{raw_gate=$raw;gate='advisory';better=$roster.jobs.$job.backup;tied=$false;shortfall_tasks=3;report_paths=@{markdown='synthetic'}}
            Initialize-TestBenchEvidence
            $bench=Add-TestBenchEvidence $bench
            $staged=[pscustomobject]@{identity=(ConvertTo-Json $roster.jobs -Compress -Depth 30)}
            $path=Complete-RouterDriftBench $staged @{$job=$bench} (Get-Date)
            Check ([bool]$path -eq ($job -eq 'writer' -and $raw -eq 'fail')) "F2 drift $job $raw"
        }
    }
    Update-RouterBenchJudges @([pscustomobject]@{lane='claude';id='claude-opus-9-9'},[pscustomobject]@{lane='codex';id='gpt-5-astra'})
    $config=Read-RouterJsonObject (Join-Path $a 'bench/judge-config.json')
    Check ($config.judges.claude -eq 'claude-fable-5-1' -and $config.judges.codex -eq 'gpt-6-astra') 'F3 retain frontier'
    Update-RouterBenchJudges @([pscustomobject]@{lane='claude';id='claude-fable-6-2'},[pscustomobject]@{lane='codex';id='gpt-7-astra'})
    $config=Read-RouterJsonObject (Join-Path $a 'bench/judge-config.json')
    Check ($config.judges.claude -eq 'claude-fable-6-2' -and $config.judges.codex -eq 'gpt-7-astra') 'F3 upgrade'
    Update-RouterBenchJudges @()
    Check ((Read-RouterJsonObject (Join-Path $a 'bench/judge-config.json')).judges.claude -eq 'claude-fable-6-2') 'F3 incomplete'
    Check (Test-RouterFrontierModel gpt-9.2-astra) 'F4 future family'
    Check (-not(Test-RouterFrontierModel gpt-9-sol)) 'F4 ordinary eligible'
    $request=[pscustomobject]@{job='coder';candidate='candidate';incumbent=$roster.jobs.coder.first;effort='medium'}
    $unknown={param($r) [pscustomobject]@{gate='unknown';raw_gate='unknown';task_bank_sha256='bank1';judge_pair=@{claude='fable';codex='astra'}}}
    $null=Invoke-RouterTriggeredComparison $request research $unknown
    $null=Invoke-RouterTriggeredComparison $request research $unknown
    Check ($script:sent.Count -eq 1) 'F6 repeat identity'
    $null=Invoke-RouterTriggeredComparison $request research {param($r) [pscustomobject]@{gate='unknown';raw_gate='unknown';task_bank_sha256='bank2';judge_pair=@{claude='fable';codex='astra'}}}
    $null=Invoke-RouterTriggeredComparison $request research {param($r) [pscustomobject]@{gate='unknown';raw_gate='unknown';task_bank_sha256='bank2';judge_pair=@{claude='new-fable';codex='astra'}}}
    Check ($script:sent.Count -eq 3) 'F6 bank and pair'
    $null=Invoke-RouterTriggeredComparison $request research {throw 'synthetic exception'}
    $config.judges.codex='gpt-8-astra'; Write-RouterJsonAtomic (Join-Path $a 'bench/judge-config.json') $config
    $null=Invoke-RouterTriggeredComparison $request research {throw 'synthetic exception'}
    Check ($script:sent.Count -eq 5) 'F6 exception refresh'
    $config.judge_effort='medium'; Write-RouterJsonAtomic (Join-Path $a 'bench/judge-config.json') $config
    $null=Invoke-RouterTriggeredComparison $request research {throw 'synthetic exception'}
    Check ($script:sent.Count -eq 6) 'E1 exception identity includes judge effort'
    $triggerRow=Get-Content (Join-Path $a 'bench/trigger-log.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
    Check ($triggerRow.judge_effort -eq 'medium') 'E1 trigger evidence records judge effort'
    # A completed comparison is never re-run for the same job, models, effort, bank and judges.
    $script:passRuns=0
    $passing={param($r) $script:passRuns++; [pscustomobject]@{gate='pass';raw_gate='pass';task_bank_sha256='bank3';judge_pair=@{claude='fable';codex='astra'};judge_effort='medium'}}
    $first=Invoke-RouterTriggeredComparison $request research $passing
    $rowsBefore=@(Get-Content (Join-Path $a 'bench/trigger-log.jsonl') | ConvertFrom-Json)
    $second=Invoke-RouterTriggeredComparison $request research $passing
    Check ($script:passRuns -eq 1 -and $first.gate -eq 'pass' -and $second.gate -eq 'pass' -and $second.PSObject.Properties['duplicate_of'] -and $second.duplicate_of -eq $rowsBefore[-1].at) 'G1 completed comparison runs once and the repeat reuses the saved result'
    $rows=@(Get-Content (Join-Path $a 'bench/trigger-log.jsonl') | ConvertFrom-Json)
    Check ($rows[-1].gate -eq 'duplicate' -and $rows[-1].requested_identity -eq $rows[-2].requested_identity -and $script:sent.Count -eq 6) 'G1 duplicate logged without alert'
    $null=Invoke-RouterTriggeredComparison ([pscustomobject]@{job='coder';candidate='candidate';incumbent=$roster.jobs.coder.first;effort='low'}) research $passing
    $config.judge_effort='high'; Write-RouterJsonAtomic (Join-Path $a 'bench/judge-config.json') $config
    $null=Invoke-RouterTriggeredComparison $request research $passing
    Check ($script:passRuns -eq 3) 'G1 new effort or judge setup runs again'
    # A judge outage is retried after recovery, then completed evidence dedupes.
    $recoveryRequest=[pscustomobject]@{job='coder';candidate='recovery-candidate';incumbent=$roster.jobs.coder.first;effort='medium'}
    $script:recoveryRuns=0
    $recovering={param($r)
        $script:recoveryRuns++
        if($script:recoveryRuns -eq 1){ return [pscustomobject]@{gate='unknown';raw_gate='unknown';quality_verdict=@{verdict='unknown'}} }
        return [pscustomobject]@{gate='pass';raw_gate='pass';quality_verdict=(New-ScoredQuality)}
    }
    $outage=Invoke-RouterTriggeredComparison $recoveryRequest research $recovering -SendAlerts $false
    $corrected=Invoke-RouterTriggeredComparison $recoveryRequest research $recovering -SendAlerts $false
    Check ($outage.gate -eq 'unknown' -and $corrected.gate -eq 'pass' -and $script:recoveryRuns -eq 2 -and -not $corrected.PSObject.Properties['duplicate_of']) 'G1 corrected run executes after judge outage'
    $repeat=Invoke-RouterTriggeredComparison $recoveryRequest research $recovering -SendAlerts $false
    Check ($repeat.PSObject.Properties['duplicate_of'] -and $script:recoveryRuns -eq 2) 'G1 corrected evidence dedupes'
    # Simulate an old gate=pass cache whose judges never returned scored results.
    $cache=@(Get-ChildItem (Join-Path $a 'bench/triggered') -Filter '*.json' | Where-Object {
        (Read-RouterJsonObject $_.FullName).PSObject.Properties['quality_verdict']
    })
    Check ($cache.Count -eq 1) 'G1 isolated recovery cache'
    Write-RouterJsonAtomic $cache[0].FullName ([pscustomobject]@{gate='pass';raw_gate='pass';quality_verdict=@{verdict='unknown'}})
    $afterOldOutage=Invoke-RouterTriggeredComparison $recoveryRequest research $recovering -SendAlerts $false
    Check ($script:recoveryRuns -eq 3 -and $afterOldOutage.gate -eq 'pass' -and -not $afterOldOutage.PSObject.Properties['duplicate_of']) 'G1 old pass with unknown quality cannot suppress recovery'
    # Reproduce the real pre-repair no_difference outage cache, per tier. Seed the
    # saved result directly because the repaired writer must refuse to save it.
    foreach ($nested in @($false,$true)) {
        foreach ($rounds in @(0,2,3)) {
            $quality=New-ScoredQuality $rounds
            $tier=[pscustomobject]@{gate='pass';quality_verdict=$quality}
            $saved=if($nested){[pscustomobject]@{gate='pass';tiers=@($tier)}}else{$tier}
            Write-RouterJsonAtomic $cache[0].FullName $saved
            $runsBefore=$script:recoveryRuns
            $replayed=Invoke-RouterTriggeredComparison $recoveryRequest research $recovering -SendAlerts $false
            if($rounds -lt 3) {
                Check ($script:recoveryRuns -eq $runsBefore+1 -and -not $replayed.PSObject.Properties['duplicate_of']) "G1 no_difference nested=$nested scored=$rounds cannot dedupe"
            } else {
                Check ($script:recoveryRuns -eq $runsBefore -and $replayed.PSObject.Properties['duplicate_of']) "G1 scored evidence nested=$nested dedupes at minimum 3"
            }
        }
        foreach ($badJudges in @(
            @(@{reply='a'}),
            @(@{reply='a'},@{reply='error'}),
            @(@{reply='a'},@{reply='b'},@{reply='no_difference'})
        )) {
            $quality=@{verdict='no_difference';tasks=@(@{reps=@(@{judges=$badJudges},@{judges=$badJudges},@{judges=$badJudges})})}
            $tier=[pscustomobject]@{gate='pass';quality_verdict=$quality}
            $saved=if($nested){[pscustomobject]@{gate='pass';tiers=@($tier)}}else{$tier}
            Write-RouterJsonAtomic $cache[0].FullName $saved
            $runsBefore=$script:recoveryRuns
            $replayed=Invoke-RouterTriggeredComparison $recoveryRequest research $recovering -SendAlerts $false
            Check ($script:recoveryRuns -eq $runsBefore+1 -and -not $replayed.PSObject.Properties['duplicate_of']) "G1 only two scored replies count nested=$nested"
        }
    }
    # Independent fixture roots exercise publication and the real delivered-log path.
    $priorTransport=$env:DT_MODEL_ROUTER_ALERT_TRANSPORT
    $transport=Join-Path $root 'transport.ps1'
    [IO.File]::WriteAllText($transport,@'
param($request)
if ($request.kind -eq 'secret') { return 'fixture-token' }
if ($request.uri -like '*/oauth2/applications/@me') { return [pscustomobject]@{owner=[pscustomobject]@{id='fixture-owner'}} }
if ($request.uri -like '*/users/@me/channels') { return [pscustomobject]@{id='fixture-dm'} }
if ($request.uri -like '*/channels/fixture-dm/messages') {
    $probe=[IO.File]::Open((Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.mutex'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $probe.Dispose()
    [IO.File]::AppendAllText((Join-Path $env:DT_MODEL_ROUTER_STATE 'transport.jsonl'),$request.body+"`n")
    return [pscustomobject]@{id='fixture-message'}
}
throw 'Unexpected fake transport request'
'@)
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT=$transport
    . (Join-Path $PSScriptRoot '../send-router-alert.ps1')
    function Fresh-State($name) {
        $env:DT_MODEL_ROUTER_STATE=Join-Path $root $name
        [void][IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_STATE)
        Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json') $roster
        Initialize-TestBenchEvidence
    }
    function Delivered($pattern) {
        $path=Join-Path $env:DT_MODEL_ROUTER_STATE 'alert-log.jsonl'
        if(Test-Path $path){ Get-Content $path | ForEach-Object {$_ | ConvertFrom-Json} | Where-Object {$_.event -eq 'delivered' -and $_.key -like $pattern} }
    }
    foreach($job in @('fast','coder','deep-thinker','writer')) {
        foreach($raw in @('fail','unknown','pass')) {
            Fresh-State "research-$job-$raw"
            $live=Read-RouterJsonObject (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json')
            $candidate=if($job -eq 'fast'){'gpt-6-luna'}elseif($job -eq 'coder'){'claude-opus-5-5'}else{'gpt-6.1-sol'}
            if($job -eq 'fast'){
                $live.jobs.fast.first='claude-haiku-4-5-20251001';$live.jobs.fast.first_vendor='claude'
                $live.jobs.fast.backup='gpt-6.1-sol';$live.jobs.fast.backup_vendor='codex'
            }
            Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json') $live
            $category=@{fast='mechanical';coder='complex-coding';'deep-thinker'='analysis';writer='long-form-writing'}[$job]
            $dir=Join-Path $env:DT_MODEL_ROUTER_STATE 'readings';[void][IO.Directory]::CreateDirectory($dir)
            $rows=foreach($id in @('independent-one','independent-two')){
                [pscustomobject]@{benchmark=$id;version='1';harness='fixture';effort_class='medium';independent=$true;results=@([pscustomobject]@{model=$candidate;score=99;margin=$null},[pscustomobject]@{model=$live.jobs.$job.first;score=50;margin=$null})}
            }
            Write-RouterJsonAtomic (Join-Path $dir "$category.json") ([pscustomobject]@{readings=@($rows)})
            $script:researchRaw=$raw
            $adapter={param($r) Add-TestBenchEvidence ([pscustomobject]@{raw_gate=$script:researchRaw;gate='advisory';better=$r.candidate;tied=$false;shortfall_tasks=3;report_paths=@{markdown='fixture-research-report'}}) }
            foreach($pass in @('one','two')) {
                [IO.File]::AppendAllText((Join-Path $dir 'passes.jsonl'),((@{pass_id=$pass;categories=@($category)}|ConvertTo-Json -Compress)+"`n"))
                $built=Build-RouterRosterProposal -BenchInvoker $adapter
            }
            $expected=$raw -eq 'pass' -or ($job -eq 'writer' -and $raw -eq 'fail')
            Check ([bool]$built.changed -eq $expected -and [bool](Test-Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster-proposals/latest.json')) -eq $expected) "F2 research publication $job $raw"
            if($expected){ Check ((Get-Content $built.report -Raw) -match 'shortfall 3 task.*fixture-research-report') "F2 advisory evidence $job $raw" }
        }
    }
    Fresh-State 'catalog'
    $script:RouterDiagnosisHttp={param($Uri) 'fixture-connected'}
    $script:RouterDiagnosisDns={param($ApiHost) $true}
    $script:RouterModelCheckFetcher={param($vendor) if($vendor.id -eq 'openai'){'gpt-6-sol'}else{'claude-sonnet-4-5'}}
    $script:requests=[Collections.Generic.List[object]]::new()
    $qualified={param($r)
        $script:requests.Add($r)
        $down=@{medium='low';high='medium'}[[string]$r.effort]
        Add-TestBenchEvidence ([pscustomobject]@{shadow=$false;raw_gate='pass';gate='advisory';better=$r.incumbent;tied=$false;shortfall_tasks=0;effort_down_qualified=($r.job -eq 'coder');incumbent=@{passed=3};effort_down=@{model=$r.incumbent;effort=$down;passed=3};report_paths=@{markdown='fixture-effort-report'}})
    }
    $now=[datetime]'2026-10-02T12:00:00Z'
    $null=Invoke-RouterModelCheck -Force -Now $now -BenchInvoker $qualified
    $script:RouterModelCheckFetcher={param($vendor) if($vendor.id -eq 'openai'){'gpt-6-sol';'gpt-9-astra';'gpt-9-sol'}else{'claude-sonnet-4-5';'claude-fable-9-2'}}
    $checked=Invoke-RouterModelCheck -Force -Now $now.AddHours(13) -BenchInvoker $qualified
    Check ($checked.errors.Count -eq 0 -and $checked.alerts -notcontains 'bench-trigger-error') 'F4 fake listing completes'
    Check (@($script:requests | Where-Object candidate -in @('gpt-9-astra','claude-fable-9-2')).Count -eq 0) 'F4 no automatic frontier dispatch'
    Check ($script:requests.Count -eq 0) 'F4 catalog check dispatches no comparisons'
    foreach($model in @('gpt-9-astra','claude-fable-9-2','gpt-9-sol')){ $null=Invoke-RouterNewModelComparisons -Model $model -Categories @(Get-RouterCadenceCategories -Model $model) -BenchInvoker $qualified }
    Check (@($script:requests | Where-Object candidate -in @('gpt-9-astra','claude-fable-9-2')).Count -eq 0) 'F4 no automatic frontier comparison from the release pass'
    Check (@($script:requests | Where-Object candidate -eq 'gpt-9-sol').Count -eq 4) 'F4 ordinary model release pass compares all text jobs'
    $queue=@(Read-RouterJsonArray (Join-Path $env:DT_MODEL_ROUTER_STATE 'research-queue.json'))
    foreach($model in @('gpt-9-astra','claude-fable-9-2','gpt-9-sol')){
        Check (@($queue | Where-Object {$_.model -eq $model -and $_.trigger -eq 'release'}).Count -eq 1 -and @($queue | Where-Object {$_.model -eq $model -and $_.trigger -eq 'confirmation' -and [datetime]$_.due_at -eq $now.AddHours(13).AddDays(7)}).Count -eq 1) "F4 queues retained $model"
    }
    $judges=(Read-RouterJsonObject (Join-Path $env:DT_MODEL_ROUTER_STATE 'bench/judge-config.json')).judges
    Check ($judges.codex -eq 'gpt-9-astra' -and $judges.claude -eq 'claude-fable-9-2') 'F4 listing refreshes judges'
    Check (@(Delivered 'effort-swap:*').Count -eq 1 -and (Read-RouterJsonObject (Join-Path $env:DT_MODEL_ROUTER_STATE 'effort-proposals/coder-standard.json')).status -eq 'pending') 'F5 new-model immediate proposal delivery'
    Send-RouterEffortAlerts
    $null=Invoke-RouterNewModelComparisons -Model 'gpt-9-sol' -Categories @(Get-RouterCadenceCategories -Model 'gpt-9-sol') -BenchInvoker $qualified
    Check (@(Delivered 'effort-swap:*').Count -eq 1 -and @($script:requests | Where-Object candidate -eq 'gpt-9-sol').Count -eq 4) 'F5 new-model delivered once and repeated release pass re-runs nothing'
    Check ((Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'transport.jsonl') -Raw) -match 'coder.*medium -> low.*fixture-effort-report') 'F5 new-model contents and unlocked delivery'
    Fresh-State 'drift-alert'
    $sources=Join-Path $root 'empty-sources.json';[IO.File]::WriteAllText($sources,'[]')
    $outcomes=foreach($period in @('prior','recent')) { foreach($i in 1..10){
        @{key="$period-$i";run_id='fixture';repo='fixture';chunk_id="$period-$i";source='fixture';attempt=1;failure_category='quality';model=$roster.jobs.coder.first;category='complex-coding';lane=$roster.jobs.coder.first_vendor;at=$now.AddDays($(if($period -eq 'prior'){-60}else{-1})).ToString('o');pass=($period -eq 'prior')} | ConvertTo-Json -Compress
    }}
    [IO.File]::WriteAllLines((Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl'),[string[]]$outcomes)
    $null=Update-RouterOutcomes -Now $now -SourcesPath $sources -BenchInvoker $qualified
    Check ((Test-Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'effort-proposals/coder-standard.json')) -and @(Delivered 'effort-swap:*').Count -eq 0) 'F5 drift respects alerts disabled'
    Remove-Item -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'drift-marks.json')
    Remove-Item -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'effort-proposals/coder-standard.json')
    $null=Update-RouterOutcomes -Now $now -SourcesPath $sources -BenchInvoker $qualified -SendAlerts
    $driftRows=@(Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'bench/trigger-log.jsonl') | ConvertFrom-Json)
    Check ($driftRows[-1].gate -eq 'duplicate' -and (Test-Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'effort-proposals/coder-standard.json')) -and @(Delivered 'effort-swap:*').Count -eq 1) 'F5 drift repeat reuses the saved comparison and still files and delivers the proposal'
    $null=Update-RouterOutcomes -Now $now -SourcesPath $sources -BenchInvoker $qualified -SendAlerts
    Check (@(Delivered 'effort-swap:*').Count -eq 1) 'F5 drift delivered once'
    Check ((Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'transport.jsonl') -Raw) -match 'coder.*medium -> low.*fixture-effort-report') 'F5 drift contents and unlocked delivery'
    Fresh-State 'unknown-delivery'
    $script:bank='bank-one';$script:pair=@{claude='fable-one';codex='astra-one'}
    $unknownDelivery={param($r) [pscustomobject]@{raw_gate='unknown';gate='unknown';task_bank_sha256=$script:bank;judge_pair=$script:pair}}
    $request=[pscustomobject]@{job='coder';candidate='fixture-candidate';incumbent=$roster.jobs.coder.first;effort='medium'}
    $null=Invoke-RouterTriggeredComparison $request research $unknownDelivery
    $null=Invoke-RouterTriggeredComparison $request research $unknownDelivery
    Check (@(Delivered 'bench-unknown:*').Count -eq 1) 'F6 delivered same evidence once'
    $script:bank='bank-two';$null=Invoke-RouterTriggeredComparison $request research $unknownDelivery
    Check (@(Delivered 'bench-unknown:*').Count -eq 2) 'F6 delivered changed bank'
    $script:pair.codex='astra-two';$null=Invoke-RouterTriggeredComparison $request research $unknownDelivery
    Check (@(Delivered 'bench-unknown:*').Count -eq 3) 'F6 delivered changed judges'
    $null=Invoke-RouterTriggeredComparison $request research {throw 'fixture exception text'}
    $null=Invoke-RouterTriggeredComparison $request research {throw 'fixture exception text'}
    Check (@(Delivered 'bench-unknown:*').Count -eq 4) 'F6 exception delivered once'
    Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'bench/judge-config.json') @{judges=@{claude='claude-fable-9-2';codex='gpt-9-astra'}}
    $null=Invoke-RouterTriggeredComparison $request research {throw 'fixture exception text'}
    Check (@(Delivered 'bench-unknown:*').Count -eq 5) 'F6 exception refreshed identity delivered'
    Check (@(Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'transport.jsonl')).Count -eq 5) 'F6 real fake-transport sends equal delivered identities'
    Check ((Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'alert-log.jsonl') -Raw) -notmatch 'fixture-token|fixture exception text') 'F6 no transport secret or exception text persisted'
    # Fresh CLI process: no preloaded helper can conceal the no-drift dependency.
    Fresh-State 'empty-cli'
    $sources=Join-Path $root 'empty-sources.json'; [IO.File]::WriteAllText($sources,'[]')
    $cli=Join-Path $PSScriptRoot '../update-outcomes.ps1'
    $raw=& pwsh -NoProfile -File $cli -SourcesPath $sources -Json
    $exitCode=$LASTEXITCODE
    $emptyResult=($raw -join "`n") | ConvertFrom-Json
    Check ($exitCode -eq 0 -and $emptyResult.total_records -eq 0) 'R1 fresh empty CLI returns valid JSON'
    $basis=New-RouterBenchProposalEvidence coder (Add-TestBenchEvidence ([pscustomobject]@{}))
    Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'effort-proposals/coder-standard.json') @{status='pending';job='coder';model=$roster.jobs.coder.first;current_effort='medium';proposed_effort='low';report='empty-drift-report';bench_evidence=$basis}
    $null=& pwsh -NoProfile -File $cli -SourcesPath $sources -Json
    Check ($LASTEXITCODE -eq 0 -and @(Delivered 'effort-swap:*').Count -eq 1) 'R1 pending effort delivered with no drift outside lock'
    $null=& pwsh -NoProfile -File $cli -SourcesPath $sources -Json
    Check ($LASTEXITCODE -eq 0 -and @(Delivered 'effort-swap:*').Count -eq 1) 'R1 no-drift effort delivery deduplicated'
    Fresh-State 'unknown-opt-in'
    & {
        function Update-RouterOutcomesLocked {
            param($Now,$SourcesPath)
            $live=(Read-RouterRoster).roster
            [pscustomobject]@{requests=@([pscustomobject]@{job='coder';candidate=$live.jobs.coder.backup;incumbent=$live.jobs.coder.first;effort=$live.jobs.coder.first_effort});identity=(ConvertTo-Json $live.jobs -Compress -Depth 30);alerts=@();proposal=$null}
        }
        $adapter={param($r) [pscustomobject]@{raw_gate='unknown';gate='unknown';effort_down_qualified=$false}}
        $null=Update-RouterOutcomes -BenchInvoker $adapter
        Check (@(Delivered 'bench-unknown:*').Count -eq 0 -and -not(Test-Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'transport.jsonl'))) 'R2 omitted opt-in makes no delivery'
        $null=Update-RouterOutcomes -BenchInvoker $adapter -SendAlerts
        $null=Update-RouterOutcomes -BenchInvoker $adapter -SendAlerts
        Check (@(Delivered 'bench-unknown:*').Count -eq 1) 'R2 enabled UNKNOWN delivers once outside lock'
    }
    # Exercise the host's structural_alert callback with a real engine and a fake CLI.
    # The host imports Send-RouterAlert locally; observe the disposable transport it really calls.
    & {
        $protocolFailure={param($r) @{status='unknown';failure_category='protocol';detail='malformed delta'}}
        foreach($quiet in @($false,$true)) {
            Fresh-State "structural-alert-$quiet"
            $halt=Invoke-RouterBench -Job fast -Candidate gpt-6-luna -Incumbent gpt-6.1-sol -StateDir $env:DT_MODEL_ROUTER_STATE -CliInvoker $protocolFailure -Limits {param($v) @{blocked=$false}} -NoAlerts:$quiet
            Check ($halt.halted -and $halt.gate -eq 'unknown' -and $halt.status -eq 'infrastructure_failure') "structural host halt quiet=$quiet"
            Check (@($halt.outcomes | Where-Object attempt -ne 1).Count -eq 0) "structural host does not retry quiet=$quiet"
            $signals=@(Delivered 'bench-structural:*')
            $sink=Join-Path $env:DT_MODEL_ROUTER_STATE 'transport.jsonl'
            if($quiet) { Check ($signals.Count -eq 0 -and -not(Test-Path $sink)) 'structural host NoAlerts suppresses delivery' }
            else {
                Check ($signals.Count -eq 1 -and @(Get-Content $sink).Count -eq 1) 'structural host delivers once for the signature'
                Check ($signals[0].key -eq 'bench-structural:protocol:boundary' -and $signals[0].message -match 'Quality is unknown' -and (Get-Content $sink -Raw) -match 'Quality is unknown') 'structural host alert key and message'
            }
        }
    }
    # Same details through the Python authority and the host's Codex delegate.
    foreach($detail in @('Codex transport failed','Codex stdin timeout','Codex transport timeout','not JSON','Empty dispatch response','Codex CLI missing','Codex stdin message limit','Parallel call returned nothing.','actual model or effort mismatch','ERROR: Usage limit reached','account authentication changed or malformed','codex error: unauthorized http 401')) {
        $expected=(@{status='unknown';detail=$detail}|ConvertTo-Json -Compress) | & python (Join-Path $script:BenchRoot 'codex_appserver.py') --classify-failure | ConvertFrom-Json
        Check ((Get-BenchFailureCategory $detail -Vendor codex) -eq $expected.failure_category) "host/Python failure agreement: $detail"
    }
    Check ((Get-BenchFailureCategory 'Codex transport failed' -Vendor claude) -eq 'transport') 'Claude retains historical failure classifier'

    # Real Invoke-RouterBench -> Invoke-BenchDispatchCall -> Invoke-BenchCli.
    # Fake transport CLI outputs exercise failures outside the app-server parser.
    $realBenchRoot=$script:BenchRoot
    $benchRootVariable=Get-Variable BenchRoot -Scope Script
    $fakeHost=Join-Path $fixture.root 'fake transport CLI'; [void][IO.Directory]::CreateDirectory($fakeHost)
    foreach($case in @('exit3','crash','non-json','empty','missing','prompt-limit','dispatch-raises','invalid-payload','parallel-empty','turn-detail')) {
        Fresh-State "wrapper-$case"
        $counter=@{calls=0}
        $stub=switch($case) {
            'exit3' { 'import sys; sys.stdin.readline(); sys.exit(3)' }
            'crash' { 'import ctypes,sys; sys.stdin.readline(); ctypes.windll.kernel32.ExitProcess(0xC0000142)' }
            'non-json' { 'import sys; sys.stdin.readline(); print("not JSON")' }
            'turn-detail' { 'import sys,json; sys.stdin.readline(); print(json.dumps({"status":"unknown","failure_category":"protocol","detail":"single-inference raw evidence missing or ambiguous"}))' }
            default { 'import sys; sys.stdin.readline()' }
        }
        [IO.File]::WriteAllText((Join-Path $fakeHost 'codex_appserver.py'),$stub)
        $fakeCli={param($r)
            $counter.calls++
            if($case -eq 'dispatch-raises'){throw 'raising dispatch PRIVATE'}
            if($case -eq 'invalid-payload'){return @{status='ok';answer=3}}
            if($case -eq 'parallel-empty'){throw 'Parallel call returned nothing.'}
            $copy=@{}; foreach($key in $r.Keys){$copy[$key]=$r[$key]}
            if($case -eq 'prompt-limit'){$copy.prompt='x'*1048577}
            try {
                $benchRootVariable.Value=$fakeHost
                $resolver=if($case -eq 'missing'){{ (Get-Command 'rdr-nonexistent-cli-88' -ErrorAction Stop).Source }}else{{ @('fake-codex-cli') }}
                Invoke-BenchCli -Request $copy -CodexCommandResolver $resolver
            } finally { $benchRootVariable.Value=$realBenchRoot }
        }.GetNewClosure()
        $halt=Invoke-RouterBench -Job fast -Candidate gpt-6-luna -Incumbent gpt-6.1-sol -StateDir $env:DT_MODEL_ROUTER_STATE -CliInvoker $fakeCli -Limits {param($v) @{blocked=$false}} -NoAlerts
        Check ($halt.halted -and $halt.gate -eq 'unknown' -and $counter.calls -eq 6) "real host $case halts at six calls (actual $($counter.calls))"
        Check (@($halt.outcomes | Where-Object attempt -ne 1).Count -eq 0) "real host $case never retries"
        Check (@($halt.calls | Where-Object vendor -eq codex).Count -eq 6) "real host $case ledger agrees"
        if($case -eq 'turn-detail') { Check ($halt.spend.structural_failures.'protocol:turn/completed' -eq 6) 'real host trims newline before matching turn/completed' }
    }
    foreach($authDetail in @('account authentication changed or malformed','codex error: unauthorized http 401')) {
        Fresh-State ('auth-'+[guid]::NewGuid().ToString('N'))
        $authCli={param($r) @{status='unknown';detail=$authDetail}}.GetNewClosure()
        $halt=Invoke-RouterBench -Job fast -Candidate gpt-6-luna -Incumbent gpt-6.1-sol -StateDir $env:DT_MODEL_ROUTER_STATE -CliInvoker $authCli -Limits {param($v) @{blocked=$false}}
        Check ($halt.halted -and @($halt.calls).Count -eq 6) 'real host auth halts at six'
        Check (@($halt.calls | Where-Object { $_.failure_category -ne 'auth' -or $_.detail -notmatch 're-authenticate' }).Count -eq 0) 'real host auth detail is actionable'
        $signals=@(Delivered 'bench-structural:auth:*')
        Check ($signals.Count -eq 1 -and $signals[0].message -match 're-authenticate' -and $signals[0].message -notmatch 'repair the transport') 'real host auth alert names re-authentication'
    }
    # Also enter the real pooled-call catch, rather than only supplying its text.
    & {
        Fresh-State 'real-parallel-empty'
        $schemaFake=Join-Path $fixture.root 'schema-only.py'
        [IO.File]::WriteAllText($schemaFake,'import sys,json; from pathlib import Path; assert sys.argv[1:3]==["app-server","generate-json-schema"]; (Path(sys.argv[4])/"ServerNotification.json").write_text(json.dumps({"properties":{"method":{"enum":["warning"]}}}))')
        function Get-CodexProcessSpec { param($CodexPath) @{file=(Get-Command python).Source;prefix_args=@($schemaFake)} }
        $savedParallel=$script:BenchParallelCall
        $script:BenchParallelCall={param($BenchScript,$RequestJson,$TimeoutMs) return}
        try {
            $config=Get-Content (Join-Path $realBenchRoot 'bench-config.json') -Raw | ConvertFrom-Json -AsHashtable
            $config.max_parallel_calls=2
            $configPath=Join-Path $fixture.root 'parallel-config.json'; Write-RouterJsonAtomic $configPath $config
            $halt=Invoke-RouterBench -Job fast -Candidate gpt-6-luna -Incumbent gpt-6.1-sol -StateDir $env:DT_MODEL_ROUTER_STATE -ConfigPath $configPath -Limits {param($v) @{blocked=$false}} -NoAlerts
            Check ($halt.halted -and $halt.gate -eq 'unknown') 'real pooled wrapper failure halts'
            Check (@($halt.calls).Count -ge 6 -and @($halt.calls).Count -le 7) 'real pooled failure has only bounded in-flight overshoot'
            Check (@($halt.calls | Where-Object { $_.failure_category -ne 'protocol' -or $_.detail -notmatch '^Parallel call returned nothing' }).Count -eq 0) 'real pooled catch delegates Codex classification'
            Check (@($halt.outcomes | Where-Object attempt -ne 1).Count -eq 0) 'real pooled failure is never retried'
        } finally { $script:BenchParallelCall=$savedParallel }
    }
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT=$priorTransport
    "SUMMARY: $script:checks passed; 0 failed"
} finally { $env:DT_MODEL_ROUTER_STATE=$prior; $env:DT_MODEL_ROUTER_ALERT_TRANSPORT=$priorTransport; Exit-RouterTestCodexHome $fixture }
