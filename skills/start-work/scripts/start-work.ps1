# Set up the git surface for a unit of work per the trunk-based tier model.
#
# Tiers:
#   light  - stay on main, no branch (ship directly).
#   medium - create/checkout feat/<name> in the primary tree.
#   heavy  - create a worktree at ..\<repo>-<name> on feat/<name>; primary tree stays on main.
#
# The agent + Danny decide the tier and name; this script does only the deterministic git setup.
# It never pushes and never merges.
#
# Returns a JSON summary on -Json: status, tier, repo_root, main_pulled, branch, worktree_path.

param(
    [Parameter(Mandatory)]
    [ValidateSet('light', 'medium', 'heavy')]
    [string]$Tier,

    [string]$Name,

    [ValidateSet('feat', 'fix')]
    [string]$Prefix = 'feat',

    [string]$RepoRoot,
    [switch]$SkipPull,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Git {
    param([string[]]$GitArgs)
    $output = & git @GitArgs 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

function Fail {
    param([string]$Message)
    if ($Json) { [pscustomobject]@{ status = 'error'; error_message = $Message } | ConvertTo-Json -Depth 4; exit 1 }
    throw $Message
}

# Resolve repo root
if (-not $RepoRoot) {
    $top = Invoke-Git -GitArgs @('rev-parse', '--show-toplevel')
    if ($top.ExitCode -ne 0) { Fail "Not inside a git repository." }
    $RepoRoot = $top.Output.Trim()
}
$check = Invoke-Git -GitArgs @('-C', $RepoRoot, 'rev-parse', '--is-inside-work-tree')
if ($check.ExitCode -ne 0 -or $check.Output.Trim() -ne 'true') { Fail "RepoRoot is not a git repository: $RepoRoot" }

# Validate name for medium/heavy
$branch = $null
if ($Tier -ne 'light') {
    if ([string]::IsNullOrWhiteSpace($Name)) { Fail "Tier '$Tier' requires -Name (a meaningful kebab-case slug)." }
    if ($Name -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { Fail "Name must be kebab-case (lowercase words separated by single hyphens): got '$Name'." }
    $generic = @('update', 'fix', 'changes', 'change', 'wip', 'stuff', 'misc', 'temp', 'new', 'work')
    if ($generic -contains $Name) { Fail "Name '$Name' is too generic. Use an intent-describing slug like 'trade-log-csv-export'." }
    $branch = "$Prefix/$Name"

    # Require a clean tree before switching to main and branching.
    $dirty = Invoke-Git -GitArgs @('-C', $RepoRoot, 'status', '--porcelain')
    if (-not [string]::IsNullOrWhiteSpace($dirty.Output)) {
        Fail "Working tree has uncommitted changes. Commit or stash before starting new feature work."
    }
}

# Refresh main
$co = Invoke-Git -GitArgs @('-C', $RepoRoot, 'checkout', 'main')
if ($co.ExitCode -ne 0) { Fail "Could not checkout main: $($co.Output)" }

$pulled = $false
if (-not $SkipPull) {
    $hasOrigin = Invoke-Git -GitArgs @('-C', $RepoRoot, 'remote', 'get-url', 'origin')
    if ($hasOrigin.ExitCode -eq 0) {
        $pull = Invoke-Git -GitArgs @('-C', $RepoRoot, 'pull', 'origin', 'main')
        if ($pull.ExitCode -ne 0) { Fail "git pull origin main failed: $($pull.Output)" }
        $pulled = $true
    }
}

$result = [ordered]@{
    status        = 'success'
    tier          = $Tier
    repo_root     = $RepoRoot
    main_pulled   = $pulled
    branch        = $branch
    worktree_path = $null
}

switch ($Tier) {
    'light' {
        # Stay on main; no branch.
    }
    'medium' {
        $exists = Invoke-Git -GitArgs @('-C', $RepoRoot, 'rev-parse', '--verify', "refs/heads/$branch")
        if ($exists.ExitCode -eq 0) {
            $sw = Invoke-Git -GitArgs @('-C', $RepoRoot, 'checkout', $branch)
            if ($sw.ExitCode -ne 0) { Fail "Branch '$branch' exists but checkout failed: $($sw.Output)" }
        }
        else {
            $cb = Invoke-Git -GitArgs @('-C', $RepoRoot, 'checkout', '-b', $branch)
            if ($cb.ExitCode -ne 0) { Fail "Could not create branch '$branch': $($cb.Output)" }
        }
    }
    'heavy' {
        $leaf = Split-Path $RepoRoot -Leaf
        $parent = Split-Path $RepoRoot -Parent
        $wtPath = Join-Path $parent ("{0}-{1}" -f $leaf, $Name)
        if (Test-Path -LiteralPath $wtPath) { Fail "Worktree path already exists: $wtPath" }
        $branchExists = Invoke-Git -GitArgs @('-C', $RepoRoot, 'rev-parse', '--verify', "refs/heads/$branch")
        if ($branchExists.ExitCode -eq 0) {
            $wt = Invoke-Git -GitArgs @('-C', $RepoRoot, 'worktree', 'add', $wtPath, $branch)
        }
        else {
            $wt = Invoke-Git -GitArgs @('-C', $RepoRoot, 'worktree', 'add', $wtPath, '-b', $branch)
        }
        if ($wt.ExitCode -ne 0) { Fail "Could not create worktree: $($wt.Output)" }
        $result.worktree_path = $wtPath
    }
}

$obj = [pscustomobject]$result
if ($Json) { $obj | ConvertTo-Json -Depth 6; exit 0 }

switch ($Tier) {
    'light' { Write-Output "Light: working on main (no branch). Ship directly when done." }
    'medium' { Write-Output "Medium: on branch '$branch' in the primary tree." }
    'heavy' { Write-Output "Heavy: worktree at '$($result.worktree_path)' on branch '$branch'. Work there; primary tree stays on main." }
}
