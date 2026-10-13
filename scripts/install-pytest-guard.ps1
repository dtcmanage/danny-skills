param(
    [Parameter(Mandatory)][ValidateSet('Install','Uninstall')][string]$Action
)
# Opt-in rollout only. This script changes User environment registration, never
# Python/site-packages, machine environment, or the current process environment.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'PYTEST_GUARD_INSTALL: Windows User environment registration only.' }
$guardDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DannyPytest/guard'
$manifest = Join-Path $guardDir 'registration.json'
$names = @('PYTEST_PLUGINS','PYTHONPATH','DANNY_PYTEST_GUARD_DIR')
$values = @{}
foreach ($name in $names) { $values[$name] = [Environment]::GetEnvironmentVariable($name, 'User') }

if ($Action -eq 'Install') {
    if (Test-Path -LiteralPath $manifest) {
        $registration = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
        foreach ($name in $names) {
            if ($values[$name] -cne $registration.installed.$name) { throw "PYTEST_GUARD_INSTALL: registration changed at $name; uninstall before reinstalling." }
        }
        Write-Output 'Pytest guard already registered. Restart parent applications to inherit it.'
        exit 0
    }
    if ($values['DANNY_PYTEST_GUARD_DIR'] -or @(([string]$values['PYTEST_PLUGINS']).Split(',')) -contains 'danny_pytest_guard') {
        throw 'PYTEST_GUARD_INSTALL: existing guard registration has no owned manifest; refusing to replace it.'
    }
    if (@(([string]$values['PYTHONPATH']).Split(';')) -contains $guardDir) { throw 'PYTEST_GUARD_INSTALL: dedicated directory is already on PYTHONPATH.' }
    New-Item -ItemType Directory -Path $guardDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'pytest-guard/danny_pytest_guard.py') -Destination (Join-Path $guardDir 'danny_pytest_guard.py')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'pytest-lock.py') -Destination (Join-Path $guardDir 'pytest-lock.py')
    $installed = @{
        PYTEST_PLUGINS = $(if ($values['PYTEST_PLUGINS']) { $values['PYTEST_PLUGINS'] + ',danny_pytest_guard' } else { 'danny_pytest_guard' })
        PYTHONPATH = $(if ($values['PYTHONPATH']) { $values['PYTHONPATH'] + ';' + $guardDir } else { $guardDir })
        DANNY_PYTEST_GUARD_DIR = $guardDir
    }
    # Save rollback before registration. A partial install can be uninstalled.
    $record = @{ original = $values; installed = $installed; directory = $guardDir }
    [IO.File]::WriteAllText($manifest, ($record | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $installed[$name], 'User') }
    Write-Output 'Pytest guard registered for this Windows account. Restart parent applications to inherit it. Opt out: DANNY_PYTEST_GUARD=0.'
} else {
    if (-not (Test-Path -LiteralPath $manifest)) { throw 'PYTEST_GUARD_UNINSTALL: no owned registration manifest.' }
    $record = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    foreach ($name in $names) {
        $current = $values[$name]
        if ($current -ceq $record.installed.$name) {
            $restored = $record.original.$name
        } elseif ($current -ceq $record.original.$name) {
            continue  # Also supports rollback of partial installation.
        } elseif ($name -eq 'PYTEST_PLUGINS') {
            $restored = (@(([string]$current).Split(',') | Where-Object { $_ -cne 'danny_pytest_guard' }) -join ',')
        } elseif ($name -eq 'PYTHONPATH') {
            $restored = (@(([string]$current).Split(';') | Where-Object { $_ -ine $guardDir }) -join ';')
        } else {
            continue  # A later registration owns this value.
        }
        [Environment]::SetEnvironmentVariable($name, $restored, 'User')
    }
    Remove-Item -LiteralPath $manifest
    # Keep the two inert modules for processes still using the old environment.
    Write-Output 'Pytest guard unregistered. Module files retained for existing processes; restart parent applications.'
}
