# Rebase a named feature branch onto main, then fast-forward merge into main,
# then delete the branch.
#
# 1. Verify repo + clean working tree on the feature branch.
# 2. Resolve the branch name (supports bare <name>, feat/<name>, or feature/<name>).
# 3. Refresh main (checkout + pull origin main).
# 4. Rebase via repo-level scripts/git/rebase-onto-main.ps1.
# 5. Fast-forward merge main <- feature (--ff-only; never --no-ff).
# 6. Delete the local feature branch.
#
# Returns a JSON summary on -Json: branch, resolved_branch, rebase_status,
# merge_status, branch_deleted, commit_range.

param(
    [Parameter(Mandatory)]
    [string]$Branch,

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

function Fail {
    param([string]$Message, [hashtable]$Detail = @{})
    $obj = [ordered]@{
        branch = $Branch
        status = 'error'
        error_message = $Message
    }
    foreach ($k in $Detail.Keys) { $obj[$k] = $Detail[$k] }
    $result = [pscustomobject]$obj
    if ($Json) { $result | ConvertTo-Json -Depth 6; exit 1 }
    throw $Message
}

# Path resolution (junction-safe)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptDir
$resolved = (Get-Item -LiteralPath $skillRoot).ResolveLinkTarget($true)
if ($resolved) { $skillRoot = $resolved.FullName }
$repoRoot = Split-Path -Parent (Split-Path -Parent $skillRoot)
$rebaseScript = Join-Path $repoRoot 'scripts\git\rebase-onto-main.ps1'
if (-not (Test-Path -LiteralPath $rebaseScript)) {
    Fail "Missing shared helper: $rebaseScript"
}

# Verify git repo
$insideRepo = Invoke-Git -GitArgs @('rev-parse', '--is-inside-work-tree')
if ($insideRepo.ExitCode -ne 0 -or $insideRepo.Output.Trim() -ne 'true') {
    Fail "Not inside a git repository."
}

# Resolve branch name (bare, then feat/, then feature/)
$resolvedBranch = $null
foreach ($candidate in @($Branch, "feat/$Branch", "feature/$Branch")) {
    $exists = Invoke-Git -GitArgs @('rev-parse', '--verify', "refs/heads/$candidate")
    if ($exists.ExitCode -eq 0) { $resolvedBranch = $candidate; break }
}

if (-not $resolvedBranch) {
    $branchList = Invoke-Git -GitArgs @('branch', '--list', '--format=%(refname:short)')
    $branches = $branchList.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    Fail "No local branch named '$Branch', 'feat/$Branch', or 'feature/$Branch'. Local branches: $($branches -join ', ')"
}

# Check for uncommitted changes on the feature branch
$checkoutFeature = Invoke-Git -GitArgs @('checkout', $resolvedBranch)
if ($checkoutFeature.ExitCode -ne 0) {
    Fail "Checkout of '$resolvedBranch' failed: $($checkoutFeature.Output)"
}

$status = Invoke-Git -GitArgs @('status', '--porcelain')
if (-not [string]::IsNullOrWhiteSpace($status.Output)) {
    Fail "Uncommitted changes on '$resolvedBranch'. Commit or stash first." @{ uncommitted = $status.Output }
}

# Refresh main
$mainPulled = $false
$checkoutMain = Invoke-Git -GitArgs @('checkout', 'main')
if ($checkoutMain.ExitCode -ne 0) {
    Fail "Could not checkout main: $($checkoutMain.Output)"
}
if (-not $SkipPull) {
    $pullMain = Invoke-Git -GitArgs @('pull', 'origin', 'main')
    if ($pullMain.ExitCode -ne 0) {
        Fail "git pull origin main failed: $($pullMain.Output)"
    }
    $mainPulled = $true
}

$mainShaBefore = (Invoke-Git -GitArgs @('rev-parse', 'main')).Output.Trim()

# Rebase via shared helper
$rebaseOutput = & pwsh -NoProfile -File $rebaseScript -Branch $resolvedBranch -Json
$rebaseExit = $LASTEXITCODE
$rebaseParsed = $null
try { $rebaseParsed = $rebaseOutput | ConvertFrom-Json -ErrorAction Stop } catch {
    Fail "Could not parse rebase helper output: $rebaseOutput"
}

if ($rebaseParsed.status -ne 'clean') {
    $detail = @{ rebase = $rebaseParsed }
    Fail "Rebase of '$resolvedBranch' onto main failed with status '$($rebaseParsed.status)'. Repo may be mid-rebase." $detail
}

# Fast-forward merge into main
$checkoutMainAgain = Invoke-Git -GitArgs @('checkout', 'main')
if ($checkoutMainAgain.ExitCode -ne 0) {
    Fail "Could not return to main for merge: $($checkoutMainAgain.Output)"
}

$merge = Invoke-Git -GitArgs @('merge', '--ff-only', $resolvedBranch)
if ($merge.ExitCode -ne 0) {
    Fail "git merge --ff-only failed (should not happen after a clean rebase): $($merge.Output). Do NOT fall back to --no-ff."
}

$mainShaAfter = (Invoke-Git -GitArgs @('rev-parse', 'main')).Output.Trim()
$commitRange = if ($mainShaBefore -ne $mainShaAfter) { "$($mainShaBefore.Substring(0,7))..$($mainShaAfter.Substring(0,7))" } else { 'no-op' }

# Delete the feature branch
$delete = Invoke-Git -GitArgs @('branch', '-d', $resolvedBranch)
$branchDeleted = ($delete.ExitCode -eq 0)
if (-not $branchDeleted) {
    Write-Warning "Branch '$resolvedBranch' was not deleted: $($delete.Output)"
}

$summary = [pscustomobject]@{
    branch = $Branch
    resolved_branch = $resolvedBranch
    main_pulled = $mainPulled
    rebase_status = $rebaseParsed.status
    merge_status = 'ff-only'
    commit_range = $commitRange
    branch_deleted = $branchDeleted
    status = 'success'
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 6
    exit 0
}

Write-Output "Merged '$resolvedBranch' into main (ff-only). Range: $commitRange."
if ($branchDeleted) {
    Write-Output "Deleted local branch '$resolvedBranch'."
} else {
    Write-Output "Branch '$resolvedBranch' was NOT deleted (see warning above)."
}
