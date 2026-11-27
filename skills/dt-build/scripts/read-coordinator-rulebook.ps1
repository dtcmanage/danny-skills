#Requires -Version 7.0
# Render scoped rules from their authoritative sources. Entry is the bootstrap read only.
param(
    [ValidateSet('codex', 'claude')][string]$CoordinatorHost = 'codex',
    [ValidateSet('entry','authority','execution','routing','context','guardrails','adapter','worker-briefs','checkpoint','lane-health','worker-authority','roll-forward','local-work','operator-actions','fast-lane','shared')]
    [string]$Section = 'entry'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$resolved = (Get-Item -LiteralPath $skillRoot).ResolveLinkTarget($true)
if ($resolved) { $skillRoot = $resolved.FullName }
$repoRoot = Split-Path -Parent (Split-Path -Parent $skillRoot)
$text = [IO.File]::ReadAllText((Join-Path $skillRoot 'SKILL.md')).Replace("`r`n", "`n")
$resume = [IO.File]::ReadAllText((Join-Path $skillRoot 'references/managed-resume.md')).Replace("`r`n", "`n")
function Get-RuleSection([string]$Source, [string]$Start, [string]$End) {
    $a = $Source.IndexOf($Start, [StringComparison]::Ordinal)
    $b = $Source.IndexOf($End, [StringComparison]::Ordinal)
    if ($a -lt 0 -or $b -le $a) { throw "DT_BUILD_RULEBOOK_SECTION_MISSING: $Start" }
    $Source.Substring($a, $b - $a).Trim()
}
$catalog = [ordered]@{
    authority = @('## Authority read contract', '## Worker authority scope', 'before resolving authorization; included in entry')
    execution = @('6. Execute milestones', '6.5 Emit acceptance ledger', 'after bootstrap, before reconciliation or milestone work')
    routing = @('## Model routing', '## Context discipline', 'before dispatch or changing a model lane')
    context = @('## Context discipline', '## Usage telemetry', 'after bootstrap, before evidence reads or rotation')
    guardrails = @('7. Guardrails:', '8. Skill propagation gate', 'before milestone work or boundary operations')
    checkpoint = @('## Lean checkpoint', '## Local work never stops', 'before rewriting a checkpoint')
    'lane-health' = @('## Lane health', '## Operator actions belong', 'before lane-health diagnosis')
    'worker-authority' = @('## Worker authority scope', '## Lean Claude sessions', 'before preparing a worker brief')
    'roll-forward' = @('## Authority roll-forward', '## Operator recovery', 'before consolidating authority')
    'local-work' = @('## Local work never stops', '## Launch watch', 'before deciding whether local work needs a stop')
    'operator-actions' = @('## Operator actions belong', '## Live-bug fast lane', 'before raising a stop; launching session owns resume/approve')
    'fast-lane' = @('## Live-bug fast lane', '## Authority read contract', 'when a live bug interrupts milestone work')
}
$parts = [Collections.Generic.List[string]]::new()
$version = [regex]::Match($text, '(?m)^  version: (.+)$').Groups[1].Value.Trim()
if (-not $version) { throw 'DT_BUILD_RULEBOOK_VERSION_MISSING' }
$parts.Add("dt-build $version; section: $Section. Resolved script anchors: <skill> = $skillRoot; <danny-skills> = $repoRoot. Quote substituted paths.")
if ($Section -eq 'entry') {
    $parts.Add((Get-RuleSection $resume '# Managed coordinator resume' '## Carry on'))
    $parts.Add((Get-RuleSection $resume $catalog.authority[0] $catalog.authority[1]))
    $parts.Add([IO.File]::ReadAllText((Join-Path $repoRoot 'references/deterministic-reference-policy.md')).Trim())
    $conventions = [IO.File]::ReadAllText((Join-Path $repoRoot 'references/conventions.md')).Replace("`r`n", "`n")
    $parts.Add((Get-RuleSection $conventions '## Path resolution' '## Frontmatter fields'))
    $parts.Add('On-demand sections: run this same command with -Section <name>; load only when its trigger fires, after mark-bootstrap. This entry grants no permission.')
    foreach ($name in $catalog.Keys) { $parts.Add("- ${name}: $($catalog[$name][2]).") }
    $parts.Add('- adapter: before dt-job operations after the marker. - worker-briefs: before every builder/fix/verifier brief. - shared: before authoring artifacts or friction notes; full shared conventions (bootstrap path rules already included).')
    $parts.Add('Canonical policies: read 00_Resources/git-workflow.md before actual git actions; model-routing.md before dispatch; build-process.md before starting a new build or close-out. None is triggered by merely reading this existing run. Read browser policy before browser work and tech-stack guidance before application-development work. Required authorization originals always load before the marker. Read acceptance-contract.md before an acceptance gate; SKILL.md step 6.5 and close-out gates before completion.')
} elseif ($Section -eq 'adapter') {
    $parts.Add([IO.File]::ReadAllText((Join-Path $skillRoot "references/adapter-$CoordinatorHost.md")))
} elseif ($Section -eq 'worker-briefs') {
    . (Join-Path $PSScriptRoot 'worker-standing-rules.ps1')
    $parts.Add((Get-WorkerEnvironmentRule))
    $briefs = [IO.File]::ReadAllText((Join-Path $skillRoot 'references/subagent-prompts.md')).Replace("`r`n", "`n")
    $parts.Add((Get-RuleSection $briefs 'Shared rules:' '## Approved retries and file reports'))
} elseif ($Section -eq 'shared') {
    foreach ($policy in @('deterministic-reference-policy.md', 'conventions.md')) { $parts.Add([IO.File]::ReadAllText((Join-Path $repoRoot "references/$policy"))) }
} else {
    $source = if ($Section -in @('execution','routing','context','guardrails')) { $text } else { $resume }
    if ($Section -eq 'execution') { $parts.Add((Get-RuleSection $resume '## Carry on' '## Lean checkpoint')) }
    $parts.Add((Get-RuleSection $source $catalog[$Section][0] $catalog[$Section][1]))
}
$output = $parts -join "`n`n"
# Below Claude's 30k-character display ceiling, with room for tool framing. Never truncate policy.
if ($Section -eq 'entry' -and $output.Length -gt 20000) { throw "DT_BUILD_ENTRY_DISPLAY_BUDGET: $($output.Length) characters exceeds 20000; split an on-demand section" }
[Console]::Out.WriteLine($output)
