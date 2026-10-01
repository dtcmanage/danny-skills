Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:passed = 0
function Assert-True([bool]$Condition, [string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $script:passed++; Write-Output "PASS: $Name" }
$archiveScript = Join-Path $PSScriptRoot '../archive-v1-state.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('archive-v1-state-' + [guid]::NewGuid().ToString('N'))
$temp = [IO.Path]::GetFullPath($temp)
[IO.Directory]::CreateDirectory((Join-Path $temp 'profiles/history')) | Out-Null
try {
    $files = @('router-table.json', 'drift-flags.json', 'profiles/a.json', 'profiles/history/a-1.json')
    $contents = @('{"fixture":true}', '[]', '{"profile":"a"}', '{"revision":1}')
    for ($i = 0; $i -lt $files.Count; $i++) { [IO.File]::WriteAllText((Join-Path $temp $files[$i]), $contents[$i]) }
    $output = & pwsh -NoProfile -File $archiveScript -StatePath $temp -Date 2026-09-30 -Json
    Assert-True ($LASTEXITCODE -eq 0) 'initial archive exits 0'
    $result = $output | ConvertFrom-Json
    $archive = Join-Path $temp '_archive/v1-2026-09-30'
    Assert-True ((Test-Path -LiteralPath $archive -PathType Container) -and $result.archive_path -eq $archive) 'archive folder exists and is reported'
    Assert-True ($result.copied.Count -eq 3 -and $result.skipped.Count -eq 0) 'present inputs reported as copied'
    foreach ($file in $files) {
        $original = Join-Path $temp $file
        $copy = Join-Path $archive $file
        Assert-True (Test-Path -LiteralPath $original -PathType Leaf) "original remains: $file"
        Assert-True ((Test-Path -LiteralPath $copy -PathType Leaf) -and (Get-FileHash -LiteralPath $original).Hash -eq (Get-FileHash -LiteralPath $copy).Hash) "byte-identical copy: $file"
    }
    $output = & pwsh -NoProfile -File $archiveScript -StatePath $temp -Date 2026-09-30 -Json 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and ($output -join "`n") -match 'Archive already exists') 'second run without Force fails'
    [IO.File]::WriteAllText((Join-Path $temp 'profiles/a.json'), '{"profile":"updated"}')
    $output = & pwsh -NoProfile -File $archiveScript -StatePath $temp -Date 2026-09-30 -Force -Json
    Assert-True ($LASTEXITCODE -eq 0 -and ($output | ConvertFrom-Json).copied.Count -eq 3) 'Force succeeds'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $temp 'profiles/a.json')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $archive 'profiles/a.json')).Hash) 'Force refreshes profile bytes'
    Remove-Item -LiteralPath (Join-Path $temp 'drift-flags.json')
    $output = & pwsh -NoProfile -File $archiveScript -StatePath $temp -Date 2026-10-01 -Json
    Assert-True ($LASTEXITCODE -eq 0) 'missing optional file succeeds'
    $missing = $output | ConvertFrom-Json
    Assert-True ($missing.skipped.Count -eq 1 -and $missing.skipped[0] -eq 'drift-flags.json' -and $missing.copied.Count -eq 2) 'missing drift-flags.json reported as skipped'
    Write-Output "PASS: $script:passed tests"
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $temp.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Fixture cleanup outside temp root: $temp" }
    Remove-Item -LiteralPath $temp -Recurse -Force
}
