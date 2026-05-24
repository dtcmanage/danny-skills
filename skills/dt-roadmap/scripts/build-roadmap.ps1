param(
    [Parameter(Mandatory)]
    [string]$DesignPath,

    [string]$RoadmapPath = "",

    [string]$RoadmapViewPath = "",

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

function Escape-Html {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Escape-MermaidDefinition {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return $Text.Replace("&", "&amp;").Replace("<", "&lt;")
}

function Get-RelativePath {
    param(
        [string]$FromDirectory,
        [string]$ToPath
    )
    $from = [System.Uri]((Resolve-Path -LiteralPath $FromDirectory).Path + [System.IO.Path]::DirectorySeparatorChar)
    $to = [System.Uri]((Resolve-Path -LiteralPath $ToPath).Path)
    $relative = $from.MakeRelativeUri($to).ToString()
    return [System.Uri]::UnescapeDataString($relative)
}

function Write-RoadmapReviewHtml {
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [array]$Milestones,

        [Parameter(Mandatory)]
        [object]$Mermaid,

        [Parameter(Mandatory)]
        [string]$RendererAssetPath,

        [Parameter(Mandatory)]
        [string]$GeneratedUtc,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$RoadmapMarkdownPath
    )

    $outDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $assetRel = Get-RelativePath -FromDirectory $outDir -ToPath $RendererAssetPath
    $graphDefinition = Escape-MermaidDefinition $Mermaid.GraphDefinition
    $ganttDefinition = Escape-MermaidDefinition $Mermaid.GanttDefinition

    $milestoneRowsHtml = foreach ($m in $Milestones) {
        "<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td></tr>" -f `
            (Escape-Html ([string]$m.id)), `
            (Escape-Html ([string]$m.name)), `
            (Escape-Html ([string]$m.dependencies)), `
            (Escape-Html ([string]$m.verification_mode))
    }

    $provenanceItems = @("renderer: $($Mermaid.Renderer)") + @($Mermaid.Provenance)
    $provenanceRowsHtml = $provenanceItems |
        Select-Object -Unique |
        ForEach-Object { "<li>{0}</li>" -f (Escape-Html ([string]$_)) }

    $html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Roadmap Review</title>
  <style>
    :root { --bg:#f3f5f7; --card:#ffffff; --ink:#14212f; --muted:#5f6e7d; --line:#d9e1ea; --accent:#0b6b7a; }
    * { box-sizing:border-box; }
    body { margin:0; background:#f3f5f7; color:var(--ink); font-family:"Segoe UI", Tahoma, sans-serif; }
    .wrap { max-width:1180px; margin:22px auto; padding:0 16px 28px; }
    .card { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:14px; margin-bottom:12px; }
    h1,h2,h3 { margin:0 0 8px; }
    .meta { color:var(--muted); font-size:14px; }
    .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(190px,1fr)); gap:10px; margin-top:10px; }
    .metric { border:1px solid var(--line); border-radius:8px; padding:10px; background:#fbfdff; }
    .k { color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.04em; }
    .v { margin-top:5px; font-weight:700; }
    table { width:100%; border-collapse:collapse; }
    th,td { border:1px solid var(--line); padding:8px; font-size:14px; text-align:left; vertical-align:top; }
    th { background:#eef3f9; }
    .diagram-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(340px,1fr)); gap:12px; }
    .diagram-card { border:1px solid var(--line); border-radius:8px; padding:10px; background:#fbfdff; overflow:auto; }
    .mermaid { width:100%; min-height:130px; overflow:auto; border:1px solid var(--line); border-radius:8px; padding:8px; background:#ffffff; }
    .mermaid svg { display:block; max-width:100%; height:auto; margin:0 auto; }
    ul { margin:0; padding-left:20px; }
    li { margin-bottom:6px; }
  </style>
</head>
<body>
  <main class="wrap">
    <section class="card">
      <h1>Roadmap Contract Review</h1>
      <div class="meta">Generated $GeneratedUtc from $(Escape-Html $SourcePath)</div>
      <div class="grid">
        <div class="metric"><div class="k">Milestones</div><div class="v">$($Milestones.Count)</div></div>
        <div class="metric"><div class="k">Renderer</div><div class="v">$(Escape-Html ([string]$Mermaid.Renderer))</div></div>
        <div class="metric"><div class="k">Roadmap</div><div class="v">$(Escape-Html ([System.IO.Path]::GetFileName($RoadmapMarkdownPath)))</div></div>
      </div>
    </section>

    <section class="card">
      <h2>Milestones</h2>
      <table>
        <thead><tr><th>ID</th><th>Name</th><th>Depends On</th><th>Verification</th></tr></thead>
        <tbody>
          $($milestoneRowsHtml -join "`n          ")
        </tbody>
      </table>
    </section>

    <section class="card">
      <h2>Dependency Graph + Timeline</h2>
      <section class="diagram-grid">
        <article class="diagram-card">
          <h3>Dependency Graph</h3>
          <div class="mermaid">
$graphDefinition
          </div>
        </article>
        <article class="diagram-card">
          <h3>Sequential Gantt</h3>
          <div class="mermaid">
$ganttDefinition
          </div>
        </article>
      </section>
    </section>

    <section class="card">
      <h2>Dependency Provenance</h2>
      <ul>
        $($provenanceRowsHtml -join "`n        ")
      </ul>
    </section>
  </main>
  <script src="$assetRel"></script>
  <script>
  window.addEventListener('DOMContentLoaded', async function () {
    if (!window.mermaid) {
      return;
    }
    window.mermaid.initialize({ startOnLoad: false, securityLevel: 'strict' });
    await window.mermaid.run({ querySelector: '.mermaid' });
  });
  </script>
</body>
</html>
"@

    Set-Content -LiteralPath $OutputPath -Value $html -Encoding UTF8
}

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
$RoadmapPath = [System.IO.Path]::GetFullPath($RoadmapPath)
if ([string]::IsNullOrWhiteSpace($RoadmapViewPath)) {
    $RoadmapViewPath = Join-Path (Split-Path -Parent $RoadmapPath) 'roadmap-view.html'
}
$RoadmapViewPath = [System.IO.Path]::GetFullPath($RoadmapViewPath)

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
$vendoredMermaidPath = Join-Path $repoRoot 'assets\visualize\vendored\mermaid-10.9.3.min.js'

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
Write-RoadmapReviewHtml -OutputPath $RoadmapViewPath -Milestones $milestones -Mermaid $mermaid -RendererAssetPath $vendoredMermaidPath -GeneratedUtc $generatedUtc -SourcePath $DesignPath -RoadmapMarkdownPath $RoadmapPath

[pscustomobject]@{
    roadmap_path = $RoadmapPath
    roadmap_view_path = $RoadmapViewPath
    milestone_count = $milestones.Count
    chunk_count = $chunkRows.Count
    renderer = $mermaid.Renderer
    envelope_sha256 = $envelopeSha
} | ConvertTo-Json -Depth 5
