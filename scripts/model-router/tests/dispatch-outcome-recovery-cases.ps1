# Outcome recovery: execution survives a busy or damaged ledger, and pending snapshots drain later.
# Runs in the real-wrapper fixture. No live CLI or network calls.
$env:M04_FAKE_MODE=''; $env:M04_FAKE_REPORT=''
Remove-Item (Join-Path $env:DT_MODEL_ROUTER_STATE 'vendor-blocks.json') -ErrorAction SilentlyContinue
$recoveryState=$env:DT_MODEL_ROUTER_STATE
function Start-HeldProvenanceReader([string]$Target,[string]$Signal,[int]$HoldMs) {
    $holder=Join-Path $temp 'held-provenance-reader.ps1'
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
    # Neither direct lane depends on source-root discovery. Failed indexes
    # queue exactly one path and acceptance is recoverable after the mutex opens.
    foreach($lane in 'claude','codex') {
        Reset-SourceRootState "direct-index-$lane"
        $a=New-FakeCliWrapperArguments "outside-root-$lane"
        $hold=[IO.File]::Open((Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.mutex'),'OpenOrCreate','ReadWrite','None')
        try {
            Invoke-FakeCliWrapper $lane $a
            $r=Read-Evidence $a.OutputPath
            $pending=@(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE)
            Check ($r.execution_result -eq 'success' -and $r.finished_utc -and $pending.Count -eq 1 -and ([IO.File]::ReadAllText($pending[0].FullName) | ConvertFrom-Json).provenance_path -eq ($a.OutputPath+'.provenance.json') -and ([IO.File]::ReadAllText($pending[0].FullName) | ConvertFrom-Json).snapshot.finished_utc) "direct index: $lane success and one outside-root pending path under whole-run lock"
        } finally { $hold.Dispose() }
        $u=Update-RouterOutcomes -SourcesPath $sources
        Check ($u.total_records -eq 1 -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 0) "direct index: $lane update drains pointer into one row"
        Set-RouterDispatchAcceptance ($a.OutputPath+'.provenance.json') $r.dispatch_id $true
        $u=Update-RouterOutcomes -SourcesPath $sources
        Check ($u.first_attempt.accepted -eq 1 -and $u.first_attempt.total -eq 1 -and $u.total_records -eq 1) "direct index: $lane acceptance first attempt 1/1"
    }
    # An ordinary unlocked ledger reader prevents replacement on Windows.
    # Start the holder only after the fake CLI is entered, after started indexing.
    Reset-SourceRootState 'ledger-reader'
    $signal=Join-Path $temp 'ledger-reader.signal'
    $holder=Join-Path $temp 'ledger-reader.ps1'
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
    $reader=Start-Process pwsh -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-File',('"'+$holder+'"'),('"'+$ledger+'"'),('"'+$signal+'"')) -RedirectStandardOutput (Join-Path $temp 'ledger-reader.out') -RedirectStandardError (Join-Path $temp 'ledger-reader.err')
    try {
        $a=New-FakeCliWrapperArguments 'ledger-reader'
        Invoke-FakeCliWrapper 'codex' $a
        $r=Read-Evidence $a.OutputPath
        Check ($r.execution_result -eq 'success' -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 1) 'ledger reader: ledger sharing violation preserves execution and pending pointer'
    } finally {
        [IO.File]::WriteAllText(($signal+'.release'),'release')
        $env:M04_FAKE_READER_SIGNAL=''
        if (-not $reader.WaitForExit(10000)) { $reader.Kill(); throw 'ledger reader: reader failed to stop' }
    }
    # The next dispatch upsert, without a full update, also drains pending paths.
    $a=New-FakeCliWrapperArguments 'ledger-reader-next'; Invoke-FakeCliWrapper 'claude' $a
    Check (@(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 0 -and (Read-RouterOutcomeLedger $ledger).records.Count -eq 2) 'ledger reader: next upsert drains pending paths'
    # Failed preflights retain HEAD canary behavior and complete schema.
    foreach($lane in 'claude','codex') {
        Reset-SourceRootState "preflight-canary-$lane"
        $a=New-FakeCliWrapperArguments "preflight-canary-$lane"; $a.Remove('AdHoc');$a.Remove('PromptPath');$a.Preflight=$true
        $env:M04_FAKE_REPORT=Join-Path $temp 'preflight-canary-bad.txt';[IO.File]::WriteAllText($env:M04_FAKE_REPORT,'NOT OK')
        Reject { Invoke-FakeCliWrapper $lane $a } 'PREFLIGHT_FAIL'
        $rows=@(Get-Content $ledger | ForEach-Object { $_ | ConvertFrom-Json })
        Check ($rows.Count -eq 1 -and $rows[0].source -eq 'canary' -and $rows[0].run_id -eq 'preflight' -and -not $rows[0].pass) "preflight canary: $lane failed preflight exactly one canary"
        foreach($field in @('key','run_id','repo','tier','escalated','at','source','lane','model','category','attempt','pass','failure_category','diagnosis')) { Check ([bool]$rows[0].PSObject.Properties[$field]) "preflight canary: $lane complete canary field $field" }
        $env:M04_FAKE_REPORT=''; $a.OutputPath=Join-Path $script:sourceRootFolder "preflight-canary-pass-$lane.md"
        Invoke-FakeCliWrapper $lane $a
        $u=Update-RouterOutcomes -SourcesPath $sources
        Check ($u.total_records -eq 1 -and $u.new_records -eq 0 -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 0) "preflight canary: $lane passed preflight and later update add no rows"
    }
    # The real cost report reader accepts a null-workstation row.
    Reset-SourceRootState 'cost-input'
    $plainRepo=Join-Path $temp 'plain-repo';[void][IO.Directory]::CreateDirectory($plainRepo)
    & git -C $plainRepo init -q
    & git -C $plainRepo -c user.email=t@example.com -c user.name=t commit --allow-empty -qm fixture
    $a=New-FakeCliWrapperArguments 'cost-input'; $a.ProjectPath=$plainRepo
    Invoke-FakeCliWrapper 'codex' $a
    $r=Read-Evidence $a.OutputPath
    $costFixture=Join-Path $temp 'cost-input-state'
    [void][IO.Directory]::CreateDirectory($costFixture)
    $costProvenance=Join-Path $costFixture 'cost-input.provenance.json'
    Copy-Item ($a.OutputPath+'.provenance.json') $costProvenance
    $costRow=ConvertTo-DispatchOutcome $r $costProvenance
    Check (-not $costRow.PSObject.Properties['workstation'] -and $r.difficulty -and $null -eq $r.workstation) 'cost report input: real null-workstation provenance omits unknown ledger field'
    $costRow | ConvertTo-Json -Depth 40 -Compress | Set-Content (Join-Path $costFixture 'outcomes.jsonl')
    & python (Join-Path $env:M04_REPO_ROOT 'scripts/model-router/cost_report.py') --state-dir $costFixture
    Check ($LASTEXITCODE -eq 0) 'cost report input: real cost_report.py reader exit 0'
    # Deleted and malformed targets cannot poison subsequent upserts or updates.
    foreach ($lane in 'claude','codex') {
        foreach ($damage in 'deleted','malformed') {
            Reset-EmptySourcesState "$lane-$damage"
            $locked=[IO.File]::Open((Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.mutex'),'OpenOrCreate','ReadWrite','None')
            try { $r=Invoke-LaneDispatch $lane "$lane-$damage" } finally { $locked.Dispose() }
            $pointer=@(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE)[0]
            $savedPointer=Get-Content $pointer.FullName -Raw | ConvertFrom-Json -Depth 40
            Check ($savedPointer.snapshot.finished_utc -and $savedPointer.snapshot.execution_result -eq 'success') "outcome recovery: $lane $damage pointer embeds finished snapshot"
            $target=$savedPointer.provenance_path
            if ($damage -eq 'deleted') { Remove-Item -LiteralPath $target } else { [IO.File]::WriteAllText($target,'{malformed') }
            $bad=Join-Path $pointer.DirectoryName 'unresolvable.txt'; $badBytes='missing-with-no-snapshot'
            [IO.File]::WriteAllText($bad,$badBytes)
            if ($damage -eq 'malformed') { $u=Update-RouterOutcomes -SourcesPath $sources; Check ($u.unresolved_count -eq 1) "outcome recovery: $lane update reports unresolved count" }
            foreach ($n in 1..3) { $next=Invoke-LaneDispatch $lane "$lane-$damage-next$n" }
            $rows=(Read-RouterOutcomeLedger $ledger).records
            Check ($rows.Count -eq 4 -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 0) "outcome recovery: $lane $damage repeated dispatches all indexed"
            Check ($rows['dispatch:'+$r.dispatch_id].evidence_source -eq 'snapshot' -and $rows['dispatch:'+$r.dispatch_id].finished_utc) "outcome recovery: $lane $damage snapshot source visible"
            $quarantine=Join-Path $env:DT_MODEL_ROUTER_STATE 'outcome-pending/unresolved/unresolvable.txt'
            Check ((Test-Path $quarantine) -and [IO.File]::ReadAllText($quarantine) -ceq $badBytes -and (Get-Content ($quarantine+'.reason.json') -Raw | ConvertFrom-Json).reason) "outcome recovery: $lane unresolved pointer bytes and reason retained"
            $u=Update-RouterOutcomes -SourcesPath $sources
            Check ($u.unresolved_count -eq 1 -and $u.total_records -eq 4) "outcome recovery: $lane unresolved pointer never blocks update"
        }
        foreach ($holdMs in 800,12500) {
            Reset-EmptySourcesState "$lane-reader-$holdMs"
            $name="$lane-reader-$holdMs"; $target=Join-Path $temp ($name+'.md.provenance.json')
            $signal=Join-Path $temp ($name+'.signal')
            $reader=Start-HeldProvenanceReader $target $signal $holdMs
            $env:M04_FAKE_READER_SIGNAL=$signal
            try {
                $watch=[Diagnostics.Stopwatch]::StartNew()
                $r=Invoke-LaneDispatch $lane $name
                $elapsed=$watch.Elapsed.TotalMilliseconds
                $raw=Get-Content $target -Raw | ConvertFrom-Json
                Check ($r.execution_result -eq 'success' -and $r.finished_utc) "outcome recovery: $lane reader $holdMs preserves successful dispatch result"
                if ($holdMs -eq 800) {
                    Check ($raw.finished_utc -and -not (Test-Path ($target+'.finished.json')) -and $elapsed -ge 700) "outcome recovery: $lane writer retries beyond fast window"
                } else {
                    Check (-not $raw.finished_utc -and (Test-Path ($target+'.finished.json')) -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 1 -and $elapsed -ge 10000 -and $elapsed -lt 20000) "outcome recovery: $lane retry exhaustion keeps finished sidecar and pending pointer"
                    # Acceptance reads the sidecar even while the original is held.
                    Set-RouterDispatchAcceptance -ProvenancePath $target -DispatchId $r.dispatch_id -Accepted $true
                    Check ((Read-RouterDispatchEvidence $target).independent_acceptance -eq $true) "outcome recovery: $lane sidecar remains independently acceptable"
                    $null=Invoke-LaneDispatch $lane ($name+'-next')
                    $rows=(Read-RouterOutcomeLedger $ledger).records
                    Check ($rows['dispatch:'+$r.dispatch_id].finished_utc -and $rows['dispatch:'+$r.dispatch_id].independent_acceptance -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 0) "outcome recovery: $lane later drain indexes retained finished record"
                }
            } finally {
                $env:M04_FAKE_READER_SIGNAL=''
                if (-not $reader.WaitForExit(20000)) { $reader.Kill(); throw 'outcome recovery: reader did not finish' }
            }
        }
    }
    # Catch-all finished bookkeeping failure and the no-regression guard are
    # exercised directly after obtaining real wrapper evidence.
    Reset-EmptySourcesState 'bookkeeping'
    $r=Invoke-LaneDispatch 'claude' 'bookkeeping'; $target=Join-Path $temp 'bookkeeping.md.provenance.json'
    $originalWriter=(Get-Item Function:Write-RouterEvidenceJson).ScriptBlock
    try {
        function Write-RouterEvidenceJson { throw 'fixture finished writer fault' }
        $writerThrew=$false
        try { Write-RouterDispatchEvidence -Path $target -Record $r -Context $r -ExitCode 0 } catch { $writerThrew=$true }
        Check (-not $writerThrew -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 1) 'outcome recovery: finished writer exception remains best effort with pending snapshot'
        $savedState=$env:DT_MODEL_ROUTER_STATE
        $notDirectory=Join-Path $temp 'not-a-state-directory'
        [IO.File]::WriteAllText($notDirectory,'file')
        $pendingThrew=$false
        try {
            $env:DT_MODEL_ROUTER_STATE=$notDirectory
            try { Write-RouterDispatchEvidence -Path $target -Record $r -Context $r -ExitCode 0 } catch { $pendingThrew=$true }
        } finally { $env:DT_MODEL_ROUTER_STATE=$savedState }
        Check (-not $pendingThrew) 'outcome recovery: failed pending write cannot escape finished bookkeeping'

    } finally { Set-Item Function:Write-RouterEvidenceJson $originalWriter }
    $row=(Read-RouterOutcomeLedger $ledger).records['dispatch:'+$r.dispatch_id]
    $started=$r | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40 -DateKind String
    $started.finished_utc=$null; $started.execution_result=$null
    [IO.File]::WriteAllText($target,($started | ConvertTo-Json -Depth 40))
    # Remove the queued terminal snapshot so it cannot mask a regressing sync.
    Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE | Remove-Item -Force
    Sync-RouterDispatchOutcome -ProvenancePath $target
    Check ((Read-RouterOutcomeLedger $ledger).records['dispatch:'+$r.dispatch_id].finished_utc -eq $row.finished_utc) 'outcome recovery: sync never regresses a finished ledger row'
    # Real canary and dispatch-event rows take the same snapshot queue after a
    # busy lock. Inject the terminal lock failure rather than waiting 30 s twice.
    $originalAdd=(Get-Item Function:Add-RouterOutcome).ScriptBlock
    try {
        function Add-RouterOutcome { param($Row) throw 'ROUTER_OUTCOME_MUTEX_TIMEOUT' }
        $addThrew=$false
        foreach ($source in 'canary','dispatch-event') {
            try { Add-RouterOutcomeBestEffort -Row ([ordered]@{key=('snapshot-'+$source);source=$source;at=[datetimeoffset]::UtcNow.ToString('o');pass=$false;run_id='preflight';repo='fixture';lane='claude';model=$r.actual_model;category='routine-coding';attempt=1}) } catch { $addThrew=$true }
        }
        Check (-not $addThrew -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 2) 'outcome recovery: best effort canary and event retain pending snapshots'
    } finally { Set-Item Function:Add-RouterOutcome $originalAdd }
    $null=Invoke-LaneDispatch 'codex' 'drain-events'
    $rows=(Read-RouterOutcomeLedger $ledger).records
    Check ($rows.Contains('snapshot-canary') -and $rows.Contains('snapshot-dispatch-event') -and $rows['snapshot-canary'].evidence_source -eq 'snapshot') 'outcome recovery: next upsert drains canary and event snapshots'

    if (-not $RecoveryOnly) {
        # Exercise the actual ordered-dictionary event and shared canary producer
        # on both lanes through the real 30-second lock timeout.
        $healthy=Join-Path $temp 'recovery-healthy-seams.ps1'
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
                Reset-EmptySourcesState "$lane-real-event-lock"
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
                Check ($preflightExit -eq 1 -and -not $preflightRecord.pass -and $preflightRecord.preflight -and $preflightRecord.finished_utc -and $preflightRecord.execution_result -eq 'failure' -and $preflightRecord.termination_reason -eq 'ROUTER_UNEXPLAINED' -and $preflightRecord.failure_category -eq 'environment') "outcome recovery: $lane diagnosed preflight exits 1 and retains finished failure cause"
                $pending=@(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE)
                $snapshots=@($pending | ForEach-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json -Depth 40).snapshot })
                Check ($pending.Count -eq 2 -and @($snapshots | Where-Object source -eq 'canary').Count -eq 1 -and @($snapshots | Where-Object source -eq 'dispatch-event').Count -eq 1) "outcome recovery: $lane real canary and ordered event survive busy lock"
                $env:M04_FAKE_MODE=''
                $null=Invoke-LaneDispatch $lane "$lane-event-drain"
                $rows=(Read-RouterOutcomeLedger $ledger).records
                Check ($rows.Count -eq 3 -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 0) "outcome recovery: $lane real event and canary drain on next upsert"
            }
        } finally { $env:DT_BUILD_DISPATCH_SEAMS=$savedSeam; $env:M04_FAKE_MODE='' }
    }
} finally {
    $env:DT_MODEL_ROUTER_STATE=$recoveryState
    $env:M04_FAKE_MODE='';$env:M04_FAKE_REPORT='';$env:M04_FAKE_READER_SIGNAL=''
}
