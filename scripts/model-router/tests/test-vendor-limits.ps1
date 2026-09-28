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
try {
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
    $roster = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 20
    $roster.approved = $true; $roster.approved_at = [datetimeoffset]::UtcNow.ToString('o')
    $roster | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $state 'roster.json')
    [IO.File]::WriteAllText($file,$lines[1] + "`n")
    $catalog = [pscustomobject]@{ models=@([pscustomobject]@{slug='gpt-6-sol';visibility='list'}) }
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
    Write-Output "SUMMARY: $script:passed passed"
} finally {
    $env:DT_MODEL_ROUTER_STATE = $priorState
    $env:DT_MODEL_ROUTER_CODEX_SESSIONS = $priorSessions
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorTransport
    Remove-Item -LiteralPath $temp -Recurse -Force
}
