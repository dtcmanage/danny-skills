# Runs inside the real-wrapper fixture; all model launches use the explicit fake.
$env:M04_FAKE_MODE=''; $env:M04_FAKE_REPORT=''
Remove-Item (Join-Path $env:DT_MODEL_ROUTER_STATE 'vendor-blocks.json') -ErrorAction SilentlyContinue
$a4State=$env:DT_MODEL_ROUTER_STATE
$a4Prompt=[IO.File]::ReadAllText($prompt)
$a4Roster=[IO.File]::ReadAllText((Join-Path $a4State 'roster.json'))
$fakeCli=(Resolve-Path -LiteralPath (Join-Path $fixture.root 'dispatch-fake-cli.ps1')).Path
function Invoke-A4Wrapper([string]$Vendor,[hashtable]$Arguments) {
    $safe=$Arguments.Clone()
    $safe[$Vendor+'CliPath']=$fakeCli
    if ((Resolve-Path -LiteralPath $safe[$Vendor+'CliPath']).Path -cne $fakeCli) { throw 'FAKE_CLI_REQUIRED' }
    & (Join-Path $env:M04_REPO_ROOT "skills/dt-build/scripts/invoke-$Vendor-chunk.ps1") @safe | Out-Null
}
function Reset-A4State([string]$Name) {
    $env:DT_MODEL_ROUTER_STATE=Join-Path $temp $Name
    [void][IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_STATE)
    [IO.File]::WriteAllText((Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json'),$a4Roster)
    $script:ledger=Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl'
    $script:sources=Join-Path $env:DT_MODEL_ROUTER_STATE 'sources.json'
    # Earlier cases leave legacy acceptance rows in $repo. Discovery gets a
    # fresh root per case; A1's output must remain outside that root.
    $script:a4SourceRoot=Join-Path $env:DT_MODEL_ROUTER_STATE 'source-root'
    [void][IO.Directory]::CreateDirectory($script:a4SourceRoot)
    ConvertTo-Json -InputObject @($script:a4SourceRoot) | Set-Content $sources
}
function New-A4Arguments([string]$Name) {
    @{ProjectPath=$repo;PromptPath=$prompt;OutputPath=(Join-Path $temp ($Name+'.md'));Category='routine-coding';Effort='medium';SelectionReason='a4 fake CLI fixture';AdHoc=$true;ReadOnly=$true;Json=$true}
}
try {
    # A1: neither direct lane depends on source-root discovery. Failed indexes
    # queue exactly one path and acceptance is recoverable after the mutex opens.
    foreach($lane in 'claude','codex') {
        Reset-A4State "A1-$lane"
        $a=New-A4Arguments "outside-A1-$lane"
        $hold=[IO.File]::Open((Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.mutex'),'OpenOrCreate','ReadWrite','None')
        try {
            Invoke-A4Wrapper $lane $a
            $r=Read-Evidence $a.OutputPath
            $pending=@(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE)
            Check ($r.execution_result -eq 'success' -and $r.finished_utc -and $pending.Count -eq 1 -and ([IO.File]::ReadAllText($pending[0].FullName) | ConvertFrom-Json).provenance_path -eq ($a.OutputPath+'.provenance.json') -and ([IO.File]::ReadAllText($pending[0].FullName) | ConvertFrom-Json).snapshot.finished_utc) "A1 $lane success and one outside-root pending path under whole-run lock"
        } finally { $hold.Dispose() }
        $u=Update-RouterOutcomes -SourcesPath $sources
        Check ($u.total_records -eq 1 -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 0) "A1 $lane update drains pointer into one row"
        Set-RouterDispatchAcceptance ($a.OutputPath+'.provenance.json') $r.dispatch_id $true
        $u=Update-RouterOutcomes -SourcesPath $sources
        Check ($u.first_attempt.accepted -eq 1 -and $u.first_attempt.total -eq 1 -and $u.total_records -eq 1) "A1 $lane acceptance first attempt 1/1"
    }
    # A2: an ordinary unlocked ledger reader prevents replacement on Windows.
    # Start the holder only after the fake CLI is entered, after started indexing.
    Reset-A4State 'A2'
    $signal=Join-Path $temp 'A2-reader.signal'
    $holder=Join-Path $temp 'A2-reader.ps1'
    @'
param($Ledger,$Signal)
foreach ($name in @('DT_JOB_ID','DT_JOB_DIR','DT_BUILD_COORDINATOR_ID')) { Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction SilentlyContinue }
$watch=[Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath $Signal)) { if($watch.Elapsed.TotalSeconds -gt 45){exit 2}; Start-Sleep -Milliseconds 50 }
$h=[IO.File]::Open($Ledger,'Open','Read',[IO.FileShare]::ReadWrite)
try {
    [IO.File]::WriteAllText(($Signal+'.held'),'held')
    while (-not (Test-Path -LiteralPath ($Signal+'.release'))) { if($watch.Elapsed.TotalSeconds -gt 60){exit 3}; Start-Sleep -Milliseconds 50 }
} finally { $h.Dispose() }
'@ | Set-Content $holder
    $env:M04_FAKE_READER_SIGNAL=$signal
    $reader=Start-Process pwsh -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-File',('"'+$holder+'"'),('"'+$ledger+'"'),('"'+$signal+'"')) -RedirectStandardOutput (Join-Path $temp 'A2-reader.out') -RedirectStandardError (Join-Path $temp 'A2-reader.err')
    try {
        $a=New-A4Arguments 'A2'
        Invoke-A4Wrapper 'codex' $a
        $r=Read-Evidence $a.OutputPath
        Check ($r.execution_result -eq 'success' -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 1) 'A2 ledger sharing violation preserves execution and pending pointer'
    } finally {
        [IO.File]::WriteAllText(($signal+'.release'),'release')
        $env:M04_FAKE_READER_SIGNAL=''
        if (-not $reader.WaitForExit(10000)) { $reader.Kill(); throw 'A2 reader failed to stop' }
    }
    # The next dispatch upsert, without a full update, also drains pending paths.
    $a=New-A4Arguments 'A2-next'; Invoke-A4Wrapper 'claude' $a
    Check (@(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 0 -and (Read-RouterOutcomeLedger $ledger).records.Count -eq 2) 'A2 next upsert drains pending paths'
    # A3 / x12: failed preflights retain HEAD canary behavior and complete schema.
    foreach($lane in 'claude','codex') {
        Reset-A4State "A3-$lane"
        $a=New-A4Arguments "A3-$lane"; $a.Remove('AdHoc');$a.Remove('PromptPath');$a.Preflight=$true
        $env:M04_FAKE_REPORT=Join-Path $temp 'A3-bad.txt';[IO.File]::WriteAllText($env:M04_FAKE_REPORT,'NOT OK')
        Reject { Invoke-A4Wrapper $lane $a } 'PREFLIGHT_FAIL'
        $rows=@(Get-Content $ledger | ForEach-Object { $_ | ConvertFrom-Json })
        Check ($rows.Count -eq 1 -and $rows[0].source -eq 'canary' -and $rows[0].run_id -eq 'preflight' -and -not $rows[0].pass) "A3 $lane failed preflight exactly one canary"
        foreach($field in @('key','run_id','repo','tier','escalated','at','source','lane','model','category','attempt','pass','failure_category','diagnosis')) { Check ([bool]$rows[0].PSObject.Properties[$field]) "A3 $lane complete canary field $field" }
        $env:M04_FAKE_REPORT=''; $a.OutputPath=Join-Path $script:a4SourceRoot "A3-pass-$lane.md"
        Invoke-A4Wrapper $lane $a
        $u=Update-RouterOutcomes -SourcesPath $sources
        Check ($u.total_records -eq 1 -and $u.new_records -eq 0 -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 0) "A3 $lane passed preflight and later update add no rows"
    }
    # A4: retain the real reader fixture so the final gate can run it by path.
    Reset-A4State 'A4'
    $plainRepo=Join-Path $temp 'plain-repo';[void][IO.Directory]::CreateDirectory($plainRepo)
    & git -C $plainRepo init -q
    & git -C $plainRepo -c user.email=t@example.com -c user.name=t commit --allow-empty -qm fixture
    $a=New-A4Arguments 'A4'; $a.ProjectPath=$plainRepo
    Invoke-A4Wrapper 'codex' $a
    $r=Read-Evidence $a.OutputPath
    $costFixture=if($env:M04_A4_COST_FIXTURE){$env:M04_A4_COST_FIXTURE}else{Join-Path ([IO.Path]::GetTempPath()) ('m04-a4-cost-'+[guid]::NewGuid().ToString('N'))}
    [void][IO.Directory]::CreateDirectory($costFixture)
    $costProvenance=Join-Path $costFixture 'A4.provenance.json'
    Copy-Item ($a.OutputPath+'.provenance.json') $costProvenance
    $costRow=ConvertTo-DispatchOutcome $r $costProvenance
    Check (-not $costRow.PSObject.Properties['workstation'] -and $r.difficulty -and $null -eq $r.workstation) 'A4 real null-workstation provenance omits unknown ledger field'
    $costRow | ConvertTo-Json -Depth 40 -Compress | Set-Content (Join-Path $costFixture 'outcomes.jsonl')
    & python (Join-Path $env:M04_REPO_ROOT 'scripts/model-router/cost_report.py') --state-dir $costFixture
    Check ($LASTEXITCODE -eq 0) 'A4 real cost_report.py reader exit 0'
    "A4_COST_FIXTURE: $costFixture"
    # B1: public command and direct adapter derive one identity across worktrees.
    Reset-A4State 'B1'
    $linked=Join-Path $temp 'B1-linked'
    & git -C $repo worktree add -qb a4-linked $linked 2>$null
    $firstB1=$null
    foreach($attemptNumber in 1,2) {
        [IO.File]::WriteAllText($prompt,"RUN_ID: a4-identity`nchunk_id: m04-build`nattempt: $attemptNumber`nfixture")
        $env:M04_FAKE_REPORT=Join-Path $temp 'B1-report.md'
        [IO.File]::WriteAllText($env:M04_FAKE_REPORT,"DT_BUILD_REPORT_VERSION: 3`nRUN_ID: a4-identity`nchunk_id: m04-build`nattempt: $attemptNumber`nVERDICT:`nPASS`nCHANGED_FILES:`nNONE`nCOMMANDS_AND_RESULTS:`nNONE`nEVIDENCE_PATHS:`nNONE`nUNRESOLVED_BLOCKERS:`nNONE`nDISCOVERED_ENHANCEMENTS:`nNONE`nCONTINUATION_STATE:`nNONE`n")
        $a=New-A4Arguments "B1-$attemptNumber";$a.Remove('AdHoc');$a.Attempt=$attemptNumber
        if($attemptNumber -eq 1){$a.Lane='codex';$r=Invoke-RouterDispatch $a $real;$firstB1=$r}
        else{$a.ProjectPath=$linked;Invoke-A4Wrapper 'codex' $a;$r=Read-Evidence $a.OutputPath}
        Set-RouterDispatchAcceptance ($a.OutputPath+'.provenance.json') $r.dispatch_id ($attemptNumber -eq 2)
    }
    $u=Update-RouterOutcomes -SourcesPath $sources
    Check ($r.logical_task_id -eq 'a4-identity:m04-build' -and $r.logical_task_id -eq $firstB1.logical_task_id -and $u.first_attempt.total -eq 1 -and $u.first_attempt.accepted -eq 0 -and $u.first_attempt.retries -eq 1) 'B1 automatic headers link public/direct worktrees first attempt 0/1 one retry'
    $env:M04_FAKE_REPORT=''
    # B2: identical filenames and pasted headers do not alias ad hoc tasks.
    Reset-A4State 'B2'; $ids=@()
    foreach($folder in 'one','two') {
        $p=Join-Path $temp "B2-$folder/prompt.md";[void][IO.Directory]::CreateDirectory((Split-Path -Parent $p));[IO.File]::WriteAllText($p,'RUN_ID: a4-identity' + "`nchunk_id: m04-build")
        $a=New-A4Arguments "B2-$folder";$a.PromptPath=$p;Invoke-A4Wrapper 'claude' $a;$ids+=(Read-Evidence $a.OutputPath).logical_task_id
    }
    Check ($ids[0] -ne $ids[1] -and $ids[0] -like 'adhoc:*' -and $ids[1] -like 'adhoc:*' -and $ids -notcontains 'a4-identity:m04-build') 'B2 full prompt paths isolate ad hoc tasks and ignore pasted headers'
    $a=New-A4Arguments 'B2-explicit';$a.LogicalTaskId='explicit-wins';Invoke-A4Wrapper 'codex' $a
    Check ((Read-Evidence $a.OutputPath).logical_task_id -eq 'explicit-wins') 'B2 explicit logical identity wins'
    # C1: refreshed catalog, both adapters, plus all special refusal classes.
    Reset-A4State 'C1'
    foreach($modelName in @(@((Get-Content (Join-Path $env:CODEX_HOME 'models_cache.json') -Raw | ConvertFrom-Json).models.slug | Where-Object { $_ -ne 'gpt-6-astra' }) + @('claude-opus-4-8','claude-opus-5-5-20261105[1m]','claude-sonnet-4-5-20250929[1m]','claude-haiku-4-5'))) {
        $lane=if($modelName -like 'claude-*'){'claude'}else{'codex'}
        $a=New-A4Arguments ('C1-'+$lane);$a.Model=$modelName;Invoke-A4Wrapper $lane $a
        Check ((Read-Evidence $a.OutputPath).actual_model -eq $modelName) "C1 $lane known name $modelName"
    }
    foreach($modelName in @('gpt-reserve','codex-auto-review','gpt-7-sol','gpt-6.1-astra','gpt-6-astra','claude-fable-5-2','claude-3-opus-20240229')) {
        foreach($lane in 'claude','codex') {
            $before=[IO.File]::ReadAllText($env:M04_FAKE_ARGS)
            $a=New-A4Arguments 'C1-refused';$a.Model=$modelName
            Reject { Invoke-A4Wrapper $lane $a } 'FRONTIER_REQUEST_REQUIRED'
            Check ([IO.File]::ReadAllText($env:M04_FAKE_ARGS) -ceq $before) "C1 $lane refused $modelName without launch"
        }
    }
    # D1 / D2 / x20: reservations are distinct from real launches, which stay spent.
    foreach($lane in 'codex','claude') {
        Reset-A4State "D-$lane"
        $rRoster=Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json') -Raw | ConvertFrom-Json
        $rRoster.jobs.coder.first_vendor=$lane;$rRoster.jobs.coder.first=if($lane -eq 'codex'){'gpt-6.1-sol'}else{'claude-opus-5-5'}
        $rRoster.jobs.coder.backup_vendor=if($lane -eq 'codex'){'claude'}else{'codex'};$rRoster.jobs.coder.backup=if($lane -eq 'codex'){'claude-opus-5-5'}else{'gpt-6.1-sol'}
        $rRoster | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json')
        $frontierDir=Join-Path $env:DT_MODEL_ROUTER_STATE 'frontier-requests';[void][IO.Directory]::CreateDirectory($frontierDir)
        $frontierModel=if($lane -eq 'codex'){'gpt-6-astra'}else{'claude-fable-5-1'}
        $req=@{id='a4';category='complex-coding';status='approved';proposed_model=$frontierModel;proposed_effort='high';approved_model=$frontierModel;decided_at='2026-11-05T12:00:00Z'}
        $reqPath=Join-Path $frontierDir 'a4.json'
        $req | ConvertTo-Json | Set-Content $reqPath
        $a=New-A4Arguments 'D1';$a.Category='complex-coding';$a.Model=$frontierModel;$a.FrontierRequest='a4';$a.OutputPath=Join-Path $prompt 'cannot-write.md'
        $before=[IO.File]::ReadAllText($env:M04_FAKE_ARGS)
        Reject { Invoke-RouterDispatch $a $real } 'directory|file|path'
        Check ((Get-Content $reqPath -Raw | ConvertFrom-Json).status -eq 'approved' -and [IO.File]::ReadAllText($env:M04_FAKE_ARGS) -ceq $before) "D1 $lane bad output releases reservation without launch"
        $a.OutputPath=Join-Path $temp "D1-$lane.md";$r=Invoke-RouterDispatch $a $real
        Check ($r.execution_result -eq 'success') "D1 $lane retry launches successfully"
        $req.status='used';$req | ConvertTo-Json | Set-Content $reqPath
        $direct=$a.Clone();$direct.Remove('FrontierRequest');$direct.FrontierRequest='a4'
        Reject { Invoke-A4Wrapper $lane $direct } 'FRONTIER_REQUEST_USED'
        $forged=New-A4Arguments 'D1-forged';$forged.Category='complex-coding';$forged.RouterResolution=[pscustomobject]@{status='ok';model=$frontierModel;vendor=$lane;effort='high';difficulty='hard'}
        Reject { Invoke-A4Wrapper $lane $forged } 'FRONTIER_REQUEST_REQUIRED'
        foreach($mode in 'incident','unexplained') {
            $req.status='approved';$req | ConvertTo-Json | Set-Content $reqPath
            Remove-Item (Join-Path $env:DT_MODEL_ROUTER_STATE 'vendor-blocks.json'),(Join-Path $env:DT_MODEL_ROUTER_STATE 'vendor-status-cache.json') -ErrorAction SilentlyContinue
            $env:M04_FAKE_MODE=if($lane -eq 'claude' -and $mode -eq 'incident'){'claude-incident'}else{$mode}
            if($mode -eq 'unexplained') {
                $healthy=Join-Path $temp 'D2-healthy.ps1'
                @'
$script:RouterDiagnosisDns={param($ApiHost) $true}
$script:RouterDiagnosisHttp={
    param($Uri)
    if($Uri -like '*connecttest*'){return 'connected'}
    if($Uri -like '*unresolved*'){return [pscustomobject]@{incidents=@()}}
    $config=Get-Content (Join-Path $env:M04_REPO_ROOT 'references/model-router/vendor-status.json') -Raw | ConvertFrom-Json
    $laneConfig=if($Uri -eq $config.codex.components_url){$config.codex}else{$config.claude}
    [pscustomobject]@{components=@($laneConfig.components|ForEach-Object{[pscustomobject]@{name=$_;id='component';status='operational'}})}
}
'@ | Set-Content $healthy
                $originalSeam=$env:DT_BUILD_DISPATCH_SEAMS;$env:DT_BUILD_DISPATCH_SEAMS=$healthy
            }
            try {
                $beforeCount=@(Get-Content $env:M04_FAKE_ARGS).Count
                $r=Invoke-RouterDispatch $a $real
                Check (@(Get-Content $env:M04_FAKE_ARGS).Count -eq ($beforeCount+1) -and $r.execution_result -eq 'failure' -and $r.failure_category -and $r.termination_reason -notmatch 'FRONTIER_REQUEST_USED') "D2 $lane $mode one launch preserves real failure"
                if($mode -eq 'incident'){Check ($r.termination_reason -match 'ROUTER_VENDOR_INCIDENT') "D2 $lane incident cause retained"}else{Check ($r.termination_reason -match 'SINGLE_DISPATCH_REFUSED: unexplained') "D2 $lane unexplained cause retained"}
                Check ([bool](Get-Content $reqPath -Raw | ConvertFrom-Json).launched_dispatch_id) "D2 $lane $mode launched approval stays spent x20"
                Reject { Invoke-A4Wrapper $lane $direct } 'FRONTIER_REQUEST_USED'
            } finally { if($mode -eq 'unexplained'){$env:DT_BUILD_DISPATCH_SEAMS=$originalSeam} }
        }
        $env:M04_FAKE_MODE=''
    }
    Check (-not (Assert-RouterDispatchPick -Resolution ([pscustomobject]@{model='gpt-image-2'}))) 'D1 approved gpt-image-2 outside ladder unaffected'

    # E1: the one publication sink redacts stderr, job sidecar and stored evidence.
    Reset-A4State 'E1'
    $jobDir=Join-Path $temp 'redaction-run/jobs/fake';[void][IO.Directory]::CreateDirectory($jobDir)
    $env:DT_JOB_DIR=$jobDir
    try {
        $a=New-A4Arguments 'E1';$a.SelectionReason='token=sk-abcdefghijklmnopqrstuvwxyz123456'
        $stderr=Join-Path $temp 'E1.stderr'
        Invoke-A4Wrapper 'claude' $a 2> $stderr
        $all=[IO.File]::ReadAllText($stderr)+[IO.File]::ReadAllText((Join-Path $jobDir 'model-selection.json'))+[IO.File]::ReadAllText(($a.OutputPath+'.provenance.json'))+[IO.File]::ReadAllText($ledger)
        Check ($all -notmatch 'abcdefghijklmnopqrstuvwxyz123456' -and $all -match 'REDACTED') 'E1 no secret in stderr sidecar provenance or ledger'
    } finally { Remove-Item Env:DT_JOB_DIR -ErrorAction SilentlyContinue }
    # x18: absence of Claude usage survives the real parser and adapter.
    $env:M04_FAKE_MODE='unknown-usage';$a=New-A4Arguments 'x18';Reject { Invoke-A4Wrapper 'claude' $a } 'no modelUsage';$r=Read-Evidence $a.OutputPath
    Check ($r.execution_result -eq 'success' -and $null -eq $r.usage) 'x18 real Claude unknown usage stays null'
    # The public command resolves the pinned vendor even for a Claude-first job.
    $env:M04_FAKE_MODE='';$env:DT_BUILD_RUN_PIN_VENDOR='codex';$env:DT_BUILD_RUN_PIN_MODEL='gpt-6-sol'
    try {
        $a=New-A4Arguments 'pin-public';$a.Category='analysis';$r=Invoke-RouterDispatch $a $real
        Check ($r.execution_result -eq 'success' -and $r.actual_model -eq 'gpt-6-sol' -and $r.lane -eq 'codex') 'public Claude-first category resolves onto Codex run pin'
    } finally { Remove-Item Env:DT_BUILD_RUN_PIN_VENDOR,Env:DT_BUILD_RUN_PIN_MODEL -ErrorAction SilentlyContinue }
} finally {
    $env:DT_MODEL_ROUTER_STATE=$a4State
    $env:M04_FAKE_MODE='';$env:M04_FAKE_REPORT='';$env:M04_FAKE_READER_SIGNAL=''
    [IO.File]::WriteAllText($prompt,$a4Prompt)
}
