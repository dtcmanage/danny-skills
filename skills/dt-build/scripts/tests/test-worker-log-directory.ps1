#Requires -Version 7.0
# B2 fix 8: builder logs default to the run folder (jobs/<id>/logs or logs beside the report), never the
# worktree, its parent, the home directory or a shared temp root. Fixtures only; no model or vendor processes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:passed = 0
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "ASSERT_FAIL: $Message" }
    $script:passed++; Write-Output "PASS: $Message"
}
$scripts = Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'worker-standing-rules.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('worker-logs-' + [guid]::NewGuid().ToString('N'))
try {
    $worktree = Join-Path $root 'wt-m01'
    $run = Join-Path $root 'run folder/mst-x'
    New-Item -ItemType Directory -Path $worktree, (Join-Path $run 'milestones/M01'), (Join-Path $run 'jobs/j-0007') -Force | Out-Null
    $full = { param([string]$Path) [IO.Path]::GetFullPath($Path) }

    $job = Get-WorkerLogDirectory -ProjectRoot $worktree -OutputPath (Join-Path $run 'milestones/M01/report-a1.md') -JobDirectory (Join-Path $run 'jobs/j-0007')
    Assert-True ($job -eq (& $full (Join-Path $run 'jobs/j-0007/logs')) -and (Test-Path -LiteralPath $job -PathType Container)) "a dt-job worker logs into jobs/<id>/logs ($job)"

    $beside = Get-WorkerLogDirectory -ProjectRoot $worktree -OutputPath (Join-Path $run 'milestones/M01/report-a1.md') -JobDirectory ''
    Assert-True ($beside -eq (& $full (Join-Path $run 'milestones/M01/logs'))) "a direct dispatch logs beside its report in the run folder ($beside)"

    $inTree = Get-WorkerLogDirectory -ProjectRoot $worktree -OutputPath (Join-Path $worktree 'report.md') -JobDirectory '' -Label 'M01 chunk'
    Assert-True (-not $inTree.StartsWith((& $full $worktree)) -and $inTree.StartsWith((& $full ([IO.Path]::GetTempPath()))) -and $inTree -match 'dt-build-logs[\\/]M01-chunk-') "a report inside the worktree never puts logs in the worktree ($inTree)"

    $treeParent = Get-WorkerLogDirectory -ProjectRoot (Join-Path $root 'p/wt') -OutputPath (Join-Path $root 'p/x/report.md') -JobDirectory ''
    Assert-True ($treeParent -eq (& $full (Join-Path $root 'p/x/logs'))) 'a run-folder sibling of the worktree is accepted'
    $isParent = Get-WorkerLogDirectory -ProjectRoot (Join-Path $root 'r/logs/wt') -OutputPath (Join-Path $root 'r/x.md') -JobDirectory ''
    Assert-True ($isParent -ne (& $full (Join-Path $root 'r/logs')) -and $isParent.StartsWith((& $full ([IO.Path]::GetTempPath())))) "the worktree's parent (the M04 case) is never the log folder ($isParent)"
    $tempOut = Get-WorkerLogDirectory -ProjectRoot $worktree -OutputPath (Join-Path ([IO.Path]::GetTempPath()) 'preflight.md') -JobDirectory ''
    Assert-True ($tempOut -ne (& $full (Join-Path ([IO.Path]::GetTempPath()) 'logs'))) "a preflight report in the temp root does not share one temp logs folder ($tempOut)"

    $none = Get-WorkerLogDirectory -ProjectRoot $worktree -JobDirectory ''
    Assert-True ($none.StartsWith((& $full ([IO.Path]::GetTempPath()))) -and (Test-Path -LiteralPath $none -PathType Container)) 'no job and no report falls back to a private temp folder, never the process cwd'

    $rule = Get-WorkerLogRule
    Assert-True ($rule.Contains('DT_BUILD_LOG_DIR') -and $rule.Contains('never into the worktree') -and $rule.Contains('home directory')) 'the standing log rule names DT_BUILD_LOG_DIR and the forbidden places'
    $assembler = [IO.File]::ReadAllText((Join-Path $scripts 'assemble-codex-prompt.ps1'))
    Assert-True ($assembler.Contains('$logRule = Get-WorkerLogRule') -and $assembler.Contains('- $logRule')) 'every assembled chunk prompt carries the log rule'
    foreach ($wrapper in @('invoke-claude-chunk.ps1', 'invoke-codex-chunk.ps1')) {
        $text = [IO.File]::ReadAllText((Join-Path $scripts $wrapper))
        Assert-True ($text.Contains("{ `$startInfo.Environment['DT_BUILD_LOG_DIR'] = Get-WorkerLogDirectory")) "$wrapper hands the child DT_BUILD_LOG_DIR"
    }
    Write-Output "SUMMARY: $script:passed passed"
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    Get-ChildItem -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) 'dt-build-logs') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -gt [DateTime]::UtcNow.AddMinutes(-10) -and $_.Name -match '^(?:worker|M01-chunk)-' } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
