param(
    [Parameter(Mandatory)]
    [string]$DesignPath,

    [string]$RoadmapPath = "",

    [switch]$ForceMermaidFallback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $DesignPath)) {
    throw "Design file not found: $DesignPath"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptDir
$resolved = (Get-Item -LiteralPath $skillRoot).ResolveLinkTarget($true)
if ($resolved) { $skillRoot = $resolved.FullName }
$repoRoot = Split-Path -Parent (Split-Path -Parent $skillRoot)

. (Join-Path $repoRoot 'scripts\wrap-prompt-envelope.ps1')
. (Join-Path $repoRoot 'scripts\security\redact-secrets.ps1')
. (Join-Path $repoRoot 'scripts\visualize\mermaid-wrap.ps1')

$raw = Get-Content -LiteralPath $DesignPath -Raw
$redacted = Invoke-SecretRedaction -Text $raw

# Boundary primitive is mandatory any time upstream markdown is interpreted for planning.
$enveloped = New-PromptEnvelope -Label 'DT-ROADMAP SOURCE DESIGN' -Content $redacted
$envelopeSha = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($enveloped))
).Replace('-', '').ToLowerInvariant()

if ([string]::IsNullOrWhiteSpace($RoadmapPath)) {
    $RoadmapPath = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $DesignPath).Path) 'roadmap.md'
}

$phaseMatches = [regex]::Matches($redacted, '(?m)^###\s+(Phase\s+[0-9A-Za-z\- ]+.*|Contract Freeze Gate.*|Value Review.*)$')
$milestones = @()
$idx = 0
foreach ($m in $phaseMatches) {
    $idx++
    $name = $m.Groups[1].Value.Trim()
    $milestones += [pscustomobject]@{
        id = ('M{0:D2}' -f $idx)
        name = $name
        dependencies = if ($idx -eq 1) { '-' } else { ('M{0:D2}' -f ($idx - 1)) }
        verification_mode = if ($name -like '*Gate*') { 'machine-checkable' } else { 'agent' }
    }
}

if ($milestones.Count -eq 0) {
    throw "No phase milestones found in design markdown headings (expected ### Phase ... headings)."
}

$chunkRows = New-Object System.Collections.Generic.List[object]
$milestoneRows = New-Object System.Collections.Generic.List[string]
$manifestRows = New-Object System.Collections.Generic.List[string]

foreach ($m in $milestones) {
    $slug = ($m.name.ToLowerInvariant() -replace '[^a-z0-9]+', '-') -replace '(^-|-$)', ''
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = ('milestone-{0}' -f $m.id.ToLowerInvariant()) }
    $chunkSlug = "chunk-$slug"

    $chunkRows.Add([pscustomobject]@{
        'chunk-slug' = $chunkSlug
        'milestone-id' = $m.id
        'model-routing' = if ($m.verification_mode -eq 'machine-checkable') { 'codex' } else { 'claude' }
        'reference-pack-entitlement' = 'contracts, glossary'
    })

    $milestoneRows.Add("| $($m.id) | $($m.name) | $($m.dependencies) | $chunkSlug | $($m.verification_mode) | baseline-floor-default | plan-check:$($m.id.ToLowerInvariant()) | carry-forward from design-final non-negotiables and approved trade-offs |")

    $manifestRows.Add("| chk-$($m.id.ToLowerInvariant()) | $($m.id) | integration | repo baseline ready | $($m.verification_mode) | Run acceptance checks for $($m.id) and capture PASS/FAIL evidence. |")
}

$mermaid = New-MermaidRenderPayload -Milestones $milestones -TryMcp:(-not $ForceMermaidFallback) -VendoredAssetPath (Join-Path $repoRoot 'assets\visualize\vendored\mermaid-10.9.3.min.js')

$generatedUtc = (Get-Date).ToUniversalTime().ToString('o')

$roadmap = @"
---
schema_version: 1
source_artifact: $DesignPath
generated_at_utc: $generatedUtc
---

# Roadmap Contract

Derived from the finalized design source and prepared for Phase-7 dt-build intake.

## Milestones

| id | name | dependencies | chunks | verification-mode | baseline-floor | acceptance-checks | decision-basis |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
$($milestoneRows -join "`n")

## Chunks

| chunk-slug | milestone-id | model-routing | reference-pack-entitlement |
| :-- | :-- | :-- | :-- |
$($chunkRows | ForEach-Object { "| $($_.'chunk-slug') | $($_.'milestone-id') | $($_.'model-routing') | $($_.'reference-pack-entitlement') |" } | Out-String)

## Verification Manifest

| check-id | milestone-id | execution-scope | prerequisites | mode | procedure |
| :-- | :-- | :-- | :-- | :-- | :-- |
$($manifestRows -join "`n")

## Dependency Graph (Mermaid)

~~~mermaid
$($mermaid.GraphDefinition)
~~~

## Sequential Gantt (Mermaid)

~~~mermaid
$($mermaid.GanttDefinition)
~~~

## Dependency Provenance

- renderer: $($mermaid.Renderer)
$($mermaid.Provenance | ForEach-Object { "- $_" } | Out-String)

## Producer Provenance

- source-envelope-sha256: $envelopeSha
- source-path: $DesignPath
- generated-at-utc: $generatedUtc
"@

Set-Content -LiteralPath $RoadmapPath -Value $roadmap -Encoding UTF8

[pscustomobject]@{
    roadmap_path = $RoadmapPath
    milestone_count = $milestones.Count
    chunk_count = $chunkRows.Count
    renderer = $mermaid.Renderer
    envelope_sha256 = $envelopeSha
} | ConvertTo-Json -Depth 5
