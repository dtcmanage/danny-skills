#Requires -Version 7.0
# Registers (or with -Unregister removes) the dt-build-watcher scheduled task: dt-build-watcher.ps1
# every 2 minutes through the run-hidden.vbs shim, so no console ever flashes.
# Adoption step only; run it on Danny's go-ahead.
param(
    [switch]$Unregister,

    [string]$PwshPath = (Get-Command pwsh -ErrorAction Stop).Source,

    [string]$ShimPath = 'D:\Claude\_system-tools\run-hidden\run-hidden.vbs'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'dt-build-watcher'

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        "Removed scheduled task $taskName."
    }
    else { "Scheduled task $taskName is not registered." }
    return
}

$watcherPath = Join-Path $PSScriptRoot 'dt-build-watcher.ps1'
foreach ($path in @($ShimPath, $PwshPath, $watcherPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "DT_BUILD_WATCHER_SETUP: missing $path" }
}

# The shim supplies -NoProfile -NonInteractive -ExecutionPolicy Bypass -File itself.
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$ShimPath`" `"$PwshPath`" `"$watcherPath`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description 'dt-build watcher: reconciles registered runs and relaunches managed coordinators (no model calls).' -Force | Out-Null
"Registered scheduled task $taskName (every 2 minutes via run-hidden.vbs)."
