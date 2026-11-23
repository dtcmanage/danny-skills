# Release-time finding severity triage (dt-build final review / final-milestone
# acceptance, dt-ship). Policy: 00_Resources/build-process.md, "Minor findings at
# release time ship as known issues, not blockers".
#
# Only a critical finding blocks a release. Critical means exactly one of:
#   core-flow        a broken core user flow
#   data-loss        data loss or corruption
#   security         a security hole
#   deploy-rollback  a broken deploy or rollback
# Everything else (docs wording, cosmetic UI, a small edge-case bug, test or doc
# hygiene) is a known issue: the already-gated candidate ships unchanged, the
# finding is logged under "## Known issues" in <run-folder>/deferred-findings.md,
# listed in the release summary, and fixed in the next release. A known issue
# never triggers a fix round or a full-gate rerun.
#
# CLI:
#   pwsh -NoProfile -File scripts/release-triage.ps1 -FindingsPath <findings.json>
#        -Stage final-review|final-milestone|ship [-RunFolder <run>] [-Json]
#   pwsh -NoProfile -File scripts/release-triage.ps1 -ListKnownIssues -DeferredPath <deferred-findings.md> [-Json]
#
# findings.json is an array (or {"findings": [...]}) of objects:
#   id (required), what (required; "title" accepted), where (required),
#   type (app-bug|test-env|docs|design-gap, optional), milestone (optional),
#   critical (core-flow|data-loss|security|deploy-rollback; absent/"none" = not critical),
#   critical_scenario (required when critical: the concrete failure),
#   why_not_blocking (required when not critical).
# A review severity of "important" does not block on its own at release time;
# only a critical class does.
#
# Exit codes: 0 ship (no critical finding), 2 block (one or more critical),
# 1 invalid input. Callers that need the functions dot-source release-triage-lib.ps1,
# never this file (its param block would overwrite the caller's parameters).

[CmdletBinding(DefaultParameterSetName = 'Triage')]
param(
    [Parameter(ParameterSetName = 'Triage')]
    [string]$FindingsPath,

    [Parameter(ParameterSetName = 'Triage')]
    [ValidateSet('final-review', 'final-milestone', 'ship')]
    [string]$Stage,

    [Parameter(ParameterSetName = 'Triage')]
    [string]$RunFolder,

    [Parameter(ParameterSetName = 'List')]
    [switch]$ListKnownIssues,

    [Parameter(ParameterSetName = 'List')]
    [string]$DeferredPath,

    [switch]$Json
)

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'release-triage-lib.ps1')


$ErrorActionPreference = 'Stop'
if ($PSCmdlet.ParameterSetName -eq 'List') {
    $items = @(Get-KnownIssues -Path $DeferredPath)
    if ($Json) { ConvertTo-Json -InputObject @($items) -Depth 4 } else { $items | ForEach-Object { $_.line } }
    exit 0
}

if (-not $FindingsPath -or -not $Stage) {
    Write-Error 'release-triage: -FindingsPath and -Stage are required.'
    exit 1
}
try {
    $raw = Get-Content -LiteralPath $FindingsPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "release-triage: cannot read findings JSON '$FindingsPath': $($_.Exception.Message)"
    exit 1
}
$list = if ($raw -is [array]) { $raw } elseif ($raw -and (Get-ReleaseTriageValue $raw 'findings')) { @(Get-ReleaseTriageValue $raw 'findings') } elseif ($raw) { @($raw) } else { @() }
$result = Invoke-ReleaseTriage -Findings @($list) -Stage $Stage -RunFolder $RunFolder
if ($Json) {
    $result | ConvertTo-Json -Depth 5
} else {
    Write-Output "decision: $($result.decision)"
    foreach ($e in $result.errors) { Write-Output "error: $e" }
    foreach ($b in $result.blocking) { Write-Output "BLOCKER $($b.key) [$($b.critical)]: $($b.scenario)" }
    foreach ($k in $result.known_issues) { Write-Output "known issue: $k" }
    if ($result.deferred_path) { Write-Output "logged: $($result.deferred_path)" }
}
switch ($result.decision) { 'ship' { exit 0 } 'block' { exit 2 } default { exit 1 } }
