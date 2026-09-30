Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../run-router-cadence.ps1')
. (Join-Path $PSScriptRoot '../resolve-model.ps1')
. (Join-Path $PSScriptRoot '../register-router-schedules.ps1')

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
    function Start-RouterCanaryDetached { param($Models) return [pscustomobject]@{launched=$true} }
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6.1-sol' } else { 'claude-opus-5-5' } }
    [void](Invoke-RouterModelCheck -Force -Now $now)
    $script:RouterModelCheckFetcher = { param($vendor) if ($vendor.id -eq 'openai') { 'gpt-6.1-sol'; 'gpt-6-new' } else { 'claude-opus-5-5' } }
    [void](Invoke-RouterModelCheck -Force -Now $now.AddHours(1))
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
    Assert-True (@($refresh | Where-Object { $_.reason -eq 'benchmark-version' -and $_.categories -contains 'complex-coding' }).Count -eq 1) 'new benchmark version queues category refresh'
    Assert-True ((Compare-RouterBenchmarkVersion '10' '9') -gt 0 -and (Compare-RouterBenchmarkVersion '1.10' '1.9') -gt 0) 'benchmark versions compare numerically'

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
    function Invoke-RouterModelCheck { throw 'lookup called model check' }
    $catalog = [pscustomobject]@{models=@([pscustomobject]@{slug='gpt-6.1-sol';visibility='list'})}
    $first = Resolve-RouterModel -Category complex-coding -Lane codex -Catalog $catalog
    $second = Resolve-RouterModel -Category complex-coding -Lane codex -Catalog $catalog -SkipModelCheck
    Assert-True ($first.model -and $second.model) 'resolver lookup never invokes model check with or without compatibility switch'
    $tasks = @(Register-RouterSchedules)
    Assert-True (@($tasks | Where-Object { $_.name -eq 'ModelRouterCadence' -and $_.schedule -eq 'daily 01:00 ET' -and $_.action -match 'run-hidden\.vbs' }).Count -eq 1) 'overnight schedule uses hidden shim'
    Assert-True (@($tasks | Where-Object { $_.name -eq 'ModelRouterCadenceCheck' -and $_.schedule -eq 'daily 13:00 ET' -and $_.action -match 'run-hidden\.vbs' -and $_.action -match '-CheckOnly' }).Count -eq 1) 'check schedule uses hidden shim'
    $twoPassState = Join-Path $temp 'two-pass'; [IO.Directory]::CreateDirectory($twoPassState) | Out-Null
    $env:DT_MODEL_ROUTER_STATE = $twoPassState
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../approve-router-table.ps1') -Roster -Seed | Out-Null
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../approve-router-table.ps1') -Roster -Approve | Out-Null
    $twoPassReadings = Join-Path $twoPassState 'readings'; [IO.Directory]::CreateDirectory($twoPassReadings) | Out-Null
    $rows = @(@('bench-one','bench-two') | ForEach-Object { [pscustomobject]@{benchmark=$_;version='1';harness='h';effort_class='medium';independent=$true;results=@([pscustomobject]@{model='claude-opus-5-5';score=80;margin=1},[pscustomobject]@{model='gpt-6.1-sol';score=50;margin=1})} })
    [pscustomobject]@{category='complex-coding';readings=$rows} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $twoPassReadings 'complex-coding.json')
    . (Join-Path $PSScriptRoot '../build-roster.ps1')
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
    Write-Output "SUMMARY: $script:passed passed"
} finally { Exit-RouterTestCodexHome $fixtureCodexHome;
    $env:DT_MODEL_ROUTER_STATE = $priorState
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorTransport
    $env:DT_MODEL_ROUTER_CODEX_SESSIONS = $priorSessions
    Remove-Item -LiteralPath $temp -Recurse -Force
}
