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
$temp = Join-Path $env:TEMP ('model-router-outcomes-' + [guid]::NewGuid().ToString('N'))
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
    $table.generated_at = '2026-09-27'
    $rows = $table.categories.'routine-coding'.claude.candidates
    foreach ($candidate in @($rows[1],$rows[2])) {
        $candidate.grade = 'capable'
        $candidate.citations = @([pscustomobject]@{ source='Fixture'; url='https://example.org/evidence'; independent=$true; note='Fixture' })
    }
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
    $demoted = Resolve-RouterModel -Category routine-coding -Lane claude -SkipModelCheck
    Assert-True ($demoted.model -eq $rows[1].model -and $demoted.reason -match 'Drift demotion') 'resolver demotes flagged candidate'
    $protected = Resolve-RouterModel -Category routine-coding -Lane claude -Protected -SkipModelCheck
    Assert-True ($protected.model -eq $rows[1].model) 'protected pick remains strongest under drift'
    for ($i=21; $i -le 50; $i++) { Write-Provenance "recent-$i" 'M01' 1 'sonnet' ($i -le 46) '2026-09-25T12:00:00Z' }
    $clear = Run-Update
    Assert-True ($clear.drift_flags -eq 0 -and @($clear.alerts | Where-Object { $_ -like 'drift-cleared:*' }).Count -eq 1) 'drift clears at 14 point drop'

    $fixture = Get-Content -LiteralPath (Join-Path $script:state 'router-table.json') -Raw | ConvertFrom-Json -Depth 30
    $fixture.categories.'routine-coding'.claude.candidates[1].grade = 'unknown'
    $fixture | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $script:state 'router-table.json')
    @([pscustomobject]@{ category='routine-coding'; lane='claude'; model=$rows[2].model; recent_rate=0.85; prior_rate=1; flagged_at='2026-09-27T12:00:00Z' }) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $script:state 'drift-flags.json')
    $none = Resolve-RouterModel -Category routine-coding -Lane claude -SkipModelCheck
    Assert-True ($none.model -eq $rows[2].model -and @($none.alerts | Where-Object { $_ -like 'drift-no-alternative:*' }).Count -eq 1) 'no eligible alternative retains pick and alerts'

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
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
