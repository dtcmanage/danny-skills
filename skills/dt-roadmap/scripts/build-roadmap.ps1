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
. (Join-Path $repoRoot 'scripts\extract-named-artifacts.ps1')

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

function Get-SectionBody {
    # Capture from `## <Header>` up to next `## ` or EOF. Tolerant of
    # variant header phrasings: supply candidate names in priority order.
    param(
        [string]$Text,
        [string[]]$Headers
    )
    foreach ($h in $Headers) {
        $escaped = [regex]::Escape($h)
        $pattern = '(?ms)^##\s+' + $escaped + '\s*\r?\n(.*?)(?=^##\s+|\z)'
        $match = [regex]::Match($Text, $pattern)
        if ($match.Success) {
            return @{ Header = $h; Body = $match.Groups[1].Value }
        }
    }
    return $null
}

function Get-FirstSentence {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $trimmed = $Text.Trim()
    # Strip leading list/numbering markers (already stripped by caller, but be safe).
    $trimmed = ($trimmed -replace '^\d+[.)]\s+', '').Trim()
    # Split on sentence terminators followed by whitespace/end.
    $m = [regex]::Match($trimmed, '^(.+?[.!?])(\s|$)')
    if ($m.Success) {
        $candidate = $m.Groups[1].Value.Trim().TrimEnd('.', '!', '?')
        if ($candidate.Length -gt 0) { return $candidate }
    }
    if ($trimmed.Length -gt 80) {
        return $trimmed.Substring(0, 80).TrimEnd()
    }
    return $trimmed
}

function Parse-MilestonesFromImplementationSequence {
    # Primary parser. Reads a `## Implementation Sequence` (or equivalent)
    # section and turns its enumerated top-level numbered list into ordered
    # milestones (M01, M02, ...).
    param([string]$Text)

    $sectionCandidates = @(
        'Implementation Sequence',
        'Implementation Order',
        'Build Sequence',
        'Build Order',
        'Milestone Sequence'
    )
    $section = Get-SectionBody -Text $Text -Headers $sectionCandidates
    if ($null -eq $section) { return @() }

    $body = $section.Body
    $milestones = New-Object System.Collections.Generic.List[object]
    $current = $null
    $idx = 0

    foreach ($rawLine in ($body -split "`r?`n")) {
        $line = $rawLine
        # Top-level numbered list item: `1. `, `2) `, etc., no leading whitespace.
        if ($line -match '^(\d+)[.)]\s+(.+)$') {
            if ($null -ne $current) {
                [void]$milestones.Add($current)
            }
            $idx++
            $first = $Matches[2].Trim()
            $current = [pscustomobject]@{
                id = ('M{0:D2}' -f $idx)
                name = (Get-FirstSentence -Text $first)
                full_text = $first
            }
            continue
        }
        # Continuation line for the current milestone (indented or blank-separated prose).
        if ($null -ne $current -and $line -match '\S') {
            $current.full_text = ($current.full_text + ' ' + $line.Trim()).Trim()
        }
    }
    if ($null -ne $current) {
        [void]$milestones.Add($current)
    }
    return ,$milestones.ToArray()
}

function Parse-MilestonesFromPhaseHeadings {
    # Legacy fallback parser. Matches the pre-1.1.0 producer behavior for
    # designs that use `### Phase ...` / `### Contract Freeze Gate ...` /
    # `### Value Review ...` headings.
    param([string]$Text)

    $matches = [regex]::Matches($Text, '(?m)^###\s+(Phase\s+[0-9A-Za-z\- ]+.*|Contract Freeze Gate.*|Value Review.*)$')
    $milestones = New-Object System.Collections.Generic.List[object]
    $idx = 0
    foreach ($m in $matches) {
        $idx++
        $name = $m.Groups[1].Value.Trim()
        [void]$milestones.Add([pscustomobject]@{
            id = ('M{0:D2}' -f $idx)
            name = $name
            full_text = $name
        })
    }
    return ,$milestones.ToArray()
}

function Test-IsRunnableBackticked {
    # Filters backticked content to only entries the shared extractor
    # (scripts/extract-named-artifacts.ps1, which dt-build's gate also uses)
    # would recognize as a runnable command or named file artifact. Keeps
    # the producer from lifting prose backticks like `tag_clusters` or
    # `discovery_active` into procedure cells as if they were commands.
    param([string]$Candidate)
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    if ($Candidate -match '^(pytest|python|pwsh|powershell|node|npm|bun)\b') { return $true }
    if ($Candidate -match '^(?:[A-Za-z0-9_-]+/)+[A-Za-z0-9_.-]+\.(?:py|ts|js|ps1|md|yaml|yml|json|html|sql)$') { return $true }
    return $false
}

function Parse-ValidationGates {
    # Parses the `## Validation Gates` section for milestone-tagged bullets.
    # Convention (documented in SKILL.md):
    #   - M<NN>: <description>. `<command-or-path>` [`<more>` ...]
    # or
    #   - M<NN> - <description>. `<command-or-path>`
    # Backticked content inside each bullet is filtered through
    # Test-IsRunnableBackticked (which mirrors the dt-build extractor's
    # definition) and only runnable entries are collected for that milestone.
    # Returns a hashtable: milestone-id -> array of backticked strings (in
    # source order, deduplicated).
    param([string]$Text)

    $section = Get-SectionBody -Text $Text -Headers @(
        'Validation Gates',
        'Acceptance Tests',
        'Milestone Acceptance Commands'
    )
    $result = @{}
    if ($null -eq $section) { return $result }

    $body = $section.Body
    $currentMid = $null
    $bulletBuffer = ''

    foreach ($rawLine in ($body -split "`r?`n")) {
        $line = $rawLine
        # New top-level bullet starting with a milestone tag.
        # Accept `- M01:`, `- M01 -`, `- [M01]`, `- (M01)`. Plain ASCII only.
        $bulletMatch = [regex]::Match($line, '^\s*[-*]\s+(?:\[)?(?:\()?\s*(M\d+)\s*(?:\])?(?:\))?\s*[:\-]\s*(.+)$')
        if ($bulletMatch.Success) {
            # Flush previous bullet.
            if (-not [string]::IsNullOrWhiteSpace($currentMid) -and -not [string]::IsNullOrWhiteSpace($bulletBuffer)) {
                $backticks = [regex]::Matches($bulletBuffer, '`([^`]+)`')
                if ($backticks.Count -gt 0) {
                    if (-not $result.ContainsKey($currentMid)) {
                        $result[$currentMid] = New-Object System.Collections.Generic.List[string]
                    }
                    foreach ($bm in $backticks) {
                        $val = $bm.Groups[1].Value.Trim()
                        if ($val.Length -gt 0 -and (Test-IsRunnableBackticked -Candidate $val) -and -not $result[$currentMid].Contains($val)) {
                            [void]$result[$currentMid].Add($val)
                        }
                    }
                }
            }
            $currentMid = $bulletMatch.Groups[1].Value.ToUpperInvariant()
            $bulletBuffer = $bulletMatch.Groups[2].Value
            continue
        }
        # Indented continuation (sub-bullet or wrap) belongs to current milestone bullet.
        if ($null -ne $currentMid -and $line -match '^\s+\S') {
            $bulletBuffer = $bulletBuffer + ' ' + $line.Trim()
            continue
        }
        # Blank line or non-tagged top-level bullet: flush + reset.
        if ($line -match '^\s*$' -or $line -match '^\s*[-*]\s+') {
            if (-not [string]::IsNullOrWhiteSpace($currentMid) -and -not [string]::IsNullOrWhiteSpace($bulletBuffer)) {
                $backticks = [regex]::Matches($bulletBuffer, '`([^`]+)`')
                if ($backticks.Count -gt 0) {
                    if (-not $result.ContainsKey($currentMid)) {
                        $result[$currentMid] = New-Object System.Collections.Generic.List[string]
                    }
                    foreach ($bm in $backticks) {
                        $val = $bm.Groups[1].Value.Trim()
                        if ($val.Length -gt 0 -and (Test-IsRunnableBackticked -Candidate $val) -and -not $result[$currentMid].Contains($val)) {
                            [void]$result[$currentMid].Add($val)
                        }
                    }
                }
            }
            $currentMid = $null
            $bulletBuffer = ''
            continue
        }
    }
    # Final flush.
    if (-not [string]::IsNullOrWhiteSpace($currentMid) -and -not [string]::IsNullOrWhiteSpace($bulletBuffer)) {
        $backticks = [regex]::Matches($bulletBuffer, '`([^`]+)`')
        if ($backticks.Count -gt 0) {
            if (-not $result.ContainsKey($currentMid)) {
                $result[$currentMid] = New-Object System.Collections.Generic.List[string]
            }
            foreach ($bm in $backticks) {
                $val = $bm.Groups[1].Value.Trim()
                if ($val.Length -gt 0 -and (Test-IsRunnableBackticked -Candidate $val) -and -not $result[$currentMid].Contains($val)) {
                    [void]$result[$currentMid].Add($val)
                }
            }
        }
    }

    return $result
}

function Format-ProcedureCell {
    # Build a procedure-cell string that always names runnable artifacts when
    # the design supplied any. The shape (backticked commands, separated by
    # `;`) is what dt-build's Extract-NamedArtifacts is designed to read.
    param(
        [string]$MilestoneId,
        [string[]]$Commands
    )
    if ($Commands -and $Commands.Count -gt 0) {
        $quoted = $Commands | ForEach-Object { '`' + $_ + '`' }
        return ('Run ' + ($quoted -join '; ') + ' for ' + $MilestoneId + ' and capture PASS/FAIL evidence.')
    }
    # Stub: no commands found. dt-roadmap's validator will fail with
    # VERIFICATION_NAMES_NO_RUNNABLE so the design author sees the gap.
    return ('Run acceptance checks for ' + $MilestoneId + ' and capture PASS/FAIL evidence.')
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

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

$inputContractMode = 'implementation_sequence'
$milestones = Parse-MilestonesFromImplementationSequence -Text $redacted
if ($milestones.Count -eq 0) {
    $inputContractMode = 'phase_headings_fallback'
    $milestones = Parse-MilestonesFromPhaseHeadings -Text $redacted
}
if ($milestones.Count -eq 0) {
    throw "No milestones derivable from design. Expected either a `## Implementation Sequence` (or equivalent) section with a numbered list, or legacy `### Phase ...` headings. See skills/dt-roadmap/SKILL.md for the input contract."
}

$gatesByMilestone = Parse-ValidationGates -Text $redacted

# Augment each milestone with verification metadata.
$milestonesAugmented = foreach ($m in $milestones) {
    $cmds = if ($gatesByMilestone.ContainsKey($m.id)) { @($gatesByMilestone[$m.id]) } else { @() }
    $verificationMode = if ($m.name -like '*Gate*' -or $m.name -like '*gate*') { 'machine-checkable' } else { 'machine-checkable' }
    [pscustomobject]@{
        id = $m.id
        name = $m.name
        dependencies = if ($m.id -eq 'M01') { '-' } else { ('M{0:D2}' -f ([int]$m.id.Substring(1) - 1)) }
        verification_mode = $verificationMode
        commands = $cmds
    }
}

# Track milestones with no commands so we can surface the gap in the producer
# output (validator will hard-fail VERIFICATION_NAMES_NO_RUNNABLE on these).
$milestonesMissingCommands = @($milestonesAugmented | Where-Object { $_.commands.Count -eq 0 } | ForEach-Object { $_.id })

$chunkRows = New-Object System.Collections.Generic.List[object]
$milestoneRows = New-Object System.Collections.Generic.List[string]
$manifestRows = New-Object System.Collections.Generic.List[string]

foreach ($m in $milestonesAugmented) {
    $slug = ($m.name.ToLowerInvariant() -replace '[^a-z0-9]+', '-') -replace '(^-|-$)', ''
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = ('milestone-{0}' -f $m.id.ToLowerInvariant()) }
    $chunkSlug = "chunk-$slug"

    $chunkRows.Add([pscustomobject]@{
        'chunk-slug' = $chunkSlug
        'milestone-id' = $m.id
        'model-routing' = if ($m.verification_mode -eq 'machine-checkable') { 'codex' } else { 'claude' }
        'reference-pack-entitlement' = 'contracts, glossary'
    })

    $procedureText = Format-ProcedureCell -MilestoneId $m.id -Commands $m.commands
    $acceptanceText = if ($m.commands.Count -gt 0) {
        $procedureText
    } else {
        ('acceptance to be enumerated for {0} in design ## Validation Gates' -f $m.id)
    }

    $milestoneRows.Add("| $($m.id) | $($m.name) | $($m.dependencies) | $chunkSlug | $($m.verification_mode) | baseline-floor-default | $acceptanceText | carry-forward from design-final non-negotiables and approved trade-offs |")

    $manifestRows.Add("| chk-$($m.id.ToLowerInvariant()) | $($m.id) | integration | repo baseline ready | $($m.verification_mode) | $procedureText |")
}

$mermaidMilestoneInput = $milestonesAugmented | ForEach-Object {
    [pscustomobject]@{
        id = $_.id
        name = $_.name
        dependencies = $_.dependencies
        verification_mode = $_.verification_mode
    }
}

$mermaid = New-MermaidRenderPayload -Milestones $mermaidMilestoneInput -TryMcp:(-not $ForceMermaidFallback) -VendoredAssetPath (Join-Path $repoRoot 'assets\visualize\vendored\mermaid-10.9.3.min.js')
$vendoredMermaidPath = Join-Path $repoRoot 'assets\visualize\vendored\mermaid-10.9.3.min.js'

$generatedUtc = (Get-Date).ToUniversalTime().ToString('o')

$chunkRowsMarkdown = ($chunkRows | ForEach-Object { "| $($_.'chunk-slug') | $($_.'milestone-id') | $($_.'model-routing') | $($_.'reference-pack-entitlement') |" }) -join "`n"

$gapNote = if ($milestonesMissingCommands.Count -gt 0) {
    "`n## Producer Warnings`n`nThe following milestones have no runnable command lifted from design ## Validation Gates and will fail dt-roadmap's VERIFICATION_NAMES_NO_RUNNABLE check until the design author adds milestone-tagged backticked commands for them:`n`n- " + ($milestonesMissingCommands -join "`n- ") + "`n"
} else { "" }

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
$chunkRowsMarkdown

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
- input-contract-mode: $inputContractMode
- milestones-derived: $($milestonesAugmented.Count)
- milestones-with-commands: $($milestonesAugmented.Count - $milestonesMissingCommands.Count)
- milestones-missing-commands: $($milestonesMissingCommands.Count)
$gapNote
"@

Set-Content -LiteralPath $RoadmapPath -Value $roadmap -Encoding UTF8

# HTML review artifact
$milestonesForHtml = $milestonesAugmented | ForEach-Object {
    [pscustomobject]@{
        id = $_.id
        name = $_.name
        dependencies = $_.dependencies
        verification_mode = $_.verification_mode
    }
}

function Write-RoadmapReviewHtml {
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][array]$Milestones,
        [Parameter(Mandatory)][object]$Mermaid,
        [Parameter(Mandatory)][string]$RendererAssetPath,
        [Parameter(Mandatory)][string]$GeneratedUtc,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$RoadmapMarkdownPath
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

Write-RoadmapReviewHtml -OutputPath $RoadmapViewPath -Milestones $milestonesForHtml -Mermaid $mermaid -RendererAssetPath $vendoredMermaidPath -GeneratedUtc $generatedUtc -SourcePath $DesignPath -RoadmapMarkdownPath $RoadmapPath

[pscustomobject]@{
    roadmap_path = $RoadmapPath
    roadmap_view_path = $RoadmapViewPath
    milestone_count = $milestonesAugmented.Count
    chunk_count = $chunkRows.Count
    renderer = $mermaid.Renderer
    envelope_sha256 = $envelopeSha
    input_contract_mode = $inputContractMode
    milestones_missing_commands = $milestonesMissingCommands
} | ConvertTo-Json -Depth 5
