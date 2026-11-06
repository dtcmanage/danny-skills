# Real wrapper lanes: entry points, fallback, frontier reservations, model names, identity and redaction.
# Runs inside test-dispatch-real-wrappers.ps1's isolated fixture scope; every launch uses the fake CLI.
$env:M04_FAKE_MODE=''; $env:M04_FAKE_REPORT=''
Remove-Item (Join-Path $env:DT_MODEL_ROUTER_STATE 'vendor-blocks.json') -ErrorAction SilentlyContinue
# Real directory junction: exercise both installed wrapper entry points.
$junction=Join-Path $temp 'installed/dt-build'; [void][IO.Directory]::CreateDirectory((Split-Path -Parent $junction))
New-Item -ItemType Junction -Path $junction -Target (Join-Path $env:M04_REPO_ROOT 'skills/dt-build') | Out-Null
try {
    foreach($lane in 'claude','codex') {
        $a=@{ProjectPath=$repo;PromptPath=$prompt;OutputPath=(Join-Path $temp "junction-$lane.md");Category='routine-coding';Effort='medium';SelectionReason='junction startup fixture';AdHoc=$true;ReadOnly=$true;Json=$true}
        $a[$lane+'CliPath']=Join-Path $fixture.root 'dispatch-fake-cli.ps1'
        & (Join-Path $junction "scripts/invoke-$lane-chunk.ps1") @a | Out-Null
        $jr=Read-Evidence $a.OutputPath
        Check ($jr.execution_result -eq 'success' -and $jr.lane -eq $lane) "real junction $lane startup and execution"
    }
} finally { (Get-Item -LiteralPath $junction).Delete() }
# A real failed preflight must not poison any subsequent ledger update.
$env:M04_FAKE_REPORT=Join-Path $temp 'preflight-bad.txt'; [IO.File]::WriteAllText($env:M04_FAKE_REPORT,'NOT OK')
foreach($lane in 'claude','codex') {
    $a=@{ProjectPath=$repo;OutputPath=(Join-Path $temp "preflight-$lane.md");Category='routine-coding';Preflight=$true;ReadOnly=$true;Json=$true;Scrutiny=$true}
    $a[$lane+'CliPath']=Join-Path $fixture.root 'dispatch-fake-cli.ps1'
    Reject { & (Join-Path $env:M04_REPO_ROOT "skills/dt-build/scripts/invoke-$lane-chunk.ps1") @a } "PREFLIGHT_FAIL"
    $u=Update-RouterOutcomes -SourcesPath $sources
    Check ($null -ne $u) "real $lane failed preflight allows later update"
}
$env:M04_FAKE_REPORT=''
# Default production invoker, with wrapper launch shims only at fixture paths.
$shimDir=Join-Path $temp 'wrapper-shims'; [void][IO.Directory]::CreateDirectory($shimDir)
foreach($lane in 'claude','codex') {
    $wrapperSource=Join-Path $env:M04_REPO_ROOT "skills/dt-build/scripts/invoke-$lane-chunk.ps1"
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($wrapperSource,[ref]$null,[ref]$null)
    $scriptText=$ast.ParamBlock.Extent.Text+"`n"+'& '''+(Join-Path $env:M04_REPO_ROOT "skills/dt-build/scripts/invoke-$lane-chunk.ps1")+''' -'+$lane+'CliPath '''+(Join-Path $fixture.root 'dispatch-fake-cli.ps1')+''' @PSBoundParameters'
    [IO.File]::WriteAllText((Join-Path $shimDir "invoke-$lane-chunk.ps1"),$scriptText)
}
$public=New-RouterWrapperInvoker -WrapperDirectory $shimDir
$env:M04_FAKE_MODE='claude-incident';$o=$base.Clone();$o.AllowOutputInProject=$true;$o.OutputPath=Join-Path $repo 'public-fallback.md'
$roster.jobs.coder.first_vendor='claude';$roster.jobs.coder.first='claude-opus-5-5';$roster.jobs.coder.backup_vendor='codex';$roster.jobs.coder.backup='gpt-6.1-sol'
$roster | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json')
$r=Invoke-RouterDispatch $o $public
Check ($r.execution_result -eq 'success' -and $r.actual_model -like 'gpt-*' -and $r.requested_model -like 'claude-*') 'default invoker Claude-to-Codex fallback preserves output permission'
# Explicit lane prevents cross-family fallback and records why it stopped.
Remove-Item (Join-Path $env:DT_MODEL_ROUTER_STATE 'vendor-blocks.json') -ErrorAction SilentlyContinue
$o.Lane='claude';$r=Invoke-RouterDispatch $o $public
Check ($r.lane -eq 'claude' -and $null -eq $r.fallback_reason -and $r.fallback_refusal -match 'Explicit -Lane' -and $r.execution_result -eq 'failure') 'explicit lane refuses cross-family fallback with evidence'
$env:M04_FAKE_MODE=''
Remove-Item (Join-Path $env:DT_MODEL_ROUTER_STATE 'vendor-blocks.json') -ErrorAction SilentlyContinue
# A failing backup must replace the original finished row with the backup failure.
$broken={param($Vendor,$Arguments) if($Vendor -eq 'codex'){throw 'fixture backup refusal'}; & $real $Vendor $Arguments}
$env:M04_FAKE_MODE='claude-incident';$o.Remove('Lane');$r=Invoke-RouterDispatch $o $broken
Check ($r.failure_category -eq 'tooling' -and $r.termination_reason -match 'fixture backup refusal' -and $r.fallback_reason) 'backup refusal recorded on finished dispatch'
$env:M04_FAKE_MODE=''
Remove-Item (Join-Path $env:DT_MODEL_ROUTER_STATE 'vendor-blocks.json') -ErrorAction SilentlyContinue
# Refusal before CLI launch releases a frontier reservation; documented two-stage
# resolve then wrapper handoff launches once with the request id.
$roster.jobs.coder.first_vendor='codex';$roster.jobs.coder.first='gpt-6.1-sol';$roster.jobs.coder.backup_vendor='claude';$roster.jobs.coder.backup='claude-opus-5-5'
$roster | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json')
$request=Join-Path $frontier 'handoff.json'
@{id='handoff';category='complex-coding';status='approved';proposed_model='gpt-6-astra';proposed_effort='high';approved_model='gpt-6-astra';decided_at='2026-11-05T12:00:00Z'} | ConvertTo-Json | Set-Content $request
$o=$base.Clone();$o.Category='complex-coding';$o.Model='gpt-6-astra';$o.FrontierRequest='handoff';$o.AdHoc=$false
$before=[IO.File]::ReadAllText($env:M04_FAKE_ARGS);$r=Invoke-RouterDispatch $o $real
Check ((Get-Content $request -Raw | ConvertFrom-Json).status -eq 'approved' -and [IO.File]::ReadAllText($env:M04_FAKE_ARGS) -ceq $before) 'wrapper validation refusal never burns frontier approval'
$pick=Resolve-RouterModel -Category complex-coding -FrontierRequest handoff
$a=@{ProjectPath=$repo;PromptPath=$prompt;OutputPath=(Join-Path $temp 'handoff.md');Category='complex-coding';Effort='high';SelectionReason='approved handoff fixture';AdHoc=$true;ReadOnly=$true;Model=$pick.model;FrontierRequest='handoff';CodexCliPath=(Join-Path $fixture.root 'dispatch-fake-cli.ps1');Json=$true}
& (Join-Path $env:M04_REPO_ROOT 'skills/dt-build/scripts/invoke-codex-chunk.ps1') @a | Out-Null
Check ((Read-Evidence $a.OutputPath).execution_result -eq 'success') 'documented reserved frontier handoff launches fake CLI'
Reject { & (Join-Path $env:M04_REPO_ROOT 'skills/dt-build/scripts/invoke-codex-chunk.ps1') @a } 'FRONTIER_REQUEST_USED'
# Older-generation override and run pin preserve the catalog warning.
$o=$base.Clone();$o.Model='gpt-5.6-sol';$o.Lane='codex';$emitted=@(Invoke-RouterDispatch $o $real 3>&1);$warning=@($emitted | Where-Object { $_ -is [System.Management.Automation.WarningRecord] });$r=@($emitted | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[-1]
Check ($r.actual_model -eq 'gpt-5.6-sol' -and ($warning -join ' ') -match 'older generation') 'known older override runs with older-generation warning'
$env:DT_BUILD_RUN_PIN_VENDOR='codex';$env:DT_BUILD_RUN_PIN_MODEL='gpt-5.6-sol'
try {
    $a=@{ProjectPath=$repo;PromptPath=$prompt;OutputPath=(Join-Path $temp 'pin.md');Category='routine-coding';Effort='medium';SelectionReason='run pin fixture';AdHoc=$true;ReadOnly=$true;CodexCliPath=(Join-Path $fixture.root 'dispatch-fake-cli.ps1');Json=$true}
    & (Join-Path $env:M04_REPO_ROOT 'skills/dt-build/scripts/invoke-codex-chunk.ps1') @a | Out-Null
    Check ((Read-Evidence $a.OutputPath).actual_model -eq 'gpt-5.6-sol') 'known older-generation run pin still works'
} finally { Remove-Item Env:DT_BUILD_RUN_PIN_VENDOR,Env:DT_BUILD_RUN_PIN_MODEL -ErrorAction SilentlyContinue }
# Unknown telemetry remains null even if the correlated rollout is locked.
$id=[guid]::NewGuid().ToString();$locked=Join-Path $env:DT_MODEL_ROUTER_CODEX_SESSIONS "rollout-2026-11-05T00-00-00-$id.jsonl"
[IO.File]::WriteAllText($locked,'{}');$lock=[IO.File]::Open($locked,'Open','ReadWrite','None')
try { $telemetry=Read-RouterCodexExecutionEvidence -Stream "session id: $id" -Project $repo; Check ($null -eq $telemetry.model -and $null -eq $telemetry.usage) 'locked rollout remains unknown without failing execution' } finally { $lock.Dispose() }
foreach($mode in @(@{AdHoc=$true;ReadOnly=$false;Tools='Bash,Read,Edit,Write,Glob,Grep,WebSearch,WebFetch'},@{AdHoc=$false;ReadOnly=$true;Tools='Bash,Read,Glob,Grep'})) {
    $a=@{ProjectPath=$repo;PromptPath=$prompt;OutputPath=(Join-Path $temp 'tools.md');Category='routine-coding';Effort='medium';SelectionReason='tool fixture';AdHoc=$mode.AdHoc;ReadOnly=$mode.ReadOnly;ClaudeCliPath=(Join-Path $fixture.root 'dispatch-fake-cli.ps1');Json=$true}
    if(-not $mode.AdHoc){
        [IO.File]::WriteAllText($prompt,"RUN_ID: tools`nchunk_id: tools-build`nattempt: 1`nfixture")
        $env:M04_FAKE_REPORT=Join-Path $temp 'tools-report.md'
        [IO.File]::WriteAllText($env:M04_FAKE_REPORT,"DT_BUILD_REPORT_VERSION: 3`nRUN_ID: tools`nchunk_id: tools-build`nattempt: 1`nVERDICT:`nPASS`nCHANGED_FILES:`nNONE`nCOMMANDS_AND_RESULTS:`nNONE`nEVIDENCE_PATHS:`nNONE`nUNRESOLVED_BLOCKERS:`nNONE`nDISCOVERED_ENHANCEMENTS:`nNONE`nCONTINUATION_STATE:`nNONE`n")
    }
    & (Join-Path $env:M04_REPO_ROOT 'skills/dt-build/scripts/invoke-claude-chunk.ps1') @a | Out-Null
    Check ((Read-Evidence $a.OutputPath).tools -eq $mode.Tools) "Claude exact tools ad hoc $($mode.AdHoc), read only $($mode.ReadOnly)"
}
$env:M04_FAKE_MODE=''; $env:M04_FAKE_REPORT=''
Remove-Item (Join-Path $env:DT_MODEL_ROUTER_STATE 'vendor-blocks.json') -ErrorAction SilentlyContinue
$laneCaseState=$env:DT_MODEL_ROUTER_STATE
$laneCasePrompt=[IO.File]::ReadAllText($prompt)
try {
    # Public command and direct adapter derive one identity across worktrees.
    Reset-SourceRootState 'task-identity'
    $linked=Join-Path $temp 'task-identity-linked'
    & git -C $repo worktree add -qb task-identity-branch $linked 2>$null
    $firstIdentity=$null
    foreach($attemptNumber in 1,2) {
        [IO.File]::WriteAllText($prompt,"RUN_ID: fixture-identity`nchunk_id: fixture-build`nattempt: $attemptNumber`nfixture")
        $env:M04_FAKE_REPORT=Join-Path $temp 'task-identity-report.md'
        [IO.File]::WriteAllText($env:M04_FAKE_REPORT,"DT_BUILD_REPORT_VERSION: 3`nRUN_ID: fixture-identity`nchunk_id: fixture-build`nattempt: $attemptNumber`nVERDICT:`nPASS`nCHANGED_FILES:`nNONE`nCOMMANDS_AND_RESULTS:`nNONE`nEVIDENCE_PATHS:`nNONE`nUNRESOLVED_BLOCKERS:`nNONE`nDISCOVERED_ENHANCEMENTS:`nNONE`nCONTINUATION_STATE:`nNONE`n")
        $a=New-FakeCliWrapperArguments "task-identity-$attemptNumber";$a.Remove('AdHoc');$a.Attempt=$attemptNumber
        if($attemptNumber -eq 1){$a.Lane='codex';$r=Invoke-RouterDispatch $a $real;$firstIdentity=$r}
        else{$a.ProjectPath=$linked;Invoke-FakeCliWrapper 'codex' $a;$r=Read-Evidence $a.OutputPath}
        Set-RouterDispatchAcceptance ($a.OutputPath+'.provenance.json') $r.dispatch_id ($attemptNumber -eq 2)
    }
    $u=Update-RouterOutcomes -SourcesPath $sources
    Check ($r.logical_task_id -eq 'fixture-identity:fixture-build' -and $r.logical_task_id -eq $firstIdentity.logical_task_id -and $u.first_attempt.total -eq 1 -and $u.first_attempt.accepted -eq 0 -and $u.first_attempt.retries -eq 1) 'task identity: automatic headers link public/direct worktrees first attempt 0/1 one retry'
    $env:M04_FAKE_REPORT=''
    # Identical filenames and pasted headers do not alias ad hoc tasks.
    Reset-SourceRootState 'task-paths'; $ids=@()
    foreach($folder in 'one','two') {
        $p=Join-Path $temp "task-paths-$folder/prompt.md";[void][IO.Directory]::CreateDirectory((Split-Path -Parent $p));[IO.File]::WriteAllText($p,'RUN_ID: fixture-identity' + "`nchunk_id: fixture-build")
        $a=New-FakeCliWrapperArguments "task-paths-$folder";$a.PromptPath=$p;Invoke-FakeCliWrapper 'claude' $a;$ids+=(Read-Evidence $a.OutputPath).logical_task_id
    }
    Check ($ids[0] -ne $ids[1] -and $ids[0] -like 'adhoc:*' -and $ids[1] -like 'adhoc:*' -and $ids -notcontains 'fixture-identity:fixture-build') 'task identity: full prompt paths isolate ad hoc tasks and ignore pasted headers'
    $a=New-FakeCliWrapperArguments 'task-paths-explicit';$a.LogicalTaskId='explicit-wins';Invoke-FakeCliWrapper 'codex' $a
    Check ((Read-Evidence $a.OutputPath).logical_task_id -eq 'explicit-wins') 'task identity: explicit logical identity wins'
    # Refreshed catalog, both adapters, plus all special refusal classes.
    Reset-SourceRootState 'model-names'
    foreach($modelName in @(@((Get-Content (Join-Path $env:CODEX_HOME 'models_cache.json') -Raw | ConvertFrom-Json).models.slug | Where-Object { $_ -ne 'gpt-6-astra' }) + @('claude-opus-4-8','claude-opus-5-5-20261105[1m]','claude-sonnet-4-5-20250929[1m]','claude-haiku-4-5'))) {
        $lane=if($modelName -like 'claude-*'){'claude'}else{'codex'}
        $a=New-FakeCliWrapperArguments ('model-names-'+$lane);$a.Model=$modelName;Invoke-FakeCliWrapper $lane $a
        Check ((Read-Evidence $a.OutputPath).actual_model -eq $modelName) "model names: $lane known name $modelName"
    }
    foreach($modelName in @('gpt-reserve','codex-auto-review','gpt-7-sol','gpt-6.1-astra','gpt-6-astra','claude-fable-5-2','claude-3-opus-20240229')) {
        foreach($lane in 'claude','codex') {
            $before=[IO.File]::ReadAllText($env:M04_FAKE_ARGS)
            $a=New-FakeCliWrapperArguments 'model-names-refused';$a.Model=$modelName
            Reject { Invoke-FakeCliWrapper $lane $a } 'FRONTIER_REQUEST_REQUIRED'
            Check ([IO.File]::ReadAllText($env:M04_FAKE_ARGS) -ceq $before) "model names: $lane refused $modelName without launch"
        }
    }
    # A caller-supplied resolution naming an unmappable model never launches.
    foreach ($lane in 'claude','codex') {
        Reset-EmptySourcesState "$lane-caller-pick"
        $o=$base.Clone(); $o.OutputPath=Join-Path $temp "$lane-caller.md"
        $o.Effort='medium'
        $o.RouterResolution=[pscustomobject]@{status='ok';model=$(if ($lane -eq 'claude'){'claude-fable-5-2'}else{'gpt-7-sol'});vendor=$lane;effort='medium'}
        $o[$lane+'CliPath']=Join-Path $fixture.root 'dispatch-fake-cli.ps1'; $o.Remove('Lane')
        $before=[IO.File]::ReadAllText($env:M04_FAKE_ARGS)
        Reject { & (Join-Path $env:M04_REPO_ROOT "skills/dt-build/scripts/invoke-$lane-chunk.ps1") @o | Out-Null } 'FRONTIER_REQUEST_REQUIRED'
        Check ([IO.File]::ReadAllText($env:M04_FAKE_ARGS) -ceq $before) "model names: $lane unmappable caller resolution never launches"
    }
    # Reservations are distinct from real launches, which stay spent.
    foreach($lane in 'codex','claude') {
        Reset-SourceRootState "frontier-reservation-$lane"
        $rRoster=Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json') -Raw | ConvertFrom-Json
        $rRoster.jobs.coder.first_vendor=$lane;$rRoster.jobs.coder.first=if($lane -eq 'codex'){'gpt-6.1-sol'}else{'claude-opus-5-5'}
        $rRoster.jobs.coder.backup_vendor=if($lane -eq 'codex'){'claude'}else{'codex'};$rRoster.jobs.coder.backup=if($lane -eq 'codex'){'claude-opus-5-5'}else{'gpt-6.1-sol'}
        $rRoster | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json')
        $frontierDir=Join-Path $env:DT_MODEL_ROUTER_STATE 'frontier-requests';[void][IO.Directory]::CreateDirectory($frontierDir)
        $frontierModel=if($lane -eq 'codex'){'gpt-6-astra'}else{'claude-fable-5-1'}
        $req=@{id='reservation';category='complex-coding';status='approved';proposed_model=$frontierModel;proposed_effort='high';approved_model=$frontierModel;decided_at='2026-11-05T12:00:00Z'}
        $reqPath=Join-Path $frontierDir 'reservation.json'
        $req | ConvertTo-Json | Set-Content $reqPath
        $a=New-FakeCliWrapperArguments 'frontier-bad-output';$a.Category='complex-coding';$a.Model=$frontierModel;$a.FrontierRequest='reservation';$a.OutputPath=Join-Path $prompt 'cannot-write.md'
        $before=[IO.File]::ReadAllText($env:M04_FAKE_ARGS)
        Reject { Invoke-RouterDispatch $a $real } 'directory|file|path'
        Check ((Get-Content $reqPath -Raw | ConvertFrom-Json).status -eq 'approved' -and [IO.File]::ReadAllText($env:M04_FAKE_ARGS) -ceq $before) "frontier reservation: $lane bad output releases reservation without launch"
        $a.OutputPath=Join-Path $temp "frontier-retry-$lane.md";$r=Invoke-RouterDispatch $a $real
        Check ($r.execution_result -eq 'success') "frontier reservation: $lane retry launches successfully"
        $req.status='used';$req | ConvertTo-Json | Set-Content $reqPath
        $direct=$a.Clone();$direct.Remove('FrontierRequest');$direct.FrontierRequest='reservation'
        Reject { Invoke-FakeCliWrapper $lane $direct } 'FRONTIER_REQUEST_USED'
        $forged=New-FakeCliWrapperArguments 'frontier-forged';$forged.Category='complex-coding';$forged.RouterResolution=[pscustomobject]@{status='ok';model=$frontierModel;vendor=$lane;effort='high';difficulty='hard'}
        Reject { Invoke-FakeCliWrapper $lane $forged } 'FRONTIER_REQUEST_REQUIRED'
        foreach($mode in 'incident','unexplained') {
            $req.status='approved';$req | ConvertTo-Json | Set-Content $reqPath
            Remove-Item (Join-Path $env:DT_MODEL_ROUTER_STATE 'vendor-blocks.json'),(Join-Path $env:DT_MODEL_ROUTER_STATE 'vendor-status-cache.json') -ErrorAction SilentlyContinue
            $env:M04_FAKE_MODE=if($lane -eq 'claude' -and $mode -eq 'incident'){'claude-incident'}else{$mode}
            if($mode -eq 'unexplained') {
                $healthy=Join-Path $temp 'frontier-healthy-seams.ps1'
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
                Check (@(Get-Content $env:M04_FAKE_ARGS).Count -eq ($beforeCount+1) -and $r.execution_result -eq 'failure' -and $r.failure_category -and $r.termination_reason -notmatch 'FRONTIER_REQUEST_USED') "frontier reservation: $lane $mode one launch preserves real failure"
                if($mode -eq 'incident'){Check ($r.termination_reason -match 'ROUTER_VENDOR_INCIDENT') "frontier reservation: $lane incident cause retained"}else{Check ($r.termination_reason -match 'SINGLE_DISPATCH_REFUSED: unexplained') "frontier reservation: $lane unexplained cause retained"}
                Check ([bool](Get-Content $reqPath -Raw | ConvertFrom-Json).launched_dispatch_id) "frontier reservation: $lane $mode launched approval stays spent"
                Reject { Invoke-FakeCliWrapper $lane $direct } 'FRONTIER_REQUEST_USED'
            } finally { if($mode -eq 'unexplained'){$env:DT_BUILD_DISPATCH_SEAMS=$originalSeam} }
        }
        $env:M04_FAKE_MODE=''
    }
    Check (-not (Assert-RouterDispatchPick -Resolution ([pscustomobject]@{model='gpt-image-2'}))) 'frontier reservation: approved gpt-image-2 outside ladder unaffected'

    # The one publication sink redacts stderr, job sidecar and stored evidence.
    Reset-SourceRootState 'redaction'
    $jobDir=Join-Path $temp 'redaction-run/jobs/fake';[void][IO.Directory]::CreateDirectory($jobDir)
    $env:DT_JOB_DIR=$jobDir
    try {
        $a=New-FakeCliWrapperArguments 'redaction';$a.SelectionReason='token=sk-abcdefghijklmnopqrstuvwxyz123456'
        $stderr=Join-Path $temp 'redaction.stderr'
        Invoke-FakeCliWrapper 'claude' $a 2> $stderr
        $all=[IO.File]::ReadAllText($stderr)+[IO.File]::ReadAllText((Join-Path $jobDir 'model-selection.json'))+[IO.File]::ReadAllText(($a.OutputPath+'.provenance.json'))+[IO.File]::ReadAllText($ledger)
        Check ($all -notmatch 'abcdefghijklmnopqrstuvwxyz123456' -and $all -match 'REDACTED') 'redaction: no secret in stderr sidecar provenance or ledger'
    } finally { Remove-Item Env:DT_JOB_DIR -ErrorAction SilentlyContinue }
    # Absence of Claude usage survives the real parser and adapter.
    $env:M04_FAKE_MODE='unknown-usage';$a=New-FakeCliWrapperArguments 'unknown-usage';Reject { Invoke-FakeCliWrapper 'claude' $a } 'no modelUsage';$r=Read-Evidence $a.OutputPath
    Check ($r.execution_result -eq 'success' -and $null -eq $r.usage) 'usage: real Claude unknown usage stays null'
    # The public command resolves the pinned vendor even for a Claude-first job.
    $env:M04_FAKE_MODE='';$env:DT_BUILD_RUN_PIN_VENDOR='codex';$env:DT_BUILD_RUN_PIN_MODEL='gpt-6-sol'
    try {
        $a=New-FakeCliWrapperArguments 'pin-public';$a.Category='analysis';$r=Invoke-RouterDispatch $a $real
        Check ($r.execution_result -eq 'success' -and $r.actual_model -eq 'gpt-6-sol' -and $r.lane -eq 'codex') 'public Claude-first category resolves onto Codex run pin'
    } finally { Remove-Item Env:DT_BUILD_RUN_PIN_VENDOR,Env:DT_BUILD_RUN_PIN_MODEL -ErrorAction SilentlyContinue }
} finally {
    $env:DT_MODEL_ROUTER_STATE=$laneCaseState
    $env:M04_FAKE_MODE='';$env:M04_FAKE_REPORT='';$env:M04_FAKE_READER_SIGNAL=''
    [IO.File]::WriteAllText($prompt,$laneCasePrompt)
}
