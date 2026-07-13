param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$IntegrationBranch,
    [string]$MergeTarget = 'main',
    [switch]$UseExisting,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
    throw "BRANCH_PREP_FAIL: repo path not found: $RepoPath"
}
$repo = (Resolve-Path -LiteralPath $RepoPath).Path
$rootOutput = & git -C $repo rev-parse --show-toplevel 2>&1
if ($LASTEXITCODE -ne 0) { throw "BRANCH_PREP_FAIL: not a git repo: $repo`n$($rootOutput -join "`n")" }
$repo = ([string]($rootOutput | Select-Object -Last 1)).Trim()

foreach ($ref in @($IntegrationBranch, $MergeTarget)) {
    & git -C $repo check-ref-format --branch $ref *> $null
    if ($LASTEXITCODE -ne 0) { throw "BRANCH_PREP_FAIL: invalid branch name: $ref" }
}
if ($IntegrationBranch -eq $MergeTarget) {
    throw "BRANCH_PREP_FAIL: integration branch must differ from protected merge target '$MergeTarget'."
}

& git -C $repo show-ref --verify --quiet "refs/heads/$MergeTarget"
if ($LASTEXITCODE -ne 0) { throw "BRANCH_PREP_FAIL: merge target branch not found: $MergeTarget" }
$mergeTargetSha = (& git -C $repo rev-parse $MergeTarget).Trim()

& git -C $repo show-ref --verify --quiet "refs/heads/$IntegrationBranch"
$integrationExists = ($LASTEXITCODE -eq 0)
if ($UseExisting) {
    if (-not $integrationExists) { throw "BRANCH_PREP_FAIL: existing integration branch not found: $IntegrationBranch" }
    $integrationSha = (& git -C $repo rev-parse $IntegrationBranch).Trim()
    & git -C $repo merge-base --is-ancestor $MergeTarget $IntegrationBranch
    if ($LASTEXITCODE -ne 0) {
        throw "BRANCH_PREP_FAIL: existing integration branch is not descended from merge target '$MergeTarget'."
    }
    $created = $false
}
else {
    if ($integrationExists) { throw "BRANCH_PREP_FAIL: integration branch already exists: $IntegrationBranch" }
    & git -C $repo branch $IntegrationBranch $mergeTargetSha
    if ($LASTEXITCODE -ne 0) { throw "BRANCH_PREP_FAIL: could not create integration branch: $IntegrationBranch" }
    $integrationSha = $mergeTargetSha
    $created = $true
}

$result = [pscustomobject]@{
    pass               = $true
    repo_root          = $repo
    integration_branch = $IntegrationBranch
    integration_sha    = $integrationSha
    merge_target       = $MergeTarget
    merge_target_sha   = $mergeTargetSha
    created            = $created
}
if ($Json) { $result | ConvertTo-Json -Depth 4 } else { $result }
