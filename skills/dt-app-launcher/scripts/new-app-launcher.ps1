# Scaffold hardened standalone app launchers for local static/dashboard apps.

param(
    [Parameter(Mandatory)]
    [string]$AppName,

    [string]$TargetPath = (Get-Location).Path,

    [Parameter(Mandatory)]
    [string]$StaticRoot,

    [Parameter(Mandatory)]
    [string]$EntryFile,

    [int]$Port = 8793,

    [string]$Slug = "",

    [string]$BuildCommand = "",

    [string]$AllowedRoot = "",

    [switch]$CreateShortcuts,

    [switch]$NoShortcuts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$BasePath = ""
    )

    $candidate = $Path -replace '/', '\'
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        if ([string]::IsNullOrWhiteSpace($BasePath)) {
            $BasePath = (Get-Location).Path
        }
        $candidate = Join-Path $BasePath $candidate
    }

    return [System.IO.Path]::GetFullPath($candidate)
}

function Test-PathInside {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent
    )

    $child = Resolve-FullPath -Path $Path
    $base = Resolve-FullPath -Path $Parent
    if ($child.Equals($base, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $child.StartsWith("$base\", [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-Slug {
    param([Parameter(Mandatory)][string]$Value)

    $slugValue = $Value.Trim().ToLowerInvariant()
    $slugValue = $slugValue -replace "[^a-z0-9]+", "-"
    $slugValue = $slugValue.Trim("-")
    if ([string]::IsNullOrWhiteSpace($slugValue)) {
        throw "Could not derive a launcher slug from '$Value'. Pass -Slug explicitly."
    }
    return $slugValue
}

function Write-TextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
}

function ConvertTo-JsonLiteral {
    param([AllowNull()][string]$Value)
    return ($Value | ConvertTo-Json -Compress)
}

if ($Port -eq 8792) {
    throw "Port 8792 is reserved for File Sorter. Choose a different port."
}

$targetRoot = Resolve-FullPath -Path $TargetPath
if (-not (Test-Path -LiteralPath $targetRoot)) {
    throw "TargetPath does not exist: $targetRoot"
}

$staticRootPath = Resolve-FullPath -Path $StaticRoot -BasePath $targetRoot
$allowedRootPath = if ($AllowedRoot) { Resolve-FullPath -Path $AllowedRoot -BasePath $targetRoot } else { $targetRoot }
if (-not (Test-PathInside -Path $staticRootPath -Parent $allowedRootPath)) {
    throw "StaticRoot must stay inside AllowedRoot. StaticRoot=$staticRootPath AllowedRoot=$allowedRootPath"
}

$entryPath = Resolve-FullPath -Path $EntryFile -BasePath $staticRootPath
if (-not (Test-PathInside -Path $entryPath -Parent $staticRootPath)) {
    throw "EntryFile must stay inside StaticRoot. EntryFile=$entryPath StaticRoot=$staticRootPath"
}

$launcherSlug = if ($Slug) { ConvertTo-Slug -Value $Slug } else { ConvertTo-Slug -Value $AppName }
$scriptsDir = Join-Path $targetRoot "scripts"
$nodeScriptsDir = Join-Path $scriptsDir "node"
$serverScriptPath = Join-Path $nodeScriptsDir "serve-static-app.js"
$startScriptPath = Join-Path $scriptsDir "start-$launcherSlug.ps1"
$stopScriptPath = Join-Path $scriptsDir "stop-$launcherSlug.ps1"
$shortcutScriptPath = Join-Path $scriptsDir "create-$launcherSlug-shortcut.ps1"
$batchPath = Join-Path $targetRoot "start-$launcherSlug.bat"
$manifestPath = Join-Path $targetRoot "$launcherSlug-launcher.json"

$relativeStaticRoot = [System.IO.Path]::GetRelativePath($targetRoot, $staticRootPath)
$relativeEntryFile = [System.IO.Path]::GetRelativePath($staticRootPath, $entryPath)

$existing = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    throw "Port $Port is already in use by PID(s): $((@($existing.OwningProcess) | Select-Object -Unique) -join ', ')"
}

$serverScript = @'
#!/usr/bin/env node
import fs from "node:fs";
import http from "node:http";
import path from "node:path";

const args = process.argv.slice(2);
const getArg = (name, fallback = null) => {
  const idx = args.indexOf(name);
  return idx === -1 ? fallback : args[idx + 1];
};

const root = path.resolve(getArg("--root", process.cwd()));
const port = Number(getArg("--port", "8793"));
const host = getArg("--host", "127.0.0.1");

const mime = new Map([
  [".html", "text/html; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".mjs", "text/javascript; charset=utf-8"],
  [".csv", "text/csv; charset=utf-8"],
  [".md", "text/markdown; charset=utf-8"],
  [".svg", "image/svg+xml"],
  [".png", "image/png"],
  [".jpg", "image/jpeg"],
  [".jpeg", "image/jpeg"],
  [".webp", "image/webp"],
  [".ico", "image/x-icon"]
]);

function send(res, status, body, contentType = "text/plain; charset=utf-8") {
  res.writeHead(status, {
    "content-type": contentType,
    "cache-control": "no-store",
    "x-content-type-options": "nosniff"
  });
  res.end(body);
}

function resolveRequestPath(urlPath) {
  const decoded = decodeURIComponent((urlPath || "/").split("?")[0]);
  const relative = decoded === "/" ? "" : decoded.replace(/^\/+/, "");
  const resolved = path.resolve(root, relative);
  if (resolved !== root && !resolved.toLowerCase().startsWith(`${root.toLowerCase()}${path.sep}`)) {
    return null;
  }
  return resolved;
}

const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    send(res, 200, JSON.stringify({ ok: true, root }), "application/json; charset=utf-8");
    return;
  }

  const file = resolveRequestPath(req.url);
  if (!file) {
    send(res, 403, "Forbidden");
    return;
  }

  const target = fs.existsSync(file) && fs.statSync(file).isDirectory()
    ? path.join(file, "index.html")
    : file;

  if (!fs.existsSync(target) || !fs.statSync(target).isFile()) {
    send(res, 404, "Not found");
    return;
  }

  const type = mime.get(path.extname(target).toLowerCase()) || "application/octet-stream";
  res.writeHead(200, {
    "content-type": type,
    "cache-control": "no-store",
    "x-content-type-options": "nosniff"
  });
  fs.createReadStream(target).pipe(res);
});

server.listen(port, host, () => {
  process.stdout.write(JSON.stringify({ ok: true, url: `http://${host}:${port}/`, root }));
});

process.on("SIGTERM", () => server.close(() => process.exit(0)));
process.on("SIGINT", () => server.close(() => process.exit(0)));
'@

$startTemplate = @'
param(
    [int]$Port = __PORT__,
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ServerScript = Join-Path $PSScriptRoot "node\serve-static-app.js"
$AppName = __APP_NAME_JSON__
$LauncherSlug = __SLUG_JSON__
$StaticRootRelative = __STATIC_ROOT_JSON__
$EntryFileRelative = __ENTRY_FILE_JSON__
$BuildCommand = __BUILD_COMMAND_JSON__
$ProfilePrefix = "$LauncherSlug-edge"

function Resolve-FullPath {
    param([Parameter(Mandatory)][string]$Path, [string]$BasePath = "")
    $candidate = $Path -replace '/', '\'
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        if ([string]::IsNullOrWhiteSpace($BasePath)) { $BasePath = (Get-Location).Path }
        $candidate = Join-Path $BasePath $candidate
    }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Wait-ForServer {
    param([int]$Port)
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 1
            if ($response.StatusCode -eq 200) { return }
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
    }
    throw "$AppName UI server did not start on port $Port."
}

function Get-EdgePath {
    $cmd = Get-Command msedge.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw "Microsoft Edge was not found. Install Edge or add msedge.exe to PATH."
}

function Quote-Arg {
    param([string]$Value)
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Write-EdgePolicyFiles {
    param([string]$ProfileDir)

    $localStatePath = Join-Path $ProfileDir "Local State"
    $defaultProfile = Join-Path $ProfileDir "Default"
    $preferencesPath = Join-Path $defaultProfile "Preferences"

    New-Item -ItemType Directory -Path $defaultProfile -Force | Out-Null

    @{
        "browser" = @{ "has_seen_welcome_page" = $true }
        "sync" = @{ "requested" = $false; "suppress_start" = $true }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $localStatePath -Encoding UTF8

    @{
        "credentials_enable_service" = $false
        "profile" = @{ "password_manager_enabled" = $false; "exit_type" = "Normal"; "exited_cleanly" = $true }
        "signin" = @{ "allowed" = $false }
        "sync" = @{ "requested" = $false; "suppress_start" = $true }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $preferencesPath -Encoding UTF8
}

$staticRoot = Resolve-FullPath -Path $StaticRootRelative -BasePath $ProjectRoot
$entryPath = Resolve-FullPath -Path $EntryFileRelative -BasePath $staticRoot
if (-not (Test-Path -LiteralPath $entryPath)) {
    throw "App entry file not found: $entryPath"
}

if (-not $SkipBuild -and -not [string]::IsNullOrWhiteSpace($BuildCommand)) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        & $pwsh.Source -NoProfile -Command $BuildCommand
    }
    else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $BuildCommand
    }
    if ($LASTEXITCODE -ne 0) { throw "Build command failed." }
}

$existing = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    throw "Port $Port is already in use. Run scripts\stop-$LauncherSlug.ps1 or choose another port."
}

$server = $null
$edge = $null
$profileDir = Join-Path $env:TEMP "$ProfilePrefix-$([guid]::NewGuid())"

try {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    Write-EdgePolicyFiles -ProfileDir $profileDir

    $serverArgs = "$(Quote-Arg $ServerScript) --root $(Quote-Arg $staticRoot) --host 127.0.0.1 --port $Port"
    $server = Start-Process node `
        -ArgumentList $serverArgs `
        -WorkingDirectory $ProjectRoot `
        -WindowStyle Hidden `
        -PassThru

    Wait-ForServer -Port $Port

    $edgePath = Get-EdgePath
    $entryUrl = ($EntryFileRelative -replace '\\', '/')
    $url = "http://127.0.0.1:$Port/$entryUrl"
    $edgeArgs = @(
        "--app=$(Quote-Arg $url)",
        "--user-data-dir=$(Quote-Arg $profileDir)",
        "--profile-directory=Default",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-sync",
        "--disable-extensions",
        "--disable-component-extensions-with-background-pages",
        "--disable-background-networking",
        "--disable-features=msEdgeSidebarV2,msImplicitSignin,EdgeSignInInterceptionEnabled,EdgeOnRampFRE"
    ) -join " "

    $edge = Start-Process $edgePath `
        -ArgumentList $edgeArgs `
        -WindowStyle Normal `
        -PassThru

    Write-Host "$AppName running at $url"
    Wait-Process -Id $edge.Id
}
finally {
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }

    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$profileDir*" -or $_.CommandLine -like "*127.0.0.1:$Port*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
}
'@

$stopTemplate = @'
param(
    [int]$Port = __PORT__
)

$ErrorActionPreference = "SilentlyContinue"
$AppName = __APP_NAME_JSON__
$LauncherSlug = __SLUG_JSON__
$ProfilePrefix = "$LauncherSlug-edge"
$killed = $false

Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
    Where-Object { $_.CommandLine -like "*127.0.0.1:$Port*" -or $_.CommandLine -like "*$ProfilePrefix-*" } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force
        Write-Host "Stopped $AppName window (PID $($_.ProcessId))."
        $killed = $true
    }

$connections = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $Port -State Listen
foreach ($owningProcessId in ($connections.OwningProcess | Select-Object -Unique)) {
    Stop-Process -Id $owningProcessId -Force
    Write-Host "Stopped $AppName server (PID $owningProcessId)."
    $killed = $true
}

if (-not $killed) {
    Write-Host "$AppName is not running."
}
'@

$shortcutTemplate = @'
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$AppName = __APP_NAME_JSON__
$LauncherSlug = __SLUG_JSON__
$launcherScript = Join-Path $repo "scripts\start-$LauncherSlug.ps1"

if (-not (Test-Path -LiteralPath $launcherScript)) {
    throw "Launcher script not found at $launcherScript"
}

$powershellExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$iconPath = $powershellExe

$shell = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath("Desktop")
$startMenuPrograms = Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs"

foreach ($location in @($desktop, $startMenuPrograms)) {
    if (-not (Test-Path -LiteralPath $location)) {
        New-Item -ItemType Directory -Path $location -Force | Out-Null
    }

    $shortcutPath = Join-Path $location "$AppName.lnk"
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powershellExe
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherScript`""
    $shortcut.WorkingDirectory = $repo
    $shortcut.Description = "$AppName - standalone local app launcher"
    $shortcut.IconLocation = $iconPath
    $shortcut.Save()

    Write-Host "Created shortcut: `"$shortcutPath`""
}

Write-Host ""
Write-Host "Done. Double-click '$AppName' from Desktop or Start Menu."
'@

$batchTemplate = @'
@echo off
REM Launch __APP_NAME__ in its own hardened Edge app window.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-__SLUG__.ps1"
'@

if (-not (Test-Path -LiteralPath $serverScriptPath)) {
    Write-TextFile -Path $serverScriptPath -Content $serverScript
}

$replacements = @{
    "__PORT__" = [string]$Port
    "__APP_NAME_JSON__" = ConvertTo-JsonLiteral -Value $AppName
    "__SLUG_JSON__" = ConvertTo-JsonLiteral -Value $launcherSlug
    "__STATIC_ROOT_JSON__" = ConvertTo-JsonLiteral -Value $relativeStaticRoot
    "__ENTRY_FILE_JSON__" = ConvertTo-JsonLiteral -Value $relativeEntryFile
    "__BUILD_COMMAND_JSON__" = ConvertTo-JsonLiteral -Value $BuildCommand
    "__APP_NAME__" = $AppName
    "__SLUG__" = $launcherSlug
}

foreach ($key in $replacements.Keys) {
    $startTemplate = $startTemplate.Replace($key, $replacements[$key])
    $stopTemplate = $stopTemplate.Replace($key, $replacements[$key])
    $shortcutTemplate = $shortcutTemplate.Replace($key, $replacements[$key])
    $batchTemplate = $batchTemplate.Replace($key, $replacements[$key])
}

Write-TextFile -Path $startScriptPath -Content $startTemplate
Write-TextFile -Path $stopScriptPath -Content $stopTemplate
Write-TextFile -Path $shortcutScriptPath -Content $shortcutTemplate
Write-TextFile -Path $batchPath -Content $batchTemplate

$manifest = [ordered]@{
    app_name = $AppName
    slug = $launcherSlug
    target_root = $targetRoot
    static_root = $staticRootPath
    entry_file = $entryPath
    port = $Port
    start_script = $startScriptPath
    stop_script = $stopScriptPath
    shortcut_script = $shortcutScriptPath
    batch_launcher = $batchPath
    server_script = $serverScriptPath
    build_command = $BuildCommand
    edge_mode = "app"
    hardening = @(
        "isolated temporary user-data-dir",
        "disable-sync",
        "disable-extensions",
        "disable first-run and default-browser checks",
        "pre-seeded profile preferences"
    )
}

Write-TextFile -Path $manifestPath -Content ($manifest | ConvertTo-Json -Depth 8)

if ($CreateShortcuts -and -not $NoShortcuts) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $shortcutScriptPath
}

[pscustomobject]$manifest | ConvertTo-Json -Depth 8
