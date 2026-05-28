# Rebase every local feature branch onto main.
#
# 1. Verify repo + remember starting branch.
# 2. Refresh main (checkout + pull origin main).
# 3. Enumerate local branches excluding main.
# 4. Skip any feature branch checked out in another worktree (report it).
# 5. Invoke repo-level rebase-onto-main.ps1 per remaining branch.
# 6. Stop and report on the first conflict; never use --skip silently.
# 7. Return to the starting branch (or main if unclear).
#
# Returns a JSON summary: starting_branch, main_pulled, feature_branches, skipped_worktree, results, conflicted_branch.

param(
    [switch]$Json,
    [switch]$SkipPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Git {
    param([string[]]$GitArgs)
    $output = & git @GitArgs 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output -join "`n")
    }
}

# Path resolution (junction-safe per references/conventions.md)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptDir
$resolved = (Get-Item -LiteralPath $skillRoot).ResolveLinkTarget($true)
if ($resolved) { $skillRoot = $resolved.FullName }
$repoRoot = Split-Path -Parent (Split-Path -Parent $skillRoot)
$rebaseScript = Join-Path $repoRoot 'scripts\git\rebase-onto-main.ps1'

if (-not (Test-Path -LiteralPath $rebaseScript)) {
    throw "Missing shared helper: $rebaseScript"
}

# Verify git repo
$insideRepo = Invoke-Git -GitArgs @('rev-parse', '--is-inside-work-tree')
if ($insideRepo.ExitCode -ne 0 -or $insideRepo.Output.Trim() -ne 'true') {
    throw "Not inside a git repository. Run this from inside the working tree."
}

# Remember starting branch
$current = Invoke-Git -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')
$startingBranch = $current.Output.Trim()
if ([string]::IsNullOrWhiteSpace($startingBranch) -or $startingBranch -eq 'HEAD') {
    $startingBranch = 'main'
}

# Refresh main
$mainPulled = $false
$checkoutMain = Invoke-Git -GitArgs @('checkout', 'main')
if ($checkoutMain.ExitCode -ne 0) {
    throw "Could not checkout main: $($checkoutMain.Output)"
}

if (-not $SkipPull) {
    $pullMain = Invoke-Git -GitArgs @('pull', 'origin', 'main')
    if ($pullMain.ExitCode -ne 0) {
        throw "git pull origin main failed: $($pullMain.Output)"
    }
    $mainPulled = $true
}

# Branches checked out in worktrees cannot be checked out from the primary tree.
$wt = Invoke-Git -GitArgs @('worktree', 'list', '--porcelain')
$worktreeBranches = @()
foreach ($line in ($wt.Output -split "`r?`n")) {
    if ($line -match '^branch refs/heads/(.+)$') { $worktreeBranches += $Matches[1] }
}

# List feature branches
$branchList = Invoke-Git -GitArgs @('branch', '--list', '--format=%(refname:short)')
if ($branchList.ExitCode -ne 0) {
    throw "git branch --list failed: $($branchList.Output)"
}

$allBranches = $branchList.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$candidateBranches = @($allBranches | Where-Object { $_ -ne 'main' })
$skippedWorktree = @($candidateBranches | Where-Object { $worktreeBranches -contains $_ })
$featureBranches = @($candidateBranches | Where-Object { $worktreeBranches -notcontains $_ })

$results = @()
$conflictedBranch = $null

foreach ($branch in $featureBranches) {
    $rebaseOutput = & pwsh -NoProfile -File $rebaseScript -Branch $branch -Json
    $rebaseExit = $LASTEXITCODE

    $parsed = $null
    try { $parsed = $rebaseOutput | ConvertFrom-Json -ErrorAction Stop } catch {
        $results += [pscustomobject]@{
            branch = $branch
            status = 'error'
            error_message = "Could not parse helper output: $rebaseOutput"
        }
        $conflictedBranch = $branch
        break
    }

    $results += $parsed

    if ($parsed.status -eq 'conflict') {
        $conflictedBranch = $branch
        break
    }
    if ($parsed.status -eq 'error') {
        $conflictedBranch = $branch
        break
    }
}

# Return to the starting branch unless we're mid-conflict on a different branch
if (-not $conflictedBranch) {
    $returnTarget = $startingBranch
    if ($featureBranches -notcontains $returnTarget -and $returnTarget -ne 'main') {
        $returnTarget = 'main'
    }
    $returnCheckout = Invoke-Git -GitArgs @('checkout', $returnTarget)
    if ($returnCheckout.ExitCode -ne 0) {
        Write-Warning "Could not return to '$returnTarget': $($returnCheckout.Output)"
    }
}

$summary = [pscustomobject]@{
    starting_branch = $startingBranch
    main_pulled = $mainPulled
    feature_branches = $featureBranches
    skipped_worktree = $skippedWorktree
    results = $results
    conflicted_branch = $conflictedBranch
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 6
    if ($conflictedBranch) { exit 2 }
    exit 0
}

Write-Output "Starting branch: $startingBranch"
Write-Output "main pulled: $mainPulled"
Write-Output ("Feature branches: " + ($featureBranches -join ', '))
if ($skippedWorktree.Count -gt 0) {
    Write-Output ("Skipped (checked out in a worktree): " + ($skippedWorktree -join ', '))
}
foreach ($r in $results) {
    if ($r.status -eq 'clean') {
        Write-Output "  [OK] $($r.branch)"
    }
    elseif ($r.status -eq 'conflict') {
        Write-Warning "  [CONFLICT] $($r.branch) - files: $($r.conflicted_files -join ', ')"
    }
    else {
        Write-Warning "  [ERROR] $($r.branch) - $($r.error_message)"
    }
}

if ($conflictedBranch) {
    Write-Warning "Stopped on '$conflictedBranch'. Repo is mid-rebase; resolve or 'git rebase --abort'."
    exit 2
}

Write-Output "All feature branches rebased onto main cleanly."
