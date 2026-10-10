param()

# Report version 3, the continuation record, and the working-state tree hash: the shared report contract
# called directly, both chunk wrappers through fake CLIs (no live model calls), validate-continuation.ps1,
# and dt-job tree-hash / can-reuse.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT_FAIL: $Message" }
    $script:passed++
}

function Write-Utf8 {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function New-Report {
    # A report for fixture-run / fixture-chunk / attempt 1; -Version 2 omits the v3 fields.
    param([int]$Version = 3, [string]$Verdict = 'PASS', [string[]]$Evidence = @('NONE'), [string]$Continuation = 'NONE')
    $lines = @("DT_BUILD_REPORT_VERSION: $Version", 'RUN_ID: fixture-run', 'chunk_id: fixture-chunk', 'attempt: 1')
    if ($Version -ge 3) { $lines += @('VERDICT:', $Verdict) }
    $lines += @('CHANGED_FILES:', 'NONE', 'COMMANDS_AND_RESULTS:', 'NONE')
    if ($Version -ge 3) { $lines += @('EVIDENCE_PATHS:') + $Evidence }
    $lines += @('UNRESOLVED_BLOCKERS:', 'NONE', 'DISCOVERED_ENHANCEMENTS:', 'NONE', 'CONTINUATION_STATE:')
    if ($Version -ge 3) { $lines += $Continuation } else { $lines += 'NONE' }
    return ($lines -join "`n")
}

function New-ContinuationRecord {
    # A record file; $Fields overrides or (with $null) removes fields of the valid default.
    param([string]$Path, [hashtable]$Fields = @{}, [object[]]$Tests = $null, [switch]$NoBlock, [string]$RawJson)
    $record = [ordered]@{
        run_id = 'fixture-run'; chunk_id = 'fixture-chunk'; attempt = 1
        completed = @('wrote the validator'); tests = @(); running_jobs = @('j-0001'); blockers = @()
        authorization = @('merge'); next_step = 'run the suite'
    }
    if ($null -ne $Tests) { $record.tests = @($Tests) }
    foreach ($key in $Fields.Keys) {
        if ($null -eq $Fields[$key]) { $record.Remove($key) } else { $record[$key] = $Fields[$key] }
    }
    $json = if ($RawJson) { $RawJson } else { $record | ConvertTo-Json -Depth 6 }
    $text = if ($NoBlock) { "# Continuation`n`n$json`n" } else { "# Continuation`n`nDone so far.`n`n``````json`n$json`n```````n`nFree notes after the block.`n" }
    Write-Utf8 -Path $Path -Content $text
    return $Path
}

$scriptDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$repoRoot = (Resolve-Path (Join-Path $scriptDir '..\..\..')).Path
$dtJob = Join-Path $scriptDir 'dt-job.ps1'
$validator = Join-Path $scriptDir 'validate-continuation.ps1'
$contract = Join-Path $scriptDir 'report-contract.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-report-v3-tests-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$savedEnv = @{}
foreach ($name in @('CODEX_HOME', 'DT_MODEL_ROUTER_STATE', 'DT_MODEL_ROUTER_ALERT_TRANSPORT', 'DT_MODEL_ROUTER_CLAUDE_CREDENTIALS', 'DT_FAKE_REPORT_FILE', 'GIT_INDEX_FILE')) {
    $savedEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
}
Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue

$exitCode = 0
try {
    . $contract
    $evidence = Join-Path $tempRoot 'evidence\suite.txt'
    Write-Utf8 -Path $evidence -Content 'SUMMARY: 1 passed'
    $evidence2 = Join-Path $tempRoot 'evidence\other.txt'
    Write-Utf8 -Path $evidence2 -Content 'ok'
    $treeSha = 'a' * 40
    $goodTest = [ordered]@{ command = 'pwsh -NoProfile -File tests/suite.ps1'; exit_code = 0; evidence_path = $evidence; tree_hash = $treeSha; recorded_utc = '2026-10-10T08:00:00Z' }
    $goodRecord = New-ContinuationRecord -Path (Join-Path $tempRoot 'records\good.md') -Tests @($goodTest)
    $check = { param([string]$Text) Get-ReportShapeResult -Text $Text -RunId 'fixture-run' -ChunkId 'fixture-chunk' -ExpectedAttempt 1 }

    # ---- report v3 accepted; v2 accepted with a warning.
    $r = & $check (New-Report -Evidence @($evidence, $evidence2) -Continuation $goodRecord)
    Assert-True (@($r.errors).Count -eq 0 -and $r.version -eq 3 -and $null -eq $r.warning) "a full v3 report validates ($(@($r.errors) -join '; '))"
    $r = & $check (New-Report)
    Assert-True (@($r.errors).Count -eq 0 -and $null -eq $r.warning) 'a v3 report with NONE evidence and NONE continuation validates'
    foreach ($verdict in $script:DtReportVerdicts) {
        if (@((& $check (New-Report -Verdict $verdict)).errors).Count -ne 0) { throw "ASSERT_FAIL: verdict $verdict was rejected" }
    }
    $script:passed++
    $r = & $check (New-Report -Version 2)
    Assert-True (@($r.errors).Count -eq 0 -and $r.version -eq 2 -and $r.warning -eq 'v2') 'a v2 report is accepted with the v2 warning'
    $fenced = "Summary prose.`n`n```````n" + (New-Report -Evidence @($evidence)) + "`n```````n`nTrailing prose."
    Assert-True (@((& $check $fenced).errors).Count -eq 0) 'a v3 report inside a code fence with prose around it validates'
    $inline = (New-Report) -replace "VERDICT:\nPASS", 'VERDICT: PASS'
    Assert-True (@((& $check $inline).errors).Count -eq 0) 'an inline VERDICT value validates'

    # ---- each v3 failure is an output-shape error.
    $r = & $check (New-Report -Verdict 'DONE')
    Assert-True (@($r.errors | Where-Object { $_ -match "^VERDICT 'DONE'" }).Count -eq 1) 'a verdict outside the set is rejected'
    Assert-True (@((& $check (New-Report -Verdict 'pass')).errors).Count -eq 1) 'a lower-case verdict is rejected'
    Assert-True (@((& $check ((New-Report) -replace "VERDICT:\nPASS\n", '')).errors | Where-Object { $_ -eq 'missing VERDICT' }).Count -eq 1) 'a v3 report without VERDICT is rejected'
    $missingEvidence = Join-Path $tempRoot 'evidence\missing.txt'
    $r = & $check (New-Report -Evidence @($evidence, $missingEvidence))
    Assert-True (@($r.errors | Where-Object { $_ -match 'EVIDENCE_PATHS entry does not exist' -and $_ -match 'missing\.txt' }).Count -eq 1) 'a missing evidence path is rejected'
    Assert-True (@((& $check (New-Report -Evidence @('evidence\suite.txt'))).errors).Count -eq 1) 'a relative evidence path is rejected'
    Assert-True (@((& $check ((New-Report) -replace "EVIDENCE_PATHS:\nNONE\n", '')).errors | Where-Object { $_ -eq 'missing EVIDENCE_PATHS' }).Count -eq 1) 'a v3 report without EVIDENCE_PATHS is rejected'
    $r = & $check (New-Report -Continuation (Join-Path $tempRoot 'records\absent.md'))
    Assert-True (@($r.errors | Where-Object { $_ -match '^CONTINUATION_STATE does not exist' }).Count -eq 1) 'a continuation path that does not exist is rejected'
    $badRecord = New-ContinuationRecord -Path (Join-Path $tempRoot 'records\bad-report.md') -Fields @{ next_step = $null }
    $r = & $check (New-Report -Continuation $badRecord)
    Assert-True (@($r.errors | Where-Object { $_ -match '^CONTINUATION_STATE invalid: continuation record missing field next_step' }).Count -eq 1) 'a continuation record that fails the validator is rejected'
    $otherRun = New-ContinuationRecord -Path (Join-Path $tempRoot 'records\other-run.md') -Fields @{ run_id = 'another-run' }
    Assert-True (@((& $check (New-Report -Continuation $otherRun)).errors | Where-Object { $_ -match 'run_id' }).Count -eq 1) "a continuation record for another run is rejected"
    Assert-True (@((& $check ((New-Report) -replace 'DT_BUILD_REPORT_VERSION: 3', 'DT_BUILD_REPORT_VERSION: 4')).errors | Where-Object { $_ -eq 'missing or mismatched DT_BUILD_REPORT_VERSION' }).Count -eq 1) 'an unknown report version is rejected'

    # ---- UNC and relative paths are rejected; every entry up to the next header is read.
    foreach ($unc in @('\\fixture-server\share\suite.txt', '//fixture-server/share/suite.txt', '\\?\C:\evidence\suite.txt')) {
        $r = & $check (New-Report -Evidence @($evidence, $unc))
        if (@($r.errors | Where-Object { $_ -like "EVIDENCE_PATHS entry is not an absolute local path: $unc" }).Count -ne 1) { throw "ASSERT_FAIL: UNC evidence path was not rejected: $unc ($(@($r.errors) -join '; '))" }
        $r = & $check (New-Report -Continuation $unc)
        if (@($r.errors | Where-Object { $_ -like "CONTINUATION_STATE is not an absolute local path: $unc" }).Count -ne 1) { throw "ASSERT_FAIL: UNC continuation path was not rejected: $unc ($(@($r.errors) -join '; '))" }
    }
    $script:passed++
    $r = & $check (New-Report -Evidence @('evidence\suite.txt'))
    Assert-True (@($r.errors | Where-Object { $_ -eq 'EVIDENCE_PATHS entry is not an absolute local path: evidence\suite.txt' }).Count -eq 1) 'a relative evidence path is rejected as not absolute'
    $r = & $check (New-Report -Continuation 'records\good.md')
    Assert-True (@($r.errors | Where-Object { $_ -eq 'CONTINUATION_STATE is not an absolute local path: records\good.md' }).Count -eq 1) 'a relative continuation path is rejected'
    $r = & $check (New-Report -Evidence @($evidence, '', $missingEvidence))
    Assert-True (@($r.errors | Where-Object { $_ -match 'EVIDENCE_PATHS entry does not exist' -and $_ -match 'missing\.txt' }).Count -eq 1) "an evidence entry after a blank line is still validated ($(@($r.errors) -join '; '))"
    $r = & $check (New-Report -Evidence @($evidence, '', $evidence2))
    Assert-True (@($r.errors).Count -eq 0) 'existing evidence entries split by a blank line validate'
    $r = & $check (New-Report -Continuation "NONE`n$goodRecord")
    Assert-True (@($r.errors | Where-Object { $_ -eq 'CONTINUATION_STATE must hold one entry, NONE or one path; found 2' }).Count -eq 1) "two CONTINUATION_STATE entries are rejected ($(@($r.errors) -join '; '))"
    $r = & $check (New-Report -Continuation "$goodRecord`n`n$goodRecord")
    Assert-True (@($r.errors | Where-Object { $_ -match '^CONTINUATION_STATE must hold one entry' }).Count -eq 1) 'a second CONTINUATION_STATE entry after a blank line is rejected'

    # ---- a missing or malformed tree_hash names the field and the command that computes it.
    $hintPattern = 'compute it with: pwsh -NoProfile -File "(?<path>[^"]+dt-job\.ps1)" tree-hash -WorkingTree "<worktree>"'
    $noHash = New-ContinuationRecord -Path (Join-Path $tempRoot 'records\no-hash.md') -Tests @([ordered]@{ command = 'x'; exit_code = 0; evidence_path = $evidence; recorded_utc = '2026-10-10T08:00:00Z' })
    $r = & $check (New-Report -Continuation $noHash)
    $hint = @($r.errors | Where-Object { $_ -match '^CONTINUATION_STATE invalid: continuation tests\[0\] missing field tree_hash; ' -and $_ -match $hintPattern })
    Assert-True ($hint.Count -eq 1 -and @($r.errors).Count -eq 1) "a record without tree_hash is rejected with the field and the command ($(@($r.errors) -join '; '))"
    $hintPath = ([regex]::Match($hint[0], $hintPattern)).Groups['path'].Value
    Assert-True ([System.IO.Path]::IsPathFullyQualified($hintPath) -and (Test-Path -LiteralPath $hintPath -PathType Leaf)) "the tree_hash hint names an existing absolute dt-job.ps1 ($hintPath)"
    $badHash = New-ContinuationRecord -Path (Join-Path $tempRoot 'records\bad-hash.md') -Tests @([ordered]@{ command = 'x'; exit_code = 0; evidence_path = $evidence; tree_hash = 'HEAD'; recorded_utc = '2026-10-10T08:00:00Z' })
    $r = & $check (New-Report -Continuation $badHash)
    Assert-True (@($r.errors | Where-Object { $_ -match '^CONTINUATION_STATE invalid: continuation tests\[0\]\.tree_hash must be a git tree sha; ' -and $_ -match $hintPattern }).Count -eq 1) 'a malformed tree_hash is rejected with the field and the command'

    # ---- the assembled checkpoint rule names dt-job.ps1 by an existing absolute path.
    $packFile = Join-Path $tempRoot 'assemble\contracts.md'
    Write-Utf8 -Path $packFile -Content "# Contracts pack`n`n=== REFERENCE PACK PAYLOAD ===`nFixture contract.`n"
    $manifestFile = Join-Path $tempRoot 'assemble\manifest.json'
    Write-Utf8 -Path $manifestFile -Content (@{ contracts = @{ path = $packFile; payload_sha256 = '' } } | ConvertTo-Json -Depth 3)
    $assembledPath = Join-Path $tempRoot 'assemble\prompt.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'assemble-codex-prompt.ps1') -ManifestPath $manifestFile -RequiredEntitlements contracts -RunId fixture-run -ChunkId fixture-chunk -Attempt 1 -PreambleText 'Fixture preamble.' -BriefText 'Fixture brief.' -OutputPath $assembledPath *> $null
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $assembledPath)) "the assembler runs on a fixture manifest (exit $LASTEXITCODE)"
    $assembled = [System.IO.File]::ReadAllText($assembledPath)
    $ruleMatch = [regex]::Match($assembled, '`pwsh -NoProfile -File "(?<path>[^"]+)" tree-hash -WorkingTree "<worktree>"`')
    $rulePath = $ruleMatch.Groups['path'].Value
    Assert-True ($ruleMatch.Success -and [System.IO.Path]::IsPathFullyQualified($rulePath) -and (Split-Path -Leaf $rulePath) -eq 'dt-job.ps1' -and (Test-Path -LiteralPath $rulePath -PathType Leaf)) "the assembled checkpoint rule gives a copy-paste tree-hash command with an existing absolute dt-job.ps1 ($rulePath)"
    Assert-True ($assembled -notmatch '(?<![\\/])dt-job tree-hash') 'the assembled rule no longer names a bare dt-job command'

    # ---- both wrappers validate through the one shared contract.
    foreach ($wrapperName in @('invoke-claude-chunk.ps1', 'invoke-codex-chunk.ps1')) {
        $wrapperPath = Join-Path $scriptDir $wrapperName
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($wrapperPath, [ref]$tokens, [ref]$parseErrors)
        $ownDefs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Get-ReportShapeErrors', 'Get-ReportShapeResult', 'Get-DtContinuationRecord') }, $true))
        $text = Get-Content -Raw -LiteralPath $wrapperPath
        Assert-True (@($parseErrors).Count -eq 0 -and $ownDefs.Count -eq 0 -and $text.Contains(". (Join-Path `$PSScriptRoot 'report-contract.ps1')") -and $text.Contains('Get-ReportShapeResult -Text $lastMessage') -and $text -match 'report_version_warning\s+= \$reportVersionWarning') "$wrapperName validates through report-contract.ps1 and reports the version warning"
    }

    # Both wrappers end to end, with fake CLIs.
    $routerState = Join-Path $tempRoot 'router-state'
    Write-Utf8 -Path (Join-Path $routerState 'last-check.json') -Content (@{ checked_at = (Get-Date).ToString('o') } | ConvertTo-Json)
    $env:DT_MODEL_ROUTER_STATE = $routerState
    $fakeTransport = Join-Path $tempRoot 'fake-alert-transport.ps1'
    Write-Utf8 -Path $fakeTransport -Content @'
param($request)
if ($request['kind'] -eq 'secret') { return 'fake-secret' }
if ([string]$request['uri'] -like '*/oauth2/applications/@me') { return [pscustomobject]@{ owner = [pscustomobject]@{ id = '1' } } }
return [pscustomobject]@{ id = 'fake' }
'@
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $fakeTransport
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = Join-Path $tempRoot 'missing-claude-credentials.json'
    $codexHome = Join-Path $tempRoot 'codex-home'
    Write-Utf8 -Path (Join-Path $codexHome 'models_cache.json') -Content '{"fetched_at":"fixture","models":[{"slug":"gpt-6.1-sol","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}]}]}'
    Write-Utf8 -Path (Join-Path $codexHome 'auth.json') -Content '{"auth_mode":"fixture"}'
    $env:CODEX_HOME = $codexHome
    $fakeCodex = Join-Path $tempRoot 'fake-codex.ps1'
    Write-Utf8 -Path $fakeCodex -Content @'
if ($args -contains '--version') { Write-Output 'codex-cli fixture'; exit 0 }
if ($args -contains 'debug') { Get-Content -Raw -LiteralPath (Join-Path $env:CODEX_HOME 'models_cache.json'); exit 0 }
$outIndex = [Array]::IndexOf([object[]]$args, '--output-last-message')
$outPath = [string]$args[$outIndex + 1]
[void][Console]::In.ReadToEnd()
[System.IO.File]::WriteAllText($outPath, [System.IO.File]::ReadAllText($env:DT_FAKE_REPORT_FILE))
'@
    $fakeClaude = Join-Path $tempRoot 'fake-claude.ps1'
    Write-Utf8 -Path $fakeClaude -Content @'
if ($args -contains '--version') { Write-Output 'claude-cli fixture'; exit 0 }
[void][Console]::In.ReadToEnd()
$usage = [ordered]@{}; $usage['claude-sonnet-5'] = @{ inputTokens = 10; outputTokens = 20; costUSD = 0.01 }
Write-Output (@{ type = 'result'; is_error = $false; result = [System.IO.File]::ReadAllText($env:DT_FAKE_REPORT_FILE); total_cost_usd = 0.01; modelUsage = $usage } | ConvertTo-Json -Depth 5 -Compress)
'@
    $project = Join-Path $tempRoot 'project'
    Write-Utf8 -Path (Join-Path $project 'README.md') -Content 'fixture'
    & git -C $project init -q
    $prompt = Join-Path $tempRoot 'prompt.md'
    Write-Utf8 -Path $prompt -Content "RUN_ID: fixture-run`nchunk_id: fixture-chunk`nattempt: 1`nfixture"
    $reportFile = Join-Path $tempRoot 'fake-report.md'
    $env:DT_FAKE_REPORT_FILE = $reportFile
    $cases = @(
        @{ name = 'v3'; text = (New-Report -Evidence @($evidence) -Continuation $goodRecord); pass = $true; warning = $null },
        @{ name = 'v2'; text = (New-Report -Version 2); pass = $true; warning = 'v2' },
        @{ name = 'bad-verdict'; text = (New-Report -Verdict 'DONE'); pass = $false; match = "VERDICT 'DONE'" },
        @{ name = 'missing-evidence'; text = (New-Report -Evidence @($missingEvidence)); pass = $false; match = 'EVIDENCE_PATHS entry does not exist' },
        @{ name = 'bad-continuation'; text = (New-Report -Continuation $badRecord); pass = $false; match = 'CONTINUATION_STATE invalid' }
    )
    foreach ($lane in @('codex', 'claude')) {
        foreach ($case in $cases) {
            Write-Utf8 -Path $reportFile -Content $case.text
            $out = Join-Path $tempRoot "out\$lane-$($case.name).md"
            New-Item -ItemType Directory -Path (Split-Path -Parent $out) -Force | Out-Null
            if ($lane -eq 'codex') {
                & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') -ProjectPath $project -PromptPath $prompt -OutputPath $out -CodexCliPath $fakeCodex -Tier standard -Effort medium -SelectionReason 'report v3 fixture' -Attempt 1 -Json *> $null
            }
            else {
                & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') -ProjectPath $project -PromptPath $prompt -OutputPath $out -ClaudeCliPath $fakeClaude -Model claude-sonnet-5 -Tier standard -Effort medium -SelectionReason 'report v3 fixture' -Attempt 1 -Json *> $null
            }
            $code = $LASTEXITCODE
            $prov = Get-Content -Raw -LiteralPath "$out.provenance.json" | ConvertFrom-Json
            if ($case.pass) {
                Assert-True ($code -eq 0 -and $prov.pass -and @($prov.output_shape_errors).Count -eq 0 -and $prov.report_version_warning -eq $case.warning) "$lane wrapper accepts the $($case.name) report (exit $code, warning '$($prov.report_version_warning)', errors $(@($prov.output_shape_errors) -join '; '))"
            }
            else {
                $prefix = if ($lane -eq 'codex') { 'CODEX_OUTPUT_INVALID' } else { 'CLAUDE_OUTPUT_INVALID' }
                Assert-True ($code -ne 0 -and -not $prov.pass -and $prov.failure_category -eq 'model-output' -and [string]$prov.termination_reason -like "${prefix}:*" -and @($prov.output_shape_errors | Where-Object { $_ -like "*$($case.match)*" }).Count -ge 1) "$lane wrapper rejects the $($case.name) report as an output-shape error ($($prov.termination_reason))"
            }
        }
    }

    # ---- continuation validator.
    $vRun = { param([string[]]$Arguments) $raw = & pwsh -NoProfile -File $validator @Arguments -Json; [pscustomobject]@{ exit = $LASTEXITCODE; result = (($raw -join "`n") | ConvertFrom-Json) } }
    $v = & $vRun @('-Path', $goodRecord)
    Assert-True ($v.exit -eq 0 -and $v.result.valid) 'a complete record validates'
    $v = & $vRun @('-Path', $goodRecord, '-RunId', 'fixture-run', '-ChunkId', 'fixture-chunk')
    Assert-True ($v.exit -eq 0 -and $v.result.valid) 'a record matching -RunId and -ChunkId validates'
    $v = & $vRun @('-Path', $goodRecord, '-RunId', 'other-run')
    Assert-True ($v.exit -ne 0 -and @($v.result.errors | Where-Object { $_ -match 'run_id' }).Count -eq 1) 'a run mismatch fails'
    $v = & $vRun @('-Path', $goodRecord, '-ChunkId', 'other-chunk')
    Assert-True ($v.exit -ne 0 -and @($v.result.errors | Where-Object { $_ -match 'chunk_id' }).Count -eq 1) 'a chunk mismatch fails'
    $v = & $vRun @('-Path', (New-ContinuationRecord -Path (Join-Path $tempRoot 'records\noblock.md') -NoBlock))
    Assert-True ($v.exit -ne 0 -and @($v.result.errors)[0] -match 'no ```json block') 'a record with no json block fails'
    $v = & $vRun @('-Path', (New-ContinuationRecord -Path (Join-Path $tempRoot 'records\garbage.md') -RawJson '{ not json'))
    Assert-True ($v.exit -ne 0 -and @($v.result.errors)[0] -match 'does not parse') 'a record whose block does not parse fails'
    foreach ($field in $script:DtContinuationFields) {
        $v = & $vRun @('-Path', (New-ContinuationRecord -Path (Join-Path $tempRoot "records\missing-$field.md") -Fields @{ $field = $null }))
        if ($v.exit -eq 0 -or @($v.result.errors | Where-Object { $_ -eq "continuation record missing field $field" }).Count -ne 1) { throw "ASSERT_FAIL: missing $field was not reported" }
    }
    $script:passed++
    $wrongTypes = @(
        @{ attempt = 'one' }, @{ attempt = 0 }, @{ completed = 'all of it' }, @{ completed = @(1, 2) }, @{ running_jobs = 'j-0001' },
        @{ blockers = 'none' }, @{ authorization = 'merge' }, @{ next_step = @('a') }, @{ run_id = 7 }, @{ tests = 'passed' }
    )
    $i = 0
    foreach ($fields in $wrongTypes) {
        $v = & $vRun @('-Path', (New-ContinuationRecord -Path (Join-Path $tempRoot "records\type-$i.md") -Fields $fields))
        if ($v.exit -eq 0) { throw "ASSERT_FAIL: wrong type was accepted: $($fields | ConvertTo-Json -Compress)" }
        $i++
    }
    $script:passed++
    $badTests = @(
        [ordered]@{ command = 'x'; exit_code = 0; evidence_path = $evidence; recorded_utc = '2026-10-10T08:00:00Z' },
        [ordered]@{ command = 'x'; exit_code = '0'; evidence_path = $evidence; tree_hash = $treeSha; recorded_utc = '2026-10-10T08:00:00Z' },
        [ordered]@{ command = 'x'; exit_code = 0; evidence_path = $evidence; tree_hash = 'HEAD'; recorded_utc = '2026-10-10T08:00:00Z' },
        [ordered]@{ command = 'x'; exit_code = 0; evidence_path = $evidence; tree_hash = $treeSha; recorded_utc = 'yesterday-ish' },
        'not an object'
    )
    $i = 0
    foreach ($test in $badTests) {
        $v = & $vRun @('-Path', (New-ContinuationRecord -Path (Join-Path $tempRoot "records\test-$i.md") -Tests @($test)))
        if ($v.exit -eq 0) { throw "ASSERT_FAIL: malformed test entry was accepted: $($test | ConvertTo-Json -Compress)" }
        $i++
    }
    $script:passed++
    $v = & $vRun @('-Path', (New-ContinuationRecord -Path (Join-Path $tempRoot 'records\auth-object.md') -Fields @{ authorization = [ordered]@{ approved = @('merge') } }))
    Assert-True ($v.exit -eq 0) 'authorization copied as an object validates'
    $text = & pwsh -NoProfile -File $validator -Path (Join-Path $tempRoot 'records\missing-next_step.md')
    Assert-True ($LASTEXITCODE -ne 0 -and [string]@($text)[0] -eq 'INVALID: continuation record missing field next_step') 'without -Json the validator prints one INVALID line per error'

    # ---- working-state tree hash.
    $repo = Join-Path $tempRoot 'hash-repo'
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git -C $repo init -q
    & git -C $repo config user.email 'fixture@example.invalid'
    & git -C $repo config user.name 'Fixture'
    & git -C $repo config core.autocrlf false
    Write-Utf8 -Path (Join-Path $repo 'tracked.txt') -Content "one`n"
    Write-Utf8 -Path (Join-Path $repo '.gitignore') -Content "ignored/`n"
    [System.IO.File]::WriteAllBytes((Join-Path $repo 'blob.bin'), [byte[]](0, 1, 2, 255, 0, 7))
    & git -C $repo add tracked.txt .gitignore blob.bin
    & git -C $repo commit -q -m 'fixture'
    Write-Utf8 -Path (Join-Path $repo 'untracked.txt') -Content "draft`n"
    Write-Utf8 -Path (Join-Path $repo 'staged.txt') -Content "staged`n"
    & git -C $repo add staged.txt
    $indexPath = Join-Path $repo '.git\index'
    $indexBefore = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
    $stagedBefore = (& git -C $repo diff --cached --name-only) -join ','
    $hash = { param([string]$Tree) $raw = & pwsh -NoProfile -File $dtJob tree-hash -WorkingTree $Tree; if ($LASTEXITCODE -ne 0) { throw "tree-hash exited $LASTEXITCODE" }; ([string]@($raw)[0]).Trim() }
    $h0 = & $hash $repo
    Assert-True ($h0 -match '^[0-9a-f]{40}$') "tree-hash returns a tree sha ($h0)"
    Assert-True ((Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash -eq $indexBefore -and ((& git -C $repo diff --cached --name-only) -join ',') -eq $stagedBefore -and ((& git -C $repo status --porcelain) -match 'untracked\.txt')) 'the real index is untouched: staged set unchanged, untracked file still untracked'
    Assert-True (@(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'dt-job-tree-hash-*' -Directory -ErrorAction SilentlyContinue).Count -eq 0) 'the temporary index folder is removed'
    $null = Get-Content -Raw -LiteralPath (Join-Path $repo 'tracked.txt')
    $null = Get-Content -Raw -LiteralPath (Join-Path $repo 'untracked.txt')
    $null = & git -C $repo status --porcelain
    Assert-True ((& $hash $repo) -eq $h0) 'reads and git status leave the tree hash unchanged'
    Write-Utf8 -Path (Join-Path $repo 'ignored\scratch.log') -Content 'noise'
    Assert-True ((& $hash $repo) -eq $h0) 'a file under .gitignore does not change the tree hash'
    Write-Utf8 -Path (Join-Path $repo 'tracked.txt') -Content "two`n"
    $h1 = & $hash $repo
    Assert-True ($h1 -ne $h0) 'an edit to a tracked file changes the tree hash'
    Write-Utf8 -Path (Join-Path $repo 'untracked.txt') -Content "draft edited`n"
    $h2 = & $hash $repo
    Assert-True ($h2 -ne $h1) "an untracked file's content changes the tree hash"
    [System.IO.File]::WriteAllBytes((Join-Path $repo 'blob.bin'), [byte[]](0, 1, 2, 254, 0, 7))
    $h3 = & $hash $repo
    Assert-True ($h3 -ne $h2) 'a binary file edit changes the tree hash'
    Assert-True ((& $hash $repo) -eq $h3) 'the tree hash is stable across repeated calls'
    $sub = Join-Path $repo 'nested'
    New-Item -ItemType Directory -Path $sub -Force | Out-Null
    Write-Utf8 -Path (Join-Path $sub 'n.txt') -Content 'n'
    Assert-True ((& $hash $sub) -eq (& $hash $repo)) 'a subfolder hashes the whole working tree'
    Assert-True ((Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash -eq $indexBefore) 'after every tree-hash call the real index file is byte-identical'
    $notRepo = Join-Path $tempRoot 'not-a-repo'
    New-Item -ItemType Directory -Path $notRepo -Force | Out-Null
    & pwsh -NoProfile -File $dtJob tree-hash -WorkingTree $notRepo *> $null
    Assert-True ($LASTEXITCODE -ne 0) 'tree-hash fails outside a git working tree'
    $expected = & $hash $repo
    $env:GIT_INDEX_FILE = Join-Path $tempRoot 'caller-index'
    try {
        $withCallerIndex = & $hash $repo
        Assert-True ($withCallerIndex -eq $expected -and $env:GIT_INDEX_FILE -eq (Join-Path $tempRoot 'caller-index') -and -not (Test-Path -LiteralPath (Join-Path $tempRoot 'caller-index'))) "a caller's GIT_INDEX_FILE is neither used nor written"
    }
    finally { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }

    # ---- can-reuse: only an exact command, exit 0, and the current tree hash.
    $cmd = 'pwsh -NoProfile -File tests/suite.ps1'
    $reuse = { param([string]$Record, [string]$Command) $raw = & pwsh -NoProfile -File $dtJob can-reuse -Record $Record -Command $Command -WorkingTree $repo -Json; [pscustomobject]@{ exit = $LASTEXITCODE; result = (($raw -join "`n") | ConvertFrom-Json) } }
    $now = '2026-10-10T08:30:00Z'
    $match = New-ContinuationRecord -Path (Join-Path $tempRoot 'records\reuse-match.md') -Tests @([ordered]@{ command = $cmd; exit_code = 0; evidence_path = $evidence; tree_hash = $expected; recorded_utc = $now })
    $c = & $reuse $match $cmd
    Assert-True ($c.exit -eq 0 -and $c.result.reuse -eq $true -and $c.result.evidence_path -eq $evidence) "an exact command, exit 0, and the current tree hash allow reuse ($($c.result.reason))"
    $plain = & pwsh -NoProfile -File $dtJob can-reuse -Record $match -Command $cmd -WorkingTree $repo
    Assert-True ([string]@($plain)[0] -eq 'true') 'can-reuse prints true without -Json'
    $c = & $reuse $match "$cmd -Verbose"
    Assert-True ($c.result.reuse -eq $false -and $c.result.reason -match 'exact command') 'a different command does not reuse'
    $c = & $reuse $match ($cmd.ToUpperInvariant())
    Assert-True ($c.result.reuse -eq $false) 'command matching is exact, including case'
    $failed = New-ContinuationRecord -Path (Join-Path $tempRoot 'records\reuse-failed.md') -Tests @([ordered]@{ command = $cmd; exit_code = 1; evidence_path = $evidence; tree_hash = $expected; recorded_utc = $now })
    $c = & $reuse $failed $cmd
    Assert-True ($c.result.reuse -eq $false -and $c.result.reason -match 'did not pass') 'a failing recorded test does not reuse'
    $stale = New-ContinuationRecord -Path (Join-Path $tempRoot 'records\reuse-stale.md') -Tests @([ordered]@{ command = $cmd; exit_code = 0; evidence_path = $evidence; tree_hash = $h2; recorded_utc = $now })
    $c = & $reuse $stale $cmd
    Assert-True ($c.result.reuse -eq $false -and $c.result.reason -match 'tree hash changed') 'a stale tree hash does not reuse'
    Write-Utf8 -Path (Join-Path $repo 'untracked.txt') -Content "edited after the test`n"
    $c = & $reuse $match $cmd
    Assert-True ($c.result.reuse -eq $false) 'an untracked edit after the test forces a rerun'
    $h4 = & $hash $repo
    $malformed = @(
        (New-ContinuationRecord -Path (Join-Path $tempRoot 'records\reuse-noblock.md') -NoBlock -Tests @([ordered]@{ command = $cmd; exit_code = 0; evidence_path = $evidence; tree_hash = $h4; recorded_utc = $now })),
        (New-ContinuationRecord -Path (Join-Path $tempRoot 'records\reuse-nonext.md') -Fields @{ next_step = $null } -Tests @([ordered]@{ command = $cmd; exit_code = 0; evidence_path = $evidence; tree_hash = $h4; recorded_utc = $now })),
        (New-ContinuationRecord -Path (Join-Path $tempRoot 'records\reuse-badtest.md') -Tests @([ordered]@{ command = $cmd; exit_code = 0; tree_hash = $h4; recorded_utc = $now })),
        (New-ContinuationRecord -Path (Join-Path $tempRoot 'records\reuse-garbage.md') -RawJson ('{"tests":[{"command":"' + $cmd + '","exit_code":0,"tree_hash":"' + $h4 + '"}]')),
        (Join-Path $tempRoot 'records\reuse-absent.md')
    )
    foreach ($record in $malformed) {
        $c = & $reuse $record $cmd
        if ($c.exit -ne 0 -or $c.result.reuse -ne $false -or -not $c.result.reason) { throw "ASSERT_FAIL: malformed record authorized reuse or gave no reason: $record" }
    }
    $script:passed++
    $c = & $reuse (New-ContinuationRecord -Path (Join-Path $tempRoot 'records\reuse-notrepo.md') -Tests @([ordered]@{ command = $cmd; exit_code = 0; evidence_path = $evidence; tree_hash = $h4; recorded_utc = $now })) $cmd
    Assert-True ($c.result.reuse -eq $true) 'a valid record against the current hash reuses (control for the malformed set)'
    $raw = & pwsh -NoProfile -File $dtJob can-reuse -Record $match -Command $cmd -WorkingTree $notRepo -Json
    Assert-True ((($raw -join "`n") | ConvertFrom-Json).reuse -eq $false -and (($raw -join "`n") | ConvertFrom-Json).reason -match 'cannot decide') 'a tree hash that cannot be computed returns false with the reason'

    # ---- tracked files that .gitignore matches (force-added) are in the hash, committed or only staged.
    $forced = Join-Path $tempRoot 'forced-repo'
    New-Item -ItemType Directory -Path $forced -Force | Out-Null
    & git -C $forced init -q
    & git -C $forced config user.email 'fixture@example.invalid'
    & git -C $forced config user.name 'Fixture'
    & git -C $forced config core.autocrlf false
    Write-Utf8 -Path (Join-Path $forced '.gitignore') -Content "*.log`n"
    Write-Utf8 -Path (Join-Path $forced 'a.txt') -Content "a`n"
    Write-Utf8 -Path (Join-Path $forced 'secret.log') -Content "committed v1`n"
    & git -C $forced add .gitignore a.txt
    & git -C $forced add -f secret.log
    & git -C $forced commit -q -m 'fixture'
    Write-Utf8 -Path (Join-Path $forced 'staged.log') -Content "staged v1`n"
    & git -C $forced add -f staged.log
    $forcedIndex = Join-Path $forced '.git\index'
    $forcedIndexBefore = (Get-FileHash -LiteralPath $forcedIndex -Algorithm SHA256).Hash
    $reuseIn = { param([string]$Tree, [string]$Record, [string]$Command) $raw = & pwsh -NoProfile -File $dtJob can-reuse -Record $Record -Command $Command -WorkingTree $Tree -Json; (($raw -join "`n") | ConvertFrom-Json) }
    $f0 = & $hash $forced
    $forcedTree = @(& git -C $forced ls-tree --name-only $f0)
    Assert-True (($forcedTree -contains 'secret.log') -and ($forcedTree -contains 'staged.log')) "committed and staged force-added files are in the hashed tree ($($forcedTree -join ','))"
    $forcedRecord = New-ContinuationRecord -Path (Join-Path $tempRoot 'records\forced.md') -Tests @([ordered]@{ command = $cmd; exit_code = 0; evidence_path = $evidence; tree_hash = $f0; recorded_utc = $now })
    Assert-True ((& $reuseIn $forced $forcedRecord $cmd).reuse -eq $true) 'can-reuse is true before the force-added file changes'
    Write-Utf8 -Path (Join-Path $forced 'secret.log') -Content "committed v2`n"
    $c = & $reuseIn $forced $forcedRecord $cmd
    Assert-True ($c.reuse -eq $false -and $c.reason -match 'tree hash changed') "an edit to a committed force-added file after recording forces a rerun ($($c.reason))"
    Write-Utf8 -Path (Join-Path $forced 'secret.log') -Content "committed v1`n"
    Assert-True ((& $reuseIn $forced $forcedRecord $cmd).reuse -eq $true) 'restoring the force-added file restores the hash'
    Write-Utf8 -Path (Join-Path $forced 'staged.log') -Content "staged v2`n"
    Assert-True ((& $reuseIn $forced $forcedRecord $cmd).reuse -eq $false) 'an edit to a staged-only force-added file forces a rerun'
    Write-Utf8 -Path (Join-Path $forced 'staged.log') -Content "staged v1`n"
    Write-Utf8 -Path (Join-Path $forced 'other.log') -Content 'ignored noise'
    Assert-True ((& $hash $forced) -eq $f0) 'an untracked file matching .gitignore stays out of the hash'
    Assert-True ((Get-FileHash -LiteralPath $forcedIndex -Algorithm SHA256).Hash -eq $forcedIndexBefore) 'seeding from HEAD leaves the real index byte-identical'

    # ---- the continuation record itself never changes the hash.
    $before = & $hash $forced
    $defaultRecord = New-ContinuationRecord -Path (Join-Path $forced '.dt-build-continuation.md') -Tests @([ordered]@{ command = $cmd; exit_code = 0; evidence_path = $evidence; tree_hash = $before; recorded_utc = $now })
    Assert-True ((& $hash $forced) -eq $before) 'writing the default .dt-build-continuation.md leaves tree-hash unchanged'
    $c = & $reuseIn $forced $defaultRecord $cmd
    Assert-True ($c.reuse -eq $true) "a record written in the worktree root after hashing still allows reuse ($($c.reason))"
    $namedRecord = New-ContinuationRecord -Path (Join-Path $forced 'notes\state.md') -Tests @([ordered]@{ command = $cmd; exit_code = 0; evidence_path = $evidence; tree_hash = $before; recorded_utc = $now })
    $c = & $reuseIn $forced $namedRecord $cmd
    Assert-True ($c.reuse -eq $true) "a record at another path inside the worktree is left out of its own hash ($($c.reason))"
    $withRecord = & pwsh -NoProfile -File $dtJob tree-hash -WorkingTree $forced -Record $namedRecord
    Assert-True (([string]@($withRecord)[0]).Trim() -eq $before) 'tree-hash -Record leaves that record out'
    Assert-True ((& $hash $forced) -ne $before) 'without -Record a record at a non-default path is hashed like any file (control)'
    Write-Utf8 -Path (Join-Path $forced 'a.txt') -Content "a edited`n"
    Assert-True ((& $reuseIn $forced $namedRecord $cmd).reuse -eq $false) 'an edit beside the record still forces a rerun'
}
catch {
    Write-Output "FAIL: $($_.Exception.Message)"
    Write-Output $_.ScriptStackTrace
    $exitCode = 1
}
finally {
    foreach ($name in $savedEnv.Keys) { [System.Environment]::SetEnvironmentVariable($name, $savedEnv[$name]) }
    Write-Output "SUMMARY: $script:passed passed"
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($exitCode -eq 0) { Write-Output 'PASS: report v3 suite' }
exit $exitCode
