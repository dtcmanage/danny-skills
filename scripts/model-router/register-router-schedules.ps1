param([switch]$Apply, [switch]$Json,
    [string]$UnitDir = (Join-Path $HOME '.config/systemd/user'), [switch]$NoSystemctl)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-platform.ps1')

function Register-RouterSchedules {
    param([switch]$Apply, [string]$UnitDir = (Join-Path $HOME '.config/systemd/user'), [switch]$NoSystemctl)
    Assert-RouterOwner -Action 'Router schedules'
    if ((Get-RouterPlatform) -eq 'Linux') {
        $main = Get-RouterMainCheckout
        $tasks = @(
            [pscustomobject]@{ name='ModelRouterWeeklyCostReport'; unit='model-router-weekly-cost-report'; script='cost-report.ps1'; arguments=@(); calendar='Mon *-*-* 07:00:00 America/New_York' },
            [pscustomobject]@{ name='ModelRouterCadence'; unit='model-router-cadence'; script='run-router-cadence.ps1'; arguments=@(); calendar='*-*-* 01:00:00 America/New_York' },
            [pscustomobject]@{ name='ModelRouterCadenceCheck'; unit='model-router-cadence-check'; script='run-router-cadence.ps1'; arguments=@('-CheckOnly'); calendar='*-*-* 13:00:00 America/New_York' }
        )
        foreach ($item in $tasks) {
            $item.script = Join-Path $main ('scripts/model-router/' + $item.script)
            # systemd expands % specifiers and $ variables even inside quoted ExecStart arguments.
            $scriptPath = $item.script.Replace('\','\\').Replace('"','\"').Replace('%','%%').Replace('$','$$')
            $action = '/usr/bin/env pwsh -NoProfile -NonInteractive -File "' + $scriptPath + '"'
            if ($item.arguments.Count) { $action += ' ' + ($item.arguments -join ' ') }
            $service = @"
[Unit]
Description=$($item.name)

[Service]
Type=oneshot
ExecStart=$action
Environment=CLAUDE_CONFIG_DIR=/home/danny/Claude
Environment=CODEX_HOME=/home/danny/.codex
EnvironmentFile=-/home/danny/.config/command-center-v2/secrets.env
Environment=POWERSHELL_TELEMETRY_OPTOUT=1
"@
            $timer = @"
[Unit]
Description=$($item.name) schedule

[Timer]
OnCalendar=$($item.calendar)
Persistent=true

[Install]
WantedBy=timers.target
"@
            $item | Add-Member -NotePropertyMembers @{
                service_path=(Join-Path $UnitDir ($item.unit + '.service'))
                timer_path=(Join-Path $UnitDir ($item.unit + '.timer'))
                service_content=($service + "`n"); timer_content=($timer + "`n")
                schedule=$item.calendar; action=$action
            }
        }
        if ($Apply) {
            $null = [IO.Directory]::CreateDirectory($UnitDir)
            foreach ($item in $tasks) {
                [IO.File]::WriteAllText($item.service_path, $item.service_content, [Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText($item.timer_path, $item.timer_content, [Text.UTF8Encoding]::new($false))
            }
            if (-not $NoSystemctl) {
                & systemctl --user daemon-reload
                if ($LASTEXITCODE -ne 0) { throw 'Failed to reload systemd user units' }
                foreach ($item in $tasks) {
                    & systemctl --user enable --now ($item.unit + '.timer')
                    if ($LASTEXITCODE -ne 0) { throw "Failed to enable $($item.unit).timer" }
                }
            }
        }
        return @($tasks)
    }
    # Legacy Windows registration retained for compatibility; the owner guard refuses Windows.
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
        # schtasks /create cannot set catch-up; runs missed while SNOWWHITE is off or in another OS fire on return.
        $task = Get-ScheduledTask -TaskName $item.name
        $task.Settings.StartWhenAvailable = $true
        Set-ScheduledTask -InputObject $task | Out-Null
    }
    return @($tasks)
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = @(Register-RouterSchedules -Apply:$Apply -UnitDir $UnitDir -NoSystemctl:$NoSystemctl)
    if ($Json) { ConvertTo-Json -InputObject $result -Depth 5 -Compress } else { $result | Format-Table name,schedule,action -AutoSize }
}
