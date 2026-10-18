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
    Check ($live.memory_per_job_source -eq 'explicit') 'explicit memory overrides history'
    $fallback = (& pwsh -NoProfile -File $probe -RunFolder $root) | ConvertFrom-Json
    Check ($fallback.memory_per_job_gb -eq 2 -and $fallback.memory_per_job_source -eq 'default') 'empty history falls back to 2 GB'
    $jobs = Join-Path $root 'jobs'
    New-Item -ItemType Directory -Path $jobs | Out-Null
    foreach ($i in 0..21) {
        @{ status = 'succeeded'; ended = [DateTime]::UtcNow.AddMinutes(-$i).ToString('o'); kind = 'test'; peak_memory_gb = $(if ($i -ge 20) { 99 } else { 4 }) } |
            ConvertTo-Json | Set-Content (Join-Path $jobs "$i.json")
    }
    @{ status = 'failed'; ended = [DateTime]::UtcNow.ToString('o'); kind = 'build'; peak_memory_gb = 8 } | ConvertTo-Json | Set-Content (Join-Path $jobs 'build.json')
    @{ status = 'running'; ended = $null; kind = 'test'; peak_memory_gb = 100 } | ConvertTo-Json | Set-Content (Join-Path $jobs 'running.json')
    $measured = (& pwsh -NoProfile -File $probe -RunFolder $root -Kind test) | ConvertFrom-Json
    Check ($measured.memory_per_job_gb -eq 5 -and $measured.memory_per_job_source -eq 'measured (20 jobs, max 4 GB)') 'history filters kind and uses only last 20 finished jobs'
    $override = (& pwsh -NoProfile -File $probe -RunFolder $root -Kind test -MemoryPerJobGB 3) | ConvertFrom-Json
    Check ($override.memory_per_job_gb -eq 3 -and $override.memory_per_job_source -eq 'explicit') 'explicit memory wins over measured history'
    $all = Get-BuildMemoryHistory -RunFolder $root
    Check ($all.value -eq 10 -and $all.source -eq 'measured (20 jobs, max 8 GB)') 'omitted kind includes all kinds and failed jobs'
    Check ((Get-BuildMemoryHistory -RunFolder $root -Kind absent).source -eq 'default') 'unmatched kind falls back'
    @{ status = 'succeeded'; ended = [DateTime]::UtcNow.ToString('o'); kind = 'small'; peak_memory_gb = 0.1 } | ConvertTo-Json | Set-Content (Join-Path $jobs 'small.json')
    Check ((Get-BuildMemoryHistory -RunFolder $root -Kind small).value -eq 0.5) 'measured sizing retains 0.5 GB floor'
    @{ status = 'succeeded'; ended = [DateTime]::UtcNow.ToString('o'); kind = 'unknown'; peak_memory_gb = $null } | ConvertTo-Json | Set-Content (Join-Path $jobs 'unknown.json')
    Check ((Get-BuildMemoryHistory -RunFolder $root -Kind unknown).source -eq 'default') 'null peaks do not invent history'
    . (Join-Path $PSScriptRoot '../worker-standing-rules.ps1')
    $rule = Get-WorkerHardwareRule
    Check ($rule.Contains('pytest-xdist -n <budget>') -and $rule.Contains('plan''s named reason') -and $rule.Contains('exclusive_reason is opt-in')) 'worker rule requires bounded sharding and named serial causes'
    Write-Output "SUMMARY: $passed passed"
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
