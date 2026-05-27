# Verify a scaffolded app launcher against the contract in SKILL.md.
#
# Reads the launcher manifest (<slug>-launcher.json) and runs a fixed
# checklist depending on mode (edge_static | python_gui). Returns a
# structured pass/fail report so the AI does not need to interpret raw
# process command lines or .lnk targets by hand.
#
# Required checks (always run when artifacts exist):
#   - manifest, start/stop/shortcut/batch script files exist
#   - desktop + start-menu .lnk shortcuts exist and target the right exe
#
# Runtime checks (only with -CheckRunning):
#   - TCP listener exists on the manifest port
#   - For edge_static: an msedge.exe process has the required hardening
#     flags (--app=, --user-data-dir=<contains slug>, --disable-sync,
#     --disable-extensions, --no-first-run)
#   - For python_gui: a pythonw.exe process is running the configured entry

param(
    [Parameter(Mandatory)]
    [string]$ManifestPath,

    [switch]$CheckRunning,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-Check {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail = ""
    )
    return [pscustomobject]@{
        name = $Name
        status = $Status
        detail = $Detail
    }
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Launcher manifest not found: $ManifestPath"
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

$slug = [string]$manifest.slug
$mode = if ($manifest.PSObject.Properties.Name -contains 'launcher_mode') { [string]$manifest.launcher_mode } else { 'edge_static' }
$port = [int]$manifest.port
$appName = [string]$manifest.app_name

$checks = New-Object System.Collections.Generic.List[object]

# File-existence checks
foreach ($key in @('start_script', 'stop_script', 'shortcut_script', 'batch_launcher')) {
    $path = [string]$manifest.$key
    if (Test-Path -LiteralPath $path) {
        $checks.Add((New-Check -Name $key -Status 'pass' -Detail $path))
    }
    else {
        $checks.Add((New-Check -Name $key -Status 'fail' -Detail "Missing: $path"))
    }
}

# Shortcut checks (Desktop + Start Menu)
$desktop = [Environment]::GetFolderPath('Desktop')
$startMenuPrograms = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
$shortcutLocations = @(
    @{ Label = 'shortcut_desktop'; Path = (Join-Path $desktop "$appName.lnk") },
    @{ Label = 'shortcut_startmenu'; Path = (Join-Path $startMenuPrograms "$appName.lnk") }
)

$shell = $null
try { $shell = New-Object -ComObject WScript.Shell } catch { }

foreach ($loc in $shortcutLocations) {
    $lnk = $loc.Path
    if (-not (Test-Path -LiteralPath $lnk)) {
        $checks.Add((New-Check -Name $loc.Label -Status 'fail' -Detail "Missing: $lnk"))
        continue
    }

    if (-not $shell) {
        $checks.Add((New-Check -Name $loc.Label -Status 'fail' -Detail "Found but WScript.Shell unavailable to read target: $lnk"))
        continue
    }

    $shortcut = $shell.CreateShortcut($lnk)
    $target = [string]$shortcut.TargetPath
    $args = [string]$shortcut.Arguments
    $detail = "TargetPath=$target  Arguments=$args"

    if ($mode -eq 'python_gui') {
        $targetLeaf = [System.IO.Path]::GetFileName($target).ToLowerInvariant()
        if ($targetLeaf -ne 'pythonw.exe') {
            $checks.Add((New-Check -Name $loc.Label -Status 'fail' -Detail "Expected pythonw.exe TargetPath, got '$target'. python_gui shortcuts must not point at .bat or powershell.exe."))
            continue
        }
        if ($target -like '*WindowsApps*') {
            $checks.Add((New-Check -Name $loc.Label -Status 'fail' -Detail "TargetPath points at WindowsApps shim: $target"))
            continue
        }
    }
    else {
        # edge_static: shortcut targets powershell.exe wrapping the start script
        if ($target -notlike '*powershell.exe' -and $target -notlike '*pwsh.exe') {
            $checks.Add((New-Check -Name $loc.Label -Status 'fail' -Detail "Expected powershell.exe TargetPath for edge_static, got '$target'."))
            continue
        }
        if ($args -notmatch "start-$slug\.ps1") {
            $checks.Add((New-Check -Name $loc.Label -Status 'fail' -Detail "Shortcut arguments do not reference start-$slug.ps1: $args"))
            continue
        }
    }

    $checks.Add((New-Check -Name $loc.Label -Status 'pass' -Detail $detail))
}

# Runtime checks
if ($CheckRunning) {
    # Port listener
    $listen = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($listen) {
        $owningPids = ($listen.OwningProcess | Select-Object -Unique) -join ','
        $checks.Add((New-Check -Name 'port_listening' -Status 'pass' -Detail "Port $port has listener(s) PID $owningPids"))
    }
    else {
        $checks.Add((New-Check -Name 'port_listening' -Status 'fail' -Detail "No listener on port $port"))
    }

    if ($mode -eq 'edge_static') {
        $edgeProcs = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*$slug-edge-*" -or $_.CommandLine -like "*127.0.0.1:$port*" }

        if (-not $edgeProcs) {
            $checks.Add((New-Check -Name 'edge_process' -Status 'fail' -Detail "No msedge.exe process matching slug '$slug-edge-*' or port $port"))
        }
        else {
            $requiredFlags = @('--app=', "--user-data-dir=", '--disable-sync', '--disable-extensions', '--no-first-run')
            $matched = $false
            foreach ($proc in $edgeProcs) {
                $cmd = [string]$proc.CommandLine
                $missing = @($requiredFlags | Where-Object { $cmd -notlike "*$_*" })
                if ($missing.Count -eq 0 -and ($cmd -like "*$slug-edge-*" -or $cmd -like "*$slug*")) {
                    $matched = $true
                    $checks.Add((New-Check -Name 'edge_process' -Status 'pass' -Detail "PID $($proc.ProcessId): all hardening flags present."))
                    break
                }
            }
            if (-not $matched) {
                $sample = ($edgeProcs | Select-Object -First 1).CommandLine
                $checks.Add((New-Check -Name 'edge_process' -Status 'fail' -Detail "Edge process(es) found but none had all required flags. Sample: $sample"))
            }
        }
    }
    elseif ($mode -eq 'python_gui') {
        $pythonEntry = [string]$manifest.python_entry
        $pythonEntryLeaf = [System.IO.Path]::GetFileName($pythonEntry)
        $pyProcs = Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*$pythonEntryLeaf*" }

        if ($pyProcs) {
            $checks.Add((New-Check -Name 'pythonw_process' -Status 'pass' -Detail "pythonw.exe running $pythonEntryLeaf (PID $($pyProcs[0].ProcessId))"))
        }
        else {
            $checks.Add((New-Check -Name 'pythonw_process' -Status 'fail' -Detail "No pythonw.exe process found running $pythonEntryLeaf"))
        }
    }
}

$allPass = -not ($checks | Where-Object { $_.status -eq 'fail' })

$report = [pscustomobject]@{
    slug = $slug
    mode = $mode
    port = $port
    app_name = $appName
    manifest_path = (Resolve-Path -LiteralPath $ManifestPath).Path
    checked_running = [bool]$CheckRunning
    checks = $checks
    pass = $allPass
}

if ($Json) {
    $report | ConvertTo-Json -Depth 6
    if (-not $allPass) { exit 1 }
    exit 0
}

Write-Output "Launcher: $appName ($slug, $mode, port $port)"
foreach ($c in $checks) {
    $marker = switch ($c.status) {
        'pass' { '[OK]' }
        'fail' { '[FAIL]' }
        default { '[--]' }
    }
    Write-Output "  $marker $($c.name): $($c.detail)"
}
if ($allPass) {
    Write-Output "Verification PASSED."
} else {
    Write-Warning "Verification FAILED. See [FAIL] rows above."
    exit 1
}
