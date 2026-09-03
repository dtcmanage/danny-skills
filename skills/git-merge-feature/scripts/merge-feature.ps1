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
# merge_status, branch_deleted, commit_range, worktree_path, worktree_removed,
# rerere_enabled.
#
# -PurgeWorktree (opt-in, passed by dt-ship): makes post-merge cleanup mandatory.
# A worktree-remove or branch-delete failure becomes a hard error (exit 1)
# instead of a warning, and a successful removal is followed by
# 'git worktree prune'. Default behavior without the switch is unchanged.

param(
    [Parameter(Mandatory)]
    [string]$Branch,

    [switch]$Json,
    [switch]$SkipPull,
    [switch]$PurgeWorktree
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

# Delete a feature branch that is already merged into main. 'git branch -d'
# refuses when the branch tracks an upstream (e.g. created with
# 'git worktree add -b X origin/main') that does not yet contain it, even
# though it is fully merged into local main. Retry with -D only after proving
# main contains the branch tip, so the force never deletes unmerged work.
function Remove-MergedBranch {
    param([string]$Repo, [string]$BranchName)
    $gitArgs = @()
    if ($Repo) { $gitArgs += @('-C', $Repo) }
    $delete = Invoke-Git -GitArgs ($gitArgs + @('branch', '-d', $BranchName))
    if ($delete.ExitCode -eq 0) { return $delete }
    $ancestor = Invoke-Git -GitArgs ($gitArgs + @('merge-base', '--is-ancestor', $BranchName, 'main'))
    if ($ancestor.ExitCode -ne 0) { return $delete }
    return Invoke-Git -GitArgs ($gitArgs + @('branch', '-D', $BranchName))
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

# Report rerere state in the JSON so the model can suggest enabling it without
# re-checking git config itself.
$rerereEnabled = ((Invoke-Git -GitArgs @('config', '--get', 'rerere.enabled')).Output.Trim() -eq 'true')

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

# Detect whether the resolved branch is checked out in a worktree. Under the
# trunk-based workflow every feature lives in its own worktree, so the branch
# usually cannot be checked out in the primary tree. The first "worktree" entry
# is the primary tree; a path split with limit 2 preserves spaces in paths.
$wtList = Invoke-Git -GitArgs @('worktree', 'list', '--porcelain')
$mainWorktree = $null
$branchWorktree = $null
$curPath = $null
foreach ($wtLine in ($wtList.Output -split "`r?`n")) {
    if ($wtLine -like 'worktree *') {
        $curPath = ($wtLine -split '\s+', 2)[1].Trim()
        if (-not $mainWorktree) { $mainWorktree = $curPath }
    }
    elseif ($wtLine -like 'branch *') {
        $wtRef = ($wtLine -split '\s+', 2)[1].Trim()
        if ($wtRef -eq "refs/heads/$resolvedBranch") { $branchWorktree = $curPath }
    }
}

if ($branchWorktree -and ($branchWorktree -ne $mainWorktree)) {
    # --- Worktree-aware merge (branch lives in its own worktree) ---
    # Do not check the branch out in the primary tree; inspect/rebase in place.
    $wtStatus = Invoke-Git -GitArgs @('-C', $branchWorktree, 'status', '--porcelain')
    if (-not [string]::IsNullOrWhiteSpace($wtStatus.Output)) {
        Fail "Uncommitted changes on '$resolvedBranch' in worktree '$branchWorktree'. Commit or stash first." @{ uncommitted = $wtStatus.Output; worktree_path = $branchWorktree }
    }

    $coMain = Invoke-Git -GitArgs @('-C', $mainWorktree, 'checkout', 'main')
    if ($coMain.ExitCode -ne 0) {
        Fail "Could not checkout main in primary tree '$mainWorktree': $($coMain.Output)" @{ worktree_path = $branchWorktree }
    }

    $mainPulled = $false
    if (-not $SkipPull) {
        $pullMain = Invoke-Git -GitArgs @('-C', $mainWorktree, 'pull', '--ff-only', 'origin', 'main')
        if ($pullMain.ExitCode -ne 0) {
            Fail "git pull --ff-only origin main failed: $($pullMain.Output)" @{ worktree_path = $branchWorktree }
        }
        $mainPulled = $true
    }

    $mainShaBefore = (Invoke-Git -GitArgs @('-C', $mainWorktree, 'rev-parse', 'main')).Output.Trim()

    # Rebase the feature branch inside its own worktree, onto the refreshed main.
    $wtRebase = Invoke-Git -GitArgs @('-C', $branchWorktree, 'rebase', 'main')
    if ($wtRebase.ExitCode -ne 0) {
        $null = Invoke-Git -GitArgs @('-C', $branchWorktree, 'rebase', '--abort')
        Fail "Rebase of '$resolvedBranch' onto main failed in worktree (conflicts). Resolve in '$branchWorktree', then retry. Do NOT fall back to --no-ff." @{ rebase = $wtRebase.Output; worktree_path = $branchWorktree }
    }

    # Fast-forward merge into main from the primary tree.
    $wtMerge = Invoke-Git -GitArgs @('-C', $mainWorktree, 'merge', '--ff-only', $resolvedBranch)
    if ($wtMerge.ExitCode -ne 0) {
        Fail "git merge --ff-only failed (should not happen after a clean rebase): $($wtMerge.Output). Do NOT fall back to --no-ff." @{ worktree_path = $branchWorktree }
    }

    $mainShaAfter = (Invoke-Git -GitArgs @('-C', $mainWorktree, 'rev-parse', 'main')).Output.Trim()
    $wtCommitRange = if ($mainShaBefore -ne $mainShaAfter) { "$($mainShaBefore.Substring(0,7))..$($mainShaAfter.Substring(0,7))" } else { 'no-op' }

    # Remove the worktree (clean after rebase) before deleting the branch -
    # git refuses to delete a branch still checked out in a worktree.
    $wtRemoved = $false
    $wtDirLeftover = $null
    $wtRemove = Invoke-Git -GitArgs @('worktree', 'remove', $branchWorktree)
    if ($wtRemove.ExitCode -ne 0) {
        # Windows: the directory delete is often denied by a transient handle
        # (a shell that recently sat in the directory, an AV scan) even though
        # git has already deregistered the worktree. Retry briefly first.
        foreach ($delayMs in 1500, 3000) {
            Start-Sleep -Milliseconds $delayMs
            $wtRemove = Invoke-Git -GitArgs @('worktree', 'remove', $branchWorktree)
            if ($wtRemove.ExitCode -eq 0) { break }
        }
    }
    if ($wtRemove.ExitCode -eq 0) {
        $wtRemoved = $true
        if ($PurgeWorktree) {
            $null = Invoke-Git -GitArgs @('worktree', 'prune')
        }
    } else {
        # Distinguish "still registered" (real failure) from "deregistered but
        # the directory would not delete" (cosmetic — observed twice 2026-08-29:
        # the merge had landed and only the ship's push was lost to this).
        $null = Invoke-Git -GitArgs @('worktree', 'prune')
        $trackedLines = (Invoke-Git -GitArgs @('worktree', 'list', '--porcelain')).Output -split "`r?`n"
        if ($trackedLines -contains "worktree $branchWorktree") {
            if ($PurgeWorktree) {
                Fail "Merge landed (range $wtCommitRange) but worktree '$branchWorktree' is still registered and could not be removed: $($wtRemove.Output). Remove it by hand, then delete branch '$resolvedBranch'." @{ merge_status = 'ff-only'; commit_range = $wtCommitRange; worktree_path = $branchWorktree; worktree_removed = $false; rerere_enabled = $rerereEnabled }
            }
            Write-Warning "Could not remove worktree '$branchWorktree': $($wtRemove.Output). Branch left in place."
        } else {
            # Git no longer tracks it; finish with a direct directory delete.
            # A directory that still refuses to die is left behind as cosmetics
            # so the merge/branch/push chain can complete.
            try {
                Remove-Item -LiteralPath $branchWorktree -Recurse -Force -ErrorAction Stop
            } catch {
                $wtDirLeftover = $branchWorktree
                Write-Warning "Worktree '$branchWorktree' is deregistered but its directory could not be deleted: $($_.Exception.Message). Continuing; delete the folder at leisure."
            }
            $wtRemoved = $true
        }
    }

    $wtBranchDeleted = $false
    if ($wtRemoved) {
        $wtDelete = Remove-MergedBranch -Repo $mainWorktree -BranchName $resolvedBranch
        $wtBranchDeleted = ($wtDelete.ExitCode -eq 0)
        if (-not $wtBranchDeleted) {
            if ($PurgeWorktree) {
                Fail "Merge landed (range $wtCommitRange) and worktree was removed, but branch '$resolvedBranch' was not deleted: $($wtDelete.Output). Purge is mandatory under -PurgeWorktree." @{ merge_status = 'ff-only'; commit_range = $wtCommitRange; worktree_path = $branchWorktree; worktree_removed = $true; rerere_enabled = $rerereEnabled }
            }
            Write-Warning "Branch '$resolvedBranch' was not deleted: $($wtDelete.Output)"
        }
    }

    $wtSummary = [pscustomobject]@{
        branch = $Branch
        resolved_branch = $resolvedBranch
        main_pulled = $mainPulled
        rebase_status = 'clean'
        merge_status = 'ff-only'
        commit_range = $wtCommitRange
        branch_deleted = $wtBranchDeleted
        worktree_path = $branchWorktree
        worktree_removed = $wtRemoved
        worktree_dir_leftover = $wtDirLeftover
        rerere_enabled = $rerereEnabled
        status = 'success'
    }

    if ($Json) {
        $wtSummary | ConvertTo-Json -Depth 6
        exit 0
    }

    Write-Output "Merged '$resolvedBranch' (worktree) into main (ff-only). Range: $wtCommitRange."
    if ($wtRemoved -and -not $wtDirLeftover) { Write-Output "Removed worktree '$branchWorktree'." }
    if ($wtDirLeftover) { Write-Output "Worktree deregistered; leftover directory to delete at leisure: $wtDirLeftover" }
    if ($wtBranchDeleted) {
        Write-Output "Deleted local branch '$resolvedBranch'."
    } else {
        Write-Output "Branch '$resolvedBranch' was NOT deleted (see warning above)."
    }
    exit 0
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
$delete = Remove-MergedBranch -BranchName $resolvedBranch
$branchDeleted = ($delete.ExitCode -eq 0)
if (-not $branchDeleted) {
    if ($PurgeWorktree) {
        Fail "Merge landed (range $commitRange) but branch '$resolvedBranch' was not deleted: $($delete.Output). Purge is mandatory under -PurgeWorktree." @{ merge_status = 'ff-only'; commit_range = $commitRange; worktree_path = $null; worktree_removed = $false; rerere_enabled = $rerereEnabled }
    }
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
    worktree_path = $null
    worktree_removed = $false
    worktree_dir_leftover = $null
    rerere_enabled = $rerereEnabled
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
