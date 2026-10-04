param()

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

$scriptDir = Split-Path -Parent $PSCommandPath
$skillRoot = Split-Path -Parent $scriptDir
$resolvedSkillRoot = (Get-Item -LiteralPath $skillRoot).ResolveLinkTarget($true)
if ($resolvedSkillRoot) { $skillRoot = $resolvedSkillRoot.FullName }
$repoRoot = Split-Path -Parent (Split-Path -Parent $skillRoot)
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-build-regressions-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$originalCodexHome = $env:CODEX_HOME
$originalClaudeCredentials = $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS
$env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = Join-Path $tempRoot 'missing-claude-credentials.json'
$originalRouterState = $env:DT_MODEL_ROUTER_STATE
$originalAlertTransport = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT

try {
    # Both orchestrator retry passages must consume diagnosis before escalation.
    $skillText = Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'SKILL.md')
    $retryPassages = @(
        [regex]::Match($skillText, '(?m)^- \*\*Retry once:\*\*[^\r\n]+').Value,
        [regex]::Match($skillText, '(?s)- c\. \*\*Run the chunk through the canonical lane\.\*\*.*?(?=- c1\.)').Value
    )
    foreach ($passage in $retryPassages) {
        $text = $passage -replace '\s+', ' '
        Assert-True ($text -match 'Run the dispatch diagnosis before any `-EscalateFrom`; consume the wrapper result first\.' ) 'retry passage diagnoses before escalation'
        Assert-True ($text -match 'On `ROUTER_VENDOR_INCIDENT` re-dispatch once on the result''s `backup_pick` and print its own `MODEL_SELECTION` line; this retry consumes no attempt, as for `ROUTER_LIMIT`\.') 'incident retry uses returned backup with disclosure and no attempt charge'
        Assert-True ($text -match 'On `ROUTER_UNEXPLAINED` do not re-dispatch, escalate, or demote; stop the piece \(the wrapper already retried once and paged\)\.') 'unexplained stops without another retry or quality signal'
        Assert-True ($text -match 'On `ROUTER_OFFLINE` the piece fails as `environment`; the orchestrator''s own resume handles it\.') 'offline returns to orchestrator resume as environment'
        Assert-True ($text.IndexOf('run the dispatch diagnosis', [StringComparison]::OrdinalIgnoreCase) -lt $text.IndexOf('`-EscalateFrom')) 'diagnosis precedes first escalation reference'
        Assert-True ($text -match 'two-attempt budget' -and $text -match 'standard.*`-RetryAtHardFrom <failed model>' -and $text -match 'hard.*`-EscalateFrom <failed model>' -and $text -match 'without tiers.*`-EscalateFrom <failed model>` as before') 'both retry passages use standard-to-hard or hard-to-escalation within two attempts and keep escalation for untiered categories'
    }

    # Extract once: a backticked python -m pytest command must not produce an
    # inner duplicate pytest invocation.
    . (Join-Path $repoRoot 'scripts\extract-named-artifacts.ps1')
    $extracted = Extract-NamedArtifacts -Text 'Run `python -m pytest tests/test_one.py -q` and capture PASS/FAIL.'
    Assert-True ($extracted.commands.Count -eq 1) "python -m pytest was extracted more than once"
    Assert-True ($extracted.commands[0] -eq 'python -m pytest tests/test_one.py -q') "wrong extracted command"

    # Extension matches must end at the path token. In particular, `.js` must
    # never consume the prefix of a `.json` fixture named inside a command.
    $jsonExtracted = Extract-NamedArtifacts -Text 'Run `python scripts/repair_campaign_manifest.py --fixture tests/fixtures/service_split/v1/campaign-3.json --preview`.'
    Assert-True ($jsonExtracted.artifacts -contains 'tests/fixtures/service_split/v1/campaign-3.json') "JSON fixture path was not extracted exactly"
    Assert-True (-not ($jsonExtracted.artifacts -contains 'tests/fixtures/service_split/v1/campaign-3.js')) "JSON fixture path was truncated to .js"
    $unsupportedSuffixes = @(
        @{ Path = 'tests/assets/bundle.js.map'; Prefix = 'tests/assets/bundle.js' },
        @{ Path = 'tests/assets/check.ps1-old'; Prefix = 'tests/assets/check.ps1' },
        @{ Path = 'tests/assets/receipt.json.tmp'; Prefix = 'tests/assets/receipt.json' }
    )
    foreach ($case in $unsupportedSuffixes) {
        $unsupported = Extract-NamedArtifacts -Text ("Inspect ``python scripts/check.py --input {0}``." -f $case.Path)
        Assert-True (-not ($unsupported.artifacts -contains $case.Prefix)) ("unsupported suffix was truncated to {0}" -f $case.Prefix)
    }

    # A nested-path command target (e.g. `pwsh -File skills/dt-build/scripts/...`)
    # must never be truncated to a bare `scripts/...`/`tests/...` tail. That
    # truncated tail is what the acceptance gate looks for on disk, does not
    # find, and falsely reports as a missing artifact -- blocking a milestone
    # whose named scripts are actually present.
    $truncationText = 'Run `pwsh -NoProfile -File skills/dt-build/scripts/test-x.ps1` then ' +
        '`pwsh -NoProfile -File skills/dt-review/tests/run-tests.ps1` and confirm both exit 0.'
    $truncationExtracted = Extract-NamedArtifacts -Text $truncationText
    Assert-True ($truncationExtracted.commands.Count -eq 2) "nested-path pwsh commands were not extracted exactly twice"
    Assert-True ($truncationExtracted.commands -contains 'pwsh -NoProfile -File skills/dt-build/scripts/test-x.ps1') "full command naming skills/dt-build/scripts/test-x.ps1 was not preserved"
    Assert-True ($truncationExtracted.commands -contains 'pwsh -NoProfile -File skills/dt-review/tests/run-tests.ps1') "full command naming skills/dt-review/tests/run-tests.ps1 was not preserved"
    Assert-True (-not ($truncationExtracted.artifacts -contains 'scripts/test-x.ps1')) "nested path was truncated to scripts/test-x.ps1"
    Assert-True (-not ($truncationExtracted.artifacts -contains 'tests/run-tests.ps1')) "nested path was truncated to tests/run-tests.ps1"
    Assert-True ($truncationExtracted.artifacts.Count -eq 0) "nested-path command produced an unexpected (possibly truncated) artifact"

    # The shared helper and the gate's dependency-free inline copy are one
    # contract. Compare their parsed function extents so either copy drifting
    # alone fails this regression suite.
    $helperTokens = $null
    $helperErrors = $null
    $inlineTokens = $null
    $inlineErrors = $null
    $helperAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot 'scripts\extract-named-artifacts.ps1'),
        [ref]$helperTokens,
        [ref]$helperErrors
    )
    $inlineAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $scriptDir 'verify-milestone-acceptance.ps1'),
        [ref]$inlineTokens,
        [ref]$inlineErrors
    )
    Assert-True ($helperErrors.Count -eq 0 -and $inlineErrors.Count -eq 0) "artifact extractor scripts did not parse"
    $helperFunction = $helperAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Extract-NamedArtifacts'
    }, $true)
    $inlineFunction = $inlineAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Extract-NamedArtifacts'
    }, $true)
    Assert-True ($null -ne $helperFunction -and $null -ne $inlineFunction) "artifact extractor function was not found in both scripts"
    Assert-True ($helperFunction.Extent.Text -ceq $inlineFunction.Extent.Text) "shared and inline artifact extractor function bodies drifted"

    # Model router state is isolated: a temp state folder, a fresh catalog-check stamp (no
    # network), and a fake alert transport (no real alert can be sent).
    $routerState = Join-Path $tempRoot 'router-state'
    New-Item -ItemType Directory -Path $routerState -Force | Out-Null
    $env:DT_MODEL_ROUTER_STATE = $routerState
    Write-Utf8 -Path (Join-Path $routerState 'last-check.json') -Content (@{ checked_at = (Get-Date).ToString('o') } | ConvertTo-Json)
    $fakeAlertTransport = Join-Path $tempRoot 'fake-alert-transport.ps1'
    Write-Utf8 -Path $fakeAlertTransport -Content @'
param($request)
if ($request['kind'] -eq 'secret') { return 'fake-secret' }
if ([string]$request['uri'] -like '*/oauth2/applications/@me') { return [pscustomobject]@{ owner = [pscustomobject]@{ id = '1' } } }
return [pscustomobject]@{ id = 'fake' }
'@
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $fakeAlertTransport
    # Approved fixture roster matches the shipped default; all router assertions use it.
    . (Join-Path $repoRoot 'scripts\resolve-codex-model.ps1')
    $cachePath = Join-Path $tempRoot 'models.json'
    Write-Utf8 -Path $cachePath -Content @'
{"models":[
  {"slug":"gpt-6-astra","visibility":"list","priority":1,"upgrade":null,"description":"Frontier intelligence for the most demanding work."},
  {"slug":"gpt-6-sol","visibility":"list","priority":2,"upgrade":null,"description":"Workhorse model for coding and everyday work."},
  {"slug":"gpt-6-luna","visibility":"list","priority":3,"upgrade":null,"description":"Fast and affordable model for easier tasks."},
  {"slug":"gpt-5.6-sol","visibility":"list","priority":4,"upgrade":null},
  {"slug":"gpt-5.6-terra","visibility":"list","priority":7,"upgrade":null},
  {"slug":"gpt-5.6-luna","visibility":"list","priority":8,"upgrade":null},
  {"slug":"gpt-6-codex-spark","visibility":"list","priority":0,"upgrade":null},
  {"slug":"gpt-reserve","visibility":"hide","priority":3,"upgrade":null}
]}
'@
    # The roster's coder is GPT-6.1 Sol. The catalog
    # above stays 6.0-only for the legacy generation-ladder check below, which only looks at the newest generation.
    $routerCachePath = Join-Path $tempRoot 'models-router.json'
    Write-Utf8 -Path $routerCachePath -Content ((Get-Content -Raw -LiteralPath $cachePath).Replace('{"models":[', '{"models":[' + "`n" + '  {"slug":"gpt-6.1-sol","visibility":"list","priority":2,"upgrade":null,"description":"Workhorse model for coding and everyday work."},'))
    . (Join-Path $repoRoot 'scripts\model-router\resolve-model.ps1')
    $fixtureRoster = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'references/model-router/default-roster.json') | ConvertFrom-Json -Depth 20
    $fixtureRoster.approved = $true; $fixtureRoster.approved_at = '2026-10-01T00:00:00Z'
    Write-Utf8 -Path (Join-Path $routerState 'roster.json') -Content ($fixtureRoster | ConvertTo-Json -Depth 20)
    $routerCatalog = Get-Content -Raw -LiteralPath $routerCachePath | ConvertFrom-Json -Depth 20
    foreach ($case in @(@('complex-coding',$true,'medium'),@('routine-coding',$false,'medium'),@('mechanical',$false,'low'),@('code-review',$false,'medium'))) {
        foreach ($lane in @('codex','claude')) {
            $pick = Resolve-RouterModel -Category $case[0] -Lane $lane -Protected:$case[1] -Catalog $routerCatalog -SkipModelCheck
            $job = $fixtureRoster.jobs.(Get-RouterCategoryJob -Category $case[0])
            $want = if ($job.first_vendor -eq $lane) { $job.first } else { $job.backup }
            Assert-True ($pick.model -eq $want -and $pick.effort -eq $case[2] -and $pick.roster_source -eq 'state') "roster pick and effort $($case[0])/$lane"
        }
    }
    $emptyState = Join-Path $tempRoot 'empty-router-state'; New-Item -ItemType Directory -Path $emptyState | Out-Null
    $env:DT_MODEL_ROUTER_STATE = $emptyState
    try {
        $pick = Resolve-RouterModel -Category routine-coding -Lane claude -Catalog $routerCatalog -SkipModelCheck
        Assert-True ($pick.model -eq 'claude-opus-5-5' -and $pick.effort -eq 'medium' -and $pick.roster_source -eq 'default') 'default roster fallback and effort'
    } finally { $env:DT_MODEL_ROUTER_STATE = $routerState }
    Assert-True ((@(Get-CodexModelLadder -Catalog (Get-Content -Raw -LiteralPath $cachePath | ConvertFrom-Json)) -join ',') -eq 'gpt-6-sol,gpt-6-luna') "frontier model leaked into the automatic ladder"
    Assert-True ((Resolve-CodexModel -Tier complex -PreferredModel 'gpt-6-astra' -CachePath $cachePath -Strict 3>$null) -eq 'gpt-6-astra') "explicit frontier override was not honored"
    $retiringCache = Join-Path $tempRoot 'models-retiring.json'
    Write-Utf8 -Path $retiringCache -Content '{"models":[{"slug":"gpt-6.1-sol","visibility":"list","priority":1,"upgrade":{"model":"gpt-6-luna"}},{"slug":"gpt-6-luna","visibility":"list","priority":2,"upgrade":null}]}'
    $retiringRejected = $false
    try { [void](Resolve-CodexModel -Tier complex -CachePath $retiringCache -Strict) } catch { $retiringRejected = $_.Exception.Message -match 'unselectable' }
    Assert-True $retiringRejected "roster resolver accepted a retiring model on a constrained lane"
    $overrideRejected = $false
    try { [void](Resolve-CodexModel -Tier standard -PreferredModel 'gone-model' -CachePath $cachePath -Strict) }
    catch { $overrideRejected = $true }
    Assert-True $overrideRejected "strict resolver silently replaced an unselectable override"
    $effortCache = Join-Path $tempRoot 'models-effort.json'
    Write-Utf8 -Path $effortCache -Content '{"models":[{"slug":"gpt-6.1-sol","visibility":"list","priority":1,"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}]}]}'
    $fallbackModel = Resolve-CodexModel -Tier standard -CachePath $effortCache -Strict
    $effortRejected = $false
    try { [void](Assert-CodexReasoningEffort -Model $fallbackModel -Effort max -CachePath $effortCache -Strict) }
    catch { $effortRejected = $true }
    Assert-True $effortRejected "unsupported reasoning effort was not rejected after model fallback"

    $workingTree = Join-Path $tempRoot 'working-tree'
    New-Item -ItemType Directory -Path (Join-Path $workingTree 'tests') -Force | Out-Null
    Write-Utf8 -Path (Join-Path $workingTree 'tests\noisy.ps1') -Content @'
1..3000 | ForEach-Object {
    Write-Output ("stdout-{0:D5}-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" -f $_)
    [Console]::Error.WriteLine(("stderr-{0:D5}-yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy" -f $_))
}
'@
    Write-Utf8 -Path (Join-Path $workingTree 'tests\slow.ps1') -Content 'Start-Sleep -Seconds 5'
    Write-Utf8 -Path (Join-Path $workingTree 'scripts\repair_campaign_manifest.py') -Content 'raise SystemExit(0)'
    Write-Utf8 -Path (Join-Path $workingTree 'tests\fixtures\service_split\v1\campaign-3.json') -Content '{"synthetic":true}'
    & git -C $workingTree init -q
    & git -C $workingTree config user.email 'fixture@example.invalid'
    & git -C $workingTree config user.name 'Fixture'
    & git -C $workingTree add .
    & git -C $workingTree commit -q -m 'working tree fixture'
    $workingSha = (& git -C $workingTree rev-parse HEAD).Trim()

    $roadmap = Join-Path $tempRoot 'roadmap.md'
    Write-Utf8 -Path $roadmap -Content @'
---
schema_version: 1
source_artifact: fixture
generated_at_utc: 2026-07-12T00:00:00Z
---

## Milestones
| id | name | dependencies | chunks | verification-mode | baseline-floor | acceptance-checks | decision-basis |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| M01 | Foundation | - | chunk-m01 | machine-checkable | none | Run `pwsh -NoProfile -File tests/noisy.ps1` and capture PASS/FAIL. | fixture |
| M02 | Cut over with rollback intact | M01 | chunk-m02 | machine-checkable | M01 | Run `pwsh -NoProfile -File tests/slow.ps1` and capture PASS/FAIL. | fixture |
| M03 | JSON artifact extraction | M02 | chunk-m03 | machine-checkable | M02 | Run `python scripts/repair_campaign_manifest.py --fixture tests/fixtures/service_split/v1/campaign-3.json --preview` and capture PASS/FAIL. | fixture |

## Chunks
| chunk-slug | milestone-id | model-routing | reference-pack-entitlement |
| :-- | :-- | :-- | :-- |
| chunk-m01 | M01 | codex | contracts, glossary |
| chunk-m02 | M02 | codex | contracts, glossary |
| chunk-m03 | M03 | codex | contracts, glossary |

## Verification Manifest
| check-id | milestone-id | execution-scope | prerequisites | mode | procedure |
| :-- | :-- | :-- | :-- | :-- | :-- |
| chk-m01-first | M01 | integration | none | machine-checkable | Run an end-to-end check with `pwsh -NoProfile -File tests/noisy.ps1`. |
| chk-m01 | M01 | integration | none | machine-checkable | Run `pwsh -NoProfile -File tests/noisy.ps1` and capture PASS/FAIL. |
| chk-m02 | M02 | integration | M01 | machine-checkable | Run `pwsh -NoProfile -File tests/slow.ps1` and capture PASS/FAIL. |
| chk-m03 | M03 | integration | M02 | machine-checkable | Run `python scripts/repair_campaign_manifest.py --fixture tests/fixtures/service_split/v1/campaign-3.json --preview` and capture PASS/FAIL. |

## Dependency Graph (Mermaid)
```mermaid
graph TD
  M01 --> M02
  M02 --> M03
```

## Sequential Gantt (Mermaid)
```mermaid
gantt
  title Fixture
  dateFormat X
  section Build
  M01 :m01, 0, 1
  M02 :m02, after m01, 1
```
'@

    # Multi-check load-bearing evidence must include the first check rather than
    # only the last row, and common production/cutover wording must classify.
    $loadJson = & pwsh -NoProfile -File (Join-Path $scriptDir 'identify-load-bearing.ps1') -RoadmapPath $roadmap -Json
    $load = $loadJson | ConvertFrom-Json
    Assert-True ($load.load_bearing_milestones -contains 'M01') "first of multiple verification rows was missed"
    Assert-True ($load.load_bearing_milestones -contains 'M02') "cutover milestone was missed"

    # High-volume stdout+stderr must complete without pipe deadlock and execute
    # the named command exactly once.
    $verifyJson = & pwsh -NoProfile -File (Join-Path $scriptDir 'verify-milestone-acceptance.ps1') `
        -RoadmapPath $roadmap -MilestoneId M01 -WorkingTree $workingTree -RunTests -CommandTimeoutMs 30000 -Json
    Assert-True ($LASTEXITCODE -eq 0) "high-volume verifier failed"
    $verify = $verifyJson | ConvertFrom-Json
    Assert-True ($verify.status -eq 'PASS') "high-volume verifier did not PASS"
    Assert-True ($verify.commands_named.Count -eq 1) "verifier ran a duplicate command"
    Assert-True (-not $verify.command_results[0].timed_out) "high-volume verifier timed out"

    # The gate's inline extractor must preserve a JSON fixture path exactly; a
    # shared-helper-only assertion would not prevent the synchronized copy from
    # drifting back to the `.js` prefix bug.
    $jsonGateRaw = & pwsh -NoProfile -File (Join-Path $scriptDir 'verify-milestone-acceptance.ps1') `
        -RoadmapPath $roadmap -MilestoneId M03 -WorkingTree $workingTree -Json
    Assert-True ($LASTEXITCODE -eq 0) "JSON artifact inspection failed"
    $jsonGate = $jsonGateRaw | ConvertFrom-Json
    Assert-True ($jsonGate.status -eq 'INSPECT_ONLY') "JSON artifact inspection returned the wrong status"
    Assert-True ($jsonGate.artifacts_named -contains 'tests/fixtures/service_split/v1/campaign-3.json') "gate did not preserve the JSON fixture path"
    Assert-True (-not ($jsonGate.artifacts_named -contains 'tests/fixtures/service_split/v1/campaign-3.js')) "gate truncated the JSON fixture path to .js"
    Assert-True ($jsonGate.artifacts_missing.Count -eq 0) "gate reported a present JSON fixture as missing"

    # Timeout is bounded, recorded, and blocks acceptance.
    $timeoutJson = & pwsh -NoProfile -File (Join-Path $scriptDir 'verify-milestone-acceptance.ps1') `
        -RoadmapPath $roadmap -MilestoneId M02 -WorkingTree $workingTree -RunTests -CommandTimeoutMs 1000 -Json
    Assert-True ($LASTEXITCODE -eq 1) "timed-out verifier did not block"
    $timeout = $timeoutJson | ConvertFrom-Json
    Assert-True ([bool]$timeout.command_results[0].timed_out) "timeout provenance missing"

    # Final ledger renders stored acceptance and never fabricates implementation.
    $runFolder = Join-Path $tempRoot 'run'
    New-Item -ItemType Directory -Path $runFolder -Force | Out-Null
    $storedPass = [ordered]@{ milestone_id='M01'; status='PASS'; commit_sha=$workingSha; tests='1 fixture passed' } | ConvertTo-Json -Compress
    Write-Utf8 -Path (Join-Path $runFolder 'acceptance-rows.jsonl') -Content $storedPass
    Write-Utf8 -Path (Join-Path $runFolder 'build-decision-log.md') -Content @'
## M01
downgrade_approved_by: danny
rationale: Framework limitation accepted with visible evidence.
'@
    $ledgerOut = Join-Path $tempRoot 'ledger'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'build-acceptance-ledger.ps1') `
        -RoadmapPath $roadmap -WorkingTree $workingTree -OutDir $ledgerOut -RunFolder $runFolder *> $null
    Assert-True ($LASTEXITCODE -eq 1) "ledger should remain blocked for unstarted M02"
    $ledgerText = Get-Content -Raw -LiteralPath (Join-Path $ledgerOut 'build-acceptance-ledger.md')
    Assert-True ($ledgerText -match '\| M01 \| YES \| YES \| NO \| APPROVED_DOWNGRADE \|') "semantic approval on a machine PASS was not preserved"
    Assert-True ($ledgerText -match '\| M02 \| NO \| NO \| NO \| BLOCKED \|') "unstarted milestone was reported implemented"

    $storedMissingTests = [ordered]@{ milestone_id='M01'; status='PASS'; commit_sha=$workingSha } | ConvertTo-Json -Compress
    Write-Utf8 -Path (Join-Path $runFolder 'acceptance-rows.jsonl') -Content $storedMissingTests
    $missingTestsOut = Join-Path $tempRoot 'ledger-missing-tests'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'build-acceptance-ledger.ps1') `
        -RoadmapPath $roadmap -WorkingTree $workingTree -OutDir $missingTestsOut -RunFolder $runFolder *> $null
    $missingTestsLedger = Get-Content -Raw -LiteralPath (Join-Path $missingTestsOut 'build-acceptance-ledger.md')
    Assert-True ($missingTestsLedger -match '\| M01 \| YES \| NO \| NO \| BLOCKED \|') "stored PASS without test evidence was accepted"

    $stoppedPass = [ordered]@{ milestone_id='M01'; status='PASS_WITH_RUN_STOP'; commit_sha=$workingSha; tests='1 fixture passed'; run_stop_reason='attempt budget exhausted' } | ConvertTo-Json -Compress
    Write-Utf8 -Path (Join-Path $runFolder 'acceptance-rows.jsonl') -Content $stoppedPass
    $stoppedOut = Join-Path $tempRoot 'ledger-stopped-pass'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'build-acceptance-ledger.ps1') `
        -RoadmapPath $roadmap -WorkingTree $workingTree -OutDir $stoppedOut -RunFolder $runFolder *> $null
    $stoppedLedger = Get-Content -Raw -LiteralPath (Join-Path $stoppedOut 'build-acceptance-ledger.md')
    Assert-True ($stoppedLedger -match '\| M01 \| YES \| YES \| NO \| BLOCKED \|') "PASS_WITH_RUN_STOP was collapsed into a clean PASS"

    # A formatted-but-nonexistent SHA and status-only check cannot fabricate PASS.
    $fakeEvidence = '{"milestone_id":"M01","status":"PASS","commit_sha":"0123456789abcdef0123456789abcdef01234567","checks":[{"status":"PASS"}]}'
    Write-Utf8 -Path (Join-Path $runFolder 'acceptance-rows.jsonl') -Content $fakeEvidence
    $fakeOut = Join-Path $tempRoot 'ledger-fake-evidence'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'build-acceptance-ledger.ps1') `
        -RoadmapPath $roadmap -WorkingTree $workingTree -OutDir $fakeOut -RunFolder $runFolder *> $null
    $fakeLedger = Get-Content -Raw -LiteralPath (Join-Path $fakeOut 'build-acceptance-ledger.md')
    Assert-True ($fakeLedger -match '\| M01 \| NO \| NO \| NO \| BLOCKED \|') "fabricated commit/check evidence was accepted"

    # A per-check downgrade cannot disappear under an overall PASS row.
    $approvedCheck = [ordered]@{ milestone_id='M01'; status='PASS'; commit_sha=$workingSha; checks=@([ordered]@{name='semantic';status='APPROVED_DOWNGRADE';result='known limitation'}) } | ConvertTo-Json -Compress -Depth 5
    Write-Utf8 -Path (Join-Path $runFolder 'acceptance-rows.jsonl') -Content $approvedCheck
    Write-Utf8 -Path (Join-Path $runFolder 'build-decision-log.md') -Content '# no approval'
    $unapprovedOut = Join-Path $tempRoot 'ledger-unapproved-check'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'build-acceptance-ledger.ps1') `
        -RoadmapPath $roadmap -WorkingTree $workingTree -OutDir $unapprovedOut -RunFolder $runFolder *> $null
    $unapprovedLedger = Get-Content -Raw -LiteralPath (Join-Path $unapprovedOut 'build-acceptance-ledger.md')
    Assert-True ($unapprovedLedger -match '\| M01 \| YES \| YES \| NO \| BLOCKED \|') "per-check downgrade disappeared into PASS"

    # Fresh-process intake must not depend on ambient LASTEXITCODE or cwd and must
    # emit the corrected branch contract.
    $intakeOut = Join-Path $tempRoot 'intake'
    $intakeJson = & pwsh -NoProfile -File (Join-Path $scriptDir 'intake-dry-run.ps1') `
        -RepoPath $repoRoot -RoadmapPath $roadmap -OutputDirectory $intakeOut -RunId fixture-run -Json
    Assert-True ($LASTEXITCODE -eq 0) "fresh-process intake failed: $($intakeJson -join ' ')"
    $planText = Get-Content -Raw -LiteralPath (Join-Path $intakeOut 'fixture-run\build-plan.md')
    Assert-True ($planText -match 'integration_branch: build/fixture-run') "intake emitted wrong integration branch"
    Assert-True ($planText -match 'merge_target: main') "intake retained stale dev default"
    & pwsh -NoProfile -File (Join-Path $scriptDir 'intake-dry-run.ps1') `
        -RepoPath $repoRoot -RoadmapPath $roadmap -OutputDirectory $intakeOut -RunId protected `
        -IntegrationBranch main -MergeTarget main -UseExistingIntegrationBranch *> $null
    Assert-True ($LASTEXITCODE -ne 0) "intake allowed the protected merge target as integration branch"
    & pwsh -NoProfile -File (Join-Path $scriptDir 'intake-dry-run.ps1') `
        -RepoPath $repoRoot -RoadmapPath $roadmap -OutputDirectory $intakeOut -RunId missing-resume `
        -ResumeRunId missing-resume *> $null
    Assert-True ($LASTEXITCODE -ne 0) "resume allowed a missing integration branch state carrier"

    # The disjoint integration/chunk namespace must be creatable in real Git and
    # support the same compare-and-swap update dt-build performs per milestone.
    $gitFixture = Join-Path $tempRoot 'git-fixture'
    New-Item -ItemType Directory -Path $gitFixture -Force | Out-Null
    & git -C $gitFixture init -q
    & git -C $gitFixture config user.email 'fixture@example.invalid'
    & git -C $gitFixture config user.name 'Fixture'
    Write-Utf8 -Path (Join-Path $gitFixture 'base.txt') -Content 'base'
    & git -C $gitFixture add base.txt
    & git -C $gitFixture commit -q -m 'base'
    & git -C $gitFixture branch -M main
    $baseSha = (& git -C $gitFixture rev-parse HEAD).Trim()
    & pwsh -NoProfile -File (Join-Path $scriptDir 'prepare-integration-branch.ps1') `
        -RepoPath $gitFixture -IntegrationBranch 'build/fixture-run' -MergeTarget main *> $null
    Assert-True ($LASTEXITCODE -eq 0) "integration branch preparer failed"
    & git -C $gitFixture checkout -q -b 'dt-build/fixture-run/m01-chunk' $baseSha
    Write-Utf8 -Path (Join-Path $gitFixture 'chunk.txt') -Content 'chunk'
    & git -C $gitFixture add chunk.txt
    & git -C $gitFixture commit -q -m 'chunk'
    $chunkSha = (& git -C $gitFixture rev-parse HEAD).Trim()
    Push-Location $gitFixture
    try {
        & pwsh -NoProfile -File (Join-Path $scriptDir 'branch-cas-update.ps1') `
            -SourceRef 'dt-build/fixture-run/m01-chunk' -ExpectedTargetSha $baseSha `
            -TargetBranch 'build/fixture-run' -Json *> $null
        Assert-True ($LASTEXITCODE -eq 0) "CAS failed on corrected branch topology"
    }
    finally { Pop-Location }
    Assert-True (((& git -C $gitFixture rev-parse 'build/fixture-run').Trim()) -eq $chunkSha) "CAS did not advance integration branch"

    Push-Location $gitFixture
    try {
        & pwsh -NoProfile -File (Join-Path $scriptDir 'branch-cas-update.ps1') `
            -SourceRef 'dt-build/fixture-run/m01-chunk' -ExpectedTargetSha $baseSha -TargetBranch main -Json *> $null
        Assert-True ($LASTEXITCODE -ne 0) "CAS mutator allowed a protected branch"
    }
    finally { Pop-Location }

    # Parameter binding enforces the two-automatic-attempt cap.
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') `
        -ProjectPath $workingTree -Preflight -Attempt 3 *> $null
    Assert-True ($LASTEXITCODE -ne 0) "Codex wrapper accepted automatic attempt 3"

    # Wrapper validates report shape, redacts retained output, and preserves
    # failure provenance even when a child never reads stdin.
    $fixtureCodexHome = Join-Path $tempRoot 'codex-home'
    New-Item -ItemType Directory -Path $fixtureCodexHome -Force | Out-Null
    Write-Utf8 -Path (Join-Path $fixtureCodexHome 'models_cache.json') -Content '{"fetched_at":"fixture","models":[{"slug":"gpt-6.1-sol","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}]}]}'
    Write-Utf8 -Path (Join-Path $fixtureCodexHome 'auth.json') -Content '{"auth_mode":"fixture"}'
    $env:CODEX_HOME = $fixtureCodexHome
    $fakeCodex = Join-Path $tempRoot 'fake-codex.ps1'
    Write-Utf8 -Path $fakeCodex -Content @'
if ($args -contains '--version') { Write-Output 'codex-cli fixture'; exit 0 }
if ($args -contains 'debug') { Get-Content -Raw -LiteralPath (Join-Path $env:CODEX_HOME 'models_cache.json'); exit 0 }
if ($env:DT_FAKE_CODEX_ARGS) { [IO.File]::WriteAllText($env:DT_FAKE_CODEX_ARGS, ($args -join '|')) }
$outIndex = [Array]::IndexOf([object[]]$args, '--output-last-message')
$outPath = if ($outIndex -ge 0) { [string]$args[$outIndex + 1] } else { '' }
$mode = [string]$env:DT_FAKE_CODEX_MODE
if ($mode -eq 'hang') { Start-Sleep -Seconds 10; exit 0 }
$receivedPrompt=[Console]::In.ReadToEnd()
if($env:DT_FAKE_UNICODE_PROMPT){[IO.File]::WriteAllText($env:DT_FAKE_UNICODE_PROMPT,$receivedPrompt)}
if ($mode -eq 'preflight') { [System.IO.File]::WriteAllText($outPath, 'OK'); exit 0 }
if ($mode -eq 'malformed') { [System.IO.File]::WriteAllText($outPath, 'I cannot do that.'); exit 0 }
$report = @"
DT_BUILD_REPORT_VERSION: 2
RUN_ID: fixture-run
chunk_id: fixture-chunk
attempt: 1
CHANGED_FILES:
NONE
COMMANDS_AND_RESULTS:
NONE
UNRESOLVED_BLOCKERS:
NONE
DISCOVERED_ENHANCEMENTS:
NONE
credential: ghp_abcdefghijklmnopqrstuvwxyz123456
"@
[System.IO.File]::WriteAllText($outPath, $report)
if($env:DT_FAKE_UNICODE_TEXT){
    [IO.File]::AppendAllText($outPath,"`n"+$env:DT_FAKE_UNICODE_TEXT)
    [Console]::WriteLine($env:DT_FAKE_UNICODE_TEXT)
    [Console]::Error.WriteLine($env:DT_FAKE_UNICODE_TEXT)
}
[Console]::Error.WriteLine('stream ghp_abcdefghijklmnopqrstuvwxyz123456')
'@
    $wrapperPrompt = Join-Path $tempRoot 'wrapper-prompt.md'
    Write-Utf8 -Path $wrapperPrompt -Content "RUN_ID: fixture-run`nchunk_id: fixture-chunk`nattempt: 1`nfixture"
    $wrapperOutput = Join-Path $tempRoot 'wrapper-output.md'
    $env:DT_FAKE_CODEX_MODE = 'success'
    $missingReasonOutput = Join-Path $tempRoot 'wrapper-missing-reason.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $missingReasonOutput `
        -CodexCliPath $fakeCodex -Tier standard -Effort medium -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0) "Codex wrapper allowed a substantive dispatch without -SelectionReason"
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $missingReasonOutput `
        -CodexCliPath $fakeCodex -Tier standard -Effort medium -SelectionReason "line one`nline two" -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0) "Codex wrapper allowed a multiline -SelectionReason"
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $wrapperOutput `
        -CodexCliPath $fakeCodex -Tier standard -Effort medium -SelectionReason 'ordinary fixture implementation logic' -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -eq 0) "mock Codex success path failed"

    $tierOutput = Join-Path $tempRoot 'codex-tier-normalization.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $tierOutput -CodexCliPath $fakeCodex  -Category routine-coding -Effort low -Difficulty HARD -DifficultyReason 'interacting constraints' -SelectionReason 'tier fixture' -Json *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'Codex uppercase difficulty accepted'
    $tierProv = Get-Content -Raw -LiteralPath "$tierOutput.provenance.json" | ConvertFrom-Json
    Assert-True ($tierProv.difficulty -ceq 'hard' -and $tierProv.difficulty_reason -eq 'interacting constraints') 'Codex provenance normalizes uppercase difficulty'
    foreach ($invalid in @(@{Category='routine-coding';Difficulty='hard'}, @{Category='invalid-category';Difficulty='standard'})) {
        $badInputLog = Join-Path $tempRoot 'codex-bad-router-input.log'
        & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $tierOutput -CodexCliPath $fakeCodex  -Effort low -SelectionReason 'tier fixture' @invalid -Json *> $badInputLog
        Assert-True ($LASTEXITCODE -ne 0 -and (Get-Content -Raw -LiteralPath $badInputLog) -match 'CODEX_INVOKE_FAIL:') 'Codex router validation retains invocation failure prefix'
    }

    $retained = Get-Content -Raw -LiteralPath $wrapperOutput
    Assert-True ($retained -notmatch 'ghp_') "retained chunk output leaked a credential"
    Assert-True ($retained -match '\[REDACTED-SECRET\]') "retained chunk output was not redacted"
    $wrapperProv = Get-Content -Raw -LiteralPath "$wrapperOutput.provenance.json" | ConvertFrom-Json
    Assert-True ([string]$wrapperProv.selection_reason -eq 'ordinary fixture implementation logic') "Codex provenance omitted selection reason"
    Assert-True ([string]$wrapperProv.disclosure_line -match '^MODEL_SELECTION: fixture-chunk -> gpt-6\.1-sol \(routine-coding, effort medium\): ordinary fixture implementation logic; router: .+$') "Codex provenance omitted canonical disclosure line"

    $codexArgsLog = Join-Path $tempRoot 'codex-effort-args.txt'; $env:DT_FAKE_CODEX_ARGS = $codexArgsLog
    $lowCodexOutput = Join-Path $tempRoot 'codex-effort-low.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $lowCodexOutput -CodexCliPath $fakeCodex -Category routine-coding -Effort low -SelectionReason 'effort argument fixture' -Json *> $null
    Assert-True ($LASTEXITCODE -eq 0 -and (Get-Content -Raw -LiteralPath $codexArgsLog) -match 'model_reasoning_effort="low"') 'Codex passes explicit low effort to CLI'
    $lowCodexProv = Get-Content -Raw -LiteralPath "$lowCodexOutput.provenance.json" | ConvertFrom-Json
    Assert-True ($lowCodexProv.effort -eq 'low' -and $lowCodexProv.reasoning_effort -eq 'low' -and $lowCodexProv.disclosure_line -match 'effort low') 'Codex effort provenance and disclosure'
    $missingEffortLog = Join-Path $tempRoot 'codex-missing-effort.log'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $lowCodexOutput -CodexCliPath $fakeCodex -SelectionReason 'effort argument fixture' -Json *> $missingEffortLog
    Assert-True ($LASTEXITCODE -ne 0 -and (Get-Content -Raw -LiteralPath $missingEffortLog) -match '-Effort' -and @(Get-Content -LiteralPath $missingEffortLog).Count -eq 1) 'Codex missing -Effort fails closed with one line'
    Remove-Item Env:DT_FAKE_CODEX_ARGS

    $env:DT_FAKE_CODEX_MODE = 'preflight'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') -ProjectPath $workingTree -OutputPath (Join-Path $tempRoot 'codex-preflight.md') -CodexCliPath $fakeCodex -Category routine-coding -Preflight -Json *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'Codex preflight works without -Effort'

    $env:DT_FAKE_CODEX_MODE = 'malformed'
    $malformedOutput = Join-Path $tempRoot 'wrapper-malformed.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $malformedOutput `
        -CodexCliPath $fakeCodex -Tier standard -Effort medium -SelectionReason 'ordinary fixture implementation logic' -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0) "malformed Codex output was accepted"
    $malformedProv = Get-Content -Raw -LiteralPath "$malformedOutput.provenance.json" | ConvertFrom-Json
    Assert-True (-not [bool]$malformedProv.pass) "malformed-output failure provenance claimed PASS"

    $env:DT_FAKE_CODEX_MODE = 'hang'
    $hangPrompt = Join-Path $tempRoot 'wrapper-hang-prompt.md'
    Write-Utf8 -Path $hangPrompt -Content ("RUN_ID: fixture-run`nchunk_id: fixture-chunk`nattempt: 1`n" + ('x' * 2097152))
    $hangOutput = Join-Path $tempRoot 'wrapper-hang.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-codex-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $hangPrompt -OutputPath $hangOutput `
        -CodexCliPath $fakeCodex -Tier standard -Effort medium -SelectionReason 'ordinary fixture implementation logic' -Attempt 1 -TimeoutMs 1000 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0) "non-reading Codex child escaped timeout"
    $hangProv = Get-Content -Raw -LiteralPath "$hangOutput.provenance.json" | ConvertFrom-Json
    Assert-True (-not [bool]$hangProv.pass) "timeout failure provenance claimed PASS"
    Assert-True ([string]$hangProv.termination_reason -match 'TIMEOUT') "timeout failure provenance lacked termination reason"
    Remove-Item Env:DT_FAKE_CODEX_MODE -ErrorAction SilentlyContinue

    # Claude-lane wrapper mirrors the Codex wrapper contract: attempt cap,
    # report-shape validation, and redaction of retained output.
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') `
        -ProjectPath $workingTree -Preflight -Attempt 3 *> $null
    Assert-True ($LASTEXITCODE -ne 0) "Claude wrapper accepted automatic attempt 3"

    $fakeClaude = Join-Path $tempRoot 'fake-claude.ps1'
    Write-Utf8 -Path $fakeClaude -Content @'
if ($args -contains '--version') { Write-Output 'claude-cli fixture'; exit 0 }
if ($env:DT_FAKE_CLAUDE_ARGS) { [System.IO.File]::WriteAllText($env:DT_FAKE_CLAUDE_ARGS, ($args -join '|')) }
$receivedPrompt=[Console]::In.ReadToEnd()
if($env:DT_FAKE_UNICODE_PROMPT){[IO.File]::WriteAllText($env:DT_FAKE_UNICODE_PROMPT,$receivedPrompt)}
$mode = [string]$env:DT_FAKE_CLAUDE_MODE
$ranModel = if ($mode -eq 'wrongmodel') { 'claude-haiku-4-5-20251001' } else { 'claude-sonnet-5' }
function Write-Envelope([string]$Text) {
    if ($mode -like 'stamped*') { $Text = '[10:52:50] ' + $Text }
    $usage = [ordered]@{}; $usage[$ranModel] = @{ inputTokens = 10; outputTokens = 20; costUSD = 0.01 }
    Write-Output (@{ type = 'result'; is_error = $false; result = $Text; total_cost_usd = 0.01; modelUsage = $usage } | ConvertTo-Json -Depth 5 -Compress)
}
if ($mode -eq 'malformed') { Write-Envelope 'I cannot do that.'; exit 0 }
if ($mode -eq 'preflight') { Write-Envelope 'OK'; exit 0 }
if ($mode -eq 'stamped-preflight') { Write-Envelope 'OK'; exit 0 }
if ($mode -eq 'rawtext') { Write-Output 'plain text, no envelope'; exit 0 }
$report = @"
DT_BUILD_REPORT_VERSION: 2
RUN_ID: fixture-run
chunk_id: fixture-chunk
attempt: 1
CHANGED_FILES:
NONE
COMMANDS_AND_RESULTS:
NONE
UNRESOLVED_BLOCKERS:
NONE
DISCOVERED_ENHANCEMENTS:
NONE
credential: ghp_abcdefghijklmnopqrstuvwxyz123456
"@
if($env:DT_FAKE_UNICODE_TEXT){
    $report += "`n"+$env:DT_FAKE_UNICODE_TEXT
    [Console]::Error.WriteLine($env:DT_FAKE_UNICODE_TEXT)
}
Write-Envelope $report
'@
    $claudeOutput = Join-Path $tempRoot 'claude-wrapper-output.md'
    $env:DT_FAKE_CLAUDE_MODE = 'success'
    $claudeMissingReason = Join-Path $tempRoot 'claude-wrapper-missing-reason.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $claudeMissingReason `
        -ClaudeCliPath $fakeClaude -Model claude-sonnet-5 -Tier standard -Effort medium -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0) "Claude wrapper allowed a substantive dispatch without -SelectionReason"
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $claudeMissingReason `
        -ClaudeCliPath $fakeClaude -Model claude-sonnet-5 -Tier standard -Effort medium -SelectionReason "line one`nline two" -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0) "Claude wrapper allowed a multiline -SelectionReason"
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $claudeOutput `
        -ClaudeCliPath $fakeClaude -Model claude-sonnet-5 -Tier standard -Effort medium -SelectionReason 'ordinary fixture verification logic' -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -eq 0) "mock Claude success path failed"

    $tierOutput = Join-Path $tempRoot 'claude-tier-normalization.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $tierOutput -ClaudeCliPath $fakeClaude -Model claude-sonnet-5 -Category routine-coding -Effort low -Difficulty HARD -DifficultyReason 'interacting constraints' -SelectionReason 'tier fixture' -Json *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'Claude uppercase difficulty accepted'
    $tierProv = Get-Content -Raw -LiteralPath "$tierOutput.provenance.json" | ConvertFrom-Json
    Assert-True ($tierProv.difficulty -ceq 'hard' -and $tierProv.difficulty_reason -eq 'interacting constraints') 'Claude provenance normalizes uppercase difficulty'
    foreach ($invalid in @(@{Category='routine-coding';Difficulty='hard'}, @{Category='invalid-category';Difficulty='standard'})) {
        $badInputLog = Join-Path $tempRoot 'claude-bad-router-input.log'
        & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $tierOutput -ClaudeCliPath $fakeClaude -Model claude-sonnet-5 -Effort low -SelectionReason 'tier fixture' @invalid -Json *> $badInputLog
        Assert-True ($LASTEXITCODE -ne 0 -and (Get-Content -Raw -LiteralPath $badInputLog) -match 'CLAUDE_INVOKE_FAIL:') 'Claude router validation retains invocation failure prefix'
    }

    $claudeRetained = Get-Content -Raw -LiteralPath $claudeOutput
    Assert-True ($claudeRetained -notmatch 'ghp_') "retained Claude chunk output leaked a credential"
    Assert-True ($claudeRetained -match '\[REDACTED-SECRET\]') "retained Claude chunk output was not redacted"
    $claudeProv = Get-Content -Raw -LiteralPath "$claudeOutput.provenance.json" | ConvertFrom-Json
    Assert-True ([string]$claudeProv.selection_reason -eq 'ordinary fixture verification logic') "Claude provenance omitted selection reason"
    Assert-True ($claudeProv.effort -eq 'medium' -and $claudeProv.disclosure_line -match '^MODEL_SELECTION: fixture-chunk -> claude-sonnet-5 \(routine-coding, effort medium\): ordinary fixture verification logic; router: .+$') 'Claude effort provenance and full disclosure'
    $claudeProv.disclosure_line = $claudeProv.disclosure_line.Replace(', effort medium', '') # Preserve the existing legacy disclosure-structure assertion below.
    Assert-True ([string]$claudeProv.disclosure_line -match '^MODEL_SELECTION: fixture-chunk -> claude-sonnet-5 \(routine-coding\): ordinary fixture verification logic; router: .+$') "Claude provenance omitted canonical disclosure line"
    Assert-True ([string]$claudeProv.requested_model -eq 'claude-sonnet-5') "Claude provenance lost the router-requested model"
    Assert-True ([string]$claudeProv.resolved_model -eq 'claude-sonnet-5') "Claude provenance did not record the exact model version that ran"
    Assert-True (@($claudeProv.models_used).Count -eq 1 -and [string]@($claudeProv.models_used)[0].model -eq 'claude-sonnet-5') "Claude provenance omitted models_used"
    Assert-True ((Get-Content -Raw -LiteralPath "$claudeOutput.provenance.json") -match '"models_used":\s*\[') "Claude provenance models_used is not a JSON array"

    # A run whose reported model is outside the requested family, or whose output
    # carries no model report, fails closed with a provenance record.
    foreach ($badMode in @('wrongmodel', 'rawtext')) {
        $env:DT_FAKE_CLAUDE_MODE = $badMode
        $badOut = Join-Path $tempRoot "claude-wrapper-$badMode.md"
        & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') `
            -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $badOut `
            -ClaudeCliPath $fakeClaude -Model claude-sonnet-5 -Tier standard -Effort medium -SelectionReason 'ordinary fixture verification logic' -Attempt 1 -Json *> $null
        Assert-True ($LASTEXITCODE -ne 0) "Claude wrapper accepted $badMode output"
        $badProv = Get-Content -Raw -LiteralPath "$badOut.provenance.json" | ConvertFrom-Json
        Assert-True (-not [bool]$badProv.pass) "Claude $badMode provenance claimed PASS"
    }
    $env:DT_FAKE_CLAUDE_MODE = 'success'

    # Slim-session contract: no MCP servers, no Agent tool (blocks nested agents),
    # and -ReadOnly drops the file-writing tools for verifier/review chunks.
    $claudeArgsLog = Join-Path $tempRoot 'claude-args.txt'
    $env:DT_FAKE_CLAUDE_ARGS = $claudeArgsLog
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath (Join-Path $tempRoot 'claude-args-build.md') `
        -ClaudeCliPath $fakeClaude -Model claude-sonnet-5 -Tier standard -Effort medium -SelectionReason 'ordinary fixture implementation logic' -Attempt 1 -Json *> $null
    $buildArgs = Get-Content -Raw -LiteralPath $claudeArgsLog
    Assert-True ($buildArgs -match '--strict-mcp-config') "Claude wrapper did not disable MCP servers"
    Assert-True ($buildArgs -match '--tools\|Bash,Read,Edit,Write,Glob,Grep(\||$)') "Claude wrapper build tool list drifted"
    Assert-True ($buildArgs -notmatch 'Agent') "Claude wrapper exposed the Agent tool to a chunk"
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath (Join-Path $tempRoot 'claude-args-verify.md') `
        -ClaudeCliPath $fakeClaude -Model claude-sonnet-5 -Tier standard -Effort medium -ReadOnly -SelectionReason 'ordinary fixture verification logic' -Attempt 1 -Json *> $null
    $verifyArgs = Get-Content -Raw -LiteralPath $claudeArgsLog
    Assert-True ($verifyArgs -match '--tools\|Bash,Read,Glob,Grep(\||$)') "Claude wrapper -ReadOnly still exposed write tools"
    $lowClaudeOutput = Join-Path $tempRoot 'claude-effort-low.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $lowClaudeOutput -ClaudeCliPath $fakeClaude -Model claude-sonnet-5 -Category routine-coding -Effort low -SelectionReason 'effort argument fixture' -Json *> $null
    Assert-True ($LASTEXITCODE -eq 0 -and (Get-Content -Raw -LiteralPath $claudeArgsLog) -match '--model\|claude-sonnet-5\|--effort\|low(\||$)') 'Claude passes explicit low effort beside model to CLI'
    $lowClaudeProv = Get-Content -Raw -LiteralPath "$lowClaudeOutput.provenance.json" | ConvertFrom-Json
    Assert-True ($lowClaudeProv.effort -eq 'low' -and $lowClaudeProv.disclosure_line -match 'effort low') 'Claude low effort provenance and disclosure'
    $missingEffortLog = Join-Path $tempRoot 'claude-missing-effort.log'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $lowClaudeOutput -ClaudeCliPath $fakeClaude -SelectionReason 'effort argument fixture' -Json *> $missingEffortLog
    Assert-True ($LASTEXITCODE -ne 0 -and (Get-Content -Raw -LiteralPath $missingEffortLog) -match '-Effort' -and @(Get-Content -LiteralPath $missingEffortLog).Count -eq 1) 'Claude missing -Effort fails closed with one line'
    Remove-Item Env:DT_FAKE_CLAUDE_ARGS -ErrorAction SilentlyContinue

    $env:DT_FAKE_CLAUDE_MODE = 'preflight'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') -ProjectPath $workingTree -OutputPath (Join-Path $tempRoot 'claude-preflight.md') -ClaudeCliPath $fakeClaude -Model claude-sonnet-5 -Category routine-coding -Preflight -Json *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'Claude preflight works without -Effort'
    $env:DT_FAKE_CLAUDE_MODE = 'stamped-preflight'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') -ProjectPath $workingTree -OutputPath (Join-Path $tempRoot 'claude-stamped-preflight.md') -ClaudeCliPath $fakeClaude -Model claude-sonnet-5 -Category routine-coding -Preflight -Json *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'timestamp-prefixed Claude OK passes preflight'
    $env:DT_FAKE_CLAUDE_MODE = 'stamped-report'
    $stampedOutput = Join-Path $tempRoot 'claude-stamped-report.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $stampedOutput -ClaudeCliPath $fakeClaude -Model claude-sonnet-5 -Category routine-coding -Effort medium -SelectionReason 'stamped report regression' -Json *> $null
    Assert-True ($LASTEXITCODE -eq 0 -and (Get-Content -Raw $stampedOutput) -match '\ADT_BUILD_REPORT_VERSION:') 'timestamp-prefixed Claude structured report parses and is retained without stamp'
    $env:DT_FAKE_CLAUDE_MODE = 'success'

    # Peers rely on inherited console defaults, just like installed PS1 shims.
    # Check the actual prompt received, retained final message and stderr on both lanes.
    $unicode='§ snow 雪 emoji 😀 Tibetan བོད་ quote " backslash \'
    $unicodePrompt=Join-Path $tempRoot 'unicode-prompt.md'
    $unicodePromptText="RUN_ID: fixture-run`nchunk_id: fixture-chunk`nattempt: 1`n"+$unicode+"`nline two`ttab"
    Write-Utf8 -Path $unicodePrompt -Content $unicodePromptText
    $priorUnicodeText=$env:DT_FAKE_UNICODE_TEXT;$priorUnicodePrompt=$env:DT_FAKE_UNICODE_PROMPT
    $unicodeResults=@()
    try {
        $env:DT_FAKE_UNICODE_TEXT=$unicode
        foreach($lane in @('codex','claude')) {
            $env:DT_FAKE_UNICODE_PROMPT=Join-Path $tempRoot "$lane-unicode-received.txt"
            $out=Join-Path $tempRoot "$lane-unicode-output.md"
            $cliArgs=if($lane -eq 'codex'){@('-CodexCliPath',$fakeCodex)}else{@('-ClaudeCliPath',$fakeClaude,'-Model','claude-sonnet-5')}
            $env:DT_FAKE_CODEX_MODE='success';$env:DT_FAKE_CLAUDE_MODE='success'
            & pwsh -NoProfile -File (Join-Path $scriptDir "invoke-$lane-chunk.ps1") -ProjectPath $workingTree -PromptPath $unicodePrompt -OutputPath $out -Category routine-coding -Effort medium -SelectionReason 'Unicode transport fixture' -Json @cliArgs *> $null
            $check=@{lane=$lane;success=($LASTEXITCODE -eq 0);prompt=((Get-Content -Raw $env:DT_FAKE_UNICODE_PROMPT) -ceq $unicodePromptText);answer=((Get-Content -Raw $out).Contains($unicode));stream=((Get-Content -Raw "$out.stream.log").Contains($unicode))}
            Write-Output "UNICODE: $lane success=$($check.success); prompt=$($check.prompt); answer=$($check.answer); stream=$($check.stream)"
            $unicodeResults+=$check
        }
        foreach($check in $unicodeResults){
            Assert-True $check.success "$($check.lane) Unicode wrapper invocation"
            Assert-True $check.prompt "$($check.lane) exact Unicode prompt received by default PS1 peer"
            Assert-True $check.answer "$($check.lane) exact Unicode final message retained"
            Assert-True $check.stream "$($check.lane) exact Unicode process stream retained"
        }
        # CommandWithArgs must preserve argv boundaries, literal shell syntax and
        # stdout/stderr and a nonzero CLI exit code.
        . (Join-Path $repoRoot 'scripts/invoke-codex-process.ps1')
        $argvPeer=Join-Path $tempRoot 'argv $ literal peer.ps1'
        Write-Utf8 -Path $argvPeer -Content @'
$prompt=[Console]::In.ReadToEnd()
[IO.File]::WriteAllText($env:DT_FAKE_UNICODE_PROMPT,$prompt)
[Console]::WriteLine((ConvertTo-Json -InputObject @($args) -Compress))
[Console]::Error.WriteLine($env:DT_FAKE_UNICODE_TEXT)
exit 7
'@
        $literalArgs=@('space value','quote " value',"single ' quote",$unicode,'literal $(throw "must not execute"); &','--flag')
        $argvResult=Invoke-CodexProcess -CodexPath $argvPeer -Arguments $literalArgs -Prompt $unicodePromptText -WorkingDirectory $workingTree -TimeoutMs 10000
        Assert-True ($argvResult.exit_code -eq 7 -and -not $argvResult.timed_out) 'UTF8 PS1 bootstrap preserves explicit CLI exit code'
        Assert-True ($argvResult.stdout.Trim() -ceq (ConvertTo-Json -InputObject $literalArgs -Compress)) 'UTF8 PS1 bootstrap preserves spaced, quoted, Unicode and literal shell arguments'
        Assert-True ((Get-Content -Raw $env:DT_FAKE_UNICODE_PROMPT) -ceq $unicodePromptText) 'shared Codex process PS1 Unicode prompt exact'
        Assert-True ($argvResult.stderr.Trim() -ceq $unicode) 'shared Codex process PS1 Unicode stderr exact'
        Write-Utf8 -Path $argvPeer -Content "throw 'fixture terminating error'"
        $thrown=Invoke-CodexProcess -CodexPath $argvPeer -Arguments @('--flag') -Prompt '' -WorkingDirectory $workingTree -TimeoutMs 10000
        Assert-True ($thrown.exit_code -eq 1 -and $thrown.stderr.Contains('fixture terminating error')) 'UTF8 PS1 bootstrap preserves terminating script failure'
    } finally {$env:DT_FAKE_UNICODE_TEXT=$priorUnicodeText;$env:DT_FAKE_UNICODE_PROMPT=$priorUnicodePrompt}

    # Pin the wrapper result consumed by the retry rule on both lanes. All
    # diagnosis, clock, sleep, CLI and alert operations use temp-only fixtures.
    $failureCli = Join-Path $tempRoot 'diagnosed-failure-cli.ps1'
    Write-Utf8 -Path $failureCli -Content @'
if ($args -contains '--version') { Write-Output 'fixture-cli'; exit 0 }
if ($args -contains 'debug') { Get-Content -Raw (Join-Path $env:CODEX_HOME 'models_cache.json'); exit 0 }
[void][Console]::In.ReadToEnd()
[Console]::Error.WriteLine('fixture vendor server error')
exit 1
'@
    $dispatchSeams = Join-Path $tempRoot 'diagnosed-failure-seams.ps1'
    Write-Utf8 -Path $dispatchSeams -Content @'
$script:fixtureClock = [datetimeoffset]'2030-01-01T00:00:00Z'
$script:RouterDiagnosisClock = { $script:fixtureClock }
$script:RouterDispatchSleep = { param([int]$Milliseconds) $script:fixtureClock = $script:fixtureClock.AddMilliseconds($Milliseconds) }
$script:RouterDiagnosisDns = { param($ApiHost) $env:DT_BUILD_TEST_VERDICT -ne 'offline' }
$script:RouterDiagnosisHttp = {
    param($Uri)
    if ($Uri -like '*connecttest*') {
        if ($env:DT_BUILD_TEST_VERDICT -eq 'offline') { throw 'fixture offline' }
        return 'connected'
    }
    if ($Uri -like '*unresolved*') { return [pscustomobject]@{ incidents = @([pscustomobject]@{ id = 'fixture-incident'; components = @([pscustomobject]@{ id = 'component' }) }) } }
    $config = Get-Content -Raw (Join-Path $repoRoot 'references/model-router/vendor-status.json') | ConvertFrom-Json
    $lane = if ($Uri -eq $config.codex.components_url) { $config.codex } else { $config.claude }
    return [pscustomobject]@{ components = @($lane.components | ForEach-Object { [pscustomobject]@{ name = $_; id = 'component'; status = $(if ($env:DT_BUILD_TEST_VERDICT -eq 'vendor_incident') { 'degraded_performance' } else { 'operational' }) } }) }
}
'@
    $savedDispatchSeams = $env:DT_BUILD_DISPATCH_SEAMS
    $savedTestVerdict = $env:DT_BUILD_TEST_VERDICT
    try {
        $env:DT_BUILD_DISPATCH_SEAMS = $dispatchSeams
        foreach ($lane in @('codex','claude')) {
            foreach ($verdict in @('offline','vendor_incident','unexplained')) {
                Remove-Item (Join-Path $routerState 'vendor-status-cache.json'),(Join-Path $routerState 'vendor-blocks.json') -Force -ErrorAction SilentlyContinue
                $env:DT_BUILD_TEST_VERDICT = $verdict
                $out = Join-Path $tempRoot "$lane-$verdict.md"
                $resultPath = Join-Path $tempRoot "$lane-$verdict.json"
                $errPath = Join-Path $tempRoot "$lane-$verdict.stderr"
                $cliArgs = if ($lane -eq 'codex') { @('-CodexCliPath', $failureCli) } else { @('-ClaudeCliPath', $failureCli) }
                & pwsh -NoProfile -File (Join-Path $scriptDir "invoke-$lane-chunk.ps1") `
                    -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $out `
                    -Category routine-coding -Effort medium -SelectionReason 'diagnosed failure contract fixture' `
                    -Attempt 1 -TimeoutMs 120000 -Json @cliArgs 1>$resultPath 2>$errPath
                Assert-True ($LASTEXITCODE -ne 0) "$lane $verdict fails the piece"
                $result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
                $prov = Get-Content -Raw -LiteralPath "$out.provenance.json" | ConvertFrom-Json
                $termination = 'ROUTER_' + $verdict.ToUpperInvariant()
                foreach ($record in @($result, $prov)) {
                    Assert-True ($record.termination_reason -ceq $termination) "$lane $verdict termination_reason contract: $($record.termination_reason)"
                    Assert-True ($record.failure_category -ceq 'environment' -and $record.diagnosis -ceq $verdict) "$lane $verdict environment and diagnosis contract"
                    if ($verdict -eq 'vendor_incident') {
                        $other = if ($lane -eq 'codex') { 'claude' } else { 'codex' }
                        Assert-True ($record.backup_pick.vendor -eq $other -and $record.backup_pick.model -and $record.backup_pick.effort) "$lane incident result carries usable other-vendor backup pick"
                    }
                }
            }
        }
    } finally {
        Remove-Item (Join-Path $routerState 'vendor-status-cache.json'),(Join-Path $routerState 'vendor-blocks.json') -Force -ErrorAction SilentlyContinue
        $env:DT_BUILD_DISPATCH_SEAMS = $savedDispatchSeams
        $env:DT_BUILD_TEST_VERDICT = $savedTestVerdict
    }

    # Every assembled prompt carries the standing context-discipline rules and
    # the checkpoint field; removing either silently restores unbounded builders.
    $assembler = Get-Content -Raw -LiteralPath (Join-Path $scriptDir 'assemble-codex-prompt.ps1')
    Assert-True ($assembler -match 'Do not spawn subagents') "assembled prompt lost the nested-agent ban"
    Assert-True ($assembler -match 'after about 100 tool calls') "assembled prompt lost the checkpoint rule"
    Assert-True ($assembler -match '(?m)^CONTINUATION_STATE:') "assembled report lost the CONTINUATION_STATE field"

    # Usage collector: an executed acceptance gate marks an orchestrator, a session
    # that only mentions the script does not, nested agents and unset models are
    # flagged, and a broken environment never fails the build.
    $usageHome = Join-Path $tempRoot 'usage-claude-home'
    $usageProject = Join-Path $usageHome 'projects\fixture-project'
    New-Item -ItemType Directory -Path (Join-Path $usageProject 'sess-orch\subagents') -Force | Out-Null
    $usageLine = {
        param($id, $block, $cacheRead)
        (@{ type = 'assistant'; timestamp = '2030-01-01T00:00:00Z'; message = @{ id = $id; model = 'claude-opus-5'
            usage = @{ input_tokens = 10; cache_creation_input_tokens = 0; cache_read_input_tokens = $cacheRead; output_tokens = 5 }
            content = @($block) } } | ConvertTo-Json -Depth 8 -Compress)
    }
    $gateCall = @{ type = 'tool_use'; name = 'Bash'; input = @{ command = 'pwsh -File scripts/verify-milestone-acceptance.ps1 -RoadmapPath r.md -MilestoneId M01 -WorkingTree .dt-build/fixture-usage-run' } }
    $mention = @{ type = 'tool_use'; name = 'Bash'; input = @{ command = 'echo "verify-milestone-acceptance.ps1", "write-build-state.ps1"' } }
    $spawn = @{ type = 'tool_use'; name = 'Agent'; input = @{ prompt = 'look around' } }
    Write-Utf8 -Path (Join-Path $usageProject 'sess-orch.jsonl') -Content (& $usageLine 'm1' $gateCall 400000)
    Write-Utf8 -Path (Join-Path $usageProject 'sess-orch\subagents\agent-builder.jsonl') -Content (& $usageLine 'm2' $spawn 1000)
    Write-Utf8 -Path (Join-Path $usageProject 'sess-mention.jsonl') -Content (& $usageLine 'm3' $mention 1000)
    $usageOut = Join-Path $tempRoot 'usage-out'
    $savedClaudeHome = $env:CLAUDE_CONFIG_DIR; $savedUsageCache = $env:DT_BUILD_USAGE_CACHE; $savedCodexHome = $env:CODEX_HOME
    try {
        $env:CLAUDE_CONFIG_DIR = $usageHome
        $env:DT_BUILD_USAGE_CACHE = Join-Path $tempRoot 'usage-cache'
        $env:CODEX_HOME = Join-Path $tempRoot 'usage-no-codex'
        $usageStdout = (& pwsh -NoProfile -File (Join-Path $scriptDir 'collect-usage.ps1') -OutDir $usageOut -Baseline '2029-01-01') -join "`n"
        Assert-True ($LASTEXITCODE -eq 0) "usage collector returned nonzero"
        $usageRows = @(Get-ChildItem -LiteralPath $usageOut -Filter 'usage-ledger-*.jsonl' | Get-Content | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True ($usageRows.Count -eq 1) "usage collector should keep only the session that executed a dt-build gate"
        Assert-True ([string]$usageRows[0].run_id -eq 'fixture-usage-run') "usage collector lost the run id"
        Assert-True ([int]$usageRows[0].nested_agents -eq 1) "usage collector missed a nested agent"
        Assert-True ($usageStdout -match 'DT_BUILD_USAGE_ALERT: fixture-usage-run .*context peaked at 400K; 1 nested agents') "usage collector did not alert on a new flagged run"
        Assert-True (Test-Path -LiteralPath (Join-Path $usageOut 'usage-dashboard.html')) "usage dashboard was not rendered"
        $usageAgain = (& pwsh -NoProfile -File (Join-Path $scriptDir 'collect-usage.ps1') -OutDir $usageOut -Baseline '2029-01-01') -join "`n"
        Assert-True ($usageAgain -notmatch 'DT_BUILD_USAGE_ALERT') "usage collector re-alerted on an already-seen flag"
    }
    finally {
        $env:CLAUDE_CONFIG_DIR = $savedClaudeHome; $env:DT_BUILD_USAGE_CACHE = $savedUsageCache; $env:CODEX_HOME = $savedCodexHome
    }

    $env:DT_FAKE_CLAUDE_MODE = 'malformed'
    $claudeMalformed = Join-Path $tempRoot 'claude-wrapper-malformed.md'
    & pwsh -NoProfile -File (Join-Path $scriptDir 'invoke-claude-chunk.ps1') `
        -ProjectPath $workingTree -PromptPath $wrapperPrompt -OutputPath $claudeMalformed `
        -ClaudeCliPath $fakeClaude -Model claude-sonnet-5 -Tier standard -Effort medium -SelectionReason 'ordinary fixture verification logic' -Attempt 1 -Json *> $null
    Assert-True ($LASTEXITCODE -ne 0) "malformed Claude output was accepted"
    $claudeMalformedProv = Get-Content -Raw -LiteralPath "$claudeMalformed.provenance.json" | ConvertFrom-Json
    Assert-True (-not [bool]$claudeMalformedProv.pass) "malformed Claude-output failure provenance claimed PASS"
    Remove-Item Env:DT_FAKE_CLAUDE_MODE -ErrorAction SilentlyContinue

    Write-Output 'PASS: dt-build regression suite'
    Write-Output "SUMMARY: $script:passed passed"
}
finally {
    if ($null -eq $originalCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    else { $env:CODEX_HOME = $originalCodexHome }
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = $originalClaudeCredentials
    $env:DT_MODEL_ROUTER_STATE = $originalRouterState
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $originalAlertTransport
    Remove-Item Env:DT_FAKE_CODEX_MODE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

exit 0
