param(
    [Parameter(Mandatory)]
    [string]$SourceRef,

    [Parameter(Mandatory)]
    [string]$ExpectedTargetSha,

    [Parameter(Mandatory)]
    [string]$TargetBranch,

    [string]$RepoPath = (Get-Location).Path,

    [switch]$AllowRebase,

    # Explicit attestation: the old tip from which the caller performed the planned rebase.
    [string]$RebasedFromSha,

    [string]$RunFolder,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($TargetBranch -in @('main', 'master')) {
    throw "CAS_FAIL: refusing to mutate protected branch '$TargetBranch'."
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string[]]$Args,
        [switch]$AllowFailure
    )
    $out = & git -C $RepoPath @Args 2>&1
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
    $resolvedOld = if ($RebasedFromSha) {
        $oldRef = if ($RebasedFromSha -match '^[0-9a-fA-F]{7,40}$') { $RebasedFromSha.ToLowerInvariant() } else { $RebasedFromSha }
        (Invoke-Git -Args @('rev-parse', '--verify', "$oldRef^{commit}") -AllowFailure).text.Trim()
    } else { '' }
    $rebase = $ancestorCheck.code -eq 1 -and $AllowRebase -and $RunFolder -and $resolvedOld -ceq $currentTargetSha
    if ($rebase) {
        # Compare the old divergent range against the same number of commits at the new tip.
        # range-diff must pair every commit with an identical patch (including empty commits).
        $common = (Invoke-Git -Args @('merge-base', $currentTargetSha, $sourceSha) -AllowFailure)
        $equivalent = $false
        if ($common.code -eq 0) {
            $oldRange = "$($common.text.Trim())..$currentTargetSha"
            $count = [int](Invoke-Git -Args @('rev-list', '--count', $oldRange)).text.Trim()
            $newBase = Invoke-Git -Args @('rev-parse', '--verify', "$sourceSha~$count") -AllowFailure
            if ($count -gt 0 -and $newBase.code -eq 0) {
                $diff = Invoke-Git -Args @('range-diff', '--no-color', '--no-ext-diff', $oldRange, "$($newBase.text.Trim())..$sourceSha") -AllowFailure
                $pairs = @($diff.lines | Where-Object { $_ -match '^\s*\d+:\s+[0-9a-f]+\s+=\s+\d+:\s+[0-9a-f]+\s' })
                $equivalent = $diff.code -eq 0 -and $pairs.Count -eq $count -and @($diff.lines | Where-Object { $_ -notmatch '^\s*\d+:\s+[0-9a-f]+\s+=\s+\d+:\s+[0-9a-f]+\s' -and $_.Trim() }).Count -eq 0
            }
        }
        if (-not $equivalent) {
            $rebase = $false
            $result.reason = 'CAS_BLOCKED: rebased tip patch set does not match the old divergent range.'
        }
    }
    if ($ancestorCheck.code -ne 0 -and -not $rebase) {
        if (-not $result.reason) { $result.reason = "CAS_BLOCKED: source is not a fast-forward descendant of current $TargetBranch." }
        if ($AllowRebase) { $result.reason += ' Rebase requires -RunFolder and -RebasedFromSha equal to the expected old tip.' }
    }
    else {
      try {
        $refName = "refs/heads/$TargetBranch"
        if ($rebase) {
            # Dot-source in a child scope: dt-job's parameters must not clear CAS parameters.
            & {
                param($ledgerRun, $branch, $oldTip, $newTip)
                . (Join-Path $PSScriptRoot 'dt-job.ps1')
                Invoke-DtJobLocked -RunFolder $ledgerRun -Action {
                    $reason = "Planned rebase of $branch from $oldTip to $newTip; old tip resolved and patch set verified with git range-diff."
                    Add-DtJobEvent -RunFolder $ledgerRun -JobId 'run' -Type 'branch_rebase_requested' -Status 'runnable' -Reason $reason
                    try {
                        Invoke-Git -Args @('update-ref', "refs/heads/$branch", $newTip, $oldTip) | Out-Null
                    } catch {
                        Add-DtJobEvent -RunFolder $ledgerRun -JobId 'run' -Type 'branch_rebase_failed' -Status 'failed' -Reason "$reason $($_.Exception.Message)"
                        throw
                    }
                    Add-DtJobEvent -RunFolder $ledgerRun -JobId 'run' -Type 'branch_rebased' -Status 'accepted' -Reason $reason
                }
            } $RunFolder $TargetBranch $ExpectedTargetSha $sourceSha
            $result.mode = 'compare-and-swap-rebase'
        } else { Invoke-Git -Args @("update-ref", $refName, $sourceSha, $ExpectedTargetSha) | Out-Null }
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
      } catch {
        $result.reason = "CAS_FAIL: $($_.Exception.Message)"
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
