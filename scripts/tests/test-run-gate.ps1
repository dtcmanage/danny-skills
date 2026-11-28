Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../run-gate.ps1')
$passed = 0
function Assert-Gate([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_FAIL: $Message" }
    $script:passed++
}
$all = @(Get-GateSteps)
foreach ($suite in @(
    @{Name='dt-job';Path='skills/dt-build/scripts/tests/test-dt-job.ps1'},
    @{Name='build-regressions';Path='skills/dt-build/scripts/test-dt-build-regressions.ps1'}
)) {
    $source = [IO.File]::ReadAllText((Join-Path $repo $suite.Path))
    $range = [regex]::Match($source, 'ValidateRange\(0,\s*(\d+)\)\]\[int\]\$Shard')
    $step = @($all | Where-Object Name -eq $suite.Name)[0]
    Assert-Gate ($range.Success -and $step.Slots -eq [int]$range.Groups[1].Value) "$($suite.Name) slot weight matches all independent shard workers"
}
$cheap = @($all | Where-Object Skill -eq '*')
$build = @(Select-GateSteps -ChangedPaths @('skills/dt-build/scripts/a.ps1'))
Assert-Gate ($build.Count -eq $cheap.Count + 6) 'dt-build selects its six suites and every cheap check'
Assert-Gate (@($build | Where-Object { $_.Skill -notin @('*','dt-build') }).Count -eq 0) 'dt-build excludes unrelated suites'
foreach ($path in @('scripts/a.ps1','references/a.md','tools/a.ps1','.ship.json','.claude-plugin/unknown.json','README.md','skills/unknown/a.ps1')) {
    Assert-Gate (@(Select-GateSteps -ChangedPaths @($path)).Count -eq $all.Count) "full gate for shared/unknown $path"
}
Assert-Gate (@(Select-GateSteps -ChangedPaths @()).Count -eq $cheap.Count) 'empty diff keeps cheap checks'
Assert-Gate (@(Select-GateSteps -ChangedPaths @('skills/dt-review/SKILL.md')).Count -eq $cheap.Count + 2) 'review selects both suites'
Assert-Gate (@(Select-GateSteps -ChangedPaths @('skills/dt-build/a') -Full).Count -eq $all.Count) 'Full overrides selection'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('gate-tests-' + [guid]::NewGuid().ToString('N'))
$originalRepo = $repo
try {
    New-Item -ItemType Directory -Path (Join-Path $fixture 'scripts/lib') -Force | Out-Null
    & git -C $fixture init -q
    & git -C $fixture config user.name Fixture
    & git -C $fixture config user.email fixture@example.invalid
    'base' | Set-Content (Join-Path $fixture 'base')
    New-Item -ItemType Directory -Path (Join-Path $fixture '.claude-plugin'),(Join-Path $fixture 'skills/dt-roadmap') -Force | Out-Null
    'fixture' | Set-Content (Join-Path $fixture 'skills/dt-roadmap/SKILL.md')
    '{"name":"fixture","version":"1.0.0","metadata":{"changelog":["1.0.0 initial"]}}' | Set-Content (Join-Path $fixture '.claude-plugin/plugin.json')
    '{"name":"fixture","metadata":{"version":"1.0.0"},"plugins":[{"name":"fixture","version":"1.0.0"}]}' | Set-Content (Join-Path $fixture '.claude-plugin/marketplace.json')
    & git -C $fixture add .
    & git -C $fixture commit -qm base
    & git -C $fixture branch -M main
    & git -C $fixture checkout -qb feat/test
    New-Item -ItemType Directory -Path (Join-Path $fixture 'skills/dt-build') -Force | Out-Null
    'fixture' | Set-Content (Join-Path $fixture 'skills/dt-build/change.ps1')
    $repo = $fixture
    Assert-Gate ((@(Get-GateChangedPaths auto) -join ',') -eq 'skills/dt-build/change.ps1') 'untracked skill change is selected'
    & git -C $fixture add .
    & git -C $fixture commit -qm change
    Assert-Gate ((@(Get-GateChangedPaths auto) -join ',') -eq 'skills/dt-build/change.ps1') 'committed skill change uses merge base'
    '{"metadata":{"changelog":["1.0.1 dt-roadmap","1.0.0 initial"]},"version":"1.0.1","name":"fixture"}' | Set-Content (Join-Path $fixture '.claude-plugin/plugin.json')
    '{"name":"fixture","metadata":{"version":"1.0.1"},"plugins":[{"name":"fixture","version":"1.0.1"}]}' | Set-Content (Join-Path $fixture '.claude-plugin/marketplace.json')
    $releasePaths = @('skills/dt-roadmap/SKILL.md','skills/dt-roadmap/CHANGELOG.md','.claude-plugin/plugin.json','.claude-plugin/marketplace.json')
    $roadmap = @(Select-GateSteps -ChangedPaths $releasePaths)
    Assert-Gate ($roadmap.Count -eq $cheap.Count + 4 -and @($roadmap | Where-Object { $_.Skill -notin @('*','dt-roadmap') }).Count -eq 0) 'roadmap plus plugin release selects its four suites and cheap checks only'
    Assert-Gate ((@($roadmap | Where-Object Skill -eq 'dt-roadmap').Command -join ' ') -match 'test-hardware-roadmap.ps1' -and (@($roadmap | Where-Object Skill -eq 'dt-roadmap').Command -join ' ') -match 'test-design-coverage.ps1' -and (@($roadmap | Where-Object Skill -eq 'dt-roadmap').Command -join ' ') -match 'test-milestone-sources.ps1' -and (@($roadmap | Where-Object Skill -eq 'dt-roadmap').Command -join ' ') -match 'test-command-intake.ps1') 'catalog includes every roadmap suite'
    & git -C $fixture add .claude-plugin
    & git -C $fixture commit -qm release
    Assert-Gate (@(Select-GateSteps -ChangedPaths $releasePaths).Count -eq $cheap.Count + 4) 'committed release fields use merge base too'
    '{"name":"changed","version":"1.0.1"}' | Set-Content (Join-Path $fixture '.claude-plugin/plugin.json')
    Assert-Gate (@(Select-GateSteps -ChangedPaths $releasePaths).Count -eq $all.Count) 'plugin non-version field change forces full'
    & git -C $fixture checkout -- .claude-plugin/plugin.json
    '{"name":"fixture","metadata":{"version":"1.0.1"},"plugins":[{"name":"changed","version":"1.0.1"}]}' | Set-Content (Join-Path $fixture '.claude-plugin/marketplace.json')
    Assert-Gate (@(Select-GateSteps -ChangedPaths $releasePaths).Count -eq $all.Count) 'marketplace nested non-version field change forces full'
    '{broken' | Set-Content (Join-Path $fixture '.claude-plugin/plugin.json')
    Assert-Gate (@(Select-GateSteps -ChangedPaths $releasePaths).Count -eq $all.Count) 'malformed release JSON forces full'
    $repo = $originalRepo

    # Run the actual scheduler against disposable steps, including two different failures.
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../run-gate.ps1'))
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    $catalog = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-GateSteps' },$true)
    $replacement = @'
function Get-GateSteps {
 @(
 @{Name='failure-one';Skill='*';Command="Write-Output 'first stdout'; [Console]::Error.WriteLine('first stderr'); exit 3"}
 @{Name='failure-two';Skill='*';Command="Write-Output 'second stdout'; throw 'second failure'"}
 @{Name='success';Skill='*';Command='Write-Output ''completed after failures''; Write-Output (''startup profile: '' + $env:DOTNET_MultiCoreJitMinNumCpus + ''/'' + $env:COMPlus_MultiCoreJitMinNumCpus); exit 0'}
 )
}
'@
    $source = $source.Remove($catalog.Extent.StartOffset,$catalog.Extent.Text.Length).Insert($catalog.Extent.StartOffset,$replacement)
    [IO.File]::WriteAllText((Join-Path $fixture 'scripts/run-gate.ps1'),$source)
    Copy-Item (Join-Path $PSScriptRoot '../lib/resolve-test-python.ps1') (Join-Path $fixture 'scripts/lib/')
    Copy-Item (Join-Path $PSScriptRoot '../lib/runtime-test-admission.ps1') (Join-Path $fixture 'scripts/lib/')
    Copy-Item (Join-Path $originalRepo 'requirements-test.txt') $fixture
    $startupDir = Join-Path $fixture 'skills/dt-build/scripts'
    New-Item -ItemType Directory -Path $startupDir -Force | Out-Null
    Copy-Item (Join-Path $originalRepo 'skills/dt-build/scripts/powershell-startup.ps1') $startupDir
    $logs = Join-Path $fixture 'logs'
    $startupEnvironment = @{}
    foreach ($name in @('DOTNET_MultiCoreJitMinNumCpus', 'COMPlus_MultiCoreJitMinNumCpus', 'XDG_CACHE_HOME')) {
        $startupEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    try {
        # The gate must protect its own children, even when the caller has not
        # opted out. A disposable Unix cache keeps that control launch isolated.
        $env:DOTNET_MultiCoreJitMinNumCpus = '1'
        $env:COMPlus_MultiCoreJitMinNumCpus = '1'
        if (-not $IsWindows) { $env:XDG_CACHE_HOME = Join-Path $fixture 'startup-cache' }
        $output = @(& pwsh -NoProfile -File (Join-Path $fixture 'scripts/run-gate.ps1') -Full -ThrottleLimit 2 -LogDirectory $logs 2>&1) -join "`n"
        $schedulerExit = $LASTEXITCODE
    }
    finally {
        foreach ($name in $startupEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $startupEnvironment[$name]) }
    }
    Assert-Gate ($schedulerExit -eq 1) 'any failed step makes the scheduler fail'
    Assert-Gate ($output.Contains('FAILED: failure-one') -and $output.Contains('FAILED: failure-two')) 'all failures are named'
    Assert-Gate ($output.Contains('first stdout') -and $output.Contains('first stderr') -and $output.Contains('second failure')) 'tails retain both streams from every failure'
    $timings = Get-Content -Raw (Join-Path $logs 'timings.json') | ConvertFrom-Json
    Assert-Gate ($timings.steps.Count -eq 3 -and @($timings.steps | Where-Object name -eq 'success')[0].exit_code -eq 0) 'scheduler continues after failures and records all durations'
    Assert-Gate ((Get-Content -Raw (Join-Path $logs 'success.log')).Contains('completed after failures')) 'successful output remains available'
    Assert-Gate ((Get-Content -Raw (Join-Path $logs 'success.log')).Contains('startup profile: 65535/65535')) 'gate launch boundary protects a real child without an inherited opt-out'
}
finally { $repo = $originalRepo; Remove-Item -LiteralPath $fixture -Recurse -Force }
Write-Output "PASS: gate runner ($passed assertions)"
