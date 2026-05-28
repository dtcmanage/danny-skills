param(
    [Parameter(Mandatory)]
    [string]$SourceRef,

    [Parameter(Mandatory)]
    [string]$ExpectedTargetSha,

    [Parameter(Mandatory)]
    [string]$TargetBranch,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string[]]$Args,
        [switch]$AllowFailure
    )
    $out = & git @Args 2>&1
    $code = $LASTEXITCODE
    if (-not $AllowFailure -and $code -ne 0) {
        throw ("CAS_FAIL: git {0}`n{1}" -f ($Args -join " "), ($out -join "`n"))
    }
    return [pscustomobject]@{
        code = $code
        lines = @($out)
        text = ($out -join "`n")
    }
}

$gitRoot = Invoke-Git -Args @("rev-parse", "--show-toplevel")
$sourceSha = (Invoke-Git -Args @("rev-parse", $SourceRef)).text.Trim()
$currentTargetSha = (Invoke-Git -Args @("rev-parse", $TargetBranch)).text.Trim()

$result = [ordered]@{
    pass = $false
    target_branch = $TargetBranch
    source_ref = $SourceRef
    source_sha = $sourceSha
    expected_target_sha = $ExpectedTargetSha
    observed_target_sha = $currentTargetSha
    mode = "compare-and-swap"
    updated = $false
    reason = ""
}

if ($currentTargetSha -ne $ExpectedTargetSha) {
    $result.reason = "CAS_BLOCKED: $TargetBranch advanced before compare-and-swap update."
}
else {
    $ancestorCheck = Invoke-Git -Args @("merge-base", "--is-ancestor", $currentTargetSha, $sourceSha) -AllowFailure
    if ($ancestorCheck.code -ne 0) {
        $result.reason = "CAS_BLOCKED: source is not a fast-forward descendant of current $TargetBranch."
    }
    else {
        $refName = "refs/heads/$TargetBranch"
        Invoke-Git -Args @("update-ref", $refName, $sourceSha, $ExpectedTargetSha) | Out-Null
        $afterSha = (Invoke-Git -Args @("rev-parse", $TargetBranch)).text.Trim()
        if ($afterSha -ne $sourceSha) {
            $result.reason = "CAS_FAIL: $TargetBranch ref update did not land expected source sha."
        }
        else {
            $result.pass = $true
            $result.updated = $true
            $result.observed_target_sha = $afterSha
            $result.reason = "PASS"
        }
    }
}

$obj = [pscustomobject]$result
if ($Json) {
    $obj | ConvertTo-Json -Depth 6
    if (-not $obj.pass) { exit 1 }
}
else {
    if (-not $obj.pass) {
        throw $obj.reason
    }
    Write-Output ("PASS: compare-and-swap updated {0} to {1}" -f $obj.target_branch, $obj.source_sha)
}
