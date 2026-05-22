# html-builder.ps1
# Shared HTML artifact assembler used by dt-visualize-plan and dt-visualize-design.

param(
    [Parameter(Mandatory)]
    [string]$PlanPath,

    [string]$OutputPath = "",

    [ValidateSet("milestone-table-only", "plan-plus-mermaid", "ui-mockup")]
    [string]$Mode = "milestone-table-only",

    [switch]$ForceMermaidFallback,

    [ValidateSet("frontend-design", "web-artifacts-builder", "manual-single-variant")]
    [string]$UiMockupProvider = "web-artifacts-builder",

    [string]$UiMockupPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Plan file not found: $PlanPath"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)

$templatePath = Join-Path $repoRoot "assets\visualize\template.html"
$tokensPath = Join-Path $repoRoot "assets\visualize\tokens.css"
$vendoredMermaidPath = Join-Path $repoRoot "assets\visualize\vendored\mermaid-10.9.3.min.js"

if (-not (Test-Path -LiteralPath $templatePath)) { throw "Template not found: $templatePath" }
if (-not (Test-Path -LiteralPath $tokensPath)) { throw "Tokens CSS not found: $tokensPath" }
if (-not (Test-Path -LiteralPath $vendoredMermaidPath)) { throw "Vendored mermaid asset not found: $vendoredMermaidPath" }

. (Join-Path $repoRoot "scripts\security\redact-secrets.ps1")
. (Join-Path $scriptDir "mermaid-wrap.ps1")

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Split-Path -Parent $PlanPath) "plan-view.html"
}

function Escape-Html {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Convert-MarkdownSubsetToHtml {
    param([string]$Text)

    $lines = $Text -split "`r?`n"
    $chunks = New-Object System.Collections.Generic.List[string]
    $inList = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*-\s+(.+)$') {
            if (-not $inList) {
                $chunks.Add("<ul>")
                $inList = $true
            }
            $chunks.Add("<li>{0}</li>" -f (Escape-Html $Matches[1]))
            continue
        }

        if ($inList) {
            $chunks.Add("</ul>")
            $inList = $false
        }

        if ($line -match '^###\s+(.+)$') {
            $chunks.Add("<h3>{0}</h3>" -f (Escape-Html $Matches[1]))
            continue
        }
        if ($line -match '^##\s+(.+)$') {
            $chunks.Add("<h2>{0}</h2>" -f (Escape-Html $Matches[1]))
            continue
        }
        if ($line -match '^#\s+(.+)$') {
            $chunks.Add("<h1>{0}</h1>" -f (Escape-Html $Matches[1]))
            continue
        }
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $chunks.Add("<p>{0}</p>" -f (Escape-Html $line))
    }

    if ($inList) {
        $chunks.Add("</ul>")
    }

    return ($chunks -join "`n")
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
    param(
        [string]$Text,
        [string]$Heading
    )
    $escaped = [regex]::Escape($Heading)
    $pattern = "(?ms)^##\s+$escaped\s*\r?\n(.*?)(?=^##\s+|\z)"
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }
    return ""
}

$raw = Get-Content -LiteralPath $PlanPath -Raw
$redacted = Invoke-SecretRedaction -Text $raw

$title = if ($redacted -match '(?m)^#\s+(.+)$') { $Matches[1].Trim() } else { [System.IO.Path]::GetFileNameWithoutExtension($PlanPath) }
$date = if ($redacted -match '(?m)^\*\*Date:\*\*\s*(.+)$') { $Matches[1].Trim() } else { "n/a" }
$surface = if ($redacted -match '(?m)^\*\*Surface:\*\*\s*(.+)$') { $Matches[1].Trim() } else { "n/a" }
$scope = if ($redacted -match '(?m)^\*\*Scope:\*\*\s*(.+)$') { $Matches[1].Trim() } else { "n/a" }

$milestones = @()
$phaseMatches = [regex]::Matches($redacted, '(?m)^###\s+(Phase\s+[0-9A-Za-z\- ]+.*|Contract Freeze Gate.*|Value Review.*)$')
if ($phaseMatches.Count -gt 0) {
    $idx = 0
    foreach ($m in $phaseMatches) {
        $idx++
        $milestones += [pscustomobject]@{
            id        = "M{0:D2}" -f $idx
            name      = $m.Groups[1].Value.Trim()
            dependsOn = if ($idx -gt 1) { "M{0:D2}" -f ($idx - 1) } else { "-" }
        }
    }
}
else {
    $sectionMatches = [regex]::Matches($redacted, '(?m)^##\s+(.+)$')
    $idx = 0
    foreach ($m in $sectionMatches) {
        $name = $m.Groups[1].Value.Trim()
        if ($name -in @("Open Questions", "Out of Scope", "Plan Amendments", "Dialogue Log")) { continue }
        $idx++
        $milestones += [pscustomobject]@{
            id        = "M{0:D2}" -f $idx
            name      = $name
            dependsOn = if ($idx -gt 1) { "M{0:D2}" -f ($idx - 1) } else { "-" }
        }
    }
}

if ($milestones.Count -eq 0) {
    $milestones += [pscustomobject]@{
        id        = "M01"
        name      = "Plan imported"
        dependsOn = "-"
    }
}

$milestoneRows = foreach ($m in $milestones) {
    "<tr><td>{0}</td><td>{1}</td><td>{2}</td></tr>" -f (Escape-Html $m.id), (Escape-Html $m.name), (Escape-Html $m.dependsOn)
}
$milestoneTable = @"
<table class="milestone-table">
  <thead>
    <tr><th>ID</th><th>Milestone</th><th>Depends On</th></tr>
  </thead>
  <tbody>
    $($milestoneRows -join "`n    ")
  </tbody>
</table>
"@

$openQuestions = Get-SectionBody -Text $redacted -Heading "Open Questions"
$openQuestionsHtml = if ([string]::IsNullOrWhiteSpace($openQuestions)) {
    "<p class=""muted"">No explicit Open Questions section found.</p>"
}
else {
    Convert-MarkdownSubsetToHtml -Text $openQuestions
}

$dependencyProvenance = New-Object System.Collections.Generic.List[string]
$mermaidBlocks = ""
$mermaidScript = ""
$mermaidMode = "disabled"

if ($Mode -ne "milestone-table-only") {
    $payload = New-MermaidRenderPayload -Milestones $milestones -TryMcp:(-not $ForceMermaidFallback) -VendoredAssetPath $vendoredMermaidPath
    $mermaidMode = $payload.Renderer
    foreach ($line in $payload.Provenance) {
        $dependencyProvenance.Add($line)
    }

    $graphDefinition = Escape-Html $payload.GraphDefinition
    $ganttDefinition = Escape-Html $payload.GanttDefinition
    $mermaidBlocks = @"
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
"@

    $assetRel = Get-RelativePath -FromDirectory (Split-Path -Parent $OutputPath) -ToPath $vendoredMermaidPath
    $mermaidScript = @"
<script src="$assetRel"></script>
<script>
if (window.mermaid) {
  window.mermaid.initialize({ startOnLoad: true, securityLevel: 'strict' });
}
</script>
"@
}
else {
    $dependencyProvenance.Add("Renderer: none (milestone-table-only mode)")
}

$uiMockupHtml = "<p class=""muted"">UI mockup mode not selected.</p>"
if ($Mode -eq "ui-mockup") {
    if (-not [string]::IsNullOrWhiteSpace($UiMockupPath) -and (Test-Path -LiteralPath $UiMockupPath)) {
        $uiRaw = Get-Content -LiteralPath $UiMockupPath -Raw
        $uiRedacted = Invoke-SecretRedaction -Text $uiRaw
        $uiMockupHtml = "<pre class=""code-block"">" + (Escape-Html $uiRedacted) + "</pre>"
    }
    else {
        $uiMockupHtml = "<p class=""muted"">No UI mockup artifact provided yet. Fallback can proceed with manual single-variant HTML.</p>"
    }

    switch ($UiMockupProvider) {
        "frontend-design" {
            $dependencyProvenance.Add("UI provider: frontend-design:frontend-design")
        }
        "web-artifacts-builder" {
            $dependencyProvenance.Add("UI provider: anthropic-skills:web-artifacts-builder")
            $dependencyProvenance.Add("Debt: regenerate polished mockup when frontend-design is reachable")
        }
        "manual-single-variant" {
            $dependencyProvenance.Add("UI provider fallback: manual single-variant SVG/HTML")
            $dependencyProvenance.Add("Debt: regenerate three-variant sketches when web-artifacts-builder is reachable")
        }
    }
}

$summaryCards = @"
<article class="summary-card"><span class="label">Surface</span><span class="value">$(Escape-Html $surface)</span></article>
<article class="summary-card"><span class="label">Scope</span><span class="value">$(Escape-Html $scope)</span></article>
<article class="summary-card"><span class="label">Mode</span><span class="value">$(Escape-Html $Mode)</span></article>
<article class="summary-card"><span class="label">Mermaid renderer</span><span class="value">$(Escape-Html $mermaidMode)</span></article>
"@

$fullPlanHtml = "<pre class=""code-block"">" + (Escape-Html $redacted) + "</pre>"
$template = Get-Content -LiteralPath $templatePath -Raw
$tokens = Get-Content -LiteralPath $tokensPath -Raw

$provenanceLines = $dependencyProvenance | Select-Object -Unique | ForEach-Object { "<li>{0}</li>" -f (Escape-Html $_) }
$provenanceHtml = "<ul>" + ($provenanceLines -join "") + "</ul>"

$rendered = $template
$rendered = $rendered.Replace("{{TITLE}}", (Escape-Html $title))
$rendered = $rendered.Replace("{{DATE}}", (Escape-Html $date))
$rendered = $rendered.Replace("{{TOKENS_CSS}}", $tokens)
$rendered = $rendered.Replace("{{SUMMARY_CARDS}}", $summaryCards)
$rendered = $rendered.Replace("{{MILESTONE_TABLE}}", $milestoneTable)
$rendered = $rendered.Replace("{{OPEN_QUESTIONS}}", $openQuestionsHtml)
$rendered = $rendered.Replace("{{MERMAID_BLOCKS}}", $mermaidBlocks)
$rendered = $rendered.Replace("{{UI_MOCKUP}}", $uiMockupHtml)
$rendered = $rendered.Replace("{{PLAN_PREVIEW}}", $fullPlanHtml)
$rendered = $rendered.Replace("{{DEPENDENCY_PROVENANCE}}", $provenanceHtml)
$rendered = $rendered.Replace("{{MERMAID_SCRIPT}}", $mermaidScript)

$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

Set-Content -LiteralPath $OutputPath -Value $rendered -Encoding UTF8
Write-Host "Wrote: $OutputPath"
