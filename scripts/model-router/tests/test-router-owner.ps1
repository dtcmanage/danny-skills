Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../router-common.ps1')
. (Join-Path $PSScriptRoot '../register-router-schedules.ps1')
. (Join-Path $PSScriptRoot '../router-state-inventory.ps1')
$script:passed = 0
function Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++; Write-Output "PASS: $Name"
}
if ($IsLinux) { Check ((Get-RouterPlatform) -eq 'Linux') 'native Linux detection' }
Check ((Get-RouterOwnerPlatform) -eq 'Linux') 'Linux owns router'
Assert-RouterOwner -Action 'fixture' -Platform Linux
Assert-RouterWindowsOwner -Action 'compatibility fixture' -Platform Linux
foreach ($platform in @('Windows','MacOS','Other')) {
    $message = ''
    try { Assert-RouterOwner -Action 'fixture' -Platform $platform } catch { $message = $_.Exception.Message }
    Check ($message -ceq 'ROUTER_OWNER: fixture is owned by the Linux session host (CT202).') "$platform refused"
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('router-owner-' + [guid]::NewGuid().ToString('N'))
$oldState = $env:DT_MODEL_ROUTER_STATE; $oldShared = $env:DT_MODEL_ROUTER_SHARED
$originalPlatform = ${function:Get-RouterPlatform}
try {
    $env:DT_MODEL_ROUTER_STATE = Join-Path $temp 'state'
    $env:DT_MODEL_ROUTER_SHARED = Join-Path $temp 'shared'
    $null = [IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_STATE)
    $null = [IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_SHARED)
    $roster = Get-Content (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json
    $roster.approved = $true; $roster.approved_at = '2026-11-23T12:00:00Z'
    $state = Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json'
    $shared = Join-Path $env:DT_MODEL_ROUTER_SHARED 'roster.json'
    foreach ($platform in @('Linux','Windows','MacOS')) {
        Set-Item Function:Get-RouterPlatform -Value ({ $platform }.GetNewClosure())
        Write-RouterJsonAtomic $state $roster
        Write-RouterJsonAtomic $shared $roster
        $expected = if ($platform -eq 'Linux') { 'state' } else { 'shared' }
        Check ((Read-RouterRoster).source -eq $expected) "$platform preferred roster"
        $preferred = if ($platform -eq 'Linux') { $state } else { $shared }
        Remove-Item $preferred
        $fallback = if ($platform -eq 'Linux') { 'shared' } else { 'state' }
        Check ((Read-RouterRoster).source -eq $fallback) "$platform absent preferred fallback"
        Remove-Item $state,$shared -ErrorAction SilentlyContinue
        Check ((Read-RouterRoster).source -eq 'default') "$platform default when both absent"
        $role = if ($platform -eq 'Linux') { 'roster-authority' } else { 'local-observer' }
        Check ((Get-RouterStateInventory).machine_role -eq $role) "$platform inventory role"
    }
    function Get-RouterPlatform { 'Linux' }
    $units = Join-Path $temp 'units'
    function systemctl { throw 'Unexpected systemctl in fixture' }
    $plan = @(Register-RouterSchedules -UnitDir $units)
    Check ($plan.Count -eq 3 -and -not (Test-Path $units)) 'dry run writes nothing'
    $result = @(Register-RouterSchedules -Apply -UnitDir $units -NoSystemctl)
    Check (@(Get-ChildItem $units).Count -eq 6) 'writes six unit files'
    $calendars = @('Mon *-*-* 07:00:00 America/New_York','*-*-* 01:00:00 America/New_York','*-*-* 13:00:00 America/New_York')
    $main = Get-RouterMainCheckout
    for ($i=0; $i -lt 3; $i++) {
        $item = $result[$i]
        $timer = Get-Content $item.timer_path -Raw
        $service = Get-Content $item.service_path -Raw
        Check ($timer.Contains('OnCalendar=' + $calendars[$i]) -and $timer.Contains('Persistent=true')) "$($item.name) calendar and catchup"
        Check ($service.Contains('Type=oneshot') -and $service.Contains('/usr/bin/env pwsh -NoProfile -NonInteractive -File "' + $main) -and -not $service.Contains('danny-skills-router-linux-owner/')) "$($item.name) primary checkout execution"
        Check ($service.Contains('Environment=CLAUDE_CONFIG_DIR=/home/danny/Claude') -and $service.Contains('EnvironmentFile=-/home/danny/.config/command-center-v2/secrets.env') -and $service.Contains('Environment=POWERSHELL_TELEMETRY_OPTOUT=1')) "$($item.name) environment"
        Check ($service.Contains('-CheckOnly') -eq ($i -eq 2)) "$($item.name) arguments"
    }
    foreach ($platform in @('Windows','MacOS')) {
        Set-Item Function:Get-RouterPlatform -Value ({ $platform }.GetNewClosure())
        $message = ''
        try { Register-RouterSchedules -Apply -UnitDir (Join-Path $temp 'refused') -NoSystemctl } catch { $message = $_.Exception.Message }
        Check ($message -like 'ROUTER_OWNER:*' -and -not (Test-Path (Join-Path $temp 'refused'))) "$platform scheduler refusal before writes"
    }
} finally {
    Set-Item Function:Get-RouterPlatform -Value $originalPlatform
    $env:DT_MODEL_ROUTER_STATE=$oldState; $env:DT_MODEL_ROUTER_SHARED=$oldShared
    Remove-Item $temp -Recurse -Force
}
Write-Output "SUMMARY: $script:passed passed"
