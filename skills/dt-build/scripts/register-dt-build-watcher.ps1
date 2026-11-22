#Requires -Version 7.0
# Registers (or with -Unregister removes) the dt-build-watcher scheduled task: dt-build-watcher.ps1
# every 2 minutes through the run-hidden.vbs shim, so no console ever flashes.
# On Linux it installs a systemd --user timer instead. Adoption step only; run it on Danny's go-ahead.
param(
    [switch]$Unregister,

    [string]$PwshPath = (Get-Command pwsh -ErrorAction Stop).Source,

    [string]$ShimPath = 'D:\Claude\_system-tools\run-hidden\run-hidden.vbs'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'dt-build-watcher'

if ($IsLinux) {
    # Linux session host (CT202): a systemd --user service + timer every 2 minutes. KillMode=process keeps
    # coordinators the watcher launches alive after the watcher run exits.
    $unitDir = Join-Path $HOME '.config/systemd/user'
    $service = Join-Path $unitDir "$taskName.service"
    $timer = Join-Path $unitDir "$taskName.timer"
    if ($Unregister) {
        & systemctl --user disable --now "$taskName.timer" 2>$null
        Remove-Item -LiteralPath $service, $timer -ErrorAction SilentlyContinue
        & systemctl --user daemon-reload
        "Removed systemd user timer $taskName."
        return
    }
    $watcherPath = Join-Path $PSScriptRoot 'dt-build-watcher.ps1'
    if (-not (Test-Path -LiteralPath $watcherPath)) { throw "DT_BUILD_WATCHER_SETUP: missing $watcherPath" }
    New-Item -ItemType Directory -Path $unitDir -Force | Out-Null
    $serviceText = @"
[Unit]
Description=dt-build watcher: reconciles registered runs and relaunches managed coordinators (no model calls)

[Service]
Type=oneshot
Environment=TEMP=/tmp
Environment=CODEX_HOME=%h/.codex
ExecStart=$PwshPath -NoProfile -NonInteractive -File "$watcherPath"
TimeoutStartSec=600
KillMode=process
"@
    $timerText = @"
[Unit]
Description=Run dt-build watcher every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
"@
    [IO.File]::WriteAllText($service, $serviceText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($timer, $timerText, [Text.UTF8Encoding]::new($false))
    & systemctl --user daemon-reload
    & systemctl --user enable --now "$taskName.timer"
    if ($LASTEXITCODE -ne 0) { throw "DT_BUILD_WATCHER_SETUP: systemctl enable failed ($LASTEXITCODE)" }
    "Registered systemd user timer $taskName (every 2 minutes)."
    return
}

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
