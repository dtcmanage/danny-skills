# Runs in the real-wrapper fixture. No live CLI or network calls.
$env:M04_FAKE_MODE=''; $env:M04_FAKE_REPORT=''
$a5State=$env:DT_MODEL_ROUTER_STATE
$a5Roster=Get-Content (Join-Path $env:M04_REPO_ROOT 'references/model-router/default-roster.json') -Raw | ConvertFrom-Json
$a5Roster.approved=$true; $a5Roster.approved_at='2026-11-05T00:00:00Z'
function Reset-A5State([string]$Name) {
    $env:DT_MODEL_ROUTER_STATE=Join-Path $temp ('a5-'+$Name)
    [void][IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_STATE)
    $a5Roster | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json')
    $script:ledger=Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl'
    $script:sources=Join-Path $env:DT_MODEL_ROUTER_STATE 'sources.json'
    '[]' | Set-Content $sources
}
function Invoke-A5([string]$Lane,[string]$Name) {
    $o=$base.Clone(); $o.Lane=$Lane; $o.OutputPath=Join-Path $temp ($Name+'.md')
    Invoke-RouterDispatch $o $real
}
function A5-Holder([string]$Target,[string]$Signal,[int]$HoldMs) {
    $holder=Join-Path $temp 'a5-holder.ps1'
    @'
param($Target,$Signal,[int]$HoldMs)
foreach ($name in @('DT_JOB_ID','DT_JOB_DIR','DT_BUILD_COORDINATOR_ID')) { Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction SilentlyContinue }
$watch=[Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath $Signal)) { if($watch.Elapsed.TotalSeconds -gt 45){exit 2}; Start-Sleep -Milliseconds 25 }
$h=[IO.File]::Open($Target,'Open','Read',[IO.FileShare]::ReadWrite)
try { [IO.File]::WriteAllText(($Signal+'.held'),'held'); Start-Sleep -Milliseconds $HoldMs } finally { $h.Dispose() }
'@ | Set-Content $holder
    Start-Process pwsh -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-File',('"'+$holder+'"'),('"'+$Target+'"'),('"'+$Signal+'"'),$HoldMs) -RedirectStandardOutput ($Signal+'.out') -RedirectStandardError ($Signal+'.err')
}
try {
    # Deleted and malformed targets cannot poison subsequent upserts or updates.
    foreach ($lane in 'claude','codex') {
        foreach ($damage in 'deleted','malformed') {
            Reset-A5State "$lane-$damage"
            $locked=[IO.File]::Open((Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.mutex'),'OpenOrCreate','ReadWrite','None')
            try { $r=Invoke-A5 $lane "$lane-$damage" } finally { $locked.Dispose() }
            $pointer=@(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE)[0]
            $savedPointer=Get-Content $pointer.FullName -Raw | ConvertFrom-Json -Depth 40
            Check ($savedPointer.snapshot.finished_utc -and $savedPointer.snapshot.execution_result -eq 'success') "A5 $lane $damage pointer embeds finished snapshot"
            $target=$savedPointer.provenance_path
            if ($damage -eq 'deleted') { Remove-Item -LiteralPath $target } else { [IO.File]::WriteAllText($target,'{malformed') }
            $bad=Join-Path $pointer.DirectoryName 'unresolvable.txt'; $badBytes='missing-with-no-snapshot'
            [IO.File]::WriteAllText($bad,$badBytes)
            if ($damage -eq 'malformed') { $u=Update-RouterOutcomes -SourcesPath $sources; Check ($u.unresolved_count -eq 1) "A5 $lane update reports unresolved count" }
            foreach ($n in 1..3) { $next=Invoke-A5 $lane "$lane-$damage-next$n" }
            $rows=(Read-RouterOutcomeLedger $ledger).records
            Check ($rows.Count -eq 4 -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 0) "A5 $lane $damage repeated dispatches all indexed"
            Check ($rows['dispatch:'+$r.dispatch_id].evidence_source -eq 'snapshot' -and $rows['dispatch:'+$r.dispatch_id].finished_utc) "A5 $lane $damage snapshot source visible"
            $quarantine=Join-Path $env:DT_MODEL_ROUTER_STATE 'outcome-pending/unresolved/unresolvable.txt'
            Check ((Test-Path $quarantine) -and [IO.File]::ReadAllText($quarantine) -ceq $badBytes -and (Get-Content ($quarantine+'.reason.json') -Raw | ConvertFrom-Json).reason) "A5 $lane unresolved pointer bytes and reason retained"
            $u=Update-RouterOutcomes -SourcesPath $sources
            Check ($u.unresolved_count -eq 1 -and $u.total_records -eq 4) "A5 $lane unresolved pointer never blocks update"
        }
        foreach ($holdMs in 800,12500) {
            Reset-A5State "$lane-reader-$holdMs"
            $name="$lane-reader-$holdMs"; $target=Join-Path $temp ($name+'.md.provenance.json')
            $signal=Join-Path $temp ($name+'.signal')
            $reader=A5-Holder $target $signal $holdMs
            $env:M04_FAKE_READER_SIGNAL=$signal
            try {
                $watch=[Diagnostics.Stopwatch]::StartNew()
                $r=Invoke-A5 $lane $name
                $elapsed=$watch.Elapsed.TotalMilliseconds
                $raw=Get-Content $target -Raw | ConvertFrom-Json
                Check ($r.execution_result -eq 'success' -and $r.finished_utc) "A5 $lane reader $holdMs preserves successful dispatch result"
                if ($holdMs -eq 800) {
                    Check ($raw.finished_utc -and -not (Test-Path ($target+'.finished.json')) -and $elapsed -ge 700) "A5 $lane writer retries beyond fast window"
                } else {
                    Check (-not $raw.finished_utc -and (Test-Path ($target+'.finished.json')) -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 1 -and $elapsed -ge 10000 -and $elapsed -lt 20000) "A5 $lane retry exhaustion keeps finished sidecar and pending pointer"
                    # Acceptance reads the sidecar even while the original is held.
                    Set-RouterDispatchAcceptance -ProvenancePath $target -DispatchId $r.dispatch_id -Accepted $true
                    Check ((Read-RouterDispatchEvidence $target).independent_acceptance -eq $true) "A5 $lane sidecar remains independently acceptable"
                    $null=Invoke-A5 $lane ($name+'-next')
                    $rows=(Read-RouterOutcomeLedger $ledger).records
                    Check ($rows['dispatch:'+$r.dispatch_id].finished_utc -and $rows['dispatch:'+$r.dispatch_id].independent_acceptance -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 0) "A5 $lane later drain indexes retained finished record"
                }
            } finally {
                $env:M04_FAKE_READER_SIGNAL=''
                if (-not $reader.WaitForExit(20000)) { $reader.Kill(); throw 'A5 reader did not finish' }
            }
        }
        Reset-A5State "$lane-caller-pick"
        $o=$base.Clone(); $o.OutputPath=Join-Path $temp "$lane-caller.md"
        $o.Effort='medium'
        $o.RouterResolution=[pscustomobject]@{status='ok';model=$(if ($lane -eq 'claude'){'claude-fable-5-2'}else{'gpt-7-sol'});vendor=$lane;effort='medium'}
        $o[$lane+'CliPath']=Join-Path $fixture.root 'dispatch-fake-cli.ps1'; $o.Remove('Lane')
        $before=[IO.File]::ReadAllText($env:M04_FAKE_ARGS)
        Reject { & (Join-Path $env:M04_REPO_ROOT "skills/dt-build/scripts/invoke-$lane-chunk.ps1") @o | Out-Null } 'FRONTIER_REQUEST_REQUIRED'
        Check ([IO.File]::ReadAllText($env:M04_FAKE_ARGS) -ceq $before) "A5 $lane unmappable caller resolution never launches"
    }
    # Catch-all finished bookkeeping failure and the no-regression guard are
    # exercised directly after obtaining real wrapper evidence.
    Reset-A5State 'bookkeeping'
    $r=Invoke-A5 'claude' 'bookkeeping'; $target=Join-Path $temp 'bookkeeping.md.provenance.json'
    $originalWriter=(Get-Item Function:Write-RouterEvidenceJson).ScriptBlock
    try {
        function Write-RouterEvidenceJson { throw 'fixture finished writer fault' }
        $writerThrew=$false
        try { Write-RouterDispatchEvidence -Path $target -Record $r -Context $r -ExitCode 0 } catch { $writerThrew=$true }
        Check (-not $writerThrew -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 1) 'A5 finished writer exception remains best effort with pending snapshot'
        $savedState=$env:DT_MODEL_ROUTER_STATE
        $notDirectory=Join-Path $temp 'a5-not-a-state-directory'
        [IO.File]::WriteAllText($notDirectory,'file')
        $pendingThrew=$false
        try {
            $env:DT_MODEL_ROUTER_STATE=$notDirectory
            try { Write-RouterDispatchEvidence -Path $target -Record $r -Context $r -ExitCode 0 } catch { $pendingThrew=$true }
        } finally { $env:DT_MODEL_ROUTER_STATE=$savedState }
        Check (-not $pendingThrew) 'A5 failed pending write cannot escape finished bookkeeping'

    } finally { Set-Item Function:Write-RouterEvidenceJson $originalWriter }
    $row=(Read-RouterOutcomeLedger $ledger).records['dispatch:'+$r.dispatch_id]
    $started=$r | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40 -DateKind String
    $started.finished_utc=$null; $started.execution_result=$null
    [IO.File]::WriteAllText($target,($started | ConvertTo-Json -Depth 40))
    # Remove the queued terminal snapshot so it cannot mask a regressing sync.
    Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE | Remove-Item -Force
    Sync-RouterDispatchOutcome -ProvenancePath $target
    Check ((Read-RouterOutcomeLedger $ledger).records['dispatch:'+$r.dispatch_id].finished_utc -eq $row.finished_utc) 'A5 sync never regresses a finished ledger row'
    # Real canary and dispatch-event rows take the same snapshot queue after a
    # busy lock. Inject the terminal lock failure rather than waiting 30 s twice.
    $originalAdd=(Get-Item Function:Add-RouterOutcome).ScriptBlock
    try {
        function Add-RouterOutcome { param($Row) throw 'ROUTER_OUTCOME_MUTEX_TIMEOUT' }
        $addThrew=$false
        foreach ($source in 'canary','dispatch-event') {
            try { Add-RouterOutcomeBestEffort -Row ([ordered]@{key=('a5-'+$source);source=$source;at=[datetimeoffset]::UtcNow.ToString('o');pass=$false;run_id='preflight';repo='fixture';lane='claude';model=$r.actual_model;category='routine-coding';attempt=1}) } catch { $addThrew=$true }
        }
        Check (-not $addThrew -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 2) 'A5 best effort canary and event retain pending snapshots'
    } finally { Set-Item Function:Add-RouterOutcome $originalAdd }
    $null=Invoke-A5 'codex' 'drain-events'
    $rows=(Read-RouterOutcomeLedger $ledger).records
    Check ($rows.Contains('a5-canary') -and $rows.Contains('a5-dispatch-event') -and $rows['a5-canary'].evidence_source -eq 'snapshot') 'A5 next upsert drains canary and event snapshots'
    # Product guard: a harmless CLI outside the root models a failed patch.
    # Never point a test at the installed model executables.
    $outside=Join-Path $temp 'outside-cli.ps1'; $marker=Join-Path $temp 'outside-cli-started'
    [IO.File]::WriteAllText($outside,('[IO.File]::WriteAllText('''+$marker+''',''started''); exit 0'))
    $savedRoot=$env:DT_ROUTER_TEST_FAKE_CLI_ROOT
    $env:DT_ROUTER_TEST_FAKE_CLI_ROOT=$fixture.root
    try {
        foreach ($lane in 'claude','codex') {
            $o=$base.Clone(); $o.OutputPath=Join-Path $temp "$lane-guard.md"; $o[$lane+'CliPath']=$outside
            Reject { & (Join-Path $env:M04_REPO_ROOT "skills/dt-build/scripts/invoke-$lane-chunk.ps1") @o | Out-Null } 'ROUTER_TEST_FAKE_CLI_REQUIRED'
            Check (-not (Test-Path $marker)) "A5 $lane external CLI blocked before process start without retry"
            $null=Invoke-A5 $lane "$lane-inside-root"
            Check ((Read-RouterDispatchEvidence (Join-Path $temp "$lane-inside-root.md.provenance.json")).execution_result -eq 'success') "A5 $lane allowed fake CLI runs"
        }
        # Real-shape usage credentials must never reach either I/O seam.
        & {
            . (Join-Path $env:M04_REPO_ROOT 'scripts/model-router/vendor-limits.ps1')
            $script:a5NetworkCalls=0
            $script:RouterClaudeCredentialProvider={ $script:a5NetworkCalls++; [pscustomobject]@{status='available';token='fake'} }
            $script:RouterClaudeUsageFetcher={ $script:a5NetworkCalls++; throw 'NETWORK_CALL' }
            $quota=Join-Path $fixture.root 'quota-reader.py'
            [IO.File]::WriteAllText($quota, ("from pathlib import Path`nPath(" + ($marker | ConvertTo-Json -Compress) + " ).write_text('started')`n"))
            $env:DT_MODEL_ROUTER_CODEX_LIVE_COMMAND=$quota
            $claudeUsage=Get-RouterClaudeUsage; $codexUsage=Get-RouterCodexLiveUsage
            Check ($null -eq $claudeUsage -and $null -eq $codexUsage -and $null -eq (Get-RouterCodexUsage) -and $null -eq (Get-RouterCachedWeeklyUsage 'claude') -and $script:a5NetworkCalls -eq 0) 'A5 usage readers return unknown without network or CLI calls'
            Check (-not (Test-Path $marker)) 'A5 quota reader starts no CLI under fake root guard'
            Remove-Item Env:DT_MODEL_ROUTER_CODEX_LIVE_COMMAND -ErrorAction SilentlyContinue
        }
        $originalPath=$env:PATH
        try {
            $outsideDir=Join-Path $temp 'outside-bin'; [void][IO.Directory]::CreateDirectory($outsideDir)
            foreach ($lane in 'claude','codex') { Copy-Item $outside (Join-Path $outsideDir ($lane+'.ps1')) }
            $escape=Join-Path $fixture.root 'escape'
            New-Item -ItemType Junction -Path $escape -Target $outsideDir | Out-Null
            try { Reject { Assert-RouterTestCliPath -Path (Join-Path $escape 'claude.ps1') } 'ROUTER_TEST_FAKE_CLI_REQUIRED' } finally { (Get-Item $escape).Delete() }
            $env:PATH=$outsideDir+[IO.Path]::PathSeparator+$originalPath
            # A wrapper shim without its own guard proves dispatch's guard is
            # independently load-bearing. It can only write a harmless marker.
            $shimDir=Join-Path $temp 'unguarded-shims'; [void][IO.Directory]::CreateDirectory($shimDir)
            foreach ($lane in 'claude','codex') {
                $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $env:M04_REPO_ROOT "skills/dt-build/scripts/invoke-$lane-chunk.ps1"),[ref]$null,[ref]$null)
                [IO.File]::WriteAllText((Join-Path $shimDir "invoke-$lane-chunk.ps1"),($ast.ParamBlock.Extent.Text+"`n"+'[IO.File]::WriteAllText('''+$marker+''',''started'')'))
            }
            $defaultInvoker=New-RouterWrapperInvoker -WrapperDirectory $shimDir
            $o=$base.Clone(); $o.Live=$true
            foreach ($lane in 'claude','codex') { $o.Lane=$lane; Reject { Invoke-RouterDispatch $o $defaultInvoker } 'ROUTER_TEST_FAKE_CLI_REQUIRED' }
            Check (-not (Test-Path $marker)) 'A5 public dispatch refuses external CLI without retry'
        } finally { $env:PATH=$originalPath }
        $env:DT_ROUTER_TEST_FAKE_CLI_ROOT=''
        Assert-RouterTestCliPath -Path $outside
        $plain=Invoke-A5 'claude' 'guard-unset'
        Check ($plain.execution_result -eq 'success') 'A5 absent fake root preserves normal wrapper behavior'
    } finally { $env:DT_ROUTER_TEST_FAKE_CLI_ROOT=$savedRoot }

    if (-not $A5Only) {
        # Exercise the actual ordered-dictionary event and shared canary producer
        # on both lanes through the real 30-second lock timeout.
        $healthy=Join-Path $temp 'a5-healthy.ps1'
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
        $savedSeam=$env:DT_BUILD_DISPATCH_SEAMS
        try {
            $env:DT_BUILD_DISPATCH_SEAMS=$healthy
            foreach ($lane in 'claude','codex') {
                Reset-A5State "$lane-real-event-lock"
                $env:M04_FAKE_MODE='unexplained'
                $a=@{ProjectPath=$repo;Category='routine-coding';Preflight=$true;ReadOnly=$true;Scrutiny=$true;Json=$true;OutputPath=(Join-Path $temp "$lane-real-event.md")}
                $a[$lane+'CliPath']=Join-Path $fixture.root 'dispatch-fake-cli.ps1'
                $locked=[IO.File]::Open((Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.mutex'),'OpenOrCreate','ReadWrite','None')
                # Diagnosed failures return exit 1 with the real cause in provenance.
                try {
                    & (Join-Path $env:M04_REPO_ROOT "skills/dt-build/scripts/invoke-$lane-chunk.ps1") @a | Out-Null
                    $preflightExit = $LASTEXITCODE
                } finally { $locked.Dispose() }
                $preflightRecord = Read-RouterDispatchEvidence ($a.OutputPath + '.provenance.json')
                Check ($preflightExit -eq 1 -and -not $preflightRecord.pass -and $preflightRecord.preflight -and $preflightRecord.finished_utc -and $preflightRecord.execution_result -eq 'failure' -and $preflightRecord.termination_reason -eq 'ROUTER_UNEXPLAINED' -and $preflightRecord.failure_category -eq 'environment') "A5 $lane diagnosed preflight exits 1 and retains finished failure cause"
                $pending=@(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE)
                $snapshots=@($pending | ForEach-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json -Depth 40).snapshot })
                Check ($pending.Count -eq 2 -and @($snapshots | Where-Object source -eq 'canary').Count -eq 1 -and @($snapshots | Where-Object source -eq 'dispatch-event').Count -eq 1) "A5 $lane real canary and ordered event survive busy lock"
                $env:M04_FAKE_MODE=''
                $null=Invoke-A5 $lane "$lane-event-drain"
                $rows=(Read-RouterOutcomeLedger $ledger).records
                Check ($rows.Count -eq 3 -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 0) "A5 $lane real event and canary drain on next upsert"
            }
        } finally { $env:DT_BUILD_DISPATCH_SEAMS=$savedSeam; $env:M04_FAKE_MODE='' }
    }
} finally { $env:DT_MODEL_ROUTER_STATE=$a5State; $env:M04_FAKE_READER_SIGNAL='' }
