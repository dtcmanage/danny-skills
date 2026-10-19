# Shared wrapper checks; approvals remain owned by dt-job.
function Assert-WorkerAttemptApproval {
    param([int]$RequestedAttempt, [string]$ApprovalName, [string]$ApprovalRunFolder)
    if ($RequestedAttempt -le 2) { return }
    if (-not $ApprovalName -or -not $ApprovalRunFolder) {
        throw 'ATTEMPT_APPROVAL_REQUIRED: attempts 3+ require -ApprovalOperation and a run folder with a recorded approval.'
    }
    try {
        # Function scope keeps dt-job's parameter defaults out of the wrapper scope.
        . (Join-Path $PSScriptRoot 'dt-job.ps1')
        $approved = @((Get-DtJobApprovals -RunFolder $ApprovalRunFolder).approvals | Where-Object {
            $_.PSObject.Properties['operation'] -and $_.operation -ceq $ApprovalName
        })
        if ($approved.Count -eq 0) { throw 'operation is not recorded as approved' }
    } catch { throw "ATTEMPT_APPROVAL_REQUIRED: cannot verify '$ApprovalName': $($_.Exception.Message)" }
}

function Get-WorkerStartCommit {
    param([string]$Tree)
    $head = & git -C $Tree rev-parse --verify -q HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { return [string]$head }
    # An unborn branch has no start commit; compare against Git's empty tree instead.
    $emptyTree = $null | & git -C $Tree mktree
    if ($LASTEXITCODE -ne 0) { throw 'CHANGED_FILES_GIT_FAILED: cannot record start tree.' }
    return [string]$emptyTree
}

function Get-WorkerChangedFiles {
    param([string]$Tree, [string]$StartCommit, [string]$ReportPath)
    # NUL delimiters preserve Unicode, spaces, quotes and newlines in Git paths.
    $tracked = (@(& git -C $Tree diff --no-ext-diff --no-renames --name-only -z $StartCommit --) -join "`n")
    if ($LASTEXITCODE -ne 0) { throw 'CHANGED_FILES_GIT_FAILED: cannot inspect changes from start commit.' }
    $untracked = (@(& git -C $Tree ls-files --others --exclude-standard -z) -join "`n")
    if ($LASTEXITCODE -ne 0) { throw 'CHANGED_FILES_GIT_FAILED: cannot inspect untracked files.' }
    $actual = @(($tracked.Split([char]0) + $untracked.Split([char]0)) | Where-Object { $_ -ne '' } | Sort-Object -Unique -CaseSensitive)
    $report = if (Test-Path -LiteralPath $ReportPath) { [IO.File]::ReadAllText($ReportPath) } else { '' }
    $entries = if ($report) { Get-DtReportSection -Text $report -Name CHANGED_FILES -PathField } else { @() }
    $entries = @($entries | Where-Object { $null -ne $_ })
    $reported = @($entries | Where-Object { $_ -cne 'NONE' } | ForEach-Object { $_.Replace('\', '/') -replace '^\./', '' } | Sort-Object -Unique -CaseSensitive)
    $mismatch = ($entries.Count -eq 0) -or ($entries -contains 'NONE' -and $entries.Count -gt 1) -or
        (@(Compare-Object -ReferenceObject (@('') + $actual) -DifferenceObject (@('') + $reported) -CaseSensitive).Count -gt 0)
    $warnings = @(if ($mismatch) { 'REPORT_CHANGED_FILES_MISMATCH' })
    if ($mismatch) { [Console]::Error.WriteLine('WARNING: REPORT_CHANGED_FILES_MISMATCH: reported [' + ($reported -join ', ') + ']; actual [' + ($actual -join ', ') + ']') }
    [pscustomobject]@{ actual_changed_files = @($actual); warnings = @($warnings) }
}
