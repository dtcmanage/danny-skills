param(
    [Parameter(Mandatory)]
    [string]$CandidatePath,

    [Parameter(Mandatory)]
    [string]$AllowedRoot,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'path-identity.ps1')

$candidateFull = ConvertTo-DtPathIdentity $CandidatePath
$rootFull = ConvertTo-DtPathIdentity $AllowedRoot

$rootWithSep = if ($rootFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $rootFull
}
else {
    $rootFull + [System.IO.Path]::DirectorySeparatorChar
}

$pass = $candidateFull.StartsWith($rootWithSep, [System.StringComparison]::Ordinal) -or
    (Test-DtPathEqual $candidateFull $rootFull)

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
