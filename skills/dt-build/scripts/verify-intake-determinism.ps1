param(
    [Parameter(Mandatory)]
    [string]$RoadmapPath,

    [Parameter(Mandatory)]
    [string]$KnownGoodDirectory,

    [switch]$RefreshKnownGood
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DirectoryFileHashes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$IncludeFiles = @()
    )
    $files = Get-ChildItem -LiteralPath $Path -File -Recurse | Sort-Object FullName
    $rows = foreach ($file in $files) {
        $rel = $file.FullName.Substring($Path.Length).TrimStart('\', '/')
        if ($IncludeFiles.Count -gt 0 -and ($IncludeFiles -notcontains $rel)) {
            continue
        }
        [pscustomobject]@{
            rel = $rel
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return $rows
}

function Assert-HashSetsEqual {
    param(
        [Parameter(Mandatory)][object[]]$Left,
        [Parameter(Mandatory)][object[]]$Right,
        [Parameter(Mandatory)][string]$Label
    )
    $leftMap = @{}
    foreach ($item in $Left) { $leftMap[$item.rel] = $item.sha256 }
    $rightMap = @{}
    foreach ($item in $Right) { $rightMap[$item.rel] = $item.sha256 }

    $missing = @($leftMap.Keys | Where-Object { -not $rightMap.ContainsKey($_) })
    $extra = @($rightMap.Keys | Where-Object { -not $leftMap.ContainsKey($_) })
    $mismatch = @()
    foreach ($k in $leftMap.Keys) {
        if ($rightMap.ContainsKey($k) -and $leftMap[$k] -ne $rightMap[$k]) {
            $mismatch += "$k (`"$($leftMap[$k])`" != `"$($rightMap[$k])`")"
        }
    }

    if ($missing.Count -gt 0 -or $extra.Count -gt 0 -or $mismatch.Count -gt 0) {
        $parts = @()
        if ($missing.Count -gt 0) { $parts += "missing: $($missing -join ', ')" }
        if ($extra.Count -gt 0) { $parts += "extra: $($extra -join ', ')" }
        if ($mismatch.Count -gt 0) { $parts += "mismatch: $($mismatch -join '; ')" }
        throw "DETERMINISM_FAIL [$Label]: $($parts -join ' | ')"
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$dryRunScript = Join-Path $scriptDir "intake-dry-run.ps1"

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("phase7a-intake-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null

try {
    $deterministicFiles = @(
        "build-state.md",
        "build-decision-log.md",
        "build-plan.md"
    )

    $runA = Join-Path $scratch "run-a"
    $runB = Join-Path $scratch "run-b"

    & $dryRunScript -RoadmapPath $RoadmapPath -OutputDirectory $runA -RunId "phase7a-dryrun" | Out-Null
    & $dryRunScript -RoadmapPath $RoadmapPath -OutputDirectory $runB -RunId "phase7a-dryrun" | Out-Null

    $aDir = Join-Path $runA "phase7a-dryrun"
    $bDir = Join-Path $runB "phase7a-dryrun"
    $hashA = Get-DirectoryFileHashes -Path $aDir -IncludeFiles $deterministicFiles
    $hashB = Get-DirectoryFileHashes -Path $bDir -IncludeFiles $deterministicFiles
    Assert-HashSetsEqual -Left $hashA -Right $hashB -Label "run-a vs run-b"

    if ($RefreshKnownGood -or -not (Test-Path -LiteralPath $KnownGoodDirectory)) {
        New-Item -ItemType Directory -Path $KnownGoodDirectory -Force | Out-Null
        foreach ($file in $deterministicFiles) {
            Copy-Item -LiteralPath (Join-Path $aDir $file) -Destination (Join-Path $KnownGoodDirectory $file) -Force
        }
    }

    $hashKnown = Get-DirectoryFileHashes -Path $KnownGoodDirectory -IncludeFiles $deterministicFiles
    Assert-HashSetsEqual -Left $hashA -Right $hashKnown -Label "run-a vs known-good"

    Write-Output ("PASS: deterministic intake verified against known-good at {0}" -f (Resolve-Path -LiteralPath $KnownGoodDirectory).Path)
}
finally {
    if (Test-Path -LiteralPath $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
