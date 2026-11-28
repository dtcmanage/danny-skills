# Shared across worktrees; keep the inode and let the OS release the handle on exit.
if (-not ('DtRuntimeTestLeaseHandle' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
public sealed class DtRuntimeTestLeaseHandle : IDisposable {
    private readonly FileStream mutex;
    private readonly FileStream proof;
    private readonly string proofPath;
    public string Nonce { get; }
    public bool CanWrite => mutex.CanWrite && proof.CanWrite;
    public DtRuntimeTestLeaseHandle(FileStream mutex, FileStream proof, string nonce, string proofPath) {
        this.mutex = mutex; this.proof = proof; Nonce = nonce; this.proofPath = proofPath;
    }
    public void Dispose() {
        try { proof.Dispose(); try { File.Delete(proofPath); } catch (IOException) { } }
        finally { mutex.Dispose(); }
        GC.SuppressFinalize(this);
    }
    ~DtRuntimeTestLeaseHandle() { try { Dispose(); } catch { } }
}
'@
}

function Get-TestWorkerBudget {
    param([int]$Limit = 16, [int]$CpuCount = [Environment]::ProcessorCount,
        [double]$Load = -1)
    if ($Load -lt 0) {
        if (Test-Path /proc/loadavg) {
            $Load = [double]::Parse(([IO.File]::ReadAllText('/proc/loadavg').Split(' ')[0]), [Globalization.CultureInfo]::InvariantCulture)
        } elseif (-not $IsWindows) {
            $sample = & sysctl -n vm.loadavg 2>$null
            if ($LASTEXITCODE -eq 0 -and "$sample" -match '([0-9]+\.[0-9]+)') {
                $Load = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
            }
        }
        # No reliable live load measurement: reserve half the CPUs.
        if ($Load -lt 0) { $Load = $CpuCount / 2 }
    }
    # Leave 25% CPU headroom; overcommitted hosts admit one worker, never zero.
    return [Math]::Max(1, [Math]::Min($Limit, [int][Math]::Floor($CpuCount * 0.75 - $Load)))
}

function Get-RuntimeProcessIdentity {
    param([int]$ProcessId)
    try {
        if ($IsLinux) {
            # /proc field 22 is the kernel start tick, independent of .NET's
            # floating boot-time conversion. comm may contain spaces and ')'.
            $stat = [IO.File]::ReadAllText("/proc/$ProcessId/stat")
            $fields = $stat.Substring($stat.LastIndexOf(')') + 2).Split(' ')
            return [pscustomobject]@{ start="linux:$($fields[19])"; parent=[int]$fields[1] }
        }
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        if ($IsWindows) {
            $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop).ParentProcessId
            return [pscustomobject]@{ start="windows:$($process.StartTime.ToFileTimeUtc())"; parent=[int]$parent }
        }
        # ps exposes a stable native creation string on macOS (no .NET round trip).
        $start = (& /bin/ps -p $ProcessId -o lstart=) -join ''
        $parent = (& /bin/ps -p $ProcessId -o ppid=) -join ''
        if ($LASTEXITCODE -ne 0 -or -not $start.Trim()) { return $null }
        return [pscustomobject]@{ start="macos:$($start.Trim())"; parent=[int]$parent.Trim() }
    } catch { return $null }
}

function Test-RuntimeLeaseAncestor {
    param([int]$OwnerId, [string]$Start)
    $current = $PID; $seen = @{}
    while ($current -gt 0 -and -not $seen.ContainsKey($current)) {
        $seen[$current] = $true
        $identity = Get-RuntimeProcessIdentity $current
        if (-not $identity) { return $false }
        if ($current -eq $OwnerId) { return $identity.start -ceq $Start }
        $current = $identity.parent
    }
    return $false
}

function Test-RuntimeLeaseHandleBusy {
    param([string]$Path)
    $probe = $null
    try { $probe = [IO.FileStream]::new($Path, 'Open', 'ReadWrite', 'None'); return $false }
    catch [IO.FileNotFoundException] { return $false }
    catch [IO.IOException] {
        $cause = $_.Exception; while ($cause.InnerException) { $cause = $cause.InnerException }
        $code = $cause.HResult -band 0xffff
        $busy = if ($IsWindows) { $code -in @(32,33) } elseif ($IsMacOS) { $code -eq 35 } else { $code -eq 11 }
        if (-not $busy) { throw }
        return $true
    } finally { if ($probe) { $probe.Dispose() } }
}

function Test-RuntimeLinuxOwnerGone {
    param([int]$OwnerId, [string]$Start)
    if (-not $IsLinux -or $OwnerId -le 0 -or $Start -cnotmatch '^linux:[0-9]+$') { return $false }
    try {
        $stat = [IO.File]::ReadAllText("/proc/$OwnerId/stat")
        if ($stat -notmatch '^\d+ \(.*\) ') { return $false }
        $fields = $stat.Substring($stat.LastIndexOf(')') + 2).Split(' ')
        if ($fields.Count -lt 20 -or $fields[19] -notmatch '^[0-9]+$') { return $false }
        return "linux:$($fields[19])" -cne $Start
    } catch [IO.FileNotFoundException] { return [IO.Directory]::Exists('/proc/self') }
    catch [IO.DirectoryNotFoundException] { return [IO.Directory]::Exists('/proc/self') }
    catch { return $false }
}

function Remove-RuntimeOrphanProofs {
    # Caller holds the suite mutex. Never unlink that mutex. Old empty proofs
    # and partial/unknown receipts cannot prove ownership and must be retained.
    param([string]$Path)
    if (-not $IsLinux) { return }
    foreach ($candidate in [IO.Directory]::EnumerateFiles([IO.Path]::GetDirectoryName($Path))) {
        $prefix = "$Path."
        if (-not $candidate.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
        $suffix = $candidate.Substring($prefix.Length)
        if ($suffix -cnotmatch '^([0-9a-f]{32})\.lease$') { continue }
        $nonce = $Matches[1]; $probe = $null; $reader = $null
        try {
            if (([IO.File]::GetAttributes($candidate) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            # Exclusive open protects a live proof even during publication races.
            $probe = [IO.FileStream]::new($candidate, 'Open', 'ReadWrite', 'None')
            $reader = [IO.StreamReader]::new($probe, [Text.Encoding]::UTF8, $true, 1024, $true)
            $receipt = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
            if ($receipt.path -cne $Path -or $receipt.nonce -cne $nonce -or
                [string]$receipt.pid -notmatch '^[1-9][0-9]*$' -or $receipt.start -cnotmatch '^linux:[0-9]+$') { continue }
            if (Test-RuntimeLinuxOwnerGone -OwnerId ([int]$receipt.pid) -Start $receipt.start) {
                # Delete while the exclusive proof handle is still held (Linux).
                [IO.File]::Delete($candidate)
            }
        } catch { } # Busy, unreadable, malformed, or unverifiable: retain.
        finally { if ($reader) { $reader.Dispose() }; if ($probe) { $probe.Dispose() } }
    }
}

function Enter-RuntimeTestSuite {
    param([string]$LockPath)
    $root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'danny-skills/test-locks'
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $path = [IO.Path]::GetFullPath($(if ($LockPath) { $LockPath } else { Join-Path $root 'runtime-suite.mutex' }))
    $selfIdentity = Get-RuntimeProcessIdentity $PID
    if (-not $selfIdentity) { throw 'RUNTIME_SUITE_IDENTITY_UNAVAILABLE: cannot prove this process creation identity.' }
    # Global strong references survive repeated dot-sourcing in one pwsh suite.
    if (-not (Get-Variable DtRuntimeTestLeases -Scope Global -ErrorAction SilentlyContinue)) {
        $comparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
        $global:DtRuntimeTestLeases = [Collections.Generic.Dictionary[string,object]]::new($comparer)
        $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
            foreach ($lease in $global:DtRuntimeTestLeases.Values) { try { $lease.Dispose() } catch { } }
        }
    }
    if ($global:DtRuntimeTestLeases.ContainsKey($path) -and $global:DtRuntimeTestLeases[$path].CanWrite) {
        $env:DT_RUNTIME_TEST_OWNER = [string]$PID
        $env:DT_RUNTIME_TEST_OWNER_START = $selfIdentity.start
        $env:DT_RUNTIME_TEST_OWNER_PATH = $path
        $env:DT_RUNTIME_TEST_OWNER_NONCE = $global:DtRuntimeTestLeases[$path].Nonce
        return
    }
    $inherited = $env:DT_RUNTIME_TEST_OWNER_PATH -ceq $path -and
        $env:DT_RUNTIME_TEST_OWNER -match '^\d+$' -and $env:DT_RUNTIME_TEST_OWNER_START -and $env:DT_RUNTIME_TEST_OWNER_NONCE -match '^[0-9a-f]{32}$' -and
        (Test-RuntimeLeaseAncestor -OwnerId ([int]$env:DT_RUNTIME_TEST_OWNER) -Start $env:DT_RUNTIME_TEST_OWNER_START)
    if ($inherited) {
        $matchesLease = $false
        try {
            $receiptText = [IO.File]::ReadAllText("$path.lease.json")
            $receipt = $receiptText | ConvertFrom-Json
            $matchesLease = [string]$receipt.pid -ceq $env:DT_RUNTIME_TEST_OWNER -and
                $receipt.start -ceq $env:DT_RUNTIME_TEST_OWNER_START -and $receipt.path -ceq $path -and
                $receipt.nonce -ceq $env:DT_RUNTIME_TEST_OWNER_NONCE
        } catch { $matchesLease = $false }
        if ($matchesLease) {
            # A different process may own the mutex before updating its receipt.
            # Require the nonce-specific proof too; Dispose closes both handles.
            # Non-contention IO errors fail immediately instead of waiting on self.
            $proofPath = "$path.$($env:DT_RUNTIME_TEST_OWNER_NONCE).lease"
            if ((Test-RuntimeLeaseHandleBusy $path) -and (Test-RuntimeLeaseHandleBusy $proofPath) -and
                [IO.File]::ReadAllText("$path.lease.json") -ceq $receiptText) { return }
        }
    }
    $announced = $false
    while ($true) {
        try {
            $mutex = [IO.FileStream]::new($path, 'OpenOrCreate', 'ReadWrite', 'None')
            $nonce = [guid]::NewGuid().ToString('N')
            $proofPath = "$path.$nonce.lease"
            try {
                Remove-RuntimeOrphanProofs -Path $path
                $proof = [IO.FileStream]::new($proofPath, 'CreateNew', 'ReadWrite', 'None')
                $script:RuntimeTestLease = [DtRuntimeTestLeaseHandle]::new($mutex,$proof,$nonce,$proofPath)
            } catch { $mutex.Dispose(); throw }
            $global:DtRuntimeTestLeases[$path] = $script:RuntimeTestLease
            $env:DT_RUNTIME_TEST_OWNER = [string]$PID
            $env:DT_RUNTIME_TEST_OWNER_START = $selfIdentity.start
            $env:DT_RUNTIME_TEST_OWNER_PATH = $path
            $env:DT_RUNTIME_TEST_OWNER_NONCE = $nonce
            $receipt = @{pid=$env:DT_RUNTIME_TEST_OWNER;start=$env:DT_RUNTIME_TEST_OWNER_START;path=$path;nonce=$env:DT_RUNTIME_TEST_OWNER_NONCE} | ConvertTo-Json -Compress
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes($receipt)
                $proof.Write($bytes, 0, $bytes.Length)
                $proof.Flush()
                [IO.File]::WriteAllText("$path.lease.json", $receipt)
            }
            catch { $script:RuntimeTestLease.Dispose(); throw }
            return
        } catch [IO.IOException] {
            $cause = $_.Exception
            while ($cause.InnerException) { $cause = $cause.InnerException }
            $code = $cause.HResult -band 0xffff
            $contention = if ($IsWindows) { $code -in @(32,33) } elseif ($IsMacOS) { $code -eq 35 } else { $code -eq 11 }
            if (-not $contention) { throw }
            if (-not $announced) { Write-Host 'Waiting for another danny-skills runtime suite to finish.'; $announced = $true }
            Start-Sleep -Milliseconds 200
        }
    }
}
