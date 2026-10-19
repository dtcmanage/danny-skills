Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passed = 0; $failed = [Collections.Generic.List[string]]::new()
function Check([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passed++ } else { $script:failed.Add($Message) }
}
$scripts = Split-Path -Parent $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ('api-contract-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $roadmap = Join-Path $root 'roadmap.md'
    # These local fixtures test gate orchestration only; they never call a vendor or send alerts.
    Set-Content (Join-Path $root 'auth.json') '{"access_token":"[REDACTED]"}'
    Set-Content (Join-Path $root 'read.json') '{"data":[{"id":"[REDACTED]"}]}'
    Set-Content (Join-Path $root 'check.ps1') 'param([string]$Kind); Add-Content -LiteralPath "$PSScriptRoot/calls.txt" -Value $Kind; if ($Kind -eq "bad-read") { exit 7 }; exit 0'
    $base = @'
## Milestones
| id | name | acceptance-checks |
| --- | --- | --- |
| M01 | Client | Run `pwsh -NoProfile -Command 'exit 0'` |
## Verification Manifest
| check-id | milestone-id | procedure |
| --- | --- | --- |
| chk-m01 | M01 | `pwsh -NoProfile -Command 'exit 0'` |
## Design Coverage
| requirement-id | requirement | build-id | milestone-id | owner | reason |
| --- | --- | --- | --- | --- | --- |
| L120 | Outlook -Prospect mode | out-of-build | - | Email HQ | other workstation before switch-on |
## External API Contracts
| milestone-id | service | samples | credentials | auth-check | read-check | residual |
| --- | --- | --- | --- | --- | --- | --- |
| M01 | fixture | auth.json; read.json | available | `pwsh -NoProfile -File check.ps1 -Kind auth` | `pwsh -NoProfile -File check.ps1 -Kind read` | - |
'@
    $cases = @(
        @{ name = 'live checks run'; text = $base; pass = $true; code = '' },
        @{ name = 'shape mismatch'; text = $base.Replace('-Kind read', '-Kind bad-read'); pass = $false; code = 'API_LIVE_CONTRACT_FAILED' },
        @{ name = 'missing endpoint sample'; text = $base.Replace('read.json |', 'missing.json |'); pass = $false; code = 'API_SAMPLE_MISSING' },
        @{ name = 'no auth sample'; text = $base.Replace('auth.json; read.json', 'read.json'); pass = $false; code = 'API_SAMPLES_REQUIRED' },
        @{ name = 'duplicate samples'; text = $base.Replace('auth.json; read.json', 'auth.json; auth.json'); pass = $false; code = 'API_SAMPLES_REQUIRED' },
        @{ name = 'missing auth check'; text = $base.Replace('`pwsh -NoProfile -File check.ps1 -Kind auth`', '-'); pass = $false; code = 'API_LIVE_CHECK_REQUIRED' },
        @{ name = 'missing read check'; text = $base.Replace('`pwsh -NoProfile -File check.ps1 -Kind read`', '-'); pass = $false; code = 'API_LIVE_CHECK_REQUIRED' },
        @{ name = 'credentials unavailable'; text = $base.Replace('| available |', '| unavailable |').Replace('` | - |', '` | vault unavailable; owner session; recheck before switch-on |'); pass = $false; code = 'API_CREDENTIALS_UNAVAILABLE' },
        @{ name = 'unavailable without residual'; text = $base.Replace('| available |', '| unavailable |'); pass = $false; code = 'missing named residual' },
        @{ name = 'no credential decision'; text = $base.Replace('| available |', '| - |'); pass = $false; code = 'API_CREDENTIAL_STATE_REQUIRED' }
    )
    foreach ($case in $cases) {
        Set-Content -LiteralPath $roadmap -Value $case.text
        $result = (& pwsh -NoProfile -File (Join-Path $scripts 'verify-milestone-acceptance.ps1') -RoadmapPath $roadmap -MilestoneId M01 -WorkingTree $root -RunTests -Json) -join "`n" | ConvertFrom-Json
        Check ($result.accepted -eq $case.pass) "$($case.name): expected acceptance=$($case.pass); $($result.blockers -join '; ')"
        if ($case.code) { Check (($result.blockers -join ' ') -match $case.code) "$($case.name): named failure" }
        if ($case.name -eq 'live checks run') {
            Check ((Get-Content -Raw (Join-Path $root 'calls.txt')) -match 'auth\s+read') 'auth and read commands executed before acceptance'
            Check ($result.command_results.Count -eq 3) 'live commands included in persisted command evidence'
        }
        if ($case.name -eq 'credentials unavailable') { Check ($result.api_contract_residuals.Count -eq 1 -and $result.api_contract_residuals[0].Contains('vault unavailable; owner session')) 'credential gap persisted with its named residual and owner' }
        if ($case.name -eq 'shape mismatch') { Check (-not $result.tested -and $result.test_status -eq 'FAIL') 'failed live check cannot claim tests passed' }
    }
    Set-Content -LiteralPath $roadmap -Value $base
    $inspect = (& pwsh -NoProfile -File (Join-Path $scripts 'verify-milestone-acceptance.ps1') -RoadmapPath $roadmap -MilestoneId M01 -WorkingTree $root -Json) -join "`n" | ConvertFrom-Json
    Check ($inspect.status -eq 'INSPECT_ONLY' -and -not $inspect.accepted -and $inspect.command_results.Count -eq 0) 'inspection does not execute live commands or accept'
    & pwsh -NoProfile -File (Join-Path $scripts 'build-acceptance-ledger.ps1') -RoadmapPath $roadmap -WorkingTree $root -OutDir $root -RunTests | Out-Null
    foreach ($extension in @('md', 'html')) {
        $ledger = Get-Content -Raw (Join-Path $root "build-acceptance-revalidation.$extension")
        Check ($ledger.Contains('Out-of-build go-live checklist') -and $ledger.Contains('Email HQ') -and $ledger.Contains('before switch-on')) "$extension ledger carries owned go-live checklist"
    }
    & pwsh -NoProfile -File (Join-Path $scripts 'build-acceptance-ledger.ps1') -RoadmapPath $roadmap -WorkingTree $root -OutDir $root | Out-Null
    foreach ($extension in @('md', 'html')) {
        $ledger = Get-Content -Raw (Join-Path $root "build-acceptance-ledger.$extension")
        Check ($ledger.Contains('Out-of-build go-live checklist') -and $ledger.Contains('Email HQ') -and $ledger.Contains('before switch-on')) "$extension normal close-out carries owned go-live checklist"
    }
} finally {
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetTempPath())) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Write-Output "SUMMARY: $passed passed, $($failed.Count) failed"
foreach ($failure in $failed) { Write-Output "FAIL: $failure" }
if ($failed.Count) { exit 1 }
