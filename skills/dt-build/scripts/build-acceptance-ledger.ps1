param(
    [Parameter(Mandatory)][string]$RoadmapPath,
    [Parameter(Mandatory)][string]$WorkingTree,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$RunFolder = "",
    [switch]$RunTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# build-acceptance-ledger.ps1
# ---------------------------
# Aggregates per-milestone acceptance verification into the final ledger
# (build-acceptance-ledger.md + build-acceptance-ledger.html). One row per
# milestone with the four-axis split (implemented / tested / accepted / status)
# plus blockers and any downgrade-language matches found in the run folder.
#
# Inputs:
#   -RoadmapPath  Roadmap contract that dt-build executed against.
#   -WorkingTree  Built repo (used by verify-milestone-acceptance.ps1 for
#                 artifact presence checks and command execution).
#   -OutDir       Folder to write build-acceptance-ledger.{md,html} into.
#   -RunFolder    Optional .dt-build/<RUN_ID>/ folder; if provided, the
#                 downgrade scanner runs across every .md/.log/.jsonl in it
#                 and the ledger surfaces per-milestone phrase matches.
#   -RunTests     Forwarded to verify-milestone-acceptance.ps1.
#
# Exit codes:
#   0 -- every milestone PASS (or downgrades approved)
#   1 -- one or more milestones BLOCKED
#   2 -- usage/contract error

function Resolve-SkillScripts {
    $scriptDir = Split-Path -Parent $PSCommandPath
    return $scriptDir
}

function Read-RoadmapText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "ROADMAP_NOT_FOUND: $Path" }
    return [System.IO.File]::ReadAllText($Path)
}

function Get-SectionText {
    param([string]$RoadmapText, [string]$Header)
    $pattern = '(?ms)^##\s+' + [regex]::Escape($Header) + '\s*\n(.*?)(?=^##\s|\z)'
    $m = [regex]::Match($RoadmapText, $pattern)
    if (-not $m.Success) { throw "ROADMAP_SECTION_MISSING: ## $Header" }
    return $m.Groups[1].Value
}

function Parse-MilestoneIds {
    param([string]$RoadmapText)
    $section = Get-SectionText -RoadmapText $RoadmapText -Header "Milestones"
    $lines = $section -split "(`r`n|`n)" | Where-Object { $_ -match '^\|' }
    if ($lines.Count -lt 2) { return @() }
    $ids = @()
    for ($i = 2; $i -lt $lines.Count; $i++) {
        $cells = ($lines[$i] -split '\|') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($cells.Count -lt 1) { continue }
        $ids += $cells[0]
    }
    return @($ids)
}

function Status-Badge-Html {
    param([string]$Status)
    $color = switch ($Status) {
        "PASS"    { "#1f7a3a" }
        "BLOCKED" { "#a02020" }
        default   { "#6c757d" }
    }
    return "<span style=`"display:inline-block;padding:2px 8px;border-radius:10px;background:$color;color:white;font-weight:600;font-size:11px;`">$Status</span>"
}

function Yes-No-Cell {
    param([bool]$Value)
    if ($Value) { return "YES" } else { return "NO" }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$scriptsDir = Resolve-SkillScripts
$verifyScript = Join-Path $scriptsDir "verify-milestone-acceptance.ps1"
$downgradeScript = Join-Path $scriptsDir "check-downgrade-language.ps1"

if (-not (Test-Path -LiteralPath $verifyScript)) {
    Write-Error "MISSING_HELPER: $verifyScript"
    exit 2
}

$roadmapText = Read-RoadmapText -Path $RoadmapPath
$milestoneIds = Parse-MilestoneIds -RoadmapText $roadmapText

if ($milestoneIds.Count -eq 0) {
    Write-Error "ROADMAP_HAS_NO_MILESTONES: $RoadmapPath"
    exit 2
}

# Per-milestone verification.
$ledgerRows = @()
foreach ($mid in $milestoneIds) {
    $args = @(
        "-File", $verifyScript,
        "-RoadmapPath", $RoadmapPath,
        "-MilestoneId", $mid,
        "-WorkingTree", $WorkingTree,
        "-Json"
    )
    if ($RunTests) { $args += "-RunTests" }

    $jsonText = & pwsh -NoProfile @args 2>&1
    $verifyExit = $LASTEXITCODE
    # If the script wrote a usage error to stderr it still exits nonzero; capture
    # whatever it produced and best-effort parse JSON. Skip rows that fail to parse.
    try {
        $verifyResult = $jsonText | ConvertFrom-Json
    } catch {
        $ledgerRows += [pscustomobject]@{
            milestone_id     = $mid
            implemented      = $false
            tested           = $false
            accepted         = $false
            status           = "BLOCKED"
            artifacts_missing = @()
            blockers         = @("verify-milestone-acceptance.ps1 produced unparseable output: $jsonText")
            downgrade_hits   = @()
        }
        continue
    }
    $ledgerRows += [pscustomobject]@{
        milestone_id      = $mid
        implemented       = $verifyResult.implemented_hint
        tested            = $verifyResult.tested
        accepted          = $verifyResult.accepted
        status            = $verifyResult.status
        artifacts_missing = @($verifyResult.artifacts_missing)
        blockers          = @($verifyResult.blockers)
        downgrade_hits    = @()
    }
}

# Optional downgrade scan across the run folder. Match phrase lines to milestones
# by looking for "M01"/"m01" tokens on the same line.
if ($RunFolder -and (Test-Path -LiteralPath $RunFolder)) {
    $args = @(
        "-File", $downgradeScript,
        "-Path", $RunFolder,
        "-Recurse",
        "-Json"
    )
    $downgradeJson = & pwsh -NoProfile @args 2>&1
    try {
        $downgradeResult = $downgradeJson | ConvertFrom-Json
        foreach ($m in $downgradeResult.matches) {
            $hitLine = $m.line
            foreach ($row in $ledgerRows) {
                if ($hitLine -match "\b$([regex]::Escape($row.milestone_id))\b") {
                    $row.downgrade_hits += $m
                    if (-not $m.approved) {
                        $row.blockers += "downgrade language '$($m.phrase)' at $($m.source):$($m.line_number)"
                        if ($row.status -eq "PASS") {
                            $row.status = "BLOCKED"
                            $row.accepted = $false
                        }
                    }
                }
            }
        }
    } catch {
        # Surface as a global blocker row.
        $ledgerRows += [pscustomobject]@{
            milestone_id      = "<downgrade-scan>"
            implemented       = $false
            tested            = $false
            accepted          = $false
            status            = "BLOCKED"
            artifacts_missing = @()
            blockers          = @("check-downgrade-language.ps1 produced unparseable output: $downgradeJson")
            downgrade_hits    = @()
        }
    }
}

# Emit ledger.md
$mdPath = Join-Path $OutDir "build-acceptance-ledger.md"
$mdLines = @()
$mdLines += "# Build Acceptance Ledger"
$mdLines += ""
$mdLines += "Generated: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')"
$mdLines += "Roadmap: $RoadmapPath"
$mdLines += "Working tree: $WorkingTree"
if ($RunFolder) { $mdLines += "Run folder: $RunFolder" }
$mdLines += ""
$mdLines += "| ID | Implemented | Tested | Accepted | Status | Blockers |"
$mdLines += "|----|-------------|--------|----------|--------|----------|"
foreach ($r in $ledgerRows) {
    $blockerStr = if ($r.blockers.Count -gt 0) { ($r.blockers -join " · ") } else { "-" }
    $mdLines += "| {0} | {1} | {2} | {3} | {4} | {5} |" -f `
        $r.milestone_id, (Yes-No-Cell $r.implemented), (Yes-No-Cell $r.tested), (Yes-No-Cell $r.accepted), $r.status, $blockerStr
}
$mdLines += ""
$totalPass = @($ledgerRows | Where-Object { $_.status -eq "PASS" }).Count
$totalBlocked = @($ledgerRows | Where-Object { $_.status -eq "BLOCKED" }).Count
$mdLines += "**Summary:** $totalPass PASS, $totalBlocked BLOCKED (of $($ledgerRows.Count) total)."
[System.IO.File]::WriteAllText($mdPath, ($mdLines -join "`n"))

# Emit ledger.html
$htmlPath = Join-Path $OutDir "build-acceptance-ledger.html"
$htmlRows = @()
foreach ($r in $ledgerRows) {
    $blockerHtml = if ($r.blockers.Count -gt 0) { ($r.blockers | ForEach-Object { "<li>$($_)</li>" }) -join "" } else { "" }
    $blockerCell = if ($blockerHtml) { "<ul style='margin:0;padding-left:18px;'>$blockerHtml</ul>" } else { "&mdash;" }
    $htmlRows += "<tr><td><code>$($r.milestone_id)</code></td><td>$(Yes-No-Cell $r.implemented)</td><td>$(Yes-No-Cell $r.tested)</td><td>$(Yes-No-Cell $r.accepted)</td><td>$(Status-Badge-Html $r.status)</td><td>$blockerCell</td></tr>"
}
$html = @"
<!doctype html>
<html><head><meta charset="utf-8"><title>Build Acceptance Ledger</title>
<style>
  body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:1100px;margin:24px auto;padding:0 16px;color:#222;}
  h1{font-size:20px;margin-bottom:4px;}
  .meta{color:#666;font-size:12px;margin-bottom:16px;}
  table{width:100%;border-collapse:collapse;font-size:13px;}
  th,td{padding:8px 10px;border-bottom:1px solid #e0e0e0;text-align:left;vertical-align:top;}
  th{background:#f5f5f5;font-weight:600;}
  tr:hover{background:#fafafa;}
  code{font-family:'Cascadia Code',Consolas,monospace;}
  .summary{margin-top:16px;font-weight:600;}
</style></head><body>
<h1>Build Acceptance Ledger</h1>
<div class="meta">
  Generated $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')<br>
  Roadmap: <code>$RoadmapPath</code><br>
  Working tree: <code>$WorkingTree</code>$(if ($RunFolder) {"<br>Run folder: <code>$RunFolder</code>"})
</div>
<table>
<thead><tr><th>ID</th><th>Implemented</th><th>Tested</th><th>Accepted</th><th>Status</th><th>Blockers</th></tr></thead>
<tbody>
$($htmlRows -join "`n")
</tbody></table>
<div class="summary">$totalPass PASS &middot; $totalBlocked BLOCKED &middot; of $($ledgerRows.Count) total</div>
</body></html>
"@
[System.IO.File]::WriteAllText($htmlPath, $html)

Write-Output ("Ledger written:")
Write-Output ("  {0}" -f $mdPath)
Write-Output ("  {0}" -f $htmlPath)
Write-Output ("Summary: {0} PASS, {1} BLOCKED of {2} total." -f $totalPass, $totalBlocked, $ledgerRows.Count)

if ($totalBlocked -gt 0) { exit 1 } else { exit 0 }
