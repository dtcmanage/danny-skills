# Apply at process launch, including headless shells which never read .profile.
function Get-DtBuildToolboxPath {
    param([string]$Path)
    if ($IsWindows) { return $Path }
    $bin = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.local/share/workspace-python/bin'
    if (Test-Path -LiteralPath (Join-Path $bin 'python3') -PathType Leaf) {
        # An explicitly selected application venv still wins, as it does in the
        # interactive toolbox setup. A system-only/headless PATH gets the toolbox.
        foreach ($entry in ($Path -split [IO.Path]::PathSeparator)) {
            if (-not $entry -or -not (Test-Path -LiteralPath (Join-Path $entry 'python3') -PathType Leaf)) { continue }
            if ($entry -ne $bin -and (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $entry) 'pyvenv.cfg') -PathType Leaf)) { return $Path }
            break
        }
        return $bin + [IO.Path]::PathSeparator + (($Path -split [IO.Path]::PathSeparator | Where-Object { $_ -ne $bin }) -join [IO.Path]::PathSeparator)
    }
    return $Path
}
function Enable-DtBuildToolboxPath {
    $env:PATH = Get-DtBuildToolboxPath -Path $env:PATH
}
