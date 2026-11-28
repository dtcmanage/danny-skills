Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../toolbox-path.ps1')
if ($IsWindows) {
    if ((Get-DtBuildToolboxPath 'fixture-path') -cne 'fixture-path') { throw 'Windows PATH changed' }
    'PASS: Windows PATH retained'
    exit 0
}
$bin = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.local/share/workspace-python/bin'
if (-not (Test-Path -LiteralPath (Join-Path $bin python3) -PathType Leaf)) {
    if ((Get-DtBuildToolboxPath '/usr/bin:/bin') -cne '/usr/bin:/bin') { throw 'missing toolbox changed PATH' }
    'PASS: missing toolbox retains PATH'
    exit 0
}
$root = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.cache/build-acceptance-gates/toolbox-fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$root/bin" -Force | Out-Null
try {
    [IO.File]::WriteAllText("$root/pyvenv.cfg", 'fixture only; no interpreter or packages installed')
    [IO.File]::WriteAllText("$root/bin/python3", 'fixture interpreter marker')
    $system = Get-DtBuildToolboxPath '/usr/bin:/bin'
    if (($system -split ':')[0] -cne $bin) { throw 'headless PATH missed shared toolbox' }
    if ((Get-DtBuildToolboxPath $system) -cne $system) { throw 'toolbox PATH is not idempotent' }
    $application = "$root/bin`:/usr/bin:/bin"
    if ((Get-DtBuildToolboxPath $application) -cne $application) { throw 'explicit application venv displaced' }
    'SUMMARY: 3 toolbox PATH checks passed'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
