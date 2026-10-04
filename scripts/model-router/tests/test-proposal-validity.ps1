Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../build-roster.ps1')
. (Join-Path $PSScriptRoot '../update-outcomes.ps1')
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
. (Join-Path $PSScriptRoot 'fixtures/bench-proposal-evidence.ps1')
$fixture=Enter-RouterTestCodexHome
$prior=$env:DT_MODEL_ROUTER_STATE
$env:DT_MODEL_ROUTER_STATE=Join-Path $fixture.root 'proposal-validity'
$script:checks=0
function Check($ok,$label){if(-not $ok){throw "FAIL: $label"};$script:checks++}
$script:alertKeys=@()
function Send-RouterAlerts {param($Alerts) $script:alertKeys+=@($Alerts | ForEach-Object key)}
$approve=Join-Path $PSScriptRoot '../approve-roster.ps1'
function Action([string[]]$Arguments){$output=& pwsh -NoProfile -File $approve @Arguments 2>&1 | Out-String;return @{code=$LASTEXITCODE;text=$output}}
try {
    [void][IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_STATE)
    Initialize-TestBenchEvidence
    $roster=(Read-RouterRoster).roster;$roster.approved=$true;$roster.approved_at='2026-10-02T12:00:00Z'
    $rp=Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json';Write-RouterJsonAtomic $rp $roster
    $request=[pscustomobject]@{job='writer';incumbent=$roster.jobs.writer.first;effort='medium'}
    $bench=Add-TestBenchEvidence ([pscustomobject]@{shadow=$false;raw_gate='pass';effort_up_qualified=$true;incumbent=@{passed=1};effort_up=@{model=$request.incumbent;effort='high'};report_paths=@{markdown='fixture'}})
    Save-RouterEffortProposal $request $bench
    $ep=Join-Path $env:DT_MODEL_ROUTER_STATE 'effort-proposals/writer.json'
    $swap=Read-RouterJsonObject $ep
    Check ($swap.bench_evidence.judge_effort -eq 'high') 'creation captures exact rubric basis'
    $before=[IO.File]::ReadAllText($ep);Save-RouterEffortProposal $request $bench
    Check ([IO.File]::ReadAllText($ep) -ceq $before) 'same evidence deduplicates'
    Send-RouterEffortAlerts;$firstAlert=$script:alertKeys[-1]
    $configPath=Join-Path $env:DT_MODEL_ROUTER_STATE 'bench/judge-config.json';$config=Read-RouterJsonObject $configPath
    $config.judges.claude='claude-fable-new';Write-RouterJsonAtomic $configPath $config
    $result=Action @('-ApproveEffort','-Job','writer')
    Check ($result.code -ne 0 -and $result.text -match 'Judge pair changed') 'changed judge refuses approval'
    $count=$script:alertKeys.Count;Send-RouterEffortAlerts
    Check ($script:alertKeys.Count -eq $count) 'stale proposal sends no approval alert'
    Check ((Action @('-Show')).text -match 'Stale effort proposal; approval unavailable') 'Show identifies stale pending'
    $bench=Add-TestBenchEvidence $bench;Save-RouterEffortProposal $request $bench
    Check ((Read-RouterJsonObject $ep).bench_evidence.judge_pair.claude -eq 'claude-fable-new') 'fresh evidence replaces same model and efforts'
    Send-RouterEffortAlerts
    Check ($script:alertKeys[-1] -cne $firstAlert) 'fresh evidence has new alert identity'
    $config.judge_effort='medium';Write-RouterJsonAtomic $configPath $config
    Check ((Action @('-ApproveEffort','-Job','writer')).text -match 'Judge effort changed') 'changed effort refuses approval'
    $config.judge_effort='max';Write-RouterJsonAtomic $configPath $config
    Check ((Action @('-ApproveEffort','-Job','writer')).code -ne 0) 'invalid judge effort refuses approval'
    $config.judge_effort='high';Write-RouterJsonAtomic $configPath $config
    foreach ($broken in @('{invalid','', '[]', 'null', '"invalid"')) {
        [IO.File]::WriteAllText($configPath,$broken)
        Check ((Action @('-ApproveEffort','-Job','writer')).text -match 'configuration is invalid') 'malformed existing judge config refuses rubric approval'
        $context=Get-RouterBenchEvidenceContext
        Check (-not (Get-RouterBenchProposalEvidenceError coder ([pscustomobject]@{task_bank_sha256=$context.task_bank_sha256}) $context)) 'deterministic job ignores malformed judge config'
    }
    foreach ($broken in @(
        [pscustomobject]@{judges=[pscustomobject]@{claude=$config.judges.claude;codex=$config.judges.codex;note='x'};judge_effort='high'},
        [pscustomobject]@{judges=$config.judges;judge_effort=@('high')},
        [pscustomobject]@{judges=[pscustomobject]@{claude=@($config.judges.claude);codex=$config.judges.codex};judge_effort='high'})) {
        Write-RouterJsonAtomic $configPath $broken
        Check ((Action @('-ApproveEffort','-Job','writer')).code -ne 0) 'malformed pair or effort refuses rubric approval'
        $context=Get-RouterBenchEvidenceContext
        Check (-not (Get-RouterBenchProposalEvidenceError coder ([pscustomobject]@{task_bank_sha256=$context.task_bank_sha256}) $context)) 'deterministic job ignores malformed pair or effort'
    }
    Write-RouterJsonAtomic $configPath $config
    $swap=Read-RouterJsonObject $ep;$swap.bench_evidence.task_bank_sha256='previous-bank';Write-RouterJsonAtomic $ep $swap
    Check ((Action @('-ApproveEffort','-Job','writer')).text -match 'Task bank changed') 'old bank refuses approval'
    Check ((Action @('-DeclineEffort','-Job','writer')).code -eq 0) 'stale evidence can be declined'
    Save-RouterEffortProposal $request $bench
    $swap=Read-RouterJsonObject $ep;$swap.PSObject.Properties.Remove('bench_evidence');Write-RouterJsonAtomic $ep $swap
    Check ((Action @('-ApproveEffort','-Job','writer')).text -match 'Legacy benchmark evidence') 'legacy proposal refuses approval'
    Save-RouterEffortProposal $request $bench
    $approvalPath=Join-Path $env:DT_MODEL_ROUTER_STATE 'bench/golden-approval.json';$golden=Read-RouterJsonObject $approvalPath
    $golden.approved=$false;Write-RouterJsonAtomic $approvalPath $golden
    Check ((Action @('-ApproveEffort','-Job','writer')).text -match 'needs golden approval') 'withdrawn golden approval refuses proposal'
    $golden.approved=$true;Write-RouterJsonAtomic $approvalPath $golden
    Check ((Action @('-ApproveEffort','-Job','writer')).code -eq 0 -and (Read-RouterJsonObject $rp).jobs.writer.first_effort -eq 'high') 'valid effort approval applies'
    $config.judges.codex='gpt-new-astra';Write-RouterJsonAtomic $configPath $config
    Check ((Action @('-RevokeEffort','-Job','writer')).code -eq 0 -and (Read-RouterJsonObject $rp).jobs.writer.first_effort -eq 'medium') 'stale approved evidence can revoke safely'
    $legacy=Read-RouterJsonObject $ep;$legacy.current_effort='medium';$legacy.proposed_effort='low';$legacy.status='pending';Write-RouterJsonAtomic $ep $legacy
    Check ((Action @('-ApproveEffort','-Job','writer')).code -ne 0) 'legacy writer effort-down proposal cannot be approved'
    Check ((Action @('-DeclineEffort','-Job','writer')).code -eq 0 -and (Read-RouterJsonObject $ep).status -eq 'declined' -and (Read-RouterJsonObject $rp).jobs.writer.first_effort -eq 'medium') 'legacy writer effort-down proposal can be declined'
    $context=Get-RouterBenchEvidenceContext
    $deterministic=[pscustomobject]@{task_bank_sha256=$context.task_bank_sha256;judge_pair=$null;judge_effort=$null}
    Check (-not (Get-RouterBenchProposalEvidenceError coder $deterministic $context)) 'deterministic job unaffected by judges'
    $proposal=$roster | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
    $valid=New-RouterBenchProposalEvidence writer (Add-TestBenchEvidence $bench)
    $proposal | Add-Member -NotePropertyName pass_id -NotePropertyValue 'fixture'
    $proposal | Add-Member -NotePropertyName changes -NotePropertyValue @([pscustomobject]@{job='coder';slot='first';evidence='; Bench pass';bench_evidence=$deterministic},[pscustomobject]@{job='writer';slot='first';evidence='; Bench advisory';bench_evidence=$valid})
    $proposal.changes[1].bench_evidence.task_bank_sha256='old-bank'
    $dir=Join-Path $env:DT_MODEL_ROUTER_STATE 'roster-proposals';[void][IO.Directory]::CreateDirectory($dir)
    $path=Join-Path $dir 'fixture.json';Write-RouterJsonAtomic $path $proposal
    Write-RouterJsonAtomic (Join-Path $dir 'latest.json') ([pscustomobject]@{proposal=$path;report='missing-fixture'})
    Check ((Action @('-Approve')).text -match 'ROSTER_STALE_EVIDENCE') 'roster rejects stale bank'
    Check ((Action @('-Approve','-Jobs','coder')).code -eq 0) 'selected valid job approval ignores stale sibling'
    $proposal.changes[1].bench_evidence=New-RouterBenchProposalEvidence writer (Add-TestBenchEvidence $bench);Write-RouterJsonAtomic $path $proposal
    Check ((Action @('-Approve')).code -eq 0) 'valid roster basis approves'
    $proposal.changes[0].PSObject.Properties.Remove('bench_evidence');Write-RouterJsonAtomic $path $proposal
    Check ((Action @('-Approve')).text -match 'Legacy benchmark evidence') 'legacy research evidence refuses approval'
    $golden.approved=$false;Write-RouterJsonAtomic $approvalPath $golden
    Check ((Action @('-Seed')).code -eq 0 -and (Action @('-Approve')).code -eq 0) 'explicit seed bootstrap unaffected by golden approval'
    # A python3-only environment must still support the read-only proposal identity.
    $actualPython=(Get-Command python).Source
    $script:pythonLookups=@()
    function Get-Command {
        param([string]$Name, [object]$ErrorAction)
        $script:pythonLookups += $Name
        if ($Name -eq 'python3') { [pscustomobject]@{Source=$actualPython} }
    }
    try {
        $fallbackContext=Get-RouterBenchEvidenceContext
        Check ($fallbackContext.task_bank_sha256 -ceq $context.task_bank_sha256) 'python3 fallback preserves bank identity'
        Check (($script:pythonLookups -join ',') -ceq 'python,python3') 'Python lookup uses portable preference order'
    } finally { Remove-Item Function:Get-Command }
    "SUMMARY: $script:checks passed; 0 failed"
} finally {$env:DT_MODEL_ROUTER_STATE=$prior;Exit-RouterTestCodexHome $fixture}
