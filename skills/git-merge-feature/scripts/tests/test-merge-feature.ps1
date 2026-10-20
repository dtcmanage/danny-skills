# Regression tests for merge-feature.ps1 against throwaway repos.
#   pwsh -NoProfile -File skills/git-merge-feature/scripts/tests/test-merge-feature.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'merge-feature.ps1'
$failures = 0

function Assert {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Output "PASS: $Name" } else { Write-Output "FAIL: $Name"; $script:failures++ }
}

function New-Repo {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("mf-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $repo = Join-Path $root 'repo'
    New-Item -ItemType Directory -Path $repo | Out-Null
    git -C $repo init -q -b main
    git -C $repo config user.email 'test@example.com'
    git -C $repo config user.name 'test'
    git -C $repo config commit.gpgsign false
    Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'a'
    git -C $repo add -A; git -C $repo commit -q -m 'base'
    return [pscustomobject]@{ Root = $root; Repo = $repo; Tree = (Join-Path $root 'feature') }
}

# A feature worktree whose history contains a merge commit.
function Add-FeatureWithMerge {
    param($R)
    git -C $R.Repo worktree add -q -b feat/x $R.Tree main
    git -C $R.Tree checkout -q -b side
    Set-Content -LiteralPath (Join-Path $R.Tree 's.txt') -Value 's'
    git -C $R.Tree add -A; git -C $R.Tree commit -q -m 'side'
    git -C $R.Tree checkout -q feat/x
    Set-Content -LiteralPath (Join-Path $R.Tree 'f.txt') -Value 'f'
    git -C $R.Tree add -A; git -C $R.Tree commit -q -m 'feature'
    git -C $R.Tree merge -q --no-ff side -m 'merge side'
    git -C $R.Tree branch -q -D side
}

function Invoke-Merge {
    param($R)
    Push-Location $R.Repo
    try { $out = & pwsh -NoProfile -File $script -Branch x -SkipPull -Json } finally { Pop-Location }
    return ($out | ConvertFrom-Json)
}

# 1. main is an ancestor: the branch lands as-is, merge commit and SHAs kept.
$r = New-Repo
try {
    Add-FeatureWithMerge $r
    $tip = (git -C $r.Repo rev-parse feat/x).Trim()
    $result = Invoke-Merge $r
    $main = (git -C $r.Repo rev-parse main).Trim()
    Assert ($result.rebase_status -eq 'not-needed') 'ancestor main: rebase skipped'
    Assert ($main -eq $tip) 'ancestor main: main equals the original branch tip (no SHA rewrite)'
    Assert ((git -C $r.Repo rev-list --merges --count main).Trim() -eq '1') 'ancestor main: merge commit preserved'
}
finally { Remove-Item -LiteralPath $r.Root -Recurse -Force -ErrorAction SilentlyContinue }

# 2. main moved ahead: the branch is still rebased so the merge stays ff-only.
$r = New-Repo
try {
    git -C $r.Repo worktree add -q -b feat/x $r.Tree main
    Set-Content -LiteralPath (Join-Path $r.Tree 'f.txt') -Value 'f'
    git -C $r.Tree add -A; git -C $r.Tree commit -q -m 'feature'
    Set-Content -LiteralPath (Join-Path $r.Repo 'm.txt') -Value 'm'
    git -C $r.Repo add -A; git -C $r.Repo commit -q -m 'main moved'
    $before = (git -C $r.Repo rev-parse main).Trim()
    $result = Invoke-Merge $r
    Assert ($result.rebase_status -eq 'clean') 'diverged main: rebase ran'
    git -C $r.Repo merge-base --is-ancestor $before main
    Assert ($LASTEXITCODE -eq 0) 'diverged main: merge is a fast-forward of old main'
    Assert (Test-Path -LiteralPath (Join-Path $r.Repo 'f.txt')) 'diverged main: feature change landed'
}
finally { Remove-Item -LiteralPath $r.Root -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures) { Write-Output "$failures failure(s)"; exit 1 }
Write-Output 'All merge-feature tests passed.'
