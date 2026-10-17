#Requires -Version 7.0
param(
    [string]$RunFolder,
    [ValidateRange(0.01, 1048576)][double]$MemoryPerJobGB = 2
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-BuildHardwareBudget {
    param(
        [ValidateRange(1, 1048576)][int]$LogicalProcessors,
        [ValidateRange(0.01, 1048576)][double]$TotalRamGB,
        [ValidateRange(0, 1048576)][double]$FreeRamGB,
        [ValidateRange(0.01, 1048576)][double]$MemoryPerJobGB,
        [ValidateRange(0, 1048576)][int]$RunningHeavyJobs = 0
    )
    $headroom = [math]::Max(2.0, $TotalRamGB * 0.1)
    $cpuSlots = [math]::Max(1, [math]::Floor($LogicalProcessors / 4))
    $ramSlots = [math]::Max(0, [math]::Floor(($FreeRamGB - $headroom) / $MemoryPerJobGB))
    [pscustomobject]@{
        cpu_slots = [int]$cpuSlots
        ram_slots = [int]$ramSlots
        headroom_gb = $headroom
        new_heavy_job_cap = [int][math]::Min([math]::Max(0, $cpuSlots - $RunningHeavyJobs), $ramSlots)
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $RunFolder -or -not (Test-Path -LiteralPath (Join-Path $RunFolder 'build-state.md'))) {
    throw 'HARDWARE_STATE_MISSING: create build-state.md before measuring the host.'
}

$source = ''
if ($IsWindows) {
    $cpu = @(Get-CimInstance Win32_Processor)
    $os = Get-CimInstance Win32_OperatingSystem
    $cores = [int](($cpu | Measure-Object NumberOfCores -Sum).Sum)
    $logical = [int](($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum)
    $total = $os.TotalVisibleMemorySize * 1KB / 1GB
    $free = $os.FreePhysicalMemory * 1KB / 1GB
    $source = 'Win32_Processor; Win32_OperatingSystem; Get-Process CPU delta over 1s'
} elseif ($IsLinux) {
    $logical = [int](& nproc)
    $cores = @(& lscpu '--parse=CORE,SOCKET' | Where-Object { $_ -notmatch '^#' } | Sort-Object -Unique).Count
    $mem = Get-Content -LiteralPath '/proc/meminfo' -Raw
    $total = [double]([regex]::Match($mem, '(?m)^MemTotal:\s+(\d+)').Groups[1].Value) * 1KB / 1GB
    $free = [double]([regex]::Match($mem, '(?m)^MemAvailable:\s+(\d+)').Groups[1].Value) * 1KB / 1GB
    $source = 'nproc; lscpu; /proc/meminfo; Get-Process CPU delta over 1s'
} elseif ($IsMacOS) {
    $cores = [int](& sysctl -n hw.physicalcpu)
    $logical = [int](& sysctl -n hw.logicalcpu)
    $total = [double](& sysctl -n hw.memsize) / 1GB
    $vm = (& vm_stat) -join "`n"
    $page = [double]([regex]::Match($vm, 'page size of (\d+) bytes').Groups[1].Value)
    $pages = 0.0
    foreach ($kind in @('free', 'inactive', 'speculative')) {
        $pages += [double]([regex]::Match($vm, "Pages ${kind}:\s+(\d+)").Groups[1].Value)
    }
    $free = $pages * $page / 1GB
    $source = 'sysctl; vm_stat free/inactive/speculative pages; Get-Process CPU delta over 1s'
} else { throw 'HARDWARE_PLATFORM_UNKNOWN: provide a measured host probe.' }
if ($cores -le 0 -or $logical -le 0 -or $total -le 0) { throw 'HARDWARE_PROBE_FAILED: invalid host measurements.' }

# Sample activity instead of treating a long-lived process's cumulative CPU as current load.
$before = @{}
foreach ($p in Get-Process) { if ($null -ne $p.CPU) { $before[$p.Id] = [double]$p.CPU } }
$timer = [Diagnostics.Stopwatch]::StartNew()
Start-Sleep -Seconds 1
$heavy = @(foreach ($p in Get-Process) {
    if ($p.Id -eq $PID -or -not $before.ContainsKey($p.Id) -or $null -eq $p.CPU) { continue }
    $cpuCores = [math]::Max(0, ([double]$p.CPU - $before[$p.Id]) / $timer.Elapsed.TotalSeconds)
    if ($cpuCores -ge 0.25 -or $p.WorkingSet64 -ge 1GB) {
        [pscustomobject]@{ pid = $p.Id; name = $p.ProcessName; cpu_cores = [math]::Round($cpuCores, 2); working_set_gb = [math]::Round($p.WorkingSet64 / 1GB, 2) }
    }
})
$budget = Get-BuildHardwareBudget -LogicalProcessors $logical -TotalRamGB $total -FreeRamGB $free -MemoryPerJobGB $MemoryPerJobGB -RunningHeavyJobs $heavy.Count
$snapshot = [ordered]@{
    host_name = [Environment]::MachineName; measured_at = (Get-Date).ToString('o'); source = $source
    physical_cores = $cores; logical_processors = $logical; total_ram_gb = $total; free_ram_gb = $free
    other_heavy_job_running = ($heavy.Count -gt 0); heavy_process_candidates = $heavy
    memory_per_job_gb = $MemoryPerJobGB; memory_basis = 'estimate; replace with workload peak including shards'
    budget = $budget
}
$json = $snapshot | ConvertTo-Json -Depth 7
$path = Join-Path $RunFolder 'hardware-snapshot.json'
[IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
$statePath = Join-Path $RunFolder 'build-state.md'
$state = [IO.File]::ReadAllText($statePath)
$state = [regex]::Replace($state, '(?ms)^## Throughput and hardware\r?\n.*?(?=^## |\z)', '')
$state += "`n## Throughput and hardware`nHost: $($snapshot.host_name); logical_processors: $logical; RAM_GiB: $total; free_GiB: $free`nOther heavy process candidates: $($heavy.Count); new_heavy_job_cap: $($budget.new_heavy_job_cap); RAM_per_job_GiB: $MemoryPerJobGB (estimate)`nSnapshot: $path`n"
& (Join-Path $PSScriptRoot 'write-build-state.ps1') -Path $statePath -Content $state | Out-Null
$json
