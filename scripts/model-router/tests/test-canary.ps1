Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../canary/run-canary.ps1')
. (Join-Path $PSScriptRoot '../update-outcomes.ps1')

$script:passed = 0
function Assert-True([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++; Write-Output "PASS: $Name"
}
$priorState = $env:DT_MODEL_ROUTER_STATE
$testState = Join-Path $env:TEMP ('router-canary-test-' + [guid]::NewGuid().ToString('N'))
$env:DT_MODEL_ROUTER_STATE = $testState
[IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_STATE) | Out-Null
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixtureCodexHome = Enter-RouterTestCodexHome
try {
    $script:diagnosisNow = [datetimeoffset]'2026-10-01T12:00:00Z'
    $script:RouterDiagnosisClock = { $script:diagnosisNow }
    $script:RouterDiagnosisDns = { param($ApiHost) $true }
    $script:RouterDiagnosisHttp = { param($Uri) if ($Uri -like '*connecttest.txt') { return 'connected' }; throw 'fixture status lookup unavailable' }
    $script:sleeps = [System.Collections.Generic.List[int]]::new()
    $script:RouterCanarySleep = { param($Milliseconds) $script:sleeps.Add($Milliseconds); $script:diagnosisNow = $script:diagnosisNow.AddMilliseconds($Milliseconds) }
    $taskRoot = Join-Path $PSScriptRoot '../canary/tasks'
    foreach ($task in @(Get-ChildItem -LiteralPath $taskRoot -Directory | Where-Object Name -ne 'pelican')) {
        & python (Join-Path $task.FullName 'grader.py') (Join-Path $task.FullName 'known-good.txt') | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) "$($task.Name) known-good passes"
        & python (Join-Path $task.FullName 'grader.py') (Join-Path $task.FullName 'known-bad.txt') | Out-Null
        Assert-True ($LASTEXITCODE -ne 0) "$($task.Name) known-bad fails"
    }
    foreach ($badAnswer in @(Get-ChildItem -LiteralPath (Join-Path $taskRoot 'code-review') -Filter 'known-bad-*.txt')) {
        & python (Join-Path $taskRoot 'code-review/grader.py') $badAnswer.FullName | Out-Null
        Assert-True ($LASTEXITCODE -ne 0) "code-review $($badAnswer.Name) fails"
    }
    @([pscustomobject]@{ id='gpt-6-new'; lane='codex'; status='unprofiled' },[pscustomobject]@{ id='claude-new'; lane='claude'; status='unprofiled' }) | ConvertTo-Json | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'known-models.json')
    @([pscustomobject]@{ model='claude-flagged'; job='deep-thinker' }) | ConvertTo-Json | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'drift-marks.json')
    $scope = @(Get-CanaryScope)
    Assert-True ((@($scope | Where-Object picked).Count -gt 0) -and (@($scope | Where-Object new).Count -eq 2) -and (@($scope | Where-Object flagged).Count -eq 1) -and -not @($scope | Where-Object model -eq 'irrelevant').Count) 'scope contains picked, new, flagged, both lanes, nothing else'
    $frontier = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json).codex_models[0]
    @([pscustomobject]@{ id=$frontier; lane='codex'; status='unprofiled' }) | ConvertTo-Json -AsArray | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'known-models.json')
    $scheduledScope = Invoke-RouterCanary -Reason monthly -DryRun
    $releaseScope = Invoke-RouterCanary -Models @($frontier) -Reason post-release -DryRun
    $explicitScope = Invoke-RouterCanary -Models @($frontier) -Reason post-release -ExplicitModels -DryRun
    Assert-True (-not @($scheduledScope.scope | Where-Object model -eq $frontier).Count -and -not @($releaseScope.scope | Where-Object model -eq $frontier).Count -and @($explicitScope.scope | Where-Object model -eq $frontier).Count -eq 1) 'scheduled and post-release canary skip frontier unless explicitly selected'
    $script:invocations = 0
    $fake = { param($model,$lane,$task,$prompt,$run) $script:invocations++; if ($task -eq 'pelican') { return '<svg/>' }; return [IO.File]::ReadAllText((Join-Path $taskRoot "$task/known-good.txt")) }
    $dry = Invoke-RouterCanary -Models @('gpt-6-luna') -DryRun -Invoker $fake
    Assert-True ($script:invocations -eq 0 -and $dry.burn.input_tokens -gt 0 -and $dry.scope.Count -eq 1) 'dry run calls no model and reports burn'
    $snapshot = Get-CanaryBurn -Scope @([pscustomobject]@{ model='claude-haiku-4-5-20251001'; lane='claude'; tasks=@('code-review') })
    Assert-True ($snapshot.unpriced.Count -eq 0 -and $snapshot.rows[0].api_equivalent_usd -gt 0 -and $snapshot.rows[0].input_tokens -eq 171000) 'dated Haiku snapshot priced with Claude cache-write overhead'
    $zeroTask = Get-CanaryBurn -Scope @([pscustomobject]@{ model='gpt-image-2'; lane='codex'; tasks=@() }, [pscustomobject]@{ model='unknown-model-x'; lane='codex'; tasks=@('code-review') })
    Assert-True ((@($zeroTask.unpriced) -join ',') -eq 'unknown-model-x' -and $zeroTask.priced_usd -eq 0) 'zero-call models are not listed as unpriced; all-unpriced scope sums to 0'
    $first = Invoke-RouterCanary -Models @('gpt-6-luna') -Invoker $fake -Now ([datetime]'2026-09-27T10:00:00Z')
    Assert-True ($first.results.Count -eq 3 -and $script:invocations -eq 4 -and @($first.results | Where-Object { -not $_.pass }).Count -eq 0) 'three graded runs per model-task plus pelican'
    $fenced = { param($model,$lane,$task,$prompt,$run) if ($task -eq 'pelican') { return "``````svg`n<svg/>`n``````" }; return "``````python`n" + [IO.File]::ReadAllText((Join-Path $taskRoot "$task/known-good.txt")) + "`n``````" }
    $fencedRun = Invoke-RouterCanary -Models @('claude-haiku-4-5-20251001') -Invoker $fenced -Now ([datetime]'2026-09-27T10:00:30Z')
    Assert-True (@($fencedRun.results | Where-Object { -not $_.pass }).Count -eq 0 -and (Get-CanaryAnswerBody -Answer 'plain text') -eq 'plain text' -and (Get-CanaryAnswerBody -Answer '[16:47:18] plain text') -eq 'plain text' -and (Get-CanaryAnswerBody -Answer "[9:05] ``````python`nx = 1`n``````") -eq 'x = 1' -and (Get-CanaryAnswerBody -Answer "``````python`nx = 1`n``````") -eq 'x = 1') 'markdown-fenced answers are unwrapped before grading; plain answers untouched'
    $rows = @(Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl') | ConvertFrom-Json)
    Assert-True (@($rows | Where-Object model -eq 'gpt-6-luna').Count -eq 3 -and @($rows | Where-Object source -ne canary).Count -eq 0) 'outcomes append canary source'
    $sources = Join-Path $env:DT_MODEL_ROUTER_STATE 'sources.json'
    [IO.File]::WriteAllText($sources,'[]')
    $ingest = Update-RouterOutcomes -SourcesPath $sources -Now ([datetime]'2026-09-27T10:01:00Z')
    Assert-True ($ingest.total_records -eq $rows.Count) 'Update-RouterOutcomes reads canary rows'
    $baseline = Read-RouterJsonObject (Join-Path $env:DT_MODEL_ROUTER_STATE 'canary/baseline.json')
    Assert-True ([double]$baseline.'gpt-6-luna' -eq 1) 'first complete run sets baseline'
    $bad = { param($model,$lane,$task,$prompt,$run) if ($task -eq 'pelican') { return '<svg/>' }; if ($run -eq 1) { return [IO.File]::ReadAllText((Join-Path $taskRoot "$task/known-bad.txt")) }; return [IO.File]::ReadAllText((Join-Path $taskRoot "$task/known-good.txt")) }
    $second = Invoke-RouterCanary -Models @('gpt-6-luna') -Invoker $bad -Now ([datetime]'2026-09-28T10:00:00Z')
    $baseline = Read-RouterJsonObject (Join-Path $env:DT_MODEL_ROUTER_STATE 'canary/baseline.json')
    Assert-True ([double]$baseline.'gpt-6-luna' -eq 1 -and @($second.alerts | Where-Object key -like 'canary-drop:*').Count -eq 1) 'baseline unchanged and 15-point drop alerts'
    $lock = [IO.FileStream]::new((Join-Path $env:DT_MODEL_ROUTER_STATE 'canary.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $blocked = $false
    try { [void](Invoke-RouterCanary -Models @('gpt-6-luna') -Invoker $fake) } catch { $blocked = $_.Exception.Message -match 'CANARY_ALREADY_RUNNING' } finally { $lock.Dispose() }
    Assert-True $blocked 'lock prevents second run'
    $script:launchCalls = 0
    $script:RouterCanaryLauncher = { param($exe,$arguments) $script:launchCalls++; if ($exe -notlike '*wscript*' -or $arguments[0] -notlike '*run-hidden.vbs') { throw 'wrong launcher' } }
    $watch = [Diagnostics.Stopwatch]::StartNew(); [void](Start-RouterCanaryDetached -Models @('gpt-6-new')); $watch.Stop()
    Assert-True ($script:launchCalls -eq 1 -and $watch.ElapsedMilliseconds -lt 3000) 'post-release trigger is detached and non-blocking'
    . (Join-Path $PSScriptRoot '../register-router-schedules.ps1')
    $scheduled = @(Register-RouterSchedules)
    Assert-True ($scheduled.Count -eq 4 -and @($scheduled | Where-Object { $_.launcher -like '*run-hidden.vbs' }).Count -eq 4) 'schedule dry run lists all four hidden-launcher tasks without registration'
    # One stopped model/task must not suppress its siblings or another model.
    @([pscustomobject]@{ id='gpt-6-new'; lane='codex'; status='unprofiled' },[pscustomobject]@{ id='claude-new'; lane='claude'; status='unprofiled' }) | ConvertTo-Json | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'known-models.json')
    $script:cellCalls = @{}
    $failing = { param($model,$lane,$task,$prompt,$run)
        $key = "$model/$task"
        if (-not $script:cellCalls.ContainsKey($key)) { $script:cellCalls[$key]=0 }
        $script:cellCalls[$key]++
        if ($model -eq 'gpt-6-new' -and $task -ne 'pelican') { throw 'fixture vendor failure' }
        if ($task -eq 'pelican') { return '<svg/>' }
        return [IO.File]::ReadAllText((Join-Path $taskRoot "$task/known-good.txt"))
    }
    $failed = Invoke-RouterCanary -Models @('gpt-6-new','claude-new') -Invoker $failing -Now ([datetime]'2026-10-01T12:00:00Z')
    $stopped = @($failed.results | Where-Object stopped)
    Assert-True ($stopped.Count -gt 1 -and @($stopped | Where-Object { $_.model -ne 'gpt-6-new' -or $_.attempts -ne 2 }).Count -eq 0 -and @($failed.results | Where-Object { $_.model -eq 'claude-new' -and $_.pass }).Count -gt 1) 'stopped cells skip remaining repetitions while other tasks and models continue'
    Assert-True (@($failed.alerts | Where-Object key -eq 'vendor-error:codex:canary-20261001-manual:gpt-6-new').Count -eq 1 -and $script:sleeps.Count -eq 0 -and @($script:cellCalls.Values | Where-Object { $_ -gt 3 }).Count -eq 0) 'unexplained retries once immediately and pages once per model per run'
    $persisted = Get-Content (Join-Path (Split-Path $failed.report) 'results.json') -Raw | ConvertFrom-Json
    Assert-True (@($persisted.results | Where-Object stopped).Count -eq $stopped.Count) 'run record marks stopped cells'
    $diagnosedRows = @(Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl') | ConvertFrom-Json | Where-Object run_id -eq 'canary-20261001-manual')
    Assert-True (@($diagnosedRows | Where-Object { $_.model -eq 'gpt-6-new' -and $_.failure_category -eq 'environment' -and $_.diagnosis -eq 'unexplained' }).Count -eq (2 * $stopped.Count) -and @($failed.alerts | Where-Object key -like 'canary-drop:*').Count -eq 0) 'each diagnosed failed attempt carries environment and diagnosis and cannot trigger quality drift'

    $script:cellCalls = @{}; $script:sleeps.Clear()
    $script:RouterDiagnosisDns = { param($ApiHost) $false }
    $script:RouterDiagnosisHttp = { param($Uri) throw 'offline fixture' }
    $offlineInvoker = { param($model,$lane,$task,$prompt,$run) if ($task -eq 'pelican') { return '<svg/>' }; throw 'offline call fixture' }
    $offlineStart = $script:diagnosisNow
    $offline = Invoke-RouterCanary -Models @('gpt-6-luna') -Invoker $offlineInvoker -Now ([datetime]'2026-10-02T12:00:00Z')
    Assert-True (($script:diagnosisNow - $offlineStart).TotalMilliseconds -eq 600000 -and $script:sleeps.Count -eq 10 -and @($script:sleeps | Where-Object { $_ -ne 60000 }).Count -eq 0 -and $offline.results[0].stopped -and $offline.results[0].attempts -eq 1 -and $offline.results[0].diagnosis -eq 'offline') 'offline waits at 60-second intervals bounded to ten minutes per call'
    Assert-True (@($offline.alerts | Where-Object key -like 'vendor-error:*').Count -eq 0) 'offline ceiling does not page unexplained error'

    $script:sleeps.Clear(); $script:reconnectCalls=0
    $script:RouterDiagnosisDns = { param($ApiHost) $script:sleeps.Count -ge 6 }
    $script:RouterDiagnosisHttp = { param($Uri) if ($script:sleeps.Count -lt 6) { throw 'offline fixture' }; if ($Uri -like '*connecttest.txt') { return 'connected' }; throw 'fixture status lookup unavailable' }
    $reconnectInvoker = { param($model,$lane,$task,$prompt,$run)
        if ($task -eq 'pelican') { return '<svg/>' }
        $script:reconnectCalls++
        if ($script:reconnectCalls -eq 1) { throw 'offline fixture' }
        return [IO.File]::ReadAllText((Join-Path $taskRoot "$task/known-good.txt"))
    }
    $reconnected = Invoke-RouterCanary -Models @('gpt-6-luna') -Invoker $reconnectInvoker -Now ([datetime]'2026-10-03T12:00:00Z')
    Assert-True ($script:reconnectCalls -eq 4 -and @($reconnected.results | Where-Object { $_.stopped -or -not $_.pass }).Count -eq 0 -and @($reconnected.alerts | Where-Object key -like 'router-offline:* ET').Count -eq 1) 'reconnection resumes identical call and alerts after more than five minutes'
    $recoveredRows = @(Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl') | ConvertFrom-Json | Where-Object run_id -eq 'canary-20261003-manual')
    Assert-True (@($recoveredRows | Where-Object { $_.diagnosis -eq 'offline' -and $_.failure_category -eq 'environment' }).Count -eq 1 -and @($recoveredRows | Where-Object pass).Count -eq 3) 'recovered offline failure remains diagnosed alongside successful outcomes'

    $script:sleeps.Clear(); $script:RouterDiagnosisDns = { param($ApiHost) $false }
    $script:RouterDiagnosisHttp = { param($Uri) throw 'offline fixture' }
    $partialInvoker = { param($model,$lane,$task,$prompt,$run)
        if ($task -eq 'pelican') { return '<svg/>' }
        $script:diagnosisNow=$script:diagnosisNow.AddSeconds(35)
        throw 'offline after 35 seconds of model call'
    }
    $partialStart=$script:diagnosisNow
    $partial = Invoke-RouterCanary -Models @('gpt-6-luna') -Invoker $partialInvoker -Now ([datetime]'2026-10-04T12:00:00Z')
    Assert-True (($script:diagnosisNow - $partialStart).TotalMilliseconds -eq 600000 -and $script:sleeps[-1] -eq 25000 -and $partial.results[0].stopped) 'offline wait includes time already spent in model call and shortens final sleep'

    $script:sleeps.Clear(); $script:RouterDiagnosisDns = { param($ApiHost) $true }
    $script:RouterDiagnosisHttp = { param($Uri)
        if ($Uri -like '*connecttest.txt') { return 'connected' }
        if ($Uri -like '*components.json') { return [pscustomobject]@{ components=@('Codex API','CLI','Responses' | ForEach-Object { [pscustomobject]@{ id=$_; name=$_; status='major_outage' } }) } }
        return [pscustomobject]@{ incidents=@() }
    }
    $incident = Invoke-RouterCanary -Models @('gpt-6-luna') -Invoker $offlineInvoker -Now ([datetime]'2026-10-05T12:00:00Z')
    Assert-True ($incident.results[0].stopped -and $incident.results[0].diagnosis -eq 'vendor_incident' -and $incident.results[0].attempts -eq 1 -and $script:sleeps.Count -eq 0 -and @($incident.alerts | Where-Object key -like 'vendor-error:*').Count -eq 0) 'vendor incident stops only its cell without unexplained retry or alert'
    Write-Output "SUMMARY: $script:passed passed"
} finally { Exit-RouterTestCodexHome $fixtureCodexHome;
    $env:DT_MODEL_ROUTER_STATE = $priorState
    $resolved = [IO.Path]::GetFullPath($testState)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'router-canary-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
