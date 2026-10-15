#Requires -Version 7.0
# Fixtures only: no model or vendor processes. The independent review is a fixture file with provenance.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:passed = 0
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "ASSERT_FAIL: $Message" }
    $script:passed++; Write-Output "PASS: $Message"
}
$scripts = Split-Path -Parent $PSScriptRoot
$roll = Join-Path $scripts 'roll-authority-forward.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('authority-rollover-' + [guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-Text([string]$Path, [string]$Text) { [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null; [IO.File]::WriteAllText($Path, $Text, $utf8) }
function Get-FileSha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
$saved = @{}
foreach ($name in @('DT_BUILD_STATE_DIR', 'DT_JOB_ID', 'DT_BUILD_COORDINATOR_ID')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $null) }
$env:DT_BUILD_STATE_DIR = Join-Path $root 'state'

$run = Join-Path $root 'run'
$checkpoint = Join-Path $root 'planning/_build-state.md'
function New-Fixture {
    if (Test-Path $run) { Remove-Item -LiteralPath $run -Recurse -Force }
    $runSlash = $run.Replace('\', '/')
    Write-Text $checkpoint "# Build state`nrun_status: runnable`nlast_consumed_event_seq: 3`n`n## Pointers`n- RUN=$runSlash`n- STOP=RUN/stop2`n"
    Write-Text (Join-Path $run 'base/rule-a.md') "# Base rules`n`n- Never push to main without approval.`n- Pin fixture SHA abc123 for every qualification.`n`nOne review allowance remains for M05.`n"
    foreach ($stop in @('stop1', 'stop2')) {
        Write-Text (Join-Path $run "$stop/next-scope.md") "## Scope $stop`n`n- Only local work under RUN.`n- Never push to main without approval.`n"
        Write-Text (Join-Path $run "$stop/next-approval.md") "Approve $stop to continue local work only.`n"
        Write-Text (Join-Path $run "$stop/source-disposition.json") (@{ disposition = "preserve every $stop source"; seal = "seal-$stop" } | ConvertTo-Json)
    }
    $stop1 = [ordered]@{ schema = 'fixture/v1'; operation = 'stop-one'; scope = (Join-Path $run 'stop1/next-scope.md'); source_disposition = (Join-Path $run 'stop1/source-disposition.json'); approval_text = (Join-Path $run 'stop1/next-approval.md'); inherited_authority_sources = @('RUN/base/rule-a.md'); required_original_records = 5; restriction = 'No target or VM action.' }
    Write-Text (Join-Path $run 'stop1/next-operation-boundary.json') ($stop1 | ConvertTo-Json)
    $stop2 = [ordered]@{ schema = 'fixture/v1'; operation = 'stop-two'; scope = (Join-Path $run 'stop2/next-scope.md'); source_disposition = (Join-Path $run 'stop2/source-disposition.json'); approval_text = (Join-Path $run 'stop2/next-approval.md'); inherited_boundary = (Join-Path $run 'stop1/next-operation-boundary.json'); required_original_records = 9 }
    Write-Text (Join-Path $run 'stop2/next-operation-boundary.json') ($stop2 | ConvertTo-Json)
    foreach ($name in @('approvals.json', 'operator-notes.json', 'build-state.md', 'build-plan.md')) { Write-Text (Join-Path $run $name) "fixture $name`n" }
    Write-Text (Join-Path $run 'jobs/events.jsonl') ('{"seq":1,"type":"recorded"}' + "`n" + '{"seq":2,"job_id":"j-0001","type":"completed"}' + "`n")
    Write-Text (Join-Path $run 'review-log.md') "M05 review allowance consumed by j-0001 on 2026-10-14.`n"
}
function Invoke-Roll([string]$Action, [string[]]$Extra = @()) {
    $raw = & pwsh -NoProfile -File $roll -Action $Action -RunFolder $run -BuildStatePath $checkpoint @Extra 2>&1
    return [pscustomobject]@{ code = $LASTEXITCODE; text = ($raw -join "`n") }
}
function Read-Ledger([string]$Dir) { Get-Content -Raw -LiteralPath (Join-Path $Dir 'clauses-ledger.json') | ConvertFrom-Json -Depth 64 }
function Save-Ledger([string]$Dir, $Ledger) { Write-Text (Join-Path $Dir 'clauses-ledger.json') ($Ledger | ConvertTo-Json -Depth 32) }
function Find-Clause($Ledger, [string]$Needle) { @($Ledger.clauses | Where-Object { $_.text -like "*$Needle*" }) }
function Decide([string]$Dir) {
    $ledger = Read-Ledger $Dir
    foreach ($clause in $ledger.clauses) { if ($null -eq $clause.decision) { $clause.decision = 'carry' } }
    $allowance = Find-Clause $ledger 'One review allowance remains'
    $allowance[0].decision = 'drop'; $allowance[0].reason = 'consumed'
    $allowance[0].evidence = [pscustomobject]@{ quote = [pscustomobject]@{ path = 'review-log.md'; text = 'M05 review allowance consumed by j-0001' } }
    $approve1 = Find-Clause $ledger 'Approve stop1'
    $approve1[0].decision = 'drop'; $approve1[0].reason = 'closed'; $approve1[0].evidence = [pscustomobject]@{ event_seq = 2 }
    Save-Ledger $Dir $ledger
}
$script:ConsolidatedText = '- Only local work under RUN, and no target or VM action (consolidated fixture).'
function Consolidate([string]$Dir) {
    # Two restatements of the local-only rule become one consolidated clause.
    $ledger = Read-Ledger $Dir
    $id = Get-ClauseIdOf $script:ConsolidatedText
    $replaced = @((Find-Clause $ledger 'Only local work under RUN')[0], (Find-Clause $ledger 'No target or VM action')[0])
    foreach ($c in $replaced) { $c.decision = 'drop'; $c.reason = 'consolidated'; $c.evidence = [pscustomobject]@{ consolidation = $id } }
    Save-Ledger $Dir $ledger
    Write-Text (Join-Path $Dir 'consolidations.json') (ConvertTo-Json @([ordered]@{ text = $script:ConsolidatedText; heading = ''; replaces = @($replaced.id); why = 'same rule restated' }) -Depth 6)
}
function Get-ClauseIdOf([string]$Text) { 'c-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes((($Text -replace '\s+', ' ').Trim())))).ToLowerInvariant().Substring(0, 12) }
function Write-Review([string]$Dir, [string]$Verdict = 'stale', [bool]$Single = $true, [string[]]$Skip = @(), [string]$Covers = 'covers') {
    $ledger = Read-Ledger $Dir
    $ledgerSha = Get-FileSha (Join-Path $Dir 'clauses-ledger.json')
    $verdicts = @($ledger.clauses | Where-Object { $_.decision -eq 'drop' -and $_.id -notin $Skip } | ForEach-Object { [ordered]@{ clause = $_.id; verdict = $Verdict; why = 'fixture' } })
    $review = Join-Path $Dir 'review.json'
    $body = [ordered]@{ ledger_sha256 = $ledgerSha; verdicts = $verdicts }
    $consolidationsPath = Join-Path $Dir 'consolidations.json'
    if (Test-Path -LiteralPath $consolidationsPath) {
        $body.consolidations_sha256 = Get-FileSha $consolidationsPath
        $body.consolidations = @(Get-Content -Raw $consolidationsPath | ConvertFrom-Json | ForEach-Object { [ordered]@{ consolidation = (Get-ClauseIdOf $_.text); verdict = $Covers; why = 'fixture' } })
    }
    Write-Text $review ($body | ConvertTo-Json -Depth 6)
    $provenance = [ordered]@{ pass = $true; single_dispatch = $Single; output_sha256 = (Get-FileSha $review); prompt_sha256 = (Get-FileSha (Join-Path $Dir 'review-prompt.md')) }
    Write-Text "$review.provenance.json" ($provenance | ConvertTo-Json)
}

try {
    New-Fixture
    $prepared = Invoke-Roll 'prepare'
    Assert-True ($prepared.code -eq 0) "prepare succeeds ($($prepared.text))"
    $dir = ($prepared.text | ConvertFrom-Json).rollover_directory
    $ledger = Read-Ledger $dir
    Assert-True (@($ledger.sources).Count -eq 9) "ledger covers every stop-record original in the graph ($(@($ledger.sources).Count))"
    Assert-True (@($ledger.sources | Where-Object { (Split-Path -Leaf $_.path) -in @('approvals.json', 'operator-notes.json', 'build-state.md', 'build-plan.md', '_build-state.md') }).Count -eq 0) 'lifecycle records and the checkpoint are never rolled'
    $dup = Find-Clause $ledger 'Never push to main without approval'
    Assert-True ($dup.Count -eq 1 -and @($dup[0].sources).Count -eq 3) 'identical clauses merge into one row that keeps every origin'
    Assert-True (@($ledger.clauses | Where-Object { $_.text -like '/inherited_boundary:*' -and $_.decision -eq 'structural' }).Count -eq 1) 'graph-wiring JSON fields are marked structural'
    Assert-True ((Find-Clause $ledger 'No target or VM action')[0].decision -eq $null) 'restriction JSON fields need a decision'
    $composeEarly = Invoke-Roll 'compose' @('-RolloverDirectory', $dir)
    Assert-True ($composeEarly.code -ne 0 -and $composeEarly.text -match 'AUTHORITY_ROLLOVER_UNDECIDED') 'compose refuses undecided clauses'

    Decide $dir
    $composed = Invoke-Roll 'compose' @('-RolloverDirectory', $dir)
    Assert-True ($composed.code -eq 0) "compose succeeds ($($composed.text))"
    $record = Get-Content -Raw -LiteralPath (Join-Path $dir 'current-authority.md')
    Assert-True ($record.Contains('- Pin fixture SHA abc123 for every qualification.') -and $record.Contains('/restriction: No target or VM action.')) 'carried clauses appear verbatim in the current record'
    Assert-True (-not $record.Contains('One review allowance remains') -and -not $record.Contains('Approve stop1')) 'dropped clauses leave the current record'
    $sidecar = Get-Content -Raw -LiteralPath (Join-Path $dir 'current-authority.provenance.json') | ConvertFrom-Json
    Assert-True ($record.StartsWith('<!-- dt-build authority rollover v2 -->') -and -not ($record -match '<!-- clause ') -and -not $record.Contains($run) -and -not $record.Contains($run.Replace('\', '/'))) 'the v2 record holds clause text only: no per-clause markers and no absolute paths'
    Assert-True (([regex]::Matches($record, '(?m)^## Scope stop1$')).Count -eq 1 -and ([regex]::Matches($record, '(?m)^# Base rules$')).Count -eq 1) 'each original heading appears once in the record'
    $recordLines = $record -split "`n"
    $pinEntry = @($sidecar.clauses | Where-Object { $recordLines[$_.line_start - 1] -like '*Pin fixture SHA abc123*' })
    Assert-True ($pinEntry.Count -eq 1 -and $pinEntry[0].sources[0].path -eq 'base/rule-a.md' -and $pinEntry[0].sources[0].locator -like 'L*') 'the provenance sidecar maps each clause to its record lines and its RUN-relative source'
    Assert-True (@($sidecar.clauses).Count -eq @((Read-Ledger $dir).clauses | Where-Object decision -eq 'carry').Count) 'the sidecar lists every carried clause'
    $noReview = Invoke-Roll 'verify' @('-RolloverDirectory', $dir)
    Assert-True ($noReview.code -ne 0 -and $noReview.text -match 'independent review missing') 'verify requires the independent review'
    Write-Review $dir
    $verified = Invoke-Roll 'verify' @('-RolloverDirectory', $dir)
    Assert-True ($verified.code -eq 0) "verify passes with every clause decided, evidence real and review complete ($($verified.text))"

    # Each guarantee fails closed.
    $recordPath = Join-Path $dir 'current-authority.md'
    $good = Get-Content -Raw -LiteralPath $recordPath
    Write-Text $recordPath $good.Replace('Pin fixture SHA abc123', 'Pin fixture SHA abc999')
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'current-authority.md differs from compose output') 'an edited current record is refused'
    Write-Text $recordPath $good
    $sidecarPath = Join-Path $dir 'current-authority.provenance.json'
    $goodSidecar = Get-Content -Raw -LiteralPath $sidecarPath
    Write-Text $sidecarPath $goodSidecar.Replace('base/rule-a.md', 'base/rule-z.md')
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'current-authority.provenance.json differs from compose output') 'an edited provenance sidecar is refused'
    Write-Text $sidecarPath $goodSidecar
    Write-Review $dir 'live'
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'reviewer says dropped clause c-[0-9a-f]+ is live') 'a reviewer live verdict blocks the drop'
    Write-Review $dir 'stale' $false
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'not dispatched with -SingleDispatch') 'the review must be single-dispatch'
    $skipId = (Find-Clause (Read-Ledger $dir) 'Approve stop1')[0].id
    Write-Review $dir 'stale' $true @($skipId)
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match "no verdict for dropped clause $skipId") 'every dropped clause needs a verdict'
    Write-Review $dir
    $reviewPath = Join-Path $dir 'review.json'
    Write-Text $reviewPath ((Get-Content -Raw $reviewPath) + ' ')
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'differs from the reviewer output') 'a review edited after dispatch is refused'
    Write-Review $dir

    $bad = Read-Ledger $dir
    (Find-Clause $bad 'One review allowance remains')[0].evidence.quote.text = 'text that appears nowhere in the log'
    Save-Ledger $dir $bad
    $null = Invoke-Roll 'compose' @('-RolloverDirectory', $dir); Write-Review $dir
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'quote not found') 'drop evidence quotes must exist in the cited file'
    $bad = Read-Ledger $dir
    $c = (Find-Clause $bad 'One review allowance remains')[0]; $c.evidence = [pscustomobject]@{ event_seq = 99 }
    Save-Ledger $dir $bad; $null = Invoke-Roll 'compose' @('-RolloverDirectory', $dir); Write-Review $dir
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'event seq 99 not in jobs/events.jsonl') 'drop evidence events must exist'
    $bad = Read-Ledger $dir
    $c = (Find-Clause $bad 'One review allowance remains')[0]; $c.reason = 'boring'; $c.evidence = [pscustomobject]@{ event_seq = 2 }
    Save-Ledger $dir $bad; $null = Invoke-Roll 'compose' @('-RolloverDirectory', $dir); Write-Review $dir
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'drop reason must be one of') 'drop reasons are a closed set'
    $bad = Read-Ledger $dir
    $c = (Find-Clause $bad 'One review allowance remains')[0]; $c.reason = 'consumed'
    (Find-Clause $bad 'No target or VM action')[0].decision = 'structural'
    Save-Ledger $dir $bad; $null = Invoke-Roll 'compose' @('-RolloverDirectory', $dir); Write-Review $dir
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'only graph-wiring JSON fields may be structural') 'a restriction cannot be waved through as structural'
    $bad = Read-Ledger $dir
    (Find-Clause $bad 'No target or VM action')[0].decision = 'carry'
    $bad.clauses = @($bad.clauses | Where-Object { $_.text -notlike '*Only local work under RUN*' })
    Save-Ledger $dir $bad; $null = Invoke-Roll 'compose' @('-RolloverDirectory', $dir); Write-Review $dir
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'ledger clauses differ from a fresh extraction') 'a clause removed from the ledger is detected'

    # Consolidation: restatements replaced by one clause the reviewer confirms keeps every restriction.
    New-Fixture
    $dir = ((Invoke-Roll 'prepare').text | ConvertFrom-Json).rollover_directory
    Decide $dir; Consolidate $dir; $null = Invoke-Roll 'compose' @('-RolloverDirectory', $dir); Write-Review $dir
    $consolidatedVerify = Invoke-Roll 'verify' @('-RolloverDirectory', $dir)
    Assert-True ($consolidatedVerify.code -eq 0 -and ($consolidatedVerify.text | ConvertFrom-Json).consolidated -eq 1) "a covered consolidation verifies ($($consolidatedVerify.text))"
    $record = Get-Content -Raw -LiteralPath (Join-Path $dir 'current-authority.md')
    Assert-True ($record.Contains("## Consolidated restatements`n`n$script:ConsolidatedText") -and -not $record.Contains('/restriction: No target or VM action.') -and -not $record.Contains('- Only local work under RUN.')) 'the consolidated clause replaces its originals in the record'
    $sidecar = Get-Content -Raw -LiteralPath (Join-Path $dir 'current-authority.provenance.json') | ConvertFrom-Json
    $entry = @($sidecar.clauses | Where-Object kind -eq 'consolidated')
    Assert-True ($entry.Count -eq 1 -and @($entry[0].replaces).Count -eq 2 -and @($entry[0].sources).Count -ge 3) 'the sidecar keeps the consolidated clause''s replaced ids and their sources'
    Assert-True ((Get-Content -Raw (Join-Path $dir 'review-prompt.md')).Contains($script:ConsolidatedText)) 'the reviewer prompt carries each consolidated clause'
    Write-Review $dir 'stale' $true @() 'loosens'
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'reviewer says consolidated clause c-[0-9a-f]+ loosens') 'a consolidation the reviewer says loosens is refused'
    Write-Review $dir
    $consolidationsPath = Join-Path $dir 'consolidations.json'
    $goodConsolidations = Get-Content -Raw $consolidationsPath
    Write-Text $consolidationsPath ($goodConsolidations.Replace('consolidated fixture', 'consolidated fixture.'))
    $null = Invoke-Roll 'compose' @('-RolloverDirectory', $dir)
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'review names different consolidations') 'consolidations edited after review are refused'
    $one = $goodConsolidations | ConvertFrom-Json; $one[0].replaces = @($one[0].replaces[0])
    Write-Text $consolidationsPath (ConvertTo-Json @($one) -Depth 6); $null = Invoke-Roll 'compose' @('-RolloverDirectory', $dir); Write-Review $dir
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'must replace at least two clauses') 'a consolidation must replace at least two clauses'
    Write-Text $consolidationsPath $goodConsolidations
    $bad = Read-Ledger $dir
    (Find-Clause $bad 'Only local work under RUN')[0].decision = 'carry'
    Save-Ledger $dir $bad; $null = Invoke-Roll 'compose' @('-RolloverDirectory', $dir); Write-Review $dir
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'must be a drop with reason consolidated') 'every replaced clause must be dropped as consolidated'
    $bad = Read-Ledger $dir
    $c = (Find-Clause $bad 'Only local work under RUN')[0]; $c.decision = 'drop'; $c.reason = 'consolidated'; $c.evidence = [pscustomobject]@{ consolidation = 'c-000000000000' }
    Save-Ledger $dir $bad; $null = Invoke-Roll 'compose' @('-RolloverDirectory', $dir); Write-Review $dir
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'consolidation c-000000000000 is not in consolidations.json') 'a consolidated drop must name a real consolidation'

    # Fresh roll for source drift and install, with one consolidation.
    New-Fixture
    $dir = ((Invoke-Roll 'prepare').text | ConvertFrom-Json).rollover_directory
    Decide $dir; Consolidate $dir; $null = Invoke-Roll 'compose' @('-RolloverDirectory', $dir); Write-Review $dir
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).code -eq 0) 'a clean roll verifies'
    $rulePath = Join-Path $run 'base/rule-a.md'
    $ruleText = Get-Content -Raw $rulePath
    Write-Text $rulePath ($ruleText + "- New restriction added after prepare.`n")
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'source changed since prepare') 'a source edited after prepare is refused'
    Write-Text $rulePath $ruleText

    $candidate = Invoke-Roll 'install' @('-RolloverDirectory', $dir, '-CandidateOnly')
    Assert-True ($candidate.code -eq 0) "install -CandidateOnly succeeds ($($candidate.text))"
    $report = $candidate.text | ConvertFrom-Json
    Assert-True ($report.read_set_originals -eq 6 -and @($report.still_required_old_records).Count -eq 0) "the read set becomes the rollover boundary, its record and the four lifecycle records ($($report.read_set_originals))"
    Assert-True (@($report.consolidated_clauses).Count -eq 1 -and $report.consolidated_clauses[0].text -eq $script:ConsolidatedText) 'the candidate preview lists each consolidated clause for Danny''s go'
    Assert-True (-not (Test-Path (Join-Path $run 'authority-history.jsonl'))) 'a candidate-only install writes no history'
    Assert-True ((Get-Content -Raw $checkpoint) -match '(?m)^- STOP=RUN/stop2$') 'a candidate-only install leaves the checkpoint alone'

    $registered = & pwsh -NoProfile -File (Join-Path $scripts 'dt-job.ps1') register-run -RunFolder $run -BuildStatePath $checkpoint -RunId rollover-fixture -PinnedHost claude -Json 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "fixture run registers ($($registered -join ' '))"
    $installed = Invoke-Roll 'install' @('-RolloverDirectory', $dir)
    Assert-True ($installed.code -eq 0) "install succeeds ($($installed.text))"
    $checkpointText = Get-Content -Raw $checkpoint
    Assert-True ($checkpointText.Contains('- STOP=' + $dir.Replace('\', '/'))) 'install points STOP at the rollover'
    Assert-True (Test-Path (Join-Path $run 'checkpoint-history')) 'the previous checkpoint is archived'
    $digest = Get-Content -Raw (Join-Path $run 'authority-digest.json') | ConvertFrom-Json
    Assert-True (@($digest.originals).Count -eq 6 -and -not (@($digest.originals.path) -match 'stop1|stop2|rule-a')) 'the rebuilt digest no longer reads the old stop records'
    Assert-True (Test-Path (Join-Path $run 'stop1/next-operation-boundary.json')) 'old stop records stay on disk as evidence'
    $history = @(Get-Content (Join-Path $run 'authority-history.jsonl') | ConvertFrom-Json)
    Assert-True ($history.Count -eq 4 -and ($history.text -contains 'One review allowance remains for M05.') -and ($history.reason -contains 'consumed')) 'history records each dropped clause verbatim with its reason'
    Assert-True (@($history | Where-Object { -not $_.sources[0].sha256 -or -not $_.superseded_by -or -not $_.rolled_at_utc }).Count -eq 0) 'history rows carry source sha256, what superseded them and the time'
    Assert-True (@($history | Where-Object { $_.reason -eq 'consolidated' -and $_.consolidated_into -eq $script:ConsolidatedText }).Count -eq 2) 'consolidated originals go to history with the clause that replaced them'
    $again = Invoke-Roll 'install' @('-RolloverDirectory', $dir)
    Assert-True (@(Get-Content (Join-Path $run 'authority-history.jsonl')).Count -eq 4) 'history stays append-once per rollover'

    # The next roll starts from the rolled record and keeps clause identity.
    Write-Text (Join-Path $run 'stop3/next-scope.md') "- Run one qualification.`n"
    Write-Text (Join-Path $run 'stop3/next-approval.md') "Approve stop3.`n"
    Write-Text (Join-Path $run 'stop3/source-disposition.json') '{"disposition":"keep"}'
    Write-Text (Join-Path $run 'stop3/next-operation-boundary.json') ([ordered]@{ scope = (Join-Path $run 'stop3/next-scope.md'); source_disposition = (Join-Path $run 'stop3/source-disposition.json'); approval_text = (Join-Path $run 'stop3/next-approval.md'); inherited_boundary = (Join-Path $dir 'next-operation-boundary.json'); required_original_records = 6 } | ConvertTo-Json)
    Write-Text $checkpoint ((Get-Content -Raw $checkpoint) -replace '(?m)^- STOP=.*$', '- STOP=RUN/stop3')
    $rolledPath = Join-Path $dir 'current-authority.md'
    $rolled = Get-Content -Raw -LiteralPath $rolledPath
    Write-Text $rolledPath $rolled.Replace('- Pin fixture SHA abc123 for every qualification.', '- Pin fixture SHA abc124 for every qualification.')
    $tampered = Invoke-Roll 'prepare'
    Assert-True ($tampered.code -ne 0 -and $tampered.text -match 'AUTHORITY_ROLLOVER_RECORD_MISMATCH') 'a rolled record edited after install is refused by the next roll'
    Write-Text $rolledPath $rolled
    $next = Invoke-Roll 'prepare'
    Assert-True ($next.code -eq 0) "a second roll prepares from the rolled record ($($next.text))"
    $nextLedger = Read-Ledger (($next.text | ConvertFrom-Json).rollover_directory)
    $pin = Find-Clause $nextLedger 'Pin fixture SHA abc123'
    Assert-True ($pin.Count -eq 1 -and $pin[0].id -eq (Find-Clause (Read-Ledger $dir) 'Pin fixture SHA abc123')[0].id -and ($pin[0].sources.path -contains $rulePath)) 'carried clauses keep their id and original source across rolls'
    $carriedConsolidation = Find-Clause $nextLedger 'consolidated fixture'
    Assert-True ($carriedConsolidation.Count -eq 1 -and @($carriedConsolidation[0].sources | Where-Object { $_.path -like '*stop1*next-scope.md' }).Count -ge 1) 'a consolidated clause rolls forward with the sources of the clauses it replaced'
    Assert-True (@($nextLedger.sources).Count -eq 6) "the second roll reads only the rolled record plus the new stop ($(@($nextLedger.sources).Count))"

    # A checkpoint that names the history file, even as a before-bootstrap read, never makes it authority.
    Write-Text $checkpoint ((Get-Content -Raw $checkpoint) + "- Before bootstrap read RUN/authority-history.jsonl in full.`n")
    $dry = Join-Path $root 'dry-digest'
    $built = & pwsh -NoProfile -File (Join-Path $scripts 'build-authority-digest.ps1') -RunFolder $run -BuildStatePath $checkpoint -DryRun -OutputDirectory $dry 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "digest builds with the history file named ($($built -join ' '))"
    $dryDigest = Get-Content -Raw (Join-Path $dry 'authority-digest.json') | ConvertFrom-Json
    Assert-True (-not (@($dryDigest.originals.path) -match 'authority-history') -and (@($dryDigest.diagnostics | Where-Object { $_.reason -eq 'evidence_only' -and $_.resolved -like '*authority-history.jsonl' }).Count -ge 1)) 'digest discovery treats authority-history.jsonl as evidence only'
    Assert-True (-not (@($dryDigest.originals.path) -match 'provenance|clauses-ledger')) 'the provenance sidecar and ledger never enter the read set'

    # A record over the read ceiling is refused before review.
    New-Fixture
    Write-Text (Join-Path $run 'base/rule-a.md') ("# Base rules`n`n- Huge restriction " + ('x' * 97000) + "`n")
    $dir = ((Invoke-Roll 'prepare').text | ConvertFrom-Json).rollover_directory
    $ledger = Read-Ledger $dir; foreach ($clause in $ledger.clauses) { if ($null -eq $clause.decision) { $clause.decision = 'carry' } }; Save-Ledger $dir $ledger
    $big = (Invoke-Roll 'compose' @('-RolloverDirectory', $dir)).text | ConvertFrom-Json
    Assert-True (-not $big.within_ceiling -and $big.record_chars -gt 96000) 'compose reports a record over the read ceiling'
    Assert-True ((Invoke-Roll 'verify' @('-RolloverDirectory', $dir)).text -match 'over the 96000-char read ceiling') 'verify refuses a record over the read ceiling'

    Write-Output "SUMMARY: $script:passed passed"
}
finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
