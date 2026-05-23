param(
    [Parameter(Mandatory)]
    [string]$SourceRef,

    [Parameter(Mandatory)]
    [string]$ExpectedDevSha,

    [string]$DevBranch = "dev",
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
        throw ("DEV_CAS_FAIL: git {0}`n{1}" -f ($Args -join " "), ($out -join "`n"))
    }
    return [pscustomobject]@{
        code = $code
        lines = @($out)
        text = ($out -join "`n")
    }
}

$gitRoot = Invoke-Git -Args @("rev-parse", "--show-toplevel")
$sourceSha = (Invoke-Git -Args @("rev-parse", $SourceRef)).text.Trim()
$currentDevSha = (Invoke-Git -Args @("rev-parse", $DevBranch)).text.Trim()

$result = [ordered]@{
    pass = $false
    dev_branch = $DevBranch
    source_ref = $SourceRef
    source_sha = $sourceSha
    expected_dev_sha = $ExpectedDevSha
    observed_dev_sha = $currentDevSha
    mode = "compare-and-swap"
    updated = $false
    reason = ""
}

if ($currentDevSha -ne $ExpectedDevSha) {
    $result.reason = "DEV_CAS_BLOCKED: dev advanced before compare-and-swap update."
}
else {
    $ancestorCheck = Invoke-Git -Args @("merge-base", "--is-ancestor", $currentDevSha, $sourceSha) -AllowFailure
    if ($ancestorCheck.code -ne 0) {
        $result.reason = "DEV_CAS_BLOCKED: source is not a fast-forward descendant of current dev."
    }
    else {
        $refName = "refs/heads/$DevBranch"
        Invoke-Git -Args @("update-ref", $refName, $sourceSha, $ExpectedDevSha) | Out-Null
        $afterSha = (Invoke-Git -Args @("rev-parse", $DevBranch)).text.Trim()
        if ($afterSha -ne $sourceSha) {
            $result.reason = "DEV_CAS_FAIL: dev ref update did not land expected source sha."
        }
        else {
            $result.pass = $true
            $result.updated = $true
            $result.observed_dev_sha = $afterSha
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
    Write-Output ("PASS: compare-and-swap updated {0} to {1}" -f $obj.dev_branch, $obj.source_sha)
}
