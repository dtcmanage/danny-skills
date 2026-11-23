# Regression test: dt-ship refuses to merge and purge a worktree that a live
# dt-job still uses, and proceeds with -AllowLiveJobs; -KnownIssuesPath puts the
# run's known issues in the summary without blocking the ship.
#   pwsh -NoProfile -File skills/dt-ship/tests/test-ship-live-jobs.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ship = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\ship.ps1'
$failures = 0
function Assert {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Output "PASS: $Name" } else { Write-Output "FAIL: $Name"; $script:failures++ }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ship-live-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$repo = Join-Path $root 'repo'
$tree = Join-Path $root 'feature'
$state = Join-Path $root 'state'
$runFolder = Join-Path $root 'run'
$oldState = $env:DT_BUILD_STATE_DIR
try {
    New-Item -ItemType Directory -Path $repo, $state, (Join-Path $runFolder 'jobs') -Force | Out-Null
    git -C $repo init -q -b main
    git -C $repo config user.email 'test@example.com'
    git -C $repo config user.name 'test'
    git -C $repo config commit.gpgsign false
    Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'a'
    git -C $repo add -A; git -C $repo commit -q -m 'base'
    git -C $repo worktree add -q -b feat/x $tree main
    Set-Content -LiteralPath (Join-Path $tree 'f.txt') -Value 'f'
    git -C $tree add -A; git -C $tree commit -q -m 'feature'

    @{ runs = @(@{ run_id = 'fixture-run'; run_folder = $runFolder }) } | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $state 'active-runs.json')
    @{ job_id = 'j-0001'; status = 'running'; working_directory = $tree; command = 'pytest' } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $runFolder 'jobs\j-0001.json')
    # A running job record with no command/working_directory (other job kinds) must be skipped, not crash.
    @{ job_id = 'j-0002'; status = 'running' } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $runFolder 'jobs\j-0002.json')
    $env:DT_BUILD_STATE_DIR = $state

    Push-Location $repo
    try { $out = & pwsh -NoProfile -File $ship -RepoRoot $repo -Branch x -SkipPull -SkipPush -SkipGate -Json } finally { Pop-Location }
    $result = ($out -join "`n") | ConvertFrom-Json
    Assert ($result.failed_step -eq 'preflight-live-jobs') 'live dt-job: ship stops at preflight-live-jobs'
    Assert (-not $result.merged) 'live dt-job: nothing merged'
    Assert (Test-Path -LiteralPath $tree) 'live dt-job: worktree kept'
    Assert ([string]$result.error_message -like '*j-0001*') 'live dt-job: message names the job'

    Push-Location $repo
    try { $out = & pwsh -NoProfile -File $ship -RepoRoot $repo -Branch x -SkipPull -SkipPush -SkipGate -AllowLiveJobs -Json } finally { Pop-Location }
    $result = ($out -join "`n") | ConvertFrom-Json
    Assert ($result.failed_step -ne 'preflight-live-jobs') '-AllowLiveJobs: preflight passes'
    Assert ([bool]$result.merged) '-AllowLiveJobs: branch merged'

    # Release summary carries known issues; a named missing file fails closed before any mutation.
    git -C $repo worktree add -q -b feat/y (Join-Path $root 'feature-y') main
    Set-Content -LiteralPath (Join-Path $root 'feature-y/g.txt') -Value 'g'
    git -C (Join-Path $root 'feature-y') add -A; git -C (Join-Path $root 'feature-y') commit -q -m 'feature y'
    Push-Location $repo
    try { $out = & pwsh -NoProfile -File $ship -RepoRoot $repo -Branch y -SkipPull -SkipPush -SkipGate -KnownIssuesPath (Join-Path $root 'missing.md') -Json } finally { Pop-Location }
    $result = ($out -join "`n") | ConvertFrom-Json
    Assert ($result.failed_step -eq 'preflight-known-issues' -and -not $result.merged) 'missing -KnownIssuesPath fails closed before merge'
    $known = Join-Path $runFolder 'deferred-findings.md'
    Set-Content -LiteralPath $known -Value "# Deferred findings`n`n- later idea`n`n## Known issues`n`n- **M07 F1** (docs, ship): Handoff wording. Where: docs/h.md. Why it does not block: wording only. Fix: next release.`n"
    Push-Location $repo
    try { $out = & pwsh -NoProfile -File $ship -RepoRoot $repo -Branch y -SkipPull -SkipPush -SkipGate -KnownIssuesPath $known -Json } finally { Pop-Location }
    $result = ($out -join "`n") | ConvertFrom-Json
    Assert ([bool]$result.merged) 'known issues never block the ship'
    Assert (@($result.known_issues).Count -eq 1 -and @($result.known_issues)[0] -like '- **M07 F1***') 'summary lists known issues only (not other deferred entries)'
}
finally {
    $env:DT_BUILD_STATE_DIR = $oldState
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Output "$failures failure(s)"; exit 1 }
Write-Output 'All dt-ship live-job tests passed.'
