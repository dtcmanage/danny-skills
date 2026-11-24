#Requires -Version 7.0
# Render the resume rulebook directly from authoritative sources; never duplicate execution policy.
param([ValidateSet('codex', 'claude')][string]$CoordinatorHost = 'codex')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$resolved = (Get-Item -LiteralPath $skillRoot).ResolveLinkTarget($true)
if ($resolved) { $skillRoot = $resolved.FullName }
$text = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'SKILL.md')).Replace("`r`n", "`n")
$sections = @(
    @('## Model routing', '## Context discipline'),
    @('## Context discipline', '## Usage telemetry'),
    @('6. Execute milestones', '6.5 Emit acceptance ledger'),
    @('7. Guardrails:', '8. Skill propagation gate')
)
$parts = [System.Collections.Generic.List[string]]::new()
$repoRoot = Split-Path -Parent (Split-Path -Parent $skillRoot)
$parts.Add("Resolved script anchors: <skill> = $skillRoot; <danny-skills> = $repoRoot. Quote substituted paths.")
$resume = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'references/managed-resume.md')).Replace("`r`n", "`n")
# Bootstrap needs the complete authorization contract, not launch-watch, checkpoint-writing,
# roll-forward and recovery procedures. Keep selected sections verbatim and fail closed.
$resumeSections = @(
    @('# Managed coordinator resume', '## Lean checkpoint'),
    @('## Local work never stops', '## Launch watch'),
    @('## Operator actions belong to the launching session', '## Live-bug fast lane'),
    @('## Live-bug fast lane', '## Authority read contract'),
    @('## Authority read contract', '## Worker authority scope')
)
foreach ($section in $resumeSections) {
    $start = $resume.IndexOf($section[0], [StringComparison]::Ordinal)
    $end = $resume.IndexOf($section[1], [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -le $start) { throw "DT_BUILD_RULEBOOK_SECTION_MISSING: $($section[0])" }
    $parts.Add($resume.Substring($start, $end - $start).Trim())
}
$parts.Add('After mark-bootstrap, load the applicable managed-resume.md section before checkpoint writing, lane-health diagnosis, worker authority scoping or authority roll-forward. Launch watch and operator recovery belong to the launching session. Do not reread the entire reference.')
foreach ($policy in @('deterministic-reference-policy.md', 'conventions.md')) {
    $parts.Add([System.IO.File]::ReadAllText((Join-Path $repoRoot "references/$policy")))
}
$parts.Add([System.IO.File]::ReadAllText((Join-Path $skillRoot "references/adapter-$CoordinatorHost.md")))
. (Join-Path $PSScriptRoot 'worker-standing-rules.ps1')
$parts.Add('Before every builder/fix/verifier brief: ' + (Get-WorkerEnvironmentRule))
foreach ($section in $sections) {
    $start = $text.IndexOf($section[0], [System.StringComparison]::Ordinal)
    $end = $text.IndexOf($section[1], [System.StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -le $start) { throw "DT_BUILD_RULEBOOK_SECTION_MISSING: $($section[0])" }
    $parts.Add($text.Substring($start, $end - $start).Trim())
}
$parts.Add('Load acceptance-contract.md before an acceptance gate. Load SKILL.md step 6.5 and applicable close-out gates before completion. Run authority, approvals and boundaries remain mandatory; this rulebook grants no permission.')
[Console]::Out.WriteLine(($parts -join "`n`n"))
