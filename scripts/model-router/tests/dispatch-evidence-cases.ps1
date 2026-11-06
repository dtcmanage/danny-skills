# Dispatch evidence: finished sidecars, pending snapshots, acceptance verdicts and the acceptance ledger.
# Runs in the real-wrapper fixture, including its focused -EvidenceOnly mode. No live CLI or network calls.
$evidenceState=$env:DT_MODEL_ROUTER_STATE
try {
    # Damage left at a reused output path cannot suppress indexing.
    foreach ($lane in 'claude','codex') {
        Reset-RosterOnlyState "sidecar-index-$lane"
        $options=$base.Clone(); $options.Lane=$lane; $options.OutputPath=Join-Path $temp "sidecar-index-$lane.md"
        $provenance=$options.OutputPath+'.provenance.json'; $sidecar=$provenance+'.finished.json'
        $sideBytes='{broken JSON'
        [IO.File]::WriteAllText($sidecar,$sideBytes)
        $r=Invoke-RouterDispatch $options $real
        $rows=(Read-RouterOutcomeLedger (Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl')).records
        Check ($rows.Contains('dispatch:'+$r.dispatch_id)) "evidence sidecar: $lane malformed sidecar dispatch produces ledger row"
        $row=$rows['dispatch:'+$r.dispatch_id]
        Check ($row.execution_result -eq 'success' -and $row.finished_utc -and $null -eq $row.independent_acceptance -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 0) "evidence sidecar: $lane finished execution indexed without acceptance or pending pointer"
        Check ([IO.File]::ReadAllText($sidecar) -ceq $sideBytes) "evidence sidecar: $lane indexing preserves malformed sidecar bytes"
    }
    # Unreadable sidecars cannot hide a healthy finished main.
    foreach ($lane in 'claude','codex') { foreach ($damage in 'malformed','locked') { foreach ($verdict in $true,$false) {
        Reset-RosterOnlyState "unreadable-sidecar-$lane-$damage-$verdict"
        $options=$base.Clone(); $options.Lane=$lane; $options.OutputPath=Join-Path $temp "unreadable-sidecar-$lane-$damage-$verdict.md"
        $r=Invoke-RouterDispatch $options $real
        $provenance=$options.OutputPath+'.provenance.json'; $sidecar=$provenance+'.finished.json'
        $sideBytes=if ($damage -eq 'malformed') { '{broken JSON' } else { $r | ConvertTo-Json -Depth 40 }
        [IO.File]::WriteAllText($sidecar,$sideBytes)
        $handle=$null
        try {
            if ($damage -eq 'locked') { $handle=[IO.File]::Open($sidecar,'Open','Read',[IO.FileShare]::None) }
            $read=$null; $failure=$null
            try { $read=Read-RouterDispatchEvidence $provenance } catch { $failure=$_.Exception.Message }
            Check (-not $failure -and (Get-DispatchValue $read 'dispatch_id') -ceq $r.dispatch_id -and (Get-DispatchValue $read 'execution_result') -eq 'success') "evidence sidecar: $lane $damage healthy main remains readable"
            $failure=$null
            try { Set-RouterDispatchAcceptance $provenance $r.dispatch_id $verdict } catch { $failure=$_.Exception.Message }
            $accepted=Get-Content -LiteralPath $provenance -Raw | ConvertFrom-Json
            $row=(Read-RouterOutcomeLedger (Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl')).records['dispatch:'+$r.dispatch_id]
            Check (-not $failure -and $null -ne $accepted.independent_acceptance -and $accepted.independent_acceptance -eq $verdict -and $null -ne $row.independent_acceptance -and $row.independent_acceptance -eq $verdict) "evidence sidecar: $lane $damage acceptance $verdict reaches main and ledger"
        } finally { if ($handle) { $handle.Dispose() } }
        Check ((Test-Path -LiteralPath $sidecar) -and [IO.File]::ReadAllText($sidecar) -ceq $sideBytes) "evidence sidecar: $lane $damage failed sidecar bytes untouched"
        # With neither file readable, keep the sidecar failure visible.
        Remove-Item -LiteralPath $provenance
        $failure=$null
        try { if ($damage -eq 'locked') { $handle=[IO.File]::Open($sidecar,'Open','Read',[IO.FileShare]::None) }; $null=Read-RouterDispatchEvidence $provenance } catch { $failure=$_.Exception.Message }
        finally { if ($handle) { $handle.Dispose(); $handle=$null } }
        Check ([bool]$failure) "evidence sidecar: $lane $damage neither readable still fails"
    } } }
    # Force the check/read race in the reader itself, without timing a process.
    $raceMain=Join-Path $temp 'sidecar-race.json'; $raceSide=$raceMain+'.finished.json'
    New-EvidenceRecord 'sidecar-race' | ConvertTo-Json | Set-Content $raceMain
    [IO.File]::WriteAllText($raceSide,'{}')
    $raceRead=$null; $raceFailure=$null
    try {
        $raceRead=& {
            function Test-Path { param([string]$LiteralPath)
                if ($LiteralPath -ceq $raceSide) { Remove-Item -LiteralPath $LiteralPath; return $true }
                Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
            }
            Read-RouterDispatchEvidence $raceMain
        }
    } catch { $raceFailure=$_.Exception.Message }
    Check (-not $raceFailure -and (Get-DispatchValue $raceRead 'dispatch_id') -ceq 'sidecar-race' -and -not (Test-Path $raceSide)) 'evidence sidecar: sidecar deleted between check and read returns main'

    # A temp public-command copy injects damage immediately before each actual
    # post-work reader. Imports and wrapper paths still point at this test tree.
    $publicSource=[IO.File]::ReadAllText((Join-Path $env:M04_REPO_ROOT 'scripts/model-router/dispatch.ps1'))
    $publicSource=$publicSource.Replace('$PSScriptRoot',("'"+(Join-Path $env:M04_REPO_ROOT 'scripts/model-router')+"'"))
    foreach ($lane in 'claude','codex') { foreach ($damage in 'malformed','locked','vanished') { foreach ($site in 'after-wrapper','exit-reader') {
        Reset-RosterOnlyState "damaged-public-$lane-$damage-$site"
        $inject=@'
$damagedSidecar=[IO.Path]::GetFullPath($OutputPath)+'.provenance.json.finished.json'
[IO.File]::WriteAllText($damagedSidecar,'{broken JSON')
if ('DAMAGE' -eq 'locked') { $script:damagedSidecarHandle=[IO.File]::Open($damagedSidecar,'Open','Read',[IO.FileShare]::None) }
if ('DAMAGE' -eq 'vanished') {
    function Test-Path { param([string]$LiteralPath)
        if ($LiteralPath -ceq $damagedSidecar) { Remove-Item -LiteralPath $LiteralPath; return $true }
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
    }
}
'@
        $inject=$inject.Replace('DAMAGE',$damage)
        $needle=if ($site -eq 'after-wrapper') { '    $row = Read-RouterDispatchEvidence -Path $path' } else { '    $evidence = Read-RouterDispatchEvidence -Path ([IO.Path]::GetFullPath($OutputPath)' }
        # after-wrapper is inside Invoke-RouterDispatch, where OutputPath is in Options.
        if ($site -eq 'after-wrapper') { $inject=$inject.Replace('$OutputPath',"`$Options['OutputPath']") }
        $source=$publicSource.Replace($needle,($inject+"`n"+$needle))
        $publicScript=Join-Path $temp "damaged-public-$lane-$damage-$site.ps1"
        [IO.File]::WriteAllText($publicScript,$source)
        $publicOut=Join-Path $temp "damaged-public-$lane-$damage-$site.md"; $log=$publicOut+'.log'
        $oldRoot=$env:DT_ROUTER_TEST_FAKE_CLI_ROOT; $env:DT_ROUTER_TEST_FAKE_CLI_ROOT=$fixture.root
        try {
            Check ((Get-Command ($lane+'.ps1')).Source -ceq (Join-Path $fixture.root ($lane+'.ps1'))) "evidence sidecar public: $lane resolves proven fake CLI"
            & pwsh -NoProfile -File $publicScript -ProjectPath $repo -Category routine-coding -PromptPath $prompt -OutputPath $publicOut -SelectionReason fixture -Lane $lane -AdHoc -ReadOnly -Scrutiny -Live *> $log
            $code=$LASTEXITCODE; $text=[IO.File]::ReadAllText($log)
        } finally { $env:DT_ROUTER_TEST_FAKE_CLI_ROOT=$oldRoot }
        $main=Get-Content ($publicOut+'.provenance.json') -Raw | ConvertFrom-Json
        Check ($code -eq 0 -and $main.execution_result -eq 'success' -and $text -notmatch 'Conversion from JSON failed|Exception calling|FAIL:') "evidence sidecar public: $lane $damage $site finishes without post-work throw"
        Set-RouterDispatchAcceptance ($publicOut+'.provenance.json') $main.dispatch_id $true
        $row=(Read-RouterOutcomeLedger (Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl')).records['dispatch:'+$main.dispatch_id]
        Check ($row.independent_acceptance -eq $true) "evidence sidecar public: $lane $damage $site verdict recorded"
    } } }
    Reset-RosterOnlyState 'pins'
    $target=Join-Path $temp 'evidence-target.json'
    $snapshot=New-EvidenceRecord 'pending-record'
    $started=New-EvidenceRecord 'pending-record'; $started.finished_utc=$null
    $started | ConvertTo-Json | Set-Content $target
    Write-RouterPendingOutcome $target $snapshot
    $pointer=@(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE)[0]
    $pending=Read-RouterPendingOutcome $pointer
    Check ($pending.finished_utc -eq $snapshot.finished_utc -and $pending.execution_result -eq 'success' -and (Get-DispatchValue $pending 'evidence_source') -eq 'snapshot') 'pending snapshot: finished snapshot beats started target'
    $replacement=New-EvidenceRecord 'another-dispatch'; $replacement | ConvertTo-Json | Set-Content $target
    $pending=Read-RouterPendingOutcome $pointer
    Check ($pending.dispatch_id -ceq $snapshot.dispatch_id -and (Get-DispatchValue $pending 'evidence_source') -eq 'snapshot') 'pending snapshot: replaced target cannot replace pointer dispatch'
    foreach ($phase in 'started','finished') {
        $main=New-EvidenceRecord 'main-dispatch'; if ($phase -eq 'started') { $main.finished_utc=$null }
        $main | ConvertTo-Json | Set-Content $target
        $replacement | ConvertTo-Json | Set-Content ($target+'.finished.json')
        $read=Read-RouterDispatchEvidence $target
        Check ($read.dispatch_id -ceq 'main-dispatch' -and $read.finished_utc -eq $main.finished_utc) "evidence sidecar: $phase rejects sidecar for another dispatch"
    }
    # Offsets intentionally reverse lexical ordering. File times do not decide.
    $main=New-EvidenceRecord 'instant'; $main.finished_utc='2026-11-05T11:00:00+02:00'
    $main | Add-Member accepted_at_utc '2026-11-05T10:30:00+02:00'
    $main.independent_acceptance=$false
    $side=New-EvidenceRecord 'instant'; $side.finished_utc='2026-11-05T09:00:00Z'
    $side | Add-Member accepted_at_utc '2026-11-05T09:01:00Z'; $side.independent_acceptance=$true
    $main | ConvertTo-Json | Set-Content $target
    $side | ConvertTo-Json | Set-Content ($target+'.finished.json')
    Check ((Read-RouterDispatchEvidence $target).independent_acceptance -eq $true) 'evidence sidecar: parsed acceptance instant selects newer sidecar over finished main'
    $main.accepted_at_utc='2026-11-05T11:02:00+02:00'; $main | ConvertTo-Json | Set-Content $target
    Check ((Read-RouterDispatchEvidence $target).independent_acceptance -eq $false) 'evidence sidecar: stale sidecar loses to newer main acceptance instant'
    $side.finished_utc='2026-11-05T09:03:00Z'; $side | ConvertTo-Json | Set-Content ($target+'.finished.json')
    Check ((Read-RouterDispatchEvidence $target).finished_utc -eq $side.finished_utc) 'evidence sidecar: newer finished instant selects later sidecar write'
    $main.finished_utc='2026-11-05T11:04:00+02:00'; $main | ConvertTo-Json | Set-Content $target
    Check ((Read-RouterDispatchEvidence $target).finished_utc -eq $main.finished_utc) 'evidence sidecar: newer finished main defeats sidecar despite lexical ordering'
    # A later finish without a verdict must not consume a verdict-bearing pointer.
    Remove-Item ($target+'.finished.json')
    $main.independent_acceptance=$null; $main | ConvertTo-Json | Set-Content $target
    $side.independent_acceptance=$false
    Write-RouterPendingOutcome $target $side
    $verdictPointer=@(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE | Where-Object Name -eq 'instant.txt')[0]
    $pointerHash=(Get-FileHash $verdictPointer.FullName).Hash
    $refused=$false
    try { $null=Read-RouterPendingOutcome $verdictPointer } catch { $refused=$_.Exception.Message -like 'ROUTER_PENDING_UNRESOLVED*' }
    Check ($refused -and (Get-FileHash $verdictPointer.FullName).Hash -ceq $pointerHash) 'evidence sidecar: verdict snapshot cannot be silently consumed by verdict-less chosen record'
    $main.finished_utc='2026-11-05T09:00:00Z'; $main.accepted_at_utc='2026-11-05T09:00:00Z'
    $main | ConvertTo-Json | Set-Content $target
    $pending=$null
    try { $pending=Read-RouterPendingOutcome $verdictPointer } catch { }
    Check ($null -ne (Get-DispatchValue $pending 'independent_acceptance') -and $pending.independent_acceptance -eq $false -and (Get-DispatchValue $pending 'evidence_source') -eq 'snapshot') 'evidence sidecar: newer acceptance snapshot beats finished target without verdict'

    Reset-RosterOnlyState 'stale-sidecar'
    $context=New-RouterDispatchContext -PromptPath $prompt -AdHoc -Project $repo -Category routine-coding -RequestedModel gpt-6.1-sol
    $stale=New-EvidenceRecord $context.dispatch_id; $stale | ConvertTo-Json | Set-Content ($target+'.finished.json')
    Write-RouterDispatchEvidence $target ([pscustomobject]@{}) $context -ExitCode 0
    $rows=(Read-RouterOutcomeLedger (Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl')).records
    Check (-not (Test-Path ($target+'.finished.json')) -and $rows.Contains('dispatch:'+$context.dispatch_id)) 'evidence sidecar: successful finished write removes stale sidecar and indexes outcome'

    # Each lane really finishes before a reader holds it beyond the 10s retry.
    foreach ($lane in 'claude','codex') { foreach ($verdict in $true,$false) {
        Reset-RosterOnlyState "$lane-$verdict"
        $options=$base.Clone(); $options.Lane=$lane; $options.OutputPath=Join-Path $temp "held-$lane-$verdict.md"
        $r=Invoke-RouterDispatch $options $real
        $provenance=$options.OutputPath+'.provenance.json'
        $signal=Join-Path $temp "held-signal-$lane-$verdict"
        $holder=Join-Path $temp 'held-acceptance-reader.ps1'
        @'
param($Target,$Signal)
foreach ($name in @('DT_JOB_ID','DT_JOB_DIR','DT_BUILD_COORDINATOR_ID')) { Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction SilentlyContinue }
$h=[IO.File]::Open($Target,'Open','Read',[IO.FileShare]::ReadWrite)
try { [IO.File]::WriteAllText($Signal,'held'); Start-Sleep -Milliseconds 14000 } finally { $h.Dispose() }
'@ | Set-Content $holder
        $reader=Start-Process pwsh -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-File',('"'+$holder+'"'),('"'+$provenance+'"'),('"'+$signal+'"')) -RedirectStandardOutput ($signal+'.out') -RedirectStandardError ($signal+'.err')
        try {
            $watch=[Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path $signal)) { if ($watch.Elapsed.TotalSeconds -gt 20) { throw 'Held reader did not open provenance' }; Start-Sleep -Milliseconds 25 }
            $before=[IO.File]::ReadAllBytes($provenance)
            $watch.Restart()
            Set-RouterDispatchAcceptance $provenance $r.dispatch_id $verdict
            Check ($watch.Elapsed.TotalSeconds -ge 10 -and (Test-Path ($provenance+'.finished.json'))) "evidence sidecar: $lane $verdict held finished file takes sidecar path"
            $read=Read-RouterDispatchEvidence $provenance
            Check ($null -ne $read.independent_acceptance -and $read.independent_acceptance -eq $verdict) "evidence sidecar: $lane $verdict held reader sees verdict"
            Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($provenance)) -ceq [Convert]::ToBase64String($before)) "evidence sidecar: $lane $verdict held main bytes preserved"
            $sideHash=(Get-FileHash ($provenance+'.finished.json')).Hash
            $rows=(Read-RouterOutcomeLedger (Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl')).records
            $row=$rows['dispatch:'+$r.dispatch_id]
            Check ($null -ne $row.independent_acceptance -and $row.independent_acceptance -eq $verdict -and $row.pass -eq $verdict -and @(Get-RouterPendingOutcomes $env:DT_MODEL_ROUTER_STATE).Count -eq 0 -and (Get-FileHash ($provenance+'.finished.json')).Hash -ceq $sideHash) "evidence sidecar: $lane $verdict ledger retains verdict and pending drains without byte loss"
        } finally { if (-not $reader.WaitForExit(20000)) { $reader.Kill(); throw 'Held reader exceeded timeout' } }
        # This is the same later-finished writer used by dispatch's fallback refusal.
        $read=Read-RouterDispatchEvidence $provenance
        Write-RouterDispatchEvidence $provenance $read $read -ExitCode 1 -ActualModel $read.actual_model -Usage $read.usage
        $later=Read-RouterDispatchEvidence $provenance
        Check ($null -ne $later.independent_acceptance -and $later.independent_acceptance -eq $verdict -and $later.accepted_at_utc -eq $read.accepted_at_utc -and -not (Test-Path ($provenance+'.finished.json'))) "evidence sidecar: $lane $verdict later finished write preserves acceptance"
    } }
    # One-milestone ledger fixture checks both rendered formats and summary modes.
    $road=Join-Path $temp 'ledger-roadmap.md'
    @'
---
schema_version: 1
source_artifact: fixture
generated_at_utc: 2026-07-12T00:00:00Z
---
## Milestones
| id | name | dependencies | chunks | verification-mode | baseline-floor | acceptance-checks | decision-basis |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| M01 | Fixture | - | chunk-m01 | machine-checkable | none | Run `pwsh -NoProfile -File tests/ledger-fixture.ps1` and capture PASS/FAIL. | fixture |
## Chunks
| chunk-slug | milestone-id | model-routing | reference-pack-entitlement |
| :-- | :-- | :-- | :-- |
| chunk-m01 | M01 | codex | contracts, glossary |
## Verification Manifest
| check-id | milestone-id | execution-scope | prerequisites | mode | procedure |
| :-- | :-- | :-- | :-- | :-- | :-- |
| chk-m01 | M01 | integration | none | machine-checkable | Run `pwsh -NoProfile -File tests/ledger-fixture.ps1` and capture PASS/FAIL. |
'@ | Set-Content $road
    [void][IO.Directory]::CreateDirectory((Join-Path $repo 'tests'))
    'Write-Output PASS' | Set-Content (Join-Path $repo 'tests/ledger-fixture.ps1')
    $run=Join-Path $temp 'ledger-run'; [void][IO.Directory]::CreateDirectory($run)
    @{milestone_id='M01';status='PASS';commit_sha=(& git -C $repo rev-parse HEAD).Trim();tests='1 fixture passed';dispatch_id='dispatch-without-path'} | ConvertTo-Json -Compress | Set-Content (Join-Path $run 'acceptance-rows.jsonl')
    foreach ($revalidate in $false,$true) {
        $outDir=Join-Path $temp "ledger-$revalidate"
        $args=@{RoadmapPath=$road;WorkingTree=$repo;OutDir=$outDir;RunFolder=$run;RunTests=$revalidate}
        $log=Join-Path $temp "ledger-$revalidate.log"
        & pwsh -NoProfile -File (Join-Path $env:M04_REPO_ROOT 'skills/dt-build/scripts/build-acceptance-ledger.ps1') @args *> $log
        $code=$LASTEXITCODE; $summary=[IO.File]::ReadAllText($log)
        $stem=if ($revalidate) {'build-acceptance-revalidation'} else {'build-acceptance-ledger'}
        $md=[IO.File]::ReadAllText((Join-Path $outDir ($stem+'.md'))); $html=[IO.File]::ReadAllText((Join-Path $outDir ($stem+'.html')))
        Check ($code -eq 0 -and $md -match '\| PASS \|' -and $md -match 'router_acceptance: unknown \(provenance_path missing\)' -and $html -match 'router_acceptance: unknown \(provenance_path missing\)' -and $summary -match 'Router acceptance: unknown for dispatch-without-path: provenance_path missing') "acceptance ledger: RunTests=$revalidate PASS has unknown note and summary"
    }
    foreach ($shape in 'foreign-main','missing-main-foreign-sidecar') { foreach ($revalidate in $false,$true) {
        $provenance=Join-Path $temp "identity-ledger-$shape-$revalidate.json"
        $foreign=New-EvidenceRecord 'foreign-dispatch'
        $foreign | ConvertTo-Json | Set-Content $(if ($shape -eq 'foreign-main') { $provenance } else { $provenance+'.finished.json' })
        @{milestone_id='M01';status='PASS';commit_sha=(& git -C $repo rev-parse HEAD).Trim();tests='1 fixture passed';dispatch_id='expected-dispatch';provenance_path=$provenance} | ConvertTo-Json -Compress | Set-Content (Join-Path $run 'acceptance-rows.jsonl')
        $outDir=Join-Path $temp "identity-ledger-$shape-$revalidate"
        $args=@{RoadmapPath=$road;WorkingTree=$repo;OutDir=$outDir;RunFolder=$run;RunTests=$revalidate}
        $log=$outDir+'.log'
        & pwsh -NoProfile -File (Join-Path $env:M04_REPO_ROOT 'skills/dt-build/scripts/build-acceptance-ledger.ps1') @args *> $log
        $code=$LASTEXITCODE; $summary=[IO.File]::ReadAllText($log)
        $stem=if ($revalidate) {'build-acceptance-revalidation'} else {'build-acceptance-ledger'}
        $md=[IO.File]::ReadAllText((Join-Path $outDir ($stem+'.md'))); $html=[IO.File]::ReadAllText((Join-Path $outDir ($stem+'.html')))
        $htmlEvidence=if ($revalidate) { $html -match 'router_acceptance: unknown \(dispatch_id mismatch\)' } else { $html -match 'DISPATCH_ACCEPTANCE_ID_MISMATCH' -and $html -match 'BLOCKED' }
        Check ($md -match 'router_acceptance: unknown \(dispatch_id mismatch\)' -and $htmlEvidence -and $summary -match 'Router acceptance: unknown for expected-dispatch: dispatch_id mismatch') "acceptance ledger: $shape RunTests=$revalidate identity mismatch has unknown note and summary"
        Check ($(if ($revalidate) { $code -eq 0 -and $md -match '\| PASS \|' } else { $code -eq 1 -and $md -match '\| BLOCKED \|' -and $md -match 'DISPATCH_ACCEPTANCE_ID_MISMATCH' })) "acceptance ledger: $shape RunTests=$revalidate retains final identity rejection"
    } }
} finally { $env:DT_MODEL_ROUTER_STATE=$evidenceState }
