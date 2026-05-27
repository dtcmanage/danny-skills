# Rebase every local feature branch onto dev.
#
# 1. Verify repo + remember starting branch.
# 2. Refresh dev (checkout + pull origin dev).
# 3. Enumerate local branches excluding main/dev.
# 4. Invoke repo-level rebase-onto-dev.ps1 per branch.
# 5. Stop and report on the first conflict; never use --skip silently.
# 6. Return to the starting branch (or dev if unclear).
#
# Returns a JSON summary: starting_branch, dev_pulled, branches[], conflicted_branch.

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
$rebaseScript = Join-Path $repoRoot 'scripts\git\rebase-onto-dev.ps1'

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
    $startingBranch = 'dev'
}

# Refresh dev
$devPulled = $false
$checkoutDev = Invoke-Git -GitArgs @('checkout', 'dev')
if ($checkoutDev.ExitCode -ne 0) {
    throw "Could not checkout dev: $($checkoutDev.Output)"
}

if (-not $SkipPull) {
    $pullDev = Invoke-Git -GitArgs @('pull', 'origin', 'dev')
    if ($pullDev.ExitCode -ne 0) {
        throw "git pull origin dev failed: $($pullDev.Output)"
    }
    $devPulled = $true
}

# List feature branches
$branchList = Invoke-Git -GitArgs @('branch', '--list', '--format=%(refname:short)')
if ($branchList.ExitCode -ne 0) {
    throw "git branch --list failed: $($branchList.Output)"
}

$allBranches = $branchList.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$featureBranches = @($allBranches | Where-Object { $_ -ne 'main' -and $_ -ne 'dev' })

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
    if ($featureBranches -notcontains $returnTarget -and $returnTarget -notin @('main', 'dev')) {
        $returnTarget = 'dev'
    }
    $returnCheckout = Invoke-Git -GitArgs @('checkout', $returnTarget)
    if ($returnCheckout.ExitCode -ne 0) {
        Write-Warning "Could not return to '$returnTarget': $($returnCheckout.Output)"
    }
}

$summary = [pscustomobject]@{
    starting_branch = $startingBranch
    dev_pulled = $devPulled
    feature_branches = $featureBranches
    results = $results
    conflicted_branch = $conflictedBranch
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 6
    if ($conflictedBranch) { exit 2 }
    exit 0
}

Write-Output "Starting branch: $startingBranch"
Write-Output "dev pulled: $devPulled"
Write-Output ("Feature branches: " + ($featureBranches -join ', '))
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

Write-Output "All feature branches rebased onto dev cleanly."
