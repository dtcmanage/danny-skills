#Requires -Version 7.0
# Registers (or with -Unregister removes) the dt-build-watcher scheduled task: dt-build-watcher.ps1
# every 2 minutes through the run-hidden.vbs shim, so no console ever flashes.
# On Linux it installs a systemd --user timer instead. Adoption step only; run it on Danny's go-ahead.
param(
    [switch]$Unregister,

    # Linux: print the generated service and timer units and stop (no files written, no systemctl).
    [switch]$PrintUnit,

    [string]$PwshPath = (Get-Command pwsh -ErrorAction Stop).Source,

    [string]$ShimPath = 'D:\Claude\_system-tools\run-hidden\run-hidden.vbs'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'dt-build-watcher'

if ($IsLinux) {
    # Linux session host (CT202): a systemd --user service + timer every 2 minutes. KillMode=process keeps
    # coordinators the watcher launches alive after the watcher run exits.
    # Headless print-mode Claude coordinators (and the chunk jobs they start, which inherit this environment) sign in
    # with the long-lived CLAUDE_CODE_OAUTH_TOKEN that Command Center v2 keeps in its secrets.env (vault
    # claude-oauth-token); the interactive login in .credentials.json expires and cannot refresh headless.
    # CLAUDE_CONFIG_DIR points them at the workspace config. The leading '-' keeps the unit valid when the
    # file is absent (managed Claude launches then fail to sign in, as before).
    $unitDir = Join-Path $HOME '.config/systemd/user'
    $service = Join-Path $unitDir "$taskName.service"
    $timer = Join-Path $unitDir "$taskName.timer"
    if ($Unregister -and -not $PrintUnit) {
        & systemctl --user disable --now "$taskName.timer" 2>$null
        Remove-Item -LiteralPath $service, $timer -ErrorAction SilentlyContinue
        & systemctl --user daemon-reload
        "Removed systemd user timer $taskName."
        return
    }
    $watcherPath = Join-Path $PSScriptRoot 'dt-build-watcher.ps1'
    # pwsh on Linux logs its own engine events (startup, NamedPipe IPC, script blocks, perf tracking) to the
    # journal at Informational by default: ~13,500 entries in 9 hours from this 2-minute timer. The settings
    # file lowers only the watcher process to Critical; errors still reach the journal through stderr.
    $settingsPath = Join-Path $PSScriptRoot 'watcher-powershell.config.json'
    foreach ($path in @($watcherPath, $settingsPath)) { if (-not (Test-Path -LiteralPath $path)) { throw "DT_BUILD_WATCHER_SETUP: missing $path" } }
    $serviceText = @"
[Unit]
Description=dt-build watcher: reconciles registered runs and relaunches managed coordinators (no model calls)

[Service]
Type=oneshot
Environment=TEMP=/tmp
Environment=POWERSHELL_TELEMETRY_OPTOUT=1
Environment=CODEX_HOME=%h/.codex
Environment=CLAUDE_CONFIG_DIR=%h/Claude
EnvironmentFile=-%h/.config/command-center-v2/secrets.env
ExecStart=$PwshPath -NoProfile -NonInteractive -SettingsFile "$settingsPath" -File "$watcherPath"
SyslogIdentifier=dt-build-watcher
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
    if ($PrintUnit) { "# $service"; $serviceText; ''; "# $timer"; $timerText; return }
    New-Item -ItemType Directory -Path $unitDir -Force | Out-Null
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
