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
        "PASS"                { "#1f7a3a" }
        "APPROVED_DOWNGRADE"  { "#b08820" }
        "BLOCKED"             { "#a02020" }
        default               { "#6c757d" }
    }
    return "<span style=`"display:inline-block;padding:2px 8px;border-radius:10px;background:$color;color:white;font-weight:600;font-size:11px;`">$Status</span>"
}

function Parse-ApprovalSection {
    # Parse a Markdown build-decision-log for per-milestone downgrade approvals.
    # Returns a hashtable mapping milestone-id -> @{ approver = '...'; rationale = '...' }.
    # Convention: a milestone's section starts with `## M<NN>` (header). Within
    # that section, a line containing `downgrade_approved_by: <upn>` activates
    # an approval; the next non-blank line(s) until the next blank line form
    # the rationale.
    param([string]$Path)
    $approvals = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $approvals }
    $lines = [System.IO.File]::ReadAllLines($Path)
    $currentMid = $null
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        $headerMatch = [regex]::Match($line, '^##\s+(M\d+)\b', 'IgnoreCase')
        if ($headerMatch.Success) {
            $currentMid = $headerMatch.Groups[1].Value.ToUpperInvariant()
            continue
        }
        if ($currentMid -and $line -match 'downgrade_approved_by\s*:\s*(\S+)') {
            $approver = $Matches[1].Trim()
            # Collect rationale = following non-blank lines until blank.
            # If a captured line starts with `rationale:`, strip that prefix so
            # the ledger doesn't double-label it.
            $rationale = New-Object System.Collections.Generic.List[string]
            for ($j = $i + 1; $j -lt $lines.Length; $j++) {
                if ([string]::IsNullOrWhiteSpace($lines[$j])) { break }
                if ($lines[$j] -match '^##\s+M\d+') { break }
                $cleaned = $lines[$j].Trim()
                $cleaned = [regex]::Replace($cleaned, '^rationale\s*:\s*', '', 'IgnoreCase')
                $rationale.Add($cleaned) | Out-Null
            }
            $approvals[$currentMid] = @{
                approver  = $approver
                rationale = ($rationale -join ' ')
            }
        }
    }
    return $approvals
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

# Read downgrade approvals from the run folder's build-decision-log.md, if any.
$approvals = @{}
if ($RunFolder -and (Test-Path -LiteralPath $RunFolder)) {
    $logPath = Join-Path $RunFolder "build-decision-log.md"
    $approvals = Parse-ApprovalSection -Path $logPath
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
            milestone_id        = $mid
            implemented         = $false
            tested              = $false
            accepted            = $false
            status              = "BLOCKED"
            artifacts_missing   = @()
            blockers            = @("verify-milestone-acceptance.ps1 produced unparseable output: $jsonText")
            downgrade_hits      = @()
            approval            = $null
            verification_checks = @()
        }
        continue
    }
    $key = $mid.ToUpperInvariant()
    $approval = if ($approvals.ContainsKey($key)) { $approvals[$key] } else { $null }
    $status = $verifyResult.status
    $blockers = @($verifyResult.blockers)
    # If the milestone is BLOCKED but the build-decision-log has an explicit
    # downgrade approval for it, flip the status to APPROVED_DOWNGRADE and
    # surface the original blockers as approval annotations instead of failures.
    if ($status -eq "BLOCKED" -and $approval) {
        $status = "APPROVED_DOWNGRADE"
    }
    $verificationChecks = @()
    if ($verifyResult.PSObject.Properties.Name -contains 'verification_checks' -and $verifyResult.verification_checks) {
        $verificationChecks = @($verifyResult.verification_checks)
    }
    $ledgerRows += [pscustomobject]@{
        milestone_id        = $mid
        implemented         = $verifyResult.implemented_hint
        tested              = $verifyResult.tested
        accepted            = ($status -eq "PASS")
        status              = $status
        artifacts_missing   = @($verifyResult.artifacts_missing)
        blockers            = $blockers
        downgrade_hits      = @()
        approval            = $approval
        verification_checks = $verificationChecks
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
            milestone_id        = "<downgrade-scan>"
            implemented         = $false
            tested              = $false
            accepted            = $false
            status              = "BLOCKED"
            artifacts_missing   = @()
            blockers            = @("check-downgrade-language.ps1 produced unparseable output: $downgradeJson")
            downgrade_hits      = @()
            approval            = $null
            verification_checks = @()
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
$mdLines += "| ID | Implemented | Tested | Accepted | Status | Notes |"
$mdLines += "|----|-------------|--------|----------|--------|-------|"
foreach ($r in $ledgerRows) {
    $noteParts = @()
    if ($r.status -eq "APPROVED_DOWNGRADE" -and $r.approval) {
        $noteParts += "approved-by: $($r.approval.approver)"
        if ($r.approval.rationale) {
            $noteParts += "rationale: $($r.approval.rationale)"
        }
        if ($r.blockers.Count -gt 0) {
            $noteParts += "originally-blocked: $(($r.blockers -join '; '))"
        }
    } elseif ($r.blockers.Count -gt 0) {
        $noteParts += ($r.blockers -join " · ")
    } else {
        $noteParts += "-"
    }
    $noteStr = ($noteParts -join " · ")
    $mdLines += "| {0} | {1} | {2} | {3} | {4} | {5} |" -f `
        $r.milestone_id, (Yes-No-Cell $r.implemented), (Yes-No-Cell $r.tested), (Yes-No-Cell $r.accepted), $r.status, $noteStr
}
$mdLines += ""
$totalPass = @($ledgerRows | Where-Object { $_.status -eq "PASS" }).Count
$totalApproved = @($ledgerRows | Where-Object { $_.status -eq "APPROVED_DOWNGRADE" }).Count
$totalBlocked = @($ledgerRows | Where-Object { $_.status -eq "BLOCKED" }).Count
$summaryParts = @("$totalPass PASS")
if ($totalApproved -gt 0) { $summaryParts += "$totalApproved APPROVED_DOWNGRADE" }
$summaryParts += "$totalBlocked BLOCKED"
$mdLines += "**Summary:** $($summaryParts -join ', ') (of $($ledgerRows.Count) total)."
[System.IO.File]::WriteAllText($mdPath, ($mdLines -join "`n"))

# Emit ledger.html
$htmlPath = Join-Path $OutDir "build-acceptance-ledger.html"
$htmlRows = @()
foreach ($r in $ledgerRows) {
    $noteHtml = ""
    if ($r.status -eq "APPROVED_DOWNGRADE" -and $r.approval) {
        $noteHtml += "<div><b>approved-by:</b> $([System.Web.HttpUtility]::HtmlEncode($r.approval.approver))</div>"
        if ($r.approval.rationale) {
            $noteHtml += "<div><b>rationale:</b> $([System.Web.HttpUtility]::HtmlEncode($r.approval.rationale))</div>"
        }
        if ($r.blockers.Count -gt 0) {
            $items = ($r.blockers | ForEach-Object { "<li>$([System.Web.HttpUtility]::HtmlEncode($_))</li>" }) -join ""
            $noteHtml += "<div><b>originally-blocked:</b><ul style='margin:4px 0;padding-left:18px;'>$items</ul></div>"
        }
    } elseif ($r.blockers.Count -gt 0) {
        $items = ($r.blockers | ForEach-Object { "<li>$([System.Web.HttpUtility]::HtmlEncode($_))</li>" }) -join ""
        $noteHtml = "<ul style='margin:0;padding-left:18px;'>$items</ul>"
    } else {
        $noteHtml = "&mdash;"
    }
    $htmlRows += "<tr><td><code>$($r.milestone_id)</code></td><td>$(Yes-No-Cell $r.implemented)</td><td>$(Yes-No-Cell $r.tested)</td><td>$(Yes-No-Cell $r.accepted)</td><td>$(Status-Badge-Html $r.status)</td><td>$noteHtml</td></tr>"
}
Add-Type -AssemblyName System.Web
$summaryHtml = "$totalPass PASS"
if ($totalApproved -gt 0) { $summaryHtml += " &middot; $totalApproved APPROVED_DOWNGRADE" }
$summaryHtml += " &middot; $totalBlocked BLOCKED &middot; of $($ledgerRows.Count) total"

# Per-milestone verification-check detail. One sub-table per milestone whose
# verify-milestone-acceptance.ps1 result exposed verification_checks. Lists
# every CHK-* row for that milestone, its named artifacts (present/missing),
# its named commands, and each command's exit code -- the per-check view the
# rolled-up Notes column in the main ledger flattens.
$detailSections = @()
foreach ($r in $ledgerRows) {
    if (-not $r.verification_checks -or $r.verification_checks.Count -eq 0) { continue }
    $checkRowsHtml = @()
    foreach ($vc in $r.verification_checks) {
        $artHtml = if ($vc.artifacts_named.Count -eq 0) {
            "&mdash;"
        } else {
            $items = @()
            foreach ($a in $vc.artifacts_named) {
                $missing = ($vc.artifacts_missing -contains $a)
                $marker = if ($missing) { " <span style='color:#a02020;font-weight:600;'>(missing)</span>" } else { "" }
                $items += "<li><code>$([System.Web.HttpUtility]::HtmlEncode($a))</code>$marker</li>"
            }
            "<ul style='margin:0;padding-left:18px;'>$($items -join '')</ul>"
        }
        $cmdHtml = if ($vc.commands_named.Count -eq 0) {
            "&mdash;"
        } else {
            $items = @()
            foreach ($c in $vc.commands_named) {
                $exitText = ""
                $exitColor = "#666"
                $cr = $vc.command_results | Where-Object { $_.command -eq $c } | Select-Object -First 1
                if ($cr) {
                    $exitText = "[exit=$($cr.exit_code)] "
                    $exitColor = if ($cr.exit_code -eq 0) { "#1f7a3a" } else { "#a02020" }
                } elseif ($vc.test_status -eq "NOT_RUN") {
                    $exitText = "[not run] "
                }
                $items += "<li><span style='color:$exitColor;font-weight:600;'>$exitText</span><code>$([System.Web.HttpUtility]::HtmlEncode($c))</code></li>"
            }
            "<ul style='margin:0;padding-left:18px;'>$($items -join '')</ul>"
        }
        $statusBadge = switch ($vc.test_status) {
            "PASS"             { Status-Badge-Html "PASS" }
            "FAIL"             { Status-Badge-Html "BLOCKED" }
            "NO_COMMAND_NAMED" { "<span style='display:inline-block;padding:2px 8px;border-radius:10px;background:#6c757d;color:white;font-weight:600;font-size:11px;'>NO_COMMAND</span>" }
            default            { "<span style='display:inline-block;padding:2px 8px;border-radius:10px;background:#6c757d;color:white;font-weight:600;font-size:11px;'>NOT_RUN</span>" }
        }
        $checkRowsHtml += "<tr><td><code>$([System.Web.HttpUtility]::HtmlEncode($vc.check_id))</code></td><td>$statusBadge</td><td>$artHtml</td><td>$cmdHtml</td></tr>"
    }
    if ($checkRowsHtml.Count -eq 0) { continue }
    $detailSections += @"
<h3 style="margin-top:24px;margin-bottom:6px;font-size:14px;">Milestone <code>$($r.milestone_id)</code> &mdash; verification checks</h3>
<table>
<thead><tr><th>Check</th><th>Status</th><th>Named artifacts</th><th>Named commands</th></tr></thead>
<tbody>
$($checkRowsHtml -join "`n")
</tbody></table>
"@
}
$detailHtml = if ($detailSections.Count -gt 0) {
    @"
<h2 style="margin-top:32px;font-size:16px;">Verification Check Detail</h2>
$($detailSections -join "`n")
"@
} else { "" }

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
<thead><tr><th>ID</th><th>Implemented</th><th>Tested</th><th>Accepted</th><th>Status</th><th>Notes</th></tr></thead>
<tbody>
$($htmlRows -join "`n")
</tbody></table>
<div class="summary">$summaryHtml</div>
$detailHtml
</body></html>
"@
[System.IO.File]::WriteAllText($htmlPath, $html)

Write-Output ("Ledger written:")
Write-Output ("  {0}" -f $mdPath)
Write-Output ("  {0}" -f $htmlPath)
$summaryStr = "{0} PASS" -f $totalPass
if ($totalApproved -gt 0) { $summaryStr += ", {0} APPROVED_DOWNGRADE" -f $totalApproved }
$summaryStr += ", {0} BLOCKED of {1} total." -f $totalBlocked, $ledgerRows.Count
Write-Output ("Summary: " + $summaryStr)

if ($totalBlocked -gt 0) { exit 1 } else { exit 0 }
