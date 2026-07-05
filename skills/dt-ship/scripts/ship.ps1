# dt-ship driver: gate -> merge -> purge -> push -> deploy -> prove live.
#
# 1. Resolve the primary tree and the feature branch in play (auto-detect when
#    -Branch is omitted).
# 2. Load the repo's ship config at <primary>\.ship.json (or -ConfigPath). No
#    config means merge + purge + push only: status 'merged_only', deploy and
#    verification recorded as skipped.
# 3. Run the config's optional gateCommand (build/tests) inside the feature
#    worktree. A failing gate stops everything before the merge.
# 4. Merge via skills/git-merge-feature/scripts/merge-feature.ps1 -PurgeWorktree
#    (rebase, ff-only merge, delete branch, remove worktree). The merge
#    machinery is reused, never reimplemented here.
# 5. Purge sweep: confirm no worktree or branch for the merged feature remains;
#    remove leftovers only when fully merged and clean.
# 6. Push main to origin (pushing main IS the ship).
# 7. Deploy: run deployCommand (after {HOST} substitution via
#    hostResolveCommand) in deployCwd.
# 8. Verify live: prodCommitProbe (url or command) must return a commit hash
#    that matches the local main HEAD, and the browser-smoke harness
#    (00_Resources\tools\browser-smoke\smoke.mjs) must pass on every
#    smokeRoutes URL. Hash mismatch or smoke failure = status 'not_shipped'.
#
# Fail closed: the first failing step stops the chain; the JSON reports
# failed_step. JSON summary: status (shipped | merged_only | not_shipped |
# failed), failed_step, branch, resolved_branch, merged, pushed, deployed,
# hash_match, local_head, prod_commit, smoke [{route, pass}], purged [],
# skipped [], rerere_enabled, error_message.

param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [string]$Branch,
    [string]$ConfigPath,
    [switch]$SkipDeploy,
    [switch]$SkipGate,
    [switch]$SkipPush,
    [switch]$SkipPull,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DefaultSmokeHarness = 'D:\Claude\_Claude-Workspace\00_Resources\tools\browser-smoke\smoke.mjs'

$state = [ordered]@{
    status = 'failed'
    failed_step = $null
    branch = $Branch
    resolved_branch = $null
    merged = $false
    pushed = $false
    deployed = $false
    hash_match = $null
    local_head = $null
    prod_commit = $null
    smoke = @()
    purged = @()
    skipped = @()
    rerere_enabled = $null
    error_message = $null
}

function Invoke-Git {
    param([string[]]$GitArgs)
    $output = & git @GitArgs 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output -join "`n")
    }
}

function Emit-Result {
    param([int]$ExitCode)
    $result = [pscustomobject]$state
    if ($Json) {
        $result | ConvertTo-Json -Depth 6
    } else {
        foreach ($key in $state.Keys) {
            $value = $state[$key]
            if ($null -ne $value -and $value -isnot [string] -and $value -isnot [bool] -and $value -isnot [int]) {
                $value = ($value | ConvertTo-Json -Compress -Depth 6)
            }
            Write-Output ("{0}: {1}" -f $key, $value)
        }
    }
    exit $ExitCode
}

function Fail-Step {
    param(
        [string]$Step,
        [string]$Message,
        [string]$Status = 'failed'
    )
    $state.status = $Status
    $state.failed_step = $Step
    $state.error_message = $Message
    Emit-Result -ExitCode 1
}

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

function Expand-HostToken {
    param([string]$Text, [string]$HostValue)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ($Text -like '*{HOST}*') {
        if ([string]::IsNullOrEmpty($HostValue)) {
            Fail-Step 'config' "A configured value uses {HOST} but hostResolveCommand is missing or returned nothing: $Text"
        }
        return $Text.Replace('{HOST}', $HostValue)
    }
    return $Text
}

function Get-TailText {
    param([string]$Text, [int]$Lines = 20)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $split = $Text -split "`r?`n"
    if ($split.Count -le $Lines) { return $Text }
    return (($split | Select-Object -Last $Lines) -join "`n")
}

# --- Step: resolve-repo ------------------------------------------------------

if (-not (Test-Path -LiteralPath $RepoRoot)) {
    Fail-Step 'resolve-repo' "RepoRoot '$RepoRoot' does not exist."
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$insideRepo = Invoke-Git -GitArgs @('-C', $RepoRoot, 'rev-parse', '--is-inside-work-tree')
if ($insideRepo.ExitCode -ne 0 -or $insideRepo.Output.Trim() -ne 'true') {
    Fail-Step 'resolve-repo' "'$RepoRoot' is not inside a git working tree."
}

# The first entry in 'git worktree list --porcelain' is the primary tree.
function Get-WorktreeMap {
    param([string]$AnyTree)
    $list = Invoke-Git -GitArgs @('-C', $AnyTree, 'worktree', 'list', '--porcelain')
    $map = @{ primary = $null; byBranch = @{} }
    $curPath = $null
    foreach ($line in ($list.Output -split "`r?`n")) {
        if ($line -like 'worktree *') {
            $curPath = ($line -split '\s+', 2)[1].Trim()
            if (-not $map.primary) { $map.primary = $curPath }
        }
        elseif ($line -like 'branch *') {
            $ref = ($line -split '\s+', 2)[1].Trim()
            $map.byBranch[$ref] = $curPath
        }
    }
    return $map
}

$wtMap = Get-WorktreeMap -AnyTree $RepoRoot
$primary = $wtMap.primary
if (-not $primary) {
    Fail-Step 'resolve-repo' "Could not determine the primary worktree for '$RepoRoot'."
}

# --- Step: resolve-branch ----------------------------------------------------

if (-not $Branch) {
    $head = (Invoke-Git -GitArgs @('-C', $RepoRoot, 'rev-parse', '--abbrev-ref', 'HEAD')).Output.Trim()
    if ($head -and $head -ne 'main' -and $head -ne 'HEAD') {
        $Branch = $head
    } else {
        $refs = Invoke-Git -GitArgs @('-C', $primary, 'for-each-ref', 'refs/heads', '--format=%(refname:short)')
        $candidates = @($refs.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'main' })
        if ($candidates.Count -eq 1) {
            $Branch = $candidates[0]
        } elseif ($candidates.Count -eq 0) {
            Fail-Step 'resolve-branch' "No feature branch found: the only local branch is main and HEAD is main. Nothing to ship."
        } else {
            Fail-Step 'resolve-branch' "Ambiguous: multiple feature branches exist and -Branch was not given. Candidates: $($candidates -join ', ')"
        }
    }
    $state.branch = $Branch
}

# Resolve the branch name the same way merge-feature.ps1 does (bare, then
# feat/, then feature/) so the gate and the purge sweep name the real branch.
$resolvedBranch = $null
foreach ($candidate in @($Branch, "feat/$Branch", "feature/$Branch")) {
    $exists = Invoke-Git -GitArgs @('-C', $primary, 'rev-parse', '--verify', "refs/heads/$candidate")
    if ($exists.ExitCode -eq 0) { $resolvedBranch = $candidate; break }
}
if (-not $resolvedBranch) {
    Fail-Step 'resolve-branch' "No local branch named '$Branch', 'feat/$Branch', or 'feature/$Branch'."
}
$state.resolved_branch = $resolvedBranch

# --- Step: config ------------------------------------------------------------

$configFile = if ($ConfigPath) { $ConfigPath } else { Join-Path $primary '.ship.json' }
$config = $null
if (Test-Path -LiteralPath $configFile) {
    try {
        $config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Fail-Step 'config' "Could not parse ship config '$configFile': $($_.Exception.Message)"
    }
    if (-not (Get-Prop $config 'deployCommand')) {
        Fail-Step 'config' "Ship config '$configFile' is missing required key 'deployCommand'."
    }
    $probeCheck = Get-Prop $config 'prodCommitProbe'
    if (-not $probeCheck -or (-not (Get-Prop $probeCheck 'url') -and -not (Get-Prop $probeCheck 'command'))) {
        Fail-Step 'config' "Ship config '$configFile' needs prodCommitProbe with either 'url' or 'command'."
    }
}

# --- Step: gate --------------------------------------------------------------

$gateCommand = Get-Prop $config 'gateCommand'
if ($gateCommand -and -not $SkipGate) {
    $branchTree = $wtMap.byBranch["refs/heads/$resolvedBranch"]
    if (-not $branchTree) {
        Fail-Step 'gate' "gateCommand is configured but branch '$resolvedBranch' is not checked out in any worktree, so there is no tree to run the gate in. Run the gate by hand in the right tree, then re-run with -SkipGate."
    }
    Push-Location $branchTree
    try {
        $gateOutput = & pwsh -NoProfile -Command $gateCommand 2>&1
        $gateExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($gateExit -ne 0) {
        Fail-Step 'gate' "Gate command failed (exit $gateExit) in '$branchTree'. NOT merged, NOT shipped. Output tail: $(Get-TailText (($gateOutput | Out-String)))"
    }
} elseif ($gateCommand -and $SkipGate) {
    $state.skipped += 'gate'
} else {
    $state.skipped += 'gate'
}

# --- Step: merge (reuse merge-feature.ps1; never reimplement) -----------------

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptDir
$resolvedLink = (Get-Item -LiteralPath $skillRoot).ResolveLinkTarget($true)
if ($resolvedLink) { $skillRoot = $resolvedLink.FullName }
$skillsRoot = Split-Path -Parent $skillRoot
$mergeScript = Join-Path $skillsRoot 'git-merge-feature\scripts\merge-feature.ps1'
if (-not (Test-Path -LiteralPath $mergeScript)) {
    Fail-Step 'merge' "Missing shared merge machinery: $mergeScript"
}

$mergeArgs = @('-NoProfile', '-File', $mergeScript, '-Branch', $resolvedBranch, '-Json', '-PurgeWorktree')
if ($SkipPull) { $mergeArgs += '-SkipPull' }

Push-Location $primary
try {
    $mergeOut = & pwsh @mergeArgs
    $mergeExit = $LASTEXITCODE
} finally {
    Pop-Location
}

$mergeText = ($mergeOut -join "`n")
$mergeParsed = $null
$braceStart = $mergeText.IndexOf('{')
$braceEnd = $mergeText.LastIndexOf('}')
if ($braceStart -ge 0 -and $braceEnd -gt $braceStart) {
    try {
        $mergeParsed = $mergeText.Substring($braceStart, $braceEnd - $braceStart + 1) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $mergeParsed = $null
    }
}

if ($mergeExit -ne 0 -or -not $mergeParsed -or (Get-Prop $mergeParsed 'status') -ne 'success') {
    $mergeError = if ($mergeParsed) { Get-Prop $mergeParsed 'error_message' 'unknown merge failure' } else { Get-TailText $mergeText }
    Fail-Step 'merge' "merge-feature.ps1 failed: $mergeError"
}

$state.merged = $true
$state.rerere_enabled = Get-Prop $mergeParsed 'rerere_enabled'
if (Get-Prop $mergeParsed 'worktree_removed' $false) {
    $state.purged += "worktree: $(Get-Prop $mergeParsed 'worktree_path')"
}
if (Get-Prop $mergeParsed 'branch_deleted' $false) {
    $state.purged += "branch: $resolvedBranch"
}

$state.local_head = (Invoke-Git -GitArgs @('-C', $primary, 'rev-parse', 'main')).Output.Trim()

# --- Step: purge (sweep: nothing of the merged feature may remain) -----------

$branchLeft = (Invoke-Git -GitArgs @('-C', $primary, 'rev-parse', '--verify', "refs/heads/$resolvedBranch")).ExitCode -eq 0
if ($branchLeft) {
    $fullyMerged = (Invoke-Git -GitArgs @('-C', $primary, 'merge-base', '--is-ancestor', $resolvedBranch, 'main')).ExitCode -eq 0
    if (-not $fullyMerged) {
        Fail-Step 'purge' "Branch '$resolvedBranch' still exists and has commits not on main. Refusing to delete."
    }
    $sweepMap = Get-WorktreeMap -AnyTree $primary
    $leftoverTree = $sweepMap.byBranch["refs/heads/$resolvedBranch"]
    if ($leftoverTree) {
        $treeStatus = Invoke-Git -GitArgs @('-C', $leftoverTree, 'status', '--porcelain')
        if (-not [string]::IsNullOrWhiteSpace($treeStatus.Output)) {
            Fail-Step 'purge' "Worktree '$leftoverTree' for merged branch '$resolvedBranch' has uncommitted changes. Not removing it."
        }
        $removeTree = Invoke-Git -GitArgs @('-C', $primary, 'worktree', 'remove', $leftoverTree)
        if ($removeTree.ExitCode -ne 0) {
            Fail-Step 'purge' "Could not remove leftover worktree '$leftoverTree': $($removeTree.Output)"
        }
        $state.purged += "worktree: $leftoverTree"
    }
    $deleteBranch = Invoke-Git -GitArgs @('-C', $primary, 'branch', '-d', $resolvedBranch)
    if ($deleteBranch.ExitCode -ne 0) {
        Fail-Step 'purge' "Could not delete merged branch '$resolvedBranch': $($deleteBranch.Output)"
    }
    $state.purged += "branch: $resolvedBranch"
}

# --- Step: push (pushing main IS the ship) ------------------------------------

if ($SkipPush) {
    $state.skipped += 'push'
} else {
    $originCheck = Invoke-Git -GitArgs @('-C', $primary, 'remote', 'get-url', 'origin')
    if ($originCheck.ExitCode -ne 0) {
        Fail-Step 'push' "No 'origin' remote configured; cannot push main. Use -SkipPush only if the repo is deliberately local-only."
    }
    $push = Invoke-Git -GitArgs @('-C', $primary, 'push', 'origin', 'main')
    if ($push.ExitCode -ne 0) {
        Fail-Step 'push' "git push origin main failed: $($push.Output)"
    }
    $state.pushed = $true
}

# --- Step: deploy + verify (requires ship config) ------------------------------

if (-not $config) {
    $state.skipped += @('deploy', 'verify-hash', 'smoke')
    $state.status = 'merged_only'
    Emit-Result -ExitCode 0
}

# Resolve {HOST} once, up front, if any configured value needs it.
$hostValue = $null
$hostResolveCommand = Get-Prop $config 'hostResolveCommand'
if ($hostResolveCommand) {
    $hostOut = & pwsh -NoProfile -Command $hostResolveCommand 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail-Step 'resolve-host' "hostResolveCommand failed: $(Get-TailText (($hostOut | Out-String)))"
    }
    $hostValue = @((($hostOut | Out-String) -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 1)[0].Trim()
    if (-not $hostValue) {
        Fail-Step 'resolve-host' "hostResolveCommand produced no output; cannot substitute {HOST}."
    }
}

if ($SkipDeploy) {
    $state.skipped += 'deploy'
} else {
    $deployCommand = Expand-HostToken (Get-Prop $config 'deployCommand') $hostValue
    $deployCwdRaw = Get-Prop $config 'deployCwd'
    $deployCwd = if (-not $deployCwdRaw) { $primary }
        elseif ([System.IO.Path]::IsPathRooted($deployCwdRaw)) { $deployCwdRaw }
        else { Join-Path $primary $deployCwdRaw }
    if (-not (Test-Path -LiteralPath $deployCwd)) {
        Fail-Step 'deploy' "deployCwd '$deployCwd' does not exist."
    }
    Push-Location $deployCwd
    try {
        $deployOutput = & pwsh -NoProfile -Command $deployCommand 2>&1
        $deployExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($deployExit -ne 0) {
        Fail-Step 'deploy' "Deploy command failed (exit $deployExit). Output tail: $(Get-TailText (($deployOutput | Out-String)))"
    }
    $state.deployed = $true
}

# --- Step: verify-hash ---------------------------------------------------------

$probe = Get-Prop $config 'prodCommitProbe'
$probeUrl = Expand-HostToken (Get-Prop $probe 'url') $hostValue
$probeCommand = Expand-HostToken (Get-Prop $probe 'command') $hostValue

$probeBody = $null
if ($probeUrl) {
    try {
        $response = Invoke-WebRequest -Uri $probeUrl -TimeoutSec 30
        $probeBody = [string]$response.Content
    } catch {
        Fail-Step 'verify-hash' "NOT SHIPPED: commit probe URL '$probeUrl' failed: $($_.Exception.Message)" 'not_shipped'
    }
} elseif ($probeCommand) {
    $probeOut = & pwsh -NoProfile -Command $probeCommand 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail-Step 'verify-hash' "NOT SHIPPED: commit probe command failed: $(Get-TailText (($probeOut | Out-String)))" 'not_shipped'
    }
    $probeBody = ($probeOut | Out-String)
}

$hashMatch = [regex]::Match($probeBody, '[0-9a-fA-F]{40}')
if (-not $hashMatch.Success) {
    $hashMatch = [regex]::Match($probeBody, '\b[0-9a-fA-F]{7,40}\b')
}
if (-not $hashMatch.Success) {
    Fail-Step 'verify-hash' "NOT SHIPPED: commit probe returned no commit hash. Probe output tail: $(Get-TailText $probeBody)" 'not_shipped'
}

$prodCommit = $hashMatch.Value.ToLowerInvariant()
$state.prod_commit = $prodCommit
$state.hash_match = $state.local_head.ToLowerInvariant().StartsWith($prodCommit)
if (-not $state.hash_match) {
    Fail-Step 'verify-hash' "NOT SHIPPED: deployed commit '$prodCommit' does not match local main HEAD '$($state.local_head)'. The deploy did not take." 'not_shipped'
}

# --- Step: smoke ---------------------------------------------------------------

$smokeRoutes = @(Get-Prop $config 'smokeRoutes' @())
if ($smokeRoutes.Count -eq 0) {
    $state.skipped += 'smoke'
} else {
    $smokeHarness = Get-Prop $config 'smokeHarnessPath' $DefaultSmokeHarness
    if (-not (Test-Path -LiteralPath $smokeHarness)) {
        Fail-Step 'smoke' "Browser-smoke harness not found at '$smokeHarness'."
    }
    $anySmokeFail = $false
    foreach ($route in $smokeRoutes) {
        $routeUrl = Expand-HostToken ([string]$route) $hostValue
        $null = & node $smokeHarness --url $routeUrl 2>&1
        $pass = ($LASTEXITCODE -eq 0)
        $state.smoke += [pscustomobject]@{ route = $routeUrl; pass = $pass }
        if (-not $pass) { $anySmokeFail = $true }
    }
    if ($anySmokeFail) {
        $failedRoutes = @($state.smoke | Where-Object { -not $_.pass } | ForEach-Object { $_.route })
        Fail-Step 'smoke' "NOT SHIPPED: browser smoke failed on: $($failedRoutes -join ', '). The site is not provably live." 'not_shipped'
    }
}

# --- Done ----------------------------------------------------------------------

$state.status = 'shipped'
Emit-Result -ExitCode 0
