#Requires -Version 7.0
# The deliberate deeper read of job evidence: capped at 16 KB per call, every line at
# 400 characters, logged to <RunFolder>/jobs/reads.jsonl, and warns on a repeat read.
[CmdletBinding(DefaultParameterSetName = 'Lines')]
param(
    [Parameter(Mandatory)]
    [string]$RunFolder,

    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter(Mandatory, ParameterSetName = 'Lines')]
    [ValidatePattern('^\d+-\d+$')]
    [string]$Lines,

    [Parameter(Mandatory, ParameterSetName = 'Grep')]
    [string]$Grep,

    [Parameter(ParameterSetName = 'Grep')]
    [int]$Context = 0,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$maxBytes = 16384
$maxLineChars = 400

$fullPath = [System.IO.Path]::GetFullPath($Path)
if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "READ_EVIDENCE_MISSING: $fullPath" }
$jobsDir = Join-Path ([System.IO.Path]::GetFullPath($RunFolder).TrimEnd('\', '/')) 'jobs'
New-Item -ItemType Directory -Path $jobsDir -Force | Out-Null
$logPath = Join-Path $jobsDir 'reads.jsonl'

$bytes = [System.IO.File]::ReadAllBytes($fullPath)
$sha256 = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
$allLines = @(([System.Text.Encoding]::UTF8.GetString($bytes)) -split "\r?\n")
if ($allLines.Count -gt 0 -and $allLines[-1] -eq '') { $allLines = @($allLines | Select-Object -SkipLast 1) }

$selected = [System.Collections.Generic.List[string]]::new()
if ($PSCmdlet.ParameterSetName -eq 'Lines') {
    $parts = $Lines -split '-'
    $first = [Math]::Max(1, [int]$parts[0])
    $last = [Math]::Min($allLines.Count, [int]$parts[1])
    for ($i = $first; $i -le $last; $i++) { $selected.Add("${i}: $($allLines[$i - 1])") }
    $selector = [ordered]@{ mode = 'lines'; range = $Lines }
}
else {
    $include = [System.Collections.Generic.SortedSet[int]]::new()
    $hits = [System.Collections.Generic.HashSet[int]]::new()
    for ($i = 0; $i -lt $allLines.Count; $i++) {
        if ($allLines[$i] -match $Grep) {
            [void]$hits.Add($i)
            for ($j = [Math]::Max(0, $i - $Context); $j -le [Math]::Min($allLines.Count - 1, $i + $Context); $j++) { [void]$include.Add($j) }
        }
    }
    foreach ($i in $include) {
        $mark = if ($hits.Contains($i)) { ':' } else { '-' }
        $selected.Add("$($i + 1)${mark} $($allLines[$i])")
    }
    $selector = [ordered]@{ mode = 'grep'; pattern = $Grep; context = $Context }
}

$truncated = $false
$out = [System.Collections.Generic.List[string]]::new()
$used = 0
foreach ($line in $selected) {
    $text = $line
    if ($text.Length -gt $maxLineChars) {
        $text = $text.Substring(0, $maxLineChars - 15) + ' ...[truncated]'
        $truncated = $true
    }
    $size = [System.Text.Encoding]::UTF8.GetByteCount($text) + 1
    if ($used + $size -gt $maxBytes) { $truncated = $true; break }
    $out.Add($text)
    $used += $size
}

if ($Json) {
    # The JSON form escapes characters; trim lines until the whole reply fits the cap too.
    $probe = [ordered]@{ path = $fullPath; selector = $selector; sha256 = $sha256; bytes_returned = $used; lines = $out; truncated = $true; evidence_path = $fullPath; warnings = @('repeat_read: same selection of an unchanged file was already read; use the earlier result.') }
    while ($out.Count -gt 0 -and [System.Text.Encoding]::UTF8.GetByteCount(($probe | ConvertTo-Json -Depth 6 -Compress)) -gt $maxBytes) {
        $used -= [System.Text.Encoding]::UTF8.GetByteCount($out[$out.Count - 1]) + 1
        $out.RemoveAt($out.Count - 1)
        $truncated = $true
        $probe.bytes_returned = $used
    }
}

$selectorKey = ($selector | ConvertTo-Json -Compress)
$repeat = $false
if (Test-Path -LiteralPath $logPath) {
    foreach ($entry in [System.IO.File]::ReadAllLines($logPath)) {
        if (-not $entry.Trim()) { continue }
        $prior = $entry | ConvertFrom-Json
        if ($prior.path -eq $fullPath -and $prior.sha256 -eq $sha256 -and ($prior.selector | ConvertTo-Json -Compress) -eq $selectorKey) { $repeat = $true; break }
    }
}

$logEntry = [ordered]@{
    ts_utc         = [DateTime]::UtcNow.ToString('o')
    path           = $fullPath
    selector       = $selector
    sha256         = $sha256
    bytes_returned = $used
    truncated      = $truncated
    repeat_read    = $repeat
}
[System.IO.File]::AppendAllText($logPath, (($logEntry | ConvertTo-Json -Compress) + "`n"), [System.Text.UTF8Encoding]::new($false))

$warnings = @()
if ($repeat) { $warnings += 'repeat_read: same selection of an unchanged file was already read; use the earlier result.' }
$result = [ordered]@{
    path           = $fullPath
    selector       = $selector
    sha256         = $sha256
    bytes_returned = $used
    lines          = $out
    truncated      = $truncated
    evidence_path  = $fullPath
    warnings       = $warnings
}

if ($Json) { $result | ConvertTo-Json -Depth 6 -Compress }
else {
    foreach ($w in $warnings) { Write-Output "WARNING $w" }
    $out
    if ($truncated) { Write-Output "[truncated: true; full file: $fullPath]" }
}
