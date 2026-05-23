param(
    [Parameter(Mandatory)]
    [string]$CandidatePath,

    [Parameter(Mandatory)]
    [string]$AllowedRoot,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$candidateFull = [System.IO.Path]::GetFullPath($CandidatePath)
$rootFull = [System.IO.Path]::GetFullPath($AllowedRoot)

$rootWithSep = if ($rootFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $rootFull
}
else {
    $rootFull + [System.IO.Path]::DirectorySeparatorChar
}

$pass = $candidateFull.StartsWith($rootWithSep, [System.StringComparison]::OrdinalIgnoreCase) -or
    ($candidateFull -eq $rootFull)

$result = [pscustomobject]@{
    pass = $pass
    candidate = $candidateFull
    allowed_root = $rootFull
}

if (-not $pass) {
    if ($Json) {
        $result | ConvertTo-Json -Depth 4
        exit 1
    }
    throw "WORKTREE_CONTAINMENT_BLOCK: '$candidateFull' escapes allowed root '$rootFull'"
}

if ($Json) {
    $result | ConvertTo-Json -Depth 4
}
else {
    Write-Output "PASS: worktree containment check passed"
}
