Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passed = 0; $failed = [Collections.Generic.List[string]]::new()
function Check([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passed++ } else { $script:failed.Add($Message) }
}
$scripts = Split-Path -Parent $PSScriptRoot
$builder = Join-Path $scripts 'build-roadmap.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('milestone-sources-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null

function Invoke-Builder([string]$Name, [string]$Design) {
    $designPath = Join-Path $root "$Name.md"
    $roadmapPath = Join-Path $root "$Name-roadmap.md"
    Set-Content -LiteralPath $designPath -Value $Design
    $stderrPath = Join-Path $root "$Name.stderr"
    $out = & pwsh -NoProfile -File $builder -DesignPath $designPath -RoadmapPath $roadmapPath -ForceMermaidFallback 2> $stderrPath
    $code = $LASTEXITCODE
    [pscustomobject]@{
        exit = $code
        stdout = ($out -join "`n")
        stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
        roadmap = if (Test-Path -LiteralPath $roadmapPath) { Get-Content -LiteralPath $roadmapPath -Raw } else { '' }
    }
}

try {
    # Fix 1: Linux runners (python3, bash, sh, ./x, uv, npx, pnpm, make, go, cargo) and .sh paths are runnable.
    $runners = @(
        'python3 tests/test_a.py', 'python3.12 -m pytest tests', 'bash scripts/check.sh', 'sh scripts/check.sh',
        './scripts/check.sh --fast', 'uv run pytest -q', 'npx vitest run', 'pnpm test', 'make test',
        'go test ./...', 'cargo test', 'scripts/check.sh'
    )
    $seq = (1..$runners.Count | ForEach-Object { "$_. Step $_. Build piece $_." }) -join "`n"
    $gates = (0..($runners.Count - 1) | ForEach-Object { '- M{0:D2}: run `{1}` and `tag_clusters`.' -f ($_ + 1), $runners[$_] }) -join "`n"
    $r = Invoke-Builder 'runners' "# Runners`n## Implementation Sequence`n$seq`n## Validation Gates`n$gates`n"
    Check ($r.exit -eq 0) "runner design builds (stderr: $($r.stderr))"
    foreach ($cmd in $runners) { Check ($r.roadmap.Contains('`' + $cmd + '`')) "runner lifted into procedure: $cmd" }
    Check (-not $r.roadmap.Contains('`tag_clusters`')) 'prose backticks stay out of procedure cells'
    # Every runner milestone names an executable command; the path-only `scripts/check.sh` (M12) is
    # still lifted as supplemental evidence but is the only milestone flagged as missing a command.
    Check ($r.roadmap -match '(?s)## Producer Warnings.*no executable command[^\n]*\n\n- M12\n(?!- M)') "only the path-only milestone M12 gets the missing-command producer warning"
    Check ($r.roadmap -match '(?m)^- milestones-missing-commands: 1$') 'producer metadata counts one milestone missing an executable command'

    # Fix 2a: a `## Milestones` section with a numbered list.
    $r = Invoke-Builder 'milestones' @'
# Design
## Context
1. Not a milestone.
## Milestones
1. **Ingest.** Build the reader.
2. **Publish.** Ship the writer.
## Validation Gates
- M01: `python3 -m pytest tests/test_ingest.py`
- M02: `python3 -m pytest tests/test_publish.py`
'@
    Check ($r.exit -eq 0) "milestones heading builds (stderr: $($r.stderr))"
    Check ($r.roadmap.Contains('| M01 | Ingest |') -and $r.roadmap.Contains('| M02 | Publish |') -and -not $r.roadmap.Contains('| M03 |')) 'milestones heading yields M01-M02 from its list only'
    Check ($r.roadmap.Contains('input-contract-mode: milestone_heading_fallback')) 'milestones heading records its fallback mode'

    # Fix 2b: a `### Build phases` heading with child headings and no list; numbered steps under a child are not milestones.
    $r = Invoke-Builder 'phases' @'
# Design
## Plan
### Build phases
#### Schema
1. Create tables.
2. Add indexes.
#### API
Expose the endpoints.
## Validation Gates
- M01: `bash scripts/schema.sh`
- M02: `bash scripts/api.sh`
'@
    Check ($r.exit -eq 0) "phases heading builds (stderr: $($r.stderr))"
    Check ($r.roadmap.Contains('| M01 | Schema |') -and $r.roadmap.Contains('| M02 | API |') -and -not $r.roadmap.Contains('| M03 |')) 'child headings become milestones'

    # Legacy `### Phase N` headings keep their parser even when a phase holds a numbered list.
    $r = Invoke-Builder 'legacy' @'
# Design
### Phase 1 - Foundations
1. Step one.
2. Step two.
### Phase 2 - Rollout
Roll out.
'@
    Check ($r.exit -eq 0 -and $r.roadmap.Contains('input-contract-mode: phase_headings_fallback') -and $r.roadmap.Contains('| M02 | Phase 2 - Rollout |') -and -not $r.roadmap.Contains('| M03 |')) 'legacy phase headings unchanged'

    # Fix 2c: numbered top-level deliverable sections; framing sections skipped.
    $r = Invoke-Builder 'numbered' @'
# Design
## 1. Overview
Why.
## 2. Ingest service
Reads files.
## 3. Review UI
Shows rows.
## 4. Risks
None.
'@
    Check ($r.exit -eq 0) "numbered sections build (stderr: $($r.stderr))"
    Check ($r.roadmap.Contains('| M01 | Ingest service |') -and $r.roadmap.Contains('| M02 | Review UI |') -and -not $r.roadmap.Contains('| M03 |') -and $r.roadmap.Contains('numbered_sections_fallback')) 'numbered deliverable sections become milestones'

    # Fix 2d: nothing derivable -> actionable error, non-zero exit, no stack trace.
    $r = Invoke-Builder 'empty' "# Design`n## Context`nProse only.`n"
    Check ($r.exit -eq 2) "underivable design exits 2 (got $($r.exit))"
    Check ($r.stderr.Contains('NO_MILESTONES_DERIVABLE: No milestones derivable from design') -and $r.stderr.Contains('## Implementation Sequence') -and $r.stderr.Contains('### Phase')) 'error names the headings it looked for'
    Check ($r.stderr -notmatch 'build-roadmap\.ps1:\d+|Line \||ScriptStackTrace|RuntimeException') 'error carries no stack trace'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "SUMMARY: $passed passed, $($failed.Count) failed"
if ($failed.Count) { $failed | ForEach-Object { Write-Output "FAIL: $_" }; exit 1 }
