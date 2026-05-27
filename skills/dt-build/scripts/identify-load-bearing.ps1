param(
    [Parameter(Mandatory)][string]$RoadmapPath,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# identify-load-bearing.ps1
# -------------------------
# Parses roadmap.md and flags milestones whose name, acceptance-checks text, or
# verification-check procedure text contains any of the load-bearing trigger
# phrases. dt-build uses the output to bump these milestones to the front of
# their DAG layer, so the load-bearing E2E is in place before non-load-bearing
# dependents start.
#
# Exit codes:
#   0 -- parsed successfully (even if no load-bearing milestones found)
#   2 -- usage/contract error (roadmap unparseable)

$Triggers = @(
    'load-bearing',
    'load bearing',
    'runtime flip',
    'end-to-end',
    'e2e',
    'critical path',
    'persistence',
    'persists',
    'publish gate',
    'ship gate',
    'final gate',
    'enforcement gate',
    ' gate '
)

# Word-boundary triggers (matched against tokenized text, not substring).
$WordTriggers = @('gate', 'publish')

function Read-RoadmapText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "ROADMAP_NOT_FOUND: $Path"
    }
    return [System.IO.File]::ReadAllText($Path)
}

function Get-SectionText {
    param([string]$RoadmapText, [string]$Header)
    $pattern = '(?ms)^##\s+' + [regex]::Escape($Header) + '\s*\n(.*?)(?=^##\s|\z)'
    $m = [regex]::Match($RoadmapText, $pattern)
    if (-not $m.Success) {
        throw "ROADMAP_SECTION_MISSING: ## $Header"
    }
    return $m.Groups[1].Value
}

function Parse-MarkdownTableRows {
    param([string]$SectionText)
    $lines = $SectionText -split "(`r`n|`n)" | Where-Object { $_ -match '^\|' }
    if ($lines.Count -lt 2) { return @() }
    $headerCells = ($lines[0] -split '\|') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $rows = @()
    for ($i = 2; $i -lt $lines.Count; $i++) {
        $cells = ($lines[$i] -split '\|') | ForEach-Object { $_.Trim() }
        $cells = @($cells | Where-Object { $_ -ne '' })
        if ($cells.Count -eq 0) { continue }
        if ($cells.Count -lt $headerCells.Count) { continue }
        $row = [ordered]@{}
        for ($c = 0; $c -lt $headerCells.Count; $c++) {
            $row[$headerCells[$c]] = $cells[$c]
        }
        $rows += [pscustomobject]$row
    }
    return $rows
}

function Find-Triggers {
    param([string]$Text)
    $lower = $Text.ToLowerInvariant()
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($t in $Triggers) {
        if ($lower.Contains($t.ToLowerInvariant())) {
            $hits.Add($t) | Out-Null
        }
    }
    foreach ($w in $WordTriggers) {
        if ($lower -match "\b$([regex]::Escape($w.ToLowerInvariant()))\b") {
            if (-not ($hits -contains $w)) { $hits.Add($w) | Out-Null }
        }
    }
    return @($hits)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$roadmapText = Read-RoadmapText -Path $RoadmapPath

try {
    $milestonesSection = Get-SectionText -RoadmapText $roadmapText -Header "Milestones"
    $verificationSection = Get-SectionText -RoadmapText $roadmapText -Header "Verification Manifest"
} catch {
    Write-Error $_.Exception.Message
    exit 2
}

$milestonesRows = Parse-MarkdownTableRows -SectionText $milestonesSection
$verificationRows = Parse-MarkdownTableRows -SectionText $verificationSection

$verificationByMid = @{}
foreach ($v in $verificationRows) {
    $mid = [string]$v.'milestone-id'
    $verificationByMid[$mid.ToUpperInvariant().Trim()] = $v
}

$loadBearing = New-Object System.Collections.Generic.List[string]
$evidence = [ordered]@{}

foreach ($m in $milestonesRows) {
    $mid = [string]$m.id
    $key = $mid.ToUpperInvariant().Trim()
    $name = [string]$m.name
    $acceptance = [string]$m.'acceptance-checks'
    $verification = ""
    if ($verificationByMid.ContainsKey($key)) {
        $verification = [string]$verificationByMid[$key].procedure
    }
    $combined = "$name`n$acceptance`n$verification"
    $hits = @(Find-Triggers -Text $combined)
    if ($hits.Count -gt 0) {
        $loadBearing.Add($key) | Out-Null
        $tail = if ($acceptance.Length -gt 140) { "..." } else { "" }
        $evidence[$key] = [pscustomobject]@{
            name               = $name
            triggers           = $hits
            acceptance_excerpt = ($acceptance.Substring(0, [Math]::Min(140, $acceptance.Length)) + $tail)
        }
    }
}

$milestoneTotal = if ($null -ne $milestonesRows) { @($milestonesRows).Count } else { 0 }

$result = [pscustomobject]@{
    load_bearing_milestones = @($loadBearing)
    evidence                = $evidence
    total_milestones        = $milestoneTotal
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
}
else {
    if ($loadBearing.Count -eq 0) {
        Write-Output ("No load-bearing milestones detected (matched 0 of {0})." -f $milestoneTotal)
    } else {
        Write-Output ("Load-bearing milestones ({0} of {1}):" -f $loadBearing.Count, $milestoneTotal)
        foreach ($mid in $loadBearing) {
            $e = $evidence[$mid]
            Write-Output ("  {0}: {1}" -f $mid, $e.name)
            Write-Output ("    triggers: {0}" -f ($e.triggers -join ", "))
        }
    }
}

exit 0
