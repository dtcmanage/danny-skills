Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passed = 0
function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_FAIL: $Message" }; $script:passed++
}
$probe = Join-Path $PSScriptRoot '../measure-build-host.ps1'
. $probe
$budget = Get-BuildHardwareBudget -LogicalProcessors 32 -TotalRamGB 63 -FreeRamGB 50 -MemoryPerJobGB 2
Check ($budget.new_heavy_job_cap -eq 8) '32 threads allocate eight heavy slots with headroom'
Check ([math]::Abs($budget.headroom_gb - 6.3) -lt 0.0001) 'RAM headroom retains the full ten percent without integer rounding'
$budget = Get-BuildHardwareBudget -LogicalProcessors 32 -TotalRamGB 63 -FreeRamGB 12 -MemoryPerJobGB 3 -RunningHeavyJobs 2
Check ($budget.new_heavy_job_cap -eq 1) 'RAM ceiling dominates CPU slots without double-subtracting running memory'
$budget = Get-BuildHardwareBudget -LogicalProcessors 32 -TotalRamGB 63 -FreeRamGB 50 -MemoryPerJobGB 2 -RunningHeavyJobs 3
Check ($budget.new_heavy_job_cap -eq 5) 'running heavy work reserves CPU slots'
$budget = Get-BuildHardwareBudget -LogicalProcessors 32 -TotalRamGB 63 -FreeRamGB 5 -MemoryPerJobGB 2
Check ($budget.new_heavy_job_cap -eq 0) 'memory pressure does not force a minimum job'
$budget = Get-BuildHardwareBudget -LogicalProcessors 2 -TotalRamGB 8 -FreeRamGB 6 -MemoryPerJobGB 2
Check ($budget.new_heavy_job_cap -eq 1) 'small hosts receive one slot when RAM permits'
$root = Join-Path $PSScriptRoot ('hardware-fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $root 'build-state.md') -Value "# Fixture`n## Run`nRUN_ID: fixture"
    $live = (& pwsh -NoProfile -File $probe -RunFolder $root -MemoryPerJobGB 2) | ConvertFrom-Json
    Check ($LASTEXITCODE -eq 0 -and $live.logical_processors -gt 0 -and $live.total_ram_gb -gt 0 -and $live.PSObject.Properties['other_heavy_job_running']) 'live probe measures host and other work'
    $state = Get-Content (Join-Path $root 'build-state.md') -Raw
    Check ($state.Contains('new_heavy_job_cap') -and $state.Contains('hardware-snapshot.json') -and $state.Contains('RUN_ID: fixture')) 'build state retains identity and records hardware allocation'
    & pwsh -NoProfile -File $probe -RunFolder $root -MemoryPerJobGB 3 | Out-Null
    $state = Get-Content (Join-Path $root 'build-state.md') -Raw
    $refreshed = Get-Content (Join-Path $root 'hardware-snapshot.json') -Raw | ConvertFrom-Json
    Check ($LASTEXITCODE -eq 0 -and ([regex]::Matches($state, '(?m)^## Throughput and hardware$')).Count -eq 1 -and $state.Contains('RUN_ID: fixture') -and $refreshed.memory_per_job_gb -eq 3) 'resume refresh replaces the allocation without duplicating sections or losing state'
    . (Join-Path $PSScriptRoot '../worker-standing-rules.ps1')
    $rule = Get-WorkerHardwareRule
    Check ($rule.Contains('pytest-xdist -n <budget>') -and $rule.Contains('plan''s named reason') -and $rule.Contains('exclusive_reason is opt-in')) 'worker rule requires bounded sharding and named serial causes'
    Write-Output "SUMMARY: $passed passed"
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
