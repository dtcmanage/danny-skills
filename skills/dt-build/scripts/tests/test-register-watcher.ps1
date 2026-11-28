#Requires -Version 7.0
# B2 fix 10: the Linux watcher unit runs pwsh with a settings file that keeps its engine logging out of the
# journal, opts out of telemetry and tags its output dt-build-watcher. Never writes units or runs systemctl.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../../../scripts/lib/runtime-test-admission.ps1')
Enter-RuntimeTestSuite
$ErrorActionPreference = 'Stop'
$script:passed = 0
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "ASSERT_FAIL: $Message" }
    $script:passed++; Write-Output "PASS: $Message"
}
$scripts = Split-Path -Parent $PSScriptRoot
$settingsPath = Join-Path $scripts 'watcher-powershell.config.json'
$settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
Assert-True ($settings.LogLevel -ceq 'Critical' -and $settings.LogChannels -ceq 'Operational' -and $settings.LogIdentity -ceq 'dt-build-watcher') 'settings file uses the documented PowerShell 7 logging keys (LogLevel Critical, Operational channel)'
if (-not $IsLinux) { Write-Output "SUMMARY: $script:passed passed (unit checks are Linux-only)"; return }

$unitDir = Join-Path $HOME '.config/systemd/user'
$before = if (Test-Path -LiteralPath (Join-Path $unitDir 'dt-build-watcher.service')) { (Get-FileHash (Join-Path $unitDir 'dt-build-watcher.service')).Hash } else { $null }
$printed = (& pwsh -NoProfile -File (Join-Path $scripts 'register-dt-build-watcher.ps1') -PrintUnit) -join "`n"
Assert-True ($LASTEXITCODE -eq 0) 'PrintUnit runs without systemctl'
$after = if (Test-Path -LiteralPath (Join-Path $unitDir 'dt-build-watcher.service')) { (Get-FileHash (Join-Path $unitDir 'dt-build-watcher.service')).Hash } else { $null }
Assert-True ($before -eq $after) 'PrintUnit writes no unit file'
$service = [regex]::Match($printed, '(?s)\[Service\](.*?)(?:\n# |\z)').Groups[1].Value
$lines = @($service -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Assert-True ($lines -contains 'Environment=POWERSHELL_TELEMETRY_OPTOUT=1') 'telemetry is opted out'
Assert-True ($lines -contains 'SyslogIdentifier=dt-build-watcher') 'service output is tagged dt-build-watcher'
Assert-True (@($lines | Where-Object { $_ -like 'StandardOutput=*' -or $_ -like 'StandardError=*' }).Count -eq 0) 'stdout and stderr still reach the journal (errors are kept)'
$exec = @($lines | Where-Object { $_.StartsWith('ExecStart=') })
Assert-True ($exec.Count -eq 1 -and $exec[0] -match ('-NoProfile -NonInteractive -SettingsFile "' + [regex]::Escape($settingsPath) + '" -File "' + [regex]::Escape((Join-Path $scripts 'dt-build-watcher.ps1')) + '"$')) "ExecStart passes the settings file before -File ($($exec[0]))"
foreach ($kept in @('Type=oneshot', 'Environment=TEMP=/tmp', 'Environment=CODEX_HOME=%h/.codex', 'Environment=CLAUDE_CONFIG_DIR=%h/Claude', 'EnvironmentFile=-%h/.config/command-center-v2/secrets.env', 'TimeoutStartSec=600', 'KillMode=process')) {
    Assert-True ($lines -contains $kept) "unchanged unit line kept: $kept"
}
Assert-True ($printed.Contains('OnUnitActiveSec=2min') -and $printed.Contains('WantedBy=timers.target')) 'timer unit unchanged'

# Behaviour: the settings file silences pwsh's own journal entries (startup, IPC, script-block warnings).
if (Get-Command journalctl -ErrorAction SilentlyContinue) {
    $probeId = 'b2probe' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $probe = Join-Path ([IO.Path]::GetTempPath()) "$probeId.json"
    $loud = Join-Path ([IO.Path]::GetTempPath()) "$probeId-loud.json"
    try {
        $quiet = $settings | ConvertTo-Json | ConvertFrom-Json; $quiet.LogIdentity = $probeId
        [IO.File]::WriteAllText($probe, ($quiet | ConvertTo-Json))
        [IO.File]::WriteAllText($loud, (@{ LogLevel = 'Informational'; LogChannels = 'Operational'; LogIdentity = "$probeId-loud" } | ConvertTo-Json))
        $since = (Get-Date).AddSeconds(-1).ToString('yyyy-MM-dd HH:mm:ss')
        & pwsh -NoProfile -NonInteractive -SettingsFile $loud -Command '1' | Out-Null
        & pwsh -NoProfile -NonInteractive -SettingsFile $probe -Command '1' | Out-Null
        $loudCount = 0
        for ($i = 0; $i -lt 20 -and $loudCount -eq 0; $i++) { Start-Sleep -Milliseconds 250; $loudCount = @(& journalctl --since $since -t "$probeId-loud" -q 2>$null).Count }
        if ($loudCount -gt 0) {
            $quietCount = @(& journalctl --since $since -t $probeId -q 2>$null).Count
            Assert-True ($quietCount -eq 0) "the watcher settings file writes no pwsh engine entries to the journal ($loudCount at Informational, $quietCount with the file)"
        }
        else { Write-Output 'SKIP: journal not readable by this user; behaviour check not run' }
    }
    finally { Remove-Item -LiteralPath $probe, $loud -ErrorAction SilentlyContinue }
}
Write-Output "SUMMARY: $script:passed passed"
