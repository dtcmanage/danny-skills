# Executed inside test-dispatch-real-wrappers.ps1's isolated fixture scope.
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
