#Requires -Version 7.0
# AI-98: a fresh milestone worktree gets its packages installed from its lockfiles before a worker runs.
# Fixtures only: fake npm/uv shims on PATH record their calls; nothing is downloaded.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:passed = 0
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "ASSERT_FAIL: $Message" }
    $script:passed++; Write-Output "PASS: $Message"
}
function Write-Utf8([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
$scripts = Split-Path -Parent $PSScriptRoot
$prepare = Join-Path $scripts 'prepare-worktree-deps.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('worktree-deps-' + [guid]::NewGuid().ToString('N'))
$savedPath = $env:PATH; $savedSkip = $env:DT_BUILD_SKIP_WORKTREE_DEPS
function Invoke-Prepare([string]$Path) {
    $raw = & pwsh -NoProfile -File $prepare -ProjectPath $Path -Json 2>&1
    return [pscustomobject]@{ code = $LASTEXITCODE; report = (($raw -join "`n") | ConvertFrom-Json) }
}
try {
    $bin = Join-Path $root 'bin'; $calls = Join-Path $root 'calls.log'
    foreach ($tool in @('npm', 'uv')) {
        Write-Utf8 (Join-Path $bin $tool) "#!/bin/sh`necho `"$tool `$* @ `$(pwd)`" >> '$calls'`nif [ -f FAIL_INSTALL ]; then echo 'boom: registry unreachable'; exit 3; fi`nexit 0`n"
        & chmod +x (Join-Path $bin $tool)
    }
    $env:PATH = $bin + [IO.Path]::PathSeparator + $savedPath
    Remove-Item Env:DT_BUILD_SKIP_WORKTREE_DEPS -ErrorAction SilentlyContinue

    $wt = Join-Path $root 'wt'
    Write-Utf8 (Join-Path $wt 'web/package-lock.json') '{"lockfileVersion":3}'
    Write-Utf8 (Join-Path $wt 'uv.lock') 'version = 1'
    Write-Utf8 (Join-Path $wt 'web/node_modules/dep/package-lock.json') '{}'

    $first = Invoke-Prepare $wt
    Assert-True ($first.code -eq 0 -and $first.report.pass) 'a worktree with lockfiles prepares cleanly'
    $log = Get-Content -LiteralPath $calls
    Assert-True (@($log | Where-Object { $_ -like 'npm ci *' -and $_ -like '*@ *web' }).Count -eq 1) 'npm ci runs in the folder holding package-lock.json'
    Assert-True (@($log | Where-Object { $_ -like 'uv sync --frozen*' }).Count -eq 1) 'uv sync --frozen runs for uv.lock'
    Assert-True (@($log | Where-Object { $_ -like '*node_modules*' }).Count -eq 0) 'lockfiles inside node_modules are never installed'

    $second = Invoke-Prepare $wt
    Assert-True ($second.code -eq 0 -and @($second.report.prepared | Where-Object action -ne 'current').Count -eq 0 -and (Get-Content -LiteralPath $calls).Count -eq 2) 'a second dispatch into the same worktree installs nothing'

    Write-Utf8 (Join-Path $wt 'web/package-lock.json') '{"lockfileVersion":3,"changed":true}'
    $third = Invoke-Prepare $wt
    Assert-True ((@($third.report.prepared | Where-Object action -eq 'installed').manager -join ',') -eq 'npm') 'a changed lockfile reinstalls only that folder'

    $bad = Join-Path $root 'bad'
    Write-Utf8 (Join-Path $bad 'package-lock.json') '{}'; Write-Utf8 (Join-Path $bad 'FAIL_INSTALL') ''
    $failed = Invoke-Prepare $bad
    Assert-True ($failed.code -ne 0 -and -not $failed.report.pass -and $failed.report.prepared[0].detail -match 'registry unreachable') 'an install failure fails with the installer output'

    $linked = Join-Path $root 'linked'
    Write-Utf8 (Join-Path $linked 'package-lock.json') '{}'
    New-Item -ItemType SymbolicLink -Path (Join-Path $linked 'node_modules') -Target (Join-Path $wt 'web/node_modules') | Out-Null
    $link = Invoke-Prepare $linked
    Assert-True ($link.code -ne 0 -and $link.report.prepared[0].detail -match 'link to another tree' -and (Test-Path (Join-Path $wt 'web/node_modules/dep'))) 'a linked node_modules is refused and its target left untouched'

    $env:DT_BUILD_SKIP_WORKTREE_DEPS = '1'
    $skip = Invoke-Prepare $bad
    Assert-True ($skip.code -eq 0 -and $skip.report.skipped_reason) 'DT_BUILD_SKIP_WORKTREE_DEPS=1 turns it off'
    Remove-Item Env:DT_BUILD_SKIP_WORKTREE_DEPS

    $empty = Join-Path $root 'empty'; New-Item -ItemType Directory -Path $empty -Force | Out-Null
    $none = Invoke-Prepare $empty
    Assert-True ($none.code -eq 0 -and @($none.report.prepared).Count -eq 0) 'a worktree without lockfiles is a no-op'

    foreach ($wrapper in @('invoke-claude-chunk.ps1', 'invoke-codex-chunk.ps1')) {
        $text = [IO.File]::ReadAllText((Join-Path $scripts $wrapper))
        Assert-True ($text -match "prepare-worktree-deps\.ps1" -and $text -match 'DEPS_INSTALL_FAIL' -and $text -match 'if \(-not \$Preflight -and -not \$AdHoc\)') "$wrapper prepares the worktree before every substantive dispatch"
    }
}
finally {
    $env:PATH = $savedPath
    if ($null -ne $savedSkip) { $env:DT_BUILD_SKIP_WORKTREE_DEPS = $savedSkip } else { Remove-Item Env:DT_BUILD_SKIP_WORKTREE_DEPS -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "ALL PASS ($script:passed)"
