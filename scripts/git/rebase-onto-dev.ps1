# Rebase a single feature branch onto dev. Assumes caller has already pulled
# the latest dev. Leaves the repo in conflict state on failure so the caller
# (or Danny) can decide whether to resolve or abort.
#
# Returns a JSON object with: branch, status (clean | conflict | error),
# conflicted_files (array, only on conflict), error_message (only on error).

param(
    [Parameter(Mandatory)]
    [string]$Branch,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Git {
    param([string[]]$GitArgs)

    $output = & git @GitArgs 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = ($output -join "`n")
    }
}

# Verify we're in a git repo
$insideRepo = Invoke-Git -GitArgs @('rev-parse', '--is-inside-work-tree')
if ($insideRepo.ExitCode -ne 0 -or $insideRepo.Output.Trim() -ne 'true') {
    $result = [pscustomobject]@{
        branch = $Branch
        status = 'error'
        error_message = 'Not inside a git repository.'
        conflicted_files = @()
    }
    if ($Json) { $result | ConvertTo-Json -Depth 4; exit 1 }
    throw $result.error_message
}

# Verify branch exists
$branchExists = Invoke-Git -GitArgs @('rev-parse', '--verify', "refs/heads/$Branch")
if ($branchExists.ExitCode -ne 0) {
    $result = [pscustomobject]@{
        branch = $Branch
        status = 'error'
        error_message = "Branch '$Branch' does not exist locally."
        conflicted_files = @()
    }
    if ($Json) { $result | ConvertTo-Json -Depth 4; exit 1 }
    throw $result.error_message
}

# Verify dev exists
$devExists = Invoke-Git -GitArgs @('rev-parse', '--verify', 'refs/heads/dev')
if ($devExists.ExitCode -ne 0) {
    $result = [pscustomobject]@{
        branch = $Branch
        status = 'error'
        error_message = "Local 'dev' branch not found. Caller must ensure dev exists and is current."
        conflicted_files = @()
    }
    if ($Json) { $result | ConvertTo-Json -Depth 4; exit 1 }
    throw $result.error_message
}

# Checkout the feature branch
$checkout = Invoke-Git -GitArgs @('checkout', $Branch)
if ($checkout.ExitCode -ne 0) {
    $result = [pscustomobject]@{
        branch = $Branch
        status = 'error'
        error_message = "Checkout failed: $($checkout.Output)"
        conflicted_files = @()
    }
    if ($Json) { $result | ConvertTo-Json -Depth 4; exit 1 }
    throw $result.error_message
}

# Attempt the rebase
$rebase = Invoke-Git -GitArgs @('rebase', 'dev')
if ($rebase.ExitCode -eq 0) {
    $result = [pscustomobject]@{
        branch = $Branch
        status = 'clean'
        conflicted_files = @()
    }
    if ($Json) { $result | ConvertTo-Json -Depth 4 } else {
        Write-Output "Rebased '$Branch' cleanly onto dev."
    }
    exit 0
}

# Rebase hit a conflict (or other failure). Distinguish via git status.
$conflictList = Invoke-Git -GitArgs @('diff', '--name-only', '--diff-filter=U')
$files = @($conflictList.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

if ($files.Count -gt 0) {
    $result = [pscustomobject]@{
        branch = $Branch
        status = 'conflict'
        conflicted_files = $files
        rebase_output = $rebase.Output
    }
    if ($Json) { $result | ConvertTo-Json -Depth 4; exit 2 }
    Write-Warning "Rebase of '$Branch' onto dev hit conflicts in:"
    foreach ($f in $files) { Write-Warning "  $f" }
    Write-Warning "Repo is mid-rebase. Resolve or run 'git rebase --abort'."
    exit 2
}

# Non-conflict rebase failure
$result = [pscustomobject]@{
    branch = $Branch
    status = 'error'
    error_message = "Rebase failed without conflict markers. Output: $($rebase.Output)"
    conflicted_files = @()
}
if ($Json) { $result | ConvertTo-Json -Depth 4; exit 1 }
throw $result.error_message
