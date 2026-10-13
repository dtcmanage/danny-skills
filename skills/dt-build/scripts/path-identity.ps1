# Shared filesystem identity for records and comparisons. Display paths can keep their spelling.
function ConvertTo-DtNormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    $native = $Path.Replace([char]92, [IO.Path]::DirectorySeparatorChar).Replace([char]47, [IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath($native)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd([char]92, [char]47) }
    return $full
}

function ConvertTo-DtPathIdentity {
    param([Parameter(Mandatory)][string]$Path)
    $full = ConvertTo-DtNormalizedPath $Path
    if ([OperatingSystem]::IsWindows()) { $full = $full.ToLowerInvariant() }
    return $full
}

function Test-DtPathEqual {
    param([string]$Left, [string]$Right)
    if (-not $Left -or -not $Right) { return $false }
    try { return (ConvertTo-DtPathIdentity $Left) -ceq (ConvertTo-DtPathIdentity $Right) }
    catch { return $false }
}
