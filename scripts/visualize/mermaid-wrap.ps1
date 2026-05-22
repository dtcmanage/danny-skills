# mermaid-wrap.ps1
# Shared mermaid payload builder for visualize skills.
# Builds deterministic graph + gantt definitions and returns renderer provenance.

Set-StrictMode -Version Latest

function New-MermaidRenderPayload {
    param(
        [Parameter(Mandatory)]
        [array]$Milestones,

        [switch]$TryMcp,

        [Parameter(Mandatory)]
        [string]$VendoredAssetPath,

        [string]$PinnedVersion = "10.9.3"
    )

    if (-not (Test-Path -LiteralPath $VendoredAssetPath)) {
        throw "Vendored mermaid asset not found: $VendoredAssetPath"
    }

    $sanitized = @()
    $i = 0
    foreach ($m in $Milestones) {
        $i++
        $name = [string]$m.name
        $name = $name.Replace('"', "'").Replace("[", "(").Replace("]", ")")
        $id = if ($m.id) { [string]$m.id } else { "M{0:D2}" -f $i }
        $sanitized += [pscustomobject]@{
            id   = $id
            name = $name
        }
    }

    if ($sanitized.Count -eq 0) {
        $sanitized += [pscustomobject]@{
            id   = "M01"
            name = "Plan imported"
        }
    }

    $graphLines = @("graph TD")
    for ($idx = 0; $idx -lt $sanitized.Count; $idx++) {
        $node = $sanitized[$idx]
        $graphLines += ("  {0}[`"{1}`"]" -f $node.id, $node.name)
        if ($idx -gt 0) {
            $prev = $sanitized[$idx - 1]
            $graphLines += ("  {0} --> {1}" -f $prev.id, $node.id)
        }
    }
    $graphDefinition = $graphLines -join "`n"

    $ganttLines = @(
        "gantt",
        "  title Phase Timeline",
        "  dateFormat  YYYY-MM-DD",
        "  axisFormat  %m/%d",
        "  section Buildout"
    )
    $start = Get-Date -Date "2026-01-01"
    for ($idx = 0; $idx -lt $sanitized.Count; $idx++) {
        $node = $sanitized[$idx]
        $date = $start.AddDays($idx).ToString("yyyy-MM-dd")
        $task = ("  {0} :{1}, {2}, 1d" -f $node.name, $node.id.ToLowerInvariant(), $date)
        $ganttLines += $task
    }
    $ganttDefinition = $ganttLines -join "`n"

    $hash = (Get-FileHash -LiteralPath $VendoredAssetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $assetName = Split-Path -Leaf $VendoredAssetPath

    $renderer = "vendored"
    $fallbackUsed = $false
    $provenance = @()
    $debtTags = @()

    if ($TryMcp -and $env:DANNY_SKILLS_MERMAID_MCP_READY -eq "1") {
        $renderer = "mcp"
        $provenance += "Renderer: Mermaid MCP (primary)"
        $provenance += "Fallback available: $assetName (v$PinnedVersion, sha256:$hash)"
    }
    else {
        if ($TryMcp) {
            $fallbackUsed = $true
        }
        $provenance += "Renderer: vendored mermaid.js fallback"
        $provenance += "Asset: $assetName (v$PinnedVersion, sha256:$hash)"
        $provenance += "Debt: no debt -- vendored is canonical"
    }

    return [pscustomobject]@{
        GraphDefinition = $graphDefinition
        GanttDefinition = $ganttDefinition
        Renderer        = $renderer
        FallbackUsed    = $fallbackUsed
        Provenance      = $provenance
        DebtTags        = $debtTags
        AssetFileName   = $assetName
        AssetSha256     = $hash
        AssetVersion    = $PinnedVersion
    }
}

