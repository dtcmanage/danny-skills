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
$parts.Add([System.IO.File]::ReadAllText((Join-Path $skillRoot "references/adapter-$CoordinatorHost.md")))
foreach ($section in $sections) {
    $start = $text.IndexOf($section[0], [System.StringComparison]::Ordinal)
    $end = $text.IndexOf($section[1], [System.StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -le $start) { throw "DT_BUILD_RULEBOOK_SECTION_MISSING: $($section[0])" }
    $parts.Add($text.Substring($start, $end - $start).Trim())
}
$parts.Add('Load acceptance-contract.md before an acceptance gate. Load SKILL.md step 6.5 and applicable close-out gates before completion. Run authority, approvals and boundaries remain mandatory; this rulebook grants no permission.')
[Console]::Out.WriteLine(($parts -join "`n`n"))
