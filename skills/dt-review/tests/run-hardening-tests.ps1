[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -match $Pattern) { return }
        throw "ASSERTION FAILED: $Message (unexpected error: $($_.Exception.Message))"
    }
    throw "ASSERTION FAILED: $Message (no error was thrown)"
}

function Write-Utf8([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

$SkillRoot = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent (Split-Path -Parent $SkillRoot)
$testRoot = Join-Path $env:TEMP ("dt-review-hardening-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

try {
    . (Join-Path $SkillRoot 'scripts\validate-review-semantics.ps1')
    $validReview = [ordered]@{
        headline = 'Fixture review.'
        dimension_assessments = [ordered]@{ intent='ok'; completeness='ok'; coherence='ok'; resilience='ok'; economy='ok'; feasibility='ok' }
        prior_finding_checks = @()
        findings = @([ordered]@{
            id='R1-F01'; status='NEW'; title='Fixture finding'; dimension='Completeness'; severity='medium'; blocks_design=$true
            root_cause='A contract is absent.'; remediation='Add the contract.'; validation_check='Verify the contract.'
            ambiguous_root_cause=$false; candidate_dimensions=@(); missing_evidence=''; owner_role=''
        })
        engagement_with_prior_reasoning = 'First round.'
        verdict = 'MATERIAL_CHANGES_NEEDED'
        confidence = 'high'
        confidence_reason = 'The evidence is direct.'
    }

    $blankHeadline = $validReview | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $blankHeadline.headline = ''
    Assert-Throws { Assert-DtReviewSemantics -Review $blankHeadline -Round 1 -PriorEntries @() | Out-Null } "non-empty 'headline'" 'blank core critique field passed semantic validation'

    $ownerlessHigh = $validReview | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $ownerlessHigh.findings[0].severity = 'high'
    Assert-Throws { Assert-DtReviewSemantics -Review $ownerlessHigh -Round 1 -PriorEntries @() | Out-Null } 'requires a non-empty owner_role' 'ownerless high-severity finding passed semantic validation'

    # Blocking policy: high blocks in any round, medium only in rounds 1-2, low never.
    $mediumRound1 = $validReview | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $downgrades = @(Set-DtReviewBlockingPolicy -Review $mediumRound1 -Round 1)
    Assert-True ($downgrades.Count -eq 0 -and [bool]$mediumRound1.findings[0].blocks_design -and $mediumRound1.verdict -eq 'MATERIAL_CHANGES_NEEDED') 'medium finding in round 1 was downgraded'
    $mediumRound3 = $validReview | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $downgrades = @(Set-DtReviewBlockingPolicy -Review $mediumRound3 -Round 3)
    Assert-True ($downgrades.Count -eq 1 -and $downgrades[0].id -eq 'R1-F01' -and -not [bool]$mediumRound3.findings[0].blocks_design -and $mediumRound3.verdict -eq 'MINOR_POLISH_ONLY') 'medium finding in round 3 still blocked'
    $lowRound1 = $validReview | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $lowRound1.findings[0].severity = 'low'
    $downgrades = @(Set-DtReviewBlockingPolicy -Review $lowRound1 -Round 1)
    Assert-True ($downgrades.Count -eq 1 -and $lowRound1.verdict -eq 'MINOR_POLISH_ONLY') 'low finding blocked in round 1'
    $highRound4 = $validReview | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $highRound4.findings[0].severity = 'high'
    $highRound4.findings[0].owner_role = 'operator'
    $downgrades = @(Set-DtReviewBlockingPolicy -Review $highRound4 -Round 4)
    Assert-True ($downgrades.Count -eq 0 -and [bool]$highRound4.findings[0].blocks_design -and $highRound4.verdict -eq 'MATERIAL_CHANGES_NEEDED') 'high finding in round 4 was downgraded'

    # Invocation must canonically refresh a stale prompt and bind every input hash.
    $receiptProject = Join-Path $testRoot 'receipt-project'
    $receiptScratch = Join-Path $receiptProject 'design\_review'
    New-Item -ItemType Directory -Path $receiptScratch -Force | Out-Null
    $receiptDraft = Join-Path $receiptScratch 'draft-v1.md'
    Write-Utf8 $receiptDraft "# Receipt A`n"
    $assemblyA = (& (Join-Path $SkillRoot 'scripts\assemble-review-prompt.ps1') -ProjectPath $receiptProject -Round 1 -Tier light) | ConvertFrom-Json
    Write-Utf8 $receiptDraft "# Receipt B`n"
    . (Join-Path $SkillRoot 'scripts\invocation-receipt.ps1')
    $receiptB = Get-DtReviewInvocationReceipt `
        -ProjectPath $receiptProject -Round 1 -Tier light -PromptPath $assemblyA.prompt_path `
        -AssemblerPath (Join-Path $SkillRoot 'scripts\assemble-review-prompt.ps1')
    Assert-True ($receiptB.prompt_sha256 -cne $assemblyA.prompt_sha256) 'stale prompt was not regenerated after draft mutation'
    Assert-True ((Get-Content -LiteralPath $receiptB.prompt_path -Raw).Contains('# Receipt B')) 'regenerated prompt did not embed the current draft'
    Write-Utf8 $receiptDraft "# Receipt C`n"
    Assert-Throws { Assert-DtReviewInvocationReceipt -Receipt $receiptB -Round 1 -Tier light } 'draft SHA-256 mismatch' 'post-assembly draft mutation did not invalidate the invocation receipt'

    # Exceptional I/O exits use the same bounded tree-kill primitive as timeouts.
    # Exercise that primitive against a live process so the finally wiring cannot
    # regress to Dispose-only cleanup.
    . (Join-Path $RepoRoot 'scripts\invoke-codex-process.ps1')
    $sleepInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $sleepInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
    $sleepInfo.UseShellExecute = $false
    $sleepInfo.CreateNoWindow = $true
    [void]$sleepInfo.ArgumentList.Add('-NoProfile')
    [void]$sleepInfo.ArgumentList.Add('-Command')
    [void]$sleepInfo.ArgumentList.Add('Start-Sleep -Seconds 10')
    $sleepProcess = [System.Diagnostics.Process]::new()
    $sleepProcess.StartInfo = $sleepInfo
    Assert-True $sleepProcess.Start() 'cleanup fixture process did not start'
    Stop-CodexProcessBounded -Process $sleepProcess -GraceMs 1000
    Assert-True $sleepProcess.HasExited 'bounded exceptional cleanup left the process running'
    $sleepProcess.Dispose()

    [pscustomobject]@{ status='ok'; assertions=7 } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).Path
        $tempPrefix = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if ($resolved.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved).StartsWith('dt-review-hardening-')) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
