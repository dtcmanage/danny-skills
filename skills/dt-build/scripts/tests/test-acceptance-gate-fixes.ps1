# Isolated end-to-end fixtures for the default-branch floor and run evidence.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scripts = Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'acceptance-row-schema.ps1')
$root = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.cache/build-acceptance-gates/gate-fixes-' + [guid]::NewGuid().ToString('N'))
$tree = Join-Path $root 'tree'; $run = Join-Path $root 'run'
New-Item -ItemType Directory -Path "$tree/scripts", "$run/replay" -Force | Out-Null
function Check([bool]$Ok, [string]$Label) { if (-not $Ok) { throw $Label }; "PASS: $Label" }
function Gate {
    $raw = & pwsh -NoProfile -File (Join-Path $scripts 'verify-milestone-acceptance.ps1') -RoadmapPath "$run/roadmap.md" -MilestoneId M01 -WorkingTree $tree -RunTests -Json 2> "$root/gate.stderr"
    $script:gateExit = $LASTEXITCODE
    return ($raw -join "`n" | ConvertFrom-Json)
}
function Ledger([string]$Name) {
    $out = Join-Path $root $Name
    $summary = & pwsh -NoProfile -File (Join-Path $scripts 'build-acceptance-ledger.ps1') -RoadmapPath "$run/roadmap.md" -WorkingTree $tree -RunFolder $run -OutDir $out -RunTests
    $script:ledgerExit = $LASTEXITCODE
    [pscustomobject]@{
        summary=($summary -join "`n")
        markdown=[IO.File]::ReadAllText("$out/build-acceptance-revalidation.md")
        html=[IO.File]::ReadAllText("$out/build-acceptance-revalidation.html")
        diagnostics=[IO.File]::ReadAllText("$out/verify-M01.stderr.log")
    }
}
try {
    & git -C $tree init -b main -q
    & git -C $tree config user.email fixture@example.test
    & git -C $tree config user.name Fixture
    [IO.File]::WriteAllText("$tree/scripts/check.ps1", "'ASSERT_FAIL: existing failure'; exit 7")
    & git -C $tree add .
    & git -C $tree commit -qm fixture
    [IO.File]::WriteAllText("$run/replay/replay-report.md", 'retained run evidence')
    [IO.File]::WriteAllText("$run/roadmap.md", @'
## Milestones
| id | acceptance-checks |
| --- | --- |
| M01 | Inspect `replay/replay-report.md` |
## Verification Manifest
| check-id | milestone-id | procedure |
| --- | --- | --- |
| CHK-01 | M01 | Run `pwsh -NoProfile -File scripts/check.ps1` |
'@)
    $r = Gate
    Check ($gateExit -eq 0 -and $r.accepted -and $r.command_results[0].exit_code -eq 7 -and $r.command_results[0].baseline.identical_failure) 'default-branch failure passes with raw exit and explicit baseline evidence'
    Check ($r.artifacts_present -contains 'replay/replay-report.md') 'replay artifact resolves in run folder'
    $row = [pscustomobject]@{milestone_id='M01'; commit_sha=('a'*40); accepted=$true; status='PASS'; tests='baseline floor'; command_results=$r.command_results}
    Check (@(Get-AcceptanceRowSchemaErrors $row).Count -eq 0) 'ledger writer accepts evidenced baseline floor'
    $r.command_results[0].baseline.baseline_fingerprint = '0'*64
    Check (@(Get-AcceptanceRowSchemaErrors $row).Count -gt 0) 'ledger refuses a mismatched baseline fingerprint'
    @{milestone_id='M01';status='PASS';commit_sha=(& git -C $tree rev-parse HEAD).Trim();tests='baseline checks passed'} | ConvertTo-Json -Compress | Set-Content "$run/acceptance-rows.jsonl"
    $ledger = Ledger identical
    Check ($ledgerExit -eq 0 -and $ledger.markdown -match '\| PASS \|' -and $ledger.html -match '\[baseline-identical exit=7; main [0-9a-f]{40}\]') 'ledger renders baseline-floor PASS with raw exit and default-branch commit'
    Check ($ledger.diagnostics -match 'FAILED COMMAND \(exit=7\)' -and $ledger.markdown -notmatch 'unparseable|unknown' -and $ledger.summary -notmatch 'unknown') 'baseline diagnostics retained separately without contaminating PASS or JSON'
    [IO.File]::WriteAllText("$tree/scripts/check.ps1", "'PASS'; exit 0")
    $ledger = Ledger repaired
    Check ($ledgerExit -eq 0 -and $ledger.markdown -match '\| PASS \|' -and $ledger.html -match '\[exit=0\]' -and $ledger.diagnostics -match 'FAILED COMMAND \(exit=7\)') 'candidate improvement passes despite baseline failure diagnostics'
    [IO.File]::WriteAllText("$tree/scripts/check.ps1", "'ASSERT_FAIL: changed failure'; exit 7")
    $r = Gate
    Check ($gateExit -eq 1 -and -not $r.accepted -and -not $r.command_results[0].baseline.identical_failure) 'changed failure blocks end to end'
    $ledger = Ledger changed
    Check ($ledgerExit -eq 1 -and $ledger.markdown -match '\| BLOCKED \|' -and $ledger.markdown -match 'verification command failed' -and $ledger.html -notmatch '\[baseline-identical') 'ledger remains fail closed for changed failures after separating diagnostics'
    [IO.File]::WriteAllText("$tree/scripts/check.ps1", "'ASSERT_FAIL: existing failure'; 'ASSERT_FAIL: new failure'; exit 7")
    $r = Gate
    Check ($gateExit -eq 1 -and -not $r.accepted) 'additional failure blocks end to end'
    [IO.File]::WriteAllText("$tree/scripts/check.ps1", "'ASSERT_FAIL: existing failure'; exit 7")
    Remove-Item "$run/replay/replay-report.md"
    New-Item -ItemType Directory "$tree/replay" | Out-Null
    [IO.File]::WriteAllText("$tree/replay/replay-report.md", 'stale wrong-location evidence')
    $r = Gate
    Check ($gateExit -eq 1 -and $r.artifacts_missing -contains 'replay/replay-report.md') 'worktree copy cannot hide missing run evidence'

    New-Item -ItemType Directory "$root/scan" | Out-Null
    [IO.File]::WriteAllText("$root/scan/worker.instructions.md", 'partial verifier')
    [IO.File]::WriteAllText("$root/scan/output.stream.log", 'partial verifier')
    [IO.File]::WriteAllText("$root/scan/report.md", 'clean report')
    & pwsh -NoProfile -File (Join-Path $scripts 'check-downgrade-language.ps1') -Path "$root/scan" -Recurse -Json | Out-Null
    Check ($LASTEXITCODE -eq 0) 'generated instructions and stream logs excluded'
    [IO.File]::WriteAllText("$root/scan/report.md", 'partial verifier')
    & pwsh -NoProfile -File (Join-Path $scripts 'check-downgrade-language.ps1') -Path "$root/scan" -Recurse -Json | Out-Null
    Check ($LASTEXITCODE -eq 1) 'ordinary report still scanned'

    . (Join-Path $scripts 'authority-digest.ps1')
    $candidates = @(Get-AuthorityCandidates 'skills/*/SKILL.md; skills/*/CHANGELOG.md' @{})
    Check (-not (@($candidates.literal) -contains '/SKILL.md') -and @($candidates.literal) -contains 'skills/*/SKILL.md') 'wildcard path remains whole for explicit waiver'
    Check (Test-AuthorityContextDocument '/home/danny/Claude/_Claude-Workspace/00_Resources/coding-conventions.md') 'canonical resource is pinned without recursively treating citations as originals'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
