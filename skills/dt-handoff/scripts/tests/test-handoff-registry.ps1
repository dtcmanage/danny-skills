Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passed = 0; $failed = [Collections.Generic.List[string]]::new()
function Check([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passed++ } else { $script:failed.Add($Message) }
}
function Invoke-Git([string]$Repo) {
    & git -C $Repo -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false @args | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git $args failed in $Repo" }
}
$registry = Join-Path (Split-Path -Parent $PSScriptRoot) 'handoff-registry.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('handoff-registry-' + [guid]::NewGuid().ToString('N'))
try {
    # Workspace repo with a workstation holding its own handoffs and a nested code repo.
    $workstation = Join-Path $root 'Workstation'
    $ownConsumed = Join-Path $workstation '_handoffs/consumed'
    $nestedRepo = Join-Path $workstation 'code-repo'
    $nestedConsumed = Join-Path $nestedRepo '_handoffs/consumed'
    foreach ($dir in @($ownConsumed, $nestedConsumed)) { [void][IO.Directory]::CreateDirectory($dir) }
    Set-Content -LiteralPath (Join-Path $ownConsumed 'handoff-2020-01-01-workspace.md') -Value 'old workspace handoff'
    Set-Content -LiteralPath (Join-Path $ownConsumed 'handoff-2099-01-01-fresh.md') -Value 'not old enough'
    Set-Content -LiteralPath (Join-Path $nestedConsumed 'handoff-2020-01-01-nested.md') -Value 'old nested handoff'
    Invoke-Git $nestedRepo init -q
    Invoke-Git $nestedRepo add -A
    Invoke-Git $nestedRepo commit -q -m fixture
    Set-Content -LiteralPath (Join-Path $root '.gitignore') -Value 'Workstation/code-repo/'
    Invoke-Git $root init -q
    Invoke-Git $root add -A
    Invoke-Git $root commit -q -m fixture

    $result = & pwsh -NoProfile -File $registry -Root $workstation -Prune -Json | ConvertFrom-Json
    Check ($LASTEXITCODE -eq 0) 'prune run succeeds'
    Check (@($result.pruned).Count -eq 1 -and $result.pruned[0].name -eq 'handoff-2020-01-01-workspace.md') 'old workspace handoff is archived'
    Check (Test-Path -LiteralPath (Join-Path $ownConsumed '_archive/handoff-2020-01-01-workspace.md')) 'workspace handoff moved into consumed/_archive'
    Check (Test-Path -LiteralPath (Join-Path $ownConsumed 'handoff-2099-01-01-fresh.md')) 'fresh consumed handoff stays'
    $skips = @(if ($result.PSObject.Properties['skipped_nested_repo']) { $result.skipped_nested_repo })
    Check ($skips.Count -eq 1 -and $skips[0].name -eq 'handoff-2020-01-01-nested.md') 'nested-repo handoff reported as skipped_nested_repo'
    Check ($skips.Count -eq 1 -and $skips[0].repo -eq [IO.Path]::GetFullPath($nestedRepo)) 'skip names the owning nested repository'
    Check (Test-Path -LiteralPath (Join-Path $nestedConsumed 'handoff-2020-01-01-nested.md')) 'nested-repo handoff left in place'
    Check (-not (Test-Path -LiteralPath (Join-Path $nestedConsumed '_archive'))) 'no archive folder created inside the nested repo'
    $nestedStatus = (& git -C $nestedRepo status --porcelain) -join "`n"
    Check ([string]::IsNullOrEmpty($nestedStatus)) "nested repo stays clean (status: $nestedStatus)"

    $plain = (& pwsh -NoProfile -File $registry -Root $workstation -Prune) -join "`n"
    Check ($plain -match 'Skipped, inside a nested repository \(1\)' -and $plain.Contains('handoff-2020-01-01-nested.md')) 'plain output lists the skipped file'
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Output "SUMMARY: $passed passed, $($failed.Count) failed"
if ($failed.Count) { $failed | ForEach-Object { Write-Output "FAIL: $_" }; exit 1 }
