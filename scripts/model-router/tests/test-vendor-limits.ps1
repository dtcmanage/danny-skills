Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../vendor-limits.ps1')
. (Join-Path $PSScriptRoot '../resolve-model.ps1')
$script:passed = 0
function Assert-True { param([object]$Condition,[string]$Name) if (-not [bool]$Condition) { throw "FAIL: $Name" }; $script:passed++; Write-Output "PASS: $Name" }
$priorState = $env:DT_MODEL_ROUTER_STATE
$priorSessions = $env:DT_MODEL_ROUTER_CODEX_SESSIONS
$priorTransport = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
$temp = Join-Path $env:TEMP ('router-limits-' + [guid]::NewGuid().ToString('N'))
$state = Join-Path $temp 'state'
$sessions = Join-Path $temp 'sessions'
[IO.Directory]::CreateDirectory($state) | Out-Null
[IO.Directory]::CreateDirectory($sessions) | Out-Null
$env:DT_MODEL_ROUTER_STATE = $state
$env:DT_MODEL_ROUTER_CODEX_SESSIONS = $sessions
$transport = Join-Path $temp 'fake-transport.ps1'
Set-Content -LiteralPath $transport -Value 'param($request) return [pscustomobject]@{ id = "fake" }'
$env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $transport
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixtureCodexHome = Enter-RouterTestCodexHome
$priorClaudeCredentials = $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS
try {
    $codexIso = Test-RouterLimitRefusal -Vendor codex -Text 'ERROR: usage limit reached; try again at 2026-10-01T12:30:00Z.'
    Assert-True ($codexIso.refused -and $codexIso.reset_at_utc -eq '2026-10-01T12:30:00.0000000+00:00') 'Codex usage refusal parses try-again time'
    $codexEpoch = Test-RouterLimitRefusal -Vendor codex -Text 'rate_limit_exceeded: resets_at=1790857800'
    Assert-True ($codexEpoch.refused -and [datetimeoffset]$codexEpoch.reset_at_utc -eq [datetimeoffset]::FromUnixTimeSeconds(1790857800)) 'Codex rate limit parses epoch reset'
    $codexJson = Test-RouterLimitRefusal -Vendor codex -Text '{"error":"rate_limit_exceeded","resets_at":"2026-10-01T12:30:00Z"}'
    Assert-True ($codexJson.refused -and $codexJson.reset_at_utc -eq '2026-10-01T12:30:00.0000000+00:00') 'Codex JSON refusal parses quoted reset field'
    Assert-True ((Test-RouterLimitRefusal -Vendor codex -Text '{"type":"error","message":"rate limit reached; try again in 1 days 2 hours 3 minutes"}').refused) 'Codex final error event is a refusal'
    $claudeIso = Test-RouterLimitRefusal -Vendor claude -Text 'You have reached your usage limit. Resets at 2026-10-01T15:00:00-04:00'
    Assert-True ($claudeIso.refused -and $claudeIso.reset_at_utc -eq '2026-10-01T19:00:00.0000000+00:00') 'Claude usage refusal parses local offset'
    Assert-True ((Test-RouterLimitRefusal -Vendor claude -Text 'Usage limit reached.').refused) 'Claude refusal without reset uses default block duration'
    Assert-True (-not (Test-RouterLimitRefusal -Vendor codex -Text "failed output: rate_limits/usage_limit.ps1`nrate limiting middleware").refused) 'Codex transcript identifiers and rate limiting prose are not refusals'
    Assert-True (-not (Test-RouterLimitRefusal -Vendor claude -Text 'error_max_turns: result mentions rate limit in source text').refused) 'Claude max-turns result mentioning rate limit is not a refusal'
    $claudeEpoch = Test-RouterLimitRefusal -Vendor claude -Text 'Claude AI usage limit reached|1790857800'
    Assert-True ($claudeEpoch.refused -and [datetimeoffset]$claudeEpoch.reset_at_utc -eq [datetimeoffset]::FromUnixTimeSeconds(1790857800)) 'Claude pipe epoch reset parses'
    $codexRelative = Test-RouterLimitRefusal -Vendor codex -Text 'ERROR: usage limit reached; try again in 2 days 3 hours 4 minutes'
    Assert-True ($codexRelative.refused -and ([datetimeoffset]$codexRelative.reset_at_utc - [datetimeoffset]::UtcNow).TotalMinutes -gt 3059 -and ([datetimeoffset]$codexRelative.reset_at_utc - [datetimeoffset]::UtcNow).TotalMinutes -le 3064) 'Codex relative reset parses'
    Assert-True (-not (Test-RouterLimitRefusal -Vendor codex -Text 'Completed 100 requests successfully.').refused) 'ordinary output is not a limit refusal'
    # Wording the installed Codex CLI prints, and Claude API/CLI limit shapes.
    $codexHit = Test-RouterLimitRefusal -Vendor codex -Text ("ERROR: You" + [char]0x2019 + "ve hit your usage limit. Upgrade to Pro or try again in 4 days 2 hours.")
    Assert-True ($codexHit.refused -and ([datetimeoffset]$codexHit.reset_at_utc - [datetimeoffset]::UtcNow).TotalHours -gt 97.9 -and ([datetimeoffset]$codexHit.reset_at_utc - [datetimeoffset]::UtcNow).TotalHours -le 98.1) 'Codex hit-your-usage-limit message with partial relative reset'
    Assert-True ((Test-RouterLimitRefusal -Vendor codex -Text "ERROR: You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits").refused) 'Codex hit-your-usage-limit with ASCII apostrophe'
    $minutes = Test-RouterLimitRefusal -Vendor codex -Text "ERROR: You've hit your usage limit. Try again in 45 minutes."
    Assert-True ($minutes.refused -and ([datetimeoffset]$minutes.reset_at_utc - [datetimeoffset]::UtcNow).TotalMinutes -gt 44 -and ([datetimeoffset]$minutes.reset_at_utc - [datetimeoffset]::UtcNow).TotalMinutes -le 46) 'Codex minutes-only relative reset'
    Assert-True ((Test-RouterLimitRefusal -Vendor claude -Text 'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed the rate limit for your organization"}}').refused) 'Claude 429 rate_limit_error is a refusal'
    Assert-True ((Test-RouterLimitRefusal -Vendor claude -Text "5-hour limit reached - resets 3pm").refused) 'Claude 5-hour limit message is a refusal'
    Assert-True ((Test-RouterLimitRefusal -Vendor claude -Text "You've hit your limit - resets 3pm").refused) 'Claude hit-your-limit message is a refusal'
    Assert-True (-not (Test-RouterLimitRefusal -Vendor codex -Text 'ERROR: tests failed: test_rate_limit_exceeded_returns_429').refused) 'test identifiers containing rate_limit_exceeded are not refusals'
    $dated = Test-RouterLimitRefusal -Vendor codex -Text "ERROR: You've hit your usage limit. Upgrade to Pro or try again at Oct 2nd, 2027 3:04 PM."
    Assert-True ($dated.refused -and ([datetimeoffset]$dated.reset_at_utc).ToLocalTime().ToString('yyyy-MM-dd HH:mm') -eq '2027-10-02 15:04') 'Codex English dated reset parses as local time'
    $clockOnly = Test-RouterLimitRefusal -Vendor codex -Text "ERROR: You've hit your usage limit. Try again at 3:04 PM."
    $delta = ([datetimeoffset]$clockOnly.reset_at_utc - [datetimeoffset]::UtcNow).TotalHours
    Assert-True ($clockOnly.refused -and $delta -gt 0 -and $delta -le 24 -and ([datetimeoffset]$clockOnly.reset_at_utc).ToLocalTime().ToString('HH:mm') -eq '15:04') 'Codex clock-only reset is the next occurrence'
    Assert-True ((Test-RouterLimitRefusal -Vendor codex -Text 'ERROR: Your workspace is out of credits.').refused -and (Test-RouterLimitRefusal -Vendor codex -Text "ERROR: You've hit your spend cap set by the owner of your workspace.").refused) 'Codex workspace credit and spend-cap messages are refusals'
    Assert-True ($null -eq (Get-RouterCodexUsage) -and -not (Get-RouterVendorBlocked -Vendor codex)) 'no logs leave Codex available'
    $fixture = Join-Path $PSScriptRoot 'fixtures/codex-sessions/2026/09/28/rollout-usage.jsonl'
    $file = Join-Path $sessions '2026/09/28/rollout-usage.jsonl'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $file)) | Out-Null
    Copy-Item -LiteralPath $fixture -Destination $file
    $lines = [IO.File]::ReadAllLines($file)
    [IO.File]::WriteAllText($file,$lines[0] + "`n")
    $usage = Get-RouterCodexUsage
    Assert-True ($usage.used_percent -eq 94.9 -and $usage.source_file -eq $file -and $usage.observed_at_utc -eq '2026-09-28T10:00:00.0000000+00:00' -and -not (Get-RouterVendorBlocked -Vendor codex)) '94.9 percent parses and remains available'
    [IO.File]::AppendAllText($file,$lines[1] + "`n")
    Assert-True ((Get-RouterCodexUsage).used_percent -eq 95 -and (Get-RouterVendorBlocked -Vendor codex)) '95 percent blocks Codex'
    $stream = [IO.FileStream]::new($file,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    try { Assert-True ((Get-RouterCodexUsage).used_percent -eq 95) 'live writer does not prevent shared read' }
    finally { $stream.Dispose() }
    $row = $lines[1] | ConvertFrom-Json
    $row.payload.rate_limits.primary.resets_at = [datetimeoffset]::UtcNow.AddMinutes(-1).ToUnixTimeSeconds()
    [IO.File]::WriteAllText($file,($row | ConvertTo-Json -Compress -Depth 10) + "`n")
    Assert-True ((Get-RouterCodexUsage).used_percent -eq 0 -and -not (Get-RouterVendorBlocked -Vendor codex)) 'past reset zeroes usage'
    $older = Join-Path $sessions '2026/09/27/rollout-old.jsonl'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $older)) | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/codex-sessions/2026/09/27/rollout-old.jsonl') -Destination $older
    [IO.File]::SetLastWriteTimeUtc($older,[datetime]::UtcNow.AddHours(-1))
    [IO.File]::SetLastWriteTimeUtc($file,[datetime]::UtcNow)
    Assert-True ((Get-RouterCodexUsage).source_file -eq $file) 'newest log selected over older day'
    Remove-Item -LiteralPath $file,$older
    $reset = [datetimeoffset]::UtcNow.AddMinutes(30)
    $block = Add-RouterVendorBlock -Vendor claude -ResetAtUtc $reset -Reason 'limit refused'
    Assert-True ((Get-RouterVendorBlocked -Vendor claude) -and $block.reason -eq 'limit refused' -and [datetimeoffset]$block.reset_at_utc -eq $reset) 'refusal uses supplied reset time'
    $block = Add-RouterVendorBlock -Vendor claude -Reason 'no reset'
    $length = ([datetimeoffset]$block.reset_at_utc - [datetimeoffset]$block.blocked_at_utc).TotalSeconds
    Assert-True ($length -ge 3599 -and $length -le 3601) 'refusal without reset lasts one hour'
    $entries = @(Read-RouterJsonArray -Path (Join-Path $state 'vendor-blocks.json'))
    Assert-True ($entries.Count -eq 1 -and $entries[0].reason -eq 'no reset') 'new block replaces prior vendor entry'
    $null = Add-RouterVendorBlock -Vendor codex -ResetAtUtc ([datetimeoffset]::UtcNow.AddMinutes(-1)) -Reason 'expired'
    Assert-True (-not (Get-RouterVendorBlocked -Vendor codex)) 'expired block ignored'
    $null = Add-RouterVendorBlock -Vendor claude -Reason 'replacement'
    $entries = @(Read-RouterJsonArray -Path (Join-Path $state 'vendor-blocks.json'))
    Assert-True ($entries.Count -eq 1 -and $entries[0].reason -eq 'replacement') 'next write prunes expired blocks'
    $null = Add-RouterVendorBlock -Vendor claude -ResetAtUtc ([datetimeoffset]::UtcNow.AddMinutes(-1)) -Reason 'expired Claude'
    $catalog = [pscustomobject]@{ models=@([pscustomobject]@{slug='gpt-6-sol';visibility='list'}) }
    $null = Add-RouterVendorBlock -Vendor codex -Reason 'v1 Codex limit'
    $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Lane codex -Catalog $catalog
    Assert-True ($pick.status -eq 'wait' -and $null -eq $pick.model -and $pick.roster_source -eq 'default') 'pre-approval constrained blocked Codex waits'
    $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Catalog $catalog
    Assert-True ($pick.status -eq 'ok' -and $pick.vendor -eq 'claude') 'pre-approval blocked first choice uses backup'
    $pick = Resolve-RouterModel -SkipModelCheck -Category image-generation -Catalog $catalog
    Assert-True ($pick.status -eq 'wait' -and $null -eq $pick.model) 'pre-approval blocked image generation waits'
    $null = Add-RouterVendorBlock -Vendor claude -Reason 'v1 Claude limit'
    $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Catalog $catalog
    Assert-True ($pick.status -eq 'wait' -and $null -eq $pick.model) 'pre-approval both blocked waits'
    $null = Add-RouterVendorBlock -Vendor codex -ResetAtUtc ([datetimeoffset]::UtcNow.AddMinutes(-1)) -Reason 'clear Codex'
    $null = Add-RouterVendorBlock -Vendor claude -ResetAtUtc ([datetimeoffset]::UtcNow.AddMinutes(-1)) -Reason 'clear Claude'
    $roster = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 20
    $roster.approved = $true; $roster.approved_at = [datetimeoffset]::UtcNow.ToString('o')
    $roster | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $state 'roster.json')
    [IO.File]::WriteAllText($file,$lines[1] + "`n")
    $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Catalog $catalog
    Assert-True ($pick.roster_source -eq 'state' -and $pick.model -eq 'claude-opus-5-5' -and $pick.vendor -eq 'claude') 'approved roster sends blocked Codex coder to Claude backup'
    $null = Add-RouterVendorBlock -Vendor claude -Reason 'limit refused'
    $pick = Resolve-RouterModel -SkipModelCheck -Category complex-coding -Catalog $catalog
    Assert-True ($pick.status -eq 'wait' -and $null -eq $pick.model) 'both vendors blocked make resolver wait'
    $cli = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../vendor-limits.ps1') -Vendor claude -Json | ConvertFrom-Json
    Assert-True ($cli.vendor -eq 'claude' -and $cli.blocked -and $cli.reason -eq 'limit refused' -and $null -eq $cli.used_percent) 'CLI returns vendor limit status JSON'
    $cliReset = [datetimeoffset]::UtcNow.AddMinutes(20).ToString('o')
    $recorded = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../vendor-limits.ps1') -RecordBlock -Vendor codex -ResetAtUtc $cliReset -Reason 'CLI refusal' -Json | ConvertFrom-Json
    Assert-True ($recorded.blocked -and $recorded.reason -eq 'CLI refusal' -and @(Read-RouterJsonArray -Path (Join-Path $state 'vendor-blocks.json') | Where-Object { $_.vendor -eq 'codex' -and $_.reason -eq 'CLI refusal' }).Count -eq 1) 'CLI records refusal with reset time'
    $priorClaudeCredentials = $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS
    $credentialsPath = Join-Path $temp 'fixture-credentials.json'
    $cachePath = Join-Path $state 'claude-usage.json'
    $script:claudeFetchCalls = 0
    $script:claudePercent = 67.0
    $script:claudeReset = [datetimeoffset]::UtcNow.AddDays(3).ToString('o')
    $script:RouterClaudeUsageFetcher = {
        param($token)
        $script:claudeFetchCalls++
        return [pscustomobject]@{
            seven_day=[pscustomobject]@{ utilization=$script:claudePercent; resets_at=$script:claudeReset }
            five_hour=[pscustomobject]@{ utilization=8.0; resets_at=[datetimeoffset]::UtcNow.AddHours(2).ToString('o') }
        }
    }
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = $credentialsPath
    $credentials = [pscustomobject]@{ claudeAiOauth=[pscustomobject]@{ accessToken='fixture-token-never-cache'; expiresAt=[datetimeoffset]::UtcNow.AddHours(1).ToUnixTimeMilliseconds() } }
    Write-RouterJsonAtomic -Path $credentialsPath -Value $credentials
    Remove-Item -LiteralPath (Join-Path $state 'vendor-blocks.json') -Force
    $usage = Get-RouterClaudeUsage
    Assert-True ($usage.used_percent -eq 67 -and $usage.session_percent -eq 8 -and -not (Get-RouterVendorBlocked -Vendor claude)) 'Claude 67 percent and session parse without blocking'
    Assert-True ((Test-Path -LiteralPath $cachePath) -and [IO.File]::ReadAllText($cachePath) -notmatch 'fixture-token-never-cache') 'Claude cache written without token'
    Assert-True ($usage.source -eq 'oauth-usage' -and ([datetimeoffset]$usage.resets_at_utc).Offset -eq [timespan]::Zero -and @($usage.PSObject.Properties).Count -eq 6) 'Claude reading has only six fields and UTC reset'
    $calls = $script:claudeFetchCalls
    $cached = Get-RouterClaudeUsage
    Assert-True ($script:claudeFetchCalls -eq $calls) 'fresh Claude cache skips fetch'
    Assert-True ($cached.used_percent -is [double] -and $cached.resets_at_utc -is [string] -and $cached.observed_at_utc -is [string] -and $cached.session_resets_at_utc -is [string]) 'Claude cache returns double percentages and ISO strings'
    $usage.observed_at_utc = [datetimeoffset]::UtcNow.AddMinutes(-6).ToString('o')
    Write-RouterJsonAtomic -Path $cachePath -Value $usage
    $null = Get-RouterClaudeUsage
    Assert-True ($script:claudeFetchCalls -eq $calls + 1) 'stale Claude cache fetches'
    Remove-Item -LiteralPath $cachePath
    $script:claudePercent = 96
    Assert-True ((Get-RouterVendorBlocked -Vendor claude)) 'Claude 96 percent blocks'
    $cli = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../vendor-limits.ps1') -Vendor claude -Json | ConvertFrom-Json
    Assert-True ($cli.blocked -and $cli.reason -eq 'Claude weekly usage at or above 95%' -and $cli.session_percent -eq 8 -and $cli.resets_at_utc) 'Claude CLI uses cached weekly reading and reason'
    $usage = Read-RouterJsonObject -Path $cachePath
    $usage.used_percent = 95
    Write-RouterJsonAtomic -Path $cachePath -Value $usage
    Assert-True ((Get-RouterVendorBlocked -Vendor claude)) 'Claude exact 95 percent threshold blocks'
    $usage.used_percent = 67; $usage.session_percent = 100
    Write-RouterJsonAtomic -Path $cachePath -Value $usage
    Assert-True (-not (Get-RouterVendorBlocked -Vendor claude)) 'Claude session limit is informational for routing'
    Remove-Item -LiteralPath $cachePath
    $credentials.claudeAiOauth.expiresAt = [datetimeoffset]::UtcNow.AddMinutes(-1).ToUnixTimeMilliseconds()
    Write-RouterJsonAtomic -Path $credentialsPath -Value $credentials
    $calls = $script:claudeFetchCalls
    Assert-True ($null -eq (Get-RouterClaudeUsage) -and $script:claudeFetchCalls -eq $calls) 'expired Claude token never fetches'
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = Join-Path $temp 'missing.json'
    Assert-True ($null -eq (Get-RouterClaudeUsage)) 'missing Claude credentials return unknown'
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = $credentialsPath
    Set-Content -LiteralPath $credentialsPath -Value '{broken'
    Assert-True ($null -eq (Get-RouterClaudeUsage)) 'unparsable Claude credentials return unknown'
    $credentials.claudeAiOauth.expiresAt = [datetimeoffset]::UtcNow.AddHours(1).ToUnixTimeMilliseconds()
    $credentials.claudeAiOauth.accessToken = ''
    Write-RouterJsonAtomic -Path $credentialsPath -Value $credentials
    Assert-True ($null -eq (Get-RouterClaudeUsage) -and $script:claudeFetchCalls -eq $calls) 'absent Claude token never fetches'
    $credentials.claudeAiOauth.accessToken = 'fixture-token-never-cache'
    Write-RouterJsonAtomic -Path $credentialsPath -Value $credentials
    $usage.used_percent = 67
    $usage.observed_at_utc = [datetimeoffset]::UtcNow.AddMinutes(-6).ToString('o')
    Write-RouterJsonAtomic -Path $cachePath -Value $usage
    $script:RouterClaudeUsageFetcher = { param($token) $script:claudeFetchCalls++; throw 'fixture failure' }
    Assert-True ((Get-RouterClaudeUsage).used_percent -eq 67) 'Claude fetch failure falls back to stale cache'
    Remove-Item -LiteralPath $cachePath
    Assert-True ($null -eq (Get-RouterClaudeUsage)) 'Claude fetch failure without cache returns unknown'
    Write-RouterJsonAtomic -Path $cachePath -Value $usage
    $script:RouterClaudeUsageFetcher = { param($token) return [pscustomobject]@{ seven_day=[pscustomobject]@{ utilization='invalid'; resets_at='invalid' } } }
    Assert-True ((Get-RouterClaudeUsage).used_percent -eq 67) 'Claude parse failure falls back to stale cache'
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = Join-Path $temp 'missing.json'
    Assert-True ($null -eq (Get-RouterClaudeUsage)) 'stale cache does not mask missing credentials'
    $usage.observed_at_utc = [datetimeoffset]::UtcNow.ToString('o')
    Write-RouterJsonAtomic -Path $cachePath -Value $usage
    Assert-True ((Get-RouterClaudeUsage).used_percent -eq 67) 'fresh cache may precede missing credentials'
    $usage.resets_at_utc = [datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o')
    Write-RouterJsonAtomic -Path $cachePath -Value $usage
    Assert-True ((Get-RouterClaudeUsage).used_percent -eq 0) 'past Claude cached reset zeroes weekly usage'
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = $credentialsPath
    Remove-Item -LiteralPath $cachePath
    $script:RouterClaudeUsageFetcher = { param($token) return [pscustomobject]@{ seven_day=[pscustomobject]@{ utilization=96; resets_at=[datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o') } } }
    $usage = Get-RouterClaudeUsage
    Assert-True ($usage.used_percent -eq 0 -and $null -eq $usage.session_percent -and $null -eq $usage.session_resets_at_utc) 'past Claude fetched reset zeroes usage and optional session is null'
    $usage.used_percent = 67; $usage.resets_at_utc = [datetimeoffset]::UtcNow.AddDays(3).ToString('o')
    Write-RouterJsonAtomic -Path $cachePath -Value $usage
    $null = Add-RouterVendorBlock -Vendor claude -Reason 'refusal wins'
    Assert-True ((Get-RouterVendorBlocked -Vendor claude)) 'Claude refusal still blocks at 67 percent'
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = $priorClaudeCredentials
    # Resume selection uses only fixture state, usage cache and session logs.
    Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $state 'vendor-blocks.json') -ErrorAction SilentlyContinue
    $usage.used_percent = 96
    $usage.observed_at_utc = [datetimeoffset]::UtcNow.ToString('o')
    $usage.resets_at_utc = [datetimeoffset]::UtcNow.AddHours(2).ToString('o')
    Write-RouterJsonAtomic -Path $cachePath -Value $usage
    $later = [datetimeoffset]::UtcNow.AddHours(4)
    $null = Add-RouterVendorBlock -Vendor claude -ResetAtUtc $later -Reason 'refusal'
    $resume = Get-RouterResumeAfter -Vendors claude
    Assert-True ($resume.resume_after_utc -eq $later.ToString('o') -and $resume.resume_after_source -eq 'refusal-reset') 'later refusal reset wins over usage reset'
    $null = Add-RouterVendorBlock -Vendor claude -ResetAtUtc ([datetimeoffset]::UtcNow.AddMinutes(20)) -Reason 'refusal'
    $resume = Get-RouterResumeAfter -Vendors claude
    Assert-True ($resume.resume_after_utc -eq $usage.resets_at_utc -and $resume.resume_after_source -eq 'usage-reset') 'later usage reset wins over refusal reset'
    $usage.used_percent = 94.9
    Write-RouterJsonAtomic -Path $cachePath -Value $usage
    $block = Add-RouterVendorBlock -Vendor claude -Reason 'refusal'
    $resume = Get-RouterResumeAfter -Vendors claude
    Assert-True ($resume.resume_after_source -eq 'recheck' -and $resume.resume_after_utc -eq $block.reset_at_utc -and $resume.resume_after_et.StartsWith('recheck after ')) 'no-reset refusal reports exact one-hour recheck'
    $null = Add-RouterVendorBlock -Vendor codex -ResetAtUtc $later -Reason 'refusal'
    $resume = Get-RouterResumeAfter -Vendors codex,claude
    Assert-True ($resume.resume_after_utc -eq $block.reset_at_utc -and $resume.resume_after_source -eq 'recheck') 'minimum vendor reset retains its constraint source'
    Assert-True ((Format-RouterResumeAfterEt -AtUtc '2026-07-01T18:00:00Z' -Source usage-reset) -ceq 'resume after Wed 2026-07-01 2:00 PM ET') 'EDT rendering uses Eastern time zone'
    Assert-True ((Format-RouterResumeAfterEt -AtUtc '2026-01-01T19:00:00Z' -Source refusal-reset) -ceq 'resume after Thu 2026-01-01 2:00 PM ET') 'EST rendering uses Eastern time zone'
    Write-Output "SUMMARY: $script:passed passed"
} finally { $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = $priorClaudeCredentials; Exit-RouterTestCodexHome $fixtureCodexHome;
    $env:DT_MODEL_ROUTER_STATE = $priorState
    $env:DT_MODEL_ROUTER_CODEX_SESSIONS = $priorSessions
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorTransport
    Remove-Item -LiteralPath $temp -Recurse -Force
}
