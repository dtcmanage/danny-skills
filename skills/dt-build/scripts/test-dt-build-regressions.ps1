param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT_FAIL: $Message" }
}

function Write-Utf8 {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

$scriptDir = Split-Path -Parent $PSCommandPath
$skillRoot = Split-Path -Parent $scriptDir
$resolvedSkillRoot = (Get-Item -LiteralPath $skillRoot).ResolveLinkTarget($true)
if ($resolvedSkillRoot) { $skillRoot = $resolvedSkillRoot.FullName }
$repoRoot = Split-Path -Parent (Split-Path -Parent $skillRoot)
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-build-regressions-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$originalCodexHome = $env:CODEX_HOME

try {
    # Extract once: a backticked python -m pytest command must not produce an
    # inner duplicate pytest invocation.
    . (Join-Path $repoRoot 'scripts\extract-named-artifacts.ps1')
    $extracted = Extract-NamedArtifacts -Text 'Run `python -m pytest tests/test_one.py -q` and capture PASS/FAIL.'
    Assert-True ($extracted.commands.Count -eq 1) "python -m pytest was extracted more than once"
    Assert-True ($extracted.commands[0] -eq 'python -m pytest tests/test_one.py -q') "wrong extracted command"

    # Current model tiers resolve deterministically from a synthetic live cache.
    . (Join-Path $repoRoot 'scripts\resolve-codex-model.ps1')
    $cachePath = Join-Path $tempRoot 'models.json'
    Write-Utf8 -Path $cachePath -Content @'
{"models":[
  {"slug":"gpt-5.6-sol","visibility":"list"},
  {"slug":"gpt-5.6-terra","visibility":"list"},
  {"slug":"gpt-5.6-luna","visibility":"list"},
  {"slug":"gpt-5.3-codex-spark","visibility":"list"}
]}
'@
    Assert-True ((Resolve-CodexModel -Tier complex -CachePath $cachePath -Strict) -eq 'gpt-5.6-sol') "complex tier did not select Sol"
    Assert-True ((Resolve-CodexModel -Tier standard -CachePath $cachePath -Strict) -eq 'gpt-5.6-terra') "standard tier did not select Terra"
    Assert-True ((Resolve-CodexModel -Tier light -CachePath $cachePath -Strict) -eq 'gpt-5.6-luna') "light tier did not select Luna"
    $effortCache = Join-Path $tempRoot 'models-effort.json'
    Write-Utf8 -Path $effortCache -Content '{"models":[{"slug":"gpt-5.5","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}]}]}'
    $fallbackModel = Resolve-CodexModel -Tier standard -PreferredModel 'gone-model' -CachePath $effortCache -Strict
    $effortRejected = $false
    try { [void](Assert-CodexReasoningEffort -Model $fallbackModel -Effort max -CachePath $effortCache -Strict) }
    catch { $effortRejected = $true }
    Assert-True $effortRejected "unsupported reasoning effort was not rejected after model fallback"

    $workingTree = Join-Path $tempRoot 'working-tree'
    New-Item -ItemType Directory -Path (Join-Path $workingTree 'tests') -Force | Out-Null
    Write-Utf8 -Path (Join-Path $workingTree 'tests\noisy.ps1') -Content @'
1..3000 | ForEach-Object {
    Write-Output ("stdout-{0:D5}-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" -f $_)
    [Console]::Error.WriteLine(("stderr-{0:D5}-yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy" -f $_))
}
'@
    Write-Utf8 -Path (Join-Path $workingTree 'tests\slow.ps1') -Content 'Start-Sleep -Seconds 5'
    & git -C $workingTree init -q
    & git -C $workingTree config user.email 'fixture@example.invalid'
    & git -C $workingTree config user.name 'Fixture'
    & git -C $workingTree add .
    & git -C $workingTree commit -q -m 'working tree fixture'
    $workingSha = (& git -C $workingTree rev-parse HEAD).Trim()

    $roadmap = Join-Path $tempRoot 'roadmap.md'
    Write-Utf8 -Path $roadmap -Content @'
---
schema_version: 1
source_artifact: fixture
generated_at_utc: 2026-07-12T00:00:00Z
---

## Milestones
| id | name | dependencies | chunks | verification-mode | baseline-floor | acceptance-checks | decision-basis |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| M01 | Foundation | - | chunk-m01 | machine-checkable | none | Run `pwsh -NoProfile -File tests/noisy.ps1` and capture PASS/FAIL. | fixture |
| M02 | Cut over with rollback intact | M01 | chunk-m02 | machine-checkable | M01 | Run `pwsh -NoProfile -File tests/slow.ps1` and capture PASS/FAIL. | fixture |

## Chunks
| chunk-slug | milestone-id | model-routing | reference-pack-entitlement |
| :-- | :-- | :-- | :-- |
| chunk-m01 | M01 | codex | contracts, glossary |
| chunk-m02 | M02 | codex | contracts, glossary |

## Verification Manifest
| check-id | milestone-id | execution-scope | prerequisites | mode | procedure |
| :-- | :-- | :-- | :-- | :-- | :-- |
| chk-m01-first | M01 | integration | none | machine-checkable | Run an end-to-end check with `pwsh -NoProfile -File tests/noisy.ps1`. |
| chk-m01 | M01 | integration | none | machine-checkable | Run `pwsh -NoProfile -File tests/noisy.ps1` and capture PASS/FAIL. |
| chk-m02 | M02 | integration | M01 | machine-checkable | Run `pwsh -NoProfile -File tests/slow.ps1` and capture PASS/FAIL. |

## Dependency Graph (Mermaid)
```mermaid
graph TD
  M01 --> M02
```

## Sequential Gantt (Mermaid)
```mermaid
gantt
  title Fixture
  dateFormat X
  section Build
  M01 :m01, 0, 1
  M02 :m02, after m01, 1
```
'@

    # Multi-check load-bearing evidence must include the first check rather than
    # only the last row, and common production/cutover wording must classify.
    $loadJson = & pwsh -NoProfile -File (Join-Path $scriptDir 'identify-load-bearing.ps1') -RoadmapPath $roadmap -Json
    $load = $loadJson | ConvertFrom-Json
    Assert-True ($load.load_bearing_milestones -contains 'M01') "first of multiple verification rows was missed"
    Assert-True ($load.load_bearing_milestones -contains 'M02') "cutover milestone was missed"

    # High-volume stdout+stderr must complete without pipe deadlock and execute
    # the named command exactly once.
    $verifyJson = & pwsh -NoProfile -File (Join-Path $scriptDir 'verify-milestone-acceptance.ps1') `
        -RoadmapPath $roadmap -MilestoneId M01 -WorkingTree $workingTree -RunTests -CommandTimeoutMs 30000 -Json
    Assert-True ($LASTEXITCODE -eq 0) "high-volume verifier failed"
    $verify = $verifyJson | ConvertFrom-Json
    Assert-True ($verify.status -eq 'PASS') "high-volume verifier did not PASS"
    Assert-True ($verify.commands_named.Count -eq 1) "verifier ran a duplicate command"
    Assert-True (-not $verify.command_results[0].timed_out) "high-volume verifier timed out"

    # Timeout is bounded, recorded, and blocks acceptance.
    $timeoutJson = & pwsh -NoProfile -File (Join-Path $scriptDir 'verify-milestone-acceptance.ps1') `
        -RoadmapPath $roadmap -MilestoneId M02 -WorkingTree $workingTree -RunTests -CommandTimeoutMs 1000 -Json
    Assert-True ($LASTEXITCODE -eq 1) "timed-out verifier did not block"
    $timeout = $timeoutJson | ConvertFrom-Json
    Assert-True ([bool]$timeout.command_results[0].timed_out) "timeout provenance missing"

    # Final ledger renders stored acceptance and never fabricates implementation.
    $runFolder = Join-Path $tempRoot 'run'
    New-Item -ItemType Directory -Path $runFolder -Force | Out-Null
    $storedPass = [ordered]@{ milestone_id='M01'; status='PASS'; commit_sha=$workingSha; tests='1 fixture passed' } | ConvertTo-Json -Compress
    Write-Utf8 -Path (Join-Path $runFolder 'acceptance-rows.jsonl') -Content $storedPass
    Write-Utf8 -Path (Join-Path $runFolder 'build-decision-log.md') -Content @'
## M01
downgrade_approved_by: danny
rationale: Framework limitation accepted with visible evidence.
'@
    $ledgerOut = Join-Path $tempRoot 'ledger'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'build-acceptance-ledger.ps1') `
        -RoadmapPath $roadmap -WorkingTree $workingTree -OutDir $ledgerOut -RunFolder $runFolder *> $null
    Assert-True ($LASTEXITCODE -eq 1) "ledger should remain blocked for unstarted M02"
    $ledgerText = Get-Content -Raw -LiteralPath (Join-Path $ledgerOut 'build-acceptance-ledger.md')
    Assert-True ($ledgerText -match '\| M01 \| YES \| YES \| NO \| APPROVED_DOWNGRADE \|') "semantic approval on a machine PASS was not preserved"
    Assert-True ($ledgerText -match '\| M02 \| NO \| NO \| NO \| BLOCKED \|') "unstarted milestone was reported implemented"

    $storedMissingTests = [ordered]@{ milestone_id='M01'; status='PASS'; commit_sha=$workingSha } | ConvertTo-Json -Compress
    Write-Utf8 -Path (Join-Path $runFolder 'acceptance-rows.jsonl') -Content $storedMissingTests
    $missingTestsOut = Join-Path $tempRoot 'ledger-missing-tests'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'build-acceptance-ledger.ps1') `
        -RoadmapPath $roadmap -WorkingTree $workingTree -OutDir $missingTestsOut -RunFolder $runFolder *> $null
    $missingTestsLedger = Get-Content -Raw -LiteralPath (Join-Path $missingTestsOut 'build-acceptance-ledger.md')
    Assert-True ($missingTestsLedger -match '\| M01 \| YES \| NO \| NO \| BLOCKED \|') "stored PASS without test evidence was accepted"

    $stoppedPass = [ordered]@{ milestone_id='M01'; status='PASS_WITH_RUN_STOP'; commit_sha=$workingSha; tests='1 fixture passed'; run_stop_reason='attempt budget exhausted' } | ConvertTo-Json -Compress
    Write-Utf8 -Path (Join-Path $runFolder 'acceptance-rows.jsonl') -Content $stoppedPass
    $stoppedOut = Join-Path $tempRoot 'ledger-stopped-pass'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'build-acceptance-ledger.ps1') `
        -RoadmapPath $roadmap -WorkingTree $workingTree -OutDir $stoppedOut -RunFolder $runFolder *> $null
    $stoppedLedger = Get-Content -Raw -LiteralPath (Join-Path $stoppedOut 'build-acceptance-ledger.md')
    Assert-True ($stoppedLedger -match '\| M01 \| YES \| YES \| NO \| BLOCKED \|') "PASS_WITH_RUN_STOP was collapsed into a clean PASS"

    # A formatted-but-nonexistent SHA and status-only check cannot fabricate PASS.
    $fakeEvidence = '{"milestone_id":"M01","status":"PASS","commit_sha":"0123456789abcdef0123456789abcdef01234567","checks":[{"status":"PASS"}]}'
    Write-Utf8 -Path (Join-Path $runFolder 'acceptance-rows.jsonl') -Content $fakeEvidence
    $fakeOut = Join-Path $tempRoot 'ledger-fake-evidence'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'build-acceptance-ledger.ps1') `
        -RoadmapPath $roadmap -WorkingTree $workingTree -OutDir $fakeOut -RunFolder $runFolder *> $null
    $fakeLedger = Get-Content -Raw -LiteralPath (Join-Path $fakeOut 'build-acceptance-ledger.md')
    Assert-True ($fakeLedger -match '\| M01 \| NO \| NO \| NO \| BLOCKED \|') "fabricated commit/check evidence was accepted"

    # A per-check downgrade cannot disappear under an overall PASS row.
    $approvedCheck = [ordered]@{ milestone_id='M01'; status='PASS'; commit_sha=$workingSha; checks=@([ordered]@{name='semantic';status='APPROVED_DOWNGRADE';result='known limitation'}) } | ConvertTo-Json -Compress -Depth 5
    Write-Utf8 -Path (Join-Path $runFolder 'acceptance-rows.jsonl') -Content $approvedCheck
    Write-Utf8 -Path (Join-Path $runFolder 'build-decision-log.md') -Content '# no approval'
    $unapprovedOut = Join-Path $tempRoot 'ledger-unapproved-check'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'build-acceptance-ledger.ps1') `
        -RoadmapPath $roadmap -WorkingTree $workingTree -OutDir $unapprovedOut -RunFolder $runFolder *> $null
    $unapprovedLedger = Get-Content -Raw -LiteralPath (Join-Path $unapprovedOut 'build-acceptance-ledger.md')
    Assert-True ($unapprovedLedger -match '\| M01 \| YES \| YES \| NO \| BLOCKED \|') "per-check downgrade disappeared into PASS"

    # Fresh-process intake must not depend on ambient LASTEXITCODE or cwd and must
    # emit the corrected branch contract.
    $intakeOut = Join-Path $tempRoot 'intake'
    $intakeJson = & pwsh -NoProfile -File (Join-Path $scriptDir 'intake-dry-run.ps1') `
        -RepoPath $repoRoot -RoadmapPath $roadmap -OutputDirectory $intakeOut -RunId fixture-run -Json
    Assert-True ($LASTEXITCODE -eq 0) "fresh-process intake failed: $($intakeJson -join ' ')"
    $planText = Get-Content -Raw -LiteralPath (Join-Path $intakeOut 'fixture-run\build-plan.md')
    Assert-True ($planText -match 'integration_branch: build/fixture-run') "intake emitted wrong integration branch"
    Assert-True ($planText -match 'merge_target: main') "intake retained stale dev default"
    & pwsh -NoProfile -File (Join-Path $scriptDir 'intake-dry-run.ps1') `
        -RepoPath $repoRoot -RoadmapPath $roadmap -OutputDirectory $intakeOut -RunId protected `
        -IntegrationBranch main -MergeTarget main -UseExistingIntegrationBranch *> $null
    Assert-True ($LASTEXITCODE -ne 0) "intake allowed the protected merge target as integration branch"
    & pwsh -NoProfile -File (Join-Path $scriptDir 'intake-dry-run.ps1') `
        -RepoPath $repoRoot -RoadmapPath $roadmap -OutputDirectory $intakeOut -RunId missing-resume `
        -ResumeRunId missing-resume *> $null
    Assert-True ($LASTEXITCODE -ne 0) "resume allowed a missing integration branch state carrier"

    # The disjoint integration/chunk namespace must be creatable in real Git and
    # support the same compare-and-swap update dt-build performs per milestone.
    $gitFixture = Join-Path $tempRoot 'git-fixture'
    New-Item -ItemType Directory -Path $gitFixture -Force | Out-Null
    & git -C $gitFixture init -q
    & git -C $gitFixture config user.email 'fixture@example.invalid'
    & git -C $gitFixture config user.name 'Fixture'
    Write-Utf8 -Path (Join-Path $gitFixture 'base.txt') -Content 'base'
    & git -C $gitFixture add base.txt
    & git -C $gitFixture commit -q -m 'base'
    & git -C $gitFixture branch -M main
    $baseSha = (& git -C $gitFixture rev-parse HEAD).Trim()
    & pwsh -NoProfile -File (Join-Path $scriptDir 'prepare-integration-branch.ps1') `
        -RepoPath $gitFixture -IntegrationBranch 'build/fixture-run' -MergeTarget main *> $null
    Assert-True ($LASTEXITCODE -eq 0) "integration branch preparer failed"
    & git -C $gitFixture checkout -q -b 'dt-build/fixture-run/m01-chunk' $baseSha
    Write-Utf8 -Path (Join-Path $gitFixture 'chunk.txt') -Content 'chunk'
    & git -C $gitFixture add chunk.txt
    & git -C $gitFixture commit -q -m 'chunk'
    $chunkSha = (& git -C $gitFixture rev-parse HEAD).Trim()
    Push-Location $gitFixture
    try {
        & pwsh -NoProfile -File (Join-Path $scriptDir 'branch-cas-update.ps1') `
            -SourceRef 'dt-build/fixture-run/m01-chunk' -ExpectedTargetSha $baseSha `
            -TargetBranch 'build/fixture-run' -Json *> $null
        Assert-True ($LASTEXITCODE -eq 0) "CAS failed on corrected branch topology"
    }
    finally { Pop-Location }
    Assert-True (((& git -C $gitFixture rev-parse 'build/fixture-run').Trim()) -eq $chunkSha) "CAS did not advance integration branch"

    Push-Location $gitFixture
    try {
        & pwsh -NoProfile -File (Join-Path $scriptDir 'branch-cas-update.ps1') `
            -SourceRef 'dt-build/fixture-run/m01-chunk' -ExpectedTargetSha $baseSha -TargetBranch main -Json *> $null
        Assert-True ($LASTEXITCODE -ne 0) "CAS mutator allowed a protected branch"
    }
    finally { Pop-Location }

    # Parameter binding enforces the two-automatic-attempt cap.
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') `
        -ProjectPath $workingTree -Preflight -Attempt 3 *> $null
    Assert-True ($LASTEXITCODE -ne 0) "Codex wrapper accepted automatic attempt 3"

    # Wrapper validates report shape, redacts retained output, and preserves
    # failure provenance even when a child never reads stdin.
    $fixtureCodexHome = Join-Path $tempRoot 'codex-home'
    New-Item -ItemType Directory -Path $fixtureCodexHome -Force | Out-Null
    Write-Utf8 -Path (Join-Path $fixtureCodexHome 'models_cache.json') -Content '{"fetched_at":"fixture","models":[{"slug":"gpt-5.6-terra","visibility":"list","supported_reasoning_levels":[{"effort":"medium"}]}]}'
    Write-Utf8 -Path (Join-Path $fixtureCodexHome 'auth.json') -Content '{"auth_mode":"fixture"}'
    $env:CODEX_HOME = $fixtureCodexHome
    $fakeCodex = Join-Path $tempRoot 'fake-codex.ps1'
    Write-Utf8 -Path $fakeCodex -Content @'
if ($args -contains '--version') { Write-Output 'codex-cli fixture'; exit 0 }
$outIndex = [Array]::IndexOf([object[]]$args, '--output-last-message')
$outPath = if ($outIndex -ge 0) { [string]$args[$outIndex + 1] } else { '' }
$mode = [string]$env:DT_FAKE_CODEX_MODE
if ($mode -eq 'hang') { Start-Sleep -Seconds 10; exit 0 }
[void][Console]::In.ReadToEnd()
if ($mode -eq 'malformed') { [System.IO.File]::WriteAllText($outPath, 'I cannot do that.'); exit 0 }
$report = @"
DT_BUILD_REPORT_VERSION: 2
RUN_ID: fixture-run
chunk_id: fixture-chunk
attempt: 1
CHANGED_FILES:
NONE
COMMANDS_AND_RESULTS:
NONE
UNRESOLVED_BLOCKERS:
NONE
DISCOVERED_ENHANCEMENTS:
NONE
credential: ghp_abcdefghijklmnopqrstuvwxyz123456
"@
[System.IO.File]::WriteAllText($outPath, $report)
[Console]::Error.WriteLine('stream ghp_abcdefghijklmnopqrstuvwxyz123456')
'@
    $wrapperPrompt = Join-Path $tempRoot 'wrapper-prompt.md'
    Write-Utf8 -Path $wrapperPrompt -Content "RUN_ID: fixture-run`nchunk_id: fixture-chunk`nattempt: 1`nfixture"
    $wrapperOutput = Join-Path $tempRoot 'wrapper-output.md'
    $env:DT_FAKE_CODEX_MODE = 'success'
    $missingReasonOutput = Join-Path $tempRoot 'wrapper-missing-reason.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $missingReasonOutput `
        -CodexCliPath $fakeCodex -Tier standard -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0) "Codex wrapper allowed a substantive dispatch without -SelectionReason"
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $missingReasonOutput `
        -CodexCliPath $fakeCodex -Tier standard -SelectionReason "line one`nline two" -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0) "Codex wrapper allowed a multiline -SelectionReason"
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $wrapperOutput `
        -CodexCliPath $fakeCodex -Tier standard -SelectionReason 'ordinary fixture implementation logic' -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -eq 0) "mock Codex success path failed"
    $retained = Get-Content -Raw -LiteralPath $wrapperOutput
    Assert-True ($retained -notmatch 'ghp_') "retained chunk output leaked a credential"
    Assert-True ($retained -match '\[REDACTED-SECRET\]') "retained chunk output was not redacted"
    $wrapperProv = Get-Content -Raw -LiteralPath "$wrapperOutput.provenance.json" | ConvertFrom-Json
    Assert-True ([string]$wrapperProv.selection_reason -eq 'ordinary fixture implementation logic') "Codex provenance omitted selection reason"
    Assert-True ([string]$wrapperProv.disclosure_line -match '^MODEL_SELECTION: fixture-chunk -> gpt-5\.6-terra \(standard, effort medium\): ordinary fixture implementation logic$') "Codex provenance omitted canonical disclosure line"

    $env:DT_FAKE_CODEX_MODE = 'malformed'
    $malformedOutput = Join-Path $tempRoot 'wrapper-malformed.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $malformedOutput `
        -CodexCliPath $fakeCodex -Tier standard -SelectionReason 'ordinary fixture implementation logic' -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0) "malformed Codex output was accepted"
    $malformedProv = Get-Content -Raw -LiteralPath "$malformedOutput.provenance.json" | ConvertFrom-Json
    Assert-True (-not [bool]$malformedProv.pass) "malformed-output failure provenance claimed PASS"

    $env:DT_FAKE_CODEX_MODE = 'hang'
    $hangPrompt = Join-Path $tempRoot 'wrapper-hang-prompt.md'
    Write-Utf8 -Path $hangPrompt -Content ("RUN_ID: fixture-run`nchunk_id: fixture-chunk`nattempt: 1`n" + ('x' * 2097152))
    $hangOutput = Join-Path $tempRoot 'wrapper-hang.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $hangPrompt -OutputPath $hangOutput `
        -CodexCliPath $fakeCodex -Tier standard -SelectionReason 'ordinary fixture implementation logic' -Attempt 1 -TimeoutMs 1000 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0) "non-reading Codex child escaped timeout"
    $hangProv = Get-Content -Raw -LiteralPath "$hangOutput.provenance.json" | ConvertFrom-Json
    Assert-True (-not [bool]$hangProv.pass) "timeout failure provenance claimed PASS"
    Assert-True ([string]$hangProv.termination_reason -match 'TIMEOUT') "timeout failure provenance lacked termination reason"
    Remove-Item Env:DT_FAKE_CODEX_MODE -ErrorAction SilentlyContinue

    # Claude-lane wrapper mirrors the Codex wrapper contract: attempt cap,
    # report-shape validation, and redaction of retained output.
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') `
        -ProjectPath $workingTree -Preflight -Attempt 3 *> $null
    Assert-True ($LASTEXITCODE -ne 0) "Claude wrapper accepted automatic attempt 3"

    $fakeClaude = Join-Path $tempRoot 'fake-claude.ps1'
    Write-Utf8 -Path $fakeClaude -Content @'
if ($args -contains '--version') { Write-Output 'claude-cli fixture'; exit 0 }
[void][Console]::In.ReadToEnd()
$mode = [string]$env:DT_FAKE_CLAUDE_MODE
if ($mode -eq 'malformed') { Write-Output 'I cannot do that.'; exit 0 }
$report = @"
DT_BUILD_REPORT_VERSION: 2
RUN_ID: fixture-run
chunk_id: fixture-chunk
attempt: 1
CHANGED_FILES:
NONE
COMMANDS_AND_RESULTS:
NONE
UNRESOLVED_BLOCKERS:
NONE
DISCOVERED_ENHANCEMENTS:
NONE
credential: ghp_abcdefghijklmnopqrstuvwxyz123456
"@
Write-Output $report
'@
    $claudeOutput = Join-Path $tempRoot 'claude-wrapper-output.md'
    $env:DT_FAKE_CLAUDE_MODE = 'success'
    $claudeMissingReason = Join-Path $tempRoot 'claude-wrapper-missing-reason.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $claudeMissingReason `
        -ClaudeCliPath $fakeClaude -Tier standard -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0) "Claude wrapper allowed a substantive dispatch without -SelectionReason"
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $claudeMissingReason `
        -ClaudeCliPath $fakeClaude -Tier standard -SelectionReason "line one`nline two" -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0) "Claude wrapper allowed a multiline -SelectionReason"
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $claudeOutput `
        -ClaudeCliPath $fakeClaude -Tier standard -SelectionReason 'ordinary fixture verification logic' -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -eq 0) "mock Claude success path failed"
    $claudeRetained = Get-Content -Raw -LiteralPath $claudeOutput
    Assert-True ($claudeRetained -notmatch 'ghp_') "retained Claude chunk output leaked a credential"
    Assert-True ($claudeRetained -match '\[REDACTED-SECRET\]') "retained Claude chunk output was not redacted"
    $claudeProv = Get-Content -Raw -LiteralPath "$claudeOutput.provenance.json" | ConvertFrom-Json
    Assert-True ([string]$claudeProv.selection_reason -eq 'ordinary fixture verification logic') "Claude provenance omitted selection reason"
    Assert-True ([string]$claudeProv.disclosure_line -match '^MODEL_SELECTION: fixture-chunk -> sonnet \(standard\): ordinary fixture verification logic$') "Claude provenance omitted canonical disclosure line"

    $env:DT_FAKE_CLAUDE_MODE = 'malformed'
    $claudeMalformed = Join-Path $tempRoot 'claude-wrapper-malformed.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $claudeMalformed `
        -ClaudeCliPath $fakeClaude -Tier standard -SelectionReason 'ordinary fixture verification logic' -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0) "malformed Claude output was accepted"
    $claudeMalformedProv = Get-Content -Raw -LiteralPath "$claudeMalformed.provenance.json" | ConvertFrom-Json
    Assert-True (-not [bool]$claudeMalformedProv.pass) "malformed Claude-output failure provenance claimed PASS"
    Remove-Item Env:DT_FAKE_CLAUDE_MODE -ErrorAction SilentlyContinue

    Write-Output 'PASS: dt-build regression suite'
}
finally {
    if ($null -eq $originalCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    else { $env:CODEX_HOME = $originalCodexHome }
    Remove-Item Env:DT_FAKE_CODEX_MODE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
