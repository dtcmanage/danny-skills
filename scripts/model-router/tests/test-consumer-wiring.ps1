Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:passed = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Output "PASS: $Name"
}
function Write-Utf8([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$buildScripts = Join-Path $repoRoot 'skills/dt-build/scripts'
$saved = @{}
foreach ($name in @('DT_MODEL_ROUTER_STATE','DT_MODEL_ROUTER_ALERT_TRANSPORT','DT_MODEL_ROUTER_CODEX_SESSIONS','CODEX_HOME','DT_FAKE_CLAUDE_MODE','DT_FAKE_CODEX_MODE')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$temp = Join-Path $env:TEMP ('model-router-wiring-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$priorClaudeCredentials = $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS
$env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = Join-Path $temp 'missing-claude-credentials.json'

try {
    # Isolation: temp router state, fresh catalog-check stamp (no network), a fake alert
    # transport for child processes (no real alert can be sent), and an approved fixture roster.
    $state = Join-Path $temp 'state'
    New-Item -ItemType Directory -Path $state | Out-Null
    $env:DT_MODEL_ROUTER_STATE = $state
    $env:DT_MODEL_ROUTER_CODEX_SESSIONS = Join-Path $temp 'empty-sessions'
    New-Item -ItemType Directory -Path $env:DT_MODEL_ROUTER_CODEX_SESSIONS | Out-Null
    Write-Utf8 (Join-Path $state 'last-check.json') (@{ checked_at = (Get-Date).ToString('o') } | ConvertTo-Json)
    $transportLog = Join-Path $temp 'transport.log'
    $fakeTransport = Join-Path $temp 'fake-transport.ps1'
    Write-Utf8 $fakeTransport @"
param(`$request)
Add-Content -LiteralPath '$transportLog' -Value ([string]`$request['kind'] + ' ' + [string]`$request['uri'])
if (`$request['kind'] -eq 'secret') { return 'fake-secret' }
if ([string]`$request['uri'] -like '*/oauth2/applications/@me') { return [pscustomobject]@{ owner = [pscustomobject]@{ id = '1' } } }
if ([string]`$request['uri'] -like '*/users/@me/channels') { return [pscustomobject]@{ id = 'dm' } }
return [pscustomobject]@{ id = 'fake-message' }
"@
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $fakeTransport
    function Get-TransportCount { if (Test-Path -LiteralPath $transportLog) { @(Get-Content -LiteralPath $transportLog).Count } else { 0 } }

    $rosterPath = Join-Path $state 'roster.json'
    $roster = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'references/model-router/default-roster.json') | ConvertFrom-Json -Depth 20
    $roster.approved = $true
    $roster.approved_at = '2026-09-28T00:00:00Z'
    Write-Utf8 $rosterPath ($roster | ConvertTo-Json -Depth 20)

    $levels = '"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}]'
    $codexHome = Join-Path $temp 'codex-home'
    $catalogJson = '{"fetched_at":"fixture","models":[' +
        '{"slug":"gpt-6-astra","visibility":"list","priority":1,"upgrade":null,"description":"Frontier intelligence.",' + $levels + '},' +
        '{"slug":"gpt-6.1-sol","visibility":"list","priority":2,"upgrade":null,' + $levels + '},' +
        '{"slug":"gpt-6-luna","visibility":"list","priority":3,"upgrade":null,' + $levels + '},' +
        '{"slug":"gpt-5.6-sol","visibility":"list","priority":4,"upgrade":null,' + $levels + '},' +
        '{"slug":"gpt-6-codex-spark","visibility":"list","priority":0,"upgrade":null,' + $levels + '}]}'
    Write-Utf8 (Join-Path $codexHome 'models_cache.json') $catalogJson
    Write-Utf8 (Join-Path $codexHome 'auth.json') '{"auth_mode":"fixture"}'
    $env:CODEX_HOME = $codexHome
    $cachePath = Join-Path $codexHome 'models_cache.json'

    # 1. Resolve-CodexModel delegates to the router; -Tier-only callers map as specified.
    . (Join-Path $repoRoot 'scripts/resolve-codex-model.ps1')
    . (Join-Path $repoRoot 'scripts/model-router/resolve-model.ps1')
    $map = @{ complex = 'complex-coding:True'; standard = 'routine-coding:False'; light = 'mechanical:False' }
    foreach ($tier in $map.Keys) { $m = ConvertTo-RouterCategoryFromTier -Tier $tier; Assert-True ("$($m.category):$($m.protected)" -eq $map[$tier]) "tier $tier maps to $($map[$tier])" }
    Assert-True ((Resolve-CodexModel -Tier complex -CachePath $cachePath -Strict) -eq 'gpt-6.1-sol') 'tier complex resolves complex-coding protected (strongest eligible)'
    Assert-True ((Resolve-CodexModel -Tier standard -CachePath $cachePath -Strict) -eq 'gpt-6.1-sol') 'tier standard resolves routine-coding through the approved roster'
    Assert-True ((Resolve-CodexModel -Tier light -CachePath $cachePath -Strict) -eq 'gpt-6-luna') 'tier light resolves mechanical through the approved roster'
    Assert-True ((Resolve-CodexModel -Category planning -CachePath $cachePath -Strict) -eq 'gpt-6.1-sol') 'category planning resolves through the approved roster'
    Assert-True ((Resolve-CodexModel -Category planning -Protected -CachePath $cachePath -Strict) -eq 'gpt-6.1-sol') 'category planning -Protected keeps the roster member'
    Assert-True ((Resolve-CodexModel -Category ui-frontend -CachePath $cachePath -Strict) -eq 'gpt-6.1-sol') 'category ui-frontend resolves through the router'
    Assert-True ((Resolve-CodexModel -Tier standard -PreferredModel 'gpt-6-astra' -CachePath $cachePath -Strict 3>$null) -eq 'gpt-6-astra') '-PreferredModel override honored'
    $threw = ''; try { [void](Resolve-CodexModel -Tier standard -PreferredModel 'gone-model' -CachePath $cachePath -Strict) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'not selectable') '-PreferredModel still selectable-checked under -Strict'
    $narrow = Join-Path $temp 'narrow-catalog.json'
    Write-Utf8 $narrow ('{"models":[{"slug":"gpt-5.6-sol","visibility":"list","priority":1,"upgrade":null,' + $levels + '}]}')
    $threw = ''; try { [void](Resolve-CodexModel -Tier standard -CachePath $narrow -Strict) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'not selectable') 'router pick the catalog cannot select fails closed under -Strict'
    $resolverText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/resolve-codex-model.ps1')
    $body = [regex]::Match($resolverText, '(?s)function Resolve-CodexModel \{.*?\n\}').Value
    Assert-True ($body -match 'Resolve-RouterModel' -and $body -notmatch '\$ladder\[') 'Resolve-CodexModel has no generation-ranking pick'

    $expected = @(
        @('routine-coding','gpt-6.1-sol','claude-opus-5-5','medium'),
        @('complex-coding','gpt-6.1-sol','claude-opus-5-5','medium'),
        @('ui-frontend','gpt-6.1-sol','claude-opus-5-5','medium'),
        @('mechanical','gpt-6-luna','claude-haiku-4-5-20251001','low'),
        @('code-review','gpt-6.1-sol','claude-opus-5-5','high'),
        @('planning','gpt-6.1-sol','claude-opus-5-5','high'),
        @('deep-research','gpt-6.1-sol','claude-opus-5-5','high'),
        @('math','gpt-6.1-sol','claude-opus-5-5','high'),
        @('analysis','gpt-6.1-sol','claude-opus-5-5','high'),
        @('long-form-writing','gpt-6.1-sol','claude-opus-5-5','medium'))
    foreach ($case in $expected) {
        foreach ($lane in @('codex','claude')) {
            $pick = Resolve-RouterModel -Category $case[0] -Lane $lane -SkipModelCheck
            $want = if ($lane -eq 'codex') { $case[1] } else { $case[2] }
            Assert-True ($pick.model -eq $want -and $pick.effort -eq $case[3] -and $pick.roster_source -eq 'state') "approved roster model and effort $($case[0])/$lane"
        }
    }
    $approvedRoster = Get-Content -LiteralPath $rosterPath -Raw
    Remove-Item -LiteralPath $rosterPath
    $fallbackPick = Resolve-RouterModel -Category routine-coding -Lane claude -SkipModelCheck
    Assert-True ($fallbackPick.model -eq 'claude-opus-5-5' -and $fallbackPick.effort -eq 'medium' -and $fallbackPick.roster_source -eq 'default' -and $fallbackPick.alerts -contains 'router-roster-missing') 'missing roster falls back to default with its alert'
    Write-Utf8 $rosterPath $approvedRoster

    # 2. Codex chunk wrapper: router pick, disclosure, provenance, escalation, override.
    $project = Join-Path $temp 'project'
    New-Item -ItemType Directory -Path $project | Out-Null
    & git -C $project init -q
    $prompt = Join-Path $temp 'prompt.md'
    Write-Utf8 $prompt "RUN_ID: wiring-run`nchunk_id: wiring-chunk`nattempt: 1`nfixture"
    $report = "DT_BUILD_REPORT_VERSION: 2`nRUN_ID: wiring-run`nchunk_id: wiring-chunk`nattempt: 1`nCHANGED_FILES:`nNONE`nCOMMANDS_AND_RESULTS:`nNONE`nUNRESOLVED_BLOCKERS:`nNONE`nDISCOVERED_ENHANCEMENTS:`nNONE"
    $fakeCodex = Join-Path $temp 'fake-codex.ps1'
    $launchLog = Join-Path $temp 'model-launches.log'
    Write-Utf8 $fakeCodex @"
if (`$args -contains '--version') { Write-Output 'codex-cli fixture'; exit 0 }
if (`$args -contains 'debug') { Get-Content -Raw -LiteralPath (Join-Path `$env:CODEX_HOME 'models_cache.json'); exit 0 }
[IO.File]::AppendAllText('$launchLog', "codex`n")
if (`$env:DT_FAKE_CODEX_MODE -eq 'limit') { [Console]::Error.WriteLine('ERROR: usage limit reached; try again at 2026-10-01T12:30:00Z'); exit 1 }
if (`$env:DT_FAKE_CODEX_MODE -eq 'source-text') { [Console]::Error.WriteLine('Failed to compile rate_limits/usage_limit.ps1: rate limiting middleware'); exit 1 }
`$outIndex = [Array]::IndexOf([object[]]`$args, '--output-last-message')
[void][Console]::In.ReadToEnd()
[IO.File]::WriteAllText([string]`$args[`$outIndex + 1], @'
$report
'@)
"@
    function Get-WrapperEffort([string[]]$Extra) {
        $categoryIndex = [Array]::IndexOf($Extra, '-Category')
        $tierIndex = [Array]::IndexOf($Extra, '-Tier')
        $category = if ($categoryIndex -ge 0) { $Extra[$categoryIndex + 1] } elseif ($tierIndex -ge 0) { (ConvertTo-RouterCategoryFromTier -Tier $Extra[$tierIndex + 1]).category } else { 'routine-coding' }
        $job = Get-RouterCategoryJob -Category $category
        # Wait-path image dispatches have no model effort; supply an explicit fixture value so the router wait is tested.
        if ($job -eq 'illustrator') { return 'low' }
        return [string]$roster.jobs.$job.first_effort
    }
    function Invoke-CodexWrapper([string]$Name, [string[]]$Extra, [switch]$OmitEffort) {
        $out = Join-Path $temp "$Name.md"
        $effortArgs = if ($OmitEffort) { @() } else { @('-Effort', (Get-WrapperEffort $Extra)) }
        & pwsh -NoProfile -File (Join-Path $buildScripts 'invoke-codex-chunk.ps1') -ProjectPath $project -PromptPath $prompt -OutputPath $out -CodexCliPath $fakeCodex -SelectionReason 'fixture reason' -Attempt 1 -Json @effortArgs @Extra *> $null
        $code = $LASTEXITCODE
        $prov = if (Test-Path -LiteralPath "$out.provenance.json") { Get-Content -Raw -LiteralPath "$out.provenance.json" | ConvertFrom-Json } else { $null }
        return [pscustomobject]@{ exit = $code; prov = $prov }
    }
    $missingEffort = Invoke-CodexWrapper 'codex-missing-effort' @('-Category','routine-coding') -OmitEffort
    Assert-True ($missingEffort.exit -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $temp 'codex-missing-effort.md'))) 'Codex substantive wrapper without -Effort fails closed'
    $r = Invoke-CodexWrapper 'codex-standard' @('-Tier','standard')
    Assert-True ($r.exit -eq 0 -and $r.prov.resolved_model -eq 'gpt-6.1-sol') 'codex wrapper -Tier standard resolves through the router'
    Assert-True ($r.prov.category -eq 'routine-coding' -and $r.prov.protected -eq $false -and $null -eq $r.prov.escalated_from) 'codex provenance carries category, protected, escalated_from'
    Assert-True ($r.prov.router_reason -and $null -eq $r.prov.router_table_source -and $null -eq $r.prov.router_table_date) 'codex provenance carries router reason and null retired table fields'
    Assert-True ($r.prov.disclosure_line -match '^MODEL_SELECTION: wiring-chunk -> gpt-6\.1-sol \(routine-coding, effort medium\): fixture reason; router: \S') 'codex disclosure line puts router reason after selection reason'
    $r = Invoke-CodexWrapper 'codex-escalate' @('-Category','complex-coding','-Protected','-EscalateFrom','gpt-6-luna')
    Assert-True ($r.exit -eq 0 -and $r.prov.resolved_model -eq 'gpt-6.1-sol' -and $r.prov.escalated_from -eq 'gpt-6-luna' -and $r.prov.protected -eq $true) 'codex wrapper -EscalateFrom moves one step up'
    Assert-True ($r.prov.disclosure_line -match '\(complex-coding, protected, escalated from gpt-6-luna, effort medium\)' -and $r.prov.router_reason -match 'Escalation') 'codex escalation disclosed'
    $r = Invoke-CodexWrapper 'codex-override' @('-Tier','standard','-Model','gpt-6-astra')
    Assert-True ($r.exit -eq 0 -and $r.prov.resolved_model -eq 'gpt-6-astra' -and $r.prov.router_reason -match '^Explicit -Model override') 'codex wrapper -Model override honored and disclosed'
    $r = Invoke-CodexWrapper 'codex-bad-override' @('-Tier','standard','-Model','gone-model')
    Assert-True ($r.exit -ne 0) 'codex wrapper unselectable -Model fails closed'
    $env:DT_FAKE_CODEX_MODE = 'limit'
    $r = Invoke-CodexWrapper 'codex-limit' @('-Tier','standard')
    Assert-True ($r.exit -ne 0 -and $r.prov.failure_category -eq 'environment' -and $r.prov.termination_reason -match '^ROUTER_LIMIT: codex ' -and $r.prov.vendor_block.vendor -eq 'codex') 'codex refusal records vendor block and environment failure'
    $env:DT_FAKE_CODEX_MODE = $null
    $r = Invoke-CodexWrapper 'codex-blocked-override' @('-Tier','standard','-Model','gpt-6-astra')
    Assert-True ($r.exit -ne 0 -and $r.prov.router_status -eq 'wait') 'blocked vendor stops explicit Codex override'
    Remove-Item -LiteralPath (Join-Path $state 'vendor-blocks.json')
    $env:DT_FAKE_CODEX_MODE = 'source-text'
    $r = Invoke-CodexWrapper 'codex-source-text' @('-Tier','standard')
    Assert-True ($r.exit -ne 0 -and $r.prov.failure_category -eq 'tooling' -and -not $r.prov.vendor_block) 'Codex failed output with limit identifiers does not block vendor'
    $env:DT_FAKE_CODEX_MODE = $null

    # 3. Claude chunk wrapper: router Claude lane, no fixed tier map.
    $fakeClaude = Join-Path $temp 'fake-claude.ps1'
    Write-Utf8 $fakeClaude @"
if (`$args -contains '--version') { Write-Output 'claude-cli fixture'; exit 0 }
[IO.File]::AppendAllText('$launchLog', "claude`n")
if (`$env:DT_FAKE_CLAUDE_MODE -eq 'limit') { [Console]::Error.WriteLine('You have reached your usage limit. Resets at 2026-10-01T15:00:00-04:00'); exit 1 }
if (`$env:DT_FAKE_CLAUDE_MODE -eq 'max-turns') { Write-Output (@{ type='result'; subtype='error_max_turns'; is_error=`$true; result='Source mentions rate limit reached'; modelUsage=@{} } | ConvertTo-Json -Compress); exit 0 }
if (`$env:DT_FAKE_CLAUDE_MODE -eq 'json-limit') { Write-Output (@{ type='result'; subtype='error_during_execution'; is_error=`$true; result='Claude AI usage limit reached|1790857800'; modelUsage=@{} } | ConvertTo-Json -Compress); exit 0 }
[void][Console]::In.ReadToEnd()
`$ran = [string]`$args[[Array]::IndexOf([object[]]`$args, '--model') + 1]
`$usage = [ordered]@{}; `$usage[`$ran] = @{ inputTokens = 1; outputTokens = 1; costUSD = 0.01 }
Write-Output (@{ type = 'result'; is_error = `$false; result = @'
$report
'@; total_cost_usd = 0.01; modelUsage = `$usage } | ConvertTo-Json -Depth 5 -Compress)
"@
    function Invoke-ClaudeWrapper([string]$Name, [string[]]$Extra, [switch]$OmitEffort) {
        $out = Join-Path $temp "$Name.md"
        $errPath = Join-Path $temp "$Name.stderr.txt"
        $effortArgs = if ($OmitEffort) { @() } else { @('-Effort', (Get-WrapperEffort $Extra)) }
        $stdout = @(& pwsh -NoProfile -File (Join-Path $buildScripts 'invoke-claude-chunk.ps1') -ProjectPath $project -PromptPath $prompt -OutputPath $out -ClaudeCliPath $fakeClaude -SelectionReason 'fixture reason' -Attempt 1 -Json @effortArgs @Extra 2>$errPath)
        $code = $LASTEXITCODE
        $prov = if (Test-Path -LiteralPath "$out.provenance.json") { Get-Content -Raw -LiteralPath "$out.provenance.json" | ConvertFrom-Json } else { $null }
        return [pscustomobject]@{ exit = $code; prov = $prov; stdout = ($stdout -join "`n"); stderr = (Get-Content -Raw -LiteralPath $errPath) }
    }
    $missingEffort = Invoke-ClaudeWrapper 'claude-missing-effort' @('-Category','routine-coding') -OmitEffort
    Assert-True ($missingEffort.exit -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $temp 'claude-missing-effort.md'))) 'Claude substantive wrapper without -Effort fails closed'
    $r = Invoke-ClaudeWrapper 'claude-standard' @('-Tier','standard')
    Assert-True ($r.exit -eq 0 -and $r.prov.requested_model -eq 'claude-opus-5-5' -and $r.prov.resolved_model -eq 'claude-opus-5-5') 'claude wrapper -Tier standard resolves through the router Claude lane'
    Assert-True ($r.prov.category -eq 'routine-coding' -and $r.prov.router_reason -and $null -eq $r.prov.router_table_source -and $null -eq $r.prov.router_table_date -and $r.prov.PSObject.Properties['escalated_from']) 'claude provenance carries router fields'
    Assert-True ($r.prov.disclosure_line -match '^MODEL_SELECTION: wiring-chunk -> claude-opus-5-5 \(routine-coding, effort medium\): fixture reason; router: \S') 'claude disclosure line puts router reason after selection reason'
    $r = Invoke-ClaudeWrapper 'claude-complex' @('-Tier','complex')
    Assert-True ($r.exit -eq 0 -and $r.prov.requested_model -eq 'claude-opus-5-5' -and $r.prov.protected -eq $true) 'claude wrapper -Tier complex maps to complex-coding protected'
    $r = Invoke-ClaudeWrapper 'claude-escalate' @('-Category','complex-coding','-EscalateFrom','claude-sonnet-5')
    Assert-True ($r.exit -eq 0 -and $r.prov.requested_model -eq 'claude-opus-5-5' -and $r.prov.escalated_from -eq 'claude-sonnet-5') 'claude wrapper -EscalateFrom moves one step up'
    $r = Invoke-ClaudeWrapper 'claude-override' @('-Category','planning','-Model','claude-fable-5-1')
    Assert-True ($r.exit -eq 0 -and $r.prov.requested_model -eq 'claude-fable-5-1' -and $r.prov.router_reason -match '^Explicit -Model override') 'claude wrapper -Model override honored and disclosed'
    $env:DT_FAKE_CLAUDE_MODE = 'limit'
    $r = Invoke-ClaudeWrapper 'claude-limit' @('-Tier','standard')
    Assert-True ($r.exit -ne 0 -and $r.prov.failure_category -eq 'environment' -and $r.prov.termination_reason -match '^ROUTER_LIMIT: claude ' -and $r.prov.vendor_block.vendor -eq 'claude') 'claude refusal records vendor block and environment failure'
    $env:DT_FAKE_CLAUDE_MODE = $null
    $r = Invoke-ClaudeWrapper 'claude-blocked-override' @('-Tier','standard','-Model','claude-fable-5-1')
    Assert-True ($r.exit -ne 0 -and $r.prov.router_status -eq 'wait') 'blocked vendor stops explicit Claude override'
    Remove-Item -LiteralPath (Join-Path $state 'vendor-blocks.json')
    $env:DT_FAKE_CLAUDE_MODE = 'max-turns'
    $r = Invoke-ClaudeWrapper 'claude-max-turns' @('-Tier','standard')
    Assert-True ($r.exit -ne 0 -and $r.prov.failure_category -eq 'tooling' -and -not $r.prov.vendor_block) 'Claude max-turns result mentioning rate limit does not block vendor'
    $env:DT_FAKE_CLAUDE_MODE = 'json-limit'
    $r = Invoke-ClaudeWrapper 'claude-json-limit' @('-Tier','standard')
    Assert-True ($r.exit -ne 0 -and $r.prov.failure_category -eq 'environment' -and $r.prov.vendor_block.vendor -eq 'claude') 'Claude JSON error result records vendor block'
    $env:DT_FAKE_CLAUDE_MODE = $null
    Remove-Item -LiteralPath (Join-Path $state 'vendor-blocks.json')
    $beforeSends = Get-TransportCount
    $validRoster = Get-Content -LiteralPath $rosterPath -Raw
    Write-Utf8 $rosterPath '{"schema_version":99}'
    $r = Invoke-ClaudeWrapper 'claude-review' @('-Category','code-review','-ReadOnly')
    Write-Utf8 $rosterPath $validRoster
    $parsed = $null; try { $parsed = $r.stdout | ConvertFrom-Json } catch { }
    Assert-True ($r.exit -eq 0 -and $r.prov.requested_model -eq 'claude-opus-5-5' -and $parsed -and $parsed.category -eq 'code-review') 'claude wrapper -Json keeps stdout one JSON object'
    Assert-True ($r.stderr -match 'ROUTER_ALERT: ' -and (Get-TransportCount) -gt $beforeSends) 'wrapper passes -SendAlerts and prints the ROUTER_ALERT line (fake transport)'
    Assert-True (([regex]::Matches($r.stderr, 'ROUTER_ALERT_TEST_TRANSPORT_ACTIVE')).Count -eq 1) 'test transport seam writes its stderr marker once per process'
    $claudeText = Get-Content -Raw -LiteralPath (Join-Path $buildScripts 'invoke-claude-chunk.ps1')
    Assert-True ($claudeText -notmatch "'(opus|sonnet|haiku)'" -and $claudeText -match 'Resolve-RouterModel -Category \$Category -Lane claude') 'claude wrapper has no fixed tier map'

    # Approved roster: both wrappers keep their lane member, and a wait launches no model.
    $categories = @(Get-RouterDispatchCategories)
    Assert-True ($categories.Count -eq 11 -and @(@('math','analysis') | Where-Object { $categories -notcontains $_ }).Count -eq 0) 'dispatch category list has all 11 including math and analysis'
    foreach ($category in $categories | Where-Object { $_ -ne 'image-generation' }) {
        $job = Get-RouterCategoryJob -Category $category
        $codexMember = if ($roster.jobs.$job.first_vendor -eq 'codex') { $roster.jobs.$job.first } else { $roster.jobs.$job.backup }
        $claudeMember = if ($roster.jobs.$job.first_vendor -eq 'claude') { $roster.jobs.$job.first } else { $roster.jobs.$job.backup }
        Assert-True ((Resolve-CodexModel -Category $category -CachePath $cachePath -Strict) -eq $codexMember) "Resolve-CodexModel accepts $category"
        $codexResult = Invoke-CodexWrapper "roster-codex-$category" @('-Category',$category)
        $claudeResult = Invoke-ClaudeWrapper "roster-claude-$category" @('-Category',$category)
        Assert-True ($codexResult.exit -eq 0 -and $codexResult.prov.resolved_model -eq $codexMember -and $codexResult.prov.job -eq $job -and $codexResult.prov.vendor -eq 'codex' -and $codexResult.prov.effort -eq $roster.jobs.$job.first_effort -and $codexResult.prov.disclosure_line -match ('effort ' + $roster.jobs.$job.first_effort)) "codex wrapper accepts $category and records roster job/vendor"
        Assert-True ($claudeResult.exit -eq 0 -and $claudeResult.prov.requested_model -eq $claudeMember -and $claudeResult.prov.job -eq $job -and $claudeResult.prov.vendor -eq 'claude' -and $claudeResult.prov.effort -eq $roster.jobs.$job.first_effort -and $claudeResult.prov.disclosure_line -match ('effort ' + $roster.jobs.$job.first_effort)) "claude wrapper accepts $category and records roster job/vendor"
    }
    $topCodex = Resolve-RouterModel -Category analysis -Lane codex -EscalateFrom gpt-6.1-sol -Catalog (Get-Content -Raw -LiteralPath $cachePath | ConvertFrom-Json)
    $topClaude = Resolve-RouterModel -Category analysis -Lane claude -EscalateFrom claude-opus-5-5
    Assert-True ($topCodex.model -eq 'gpt-6.1-sol' -and $topClaude.model -eq 'claude-opus-5-5') 'escalation stops at top non-frontier model on both lanes'
    $codexTop = Invoke-CodexWrapper 'codex-top' @('-Category','analysis','-EscalateFrom','gpt-6.1-sol')
    $claudeTop = Invoke-ClaudeWrapper 'claude-top' @('-Category','analysis','-EscalateFrom','claude-opus-5-5')
    Assert-True ($codexTop.exit -eq 0 -and $codexTop.prov.resolved_model -eq 'gpt-6.1-sol' -and $claudeTop.exit -eq 0 -and $claudeTop.prov.requested_model -eq 'claude-opus-5-5') 'wrappers cannot retry past top non-frontier model'
    $driftPath = Join-Path $state 'drift-marks.json'
    Write-Utf8 $driftPath (@(@{ job='coder'; model='gpt-6.1-sol' }, @{ job='coder'; model='claude-opus-5-5' }) | ConvertTo-Json -Depth 4)
    $codexDriftOverride = Invoke-CodexWrapper 'codex-drift-override' @('-Category','complex-coding','-Model','gpt-6-astra')
    $claudeDriftOverride = Invoke-ClaudeWrapper 'claude-drift-override' @('-Category','complex-coding','-Model','claude-fable-5-1')
    Assert-True ($codexDriftOverride.exit -eq 0 -and $codexDriftOverride.prov.resolved_model -eq 'gpt-6-astra' -and $claudeDriftOverride.exit -eq 0 -and $claudeDriftOverride.prov.requested_model -eq 'claude-fable-5-1') 'explicit overrides bypass constrained roster drift waits'
    Remove-Item -LiteralPath $driftPath
    $blockedUntil = [datetimeoffset]::UtcNow.AddHours(1).ToString('o')
    Write-Utf8 (Join-Path $state 'vendor-blocks.json') (@(
        @{ vendor='codex'; reset_at_utc=$blockedUntil },
        @{ vendor='claude'; reset_at_utc=$blockedUntil }
    ) | ConvertTo-Json -Depth 4)
    $launchesBefore = if (Test-Path -LiteralPath $launchLog) { @(Get-Content $launchLog).Count } else { 0 }
    foreach ($category in $categories) {
        $codexResult = Invoke-CodexWrapper "wait-codex-$category" @('-Category',$category)
        $claudeResult = Invoke-ClaudeWrapper "wait-claude-$category" @('-Category',$category)
        Assert-True ($codexResult.exit -ne 0 -and $codexResult.prov.router_status -eq 'wait' -and $codexResult.prov.failure_category -eq 'environment' -and $codexResult.prov.termination_reason -match '^ROUTER_WAIT: ' -and $codexResult.prov.job -eq (Get-RouterCategoryJob $category)) "codex wrapper accepts $category and fails closed on wait"
        Assert-True ($claudeResult.exit -ne 0 -and $claudeResult.prov.router_status -eq 'wait' -and $claudeResult.prov.failure_category -eq 'environment' -and $claudeResult.prov.termination_reason -match '^ROUTER_WAIT: ' -and $claudeResult.prov.job -eq (Get-RouterCategoryJob $category)) "claude wrapper accepts $category and fails closed on wait"
    }
    $launchesAfter = if (Test-Path -LiteralPath $launchLog) { @(Get-Content $launchLog).Count } else { 0 }
    Assert-True ($launchesAfter -eq $launchesBefore) 'blocked wrappers did not launch a model process'
    $imageResolverError = ''; try { [void](Resolve-CodexModel -Category image-generation -CachePath $cachePath -Strict) } catch { $imageResolverError = $_.Exception.Message }
    Assert-True ($imageResolverError -notmatch 'Unknown category' -and $imageResolverError -match 'No usable Codex model') 'Resolve-CodexModel accepts image-generation category'
    Remove-Item -LiteralPath (Join-Path $state 'vendor-blocks.json'), $rosterPath -Force
    $buildSkill = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'skills/dt-build/SKILL.md')
    Assert-True ($buildSkill -match 'resolve-model.ps1 -Category <c> -SendAlerts -Json' -and $buildSkill -match 'matching its returned' -and $buildSkill -notmatch 'Lane default: stay in the orchestrator') 'dt-build uses roster dispatch without family lane default'

    # 4. Other consumers pass their fixed categories.
    $reviewRound = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'skills/dt-review/scripts/invoke-codex-round.ps1')
    $reviewPreflight = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'skills/dt-review/scripts/preflight-codex.ps1')
    Assert-True ($reviewRound -match 'Resolve-CodexModel -Category planning' -and $reviewPreflight -match "if \(\`$Tier -eq 'light'\) \{ 'mechanical' \} else \{ 'planning' \}" -and $reviewPreflight -match 'Resolve-CodexModel -Category \$category') 'dt-review light preflight uses mechanical; other tiers and rounds use planning'
    $writing = Resolve-RouterModel -Category long-form-writing -Lane claude -SkipModelCheck
    Assert-True ($writing.protected -eq $true -and $writing.model -eq 'claude-opus-5-5') 'long-form-writing is protected by construction'
    foreach ($skill in @('dt-writing-draft','dt-writing-edit')) {
        Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $repoRoot "skills/$skill/SKILL.md")) -match '-Category long-form-writing') "$skill routes model dispatch as long-form-writing"
    }
    $image = Resolve-RouterModel -Category image-generation -Lane codex -SkipModelCheck
    $genImage = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'skills/dt-image-gen/scripts/gen-image.sh')
    Assert-True ($image.model -eq 'gpt-image-2' -and $genImage -match '-Category image-generation -Lane codex' -and $genImage -match 'engine stays gpt-image-2') 'dt-image-gen records the advisory image-generation pick'

    # 5. Alias mapping for host-native Agent dispatch.
    $aliases = @{ 'claude-opus-5-5' = 'opus'; 'claude-sonnet-5' = 'sonnet'; 'claude-haiku-4-5-20251001' = 'haiku'; 'claude-fable-5-1' = 'fable' }
    foreach ($id in $aliases.Keys) { Assert-True ((Get-RouterAgentAlias -Model $id) -eq $aliases[$id]) "alias $id -> $($aliases[$id])" }
    Assert-True ($null -eq (Get-RouterAgentAlias -Model 'gpt-6.1-sol')) 'non-Claude model has no Agent alias'
    $pick = Resolve-RouterModel -Category routine-coding -Lane claude -SkipModelCheck
    $codexPick = Resolve-RouterModel -Category routine-coding -Lane codex -SkipModelCheck -Catalog (Get-Content -Raw -LiteralPath $cachePath | ConvertFrom-Json)
    Assert-True ($pick.agent_alias -eq 'opus' -and $null -eq $codexPick.agent_alias) 'router result carries agent_alias on the Claude lane only'

    # 6. Frontier spend alert: 10 points, once per run.
    . (Join-Path $repoRoot 'scripts/model-router/check-frontier-spend.ps1')
    $script:spendRequests = [System.Collections.Generic.List[object]]::new()
    $fake = {
        param($request)
        $script:spendRequests.Add($request)
        if ($request['kind'] -eq 'secret') { return 'fake-secret' }
        if ([string]$request['uri'] -like '*/users/@me/channels') { return [pscustomobject]@{ id = 'dm' } }
        return [pscustomobject]@{ id = 'fake-message'; owner_id = '1' }
    }
    $start = (Get-Date).ToUniversalTime().AddHours(-1)
    function New-Rollout([string]$Path, [string]$Model, [object[]]$Readings) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add((@{ type = 'turn_context'; timestamp = $start.AddMinutes(-90).ToString('o'); payload = @{ model = $Model } } | ConvertTo-Json -Compress -Depth 6))
        foreach ($reading in $Readings) {
            $lines.Add((@{ type = 'event_msg'; timestamp = $start.AddMinutes($reading[0]).ToString('o'); payload = @{ type = 'token_count'; rate_limits = @{ primary = @{ used_percent = $reading[1]; window_minutes = 10080 } } } } | ConvertTo-Json -Compress -Depth 6))
        }
        Write-Utf8 $Path (($lines -join "`n") + "`n")
    }
    $spendCodex = Join-Path $temp 'spend-codex'
    New-Rollout (Join-Path $spendCodex 'sessions/2026/09/27/rollout-frontier.jsonl') 'gpt-6-astra' @(@(-30, 5), @(2, 24), @(4, 33))
    New-Rollout (Join-Path $spendCodex 'sessions/2026/09/27/rollout-sol.jsonl') 'gpt-6.1-sol' @(@(1, 20), @(3, 27))
    $emptyClaude = Join-Path $temp 'spend-claude-empty'
    New-Item -ItemType Directory -Path $emptyClaude | Out-Null
    $spend = Test-FrontierSpend -RunStartedAt $start -RunId 'run-a' -RemainingMilestones 3 -CodexHome $spendCodex -ClaudeHome $emptyClaude -Transport $fake 6>$null
    $spendPost = @($script:spendRequests | Where-Object { [string]$_['uri'] -like '*/messages' } | Select-Object -Last 1)
    Assert-True ($spendPost.Count -eq 1 -and [string]$spendPost[0]['body'] -match 'Remaining work: 3 milestone\(s\)' -and $spend.remaining_milestones -eq 3) 'frontier-spend alert message shows remaining work'
    Assert-True ($spend.codex.frontier_points -eq 10 -and $spend.codex.total_points -eq 13) 'codex frontier points attributed from rate_limits.primary.used_percent'
    $liveLog = Join-Path $spendCodex 'sessions/2026/09/27/rollout-frontier.jsonl'
    $writer = [IO.FileStream]::new($liveLog,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    try {
        $liveSpend = Get-RouterCodexFrontierSpend -Since ([datetimeoffset]$start) -CodexHome $spendCodex -Frontier (Get-RouterFrontierModels)
        Assert-True ($liveSpend.frontier_points -eq 10) 'frontier spend reads a Codex log held open for writing'
    } finally { $writer.Dispose() }
    Assert-True ($spend.alert_fired -and $spend.alert_key -eq 'frontier-spend:run-a' -and @($spend.lanes_over) -contains 'codex' -and $script:spendRequests.Count -gt 0) 'frontier-spend alert fires at 10 points'
    $count = $script:spendRequests.Count
    $again = Test-FrontierSpend -RunStartedAt $start -RunId 'run-a' -CodexHome $spendCodex -ClaudeHome $emptyClaude -Transport $fake 6>$null
    Assert-True (-not $again.alert_fired -and $again.alert.deduped -and $script:spendRequests.Count -eq $count) 'frontier-spend alert fires once per run'
    $lowCodex = Join-Path $temp 'spend-codex-low'
    New-Rollout (Join-Path $lowCodex 'sessions/2026/09/27/rollout-frontier.jsonl') 'gpt-6-astra' @(@(1, 20), @(2, 29))
    $low = Test-FrontierSpend -RunStartedAt $start -RunId 'run-b' -CodexHome $lowCodex -ClaudeHome $emptyClaude -Transport $fake 6>$null
    Assert-True ($low.codex.frontier_points -eq 9 -and -not $low.alert_fired -and $null -eq $low.alert -and $script:spendRequests.Count -eq $count) 'below 10 points no alert'
    $spendClaude = Join-Path $temp 'spend-claude'
    $message = { param($id, $model, $out, $minutes) @{ type = 'assistant'; timestamp = $start.AddMinutes($minutes).ToString('o'); message = @{ id = $id; model = $model; usage = @{ input_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = 0; output_tokens = $out } } } | ConvertTo-Json -Compress -Depth 6 }
    Write-Utf8 (Join-Path $spendClaude 'projects/p/session.jsonl') ((@(
        (& $message 'm1' 'claude-fable-5-1' 5000000 5), (& $message 'm1' 'claude-fable-5-1' 5000000 5),
        (& $message 'm2' 'claude-opus-5-5' 90000000 6), (& $message 'm0' 'claude-fable-5-1' 90000000 -10)) -join "`n") + "`n")
    $claudeSpend = Test-FrontierSpend -RunStartedAt $start -RunId 'run-c' -CodexHome (Join-Path $temp 'no-codex') -ClaudeHome $spendClaude -Transport $fake 6>$null
    Assert-True ($claudeSpend.claude.estimated_points -eq 10 -and @($claudeSpend.lanes_over) -contains 'claude' -and $claudeSpend.alert_fired) 'claude lane estimated from frontier weighted tokens'

    # 7. Acceptance ledger shows category and tolerates rows without it.
    $ledgerRepo = Join-Path $temp 'ledger-repo'
    New-Item -ItemType Directory -Path $ledgerRepo | Out-Null
    & git -C $ledgerRepo init -q
    & git -C $ledgerRepo config user.email 'fixture@example.invalid'
    & git -C $ledgerRepo config user.name 'Fixture'
    Write-Utf8 (Join-Path $ledgerRepo 'a.txt') 'a'
    & git -C $ledgerRepo add a.txt
    & git -C $ledgerRepo commit -q -m 'a'
    $sha = (& git -C $ledgerRepo rev-parse HEAD).Trim()
    $roadmap = Join-Path $temp 'roadmap.md'
    Write-Utf8 $roadmap "# Roadmap`n`n## Milestones`n`n| ID | Name |`n|----|------|`n| M01 | One |`n| M02 | Two |`n"
    $runFolder = Join-Path $temp 'run'
    Write-Utf8 (Join-Path $runFolder 'acceptance-rows.jsonl') ((@(
        ([ordered]@{ milestone_id = 'M01'; status = 'PASS'; commit_sha = $sha; tests = '1 passed'; category = 'complex-coding'; escalated = $true } | ConvertTo-Json -Compress),
        ([ordered]@{ milestone_id = 'M02'; status = 'PASS'; commit_sha = $sha; tests = '1 passed' } | ConvertTo-Json -Compress)) -join "`n") + "`n")
    $ledgerOut = Join-Path $temp 'ledger'
    & pwsh -NoProfile -File (Join-Path $buildScripts 'build-acceptance-ledger.ps1') -RoadmapPath $roadmap -WorkingTree $ledgerRepo -OutDir $ledgerOut -RunFolder $runFolder *> $null
    $ledgerMd = Get-Content -Raw -LiteralPath (Join-Path $ledgerOut 'build-acceptance-ledger.md')
    Assert-True ($LASTEXITCODE -eq 0 -and $ledgerMd -match '\| M01 \|[^\n]*category: complex-coding[^\n]*escalated: yes') 'ledger shows category and escalated when present'
    Assert-True ($ledgerMd -match '\| M02 \| YES \| YES \| YES \| PASS \|' -and ($ledgerMd -split "`n" | Where-Object { $_ -match '^\| M02 ' }) -notmatch 'category:') 'ledger tolerates rows without category'

    Write-Output "SUMMARY: $script:passed passed"
} finally {
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = $priorClaudeCredentials
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
