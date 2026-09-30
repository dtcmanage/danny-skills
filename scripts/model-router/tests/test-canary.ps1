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
    @([pscustomobject]@{ model='claude-flagged'; category='code-review'; lane='claude' }) | ConvertTo-Json | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'drift-flags.json')
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
    Write-Output "PASS: $script:passed canary assertions"
} finally { Exit-RouterTestCodexHome $fixtureCodexHome;
    $env:DT_MODEL_ROUTER_STATE = $priorState
    $resolved = [IO.Path]::GetFullPath($testState)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'router-canary-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
