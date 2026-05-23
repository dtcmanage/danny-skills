param(
    [Parameter(Mandatory)]
    [string]$MergeTarget,

    [Parameter(Mandatory)]
    [string]$BuildBranch,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$targetRef = "refs/heads/$MergeTarget"
$branchRef = "refs/heads/$BuildBranch"

& git show-ref --verify --quiet $targetRef
$targetExists = ($LASTEXITCODE -eq 0)
& git show-ref --verify --quiet $branchRef
$branchExists = ($LASTEXITCODE -eq 0)

if (-not $targetExists) {
    throw "DRIFT_CHECK_FAIL: merge target branch not found: $MergeTarget"
}
if (-not $branchExists) {
    throw "DRIFT_CHECK_FAIL: build branch not found: $BuildBranch"
}

$ahead = [int](& git rev-list --count "$MergeTarget..$BuildBranch")
$behind = [int](& git rev-list --count "$BuildBranch..$MergeTarget")

$result = [pscustomobject]@{
    merge_target = $MergeTarget
    build_branch = $BuildBranch
    ahead = $ahead
    behind = $behind
    drift = ($behind -gt 0)
}

if ($Json) {
    $result | ConvertTo-Json -Depth 4
}
else {
    if ($result.drift) {
        Write-Output ("DRIFT: build branch is behind by {0} commit(s) and ahead by {1}" -f $behind, $ahead)
    }
    else {
        Write-Output ("PASS: no drift (ahead={0}, behind={1})" -f $ahead, $behind)
    }
}
