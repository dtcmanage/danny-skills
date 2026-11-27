#Requires -Version 7.0
<#
.SYNOPSIS
Installs a fresh build worktree's project packages from its lockfiles before a builder or verifier runs.
Both chunk wrappers call it for every substantive (non-preflight, non-ad-hoc) dispatch, so a new milestone
worktree never reaches tests without node_modules or its Python environment.

.DESCRIPTION
Each folder holding a lockfile (the worktree root plus any subfolder, skipping node_modules, .git, .venv,
.dt-build, dist and build) is prepared once:
- package-lock.json or npm-shrinkwrap.json -> npm ci
- pnpm-lock.yaml -> pnpm install --frozen-lockfile
- yarn.lock -> yarn install --frozen-lockfile
- uv.lock -> uv sync --frozen
A folder whose install already happened for the current lockfile (a stamp holding the lockfile's sha256,
kept inside node_modules or .venv) is skipped, so repeat dispatches into the same worktree cost nothing.
It always runs a real install: it never links node_modules from another tree (git-workflow.md link footgun).
Set DT_BUILD_SKIP_WORKTREE_DEPS=1 to turn it off for one dispatch.

.PARAMETER ProjectPath
The worktree to prepare.
.PARAMETER Json
Print the report as one JSON document.

.OUTPUTS
{ pass, skipped_reason, prepared: [{ folder, manager, lockfile, action, exit_code, detail }] }.
On failure pass is false and the failing entry carries the last 40 lines of installer output in detail.

.EXAMPLE
pwsh -NoProfile -File prepare-worktree-deps.ps1 -ProjectPath <worktree> -Json
#>
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $ProjectPath).Path
$report = [ordered]@{ pass = $true; skipped_reason = $null; prepared = [Collections.Generic.List[object]]::new() }

function Out-Report {
    if ($Json) { $report | ConvertTo-Json -Depth 6 } else { [pscustomobject]$report }
}

if ($env:DT_BUILD_SKIP_WORKTREE_DEPS -eq '1') {
    $report.skipped_reason = 'DT_BUILD_SKIP_WORKTREE_DEPS=1'
    Out-Report; exit 0
}

$skipDirs = @('node_modules', '.git', '.venv', '.dt-build', 'dist', 'build')
$managers = @(
    @{ lock = 'package-lock.json'; manager = 'npm'; env = 'node_modules'; command = 'npm'; arguments = @('ci', '--no-audit', '--no-fund') }
    @{ lock = 'npm-shrinkwrap.json'; manager = 'npm'; env = 'node_modules'; command = 'npm'; arguments = @('ci', '--no-audit', '--no-fund') }
    @{ lock = 'pnpm-lock.yaml'; manager = 'pnpm'; env = 'node_modules'; command = 'pnpm'; arguments = @('install', '--frozen-lockfile') }
    @{ lock = 'yarn.lock'; manager = 'yarn'; env = 'node_modules'; command = 'yarn'; arguments = @('install', '--frozen-lockfile') }
    @{ lock = 'uv.lock'; manager = 'uv'; env = '.venv'; command = 'uv'; arguments = @('sync', '--frozen') }
)

function Get-LockFolders {
    param([string]$Dir)
    $here = @($Dir)
    foreach ($child in @(Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($skipDirs -contains $child.Name -or $child.LinkType) { continue }
        $here += Get-LockFolders -Dir $child.FullName
    }
    return $here
}

foreach ($folder in @(Get-LockFolders -Dir $root)) {
    $nodeDone = $false
    foreach ($m in $managers) {
        $lockPath = Join-Path $folder $m.lock
        if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { continue }
        # One JavaScript manager per folder: the first lockfile in the list wins.
        if ($m.env -eq 'node_modules') { if ($nodeDone) { continue }; $nodeDone = $true }
        $relative = [IO.Path]::GetRelativePath($root, $folder)
        $entry = [ordered]@{ folder = $relative; manager = $m.manager; lockfile = $m.lock; action = ''; exit_code = 0; detail = '' }
        $envDir = Join-Path $folder $m.env
        $stamp = Join-Path $envDir '.dt-build-deps-stamp'
        $hash = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ((Test-Path -LiteralPath $envDir) -and (Get-Item -LiteralPath $envDir -Force).LinkType) {
            $entry.action = 'failed'; $entry.exit_code = -1
            $entry.detail = "$($m.env) is a link to another tree; remove only the link (rm <worktree>/$($m.env)) and dispatch again"
            $report.prepared.Add($entry); $report.pass = $false; continue
        }
        if ((Test-Path -LiteralPath $stamp -PathType Leaf) -and ((Get-Content -Raw -LiteralPath $stamp).Trim() -eq $hash)) {
            $entry.action = 'current'; $report.prepared.Add($entry); continue
        }
        if (-not (Get-Command $m.command -CommandType Application -ErrorAction SilentlyContinue)) {
            $entry.action = 'failed'; $entry.exit_code = -1; $entry.detail = "$($m.command) is not installed on this host"
            $report.prepared.Add($entry); $report.pass = $false; continue
        }
        Push-Location -LiteralPath $folder
        try { $output = @(& $m.command @($m.arguments) 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
        finally { Pop-Location }
        $entry.exit_code = $code
        if ($code -eq 0) {
            $entry.action = 'installed'
            New-Item -ItemType Directory -Path $envDir -Force | Out-Null
            [IO.File]::WriteAllText($stamp, $hash, [Text.UTF8Encoding]::new($false))
        }
        else {
            $entry.action = 'failed'; $entry.detail = (@($output | Select-Object -Last 40) -join "`n")
            $report.pass = $false
        }
        $report.prepared.Add($entry)
    }
}

Out-Report
exit ([int](-not $report.pass))
