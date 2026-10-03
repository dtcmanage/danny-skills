param([switch]$Apply, [switch]$Json)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-platform.ps1')

function Register-RouterSchedules {
    param([switch]$Apply)
    Assert-RouterWindowsOwner -Action 'Router schedules'
    $shim = 'D:\Claude\_system-tools\run-hidden\run-hidden.vbs'
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $wscript = (Get-Command wscript.exe -ErrorAction Stop).Source
    $common = (& git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir 2>$null | Select-Object -First 1).Trim()
    if (-not $common) { throw 'Cannot locate main checkout for scheduled scripts' }
    $main = Split-Path -Parent $common
    $tasks = @(
        [pscustomobject]@{ name='ModelRouterWeeklyCostReport'; script=(Join-Path $main 'scripts/model-router/cost-report.ps1'); arguments=@(); schedule='weekly Monday 07:00 ET' },
        [pscustomobject]@{ name='ModelRouterCadence'; script=(Join-Path $main 'scripts/model-router/run-router-cadence.ps1'); arguments=@(); schedule='daily 01:00 ET' },
        [pscustomobject]@{ name='ModelRouterCadenceCheck'; script=(Join-Path $main 'scripts/model-router/run-router-cadence.ps1'); arguments=@('-CheckOnly'); schedule='daily 13:00 ET' }
    )
    foreach ($item in $tasks) {
        $item | Add-Member -NotePropertyName launcher -NotePropertyValue $shim
        $item | Add-Member -NotePropertyName action -NotePropertyValue ($wscript + ' "' + $shim + '" "' + $pwsh + '" "' + $item.script + '" ' + ($item.arguments -join ' '))
        if (-not $Apply) { continue }
        $arguments = '"' + $shim + '" "' + $pwsh + '" "' + $item.script + '" ' + ($item.arguments -join ' ')
        $taskRun = '"' + $wscript + '" ' + $arguments
        $scheduleArgs = switch ($item.name) {
            'ModelRouterWeeklyCostReport' { @('/sc','weekly','/d','MON','/st','07:00') }
            'ModelRouterCadence' { @('/sc','daily','/st','01:00') }
            'ModelRouterCadenceCheck' { @('/sc','daily','/st','13:00') }
        }
        & schtasks.exe /create /tn $item.name /tr $taskRun @scheduleArgs /f | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to register $($item.name)" }
    }
    return @($tasks)
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = @(Register-RouterSchedules -Apply:$Apply)
    if ($Json) { ConvertTo-Json -InputObject $result -Depth 5 -Compress } else { $result | Format-Table name,schedule,action -AutoSize }
}
