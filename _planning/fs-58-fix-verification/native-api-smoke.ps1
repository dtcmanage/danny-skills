# ABI / Windows API smoke only. Add-Type compiles in this PowerShell process;
# no Python or other child is started. This does not execute the Python backend.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Fs58NativeSmoke {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct Entry {
        public UInt32 size, usage, pid;
        public UIntPtr heap;
        public UInt32 module, threads, ppid;
        public Int32 priority;
        public UInt32 flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string exe;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct FileTime { public UInt32 low, high; }
    [DllImport("kernel32", SetLastError=true)]
    static extern IntPtr CreateToolhelp32Snapshot(UInt32 flags, UInt32 pid);
    [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool Process32FirstW(IntPtr snapshot, ref Entry entry);
    [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool Process32NextW(IntPtr snapshot, ref Entry entry);
    [DllImport("kernel32", SetLastError=true)]
    static extern IntPtr OpenProcess(UInt32 access, bool inherit, UInt32 pid);
    [DllImport("kernel32", SetLastError=true)]
    static extern bool GetProcessTimes(IntPtr process, out FileTime creation,
        out FileTime exit, out FileTime system, out FileTime user);
    [DllImport("kernel32", SetLastError=true)]
    static extern bool CloseHandle(IntPtr handle);
    public static int EntrySize() { return Marshal.SizeOf<Entry>(); }
    public static Dictionary<UInt32, UInt32> Parents() {
        var snapshot = CreateToolhelp32Snapshot(2, 0);
        if (snapshot == new IntPtr(-1)) throw new Exception("snapshot failed");
        try {
            var entry = new Entry { size = (UInt32)EntrySize() };
            if (!Process32FirstW(snapshot, ref entry)) throw new Exception("first failed");
            var parents = new Dictionary<UInt32, UInt32>();
            do { parents[entry.pid] = entry.ppid; }
            while (Process32NextW(snapshot, ref entry));
            if (Marshal.GetLastWin32Error() != 18) throw new Exception("unexpected enumeration error");
            return parents;
        } finally { CloseHandle(snapshot); }
    }
    public static UInt64? Start(UInt32 pid) {
        var process = OpenProcess(0x1000, false, pid);
        if (process == IntPtr.Zero) return null;
        try {
            FileTime creation, exit, system, user;
            if (!GetProcessTimes(process, out creation, out exit, out system, out user)) return null;
            return ((UInt64)creation.high << 32) | creation.low;
        } finally { CloseHandle(process); }
    }
}
'@
$passed = 0
function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw "ASSERT_FAIL: $message" }
    $script:passed++
    Write-Output "PASS: $message"
}
Assert-True ([Fs58NativeSmoke]::EntrySize() -eq 568) '64-bit PROCESSENTRY32W layout is 568 bytes'
$parents = [Fs58NativeSmoke]::Parents()
$currentPid = [uint32]$PID
$currentStart = [Fs58NativeSmoke]::Start($currentPid)
Assert-True ($null -ne $currentStart -and $currentStart -eq [Fs58NativeSmoke]::Start($currentPid)) 'native creation identity is present and stable'
Assert-True ($currentStart -eq (Get-Process -Id $PID).StartTime.ToFileTimeUtc()) 'GetProcessTimes equals independent .NET StartTime'
$cim = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
Assert-True ($parents[$currentPid] -eq $cim.ParentProcessId) 'Toolhelp parent equals independent CIM parent'
$parentStart = [Fs58NativeSmoke]::Start($parents[$currentPid])
Assert-True ($null -ne $parentStart -and $parentStart -le $currentStart) 'parent identity is older than child identity'
Assert-True ($null -eq [Fs58NativeSmoke]::Start([uint32]::MaxValue)) 'nonexistent PID cannot supply an identity'
Write-Output "SUMMARY: $passed passed; native API smoke only; Python backend deferred"
