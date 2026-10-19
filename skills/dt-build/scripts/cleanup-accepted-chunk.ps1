param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$ChunkBranch,
    [Parameter(Mandatory)][string]$IntegrationBranch,
    [string]$WorktreePath,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$result = [ordered]@{
    pass = $false
    chunk_branch = $ChunkBranch
    integration_branch = $IntegrationBranch
    removed_worktree = $false
    deleted_branch = $false
    leftovers = @()
    error_code = $null
}

function Invoke-Git {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $lines = @(& git -C $RepoPath @Arguments 2>&1)
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "CLEANUP_GIT_ERROR: $($lines -join "`n")"
    }
    [pscustomobject]@{ code = $code; text = ($lines -join "`n") }
}

function Get-ChunkWorktrees {
    # NUL fields preserve spaces, Unicode and paths Git would otherwise quote.
    $listing = (Invoke-Git @('worktree', 'list', '--porcelain', '-z')).text
    $path = $null
    foreach ($field in $listing.Split([char]0)) {
        if ($field.StartsWith('worktree ')) { $path = $field.Substring(9) }
        elseif ($field -ceq "branch refs/heads/$ChunkBranch") { $path }
    }
}

try {
    if ($ChunkBranch -in @('main', 'master', 'refs/heads/main', 'refs/heads/master')) {
        throw 'CLEANUP_PROTECTED_BRANCH: refusing to delete main/master.'
    }
    if ($ChunkBranch -ceq $IntegrationBranch) {
        throw 'CLEANUP_INVALID_BRANCH: chunk and integration branches must differ.'
    }
    foreach ($branch in @($ChunkBranch, $IntegrationBranch)) {
        Invoke-Git @('check-ref-format', "refs/heads/$branch") | Out-Null
    }
    $chunkRef = "refs/heads/$ChunkBranch"
    $integrationRef = "refs/heads/$IntegrationBranch"
    $ancestry = Invoke-Git @('merge-base', '--is-ancestor', $chunkRef, $integrationRef) -AllowFailure
    if ($ancestry.code -ne 0) {
        throw 'CLEANUP_NOT_MERGED: chunk is not an ancestor of the integration branch.'
    }

    $worktrees = @(Get-ChunkWorktrees)
    if ($WorktreePath) {
        $requested = [IO.Path]::GetFullPath($WorktreePath).TrimEnd('/', '\')
        $worktrees = @($worktrees | Where-Object {
            [IO.Path]::GetFullPath($_).TrimEnd('/', '\') -eq $requested
        })
        if ($worktrees.Count -ne 1) {
            throw 'CLEANUP_WORKTREE_MISMATCH: supplied path is not the chunk worktree.'
        }
    }
    foreach ($path in $worktrees) {
        $status = Invoke-Git @('-C', $path, 'status', '--porcelain', '--untracked-files=all')
        if ($status.text.Length -gt 0) {
            throw 'CLEANUP_DIRTY_WORKTREE: chunk worktree has uncommitted or untracked changes.'
        }
    }
    foreach ($path in $worktrees) {
        $removal = Invoke-Git @('worktree', 'remove', '--', $path) -AllowFailure
        Invoke-Git @('worktree', 'prune') | Out-Null
        # Windows may leave a locked folder after Git deregisters the worktree.
        if (@(Get-ChunkWorktrees) -contains $path) {
            throw "CLEANUP_WORKTREE_REMOVE_FAILED: $($removal.text)"
        }
        $result.removed_worktree = $true
        if (Test-Path -LiteralPath $path) {
            $result.leftovers += [ordered]@{ code = 'worktree_dir_leftover'; path = $path }
        }
    }
    Invoke-Git @('branch', '-D', '--', $ChunkBranch) | Out-Null
    $result.deleted_branch = $true
    $result.pass = $true
}
catch {
    $message = $_.Exception.Message
    $result.error_code = if ($message -match '^(CLEANUP_[A-Z_]+):') { $Matches[1] } else { 'CLEANUP_GIT_ERROR' }
    if (-not $Json) { Write-Output $message }
}

if ($Json) { [pscustomobject]$result | ConvertTo-Json -Depth 6 }
elseif ($result.pass) { Write-Output "PASS: cleaned accepted chunk $ChunkBranch from $IntegrationBranch." }
if (-not $result.pass) { exit 1 }
