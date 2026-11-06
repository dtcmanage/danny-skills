param([switch]$A5Only, [switch]$A6Only)
foreach ($name in @('DT_JOB_ID','DT_JOB_DIR','DT_BUILD_COORDINATOR_ID')) { Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction SilentlyContinue }
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../dispatch.ps1')
. (Join-Path $PSScriptRoot '../update-outcomes.ps1')
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('dispatch-real-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$saved=@{}; foreach($name in @('DT_MODEL_ROUTER_STATE','DT_MODEL_ROUTER_ALERT_TRANSPORT','DT_BUILD_DISPATCH_SEAMS','M04_FAKE_ARGS','M04_FAKE_MODE','M04_FAKE_REPORT','M04_REPO_ROOT')) { $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
$fixture=Enter-RouterTestCodexHome
$env:DT_MODEL_ROUTER_STATE=Join-Path $temp 'state'; [void][IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_STATE)
$env:M04_FAKE_ARGS=Join-Path $temp 'args.log'; [IO.File]::WriteAllText($env:M04_FAKE_ARGS,'')
$env:M04_REPO_ROOT=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$checks=0
function Check([bool]$Condition,[string]$Name) { if (-not $Condition) { Get-ChildItem -LiteralPath $temp -Filter '*.provenance.json' -File -Recurse | ForEach-Object { try { $ev=Read-RouterDispatchEvidence $_.FullName; [Console]::Error.WriteLine(("FAILED_CHECK_EVIDENCE: {0} termination_reason={1} exit_code={2} execution_result={3}" -f $_.FullName,(Get-DispatchValue $ev 'termination_reason'),$(if ((Get-DispatchValue $ev 'termination_reason') -match 'exited (-?\d+)') { $Matches[1] } elseif ($ev.execution_result -eq 'success') { 0 } elseif ($ev.PSObject.Properties['dispatch_attempts'] -and @($ev.dispatch_attempts).Count) { $ev.dispatch_attempts[-1].exit_code } else { 'unknown' }),(Get-DispatchValue $ev 'execution_result'))) } catch {} }; throw "FAIL: $Name" }; $script:checks++; "PASS: $Name" }
function Reject([scriptblock]$Action,[string]$Pattern) { try { & $Action | Out-Null } catch { Check ($_.Exception.Message -match $Pattern) "reject $Pattern ($($_.Exception.Message))"; return }; throw "FAIL: accepted $Pattern" }
$script:blocked=@()
function Get-RouterVendorBlocked { param($Vendor,$UsageReadings) $Vendor -in $script:blocked }
function Get-RouterClaudeUsage { $null }
function Get-RouterCodexUsage { $null }
$real={ param($Vendor,$Arguments)
    $adapter=$Arguments.Clone()
    if($Vendor -ne 'codex') { $adapter.Remove('AllowOutputInProject') }
    $adapter[$Vendor+'CliPath']=Join-Path $fixture.root 'dispatch-fake-cli.ps1'
    if ((Resolve-Path -LiteralPath $adapter[$Vendor+'CliPath']).Path -ne (Resolve-Path -LiteralPath (Join-Path $fixture.root 'dispatch-fake-cli.ps1')).Path) { throw 'FAKE_CLI_REQUIRED' }
    & (Join-Path $PSScriptRoot "../../../skills/dt-build/scripts/invoke-$Vendor-chunk.ps1") @adapter | Out-Null
}
function Read-Evidence([string]$Path) { Get-Content -LiteralPath ($Path+'.provenance.json') -Raw | ConvertFrom-Json -Depth 40 -DateKind String }
try {
    $seam=Join-Path $temp 'seams.ps1'
    @'
$script:RouterDiagnosisDns = { param($ApiHost) $true }
$script:RouterDiagnosisHttp = {
    param($Uri)
    if ($Uri -like '*connecttest*') { return 'connected' }
    if ($Uri -like '*unresolved*') { return [pscustomobject]@{incidents=@([pscustomobject]@{id='fixture';components=@([pscustomobject]@{id='component'})})} }
    $config=Get-Content -LiteralPath (Join-Path $env:M04_REPO_ROOT 'references/model-router/vendor-status.json') -Raw | ConvertFrom-Json
    $lane=if($Uri -eq $config.codex.components_url) { $config.codex } else { $config.claude }
    [pscustomobject]@{components=@($lane.components | ForEach-Object { [pscustomobject]@{name=$_;id='component';status='partial_outage'} })}
}
'@ | Set-Content -LiteralPath $seam
    $env:DT_BUILD_DISPATCH_SEAMS=$seam
    $transport=Join-Path $temp 'alert.ps1'; 'param($request); [pscustomobject]@{id="fixture"}' | Set-Content $transport
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT=$transport
    @{checked_at=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'last-check.json')
    $roster=Get-Content (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json
    $roster.approved=$true; $roster.approved_at='2026-11-05T00:00:00Z'
    $roster | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json')
    $catalogPath=Join-Path $env:CODEX_HOME 'models_cache.json'; $catalog=Get-Content $catalogPath -Raw | ConvertFrom-Json
    foreach($catalogRow in $catalog.models) { $catalogRow | Add-Member -Force -NotePropertyName supported_reasoning_levels -NotePropertyValue @(@{effort='low'},@{effort='medium'},@{effort='high'},@{effort='xhigh'}) }
    $catalog | ConvertTo-Json -Depth 12 | Set-Content $catalogPath
    $repo=Join-Path $temp '_Claude-Workspace/Fixture/repo'; [void][IO.Directory]::CreateDirectory($repo)
    & git -C $repo init -q
    & git -C $repo -c user.email=t@example.com -c user.name=t commit --allow-empty -qm fixture
    $prompt=Join-Path $temp 'prompt.md'; [IO.File]::WriteAllText($prompt,'fixture prompt')
    $out=Join-Path $temp 'result.md'
    $base=@{ProjectPath=$repo;Category='routine-coding';PromptPath=$prompt;OutputPath=$out;SelectionReason='fixture';AdHoc=$true;ReadOnly=$true}
    $ledger=Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl'
    if (-not $A5Only -and -not $A6Only) {
    # Production bench shape has neither key nor dispatch identity.
    $bench="{ `"source`": `"bench`", `"attempt`": 1, `"at`": `"2026-11-05T00:00:00Z`", `"model`": `"gpt-6.1-sol`", `"lane`": `"codex`", `"category`": `"routine-coding`", `"failure_category`": null, `"pass`": true }`r`n"
    [IO.File]::WriteAllText($ledger,$bench)
    foreach($lane in 'codex','claude') {
        $o=$base.Clone(); $o.Lane=$lane; $r=Invoke-RouterDispatch $o $real
        Check ($r.execution_result -eq 'success' -and $r.lane -eq $lane -and $r.finished_utc) "real $lane wrapper completes with lane"
        Check ($r.actual_model -and $r.usage -and $null -eq $r.independent_acceptance) "real $lane telemetry evidence, acceptance unknown"
        Check ([IO.File]::ReadAllText($ledger).StartsWith($bench)) 'keyless bench bytes and order survive sync'
        if($lane -eq 'claude') { Check ($r.tools -eq 'Bash,Read,Glob,Grep,WebSearch,WebFetch') 'ad hoc read-only web tools' }
    }
    $env:M04_FAKE_MODE='no-rollout'; $o=$base.Clone(); $o.Lane='codex'; $r=Invoke-RouterDispatch $o $real
    Check ($null -eq $r.actual_model -and $null -eq $r.usage -and $r.lane -eq 'codex') 'no session evidence means null telemetry with known Codex lane'
    $env:M04_FAKE_MODE=''
    foreach($name in @('claude-fable-5-1[1m]','fable[1m]','claude-fable-5-1-20261101',' CLAUDE-FABLE-5-1 ','gpt-6-astra[1m]','astra','unknown-new-model')) {
        $o=$base.Clone(); $o.Model=$name
        $before=[IO.File]::ReadAllText($env:M04_FAKE_ARGS)
        Reject { Invoke-RouterDispatch $o $real } 'FRONTIER_REQUEST_REQUIRED'
        Check ([IO.File]::ReadAllText($env:M04_FAKE_ARGS) -ceq $before) "frontier bypass $name never launches CLI"
        if ($name -match 'fable') {
            Reject { & (Join-Path $PSScriptRoot '../../../skills/dt-build/scripts/invoke-claude-chunk.ps1') -ProjectPath $repo -PromptPath $prompt -OutputPath $out -Category routine-coding -Effort medium -SelectionReason fixture -Model $name -AdHoc -ReadOnly -ClaudeCliPath (Join-Path $fixture.root 'dispatch-fake-cli.ps1') } 'FRONTIER_REQUEST_REQUIRED'
            Check ([IO.File]::ReadAllText($env:M04_FAKE_ARGS) -ceq $before) 'direct Claude wrapper frontier guard never launches CLI'
        }
    }
    $o=$base.Clone(); $o.Model=' OPUS[1m] '; $r=Invoke-RouterDispatch $o $real
    Check ($r.actual_model -eq 'claude-opus-5-5' -and $r.override_reason -eq 'fixture') 'known non-frontier alias normalizes'
    $o=$base.Clone(); $o.Lane='claude'; $o.EscalateFrom='sonnet'; $r=Invoke-RouterDispatch $o $real
    Check ($r.escalated_from -eq 'sonnet') 'escalation preserves caller evidence'
    $rows=@(Get-Content $ledger | ForEach-Object { $_ | ConvertFrom-Json -DateKind String })
    $row=@($rows | Where-Object { (Get-DispatchValue $_ 'dispatch_id') -eq $r.dispatch_id })[0]
    Check ($row.escalated -and $row.workstation -eq 'Fixture') 'escalated and known workstation reach ledger'
    $unknownRepo=Join-Path $temp 'unknown-repo';[void][IO.Directory]::CreateDirectory($unknownRepo)
    & git -C $unknownRepo init -q
    & git -C $unknownRepo -c user.email=t@example.com -c user.name=t commit --allow-empty -qm fixture
    $unknownOptions=$base.Clone();$unknownOptions.ProjectPath=$unknownRepo
    $unknownWorkstation=Invoke-RouterDispatch $unknownOptions $real
    Check ($null -eq $unknownWorkstation.workstation) 'unknown workstation remains null in real wrapper provenance'
    $o=$base.Clone(); $o.AdHoc=$false; $r=Invoke-RouterDispatch $o $real
    Check ($r.execution_result -eq 'failure' -and $r.finished_utc -and $r.failure_category -and $r.termination_reason) 'early wrapper refusal is terminal and explained'
    $o=$base.Clone(); $o.Lane='claude'; $o.Model='opus'; $o.SelectionReason='token=sk-abcdefghijklmnopqrstuvwxyz123456'
    $r=Invoke-RouterDispatch $o $real
    Check ($r.selection_reason -notmatch 'abcdefghijklmnopqrstuvwxyz' -and $r.override_reason -notmatch 'abcdefghijklmnopqrstuvwxyz') 'selection and override reasons redacted equally'
    $frontier=Join-Path $env:DT_MODEL_ROUTER_STATE 'frontier-requests'; [void][IO.Directory]::CreateDirectory($frontier)
    foreach($lane in 'codex','claude') {
        $roster.jobs.coder.first_vendor=$lane; $roster.jobs.coder.first=if($lane -eq 'codex'){'gpt-6.1-sol'}else{'claude-opus-5-5'}
        $roster.jobs.coder.backup_vendor=if($lane -eq 'codex'){'claude'}else{'codex'}; $roster.jobs.coder.backup=if($lane -eq 'codex'){'claude-opus-5-5'}else{'gpt-6.1-sol'}
        $roster | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json')
        $model=if($lane -eq 'codex'){'gpt-6-astra'}else{'claude-fable-5-1'}
        $request=Join-Path $frontier "$lane.json"
        @{id=$lane;category='complex-coding';status='approved';proposed_model=$model;proposed_effort='high';approved_model=$model;decided_at='2026-11-05T12:00:00Z'} | ConvertTo-Json | Set-Content $request
        $o=$base.Clone(); $o.Category='complex-coding'; $o.FrontierRequest=$lane; $o.Model='gpt-6.1-sol'
        Reject { Invoke-RouterDispatch $o $real } 'MODEL_MISMATCH'
        Check ((Get-Content $request -Raw | ConvertFrom-Json).status -eq 'approved') 'mismatch preserves fake approval'
        $o.Model=$model; $r=Invoke-RouterDispatch $o $real
        Check ($r.execution_result -eq 'success' -and $r.finished_utc -and $r.actual_model -eq $model) "approved $lane frontier finishes complete record using fake CLI"
    }
    $roster.jobs.coder.first_vendor='codex';$roster.jobs.coder.first='gpt-6.1-sol';$roster.jobs.coder.backup_vendor='claude';$roster.jobs.coder.backup='claude-opus-5-5'
    $roster | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json')
    $env:M04_FAKE_MODE='incident'; $o=$base.Clone(); $r=Invoke-RouterDispatch $o $real
    Check ($r.requested_model -eq 'gpt-6.1-sol' -and $r.actual_model -like 'claude-*' -and $r.fallback_reason -eq 'environment') 'real wrapper Codex-to-Claude fallback'
    $rows=@(Get-Content $ledger | ForEach-Object { $_ | ConvertFrom-Json -DateKind String })
    $recent=@($rows | Where-Object { (Get-DispatchValue $_ 'started_utc') -eq $r.started_utc })
    Check ($recent.Count -eq 1 -and $recent[0].dispatch_id -eq $r.dispatch_id) 'fallback is one logical dispatch'
    $env:M04_FAKE_MODE=''; Remove-Item (Join-Path $env:DT_MODEL_ROUTER_STATE 'vendor-blocks.json') -ErrorAction SilentlyContinue
    $script:blocked=@('codex','claude'); Reject { Invoke-RouterDispatch $base $real } 'ROUTER_WAIT'; $script:blocked=@()
    $r=Read-Evidence $out; Check ($r.failure_category -eq 'environment' -and $r.termination_reason -match 'ROUTER_WAIT' -and $r.category) 'wait row includes category and reason'
    $run=Join-Path $temp 'planning/.dt-build/fixture-run'; $ms=Join-Path $run 'milestones/M01'; [void][IO.Directory]::CreateDirectory($ms)
    $first=$null; $second=$null
    foreach($attempt in 1,2) {
        $o=$base.Clone(); $o.OutputPath=Join-Path $ms "report-build-a$attempt.md"; $o.Attempt=$attempt; $o.LogicalTaskId='fixture-run:m01-build'; $o.Lane='codex'; $o.AllowOutputInProject=$true
        if($first) { $o.PriorDispatchId=$first.dispatch_id }
        if ($attempt -eq 1) { $env:M04_FAKE_REPORT=Join-Path $temp 'failed-report.md'; [IO.File]::WriteAllText($env:M04_FAKE_REPORT,' ') } else { $env:M04_FAKE_REPORT='' }
        $r=Invoke-RouterDispatch $o $real
        if($attempt -eq 1) { $first=$r } else { $second=$r }
    }
    $acceptance=[ordered]@{milestone='M01';milestone_id='M01';status='PASS';implemented=$true;tested=$true;accepted=$true;commit_sha='fixture';category='routine-coding';resolved_model='gpt-6.1-sol';requested_model='gpt-6.1-sol';escalated=$false;selection_reason='fixture';attempt=2;verifier_result='PASS';command_results=@(@{command='fixture';exit_code=0});downgrade_status='clean';recorded_utc=[datetimeoffset]::UtcNow.ToString('o');dispatch_id=$second.dispatch_id;provenance_path=(Join-Path $ms 'report-build-a2.md.provenance.json')}
    $acceptPath=Join-Path $run 'acceptance-rows.jsonl'; $acceptance | ConvertTo-Json -Depth 20 -Compress | Set-Content $acceptPath
    $unverified=$base.Clone(); $unverified.OutputPath=Join-Path $repo 'unverified.md'; $unverified.AllowOutputInProject=$true; $unverified.ReadOnly=$false; $unknown=Invoke-RouterDispatch $unverified $real
    Check ($unknown.execution_result -eq 'success' -and $null -eq $unknown.independent_acceptance -and -not $unknown.failure_category) 'ad hoc execution succeeds with independent acceptance unknown'
    $sources=Join-Path $temp 'sources.json'; ConvertTo-Json -InputObject @($repo) | Set-Content $sources
    # Keep the keyless bench and only the task/retry/unknown rows for the metric.
    $keep=Read-RouterOutcomeLedger $ledger
    $relevant=[ordered]@{};foreach($key in $keep.records.Keys) { if($keep.records[$key].provenance_path -like ($repo+'*') -or $keep.records[$key].provenance_path -like ($run+'*')) { $relevant[$key]=$keep.records[$key] } }
    Write-RouterOutcomeLedger $ledger $keep $relevant
    Set-RouterDispatchAcceptance -ProvenancePath $acceptance.provenance_path -DispatchId $second.dispatch_id -Accepted $true
    $result=Update-RouterOutcomes -SourcesPath $sources
    Check ($result.first_attempt.total -eq 1 -and $result.first_attempt.accepted -eq 0 -and $result.first_attempt.retries -eq 1) 'real filter first-attempt 0/1 with one retry, unknown and bench excluded'
    $beforeBytes=[IO.File]::ReadAllText($ledger);$beforeTime=(Get-Item $ledger).LastWriteTimeUtc
    $again=Update-RouterOutcomes -SourcesPath $sources
    Check ($again.new_records -eq 0 -and [IO.File]::ReadAllText($ledger) -ceq $beforeBytes -and (Get-Item $ledger).LastWriteTimeUtc -eq $beforeTime) 'repeat update is zero new with untouched ledger'
    # The ledger's later downgrade writes provenance false while the immutable
    # acceptance file can still contain its earlier PASS. That negative is final.
    Set-RouterDispatchAcceptance -ProvenancePath $acceptance.provenance_path -DispatchId $second.dispatch_id -Accepted $false
    $null=Update-RouterOutcomes -SourcesPath $sources
    $rows=@(Get-Content $ledger | ForEach-Object { $_ | ConvertFrom-Json -DateKind String })
    Check (-not @($rows | Where-Object { (Get-DispatchValue $_ 'dispatch_id') -eq $second.dispatch_id })[0].independent_acceptance -and -not (Get-Content $acceptance.provenance_path -Raw | ConvertFrom-Json).independent_acceptance) 'earlier immutable PASS never overrides later provenance downgrade'
    $legacy=[ordered]@{};foreach($key in $acceptance.Keys) { if($key -notin @('dispatch_id','provenance_path')) { $legacy[$key]=$acceptance[$key] } }; $legacy | ConvertTo-Json -Compress -Depth 20 | Set-Content $acceptPath
    $null=Update-RouterOutcomes -SourcesPath $sources
    Check (@(Get-Content $ledger | Where-Object { $_ -match 'fixture-run:M01:2' }).Count -eq 0) 'legacy acceptance cannot add duplicate attempt'
    Set-RouterDispatchAcceptance -ProvenancePath $acceptance.provenance_path -DispatchId $second.dispatch_id -Accepted $true
    $acceptance.downgrade_status='downgraded';$acceptance.accepted=$true;$acceptance | ConvertTo-Json -Compress -Depth 20 | Set-Content $acceptPath
    $downgradeRun=Join-Path $repo '.dt-build/downgrade-run'; [void][IO.Directory]::CreateDirectory($downgradeRun)
    Copy-Item $acceptPath (Join-Path $downgradeRun 'acceptance-rows.jsonl')
    $null=Update-RouterOutcomes -SourcesPath $sources
    $rows=@(Get-Content $ledger | ForEach-Object { $_ | ConvertFrom-Json -DateKind String })
    Check (-not @($rows | Where-Object { (Get-DispatchValue $_ 'dispatch_id') -eq $second.dispatch_id })[0].independent_acceptance) 'downgraded PASS does not become accepted'
    Check ([IO.File]::ReadAllText($ledger).StartsWith($bench)) 'keyless bench bytes and order survive full rewrite'
    $legacyRun=Join-Path $repo '.dt-build/legacy-run'; [void][IO.Directory]::CreateDirectory($legacyRun)
    $outside=$base.Clone();$outside.OutputPath=Join-Path $temp 'outside-legacy.md';$outside.Attempt=2;$outside.LogicalTaskId='legacy-run:m01-build'
    $outsideRow=Invoke-RouterDispatch $outside $real
    $legacy | ConvertTo-Json -Compress -Depth 20 | Set-Content (Join-Path $legacyRun 'acceptance-rows.jsonl')
    $null=Update-RouterOutcomes -SourcesPath $sources
    Check (@(Get-Content $ledger | Where-Object { $_ -match 'legacy-run:M01:2' }).Count -eq 0) 'legacy acceptance stays unknown for correlated provenance outside the run folder'
    $future=(Get-Date).AddDays(121)
    $null=Update-RouterOutcomes -SourcesPath $sources -Now $future
    $archive=@(Get-ChildItem (Join-Path $env:DT_MODEL_ROUTER_STATE '_archive') -File -Filter 'outcomes-*.jsonl')
    Check ($archive.Count -eq 1) 'aged provenance archives once'
    $archiveHash=(Get-FileHash $archive[0].FullName).Hash; $archiveTime=$archive[0].LastWriteTimeUtc; $ledgerTime=(Get-Item $ledger).LastWriteTimeUtc
    $repeat=Update-RouterOutcomes -SourcesPath $sources -Now $future.AddDays(1)
    Check ($repeat.new_records -eq 0 -and @(Get-ChildItem (Join-Path $env:DT_MODEL_ROUTER_STATE '_archive') -File).Count -eq 1 -and (Get-FileHash $archive[0].FullName).Hash -eq $archiveHash -and (Get-Item $archive[0].FullName).LastWriteTimeUtc -eq $archiveTime -and (Get-Item $ledger).LastWriteTimeUtc -eq $ledgerTime) 'aged rows are not reimported next day; ledger and archive untouched'
    . (Join-Path $PSScriptRoot 'dispatch-repair-a3-cases.ps1')
    . (Join-Path $PSScriptRoot 'dispatch-repair-a4-cases.ps1')
    }
    if (-not $A6Only) { . (Join-Path $PSScriptRoot 'dispatch-repair-a5-cases.ps1') }
    . (Join-Path $PSScriptRoot 'dispatch-repair-a6-cases.ps1')
    "SUMMARY: $checks real-wrapper checks; fake CLIs only"
} finally {
    Exit-RouterTestCodexHome $fixture
    foreach($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
    if([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetTempPath())) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
