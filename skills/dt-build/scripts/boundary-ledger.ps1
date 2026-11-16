#Requires -Version 7.0
# Bootstrap read cache only. The run record remains the sole source of authorization.
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('record', 'plan')][string]$Verb,
    [Parameter(Mandatory)][string]$RunFolder,
    [string]$Path,
    [string[]]$Paths,
    [string[]]$Lines,
    [string]$CoordinatorId = $env:DT_BUILD_COORDINATOR_ID,
    [string]$ExpectedSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$ledgerPath = Join-Path ([IO.Path]::GetFullPath($RunFolder)) 'boundary-ledger.jsonl'

function Open-BoundaryLedger {
    param([IO.FileMode]$Mode)
    # Lock the ledger itself for both readers and appenders. The OS releases the handle
    # on process death. A two-second bound keeps contention on the full-read fallback.
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
        try { return [IO.File]::Open($ledgerPath, $Mode, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline -or -not [IO.Directory]::Exists($RunFolder)) { throw }
            Start-Sleep -Milliseconds 25
        }
    } while ($true)
}

function Get-BoundarySnapshot {
    param([string]$SourcePath)
    $bytes = [IO.File]::ReadAllBytes($SourcePath)
    [pscustomobject]@{
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        size = $bytes.LongLength
        text = $utf8.GetString($bytes).TrimStart([char]0xFEFF)
    }
}

if ($Verb -eq 'record') {
    $stream = $null
    try {
        if (-not $Path -or -not $CoordinatorId -or -not $Lines -or $Paths) { throw 'record requires -Path, -Lines and -CoordinatorId (or DT_BUILD_COORDINATOR_ID)' }
        $fullPath = [IO.Path]::GetFullPath($Path)
        $source = Get-BoundarySnapshot $fullPath
        if ($ExpectedSha256 -and $source.sha256 -cne $ExpectedSha256) { throw 'source changed since plan; read it in full again' }
        $sourceLines = $source.text -split '\r?\n'
        foreach ($line in $Lines) {
            if ([string]::IsNullOrWhiteSpace($line) -or $sourceLines -cnotcontains $line) { throw 'Lines must contain exact, nonempty source lines from the full read' }
        }
        $entry = [ordered]@{
            path = $fullPath; sha256 = $source.sha256; size = $source.size; lines = @($Lines)
            read_utc = [DateTime]::UtcNow.ToString('o'); coordinator_id = $CoordinatorId
        }
        $stream = Open-BoundaryLedger -Mode OpenOrCreate
        # Always start a new line, even after a torn append. Never rewrite old bytes.
        $prefix = ''
        if ($stream.Length -gt 0) {
            $null = $stream.Seek(-1, [IO.SeekOrigin]::End)
            if ($stream.ReadByte() -ne 10) { $prefix = "`n" }
        }
        $null = $stream.Seek(0, [IO.SeekOrigin]::End)
        $bytes = $utf8.GetBytes($prefix + ($entry | ConvertTo-Json -Depth 4 -Compress) + "`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        [ordered]@{ recorded = $true; path = $fullPath; sha256 = $source.sha256 } | ConvertTo-Json -Compress
    }
    catch {
        [ordered]@{ recorded = $false; action = 'read-full'; path = $Path; reason = $_.Exception.Message } | ConvertTo-Json -Compress
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
    return
}

if (-not $Paths -or $Path -or $Lines) { throw 'plan requires -Paths only' }
# Windows paths compare without case; Unix paths retain case. Latest physical row wins.
$comparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$latest = [Collections.Generic.Dictionary[string, object]]::new($comparer)
$ledgerFailure = $null
$stream = $null
try {
    if (-not [IO.File]::Exists($ledgerPath)) { throw 'ledger missing or unreadable' }
    $stream = Open-BoundaryLedger -Mode Open
    $reader = [IO.StreamReader]::new($stream, $utf8, $true, 4096, $true)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.Trim()) { continue }
            $key = $null
            try {
                $row = $line | ConvertFrom-Json -AsHashtable
                if ($row -isnot [Collections.IDictionary] -or $row.path -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($row.path)) { throw 'invalid path' }
                $key = [IO.Path]::GetFullPath($row.path)
                # Newer PowerShell versions deserialize ISO timestamps to DateTime.
                if ($row.read_utc -is [DateTime] -and $row.read_utc.Kind -eq [DateTimeKind]::Utc) { $row.read_utc = $row.read_utc.ToString('o') }
                $stamp = [DateTimeOffset]::MinValue
                if ($row.sha256 -isnot [string] -or $row.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                    ($row.size -isnot [long] -and $row.size -isnot [int]) -or $row.size -lt 0 -or
                    $row.lines -isnot [array] -or $row.lines.Count -eq 0 -or
                    @($row.lines | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or
                    $row.coordinator_id -isnot [string] -or [string]::IsNullOrWhiteSpace($row.coordinator_id) -or
                    $row.read_utc -isnot [string] -or -not [DateTimeOffset]::TryParse($row.read_utc, [ref]$stamp) -or $stamp.Offset -ne [TimeSpan]::Zero) { throw 'invalid entry' }
                $latest[$key] = $row
            }
            catch {
                # Never resurrect an older entry behind a corrupt successor. If its
                # path cannot be recovered, invalidate the preceding cache conservatively.
                if ($key) { $null = $latest.Remove($key) } else { $latest.Clear() }
            }
        }
    }
    finally { $reader.Dispose() }
}
catch { $latest.Clear(); $ledgerFailure = $_.Exception.Message }
finally { if ($null -ne $stream) { $stream.Dispose() } }

$results = @(foreach ($sourcePath in $Paths) {
    $result = [ordered]@{ path = $sourcePath; action = 'read-full'; lines = @(); sha256 = $null; size = $null; reason = 'new or invalid entry' }
    try {
        $result.path = [IO.Path]::GetFullPath($sourcePath)
        $source = Get-BoundarySnapshot $result.path
        $result.sha256 = $source.sha256; $result.size = $source.size
        if ($ledgerFailure) { $result.reason = $ledgerFailure }
        elseif ($latest.ContainsKey($result.path)) {
            $row = $latest[$result.path]
            $sourceLines = $source.text -split '\r?\n'
            if ($row.sha256 -ceq $source.sha256 -and $row.size -eq $source.size -and
                @($row.lines | Where-Object { $sourceLines -cnotcontains $_ }).Count -eq 0) {
                $result.action = 'unchanged'; $result.lines = @($row.lines); $result.reason = 'hash and size match'
                $result.read_utc = $row.read_utc; $result.coordinator_id = $row.coordinator_id
            }
            else { $result.reason = 'source changed or invalid recorded lines' }
        }
    }
    catch { $result.reason = $_.Exception.Message }
    [pscustomobject]$result
})
ConvertTo-Json -InputObject $results -Depth 5 -Compress
