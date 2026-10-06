Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../resolve-model.ps1')
$script:passed = 0
function Assert-True([bool]$Condition,[string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $script:passed++; Write-Output "PASS: $Name" }
function Read-Seed { Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 30 }
function Invoke-Approval { param([string[]]$Options) & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../approve-roster.ps1') @Options 2>&1 }
$priorState = $env:DT_MODEL_ROUTER_STATE
$priorTransport = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
$priorSessions = $env:DT_MODEL_ROUTER_CODEX_SESSIONS
$temp = Join-Path $env:TEMP ('roster-approval-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$env:DT_MODEL_ROUTER_STATE = $temp
$env:DT_MODEL_ROUTER_CODEX_SESSIONS = Join-Path $temp 'sessions'
[IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_CODEX_SESSIONS) | Out-Null
$stub = Join-Path $temp 'transport.ps1'
Set-Content -LiteralPath $stub -Value 'param($request) return [pscustomobject]@{id="stub"}'
$env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $stub
$catalog = [pscustomobject]@{models=@([pscustomobject]@{slug='gpt-6.1-sol';visibility='list'},[pscustomobject]@{slug='gpt-6-luna';visibility='list'})}
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixtureCodexHome = Enter-RouterTestCodexHome
try {
    $show = @(Invoke-Approval -Options @('-Show')) -join "`n"
    Assert-True ($show -match 'No roster proposal' -and $show -match 'Current roster') 'show without proposal'
    $null = Invoke-Approval -Options @('-Seed')
    $latest = Get-Content -LiteralPath (Join-Path $temp 'roster-proposals/latest.json') -Raw | ConvertFrom-Json
    $show = @(Invoke-Approval -Options @('-Show')) -join "`n"
    Assert-True ((Test-Path -LiteralPath $latest.proposal) -and $show -match '\| Job \| Current \| Proposed' -and $show -match 'Current roster') 'seed writes proposal and show prints report'
    $seed = Get-Content -Raw -LiteralPath $latest.proposal | ConvertFrom-Json -Depth 30
    foreach ($job in @(Get-RouterJobs)) {
        $want = @{fast='low';coder='medium';'deep-thinker'='medium';writer='medium';illustrator=$null}[$job]
        Assert-True ($seed.jobs.$job.first_effort -ceq $want -and $seed.jobs.$job.backup_effort -ceq $want) "seed fixed effort $job"
        if ($want) { Assert-True ($show -match "$job.*effort $want.*effort $want") "show both efforts $job" }
    }
    Assert-True ($show -match 'first_effort' -and $show -match 'backup_effort' -and $null -eq $seed.jobs.illustrator.first_effort -and $null -eq $seed.jobs.illustrator.backup_effort) 'show effort columns and illustrator null'
    $before = Resolve-RouterModel -Category complex-coding -SkipModelCheck -Catalog $catalog
    Assert-True ($before.roster_source -eq 'default') 'seed alone uses default roster'
    $null = Invoke-Approval -Options @('-Approve')
    $approved = Get-Content -LiteralPath (Join-Path $temp 'roster.json') -Raw | ConvertFrom-Json
    $next = Resolve-RouterModel -Category complex-coding -SkipModelCheck -Catalog $catalog
    Assert-True ($approved.approved -eq $true -and $approved.approved_at -and $next.roster_source -eq 'state') 'approve writes roster and next resolver call uses state'
    $null = Invoke-Approval -Options @('-Revoke')
    Assert-True (Test-Path -LiteralPath (Join-Path $temp 'roster.json')) 'revoke preserves roster file'
    $revoked = Get-Content -LiteralPath (Join-Path $temp 'roster.json') -Raw | ConvertFrom-Json
    Assert-True ($revoked.approved -eq $false -and (Resolve-RouterModel -Category complex-coding -SkipModelCheck -Catalog $catalog).roster_source -eq 'default') 'revoke clears approval and resolver uses default roster'
    $proposal = Read-Seed
    $proposal.jobs.fast.backup = 'claude-sonnet-5'
    $proposal.jobs.writer.backup = 'gpt-5.6-sol'
    $proposal | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $latest.proposal
    $output = @(Invoke-Approval -Options @('-Approve')) -join "`n"
    Assert-True ($LASTEXITCODE -ne 0 -and $output -match 'ROSTER_MODEL_CAP' -and (Get-Content -LiteralPath (Join-Path $temp 'roster.json') -Raw | ConvertFrom-Json).approved -eq $false) 'over-cap proposal refused with error'
    $output = @(Invoke-Approval -Options @('-Approve','-Jobs','writer')) -join "`n"
    Assert-True ($LASTEXITCODE -ne 0 -and $output -match 'ROSTER_MODEL_CAP') 'subset that exceeds cap refused with named error'
    $null = Invoke-Approval -Options @('-Approve','-Jobs','fast')
    $subset = Get-Content -LiteralPath (Join-Path $temp 'roster.json') -Raw | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $subset.approved -and $subset.jobs.fast.backup -eq 'claude-sonnet-5' -and $subset.jobs.writer.backup -eq 'gpt-6.1-sol') 'subset within cap approves only selected job'
    $output = @(Invoke-Approval -Options @('-Approve','-Jobs','fast,writer')) -join "`n"
    Assert-True ($LASTEXITCODE -ne 0 -and $output -match 'ROSTER_MODEL_CAP' -and $output -notmatch 'Unknown roster job') 'comma separated Jobs via File evaluates both selected jobs against cap'
    $proposal = Read-Seed
    $proposal.jobs.coder.first = 'unknown-model'
    $proposal | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $latest.proposal
    $output = @(Invoke-Approval -Options @('-Approve')) -join "`n"
    Assert-True ($LASTEXITCODE -ne 0 -and $output -match 'ROSTER_MODEL_VENDOR: coder/first') 'invalid non-cap proposal names model error'
    $proposal = Read-Seed
    $proposal | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $latest.proposal
    $null = Invoke-Approval -Options @('-Approve')
    @([pscustomobject]@{model='gpt-6.1-sol';job='coder';marked_at='2026-09-28T00:00:00Z'}) | ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $temp 'drift-marks.json')
    Assert-True ((Resolve-RouterModel -Category complex-coding -SkipModelCheck -Catalog $catalog).model -eq 'claude-opus-5-5') 'drift mark uses backup'
    $null = Invoke-Approval -Options @('-DeclineDrift','-Job','coder')
    Assert-True ((@(Read-RouterJsonArray -Path (Join-Path $temp 'drift-marks.json')).Count -eq 0) -and (Resolve-RouterModel -Category complex-coding -SkipModelCheck -Catalog $catalog).model -eq 'gpt-6.1-sol') 'decline drift removes mark and restores first choice'
    $declines = @(Read-RouterJsonArray -Path (Join-Path $temp 'drift-declines.json'))
    Assert-True ($declines.Count -eq 1 -and $declines[0].model -eq 'gpt-6.1-sol' -and $declines[0].job -eq 'coder' -and $declines[0].declined_at) 'decline persists model and job'
    @([pscustomobject]@{model='gpt-6.1-sol';job='coder';marked_at='2026-09-28T00:00:00Z'},[pscustomobject]@{model='gpt-6-luna';job='fast';marked_at='2026-09-28T00:00:00Z'}) | ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $temp 'drift-marks.json')
    $proposal = Read-Seed
    $proposal.jobs.coder.first = 'claude-opus-5-5'; $proposal.jobs.coder.first_vendor = 'claude'
    $proposal.jobs.coder.backup = 'gpt-6.1-sol'; $proposal.jobs.coder.backup_vendor = 'codex'
    $proposal | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $latest.proposal
    $null = Invoke-Approval -Options @('-Approve')
    $marks = @(Read-RouterJsonArray -Path (Join-Path $temp 'drift-marks.json'))
    Assert-True ($marks.Count -eq 1 -and $marks[0].job -eq 'fast') 'approval clears marks only for changed first choice'
    Assert-True (@(Read-RouterJsonArray -Path (Join-Path $temp 'drift-declines.json')).Count -eq 0) 'approval clears decline when first choice changes'
    foreach ($options in @(@('-Show','-Job','coder'),@('-Show','-Jobs','coder'))) {
        $output = @(& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../approve-roster.ps1') @options 2>&1) -join "`n"
        Assert-True ($LASTEXITCODE -ne 0 -and $output -match 'require') "ignored switch rejected: $($options -join ' ')"
    }
    $current = Read-RouterJsonObject (Join-Path $temp 'roster.json')
    $entry = $current.jobs.coder
    $digest = (Get-RouterBenchEvidenceContext).task_bank_sha256
    $tieDir = Join-Path $temp 'tie-proposals'
    [IO.Directory]::CreateDirectory($tieDir) | Out-Null
    $tiePath = Join-Path $tieDir 'coder.json'
    $tie = [pscustomobject]@{type='tie';job='coder';tier='standard';run_id='synthetic';bank_hash=$digest;status='pending';configurations=[pscustomobject]@{candidate=[pscustomobject]@{model=$entry.backup;effort=$entry.backup_effort};incumbent=[pscustomobject]@{model=$entry.first;effort=$entry.first_effort}}}
    foreach ($defect in @('model','effort','bank')) {
        $bad = $tie | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
        if ($defect -eq 'bank') { $bad.bank_hash = 'old' } else { $bad.configurations.candidate.$defect = 'changed' }
        Write-RouterJsonAtomic $tiePath $bad
        $output = @(Invoke-Approval -Options @('-ApproveTie','-Job','coder')) -join "`n"
        Assert-True ($LASTEXITCODE -ne 0 -and $output -match 'TIE_STALE_EVIDENCE' -and -not (Read-RouterJsonObject (Join-Path $temp 'roster.json')).jobs.coder.PSObject.Properties['tie_evidence']) "tie approval rejects $defect change"
    }
    Write-RouterJsonAtomic $tiePath $tie
    $null = Invoke-Approval -Options @('-ApproveTie','-Job','coder')
    $after = (Read-RouterJsonObject (Join-Path $temp 'roster.json')).jobs.coder
    Assert-True ($LASTEXITCODE -eq 0 -and $after.tie_evidence.approved_at -and $after.tie_evidence.bank_hash -ceq $digest -and $after.first -ceq $entry.first -and $after.backup -ceq $entry.backup -and $after.first_effort -ceq $entry.first_effort -and $after.backup_effort -ceq $entry.backup_effort -and (Read-RouterJsonObject $tiePath).status -ceq 'approved') 'tie approval persists evidence without changing pair'
    $shared = Read-RouterJsonObject (Join-Path (Get-RouterSharedDir) 'roster.json')
    Assert-True ($shared.jobs.coder.tie_evidence.run_id -ceq 'synthetic') 'tie approval publishes routing evidence'
    foreach ($mode in @('full','subset')) {
        $proposal = Read-RouterJsonObject (Join-Path $temp 'roster.json')
        $proposal.jobs.coder.PSObject.Properties.Remove('tie_evidence')
        Write-RouterJsonAtomic $latest.proposal $proposal
        $options = if ($mode -eq 'full') { @('-Approve') } else { @('-Approve','-Jobs','coder') }
        $null = Invoke-Approval -Options $options
        $retained = (Read-RouterJsonObject (Join-Path $temp 'roster.json')).jobs.coder
        Assert-True ($LASTEXITCODE -eq 0 -and $retained.tie_evidence.run_id -ceq 'synthetic') "$mode approval retains unchanged pair tie"
    }
    foreach ($field in @('first','backup','first_effort','backup_effort')) {
        foreach ($mode in @('full','subset')) {
            $original = Read-RouterJsonObject (Join-Path $temp 'roster.json')
            $proposal = $original | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
            if ($field -in @('first','backup')) {
                # Change only this slot, reusing an existing same-vendor model to preserve the cap.
                $proposal.jobs.coder.$field = if ($proposal.jobs.coder.("${field}_vendor") -eq 'claude') { $proposal.jobs.fast.backup } else { $proposal.jobs.fast.first }
            } else { $proposal.jobs.coder.$field = 'low'; $proposal.jobs.coder.(($field -replace '_effort$','_efforts')).standard = 'low' }
            Write-RouterJsonAtomic $latest.proposal $proposal
            $options = if ($mode -eq 'full') { @('-Approve') } else { @('-Approve','-Jobs','coder') }
            $null = Invoke-Approval -Options $options
            Assert-True ($LASTEXITCODE -eq 0 -and -not (Read-RouterJsonObject (Join-Path $temp 'roster.json')).jobs.coder.PSObject.Properties['tie_evidence']) "$mode approval drops tie on $field change"
            Write-RouterJsonAtomic (Join-Path $temp 'roster.json') $original
        }
    }
    $null = Invoke-Approval -Options @('-RevokeTie','-Job','coder')
    Assert-True ($LASTEXITCODE -eq 0 -and -not (Read-RouterJsonObject (Join-Path $temp 'roster.json')).jobs.coder.PSObject.Properties['tie_evidence'] -and (Read-RouterJsonObject $tiePath).status -ceq 'revoked') 'revoke removes tie evidence'
    $tie.bank_hash = 'obsolete'; Write-RouterJsonAtomic $tiePath $tie
    $before = [IO.File]::ReadAllText((Join-Path $temp 'roster.json'))
    $null = Invoke-Approval -Options @('-DeclineTie','-Job','coder')
    Assert-True ($LASTEXITCODE -eq 0 -and (Read-RouterJsonObject $tiePath).status -ceq 'declined' -and [IO.File]::ReadAllText((Join-Path $temp 'roster.json')) -ceq $before) 'decline persists even stale tie without roster change'
    # M04: quality evidence is bound to the exact run, tier and configurations.
    . (Join-Path $PSScriptRoot 'fixtures/bench-proposal-evidence.ps1')
    Initialize-TestBenchEvidence
    $qualityRoster=Read-Seed;$qualityRoster.approved=$true;$qualityRoster.approved_at='2026-10-05T12:00:00Z'
    $qualityContext=Get-RouterBenchEvidenceContext
    $basis=New-RouterBenchProposalEvidence -Job coder -Bench ([pscustomobject]@{task_bank_sha256=$qualityContext.task_bank_sha256;judge_pair=$qualityContext.judge_pair;judge_effort=$qualityContext.judge_effort})
    $runDir=Join-Path $temp 'bench/runs/quality-test';[void][IO.Directory]::CreateDirectory($runDir)
    foreach($kind in @('swap','effort','tie')) {
        Write-RouterJsonAtomic (Join-Path $temp 'roster.json') $qualityRoster
        $entry=$qualityRoster.jobs.coder
        $configs=if($kind -eq 'effort'){
            [pscustomobject]@{candidate=[pscustomobject]@{model=$entry.first;effort='high'};incumbent=[pscustomobject]@{model=$entry.first;effort='medium'}}
        } elseif($kind -eq 'tie'){
            [pscustomobject]@{candidate=[pscustomobject]@{model=$entry.backup;effort='medium'};incumbent=[pscustomobject]@{model=$entry.first;effort='medium'}}
        } else {
            [pscustomobject]@{candidate=[pscustomobject]@{model=$qualityRoster.jobs.fast.first;effort='medium'};incumbent=[pscustomobject]@{model=$entry.first;effort='medium'}}
        }
        $value=if($kind -eq 'effort'){'candidate_better'}else{'no_difference'}
        $record=[pscustomobject]@{job='coder';tier='standard';verdict=$value;configurations=$configs;run_id='quality-test'}
        $verdict=$record | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        $verdict | Add-Member -NotePropertyName tasks -NotePropertyValue @([pscustomobject]@{candidate_wins=$(if($kind -eq 'effort'){1}else{0});incumbent_wins=0;reps=@([pscustomobject]@{judges=@([pscustomobject]@{reply='no_difference'},[pscustomobject]@{reply='no_difference'})})})
        $field=if($kind -eq 'effort'){'effort_up_quality_verdict'}else{'quality_verdict'}
        $measured=[pscustomobject]@{tier='standard';configurations=$configs};$measured | Add-Member -NotePropertyName $field -NotePropertyValue $verdict
        $report=[pscustomobject]@{task_bank_sha256=$qualityContext.task_bank_sha256;quality_verdict=$null;tiers=@($measured)}
        if($kind -eq 'tie') {
            $proposal=[pscustomobject]@{type='tie';job='coder';tier='standard';status='pending';run_id='quality-test';bank_hash=$qualityContext.task_bank_sha256;configurations=$configs;quality_evidence=$record}
            $path=Join-Path $temp 'tie-proposals/coder.json';$options=@('-ApproveTie','-Job','coder')
        } elseif($kind -eq 'effort') {
            [void][IO.Directory]::CreateDirectory((Join-Path $temp 'effort-proposals'))
            $proposal=[pscustomobject]@{type='effort-swap';job='coder';tier='standard';status='pending';model=$entry.first;current_effort='medium';proposed_effort='high';bench_evidence=$basis;effort_up=$configs.candidate;quality_evidence=$record}
            $path=Join-Path $temp 'effort-proposals/coder-standard.json';$options=@('-ApproveEffort','-Job','coder')
        } else {
            $proposal=$qualityRoster | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
            $proposal.jobs.coder.first=$configs.candidate.model
            $proposal | Add-Member -NotePropertyName changes -NotePropertyValue @([pscustomobject]@{job='coder';slot='first';from=$configs.incumbent.model;to=$configs.candidate.model;evidence='Synthetic bench';bench_evidence=$basis;quality_evidence=@($record)})
            $path=$latest.proposal;$options=@('-Approve','-Jobs','coder')
        }
        foreach($defect in @('tier','configuration','verdict','bank','record-tier','record-configuration')) {
            $bad=$report | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
            $badProposal=$proposal | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
            if($defect -eq 'tier'){$bad.tiers[0].$field.tier='hard'}
            if($defect -eq 'configuration'){$bad.tiers[0].$field.configurations.candidate.effort='low'}
            if($defect -eq 'verdict'){$bad.tiers[0].$field.verdict='incumbent_better'}
            if($defect -eq 'bank'){$bad.task_bank_sha256='obsolete'}
            $proposalRecord=if($kind -eq 'swap'){$badProposal.changes[0].quality_evidence[0]}else{$badProposal.quality_evidence}
            if($defect -eq 'record-tier'){$proposalRecord.tier='hard'}
            if($defect -eq 'record-configuration'){$proposalRecord.configurations.incumbent.model='changed'}
            Write-RouterJsonAtomic $path $badProposal
            Write-RouterJsonAtomic (Join-Path $runDir 'report.json') $bad
            $before=[IO.File]::ReadAllText((Join-Path $temp 'roster.json'))
            $output=@(Invoke-Approval -Options $options) -join "`n"
            Assert-True ($LASTEXITCODE -ne 0 -and $output -match 'Quality|quality|bank' -and [IO.File]::ReadAllText((Join-Path $temp 'roster.json')) -ceq $before) "$kind quality approval rejects $defect without roster mutation"
        }
        if($kind -eq 'tie') {
            $bad=$report | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
            $bad.tiers[0].$field.tasks[0].reps=@()
            Write-RouterJsonAtomic $path $proposal
            Write-RouterJsonAtomic (Join-Path $runDir 'report.json') $bad
            $output=@(Invoke-Approval -Options $options) -join "`n"
            Assert-True ($LASTEXITCODE -ne 0 -and $output -match 'no longer supports') 'Tie approval rejects no_difference based only on unavailable draws'
        }
        Write-RouterJsonAtomic $path $proposal
        Write-RouterJsonAtomic (Join-Path $runDir 'report.json') $report
        $output=@(Invoke-Approval -Options $options) -join "`n"
        Assert-True ($LASTEXITCODE -eq 0) "$kind exact recorded quality still approves: $output"
        if($kind -eq 'effort') {
            $after=(Read-RouterJsonObject (Join-Path $temp 'roster.json')).jobs.coder
            Assert-True ($after.first_efforts.standard -ceq 'high' -and $after.first_efforts.hard -ceq 'high') 'Quality effort-up changes only the measured tier'
        }
    }
    # A legacy effort proposal has bank evidence but no quality record or run.
    Write-RouterJsonAtomic (Join-Path $temp 'roster.json') $qualityRoster
    $legacy=[pscustomobject]@{type='effort-swap';job='coder';tier='standard';status='pending';model=$qualityRoster.jobs.coder.first;current_effort='medium';proposed_effort='low';bench_evidence=$basis;effort_down=[pscustomobject]@{model=$qualityRoster.jobs.coder.first;effort='low'}}
    Write-RouterJsonAtomic (Join-Path $temp 'effort-proposals/coder-standard.json') $legacy
    $output=@(Invoke-Approval -Options @('-ApproveEffort','-Job','coder')) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0 -and (Read-RouterJsonObject (Join-Path $temp 'roster.json')).jobs.coder.first_efforts.standard -ceq 'low') "Legacy effort proposal still approves: $output"

    # Build actual drift/research proposals whose slot efforts differ from the
    # explicit medium configurations measured by the triggered comparison.
    . (Join-Path $PSScriptRoot '../build-roster.ps1')
    . (Join-Path $PSScriptRoot '../update-outcomes.ps1')
    function Get-RouterProposalJobVerdict {
        param($Job,$Incumbent,$Vendor,$Readings,$Prices,$Frontier)
        [pscustomobject]@{result=$(if($Job -eq 'coder' -and -not $Vendor){$script:researchTarget}else{'keep'});evidence='Synthetic independent research';tradeoffs=@()}
    }
    $readingDir=Join-Path $temp 'readings';[void][IO.Directory]::CreateDirectory($readingDir)
    [IO.File]::WriteAllText((Join-Path $readingDir 'passes.jsonl'),'{"pass_id":"swap-efforts","categories":["routine-coding"]}'+"`n")
    foreach($mode in @('drift','research','mismatch')) {
        $swapRoster=$qualityRoster | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $swapRoster.jobs.coder.backup_effort='low'
        $swapRoster.jobs.coder.backup_efforts.standard='low'
        $swapRoster.jobs.coder.backup_efforts.hard='medium'
        Write-RouterJsonAtomic (Join-Path $temp 'roster.json') $swapRoster
        $script:researchTarget=$swapRoster.jobs.coder.backup
        $swapRun=Join-Path $temp "bench/runs/swap-$mode";[void][IO.Directory]::CreateDirectory($swapRun)
        $tiers=@(foreach($tier in @('standard','hard')) {
            $configs=[pscustomobject]@{candidate=[pscustomobject]@{model=$swapRoster.jobs.coder.backup;effort='medium'};incumbent=[pscustomobject]@{model=$swapRoster.jobs.coder.first;effort='medium'}}
            $record=[pscustomobject]@{job='coder';tier=$tier;verdict='candidate_better';configurations=$configs;run_id="swap-$mode"}
            $verdict=$record | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $verdict | Add-Member -NotePropertyName tasks -NotePropertyValue @([pscustomobject]@{candidate_wins=1;incumbent_wins=0;reps=@()})
            [pscustomobject]@{job='coder';tier=$tier;configurations=$configs;quality_evidence=$record;quality_verdict=$verdict}
        })
        $bench=Add-TestBenchEvidence ([pscustomobject]@{raw_gate='pass';gate='pass';shadow=$false;tied=$false;better=$swapRoster.jobs.coder.backup;shortfall_tasks=0;tiers=$tiers;report_paths=[pscustomobject]@{markdown='synthetic-swap.md'}})
        Write-RouterJsonAtomic (Join-Path $swapRun 'report.json') $bench
        if($mode -eq 'drift') {
            Write-RouterJsonAtomic (Join-Path $temp 'drift-marks.json') @([pscustomobject]@{job='coder';model=$swapRoster.jobs.coder.first;prior_rate=1;recent_rate=0.5})
            $staged=[pscustomobject]@{identity=(ConvertTo-Json $swapRoster.jobs -Compress -Depth 30)}
            $swapPath=Complete-RouterDriftBench -Staged $staged -BenchResults @{coder=$bench} -Now (Get-Date)
        } else {
            $history=Join-Path $temp 'roster-proposals/verdicts.jsonl'
            [IO.File]::WriteAllText($history,(@{pass_id='previous-swap';job='coder';slot='first';result=$script:researchTarget}|ConvertTo-Json -Compress)+"`n"+(@{pass_id='swap-efforts';job='coder';slot='first';result=$script:researchTarget}|ConvertTo-Json -Compress)+"`n")
            $key="coder/first/$($swapRoster.jobs.coder.backup)/$($swapRoster.jobs.coder.first)"
            # The other-vendor slot also has its own measured comparison.
            $reverse=$bench | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
            $reverse.better=$swapRoster.jobs.coder.first
            foreach($tierResult in $reverse.tiers) {
                foreach($configs in @($tierResult.configurations,$tierResult.quality_verdict.configurations,$tierResult.quality_evidence.configurations)) {
                    $configs.candidate.model=$swapRoster.jobs.coder.first
                    $configs.incumbent.model=$swapRoster.jobs.coder.backup
                }
                $tierResult.quality_evidence.run_id="swap-$mode-reverse"
            }
            $reverseRun=Join-Path $temp "bench/runs/swap-$mode-reverse";[void][IO.Directory]::CreateDirectory($reverseRun)
            Write-RouterJsonAtomic (Join-Path $reverseRun 'report.json') $reverse
            $reverseKey="coder/backup/$($swapRoster.jobs.coder.first)/$($swapRoster.jobs.coder.backup)"
            $built=Build-RouterRosterProposalLocked -Now (Get-Date) -BenchResults @{$key=$bench;$reverseKey=$reverse} -Notification ([pscustomobject]@{alert=$null})
            $swapPath=$built.proposal
        }
        Assert-True ([bool]$swapPath) "$mode swap publisher files a proposal"
        if($mode -eq 'mismatch') {
            $badProposal=Read-RouterJsonObject $swapPath
            $badProposal.changes[0].quality_evidence[0].configurations.candidate.effort='low'
            Write-RouterJsonAtomic $swapPath $badProposal
            $badReport=Read-RouterJsonObject (Join-Path $swapRun 'report.json')
            $badReport.tiers[0].quality_verdict.configurations.candidate.effort='low'
            Write-RouterJsonAtomic (Join-Path $swapRun 'report.json') $badReport
        }
        $before=[IO.File]::ReadAllText((Join-Path $temp 'roster.json'))
        $output=@(Invoke-Approval -Options @('-Approve','-Jobs','coder')) -join "`n"
        if($mode -eq 'mismatch') {
            Assert-True ($LASTEXITCODE -ne 0 -and $output -match 'measured tier' -and [IO.File]::ReadAllText((Join-Path $temp 'roster.json')) -ceq $before) 'Swap mismatching actual measured configuration refuses without mutation'
        } else {
            Assert-True ($LASTEXITCODE -eq 0 -and (Read-RouterJsonObject (Join-Path $temp 'roster.json')).jobs.coder.first -ceq $swapRoster.jobs.coder.backup) "$mode swap to current backup approves with differing tier efforts: $output"
        }
    }
    Write-Output "PASS: $script:passed tests"
} finally { Exit-RouterTestCodexHome $fixtureCodexHome;
    $env:DT_MODEL_ROUTER_STATE = $priorState
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorTransport
    $env:DT_MODEL_ROUTER_CODEX_SESSIONS = $priorSessions
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
