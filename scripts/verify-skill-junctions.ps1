# verify-skill-junctions.ps1
# Skill junction propagation gate (Windows-only).
#
# Reconciles the danny-skills repo's skills/<name>/ folders against the four
# external surfaces that load skills via per-skill directory junctions:
#   1. $CODEX_HOME\skills\          (Codex CLI; defaults to C:\Users\<u>\.codex\skills)
#   2. ~\.agents\skills\            (Claude Code CLI / Agent SDK)
#   3. D:\Claude\skills\            (CLI mirror)
#   4. D:\Claude\_Claude-Workspace\.claude\skills\   (CLI mirror)
#
# Behavior:
#   - For each skill folder in <repo>\skills\ (or the -NewSkills subset), verify
#     a directory junction in each location points at the canonical repo target.
#   - With -Create, materialize missing junctions. Without it, report only.
#   - Never create parent target directories: a missing parent is a setup gap
#     that the operator must resolve manually.
#   - Orphan junctions (a junction whose target's leaf folder no longer exists
#     under <repo>\skills\) are reported but never auto-removed.
#   - Anthropic-provided skill names listed in -IgnoreSkills are skipped (default
#     `find-skills`), so unrelated junctions in the target locations don't trip
#     the gate.
#
# Exit codes:
#   0  pass: every (skill x location) pair ended in `ok` and no orphans/gaps
#   1  fail: any wrong_target, missing-and-not-created, setup_gap, orphan, or
#            create_failed result
#
# Usage:
#   pwsh scripts\verify-skill-junctions.ps1                       # report only, all skills
#   pwsh scripts\verify-skill-junctions.ps1 -Create               # create missing junctions
#   pwsh scripts\verify-skill-junctions.ps1 -NewSkills dt-foo -Create -Json
#   pwsh scripts\verify-skill-junctions.ps1 -RepoRoot D:\path\to\danny-skills -Json

param(
    [string]$RepoRoot,
    [string[]]$NewSkills,
    [switch]$Create,
    [switch]$Json,
    [string[]]$IgnoreSkills = @('find-skills')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- Resolve repo root -------------------------------------------------------
if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
else {
    $RepoRoot = (Resolve-Path $RepoRoot).Path
}

$skillsRoot = Join-Path $RepoRoot 'skills'
if (-not (Test-Path -LiteralPath $skillsRoot -PathType Container)) {
    throw "JUNCTION_GATE_FAIL: skills root not found under repo: $skillsRoot"
}

# ---- Target locations --------------------------------------------------------
$codexHome = $env:CODEX_HOME
if (-not $codexHome) {
    $codexHome = Join-Path $env:USERPROFILE '.codex'
}

$agentsHome = Join-Path $env:USERPROFILE '.agents'

$locations = @(
    [pscustomobject]@{ name = 'codex-cli';    path = Join-Path $codexHome 'skills' },
    [pscustomobject]@{ name = 'claude-cli';   path = Join-Path $agentsHome 'skills' },
    [pscustomobject]@{ name = 'd-claude-mirror'; path = 'D:\Claude\skills' },
    [pscustomobject]@{ name = 'workspace-mirror'; path = 'D:\Claude\_Claude-Workspace\.claude\skills' }
)
$locationPaths = @()
foreach ($l in $locations) { $locationPaths += $l.path }

# ---- Helpers -----------------------------------------------------------------
function Get-ReparseTarget {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return $null
    }
    # PS 7 returns Target as an array of strings; PS 5.1 as a single string.
    $t = $item.Target
    if ($null -eq $t) { return $null }
    if ($t -is [System.Array]) {
        if ($t.Count -eq 0) { return $null }
        return [string]$t[0]
    }
    return [string]$t
}

function Normalize-Path {
    param([string]$Path)
    if (-not $Path) { return '' }
    try {
        return [System.IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    }
    catch {
        return $Path.TrimEnd('\','/')
    }
}

function Test-PathEqual {
    param([string]$A, [string]$B)
    return ([string]::Equals(
        (Normalize-Path $A),
        (Normalize-Path $B),
        [System.StringComparison]::OrdinalIgnoreCase))
}

# ---- Determine skill set -----------------------------------------------------
$allRepoSkills = Get-ChildItem -LiteralPath $skillsRoot -Directory -Force |
    Select-Object -ExpandProperty Name |
    Sort-Object

if ($NewSkills -and $NewSkills.Count -gt 0) {
    $skillsToCheck = $NewSkills |
        Where-Object { $_ -and ($_ -notin $IgnoreSkills) } |
        Sort-Object -Unique
    $missingFromRepo = $skillsToCheck | Where-Object { $_ -notin $allRepoSkills }
    if ($missingFromRepo) {
        throw ("JUNCTION_GATE_FAIL: -NewSkills includes folders not present under {0}: {1}" -f $skillsRoot, ($missingFromRepo -join ', '))
    }
}
else {
    $skillsToCheck = $allRepoSkills | Where-Object { $_ -notin $IgnoreSkills }
}

# ---- Per-(skill, location) reconciliation ------------------------------------
$results = New-Object System.Collections.Generic.List[object]
$setupGaps = New-Object System.Collections.Generic.List[object]

foreach ($loc in $locations) {
    $parentExists = Test-Path -LiteralPath $loc.path -PathType Container
    if (-not $parentExists) {
        $setupGaps.Add([pscustomobject]@{
            location = $loc.name
            path = $loc.path
            reason = 'parent_missing'
        }) | Out-Null
    }

    foreach ($skill in $skillsToCheck) {
        $expectedTarget = Join-Path $skillsRoot $skill
        $junctionPath = Join-Path $loc.path $skill

        $row = [ordered]@{
            skill = $skill
            location = $loc.name
            location_path = $loc.path
            junction_path = $junctionPath
            expected_target = $expectedTarget
            observed_target = $null
            status = $null
            action = 'none'
            error = $null
        }

        if (-not $parentExists) {
            $row.status = 'setup_gap'
            $results.Add([pscustomobject]$row) | Out-Null
            continue
        }

        $exists = Test-Path -LiteralPath $junctionPath
        if ($exists) {
            $observed = $null
            try { $observed = Get-ReparseTarget -Path $junctionPath } catch { $observed = $null }
            $row.observed_target = $observed
            if (-not $observed) {
                # Path exists but is a real folder, not a reparse point. That's a
                # collision we cannot silently resolve.
                $row.status = 'collision_not_junction'
            }
            elseif (Test-PathEqual $observed $expectedTarget) {
                $row.status = 'ok'
            }
            else {
                $row.status = 'wrong_target'
            }
        }
        else {
            if ($Create) {
                try {
                    New-Item -ItemType Junction -Path $junctionPath -Target $expectedTarget -ErrorAction Stop | Out-Null
                    $observed = Get-ReparseTarget -Path $junctionPath
                    $row.observed_target = $observed
                    if ($observed -and (Test-PathEqual $observed $expectedTarget)) {
                        $row.status = 'created'
                        $row.action = 'created'
                    }
                    else {
                        $row.status = 'create_failed'
                        $row.action = 'create_attempted'
                        $row.error = 'post-create verification did not match expected target'
                    }
                }
                catch {
                    $row.status = 'create_failed'
                    $row.action = 'create_attempted'
                    $row.error = $_.Exception.Message
                }
            }
            else {
                $row.status = 'missing'
            }
        }

        $results.Add([pscustomobject]$row) | Out-Null
    }
}

# ---- Orphan detection --------------------------------------------------------
# A junction is an orphan if it lives in one of the target locations, points
# into <repo>\skills\<X>, and <X> is no longer a folder in the repo. Limit the
# scan to junctions whose target prefix matches <repo>\skills so unrelated
# junctions (e.g. find-skills cross-links) are excluded.
$orphans = New-Object System.Collections.Generic.List[object]
$skillsRootNormalized = (Normalize-Path $skillsRoot) + '\'
foreach ($loc in $locations) {
    if (-not (Test-Path -LiteralPath $loc.path -PathType Container)) { continue }
    Get-ChildItem -LiteralPath $loc.path -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
        ForEach-Object {
            $name = $_.Name
            if ($name -in $IgnoreSkills) { return }
            $target = $null
            try { $target = Get-ReparseTarget -Path $_.FullName } catch { $target = $null }
            if (-not $target) { return }
            $normalizedTarget = (Normalize-Path $target)
            if (-not $normalizedTarget.StartsWith($skillsRootNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
                return
            }
            $leaf = Split-Path -Leaf $normalizedTarget
            if ($leaf -notin $allRepoSkills) {
                $orphans.Add([pscustomobject]@{
                    location = $loc.name
                    location_path = $loc.path
                    name = $name
                    observed_target = $target
                    reason = 'target_skill_removed_from_repo'
                }) | Out-Null
            }
        }
}

# ---- Pass/fail synthesis -----------------------------------------------------
$failStatuses = @('missing','wrong_target','create_failed','collision_not_junction','setup_gap')
$failedRows = @($results | Where-Object { $_.status -in $failStatuses })
$pass = ($failedRows.Count -eq 0) -and ($orphans.Count -eq 0)

$createMode = if ($Create.IsPresent) { $true } else { $false }
$resultsArr   = $results.ToArray()
$orphansArr   = $orphans.ToArray()
$gapsArr      = $setupGaps.ToArray()
$skillsArr    = [object[]]$skillsToCheck
$ignoreArr    = [object[]]$IgnoreSkills
$locationsArr = [object[]]$locationPaths

$summaryHash = New-Object System.Collections.Specialized.OrderedDictionary
$summaryHash.Add('pass',           $pass)
$summaryHash.Add('repo_root',      $RepoRoot)
$summaryHash.Add('skills_root',    $skillsRoot)
$summaryHash.Add('create_mode',    $createMode)
$summaryHash.Add('skills_checked', $skillsArr)
$summaryHash.Add('ignored_skills', $ignoreArr)
$summaryHash.Add('locations',      $locationsArr)
$summaryHash.Add('results',        $resultsArr)
$summaryHash.Add('orphans',        $orphansArr)
$summaryHash.Add('setup_gaps',     $gapsArr)
$summaryObj = [pscustomobject]$summaryHash

if ($Json) {
    $summaryObj | ConvertTo-Json -Depth 8
    if (-not $pass) { exit 1 } else { exit 0 }
}

# ---- Human-readable output ---------------------------------------------------
Write-Output ("Repo:           {0}" -f $RepoRoot)
Write-Output ("Skills checked: {0}" -f ($skillsToCheck -join ', '))
Write-Output ("Create mode:    {0}" -f $Create)
Write-Output ''
Write-Output ('{0,-32} {1,-18} {2,-22} {3}' -f 'skill','location','status','note')
Write-Output ('{0,-32} {1,-18} {2,-22} {3}' -f ('-' * 32),('-' * 18),('-' * 22),('-' * 30))
foreach ($r in $results) {
    $note = ''
    if ($r.status -eq 'wrong_target')       { $note = "-> $($r.observed_target)" }
    elseif ($r.status -eq 'create_failed')  { $note = $r.error }
    elseif ($r.status -eq 'collision_not_junction') { $note = 'non-junction folder occupies path' }
    elseif ($r.status -eq 'setup_gap')      { $note = 'parent location missing' }
    Write-Output ('{0,-32} {1,-18} {2,-22} {3}' -f $r.skill, $r.location, $r.status, $note)
}

if ($setupGaps.Count -gt 0) {
    Write-Output ''
    Write-Output 'Setup gaps:'
    foreach ($g in $setupGaps) {
        Write-Output (' - [{0}] {1} ({2})' -f $g.location, $g.path, $g.reason)
    }
}

if ($orphans.Count -gt 0) {
    Write-Output ''
    Write-Output 'Orphan junctions (report only; manual cleanup):'
    foreach ($o in $orphans) {
        Write-Output (' - [{0}] {1} -> {2} ({3})' -f $o.location, $o.name, $o.observed_target, $o.reason)
    }
}

Write-Output ''
if ($pass) {
    Write-Output 'PASS: all skill junctions resolve to the canonical repo targets.'
    exit 0
}
else {
    Write-Output ('FAIL: junction gate found {0} failing row(s) and {1} orphan(s).' -f $failedRows.Count, $orphans.Count)
    exit 1
}
