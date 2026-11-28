# Pure inventory fixtures: isolated files only, no runtime registry, jobs or leases.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../authority-digest.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('discovery-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root -Force | Out-Null
$checkpoint = Join-Path $root '_build-state.md'
$passed = 0
function Check([bool]$Ok, [string]$Label) { if (-not $Ok) { throw $Label }; $script:passed++; "PASS: $Label" }
function Text([string]$Path, [string]$Value) { [IO.File]::WriteAllText((Join-Path $root $Path), $Value) }
function Missing([string]$Expected) {
    $failure = ''
    try { Get-AuthorityInventory $root $checkpoint | Out-Null } catch { $failure = $_.Exception.Message }
    Check ($failure.StartsWith('AUTHORITY_MISSING:') -and $failure.Contains($Expected)) "explicit missing authority blocks: $Expected"
}
try {
    $fixture = Get-Content -Raw (Join-Path $PSScriptRoot 'fixtures/authority-discovery-category-exceptions.json') | ConvertFrom-Json
    Check ($fixture.rows.Count -eq 261 -and $fixture.row_count -eq 261) 'all 261 sanitized incident rows retained'
    $prose = ($fixture.rows | ForEach-Object { 'Observed artifact `' + $_.candidate + '`.' }) -join "`n"
    Text roadmap.md $prose
    Text policy.md ($prose + "`nImplementation mentions ``CLAUDE.md`` and ``.claude.json``.")
    Text objective.md 'Read original: missing-from-objective.md'
    Text build-decision-log.md 'Read original: missing-from-log.md'
    Text approvals.json '{"approvals":[],"awaiting":{"message":"Coordinator blocked before bootstrap: read-coordinator-state.ps1 fails with missing /SKILL.md, /CHANGELOG.md and /var/lib/capacity-watch/state.json. Evidence only."}}'
    Text _build-state.md "roadmap_path: roadmap.md`nobjective: ``objective.md```ndecision_log: ``build-decision-log.md```nRead governing original: ``policy.md`` IN FULL."
    $inventory = @(Get-AuthorityInventory $root $checkpoint)
    Check ($inventory.Count -eq 3) 'only explicit roadmap, policy and complete approvals are pinned'
    Check (@($script:AuthorityDiagnostics | Where-Object required).Count -eq 0) 'generic incident prose cannot create a missing original'
    Text _build-state.md "Read governing original: ``build-decision-log.md`` IN FULL."
    $inventory = @(Get-AuthorityInventory $root $checkpoint)
    Check ($inventory.Count -eq 2) 'explicitly pinned log is read without recursively mining its content'
    Text _build-state.md 'Read original: missing-bare.md'
    Missing missing-bare.md
    $homeMissing = '__build-acceptance-missing-' + [guid]::NewGuid().ToString('N') + '.md'
    Text _build-state.md ('Read original: `~/' + $homeMissing + '`')
    Missing $homeMissing
    Text _build-state.md 'Current boundary: `policy.md`'
    Text policy.md 'Read original: nested-missing.md'
    Missing nested-missing.md
    Text policy.md 'Only local source changes.'
    Text approvals.json '{"approvals":[{"source":"missing-approval.md"}]}'
    Missing missing-approval.md
    Text approvals.json '{"approvals":[]}'
    Remove-Item (Join-Path $root policy.md)
    Missing policy.md
    # Reproduce the digest fixture's explicit Markdown boundary and nested approvals.
    # An ordinary link remains navigation; the authority label is what makes this an edge.
    $linked = Join-Path $root 'linked'
    New-Item -ItemType Directory (Join-Path $linked 'approvals') -Force | Out-Null
    $linkedCheckpoint = Join-Path $linked '_build-state.md'
    [IO.File]::WriteAllText($linkedCheckpoint, "Inherited: ``old boundary.md```nCurrent boundary: [current](current-boundary.md)")
    [IO.File]::WriteAllText((Join-Path $linked 'old boundary.md'), 'Scope: fixtures only; never deploy.')
    [IO.File]::WriteAllText((Join-Path $linked 'current-boundary.md'), "Only source changes. Approval: ``approval.md```nRead original: approvals/r3b3.md.`nObserved artifact [details](missing-navigation.md).")
    [IO.File]::WriteAllText((Join-Path $linked 'approval.md'), 'Approved: fixtures only.')
    [IO.File]::WriteAllText((Join-Path $linked 'approvals/r3b3.md'), 'Approved: source-only recovery. Never deploy.')
    $linkedApprovals = Join-Path $linked 'approvals.json'
    [IO.File]::WriteAllText($linkedApprovals, '{"awaiting":null,"approvals":[{"source":"approval.md"}]}')
    $inventory = @(Get-AuthorityInventory $linked $linkedCheckpoint)
    $expected = @('old boundary.md', 'current-boundary.md', 'approval.md', 'approvals/r3b3.md', 'approvals.json')
    Check ($inventory.Count -eq $expected.Count) 'explicit linked boundary and nested approvals pin exactly five originals'
    foreach ($name in $expected) {
        Check (@($inventory | Where-Object path -eq (Join-Path $linked $name)).Count -eq 1) "explicit original pinned exactly once: $name"
    }
    $mandatory = @(Get-AuthorityMandatoryPaths $inventory $linkedCheckpoint)
    foreach ($name in @('current-boundary.md', 'approval.md', 'approvals/r3b3.md', 'approvals.json')) {
        Check ($mandatory -contains (Join-Path $linked $name)) "linked boundary/approval remains a full read: $name"
    }
    [IO.File]::WriteAllText($linkedCheckpoint, "design_path: plan-draft.md`nCurrent boundary: [current](current-boundary.md)")
    [IO.File]::WriteAllText((Join-Path $linked 'plan-draft.md'), 'Scope: local source changes only.')
    [IO.File]::WriteAllText($linkedApprovals, '{"awaiting":null,"approvals":[],"scope_source":"plan-draft.md"}')
    $inventory = @(Get-AuthorityInventory $linked $linkedCheckpoint)
    $mandatory = @(Get-AuthorityMandatoryPaths $inventory $linkedCheckpoint)
    Check ($mandatory -contains (Join-Path $linked 'plan-draft.md')) 'structured approval scope_source promotes the design locator to a mandatory full read'
    foreach ($name in @('current-boundary.md', 'plan-draft.md')) {
        $path = Join-Path $linked $name
        $saved = [IO.File]::ReadAllText($path)
        Remove-Item -LiteralPath $path
        $failure = ''
        try { Get-AuthorityInventory $linked $linkedCheckpoint | Out-Null } catch { $failure = $_.Exception.Message }
        Check ($failure.StartsWith('AUTHORITY_MISSING:') -and $failure.Contains($name)) "linked/structured missing authority fails closed: $name"
        [IO.File]::WriteAllText($path, $saved)
    }
    # Evidence locators remain diagnostic even under an authority label, with
    # hostile contents, case differences or no file. Never recurse into them.
    Text approvals.json '{"approvals":[]}'
    Text evidence-notes.json 'Read governing original: missing-from-evidence.md IN FULL.'
    foreach ($locator in @('evidence-notes.json', 'EVIDENCE-NOTES.json')) {
        Text _build-state.md ("Evidence: ``$locator```nRead original: ``$locator`` IN FULL.")
        $inventory = @(Get-AuthorityInventory $root $checkpoint)
        Check ($inventory.Count -eq 1 -and (Split-Path -Leaf $inventory[0].path) -eq 'approvals.json') "evidence contents never extend authority: $locator"
        Check (@($script:AuthorityDiagnostics | Where-Object { $_.candidate -ceq $locator -and $_.reason -eq 'evidence_only' -and -not $_.required }).Count -eq 2) "both evidence locators keep evidence_only diagnostics: $locator"
    }
    Remove-Item (Join-Path $root 'evidence-notes.json')
    $inventory = @(Get-AuthorityInventory $root $checkpoint)
    Check (@($script:AuthorityDiagnostics | Where-Object reason -eq 'evidence_only').Count -eq 2) 'missing evidence remains informational'
    "SUMMARY: $passed passed, 0 failed"
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
