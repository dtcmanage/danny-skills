# Regression tests for scripts/release-triage.ps1 (release-time finding triage).
#   pwsh -NoProfile -File scripts/tests/test-release-triage.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$triage = Join-Path (Split-Path -Parent $PSScriptRoot) 'release-triage.ps1'
$failures = 0
function Assert {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Output "PASS: $Name" } else { Write-Output "FAIL: $Name"; $script:failures++ }
}
function Invoke-Triage {
    param([object[]]$Findings, [string]$Stage = 'final-review', [string]$RunFolder)
    $path = Join-Path $root ("findings-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    ConvertTo-Json -InputObject @($Findings) -Depth 4 | Set-Content -LiteralPath $path
    $cliArgs = @('-NoProfile', '-File', $triage, '-FindingsPath', $path, '-Stage', $Stage, '-Json')
    if ($RunFolder) { $cliArgs += @('-RunFolder', $RunFolder) }
    $out = & pwsh @cliArgs 2>&1
    $code = $LASTEXITCODE
    $parsed = $null
    try { $parsed = ($out -join "`n") | ConvertFrom-Json } catch { }
    return [pscustomobject]@{ Code = $code; Result = $parsed; Raw = ($out -join "`n") }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("release-triage-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    # The CC v2.1 shape: a docs finding at the final milestone, labelled important by review.
    $docs = @{ id = 'F1'; milestone = 'M07'; type = 'docs'; severity = 'important'
        what = 'Ship handoff names the old rollback folder'; where = 'docs/v21-ship-handoff.md'
        why_not_blocking = 'runbook wording only; the rollback script itself is correct and gated' }
    $run = Join-Path $root 'run'
    $r = Invoke-Triage -Findings @($docs) -Stage 'final-milestone' -RunFolder $run
    Assert ($r.Code -eq 0) 'non-critical (important docs) finding: exit 0, ship'
    Assert ($r.Result.decision -eq 'ship') 'non-critical: decision ship'
    Assert (-not $r.Result.regate_required) 'non-critical: no gate rerun'
    Assert (@($r.Result.known_issues) -contains 'M07 F1') 'non-critical: listed as known issue with milestone key'
    $deferred = Join-Path $run 'deferred-findings.md'
    $text = Get-Content -LiteralPath $deferred -Raw
    Assert ($text -match '(?m)^## Known issues$') 'deferred-findings.md gets a Known issues section'
    Assert ($text -match '\*\*M07 F1\*\* \(docs, final-milestone\)') 'known-issue line carries key, type and stage'
    Assert ($text -match 'Where: docs/v21-ship-handoff\.md') 'known-issue line records where'
    Assert ($text -match 'Why it does not block: runbook wording only') 'known-issue line records why'

    # Idempotent: the same finding twice is logged once.
    $r = Invoke-Triage -Findings @($docs) -Stage 'final-milestone' -RunFolder $run
    Assert (@($r.Result.appended).Count -eq 0) 'repeat triage appends nothing'
    Assert (@(Select-String -LiteralPath $deferred -Pattern 'M07 F1' -SimpleMatch).Count -eq 1) 'repeat triage keeps one line'

    # Existing deferred content is preserved; Known issues inserted inside its section, before a later section.
    $run2 = Join-Path $root 'run2'
    New-Item -ItemType Directory -Path $run2 | Out-Null
    $seed = "# Deferred findings`n`n- M03 nicer retry banner: can wait`n`n## Known issues`n`n- **M05 F2** (docs): old.`n`n## Later`n`n- tail`n"
    Set-Content -LiteralPath (Join-Path $run2 'deferred-findings.md') -Value $seed -NoNewline
    $cosmetic = @{ id = 'F3'; type = 'app-bug'; what = 'Tooltip clipped at 393px'; where = 'web/src/ui/Tip.tsx'; why_not_blocking = 'cosmetic; content still readable' }
    $r = Invoke-Triage -Findings @($cosmetic) -Stage 'ship' -RunFolder $run2
    $text2 = Get-Content -LiteralPath (Join-Path $run2 'deferred-findings.md') -Raw
    Assert ($text2 -match 'M03 nicer retry banner') 'existing deferred entries preserved'
    Assert ($text2.IndexOf('**F3**') -gt $text2.IndexOf('**M05 F2**') -and $text2.IndexOf('**F3**') -lt $text2.IndexOf('## Later')) 'new known issue lands inside the Known issues section'
    Assert ($text2 -match '(?m)^- tail$') 'later section preserved'

    # Every critical class blocks and requires a rerun on the fixed candidate.
    foreach ($class in @('core-flow', 'data-loss', 'security', 'deploy-rollback')) {
        $crit = @{ id = "C-$class"; type = 'app-bug'; what = 'x'; where = 'y'; critical = $class; critical_scenario = 'concrete failure' }
        $r = Invoke-Triage -Findings @($crit, $cosmetic) -RunFolder (Join-Path $root "crit-$class")
        Assert ($r.Code -eq 2 -and $r.Result.decision -eq 'block') "critical $class blocks (exit 2)"
        Assert ([bool]$r.Result.regate_required) "critical $class requires re-gate"
        Assert (@($r.Result.known_issues) -contains 'F3') "critical ${class}: the minor one is still logged as known issue"
    }
    Assert (-not (Get-Content -LiteralPath (Join-Path $root 'crit-security/deferred-findings.md') -Raw).Contains('C-security')) 'critical finding is never written as a known issue'

    # Invalid input fails closed.
    $r = Invoke-Triage -Findings @(@{ id = 'B1'; what = 'x'; where = 'y'; critical = 'ugly' })
    Assert ($r.Code -eq 1 -and $r.Result.decision -eq 'invalid') 'unknown critical class is invalid'
    $r = Invoke-Triage -Findings @(@{ id = 'B2'; what = 'x'; where = 'y'; critical = 'security' })
    Assert ($r.Code -eq 1) 'critical without scenario is invalid'
    $r = Invoke-Triage -Findings @(@{ id = 'B3'; what = 'x'; where = 'y' })
    Assert ($r.Code -eq 1) 'non-critical without why_not_blocking is invalid'
    $r = Invoke-Triage -Findings @(@{ id = 'B4'; where = 'y'; why_not_blocking = 'z' })
    Assert ($r.Code -eq 1) 'finding without what is invalid'
    $r = Invoke-Triage -Findings @(@{ id = 'B5'; what = 'x'; where = 'y'; critical = 'none'; why_not_blocking = 'z' })
    Assert ($r.Code -eq 0) "critical 'none' counts as non-critical"

    # Listing mode reads back what was logged.
    $out = & pwsh -NoProfile -File $triage -ListKnownIssues -DeferredPath $deferred -Json
    $items = @(($out -join "`n") | ConvertFrom-Json)
    Assert ($items.Count -eq 1 -and $items[0].key -eq 'M07 F1') 'list mode returns known issues'
    $out = & pwsh -NoProfile -File $triage -ListKnownIssues -DeferredPath (Join-Path $root 'missing.md') -Json
    Assert (@(($out -join "`n") | ConvertFrom-Json).Count -eq 0) 'list mode on a missing file is empty'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Output "$failures failure(s)"; exit 1 }
Write-Output 'All release-triage tests passed.'
