# Rebase a named feature branch onto dev, then fast-forward merge into dev,
# then delete the branch.
#
# 1. Verify repo + clean working tree on the feature branch.
# 2. Resolve the branch name (supports `feature/<name>` or bare `<name>`).
# 3. Refresh dev (checkout + pull origin dev).
# 4. Rebase via repo-level scripts/git/rebase-onto-dev.ps1.
# 5. Fast-forward merge dev <- feature (--ff-only; never --no-ff).
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
$rebaseScript = Join-Path $repoRoot 'scripts\git\rebase-onto-dev.ps1'
if (-not (Test-Path -LiteralPath $rebaseScript)) {
    Fail "Missing shared helper: $rebaseScript"
}

# Verify git repo
$insideRepo = Invoke-Git -GitArgs @('rev-parse', '--is-inside-work-tree')
if ($insideRepo.ExitCode -ne 0 -or $insideRepo.Output.Trim() -ne 'true') {
    Fail "Not inside a git repository."
}

# Resolve branch name
$resolvedBranch = $null
$exactExists = Invoke-Git -GitArgs @('rev-parse', '--verify', "refs/heads/$Branch")
if ($exactExists.ExitCode -eq 0) {
    $resolvedBranch = $Branch
}
else {
    $prefixedExists = Invoke-Git -GitArgs @('rev-parse', '--verify', "refs/heads/feature/$Branch")
    if ($prefixedExists.ExitCode -eq 0) {
        $resolvedBranch = "feature/$Branch"
    }
}

if (-not $resolvedBranch) {
    $branchList = Invoke-Git -GitArgs @('branch', '--list', '--format=%(refname:short)')
    $branches = $branchList.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    Fail "No local branch named '$Branch' or 'feature/$Branch'. Local branches: $($branches -join ', ')"
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

# Refresh dev
$devPulled = $false
$checkoutDev = Invoke-Git -GitArgs @('checkout', 'dev')
if ($checkoutDev.ExitCode -ne 0) {
    Fail "Could not checkout dev: $($checkoutDev.Output)"
}
if (-not $SkipPull) {
    $pullDev = Invoke-Git -GitArgs @('pull', 'origin', 'dev')
    if ($pullDev.ExitCode -ne 0) {
        Fail "git pull origin dev failed: $($pullDev.Output)"
    }
    $devPulled = $true
}

$devShaBefore = (Invoke-Git -GitArgs @('rev-parse', 'dev')).Output.Trim()

# Rebase via shared helper
$rebaseOutput = & pwsh -NoProfile -File $rebaseScript -Branch $resolvedBranch -Json
$rebaseExit = $LASTEXITCODE
$rebaseParsed = $null
try { $rebaseParsed = $rebaseOutput | ConvertFrom-Json -ErrorAction Stop } catch {
    Fail "Could not parse rebase helper output: $rebaseOutput"
}

if ($rebaseParsed.status -ne 'clean') {
    $detail = @{ rebase = $rebaseParsed }
    Fail "Rebase of '$resolvedBranch' onto dev failed with status '$($rebaseParsed.status)'. Repo may be mid-rebase." $detail
}

# Fast-forward merge into dev
$checkoutDevAgain = Invoke-Git -GitArgs @('checkout', 'dev')
if ($checkoutDevAgain.ExitCode -ne 0) {
    Fail "Could not return to dev for merge: $($checkoutDevAgain.Output)"
}

$merge = Invoke-Git -GitArgs @('merge', '--ff-only', $resolvedBranch)
if ($merge.ExitCode -ne 0) {
    Fail "git merge --ff-only failed (should not happen after a clean rebase): $($merge.Output). Do NOT fall back to --no-ff."
}

$devShaAfter = (Invoke-Git -GitArgs @('rev-parse', 'dev')).Output.Trim()
$commitRange = if ($devShaBefore -ne $devShaAfter) { "$($devShaBefore.Substring(0,7))..$($devShaAfter.Substring(0,7))" } else { 'no-op' }

# Delete the feature branch
$delete = Invoke-Git -GitArgs @('branch', '-d', $resolvedBranch)
$branchDeleted = ($delete.ExitCode -eq 0)
if (-not $branchDeleted) {
    Write-Warning "Branch '$resolvedBranch' was not deleted: $($delete.Output)"
}

$summary = [pscustomobject]@{
    branch = $Branch
    resolved_branch = $resolvedBranch
    dev_pulled = $devPulled
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

Write-Output "Merged '$resolvedBranch' into dev (ff-only). Range: $commitRange."
if ($branchDeleted) {
    Write-Output "Deleted local branch '$resolvedBranch'."
} else {
    Write-Output "Branch '$resolvedBranch' was NOT deleted (see warning above)."
}
