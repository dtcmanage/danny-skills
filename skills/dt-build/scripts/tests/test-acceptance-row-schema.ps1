Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passed = 0; $failed = [Collections.Generic.List[string]]::new()
function Check([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passed++ } else { $script:failed.Add($Message) }
}
$scripts = Split-Path -Parent $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ('acceptance-row-schema-' + [guid]::NewGuid().ToString('N'))
$run = Join-Path $root 'run'
$wt = Join-Path $root 'wt'
New-Item -ItemType Directory -Path $run, $wt | Out-Null
$oldState = $env:DT_MODEL_ROUTER_STATE
$env:DT_MODEL_ROUTER_STATE = Join-Path $root 'router-state'
try {
    & git -C $wt init -q; & git -C $wt -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
    $sha = (& git -C $wt rev-parse HEAD).Trim()
    $roadmap = Join-Path $run 'roadmap.md'
    Set-Content -LiteralPath $roadmap -Value "## Milestones`n| id | name | acceptance-checks |`n| --- | --- | --- |`n| M01 | A | Run ``x`` |`n| M02 | B | Run ``x`` |`n| M03 | C | Run ``x`` |"
    $append = Join-Path $scripts 'append-acceptance-row.ps1'
    $rows = Join-Path $run 'acceptance-rows.jsonl'

    # Write-time validation refuses an incomplete row and writes nothing.
    $bad = @{ milestone_id = 'M01'; commit_sha = $sha; accepted = $true; command_results = @(@{ command = 'x'; exit_code = 0 }) } | ConvertTo-Json -Depth 5 -Compress
    $r = (& pwsh -NoProfile -File $append -RunFolder $run -RowJson $bad -Json) -join "`n" | ConvertFrom-Json
    Check ($LASTEXITCODE -eq 1 -and -not $r.appended -and ($r.errors -join ' ') -match 'status is required' -and ($r.errors -join ' ') -match 'tests text or checks') 'invalid row refused with named missing fields'
    Check (-not (Test-Path -LiteralPath $rows)) 'refused row leaves no file'
    $mismatch = @{ milestone_id = 'M01'; commit_sha = $sha; accepted = $false; status = 'PASS'; tests = 'PASS'; command_results = @(@{ command = 'x'; exit_code = 0 }) } | ConvertTo-Json -Depth 5 -Compress
    & pwsh -NoProfile -File $append -RunFolder $run -RowJson $mismatch -Json | Out-Null
    Check ($LASTEXITCODE -eq 1) 'status PASS with accepted false refused'

    # Legacy rows (real shape of the 2026-11-27 Finance M02-M05 rows) are kept verbatim.
    $prov = Join-Path $run 'm02-report.md.provenance.json'
    Set-Content -LiteralPath $prov -Value (@{ dispatch_id = 'd-legacy'; logical_task_id = 'M02-build'; attempt = 1; finished_utc = '2026-11-27T18:00:00Z'; independent_acceptance = $true } | ConvertTo-Json -Compress)
    $provHash = (Get-FileHash -LiteralPath $prov).Hash
    New-Item -ItemType Directory -Path (Join-Path $run 'milestones/M02') | Out-Null
    Set-Content -LiteralPath (Join-Path $run 'milestones/M02/acceptance.json') -Value (@{ milestone_id = 'M02'; dispatch_id = 'd-legacy'; status = 'PASS'; accepted = $true } | ConvertTo-Json -Compress)
    $legacy = @{ milestone_id = 'M02'; commit_sha = $sha; accepted = $true; dispatch_id = 'd-legacy'; provenance_path = $prov; attempt = 1; logical_task_id = 'M02-build'; verifier = @{ verdict = 'PASS' }; command_results = @(@{ command = 'x'; exit_code = 0 }) } | ConvertTo-Json -Depth 5 -Compress
    Add-Content -LiteralPath $rows -Value $legacy

    # Three identical current PASS rows for one result (the Finance M06 j-0049 shape).
    $current = @{ milestone_id = 'M03'; commit_sha = $sha; accepted = $true; status = 'PASS'; tests = '5 of 5 commands PASS'; command_results = @(@{ command = 'x'; exit_code = 0 }) } | ConvertTo-Json -Depth 5 -Compress
    foreach ($i in 1..3) { & pwsh -NoProfile -File $append -RunFolder $run -RowJson $current -Json | Out-Null; Check ($LASTEXITCODE -eq 0) "valid row $i appended" }
    $before = [IO.File]::ReadAllLines($rows)
    Check ($before.Count -eq 4 -and $before[0] -ceq $legacy) 'append-only: legacy line kept byte-for-byte'

    $audit = (& pwsh -NoProfile -File $append -RunFolder $run -Audit -Json) -join "`n" | ConvertFrom-Json
    Check ($audit.rows[0].state -eq 'legacy' -and @($audit.rows | Where-Object state -eq 'current').Count -eq 3) 'audit classifies legacy and current rows'
    Check (([IO.File]::ReadAllLines($rows) -join "`n") -ceq ($before -join "`n")) 'audit writes nothing'

    $out = & pwsh -NoProfile -File (Join-Path $scripts 'build-acceptance-ledger.ps1') -RoadmapPath $roadmap -WorkingTree $wt -RunFolder $run -OutDir $run
    $md = Get-Content -Raw (Join-Path $run 'build-acceptance-ledger.md')
    Check ($md -match '\| M02 \| YES \| NO \| NO \| RECORD_INCOMPLETE \|' -and $md -match 'historical acceptance is not inferred' -and $md -match 'acceptance.json status=PASS \(dispatch matches') 'legacy row renders RECORD_INCOMPLETE with original gate evidence named, not accepted'
    Check ($md -match '\| M01 \| NO \| NO \| NO \| BLOCKED \|' -and $md -match 'persisted acceptance row missing for M01') 'milestone with no row stays BLOCKED'
    Check ($md -match '\*\*Summary:\*\* 1 PASS, 1 RECORD_INCOMPLETE, 1 BLOCKED \(of 3 total\)') 'three rows of one result count once'
    Check ((Get-FileHash -LiteralPath $prov).Hash -eq $provHash) 'legacy row never rewrites builder provenance (no router rejection)'
    Check (($out -join "`n") -match 'Router acceptance: unknown for d-legacy') 'router acceptance reported unknown for legacy row'
    Check ((Get-Content -Raw (Join-Path $run 'build-acceptance-ledger.html')).Contains('RECORD_INCOMPLETE')) 'html ledger shows RECORD_INCOMPLETE'
} finally {
    $env:DT_MODEL_ROUTER_STATE = $oldState
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetTempPath())) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Write-Output "SUMMARY: $passed passed, $($failed.Count) failed"
foreach ($failure in $failed) { Write-Output "FAIL: $failure" }
if ($failed.Count) { exit 1 }
