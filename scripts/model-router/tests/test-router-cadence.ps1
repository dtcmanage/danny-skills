Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../run-router-cadence.ps1')
. (Join-Path $PSScriptRoot '../resolve-model.ps1')
. (Join-Path $PSScriptRoot '../register-router-schedules.ps1')
. (Join-Path $PSScriptRoot 'fixtures/bench-proposal-evidence.ps1')

$script:passed = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Output "PASS: $Name"
}
$priorState = $env:DT_MODEL_ROUTER_STATE
$priorTransport = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
$priorSessions = $env:DT_MODEL_ROUTER_CODEX_SESSIONS
$temp = Join-Path $env:TEMP ('router-cadence-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$env:DT_MODEL_ROUTER_STATE = $temp
$env:DT_MODEL_ROUTER_CODEX_SESSIONS = Join-Path $temp 'sessions'
New-Item -ItemType Directory -Path $env:DT_MODEL_ROUTER_CODEX_SESSIONS | Out-Null
$env:DT_MODEL_ROUTER_ALERT_TRANSPORT = Join-Path $temp 'alert-stub.ps1'
Set-Content -LiteralPath $env:DT_MODEL_ROUTER_ALERT_TRANSPORT -Value 'param($request) return [pscustomobject]@{id="stub"}'
$now = [datetime]'2026-09-29T05:00:00Z'
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixtureCodexHome = Enter-RouterTestCodexHome
try {
    Initialize-TestBenchEvidence
    $script:cadenceFakeBench = { param($r) Add-TestBenchEvidence ([pscustomobject]@{raw_gate='pass';gate='pass';better=$r.candidate;tied=$false;shortfall_tasks=0;report_paths=[pscustomobject]@{markdown='synthetic'}}) }
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6.1-sol' } else { 'claude-opus-5-5' } }
    [void](Invoke-RouterModelCheck -Force -Now $now -BenchInvoker $script:cadenceFakeBench)
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6.1-sol'; 'gpt-6-new' } else { 'claude-opus-5-5' } }
    [void](Invoke-RouterModelCheck -Force -Now $now.AddHours(1) -BenchInvoker $script:cadenceFakeBench)
    $queuePath = Join-Path $temp 'research-queue.json'
    $queue = @(Read-RouterJsonArray -Path $queuePath)
    Assert-True ($queue.Count -eq 2 -and @($queue | Where-Object trigger -eq 'release').Count -eq 1 -and @($queue | Where-Object trigger -eq 'confirmation').Count -eq 1) 'release queues release and confirmation'
    Assert-True (@($queue | Where-Object trigger -eq 'confirmation')[0].due_at -eq $now.AddDays(7).AddHours(1).ToString('o')) 'confirmation is due seven days later'
    Assert-True (@($queue | Where-Object trigger -eq 'release')[0].categories -notcontains 'image-generation') 'non-image Codex release excludes illustrator'
    $categories = @('mechanical')
    $firstAdded = Add-RouterResearchQueueItem -Model 'gpt-6-new' -Trigger release -Categories $categories -DueAt $now -Reason 'one'
    $secondAdded = Add-RouterResearchQueueItem -Model 'gpt-6-new' -Trigger release -Categories $categories -DueAt $now -Reason 'two'
    Assert-True ($firstAdded -and -not $secondAdded) 'queue add returns true once and false for duplicate'
    Assert-True (@(Read-RouterJsonArray -Path $queuePath).Count -eq 3) 'queue deduplicates model trigger and categories'

    function Get-RouterStaleReadingModels { param($Months,$Now) return @('gpt-6.1-sol') }
    @([pscustomobject]@{model='gpt-6.1-sol';job='coder';marked_at=$now.ToString('o')}) | ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $temp 'drift-marks.json')
    $readDir = Join-Path $temp 'readings'; New-Item -ItemType Directory -Path $readDir | Out-Null
    $old = [pscustomobject]@{benchmark='bench';version='1';date=$now.ToString('o');results=@([pscustomobject]@{model='gpt-6.1-sol'})}
    $new = [pscustomobject]@{benchmark='bench';version='2';date=$now.ToString('o');results=@([pscustomobject]@{model='claude-opus-5-5'})}
    [pscustomobject]@{category='complex-coding';readings=@($old,$new)} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $readDir 'complex-coding.json')
    [void](Add-RouterCadenceRefreshes -Now $now)
    $refresh = @(Read-RouterJsonArray -Path $queuePath | Where-Object trigger -eq 'refresh')
    Assert-True (@($refresh | Where-Object reason -eq 'drift:coder').Count -eq 1) 'drift mark queues job refresh'
    Assert-True (@($refresh | Where-Object reason -eq 'stale-reading').Count -eq 1) 'stale roster model queues refresh'
    Assert-True (@($refresh | Where-Object reason -eq 'benchmark-version').Count -eq 0) 'benchmark version text never queues a refresh'

    $script:researchCalls = [Collections.Generic.List[object]]::new()
    $script:usagePercent = 51
    $script:writePass = $true
    $script:proposalCalls = 0
    $script:confirmationWinner = $false
    $script:lastPassId = $null
    function Get-RouterCodexUsage { return [pscustomobject]@{used_percent=$script:usagePercent} }
    function Invoke-RouterCategoryResearch {
        param($Categories,$Models,$NewModel,$Trigger,$Lane,$Now)
        $record = [pscustomobject]@{pass_id=[guid]::NewGuid().ToString('N');trigger=$Trigger;categories=$Categories;models=$Models}
        if ($Trigger -eq 'confirmation') { $script:lastPassId = $record.pass_id }
        $script:researchCalls.Add([pscustomobject]@{lane=$Lane;models=$Models;new_model=$NewModel;trigger=$Trigger;categories=$Categories})
        if ($script:writePass) { [IO.File]::AppendAllText((Join-Path $temp 'readings/passes.jsonl'),(($record | ConvertTo-Json -Compress -Depth 10) + "`n")) }
        return $record
    }
    function Build-RouterRosterProposal { param($Now) $script:proposalCalls++ }
    $script:newModelComparisons = [Collections.Generic.List[string]]::new()
    function Invoke-RouterNewModelComparisons { param($Model,$Categories,$BenchInvoker) $script:newModelComparisons.Add($Model); return 1 }
    function Write-RouterCadenceConfirmationVerdicts {
        param($Item,$PassId)
        if ($script:confirmationWinner) {
            $dir = Join-Path $temp 'roster-proposals'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $verdict = [pscustomobject]@{pass_id=$PassId;job='coder';slot='first';result='gpt-6-new'}
            [IO.File]::AppendAllText((Join-Path $dir 'verdicts.jsonl'),(($verdict | ConvertTo-Json -Compress) + "`n"))
        }
    }
    $before = @(Read-RouterJsonArray -Path $queuePath).Count
    [void](Invoke-RouterCadence -Now ([datetime]'2026-09-29T13:00:00Z'))
    Assert-True ($script:researchCalls.Count -eq 0 -and @(Read-RouterJsonArray -Path $queuePath).Count -eq $before) 'outside Eastern window runs nothing'
    $script:writePass = $false
    [void](Invoke-RouterCadence -Now $now)
    Assert-True ($script:researchCalls.Count -gt 0 -and @(Read-RouterJsonArray -Path $queuePath).Count -eq $before) 'item remains queued without written pass record'
    $script:researchCalls.Clear(); $script:writePass = $true
    [void](Invoke-RouterCadence -Now $now)
    Assert-True (@(Read-RouterJsonArray -Path $queuePath).Count -lt $before -and $script:proposalCalls -eq $script:researchCalls.Count) 'written passes each build a proposal'
    Assert-True (@($script:researchCalls | Where-Object { $_.models -contains 'gpt-6-new' -and $_.models -contains 'gpt-6-luna' -and $_.models -contains 'claude-haiku-4-5-20251001' -and $_.models -notcontains 'gpt-6.1-sol' }).Count -gt 0) 'research receives candidate and only its categories roster models'
    Assert-True (@($script:researchCalls | Where-Object { $_.trigger -eq 'release' -and $_.new_model -eq 'gpt-6-new' -and $_.models.Count -gt 1 }).Count -gt 0) 'release passes new model separately from roster models'
    Assert-True (@($script:newModelComparisons | Where-Object { $_ -eq 'gpt-6-new' }).Count -eq @($script:researchCalls | Where-Object trigger -eq 'release').Count) 'each written release pass runs the new-model comparisons'
    Assert-True (@($script:researchCalls | Where-Object lane -eq 'claude').Count -eq $script:researchCalls.Count) '51 percent Codex usage chooses Claude'
    $script:usagePercent = 50
    [void](Add-RouterResearchQueueItem -Model 'gpt-6.1-sol' -Trigger release -Categories @('mechanical') -DueAt $now -Reason 'lane-test')
    $script:researchCalls.Clear()
    [void](Invoke-RouterCadence -Now $now)
    Assert-True (@($script:researchCalls | Where-Object lane -eq 'codex').Count -eq $script:researchCalls.Count) '50 percent Codex usage chooses Codex'

    [void](Add-RouterResearchQueueItem -Model 'gpt-6-new' -Trigger confirmation -Categories @('complex-coding') -DueAt $now -Reason 'confirmation-no-verdict')
    [void](Invoke-RouterCadence -Now $now)
    Assert-True (@(Read-RouterJsonArray -Path $queuePath | Where-Object trigger -eq 'followup').Count -eq 0) 'inconclusive confirmation queues no followup'
    $script:confirmationWinner = $true
    [void](Add-RouterResearchQueueItem -Model 'gpt-6-new' -Trigger confirmation -Categories @('complex-coding') -DueAt $now -Reason 'confirmation-first-verdict')
    [void](Invoke-RouterCadence -Now $now)
    Assert-True (@(Read-RouterJsonArray -Path $queuePath | Where-Object trigger -eq 'followup').Count -eq 1) 'first conclusive confirmation queues one followup'
    # A model that already won another job still gets a follow-up for its first win in a new job.
    $followups = @(Read-RouterJsonArray -Path $queuePath | Where-Object trigger -ne 'followup')
    Use-RouterQueueMutex -StateDir $temp -Action { Write-RouterJsonAtomic -Path $queuePath -Value $followups }
    [IO.File]::AppendAllText((Join-Path $temp 'roster-proposals/verdicts.jsonl'),((([pscustomobject]@{pass_id='older';job='deep-thinker';slot='backup';result='gpt-6-new'}) | ConvertTo-Json -Compress) + "`n"))
    function Write-RouterCadenceConfirmationVerdicts { param($Item,$PassId) [IO.File]::AppendAllText((Join-Path $temp 'roster-proposals/verdicts.jsonl'),((([pscustomobject]@{pass_id=$PassId;job='writer';slot='first';result='gpt-6-new'}) | ConvertTo-Json -Compress) + "`n")) }
    [void](Add-RouterResearchQueueItem -Model 'gpt-6-new' -Trigger confirmation -Categories @('long-form-writing') -DueAt $now -Reason 'confirmation-new-job')
    [void](Invoke-RouterCadence -Now $now)
    Assert-True (@(Read-RouterJsonArray -Path $queuePath | Where-Object trigger -eq 'followup').Count -eq 1) 'first win in a new job queues a followup even after a win in another job'
    $script:modelChecks = 0
    function Invoke-RouterModelCheck { param([switch]$Force,$Now) $script:modelChecks++; return [pscustomobject]@{new_models=@()} }
    [void](Invoke-RouterCadence -Now $now)
    Assert-True ($script:modelChecks -eq 1) 'full overnight run also checks for new models'

    function Invoke-RouterModelCheck { param([switch]$Force,$Now) return [pscustomobject]@{new_models=@()} }
    $script:researchCalls.Clear()
    [void](Invoke-RouterCadence -Now $now -CheckOnly)
    Assert-True ($script:researchCalls.Count -eq 0) 'CheckOnly scans but runs no research'
    # Refresh research (drift, stale readings, benchmark versions) is queued only on request, never by the schedule.
    $script:refreshCalls = 0
    function Add-RouterCadenceRefreshes { param($Now) $script:refreshCalls++; return 0 }
    [void](Invoke-RouterCadence -Now $now -CheckOnly)
    [void](Invoke-RouterCadence -Now $now)
    Assert-True ($script:refreshCalls -eq 0) 'scheduled cadence queues no refresh research'
    [void](Invoke-RouterCadence -Now $now -CheckOnly -Refresh)
    Assert-True ($script:refreshCalls -eq 1) 'Refresh switch queues refresh research'
    function Invoke-RouterModelCheck { throw 'lookup called model check' }
    $catalog = [pscustomobject]@{models=@([pscustomobject]@{slug='gpt-6.1-sol';visibility='list'})}
    # Clear earlier cadence drift marks so the default roster's Codex pick is available for this lookup check.
    '[]' | Set-Content -LiteralPath (Join-Path $temp 'drift-marks.json')
    $first = Resolve-RouterModel -Category complex-coding -Lane codex -Catalog $catalog
    $second = Resolve-RouterModel -Category complex-coding -Lane codex -Catalog $catalog -SkipModelCheck
    Assert-True ($first.model -and $second.model) 'resolver lookup never invokes model check with or without compatibility switch'
    $tasks = @(Register-RouterSchedules)
    Assert-True (@($tasks | Where-Object { $_.name -eq 'ModelRouterCadence' -and $_.schedule -eq 'daily 01:00 ET' -and $_.action -match 'run-hidden\.vbs' }).Count -eq 1) 'overnight schedule uses hidden shim'
    Assert-True (@($tasks | Where-Object { $_.name -eq 'ModelRouterCadenceCheck' -and $_.schedule -eq 'daily 13:00 ET' -and $_.action -match 'run-hidden\.vbs' -and $_.action -match '-CheckOnly' }).Count -eq 1) 'check schedule uses hidden shim'
    $twoPassState = Join-Path $temp 'two-pass'; [IO.Directory]::CreateDirectory($twoPassState) | Out-Null
    $env:DT_MODEL_ROUTER_STATE = $twoPassState
    Initialize-TestBenchEvidence
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../approve-roster.ps1') -Seed | Out-Null
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../approve-roster.ps1') -Approve | Out-Null
    $twoPassReadings = Join-Path $twoPassState 'readings'; [IO.Directory]::CreateDirectory($twoPassReadings) | Out-Null
    $rows = @(@('bench-one','bench-two') | ForEach-Object { [pscustomobject]@{benchmark=$_;version='1';harness='h';effort_class='medium';independent=$true;results=@([pscustomobject]@{model='claude-opus-5-5';score=80;margin=1},[pscustomobject]@{model='gpt-6.1-sol';score=50;margin=1})} })
    [pscustomobject]@{category='complex-coding';readings=$rows} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $twoPassReadings 'complex-coding.json')
    . (Join-Path $PSScriptRoot '../build-roster.ps1')
    $script:cadenceRealBuilder = (Get-Command Build-RouterRosterProposal).ScriptBlock
    function Build-RouterRosterProposal { param($Now) & $script:cadenceRealBuilder -Now $Now -BenchInvoker $script:cadenceFakeBench }
    function Invoke-RouterNewModelComparisons { param($Model,$Categories,$BenchInvoker) return 0 }
    function Invoke-RouterModelCheck { param([switch]$Force,$Now) return [pscustomobject]@{new_models=@()} }
    function Add-RouterCadenceRefreshes { param($Now) return 0 }
    function Invoke-RouterCategoryResearch {
        param($Categories,$Models,$NewModel,$Trigger,$Lane,$Now)
        $record = [pscustomobject]@{pass_id=[guid]::NewGuid().ToString('N');trigger=$Trigger;categories=$Categories;models=$Models}
        [IO.File]::AppendAllText((Join-Path $twoPassReadings 'passes.jsonl'),(($record | ConvertTo-Json -Compress -Depth 10) + "`n"))
        return $record
    }
    function Write-RouterCadenceConfirmationVerdicts { param($Item,$PassId) }
    [void](Add-RouterResearchQueueItem -Model 'claude-opus-5-5' -Trigger confirmation -Categories @('complex-coding') -DueAt $now -Reason 'first-win')
    [void](Add-RouterResearchQueueItem -Model 'claude-opus-5-5' -Trigger release -Categories @('complex-coding') -DueAt $now.AddSeconds(1) -Reason 'second-win')
    $twoPass = Invoke-RouterCadence -Now $now.AddSeconds(2)
    $latest = Read-RouterJsonObject -Path (Join-Path $twoPassState 'roster-proposals/latest.json')
    $twoPassProposal = if ($latest) { Read-RouterJsonObject -Path ([string]$latest.proposal) } else { $null }
    Assert-True ($twoPass.ran.Count -eq 2 -and $twoPassProposal -and $twoPassProposal.PSObject.Properties['pass_id']) 'two covered cadence passes propose change after approved seed'
    Assert-True (@(Read-RouterJsonArray -Path (Join-Path $twoPassState 'research-queue.json') | Where-Object trigger -eq 'followup').Count -eq 1) 'first conclusive confirmation still queues followup after proposal'
    # Isolated M08 drain cases: each writes the same record shape as M07, including throws after persistence.
    $drainState = Join-Path $temp 'drain-rules'; [IO.Directory]::CreateDirectory($drainState) | Out-Null
    $env:DT_MODEL_ROUTER_STATE = $drainState
    $drainReadings = Join-Path $drainState 'readings'; [IO.Directory]::CreateDirectory($drainReadings) | Out-Null
    $failureDir = Join-Path $drainState 'research-failures'; [IO.Directory]::CreateDirectory($failureDir) | Out-Null
    $script:drainCalls = [Collections.Generic.List[string]]::new()
    function Build-RouterRosterProposal { param($Now) $script:proposalCalls++ }
    function Invoke-RouterCategoryResearch {
        param($Categories,$Models,$NewModel,$Trigger,$Lane,$Now)
        $mode = [string]$Models[0]
        $script:drainCalls.Add($mode)
        if ($mode -eq 'no-record') { throw 'failed before recording' }
        $record = [pscustomobject]@{pass_id=[guid]::NewGuid().ToString('N');trigger=$Trigger;categories=$Categories;models=$Models;deferred=($mode -like 'deferred-*');interrupted=($mode -like 'interrupted-*');diagnosis=($mode -replace '^(deferred|interrupted)-','')}
        if ($record.diagnosis -eq 'unexplained') {
            Write-RouterResearchFailure -StateDir $drainState -FileName "mechanical@20260929T010000000-$($record.pass_id).txt" -Detail 'error: synthetic stop'
        }
        [IO.File]::AppendAllText((Join-Path $drainReadings 'passes.jsonl'),(($record | ConvertTo-Json -Compress -Depth 10) + "`n"))
        if ($record.interrupted) { throw "synthetic $mode" }
        return $record
    }
    $modes = @('no-record','deferred-quota','deferred-vendor_incident','interrupted-quota','interrupted-offline','interrupted-unexplained','success')
    foreach ($mode in $modes) {
        [void](Add-RouterResearchQueueItem -Model $mode -Trigger refresh -Categories @('mechanical') -DueAt $now -Reason "operator's rerun; literal text")
    }
    $proposalBefore = $script:proposalCalls
    $drainOutput = @(Invoke-RouterCadence -Now $now 3>&1)
    $warnings = @($drainOutput | Where-Object { $_ -is [Management.Automation.WarningRecord] })
    $drain = $drainOutput[-1]
    $remainingModels = @(Read-RouterJsonArray -Path (Join-Path $drainState 'research-queue.json') | ForEach-Object model)
    Assert-True ($script:drainCalls.Count -eq $modes.Count -and $script:drainCalls[-1] -eq 'success') 'one failing item never stops the remaining drain'
    Assert-True ($warnings.Count -eq 4 -and ($warnings -join ' ') -match 'no-record' -and ($warnings -join ' ') -match 'interrupted-unexplained') 'drain logs each thrown item'
    foreach ($mode in @('no-record','deferred-quota','deferred-vendor_incident','interrupted-quota','interrupted-offline')) {
        Assert-True ($remainingModels -contains $mode) "$mode stays queued"
    }
    Assert-True ($remainingModels -notcontains 'interrupted-unexplained' -and $remainingModels -notcontains 'success' -and $drain.ran.Count -eq 2) 'unexplained stop and successful written record consume their items'
    Assert-True ($script:proposalCalls -eq $proposalBefore + 1) 'stopped and deferred research never builds proposals'
    Assert-True ($drain.needs_you.Count -eq 1 -and $drain.needs_you[0] -match 'Add-RouterResearchQueueItem') 'unexplained stop adds Needs-you re-enqueue command'
    $failure = @(Get-ChildItem -LiteralPath $failureDir -File)[0]
    Assert-True ((Get-Content -LiteralPath $failure.FullName -Raw).Contains($drain.needs_you[0])) 'Needs-you command persists with the research failure'
    [void](Add-RouterResearchQueueItem -Model 'interrupted-unexplained' -Trigger refresh -Categories @('mechanical') -DueAt $now.AddDays(1) -Reason 'stale-reading' -Automatic)
    Assert-True (@(Read-RouterJsonArray -Path (Join-Path $drainState 'research-queue.json') | Where-Object model -eq 'interrupted-unexplained').Count -eq 0) 'automatic stale refresh cannot recreate stopped item'
    # Execute the actual command and verify it recreates the consumed item, preserving quoted text.
    $command = ($drain.needs_you[0] -split 'Re-enqueue: ',2)[1]
    [void](Invoke-Expression $command)
    $reenqueued = @(Read-RouterJsonArray -Path (Join-Path $drainState 'research-queue.json') | Where-Object model -eq 'interrupted-unexplained')
    Assert-True ($reenqueued.Count -eq 1 -and $reenqueued[0].trigger -eq 'refresh' -and $reenqueued[0].categories[0] -eq 'mechanical' -and $reenqueued[0].reason -eq "operator's rerun; literal text") 'copy-paste command recreates exact queue inputs with safe quoting'
    Assert-True (@(Get-RouterStoppedResearchFiles -Model 'interrupted-unexplained' -Categories @('mechanical')).Count -eq 0) 'operator command clears persistent stop and restores dispatch eligibility'

    # Prune only older-than-30-day failures with a later successful reading in that category.
    $env:DT_MODEL_ROUTER_STATE = $drainState
    $pruneNow = [datetime]'2026-10-01T05:00:00Z'
    $pruneFiles = @{
        'mechanical@20260801T010000000-old.txt' = $false
        'mechanical@20260802T010000000-old.txt' = $false
        'mechanical@20260701T010000000.txt' = $false
        'planning@20260701T010000000.txt' = $true
        'math@20260701T010000000.txt' = $false
        'mechanical@20260920T010000000-recent.txt' = $true
        'mechanical@20260901T010000000-boundary.txt' = $true
        'planning@20260801T010000000-unresolved.txt' = $true
        'routine-coding@20260801T010000000-prior.txt' = $true
        'complex-coding@20260801T010000000-equal.txt' = $true
        'deep-research@20260801T010000000-empty.txt' = $true
    }
    foreach ($name in $pruneFiles.Keys) { Set-Content -LiteralPath (Join-Path $failureDir $name) -Value 'failure' }
    foreach ($case in @(@('mechanical','2026-08-03T05:00:00Z'),@('routine-coding','2026-07-31T05:00:00Z'),@('complex-coding','2026-08-01T05:00:00Z'),@('deep-research','2026-09-25T05:00:00Z'))) {
        $results = if ($case[0] -eq 'deep-research') { @() } else { @([pscustomobject]@{model='gpt-6.1-sol';score=80}) }
        Write-RouterJsonAtomic -Path (Join-Path $drainReadings ($case[0] + '.json')) -Value ([pscustomobject]@{category=$case[0];researched_at=$case[1];readings=@([pscustomobject]@{date='2026-07-01';results=$results})})
    }
    Write-RouterJsonAtomic -Path (Join-Path $drainReadings 'math.json') -Value ([pscustomobject]@{category='math';readings=@([pscustomobject]@{date='2026-06-01';results=@([pscustomobject]@{model='gpt-6.1-sol';score=80})})})
    $legacyRecovery = [pscustomobject]@{pass_id='legacy-recovery';categories=@('math');failed_categories=@();completed_at='2026-09-01T05:00:00Z';interrupted=$false;deferred=$false}
    [IO.File]::AppendAllText((Join-Path $drainReadings 'passes.jsonl'), (($legacyRecovery | ConvertTo-Json -Compress) + "`n"))
    # The check-only cadence also performs maintenance without dispatching research.
    function Invoke-RouterModelCheck { param([switch]$Force,$Now) return [pscustomobject]@{new_models=@()} }
    function Add-RouterCadenceRefreshes { param($Now) return 0 }
    $pruned = Invoke-RouterCadence -Now $pruneNow -CheckOnly
    foreach ($name in $pruneFiles.Keys) {
        Assert-True ((Test-Path -LiteralPath (Join-Path $failureDir $name)) -eq $pruneFiles[$name]) "pruning keep/delete: $name"
    }
    Assert-True ($pruned.ran.Count -eq 0) 'failure pruning dispatches no research in check-only mode'
    # Reviewer reproduction: the same stale model on consecutive overnight runs (refreshes are queued only with -Refresh).
    . (Join-Path $PSScriptRoot '../run-router-cadence.ps1')
    $episodeState = Join-Path $temp 'stopped-episode'; [IO.Directory]::CreateDirectory($episodeState) | Out-Null
    $env:DT_MODEL_ROUTER_STATE = $episodeState
    $script:cadenceClock = [datetimeoffset]'2026-08-01T05:00:00Z'
    $script:RouterDiagnosisClock = { $script:cadenceClock }
    function Invoke-RouterModelCheck { param([switch]$Force,$Now) return [pscustomobject]@{new_models=@()} }
    function Get-RouterStaleReadingModels { param($Months,$Now) return @('gpt-6.1-sol') }
    function Get-RouterCodexUsage { return $null }
    function Resolve-RouterDispatchFailure { param($Vendor,$ErrorText) return [pscustomobject]@{verdict='unexplained';checks=@{http=$true;dns=$true;status='operational'}} }
    function Send-RouterAlert { param($Key,$Message) }
    $script:episodeCalls = 0
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) $script:episodeCalls++; throw 'reviewer unexplained failure' }
    $nightOne = Invoke-RouterCadence -Now $script:cadenceClock.LocalDateTime -Refresh -WarningAction SilentlyContinue
    Assert-True ($script:episodeCalls -eq 2 -and $nightOne.ran.Count -eq 1 -and $nightOne.pending -eq 0) 'stale refresh unexplained stop is consumed after exactly two calls'
    $script:cadenceClock = $script:cadenceClock.AddDays(1)
    $nightTwo = Invoke-RouterCadence -Now $script:cadenceClock.LocalDateTime -Refresh -WarningAction SilentlyContinue
    Assert-True ($script:episodeCalls -eq 2 -and $nightTwo.ran.Count -eq 0 -and $nightTwo.pending -eq 0) 'next overnight stale refresh makes zero additional dispatches'
    $script:cadenceClock = $script:cadenceClock.AddDays(1)
    & {
        function Get-Date { return $script:cadenceClock.LocalDateTime }
        [void](Invoke-Expression (($nightOne.needs_you[0] -split 'Re-enqueue: ',2)[1]))
    }
    $nightThree = Invoke-RouterCadence -Now $script:cadenceClock.LocalDateTime -Refresh -WarningAction SilentlyContinue
    Assert-True ($script:episodeCalls -eq 4 -and $nightThree.ran.Count -eq 1) 'generated operator command restores actual research dispatch'
    Write-Output "SUMMARY: $script:passed passed"
} finally { Exit-RouterTestCodexHome $fixtureCodexHome;
    $env:DT_MODEL_ROUTER_STATE = $priorState
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorTransport
    $env:DT_MODEL_ROUTER_CODEX_SESSIONS = $priorSessions
    Remove-Item -LiteralPath $temp -Recurse -Force
}
