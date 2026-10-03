Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../build-roster.ps1')
. (Join-Path $PSScriptRoot '../update-outcomes.ps1')
. (Join-Path $PSScriptRoot '../check-new-models.ps1')
. (Join-Path $PSScriptRoot '../bench/run-bench.ps1')
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
. (Join-Path $PSScriptRoot 'fixtures/bench-proposal-evidence.ps1')
$fixture=Enter-RouterTestCodexHome
$prior=$env:DT_MODEL_ROUTER_STATE
$priorTransport=$env:DT_MODEL_ROUTER_ALERT_TRANSPORT
$root=Join-Path $fixture.root 'repair'
$script:checks=0
function Check($ok,$name) { if(-not $ok){throw "FAIL $name"}; $script:checks++ }
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
            $bench=[pscustomobject]@{raw_gate=$raw;gate='advisory';price_recommendation=$null;shortfall_tasks=3;report_paths=@{markdown='synthetic'}}
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
            $adapter={param($r) Add-TestBenchEvidence ([pscustomobject]@{raw_gate=$script:researchRaw;gate='advisory';price_recommendation=$null;shortfall_tasks=3;report_paths=@{markdown='fixture-research-report'}}) }
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
        Add-TestBenchEvidence ([pscustomobject]@{shadow=$false;raw_gate='pass';gate='advisory';price_recommendation=$r.incumbent;shortfall_tasks=0;effort_down_qualified=($r.job -eq 'coder');incumbent=@{passed=3};effort_down=@{model=$r.incumbent;effort=$down;passed=3};report_paths=@{markdown='fixture-effort-report'}})
    }
    $now=[datetime]'2026-10-02T12:00:00Z'
    $null=Invoke-RouterModelCheck -Force -Now $now -BenchInvoker $qualified
    $script:RouterModelCheckFetcher={param($vendor) if($vendor.id -eq 'openai'){'gpt-6-sol';'gpt-9-astra';'gpt-9-sol'}else{'claude-sonnet-4-5';'claude-fable-9-2'}}
    $checked=Invoke-RouterModelCheck -Force -Now $now.AddHours(13) -BenchInvoker $qualified
    Check ($checked.errors.Count -eq 0 -and $checked.alerts -notcontains 'bench-trigger-error') 'F4 fake listing completes'
    Check (@($script:requests | Where-Object candidate -in @('gpt-9-astra','claude-fable-9-2')).Count -eq 0) 'F4 no automatic frontier dispatch'
    Check (@($script:requests | Where-Object candidate -eq 'gpt-9-sol').Count -eq 4) 'F4 ordinary model dispatches all text jobs'
    $queue=@(Read-RouterJsonArray (Join-Path $env:DT_MODEL_ROUTER_STATE 'research-queue.json'))
    foreach($model in @('gpt-9-astra','claude-fable-9-2','gpt-9-sol')){
        Check (@($queue | Where-Object {$_.model -eq $model -and $_.trigger -eq 'release'}).Count -eq 1 -and @($queue | Where-Object {$_.model -eq $model -and $_.trigger -eq 'confirmation' -and [datetime]$_.due_at -eq $now.AddHours(13).AddDays(7)}).Count -eq 1) "F4 queues retained $model"
    }
    $judges=(Read-RouterJsonObject (Join-Path $env:DT_MODEL_ROUTER_STATE 'bench/judge-config.json')).judges
    Check ($judges.codex -eq 'gpt-9-astra' -and $judges.claude -eq 'claude-fable-9-2') 'F4 listing refreshes judges'
    Check (@(Delivered 'effort-swap:*').Count -eq 1 -and (Read-RouterJsonObject (Join-Path $env:DT_MODEL_ROUTER_STATE 'effort-proposals/coder.json')).status -eq 'pending') 'F5 new-model immediate proposal delivery'
    Send-RouterEffortAlerts
    $null=Invoke-RouterModelCheck -Force -Now $now.AddHours(26) -BenchInvoker $qualified
    Check (@(Delivered 'effort-swap:*').Count -eq 1) 'F5 new-model delivered once'
    Check ((Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'transport.jsonl') -Raw) -match 'coder.*medium -> low.*fixture-effort-report') 'F5 new-model contents and unlocked delivery'
    Fresh-State 'drift-alert'
    $sources=Join-Path $root 'empty-sources.json';[IO.File]::WriteAllText($sources,'[]')
    $outcomes=foreach($period in @('prior','recent')) { foreach($i in 1..10){
        @{key="$period-$i";run_id='fixture';repo='fixture';chunk_id="$period-$i";source='fixture';attempt=1;failure_category='quality';model=$roster.jobs.coder.first;category='complex-coding';lane=$roster.jobs.coder.first_vendor;at=$now.AddDays($(if($period -eq 'prior'){-60}else{-1})).ToString('o');pass=($period -eq 'prior')} | ConvertTo-Json -Compress
    }}
    [IO.File]::WriteAllLines((Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl'),[string[]]$outcomes)
    $null=Update-RouterOutcomes -Now $now -SourcesPath $sources -BenchInvoker $qualified
    Check ((Test-Path (Join-Path $env:DT_MODEL_ROUTER_STATE 'effort-proposals/coder.json')) -and @(Delivered 'effort-swap:*').Count -eq 0) 'F5 drift respects alerts disabled'
    Remove-Item -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'drift-marks.json')
    Remove-Item -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'effort-proposals/coder.json')
    $null=Update-RouterOutcomes -Now $now -SourcesPath $sources -BenchInvoker $qualified -SendAlerts
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
    Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'effort-proposals/coder.json') @{status='pending';job='coder';model=$roster.jobs.coder.first;current_effort='medium';proposed_effort='low';report='empty-drift-report';bench_evidence=$basis}
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
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT=$priorTransport
    "SUMMARY: $script:checks passed; 0 failed"
} finally { $env:DT_MODEL_ROUTER_STATE=$prior; $env:DT_MODEL_ROUTER_ALERT_TRANSPORT=$priorTransport; Exit-RouterTestCodexHome $fixture }
