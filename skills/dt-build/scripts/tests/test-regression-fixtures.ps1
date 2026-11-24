Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'regression-fixtures.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('fixture-retention-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $old = Join-Path $root ('dt-build-regressions-' + [guid]::NewGuid().ToString('N'))
    $recent = Join-Path $root ('dt-build-regressions-' + [guid]::NewGuid().ToString('N'))
    $unrelated = Join-Path $root 'dt-build-regressions-other-work'
    foreach ($path in @($old, $recent, $unrelated)) {
        New-Item -ItemType Directory -Path $path | Out-Null
        [IO.File]::WriteAllText((Join-Path $path 'failure.log'), 'diagnostic evidence')
    }
    (Get-Item $old).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8)
    (Get-Item $recent).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-6)
    (Get-Item $unrelated).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8)
    Remove-StaleDtRegressionFixtures -TempDirectory $root
    if (Test-Path -LiteralPath $old) { throw 'expired fixture was retained' }
    foreach ($path in @($recent, $unrelated)) {
        if ([IO.File]::ReadAllText((Join-Path $path 'failure.log')) -cne 'diagnostic evidence') { throw 'retained evidence changed' }
    }
    'PASS: expired fixture removal and recent/unrelated evidence retention'
}
finally { Remove-Item -LiteralPath $root -Recurse -Force }
