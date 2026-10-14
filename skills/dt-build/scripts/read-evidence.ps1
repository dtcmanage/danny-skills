#Requires -Version 7.0
# The deliberate deeper read of job evidence: capped at 16 KB per call, every line at
# 400 characters, logged to <RunFolder>/jobs/reads.jsonl, and warns on a repeat read.
[CmdletBinding(DefaultParameterSetName = 'Lines')]
param(
    [Parameter(Mandatory)]
    [string]$RunFolder,

    [string]$Path,

    [string]$JobId,

    [ValidateSet('summary', 'stdout', 'stderr', 'spec', 'report', 'provenance')]
    [string]$File = 'summary',

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
# Each emitted line costs its UTF-8 bytes plus the platform line ending (CRLF on Windows).
$newlineBytes = [Environment]::NewLine.Length
$repeatWarning = 'repeat_read: same selection of an unchanged file was already read; use the earlier result.'

# Ledger helpers (run lock, shared reads); pass our own values so the dot-sourced param block does not clear them.
. (Join-Path $PSScriptRoot 'dt-job.ps1') -RunFolder $RunFolder -JobId $JobId -Json:$Json

if (($Path -and $JobId) -or (-not $Path -and -not $JobId)) { throw 'READ_EVIDENCE_ARGS: use exactly one of -Path or -JobId.' }
$paths = Get-DtJobPaths -RunFolder $RunFolder
$jobsDir = $paths.Jobs
if ($JobId) {
    $jobRecord = Get-DtJobRecord -RunFolder $RunFolder -JobId $JobId
    if ($null -eq $jobRecord) { throw "READ_EVIDENCE_NO_JOB: $JobId" }
    $Path = switch ($File) {
        'summary' { $jobRecord.summary_path }
        'stdout' { $jobRecord.output_path }
        'stderr' { $jobRecord.stderr_path }
        'spec' { Join-Path (Join-Path $jobsDir $JobId) 'spec.json' }
        default {
            $reportPath = (Get-DtJobWorkerOutcome -RunFolder $RunFolder -Record $jobRecord).report_path
            if (-not $reportPath) { throw "READ_EVIDENCE_MISSING: job $JobId has no report path" }
            if ($File -eq 'provenance') { "$reportPath.provenance.json" } else { $reportPath }
        }
    }
}
$fullPath = ConvertTo-DtNormalizedPath $Path
if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    $message = "READ_EVIDENCE_MISSING: $fullPath"
    $relative = [System.IO.Path]::GetRelativePath($jobsDir, $fullPath)
    $jobMatch = [regex]::Match($relative, '^(?<id>[^\\/.]+)(?:[\\/]|\.[^\\/]+$)')
    if ($jobMatch.Success) {
        $missingJobId = $jobMatch.Groups['id'].Value
        $jobDir = Join-Path $jobsDir $missingJobId
        $available = @('summary.json', 'stdout.log', 'stderr.log', 'spec.json' | Where-Object { Test-Path -LiteralPath (Join-Path $jobDir $_) -PathType Leaf })
        $message += "; job $missingJobId has: $($available -join ', ') (use -JobId $missingJobId -File <name>)"
    }
    if ($Path -eq [System.IO.Path]::GetFileName($Path)) {
        $runFile = switch ($Path) {
            'approvals.json' { $paths.Approvals }
            'operator-notes.json' { $paths.OperatorNotes }
            'evidence-notes.json' { $paths.EvidenceNotes }
            'launches.jsonl' { $paths.Launches }
            'worktrees.jsonl' { $paths.Worktrees }
            'events.jsonl' { $paths.Events }
        }
        if ($runFile -and $fullPath -ine $runFile) { $message += "; did you mean $runFile" }
    }
    throw $message
}
New-Item -ItemType Directory -Path $jobsDir -Force | Out-Null
$logPath = Join-Path $jobsDir 'reads.jsonl'

function Open-EvidenceStream {
    return [System.IO.File]::Open($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
}

# Hash and read with streams: evidence logs can be far larger than the 16 KB a call returns.
$stream = Open-EvidenceStream
try {
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try { $sha256 = [System.Convert]::ToHexString($hasher.ComputeHash($stream)).ToLowerInvariant() }
    finally { $hasher.Dispose() }
}
finally { $stream.Dispose() }

$truncated = $false
$selected = [System.Collections.Generic.List[string]]::new()
$selectedBytes = 0
$stream = Open-EvidenceStream
try {
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
    $lineNo = 0
    $add = {
        param([string]$Text)
        if ($Text.Length -gt $maxLineChars) {
            $Text = $Text.Substring(0, $maxLineChars - 15) + ' ...[truncated]'
            $script:truncated = $true
        }
        $selected.Add($Text)
        $script:selectedBytes += [System.Text.Encoding]::UTF8.GetByteCount($Text) + $newlineBytes
    }
    if ($PSCmdlet.ParameterSetName -eq 'Lines') {
        $parts = $Lines -split '-'
        $first = [Math]::Max(1, [int]$parts[0])
        $last = [int]$parts[1]
        while ($null -ne ($line = $reader.ReadLine())) {
            $lineNo++
            if ($lineNo -lt $first) { continue }
            if ($lineNo -gt $last) { break }
            . $add "${lineNo}: $line"
            # Past the cap the rest can never be returned; stop reading.
            if ($selectedBytes -gt $maxBytes) { break }
        }
        $selector = [ordered]@{ mode = 'lines'; range = $Lines }
    }
    else {
        $before = [System.Collections.Generic.Queue[object]]::new()
        $after = 0
        while ($null -ne ($line = $reader.ReadLine())) {
            $lineNo++
            if ($line -match $Grep) {
                while ($before.Count -gt 0) { $prior = $before.Dequeue(); . $add "$($prior.n)- $($prior.text)" }
                . $add "${lineNo}: $line"
                $after = $Context
            }
            elseif ($after -gt 0) {
                . $add "${lineNo}- $line"
                $after--
            }
            elseif ($Context -gt 0) {
                $before.Enqueue([pscustomobject]@{ n = $lineNo; text = $line })
                if ($before.Count -gt $Context) { [void]$before.Dequeue() }
            }
            if ($selectedBytes -gt $maxBytes) { break }
        }
        $selector = [ordered]@{ mode = 'grep'; pattern = $Grep; context = $Context }
    }
}
finally { $stream.Dispose() }

$selectorKey = ($selector | ConvertTo-Json -Compress)
$repeat = $false
if (Test-Path -LiteralPath $logPath) {
    foreach ($entry in ((Read-DtJobText -Path $logPath) -split "\r?\n")) {
        if (-not $entry.Trim()) { continue }
        try { $prior = $entry | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ((Test-DtPathEqual $prior.path $fullPath) -and $prior.sha256 -eq $sha256 -and ($prior.selector | ConvertTo-Json -Compress) -eq $selectorKey) { $repeat = $true; break }
    }
}
$warnings = @()
if ($repeat) { $warnings += $repeatWarning }

# In text mode the warning lines and the truncation marker count against the cap too.
$marker = "[truncated: true; full file: $fullPath]"
$reserved = 0
if (-not $Json) { foreach ($w in $warnings) { $reserved += [System.Text.Encoding]::UTF8.GetByteCount("WARNING $w") + $newlineBytes } }

$out = [System.Collections.Generic.List[string]]::new()
$used = 0
foreach ($text in $selected) {
    $size = [System.Text.Encoding]::UTF8.GetByteCount($text) + $newlineBytes
    if ($used + $size + $reserved -gt $maxBytes) { $truncated = $true; break }
    $out.Add($text)
    $used += $size
}
if (-not $Json -and $truncated) {
    $markerBytes = [System.Text.Encoding]::UTF8.GetByteCount($marker) + $newlineBytes
    while ($out.Count -gt 0 -and $used + $reserved + $markerBytes -gt $maxBytes) {
        $used -= [System.Text.Encoding]::UTF8.GetByteCount($out[$out.Count - 1]) + $newlineBytes
        $out.RemoveAt($out.Count - 1)
    }
}

if ($Json) {
    # The JSON form escapes characters; trim lines until the whole reply fits the cap too.
    $probe = [ordered]@{ path = $fullPath; selector = $selector; sha256 = $sha256; bytes_returned = $used; lines = $out; truncated = $true; evidence_path = $fullPath; warnings = @($repeatWarning) }
    while ($out.Count -gt 0 -and [System.Text.Encoding]::UTF8.GetByteCount(($probe | ConvertTo-Json -Depth 6 -Compress)) -gt $maxBytes) {
        $used -= [System.Text.Encoding]::UTF8.GetByteCount($out[$out.Count - 1]) + $newlineBytes
        $out.RemoveAt($out.Count - 1)
        $truncated = $true
        $probe.bytes_returned = $used
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
Invoke-DtJobLocked -RunFolder $RunFolder -Action {
    [System.IO.File]::AppendAllText($logPath, (($logEntry | ConvertTo-Json -Compress) + "`n"), [System.Text.UTF8Encoding]::new($false))
}

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
    if ($truncated) { Write-Output $marker }
}
