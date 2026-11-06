[CmdletBinding()]
param([Parameter(Mandatory)][string]$SettingsPath,
      [Parameter(Mandatory)][ValidateSet('install','rollback','status')][string]$Action)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$SettingsPath = [IO.Path]::GetFullPath($SettingsPath)
$backup = $SettingsPath + '.router-guard.backup'
$command = '"C:/Users/Danny/AppData/Local/Python/pythoncore-3.14-64/python.exe" -I "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills/scripts/model-router/dispatch-guard.py"'
$matcher = '^(Agent|Task|Bash|PowerShell)$'
if ($Action -eq 'rollback' -and (Test-Path -LiteralPath $backup)) {
        [IO.File]::WriteAllBytes($SettingsPath, [IO.File]::ReadAllBytes($backup))
        Remove-Item -LiteralPath $backup
    Write-Output 'rollback complete'
    exit 0
}
$settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json -AsHashtable
if (-not $settings.ContainsKey('hooks')) { $settings.hooks = @{} }
if (-not $settings.hooks.ContainsKey('PreToolUse')) { $settings.hooks.PreToolUse = @() }
$entries = @($settings.hooks.PreToolUse)
$installed = @($entries | Where-Object {
    @($_.hooks | Where-Object { $_.command -eq $command -or $_.command -eq 'python "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills/scripts/model-router/dispatch-guard.py"' }).Count -gt 0
})
if ($Action -eq 'rollback') {
    if ($installed.Count -gt 0) {
        Write-Output 'No backup exists; the router guard entry is still installed. Remove the dispatch-guard.py hook entry by hand.'
        exit 1
    }
    Write-Output 'nothing to roll back'
    exit 0
}
if ($Action -eq 'status') {
    @{ installed = ($installed.Count -gt 0); backup_present = (Test-Path -LiteralPath $backup); command = $command; matcher = $matcher } | ConvertTo-Json -Compress
    exit 0
}
if ($installed.Count -gt 0) { Write-Output 'already installed'; exit 0 }
if (Test-Path -LiteralPath $backup) { throw 'Existing backup without installed entry; rollback before reinstalling.' }
[IO.File]::WriteAllBytes($backup, [IO.File]::ReadAllBytes($SettingsPath))
$settings.hooks.PreToolUse = $entries + @(@{ matcher = $matcher; hooks = @(@{ type = 'command'; command = $command; timeout = 10 }) })
$settings | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $SettingsPath -Encoding utf8NoBOM
Write-Output 'installed separate router guard entry'
