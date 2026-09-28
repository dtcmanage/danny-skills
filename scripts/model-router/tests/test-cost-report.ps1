Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:passed = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Output "PASS: $Name"
}

# Weekly cost-report.ps1 delivers a plain-language Discord DM once per reported week,
# through the same stubbed-transport seam every other model-router test uses. This test
# never touches a real Codex/Claude session log: usage-all-sessions.jsonl is written by
# hand and DT_MODEL_ROUTER_USAGE_SWEEP is pointed at a no-op sweep so cost-report.ps1
# never shells out to the real collect-usage.py sweep either.

$priorState = $env:DT_MODEL_ROUTER_STATE
$priorTransport = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
$priorSweep = $env:DT_MODEL_ROUTER_USAGE_SWEEP
$temp = Join-Path $env:TEMP ('cost-report-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$env:DT_MODEL_ROUTER_STATE = $temp

$sweep = Join-Path $temp 'noop-sweep.py'
Set-Content -LiteralPath $sweep -Value 'import sys' -Encoding utf8
$env:DT_MODEL_ROUTER_USAGE_SWEEP = $sweep

$requestLog = Join-Path $temp 'requests.jsonl'
$fakeTransport = Join-Path $temp 'fake-transport.ps1'
Set-Content -LiteralPath $fakeTransport -Value @'
param($request)
Add-Content -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'requests.jsonl') -Value ([string]$request['kind'] + ' ' + [string]$request['uri'])
if ($request['kind'] -eq 'secret') { return 'fake-secret' }
if ($request['uri'] -like '*/oauth2/applications/@me') { return [pscustomobject]@{ owner = [pscustomobject]@{ id = '123456789' } } }
if ($request['uri'] -like '*/users/@me/channels') { return [pscustomobject]@{ id = 'dm-channel' } }
if ($request['uri'] -like '*/channels/*/messages') { return [pscustomobject]@{ id = 'fake-message' } }
throw "Unexpected request: $($request['uri'])"
'@
$env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $fakeTransport

try {
    # A minimal usage row for the most recent complete ET week (Monday of that week) so
    # cost_report.py's own week selection lands on a real, non-empty report.
    $today = Get-Date
    $isoDay = [int]$today.DayOfWeek; if ($isoDay -eq 0) { $isoDay = 7 }
    $mondayThisWeek = $today.Date.AddDays(1 - $isoDay)
    $prevMonday = $mondayThisWeek.AddDays(-7)
    $dateEt = $prevMonday.ToString('yyyy-MM-dd')
    $row = [ordered]@{
        kind = 'usage'; host = 'claude'; model = 'claude-opus-5-5'; session_id = 'cost-report-test'
        date_et = $dateEt; calls = 1; tokens = [ordered]@{ input = 1000000; cache_write = 0; cache_read = 0; output = 1000000 }
    }
    ConvertTo-Json -InputObject $row -Compress | Set-Content -LiteralPath (Join-Path $temp 'usage-all-sessions.jsonl')

    $script = Join-Path $PSScriptRoot '../cost-report.ps1'
    $output1 = @(& pwsh -NoProfile -File $script -StateDir $temp) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0) 'first run exits 0'
    Assert-True (Test-Path -LiteralPath (Join-Path $temp 'cost-reports/discord-summary.json')) 'discord-summary.json written'
    $summary = Get-Content -LiteralPath (Join-Path $temp 'cost-reports/discord-summary.json') -Raw | ConvertFrom-Json
    Assert-True ($summary.key -match '^weekly-report:\d{4}-W\d{2}$') 'summary key names the reported week'
    Assert-True ($summary.message -match '\*\*Model router - week of') 'summary message carries the header line'
    Assert-True ($output1 -match 'weekly summary sent \(discord\)') 'first run reports a real send'
    $sentRequests = (Get-Content -LiteralPath $requestLog).Count
    Assert-True ($sentRequests -gt 0) 'transport actually received requests on first send'

    $key = [string]$summary.key
    $output2 = @(& pwsh -NoProfile -File $script -StateDir $temp) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0) 'second run exits 0'
    Assert-True ($output2 -match 'weekly summary already sent') 'second run is deduped'
    $log = Get-Content -LiteralPath (Join-Path $temp 'alert-log.jsonl') -Raw
    Assert-True (@($log -split '\r?\n' | Where-Object { $_ -match [regex]::Escape($key) -and $_ -match 'delivered' }).Count -eq 1) 'exactly one delivered record for the week key'
    $requestsAfterSecondRun = (Get-Content -LiteralPath $requestLog).Count
    Assert-True ($requestsAfterSecondRun -eq $sentRequests) 'dedup skips the transport entirely on the second run'

    Write-Output "SUMMARY: $script:passed passed"
} finally {
    $env:DT_MODEL_ROUTER_STATE = $priorState
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorTransport
    $env:DT_MODEL_ROUTER_USAGE_SWEEP = $priorSweep
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
