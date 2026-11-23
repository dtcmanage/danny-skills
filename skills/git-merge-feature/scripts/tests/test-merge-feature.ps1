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
    try { $out = & pwsh -NoProfile -File $script -Branch x -SkipPull -PurgeWorktree -Json } finally { Pop-Location }
    $script:mergeExit = $LASTEXITCODE
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

# Worktree-less fixtures advance main and leave live-session edits in place.
function Add-UncheckedFeature {
    param($R, [switch]$Conflict)
    Set-Content -LiteralPath (Join-Path $R.Repo 'dirty.txt') -Value 'base dirty'
    git -C $R.Repo add -A; git -C $R.Repo commit -q -m 'tracked dirty fixture'
    git -C $R.Repo checkout -q -b feat/x
    Set-Content -LiteralPath (Join-Path $R.Repo 'dirty.txt') -Value 'feature dirty'
    Set-Content -LiteralPath (Join-Path $R.Repo 'f.txt') -Value 'feature'
    if ($Conflict) { Set-Content -LiteralPath (Join-Path $R.Repo 'a.txt') -Value 'feature conflict' }
    git -C $R.Repo add -A; git -C $R.Repo commit -q -m 'feature'
    git -C $R.Repo checkout -q main
    Set-Content -LiteralPath (Join-Path $R.Repo 'm.txt') -Value 'main advanced'
    if ($Conflict) { Set-Content -LiteralPath (Join-Path $R.Repo 'a.txt') -Value 'main conflict' }
    git -C $R.Repo add -A; git -C $R.Repo commit -q -m 'main moved'
    # Conflict fixture keeps the dirty file unrelated to the feature diff.
    $dirtyName = if ($Conflict) { 'm.txt' } else { 'a.txt' }
    Set-Content -LiteralPath (Join-Path $R.Repo $dirtyName) -Value 'live session edits'
    Set-Content -LiteralPath (Join-Path $R.Repo 'untracked.txt') -Value 'live session untracked'
    return $dirtyName
}

# 3. No worktree, diverged main, and unrelated dirty/untracked primary files.
$r = New-Repo
try {
    $dirtyName = Add-UncheckedFeature $r
    $dirtyPath = Join-Path $r.Repo $dirtyName
    $untrackedPath = Join-Path $r.Repo 'untracked.txt'
    $dirtyBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($dirtyPath))
    $untrackedBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($untrackedPath))
    $before = (git -C $r.Repo rev-parse main).Trim()
    $result = Invoke-Merge $r
    Assert ($mergeExit -eq 0 -and $result.status -eq 'success') 'temporary worktree: merge succeeds'
    Assert ($result.temporary_worktree -eq $true) 'temporary worktree: summary marks temporary tree'
    Assert ($result.rebase_status -eq 'clean' -and $result.merge_status -eq 'ff-only') 'temporary worktree: rebase and ff-only merge'
    git -C $r.Repo merge-base --is-ancestor $before main
    Assert ($LASTEXITCODE -eq 0) 'temporary worktree: old main is an ancestor'
    Assert ((git -C $r.Repo rev-list --merges --count main).Trim() -eq '0') 'temporary worktree: no merge commit created'
    Assert ((Get-Content -Raw (Join-Path $r.Repo 'f.txt')).Trim() -eq 'feature') 'temporary worktree: feature landed'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dirtyPath)) -eq $dirtyBefore) 'temporary worktree: dirty tracked bytes preserved'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($untrackedPath)) -eq $untrackedBefore) 'temporary worktree: untracked bytes preserved'
    Assert (@(git -C $r.Repo worktree list --porcelain | Where-Object { $_ -like 'worktree *' }).Count -eq 1) 'temporary worktree: no registration remains'
    Assert ($result.worktree_removed -and -not (Test-Path -LiteralPath $result.worktree_path) -and -not $result.worktree_dir_leftover) 'temporary worktree: directory removed without leftover'
    git -C $r.Repo show-ref --verify --quiet refs/heads/feat/x
    Assert ($LASTEXITCODE -ne 0 -and $result.branch_deleted) 'temporary worktree: branch deleted'
    Assert ((git -C $r.Repo branch --show-current).Trim() -eq 'main') 'temporary worktree: primary stays on main'
}
finally { Remove-Item -LiteralPath $r.Root -Recurse -Force -ErrorAction SilentlyContinue }

# 4. Conflict must abort the rebase and remove the disposable worktree.
$r = New-Repo
try {
    $dirtyName = Add-UncheckedFeature $r -Conflict
    $dirtyPath = Join-Path $r.Repo $dirtyName
    $dirtyBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($dirtyPath))
    $tip = (git -C $r.Repo rev-parse feat/x).Trim()
    $mainBefore = (git -C $r.Repo rev-parse main).Trim()
    $result = Invoke-Merge $r
    Assert ($mergeExit -ne 0 -and $result.status -eq 'error') 'temporary conflict: exits non-zero'
    Assert ($result.temporary_worktree -eq $true) 'temporary conflict: summary marks temporary tree'
    Assert ((git -C $r.Repo rev-parse feat/x).Trim() -eq $tip) 'temporary conflict: branch exists at original SHA'
    Assert ((git -C $r.Repo rev-parse main).Trim() -eq $mainBefore) 'temporary conflict: main unchanged'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dirtyPath)) -eq $dirtyBefore) 'temporary conflict: dirty tracked bytes preserved'
    Assert (@(git -C $r.Repo worktree list --porcelain | Where-Object { $_ -like 'worktree *' }).Count -eq 1) 'temporary conflict: no registration remains'
    Assert (-not (Test-Path -LiteralPath $result.worktree_path)) 'temporary conflict: directory removed'
    Assert ($result.error_message -like '*branch is unchanged*worktree of your own*' -and -not $result.error_message.Contains($result.worktree_path)) 'temporary conflict: recovery points to a user-owned worktree'
}
finally { Remove-Item -LiteralPath $r.Root -Recurse -Force -ErrorAction SilentlyContinue }

# 5. A failure after a successful rebase must also clean the temporary tree.
$r = New-Repo
try {
    $null = Add-UncheckedFeature $r
    $dirtyPath = Join-Path $r.Repo 'dirty.txt'
    Set-Content -LiteralPath $dirtyPath -Value 'live edits block the final merge'
    $dirtyBefore = [IO.File]::ReadAllText($dirtyPath)
    $mainBefore = (git -C $r.Repo rev-parse main).Trim()
    $result = Invoke-Merge $r
    Assert ($mergeExit -ne 0 -and $result.error_message -like '*merge --ff-only failed*') 'temporary merge failure: exits non-zero after rebase'
    Assert (@(git -C $r.Repo worktree list --porcelain | Where-Object { $_ -like 'worktree *' }).Count -eq 1) 'temporary merge failure: no registration remains'
    Assert (-not (Test-Path -LiteralPath $result.worktree_path)) 'temporary merge failure: directory removed'
    Assert ((git -C $r.Repo rev-parse main).Trim() -eq $mainBefore) 'temporary merge failure: main unchanged'
    Assert ([IO.File]::ReadAllText($dirtyPath) -eq $dirtyBefore) 'temporary merge failure: dirty tracked bytes preserved'
    git -C $r.Repo show-ref --verify --quiet refs/heads/feat/x
    Assert ($LASTEXITCODE -eq 0) 'temporary merge failure: branch retained'
}
finally { Remove-Item -LiteralPath $r.Root -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures) { Write-Output "$failures failure(s)"; exit 1 }
Write-Output 'All merge-feature tests passed.'
