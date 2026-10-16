# Worker process-tree custody for the chunk wrappers (invoke-codex-chunk.ps1, invoke-claude-chunk.ps1).
# A worker CLI can leave a grandchild running after it finishes (Oct 15: an orphaned python child of a
# Codex worker held the wrapper's stdout pipe open for 33 minutes and grew to 12.7 GB). On Windows the
# wrapper joins a fresh job object before it starts the CLI, so every descendant, orphaned or not, is
# listed in the job and can be stopped once the dispatch is over. Elsewhere the stream drain is still
# bounded, so a held pipe can never hang the wrapper.

$script:WorkerJobHandle = [IntPtr]::Zero
$script:WorkerJobState = 'not_initialized'

function Initialize-WorkerProcessJob {
    if ($script:WorkerJobState -ne 'not_initialized') { return $script:WorkerJobState }
    if (-not $IsWindows) { $script:WorkerJobState = 'unsupported_platform'; return $script:WorkerJobState }
    try {
        if (-not ('DtWorkerJob' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DtWorkerJob {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, int length, out int returned);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, int length);
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimit { public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters { public ulong ReadOperationCount; public ulong WriteOperationCount; public ulong OtherOperationCount; public ulong ReadTransferCount; public ulong WriteTransferCount; public ulong OtherTransferCount; }
    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimit { public BasicLimit BasicLimitInformation; public IoCounters IoInfo; public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed; }
    public static bool KillOnClose;
    public static IntPtr CreateAndAssignSelf() {
        IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) { return IntPtr.Zero; }
        // FS-96: JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE. The wrapper holds the only handle, so when it exits or is
        // killed (dt-job cancel), Windows ends every process still in the job, orphans and shim children included.
        ExtendedLimit info = new ExtendedLimit();
        info.BasicLimitInformation.LimitFlags = 0x2000;
        int size = Marshal.SizeOf(typeof(ExtendedLimit));
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try { Marshal.StructureToPtr(info, buffer, false); KillOnClose = SetInformationJobObject(job, 9, buffer, size); }
        finally { Marshal.FreeHGlobal(buffer); }
        if (!AssignProcessToJobObject(job, GetCurrentProcess())) { return IntPtr.Zero; }
        return job;
    }
    public static int[] ListProcessIds(IntPtr job) {
        // JOBOBJECT_BASIC_PROCESS_ID_LIST: two DWORD counts, then ULONG_PTR ids at offset 8.
        const int capacity = 4096;
        int size = 8 + IntPtr.Size * capacity;
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try {
            int returned;
            if (!QueryInformationJobObject(job, 3, buffer, size, out returned)) { return new int[0]; }
            int count = Marshal.ReadInt32(buffer, 4);
            int[] ids = new int[count];
            for (int i = 0; i < count; i++) { ids[i] = (int)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size).ToInt64(); }
            return ids;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
}
'@
        }
        $script:WorkerJobHandle = [DtWorkerJob]::CreateAndAssignSelf()
        $script:WorkerJobState = if ($script:WorkerJobHandle -ne [IntPtr]::Zero) { 'job_object' } else { 'job_object_unavailable' }
        $script:WorkerJobKillOnClose = ($script:WorkerJobState -eq 'job_object' -and [DtWorkerJob]::KillOnClose)
    }
    catch { $script:WorkerJobState = 'job_object_unavailable' }
    return $script:WorkerJobState
}

function Get-WorkerJobProcesses {
    # Live descendants of this wrapper (the wrapper itself excluded), orphans included.
    if ($script:WorkerJobState -ne 'job_object') { return @() }
    @([DtWorkerJob]::ListProcessIds($script:WorkerJobHandle) | Where-Object { $_ -ne $PID } | ForEach-Object {
        try { Get-Process -Id $_ -ErrorAction Stop } catch { }
    })
}

function Stop-WorkerJobProcesses([int[]]$ExceptIds = @()) {
    # Stop every live descendant except the named ones; return what was stopped.
    $stopped = [Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-WorkerJobProcesses)) {
        if ($process.Id -in $ExceptIds) { continue }
        $record = [ordered]@{ pid = $process.Id; name = $process.ProcessName; working_set_mb = [int]($process.WorkingSet64 / 1MB) }
        try { $process.Kill($true); [void]$process.WaitForExit(5000); $stopped.Add([pscustomobject]$record) } catch { }
    }
    return @($stopped)
}

function Complete-WorkerDispatch {
    # Called once the worker CLI has exited or been killed. Drains its output for at most GraceMs; a
    # descendant still holding the pipes after that is stopped, then every remaining descendant is
    # stopped so nothing outlives the dispatch. Never waits unbounded.
    param(
        [Parameter(Mandatory)][System.Threading.Tasks.Task[]]$OutputTasks,
        [int]$GraceMs = 30000
    )
    $stopped = [Collections.Generic.List[object]]::new()
    $drained = $false
    try { $drained = [System.Threading.Tasks.Task]::WaitAll($OutputTasks, $GraceMs) } catch [System.AggregateException] { $drained = $true }
    if (-not $drained) {
        foreach ($item in @(Stop-WorkerJobProcesses)) { $stopped.Add($item) }
        try { $drained = [System.Threading.Tasks.Task]::WaitAll($OutputTasks, 10000) } catch [System.AggregateException] { $drained = $true }
    }
    foreach ($item in @(Stop-WorkerJobProcesses)) { $stopped.Add($item) }
    $text = @($OutputTasks | ForEach-Object { if ($_.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) { [string]$_.Result } else { '' } })
    return [pscustomobject]@{
        stdout = $text[0]; stderr = $text[1]
        streams_drained = $drained
        custody = $script:WorkerJobState
        orphans_stopped = @($stopped)
    }
}
