Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../update-outcomes.ps1')
. (Join-Path $PSScriptRoot '../resolve-model.ps1')

$script:passed = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Output "PASS: $Name"
}
function Write-Provenance([string]$Run, [string]$Chunk, [int]$Attempt, [string]$Model, [bool]$Pass, [string]$At, [string]$Tier = 'standard', [string]$Failure = '', [string]$Category = '') {
    $dir = Join-Path $script:repo ".dt-build/$Run/milestones/$Chunk"
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $name = if ($Attempt -gt 1) { "output-$Attempt-retry.md.provenance.json" } else { 'output-1.md.provenance.json' }
    @{ pass=$Pass; tier=$Tier; resolved_model=$Model; attempt=$Attempt; at=$At; failure_category=$Failure; category=$Category; chunk_id=$Chunk } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir $name)
}
function Run-Update { Update-RouterOutcomes -Now $script:now -SourcesPath $script:sources }
function Read-Records { @(Get-Content -LiteralPath (Join-Path $script:state 'outcomes.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -DateKind String }) }

$saved = $env:DT_MODEL_ROUTER_STATE
$savedTransport = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
$savedSessions = $env:DT_MODEL_ROUTER_CODEX_SESSIONS
$temp = Join-Path $env:TEMP ('model-router-outcomes-' + [guid]::NewGuid().ToString('N'))
$env:DT_MODEL_ROUTER_CODEX_SESSIONS = Join-Path $temp 'sessions'
[IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_CODEX_SESSIONS) | Out-Null
$stub = Join-Path $temp 'transport.ps1'
Set-Content -LiteralPath $stub -Value @'
param($request)
if ($request.kind -eq 'secret') { return 'fake-secret' }
if ($request.uri -like '*/oauth2/applications/@me') { return [pscustomobject]@{owner=[pscustomobject]@{id='owner'}} }
if ($request.uri -like '*/users/@me/channels') { return [pscustomobject]@{id='dm'} }
if ($request.uri -like '*/messages') { Add-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'deliveries.log') -Value $request.body }
return [pscustomobject]@{id='stub'}
'@
$env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $stub
$script:state = Join-Path $temp 'state'
$script:repo = Join-Path $temp 'sample-repo'
$script:sources = Join-Path $temp 'sources.json'
$script:now = [datetime]'2026-09-27T12:00:00Z'
[IO.Directory]::CreateDirectory($script:repo) | Out-Null
$env:DT_MODEL_ROUTER_STATE = $script:state
[IO.Directory]::CreateDirectory($script:state) | Out-Null
try {
    @($script:repo,(Join-Path $temp 'missing-repo')) | ConvertTo-Json | Set-Content -LiteralPath $script:sources
    $table = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/seed-table.json') -Raw | ConvertFrom-Json -Depth 30
    $table.source = 'research'
    $table.coverage = 'full'
    $table.evidence_routing_approved = $true
    $table.generated_at = '2026-09-27'
    $rows = $table.categories.'routine-coding'.claude.candidates
    foreach ($candidate in @($rows[1],$rows[2])) {
        $candidate.grade = 'capable'
        $candidate.confirmed_grade = 'capable'
        $candidate.citations = @([pscustomobject]@{ source='Fixture'; url='https://example.org/evidence'; independent=$true; note='Fixture' })
    }
    $rows[1].grade = 'capable'; $rows[1].confirmed_grade = 'capable'
    $rows[1].est_burn = 10; $rows[1].est_seconds = 30
    $rows[2].est_burn = 8; $rows[2].est_seconds = 10
    $table | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $script:state 'router-table.json')

    $at = '2026-09-20T12:00:00Z'
    Write-Provenance 'sample' 'M01' 1 'sonnet' $false $at
    Write-Provenance 'sample' 'M01' 2 'opus' $true $at 'complex'
    Write-Provenance 'sample' 'M02' 1 'sonnet' $false $at 'standard' 'environment'
    Write-Provenance 'sample' 'M03' 1 'sonnet' $false $at 'standard' 'tooling'
    $first = Run-Update
    $history = Read-Records
    Assert-True ($history.Count -eq 4 -and $first.new_records -eq 4) 'provenance mining and one record per attempt'
    $a = @($history | Where-Object { $_.key -eq 'sample:M01:1' })[0]
    Assert-True ($a.model -eq $rows[2].model -and -not $a.pass -and $a.escalated -and $a.category -eq 'routine-coding' -and $a.source -eq 'dt-build') 'alias, failure, category, and escalation derivation'
    Assert-True ((Run-Update).new_records -eq 0 -and (Read-Records).Count -eq 4) 'idempotent import'
    $acceptanceDir = Join-Path $script:repo '.dt-build/acceptance'
    [IO.Directory]::CreateDirectory($acceptanceDir) | Out-Null
    @{ milestone_id='M04'; lane='claude'; builder=@{ model='sonnet' }; status='PASS'; recorded_at_utc=$at; category='code-review' } | ConvertTo-Json -Compress -Depth 5 | Set-Content -LiteralPath (Join-Path $acceptanceDir 'acceptance-rows.jsonl')
    Run-Update | Out-Null
    $accepted = @(Read-Records | Where-Object { $_.key -eq 'acceptance:M04:1' })
    Assert-True ($accepted.Count -eq 1 -and $accepted[0].pass -and $accepted[0].category -eq 'code-review' -and $accepted[0].model -eq $rows[2].model) 'acceptance row mining'

    for ($i=1; $i -le 8; $i++) { Write-Provenance "threshold-$i" 'M01' 1 'sonnet' $true $at }
    Run-Update | Out-Null
    $live = (Read-RouterTable).table.categories.'routine-coding'.claude.candidates[2]
    Assert-True ($live.pass_samples -eq 0) 'ten usable first attempts required'
    Write-Provenance 'threshold-9' 'M01' 1 'sonnet' $true $at
    Run-Update | Out-Null
    $live = (Read-RouterTable).table.categories.'routine-coding'.claude.candidates[2]
    Assert-True ($live.pass_samples -eq 10 -and [math]::Abs($live.pass_rate - 0.9) -lt 0.00001) 'environment and tooling failures excluded from rate'
    $normal = Resolve-RouterModel -Category routine-coding -Lane claude -SkipModelCheck
    $protected = Resolve-RouterModel -Category routine-coding -Lane claude -Protected -SkipModelCheck
    $writing = Resolve-RouterModel -Category long-form-writing -Lane claude -SkipModelCheck
    Assert-True ($normal.model -eq $rows[2].model -and $protected.model -eq $rows[1].model -and $writing.model -eq $table.categories.'long-form-writing'.claude.fallback) 'measured rate promotes only non-protected work'

    # Prior window is 10/10. Recent 17/20 is exactly 15 points lower.
    for ($i=1; $i -le 10; $i++) { Write-Provenance "prior-$i" 'M01' 1 'sonnet' $true '2026-08-01T12:00:00Z' }
    for ($i=1; $i -le 20; $i++) { Write-Provenance "recent-$i" 'M01' 1 'sonnet' ($i -le 17) '2026-09-25T12:00:00Z' }
    Run-Update | Out-Null
    $flags = @(Read-RouterJsonArray -Path (Join-Path $script:state 'drift-flags.json'))
    Assert-True ($flags.Count -eq 0) 'baseline includes all recent samples and does not falsely flag'
    # Isolate drift dates in a fresh state while preserving the fixture table.
    $driftState = Join-Path $temp 'drift-state'
    [IO.Directory]::CreateDirectory($driftState) | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:state 'router-table.json') -Destination (Join-Path $driftState 'router-table.json')
    $env:DT_MODEL_ROUTER_STATE = $driftState
    $script:state = $driftState
    $driftRepo = Join-Path $temp 'drift-repo'
    [IO.Directory]::CreateDirectory($driftRepo) | Out-Null
    $script:repo = $driftRepo
    @($driftRepo) | ConvertTo-Json | Set-Content -LiteralPath $script:sources
    for ($i=1; $i -le 9; $i++) { Write-Provenance "prior-$i" 'M01' 1 'sonnet' $true '2026-08-01T12:00:00Z' }
    for ($i=1; $i -le 20; $i++) { Write-Provenance "recent-$i" 'M01' 1 'sonnet' ($i -le 17) '2026-09-25T12:00:00Z' }
    Assert-True ((Run-Update).drift_flags -eq 0) 'nine prior samples do not flag drift'
    Write-Provenance 'prior-10' 'M01' 1 'sonnet' $true '2026-08-01T12:00:00Z'
    $drift = Run-Update
    Assert-True ($drift.drift_flags -eq 1 -and @($drift.alerts | Where-Object { $_ -like 'drift:*' }).Count -eq 1) 'drift at exactly 15 points with 10 plus 20 samples'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:state 'alert-log.jsonl'))) 'dot-sourced v1 update returns alert without delivery'
    Remove-Item -LiteralPath (Join-Path $script:state 'drift-flags.json')
    $cli = @(& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../update-outcomes.ps1') -Now $script:now -SourcesPath $script:sources -Json 2>&1) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0 -and $cli -match 'ROUTER_ALERT:' -and (Test-Path -LiteralPath (Join-Path $script:state 'deliveries.log'))) 'v1 CLI sends alert through transport and prints chat line'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:state 'drift-marks.json'))) 'no approved roster keeps v1 drift flags'
    $demoted = Resolve-RouterModel -Category routine-coding -Lane claude -SkipModelCheck
    Assert-True ($demoted.model -eq 'claude-opus-5-5' -and $demoted.reason -match 'Drift demotion') 'resolver demotes flagged candidate (confirmed incumbent steps one rung up the ladder)'
    $protected = Resolve-RouterModel -Category routine-coding -Lane claude -Protected -SkipModelCheck
    Assert-True ($protected.model -eq $rows[1].model) 'protected pick remains strongest under drift'
    for ($i=21; $i -le 50; $i++) { Write-Provenance "recent-$i" 'M01' 1 'sonnet' ($i -le 46) '2026-09-25T12:00:00Z' }
    $clear = Run-Update
    Assert-True ($clear.drift_flags -eq 0 -and @($clear.alerts | Where-Object { $_ -like 'drift-cleared:*' }).Count -eq 1) 'drift clears at 14 point drop'

    $fixture = Get-Content -LiteralPath (Join-Path $script:state 'router-table.json') -Raw | ConvertFrom-Json -Depth 30
    $fixture.categories.'routine-coding'.claude.candidates[1].grade = 'unknown'
    $fixture.categories.'routine-coding'.claude.candidates[1].confirmed_grade = 'unknown'
    $fixture | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $script:state 'router-table.json')
    @([pscustomobject]@{ category='routine-coding'; lane='claude'; model=$rows[2].model; recent_rate=0.85; prior_rate=1; flagged_at='2026-09-27T12:00:00Z' },[pscustomobject]@{ category='routine-coding'; lane='claude'; model='claude-opus-5-5'; recent_rate=0.85; prior_rate=1; flagged_at='2026-09-27T12:00:00Z' }) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $script:state 'drift-flags.json')
    $none = Resolve-RouterModel -Category routine-coding -Lane claude -SkipModelCheck
    Assert-True ($none.model -eq $rows[2].model -and @($none.alerts | Where-Object { $_ -like 'drift-no-alternative:*' }).Count -eq 1) 'no eligible alternative (next rung also flagged, top rung frontier) retains pick and alerts'

    $rosterState = Join-Path $temp 'roster-state'; $rosterRepo = Join-Path $temp 'roster-repo'
    [IO.Directory]::CreateDirectory($rosterState) | Out-Null
    [IO.Directory]::CreateDirectory($rosterRepo) | Out-Null
    $env:DT_MODEL_ROUTER_STATE = $rosterState; $script:state = $rosterState; $script:repo = $rosterRepo
    @($rosterRepo) | ConvertTo-Json | Set-Content -LiteralPath $script:sources
    $roster = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 30
    $roster.approved = $true; $roster.approved_at = '2026-09-27T00:00:00Z'
    $roster | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $rosterState 'roster.json')
    $rosterHash = (Get-FileHash -LiteralPath (Join-Path $rosterState 'roster.json') -Algorithm SHA256).Hash
    Write-Provenance 'roster-analysis' 'M01' 1 'claude-opus-5-5' $true '2026-09-25T12:00:00Z' 'standard' '' 'analysis'
    for ($i=1; $i -le 10; $i++) { Write-Provenance "roster-prior-$i" 'M01' 1 'gpt-6-sol' $true '2026-08-01T12:00:00Z' 'complex' '' 'complex-coding' }
    for ($i=1; $i -le 20; $i++) { Write-Provenance "roster-recent-$i" 'M01' 1 'gpt-6-sol' ($i -le 17) '2026-09-25T12:00:00Z' 'complex' '' 'complex-coding' }
    $rosterDrift = Run-Update
    Assert-True (@(Read-Records | Where-Object { $_.key -eq 'roster-analysis:M01:1' -and $_.category -eq 'analysis' }).Count -eq 1) 'approved roster preserves analysis category during import'
    $marks = @(Read-RouterJsonArray -Path (Join-Path $rosterState 'drift-marks.json'))
    $latest = Read-RouterJsonObject -Path (Join-Path $rosterState 'roster-proposals/latest.json')
    $swap = Read-RouterJsonObject -Path ([string]$latest.proposal)
    Assert-True ($marks.Count -eq 1 -and $marks[0].job -eq 'coder' -and $marks[0].model -eq 'gpt-6-sol' -and [math]::Abs($marks[0].recent_rate - 0.85) -lt 0.00001) 'approved roster drift marks first choice across job categories'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rosterState 'alert-log.jsonl'))) 'dot-sourced roster update returns alert without delivery'
    Assert-True (@($rosterDrift.alerts | Where-Object { $_.key -eq 'drift:gpt-6-sol:coder:202609' -and $_.message -match 'uses its backup' -and $_.message -match 'swap first and backup' }).Count -eq 1) 'roster drift yields one backup and swap alert'
    Assert-True ($swap.jobs.coder.first -eq 'claude-opus-5-5' -and $swap.jobs.coder.backup -eq 'gpt-6-sol' -and (Test-Path -LiteralPath $latest.report)) 'drift writes swap proposal and report'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $rosterState 'roster.json') -Algorithm SHA256).Hash -eq $rosterHash) 'drift leaves approved roster unchanged'
    Assert-True (@((Run-Update).alerts).Count -eq 0) 'repeat drift emits no duplicate alert'
    Remove-Item -LiteralPath (Join-Path $rosterState 'drift-marks.json')
    $cli = @(& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../update-outcomes.ps1') -Now $script:now -SourcesPath $script:sources -Json 2>&1) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0 -and $cli -match 'ROUTER_ALERT:' -and (Test-Path -LiteralPath (Join-Path $rosterState 'deliveries.log'))) 'roster CLI sends alert through transport and prints chat line'
    for ($i=21; $i -le 50; $i++) { Write-Provenance "roster-recent-$i" 'M01' 1 'gpt-6-sol' $true '2026-09-25T12:00:00Z' 'complex' '' 'complex-coding' }
    $rosterClear = Run-Update
    Assert-True (@(Read-RouterJsonArray -Path (Join-Path $rosterState 'drift-marks.json')).Count -eq 0 -and @($rosterClear.alerts | Where-Object { $_.key -like 'drift-cleared:*' }).Count -eq 1) 'cleared roster drift removes mark and alerts once'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rosterState 'roster-proposals/latest.json'))) 'cleared drift withdraws the pending drift swap proposal'

    $sequenceState = Join-Path $temp 'sequence-state'; $sequenceRepo = Join-Path $temp 'sequence-repo'
    [IO.Directory]::CreateDirectory($sequenceState) | Out-Null
    [IO.Directory]::CreateDirectory($sequenceRepo) | Out-Null
    $env:DT_MODEL_ROUTER_STATE = $sequenceState; $script:state = $sequenceState; $script:repo = $sequenceRepo
    @($sequenceRepo) | ConvertTo-Json | Set-Content -LiteralPath $script:sources
    for ($i=1; $i -le 10; $i++) { Write-Provenance "analysis-prior-$i" 'M01' 1 'claude-opus-5-5' $true '2026-08-01T12:00:00Z' 'standard' '' 'analysis' }
    for ($i=1; $i -le 20; $i++) { Write-Provenance "analysis-recent-$i" 'M01' 1 'claude-opus-5-5' ($i -le 17) '2026-09-25T12:00:00Z' 'standard' '' 'analysis' }
    Run-Update | Out-Null
    Assert-True (@(Read-Records | Where-Object { $_.category -eq 'analysis' }).Count -eq 30) 'analysis imported before roster retains recorded category'
    Assert-True (@(Read-RouterJsonArray -Path (Join-Path $sequenceState 'drift-flags.json') | Where-Object { $_.category -eq 'planning' -and $_.model -eq 'claude-opus-5-5' }).Count -eq 1) 'v1 path counts analysis outcomes as planning'
    $roster | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $sequenceState 'roster.json')
    $analysisDrift = Run-Update
    Assert-True (@(Read-RouterJsonArray -Path (Join-Path $sequenceState 'drift-marks.json') | Where-Object job -eq 'deep-thinker').Count -eq 1) 'pre-roster analysis records count toward deep-thinker drift'
    for ($i=1; $i -le 10; $i++) { Write-Provenance "coder-prior-$i" 'M01' 1 'gpt-6-sol' $true '2026-08-01T12:00:00Z' 'complex' '' 'complex-coding' }
    for ($i=1; $i -le 20; $i++) { Write-Provenance "coder-recent-$i" 'M01' 1 'gpt-6-sol' ($i -le 17) '2026-09-25T12:00:00Z' 'complex' '' 'complex-coding' }
    Run-Update | Out-Null
    $latest = Read-RouterJsonObject -Path (Join-Path $sequenceState 'roster-proposals/latest.json')
    $both = Read-RouterJsonObject -Path ([string]$latest.proposal)
    Assert-True ($both.jobs.coder.first -eq 'claude-opus-5-5' -and $both.jobs.'deep-thinker'.first -eq 'gpt-6-sol' -and ((Get-Content -LiteralPath $latest.report -Raw) -match 'deep-thinker.*drift threshold met')) 'new proposal swaps every current mark and reports each'
    for ($i=1; $i -le 10; $i++) { Write-Provenance "writer-prior-$i" 'M01' 1 'claude-opus-5-5' $true '2026-08-01T12:00:00Z' 'standard' '' 'long-form-writing' }
    for ($i=1; $i -le 20; $i++) { Write-Provenance "writer-recent-$i" 'M01' 1 'claude-opus-5-5' ($i -le 17) '2026-09-25T12:00:00Z' 'standard' '' 'long-form-writing' }
    Run-Update | Out-Null
    $latest = Read-RouterJsonObject -Path (Join-Path $sequenceState 'roster-proposals/latest.json')
    $allSwapped = Read-RouterJsonObject -Path ([string]$latest.proposal)
    Assert-True ($allSwapped.jobs.coder.first -eq 'claude-opus-5-5' -and $allSwapped.jobs.writer.first -eq 'gpt-6-sol' -and ((Get-Content -LiteralPath $latest.report -Raw) -match 'coder.*drift threshold met') -and ((Get-Content -LiteralPath $latest.report -Raw) -match 'writer.*drift threshold met')) 'writer drift proposal retains coder swap and reports both'
    $approval = @(& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../approve-router-table.ps1') -Roster -DeclineDrift -Job coder 2>&1) -join "`n"
    $marksBefore = @(Read-RouterJsonArray -Path (Join-Path $sequenceState 'drift-marks.json'))
    $proposalBefore = (Get-FileHash -LiteralPath (Join-Path $sequenceState 'roster-proposals/latest.json') -Algorithm SHA256).Hash
    $afterDecline = Run-Update
    $marksAfter = @(Read-RouterJsonArray -Path (Join-Path $sequenceState 'drift-marks.json'))
    $coderRoute = Resolve-RouterModel -Category complex-coding -SkipModelCheck
    Assert-True ($LASTEXITCODE -eq 0 -and $marksBefore.Count -eq 2 -and $marksAfter.Count -eq 2 -and @($marksAfter | Where-Object job -eq 'coder').Count -eq 0 -and $coderRoute.model -eq 'gpt-6-sol' -and -not $afterDecline.proposal -and (Get-FileHash -LiteralPath (Join-Path $sequenceState 'roster-proposals/latest.json') -Algorithm SHA256).Hash -eq $proposalBefore) 'decline survives update without re-mark or new proposal'
    for ($i=21; $i -le 50; $i++) { Write-Provenance "coder-recent-$i" 'M01' 1 'gpt-6-sol' $true '2026-09-25T12:00:00Z' 'complex' '' 'complex-coding' }
    Run-Update | Out-Null
    Assert-True (@(Read-RouterJsonArray -Path (Join-Path $sequenceState 'drift-declines.json')).Count -eq 0) 'decline removed when model drift clears'
    for ($i=51; $i -le 200; $i++) { Write-Provenance "coder-recent-$i" 'M01' 1 'gpt-6-sol' $false '2026-09-25T12:00:00Z' 'complex' '' 'complex-coding' }
    Run-Update | Out-Null
    Assert-True (@(Read-RouterJsonArray -Path (Join-Path $sequenceState 'drift-marks.json') | Where-Object job -eq 'coder').Count -eq 1) 'new drift after clearance is marked again'
    Remove-Item -LiteralPath (Join-Path $sequenceState 'drift-marks.json')
    Update-RouterOutcomes -Now $script:now -SourcesPath $script:sources -SendAlerts | Out-Null
    $delivered = @(Get-Content -LiteralPath (Join-Path $sequenceState 'alert-log.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.key -eq 'drift:gpt-6-sol:coder:202609' -and $_.event -eq 'delivered' })
    Assert-True ((Test-Path -LiteralPath (Join-Path $sequenceState 'deliveries.log')) -and $delivered.Count -eq 1) 'explicit SendAlerts delivers dot-sourced roster alert'

    $timestampState = Join-Path $temp 'timestamp-state'
    $timestampRepo = Join-Path $temp 'timestamp-repo'
    [IO.Directory]::CreateDirectory($timestampState) | Out-Null
    [IO.Directory]::CreateDirectory($timestampRepo) | Out-Null
    $env:DT_MODEL_ROUTER_STATE = $timestampState
    $script:state = $timestampState
    $script:repo = $timestampRepo
    @($timestampRepo) | ConvertTo-Json | Set-Content -LiteralPath $script:sources
    Write-Provenance 'timestamps' 'midnight' 1 'claude-opus-5[1m]' $true '2026-07-16T21:52:00Z'
    Write-Provenance 'timestamps' 'dst-before' 1 'claude-opus-4[1m]' $true '2026-03-08T06:59:00Z'
    Write-Provenance 'timestamps' 'dst-after' 1 'claude-opus-5' $true '2026-03-08T07:01:00Z'
    $acceptanceDir = Join-Path $timestampRepo '.dt-build/timestamps'
    @{ milestone_id='accepted'; model='claude-opus-5[1m]'; status='PASS'; recorded_at_utc='2026-11-01T06:01:00Z' } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $acceptanceDir 'acceptance-rows.jsonl')
    Run-Update | Out-Null
    $timestamps = Read-Records
    Assert-True ((@($timestamps | Where-Object key -eq 'timestamps:midnight:1')[0].at) -ceq '2026-07-16T21:52:00.0000000Z') 'provenance UTC timestamp remains exact near midnight'
    Assert-True ((@($timestamps | Where-Object key -eq 'timestamps:dst-before:1')[0].at) -ceq '2026-03-08T06:59:00.0000000Z' -and (@($timestamps | Where-Object key -eq 'timestamps:dst-after:1')[0].at) -ceq '2026-03-08T07:01:00.0000000Z') 'provenance UTC timestamps remain exact across DST'
    Assert-True ((@($timestamps | Where-Object key -eq 'timestamps:accepted:1')[0].at) -ceq '2026-11-01T06:01:00.0000000Z') 'acceptance UTC timestamp remains exact across DST'
    Assert-True ((@($timestamps | Where-Object key -eq 'timestamps:midnight:1')[0].model) -ceq 'claude-opus-5' -and (@($timestamps | Where-Object key -eq 'timestamps:dst-before:1')[0].model) -ceq 'claude-opus-4' -and (@($timestamps | Where-Object key -eq 'timestamps:accepted:1')[0].model) -ceq 'claude-opus-5') 'context tag removed without changing model version'
    $unspecified = [datetime]::SpecifyKind([datetime]'2026-07-16T21:52:00', [DateTimeKind]::Unspecified)
    $unspecifiedAt = ConvertTo-RouterOutcomeUtcTimestamp $unspecified
    Assert-True ($unspecifiedAt -ceq '2026-07-16T21:52:00.0000000Z') 'UTC-named unspecified DateTime is UTC'
    $offsetAt = ConvertTo-RouterOutcomeUtcTimestamp ([datetimeoffset]'2026-07-16T17:52:00-04:00')
    Assert-True ($offsetAt -ceq '2026-07-16T21:52:00.0000000Z') 'DateTimeOffset preserves its offset'

    $env:DT_MODEL_ROUTER_STATE = Join-Path $temp 'live-state'
    $real = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/outcome-sources.json') -Raw | ConvertFrom-Json
    $liveFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $real) {
        $build = Join-Path $root '.dt-build'
        if (-not (Test-Path -LiteralPath $build -PathType Container)) { continue }
        foreach ($run in @(Get-ChildItem -LiteralPath $build -Directory)) {
            $folders = @($run.FullName)
            $milestones = Join-Path $run.FullName 'milestones'
            if (Test-Path -LiteralPath $milestones -PathType Container) { $folders += @(Get-ChildItem -LiteralPath $milestones -Directory | ForEach-Object FullName) }
            foreach ($folder in $folders) {
                foreach ($file in @(Get-ChildItem -LiteralPath $folder -File | Where-Object { $_.Name -like '*.provenance.json' -or $_.Name -eq 'acceptance-rows.jsonl' })) { $liveFiles.Add($file.FullName) }
            }
        }
    }
    $before = @{}
    foreach ($file in $liveFiles) { $before[$file] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash }
    $liveResult = Update-RouterOutcomes -Now $script:now
    $unchanged = $true
    foreach ($file in $liveFiles) { if ($before[$file] -ne (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash) { $unchanged = $false; break } }
    Assert-True ($liveResult.total_records -gt 0 -and $unchanged) 'LIVE bounded source mining is read-only'
    Write-Output "PASS: $script:passed tests"
} finally {
    $env:DT_MODEL_ROUTER_STATE = $saved
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $savedTransport
    $env:DT_MODEL_ROUTER_CODEX_SESSIONS = $savedSessions
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
