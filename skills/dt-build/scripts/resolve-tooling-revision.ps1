# Read-only published-revision and append-only runtime proofs; usage: references/tooling-revision-provenance.md.
param(
    [string]$Path,
    [string]$RepoRoot,
    [string]$PinnedSha256,
    [string]$PinnedCopyPath,
    [string]$PinnedLines,
    [string[]]$ProtectedPattern,
    [string]$Ref = 'origin/main',
    [string]$RepoRelativePath,
    [switch]$Json,
    [switch]$Fetch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-RevisionGit {
    param([string[]]$Arguments, [switch]$AllowMissing)
    $output = @(& git -C $RepoRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        if ($AllowMissing) { return $null }
        throw "git $($Arguments[0]) failed: $($output -join ' ')"
    }
    return ($output -join "`n").Trim()
}


function Convert-RevisionDate {
    param([string]$Date)
    $eastern = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
    [TimeZoneInfo]::ConvertTime([DateTimeOffset]::Parse($Date), $eastern).ToString('yyyy-MM-ddTHH:mm:sszzz')
}

function Get-BytesSha256 {
    param([byte[]]$Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Read-PinnedBytes {
    param([string]$FilePath)
    # Lock each snapshot against writers while capturing its exact bytes.
    $handle = [IO.File]::Open($FilePath, 'Open', 'Read', 'Read')
    try {
        $buffer = [IO.MemoryStream]::new()
        try { $handle.CopyTo($buffer); return ,$buffer.ToArray() }
        finally { $buffer.Dispose() }
    } finally { $handle.Dispose() }
}

function Get-ExactRows {
    param([string]$Text)
    if ($Text.Length -eq 0) { return }
    $rows = $Text.Split("`n")
    $count = $rows.Count
    if ($Text.EndsWith("`n")) { $count-- }
    for ($i = 0; $i -lt $count; $i++) {
        $row = $rows[$i]
        # Remove one CR only when it is part of a CRLF delimiter.
        if ($i -lt ($rows.Count - 1) -and $row.EndsWith("`r")) { $row = $row.Substring(0, $row.Length - 1) }
        $row
    }
}

function Get-RowAudit {
    param([string]$Row)
    $tokens = $Row.Trim() -split '\s+', 3
    [ordered]@{
        host = $tokens[0]
        row_sha256 = Get-BytesSha256 ([Text.Encoding]::UTF8.GetBytes($Row))
        # Never return whole rows; hashes identify exact edited/removed/added rows.
    }
}

function Resolve-AppendOnly {
    if ($PinnedSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw '-PinnedSha256 must be a SHA256 hex digest.' }
    if ([bool]$PinnedCopyPath -eq [bool]$PinnedLines) { throw 'Supply exactly one of -PinnedCopyPath or -PinnedLines.' }
    if (-not $ProtectedPattern -or @($ProtectedPattern | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) {
        throw '-ProtectedPattern requires one or more nonempty regexes.'
    }
    $patterns = @($ProtectedPattern | ForEach-Object {
        [regex]::new($_, [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(2))
    })
    $savedPath = if ($PinnedCopyPath) { $PinnedCopyPath } else { $PinnedLines }
    $saved = Read-PinnedBytes $savedPath
    $current = Read-PinnedBytes $Path
    $savedHash = Get-BytesSha256 $saved
    $currentHash = Get-BytesSha256 $current
    if ($PinnedCopyPath -and $savedHash -ne $PinnedSha256) { throw 'Pinned copy does not match -PinnedSha256.' }
    # Strict UTF-8 prevents lossy decoding from collapsing distinct protected rows.
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $oldText = $utf8.GetString($saved)
    $newText = $utf8.GetString($current)
    $oldRows = @(Get-ExactRows $oldText)
    $newRows = @(Get-ExactRows $newText)
    $oldProtected = @($oldRows | Where-Object { $row = $_; @($patterns | Where-Object { $_.IsMatch($row) }).Count -gt 0 })
    $newProtected = @($newRows | Where-Object { $row = $_; @($patterns | Where-Object { $_.IsMatch($row) }).Count -gt 0 })
    # Multiset comparison catches added duplicates as well as edited/removed rows.
    $remaining = [Collections.Generic.List[string]]::new()
    foreach ($row in $newProtected) { $remaining.Add($row) }
    $removed = @(
        foreach ($row in $oldProtected) {
            $index = $remaining.FindIndex([Predicate[string]]{ param($candidate) [string]::Equals($candidate, $row, [StringComparison]::Ordinal) })
            if ($index -ge 0) { $remaining.RemoveAt($index) }
            else { Get-RowAudit $row }
        }
    )
    $added = @($remaining | ForEach-Object { Get-RowAudit $_ })
    $prefix = $false
    $appended = @()
    $reason = 'content_is_not_a_byte_prefix'
    if ($savedHash -eq $PinnedSha256) {
        $prefix = $current.Length -ge $saved.Length
        for ($i = 0; $prefix -and $i -lt $saved.Length; $i++) { if ($saved[$i] -ne $current[$i]) { $prefix = $false } }
        $offset = $saved.Length
        if ($prefix -and $saved.Length -gt 0 -and $saved[-1] -ne 10 -and $current.Length -gt $offset) {
            # Only supply the absent final line terminator. Never normalize CRLF/LF elsewhere.
            if ($saved[-1] -eq 13 -and $current[$offset] -eq 10) { $offset++ }
            elseif ($current[$offset] -eq 10) { $offset++ }
            elseif ($current.Length -gt ($offset + 1) -and $current[$offset] -eq 13 -and $current[$offset + 1] -eq 10) { $offset += 2 }
            else { $prefix = $false }
        }
        if ($prefix) { $appended = @(Get-ExactRows ($utf8.GetString($current, $offset, $current.Length - $offset))) }
    } else { $reason = 'pinned_lines_do_not_prove_full_byte_prefix' }
    $status = if ($currentHash -eq $PinnedSha256) { 'UNCHANGED' }
        elseif ($prefix -and $removed.Count -eq 0 -and $added.Count -eq 0) { 'APPEND_ONLY' }
        else { 'CHANGED' }
    if ($removed.Count -or $added.Count) { $reason = 'protected_rows_changed' }
    [ordered]@{
        status = $status; path = $Path; pinned_sha256 = $PinnedSha256.ToLowerInvariant()
        sha256 = $currentHash; bytes = $current.Length
        prefix_verified = $prefix
        reason = $(if ($status -eq 'CHANGED') { $reason } else { $null })
        appended_line_count = $appended.Count
        appended_hosts = @($appended | ForEach-Object { (Get-RowAudit $_).host })
        protected_removed = $removed; protected_added = $added
        # An edit appears as its removed and added exact-row hashes; no key bytes escape.
    }
}

$stream = $null
try {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '-Path is required.' }
    if ($Fetch) { throw '-Fetch is not allowed: this helper is read-only.' }
    $file = Get-Item -LiteralPath $Path
    if ($file.PSIsContainer) { throw "Path is not a file: $Path" }
    $Path = $file.FullName
    if ($PinnedSha256 -or $PinnedCopyPath -or $PinnedLines -or $ProtectedPattern) {
        $result = Resolve-AppendOnly
        if ($Json) { $result | ConvertTo-Json -Depth 8 -Compress }
        else { [pscustomobject]$result | Format-List }
        if ($result.status -in @('UNCHANGED', 'APPEND_ONLY')) { exit 0 }
        exit 3
    }
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $skill = Get-Item -LiteralPath (Split-Path -Parent $PSScriptRoot)
        $target = $skill.ResolveLinkTarget($true)
        if ($target) { $skill = $target }
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $skill.FullName)
    }
    $RepoRoot = (Get-Item -LiteralPath $RepoRoot).FullName
    if ([string]::IsNullOrWhiteSpace($Ref) -or $Ref.StartsWith('-')) { throw '-Ref must name a git revision.' }
    if ([string]::IsNullOrWhiteSpace($RepoRelativePath)) {
        $relativePath = [IO.Path]::GetRelativePath($RepoRoot, $Path).Replace('\', '/')
        # Both repo copies and installed/junctioned dt-build skill directories.
        if ($Path.Replace('\', '/') -match '/dt-build/scripts/([^/]+)$') {
            $RepoRelativePath = 'skills/dt-build/scripts/' + $Matches[1]
        } elseif (-not $relativePath.StartsWith('../') -and -not [IO.Path]::IsPathRooted($relativePath)) {
            $RepoRelativePath = $relativePath
        } else {
            throw '-RepoRelativePath is required outside a dt-build/scripts directory.'
        }
    }
    $RepoRelativePath = $RepoRelativePath.Replace('\', '/')
    if ($RepoRelativePath.StartsWith('/') -or $RepoRelativePath -match '(^|/)\.\.?(/|$)|:' ) {
        throw '-RepoRelativePath must be a repository-relative file path without dot segments.'
    }
    $refHead = Invoke-RevisionGit -Arguments @('rev-parse', '--verify', "$Ref^{commit}")
    # Hold a read-only handle to prevent concurrent byte changes while git reads.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $bytes = $stream.Length
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $sha256 = [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    $blob = Invoke-RevisionGit -Arguments @('hash-object', '--no-filters', '--', $Path)
    $headBlob = Invoke-RevisionGit -Arguments @('rev-parse', '--verify', "${refHead}:$RepoRelativePath") -AllowMissing
    $commit = $null
    $commitDate = $null
    $history = Invoke-RevisionGit -Arguments @('log', '--format=%H', $refHead, '--', $RepoRelativePath)
    foreach ($candidate in ($history -split "`n")) {
        if (-not $candidate) { continue }
        $candidateBlob = Invoke-RevisionGit -Arguments @('rev-parse', '--verify', "${candidate}:$RepoRelativePath") -AllowMissing
        if ($candidateBlob -ceq $blob) { $commit = $candidate; break }
    }
    if ($commit) {
        $date = Invoke-RevisionGit -Arguments @('show', '-s', '--format=%cI', $commit)
        $eastern = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
        $commitDate = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::Parse($date), $eastern).ToString('yyyy-MM-ddTHH:mm:sszzz')
    }
    $result = [ordered]@{
        status = $(if ($commit) { 'ON_MAIN' } else { 'NOT_ON_MAIN' })
        path = $Path
        repo_relative_path = $RepoRelativePath
        bytes = $bytes
        sha256 = $sha256
        blob_id = $blob
        ref = $Ref
        repo_root = $RepoRoot
        ref_head = $refHead
        ref_commit_date = Convert-RevisionDate (Invoke-RevisionGit -Arguments @('show', '-s', '--format=%cI', $refHead))
        commit = $commit
        commit_date = $commitDate
        is_ref_head = [bool]($commit -and $headBlob -ceq $blob)
    }
    if ($Json) { $result | ConvertTo-Json -Compress }
    else { [pscustomobject]$result | Format-List }
    if ($commit) { exit 0 }
    exit 3
} catch {
    [Console]::Error.WriteLine("resolve-tooling-revision: $($_.Exception.Message)")
    exit 2
} finally {
    if ($stream) { $stream.Dispose() }
}
