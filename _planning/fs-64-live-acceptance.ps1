#Requires -Version 7.0
# Read-only live sources; every write stays beside this script in fs-64-live-dryrun.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scripts = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/dt-build/scripts'
$run = 'D:/Claude/_Claude-Workspace/OneDrive Migration/File Sorter/file-sorter/.dt-build/core-durability-20260922/core-durability-20260922'
$checkpoint = 'D:/Claude/_Claude-Workspace/OneDrive Migration/File Sorter/db-durability-refresh/design/_build-state.md'
$output = Join-Path $PSScriptRoot 'fs-64-live-dryrun'
. (Join-Path $scripts 'authority-digest.ps1')
$before = @(Get-AuthorityInventory $run $checkpoint)
$checkpointBefore = Get-AuthorityHash $checkpoint
$rootBefore = @(Get-ChildItem -LiteralPath $run -File | Sort-Object Name | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" })
$build = & (Join-Path $scripts 'build-authority-digest.ps1') -RunFolder $run -BuildStatePath $checkpoint -DryRun -OutputDirectory $output | ConvertFrom-Json
$verification = & (Join-Path $scripts 'verify-authority-digest.ps1') -RunFolder $run -BuildStatePath $checkpoint -DigestDirectory $output | ConvertFrom-Json
$after = @(Get-AuthorityInventory $run $checkpoint)
$rootAfter = @(Get-ChildItem -LiteralPath $run -File | Sort-Object Name | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" })
if ((ConvertTo-Json -InputObject $before -Depth 5 -Compress) -cne (ConvertTo-Json -InputObject $after -Depth 5 -Compress) -or
    $checkpointBefore -cne (Get-AuthorityHash $checkpoint) -or ($rootBefore -join "`n") -cne ($rootAfter -join "`n")) { throw 'LIVE_SOURCE_CHANGED: checkpoint, originals or root file metadata changed during acceptance' }
if (-not $build.verified -or -not $verification.verified -or $verification.enumerated_originals -ne 99 -or $verification.originals_discovered -ne 109 -or $verification.unresolved_candidates.Count) { throw 'LIVE_ACCEPTANCE_FAILED' }
$result = [ordered]@{ build_verified = $build.verified; independent_verification = $verification; source_originals_unchanged = $true; checkpoint_unchanged = $true; run_root_files_unchanged = $true; checkpoint_bytes = (Get-Item -LiteralPath $checkpoint).Length; lease_bytes = (Get-Item -LiteralPath (Join-Path $run 'coordinator.lease')).Length }
[IO.File]::WriteAllText((Join-Path $output 'acceptance.json'), ($result | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$result | ConvertTo-Json -Depth 8
