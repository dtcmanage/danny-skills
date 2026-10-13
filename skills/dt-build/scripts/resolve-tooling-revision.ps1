# Proves a dt-build tooling file matches a published danny-skills main commit; usage: references/tooling-revision-provenance.md.
param(
    [string]$Path,
    [string]$RepoRoot,
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

$stream = $null
try {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '-Path is required.' }
    $file = Get-Item -LiteralPath $Path
    if ($file.PSIsContainer) { throw "Path is not a file: $Path" }
    $Path = $file.FullName
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $skill = Get-Item -LiteralPath (Split-Path -Parent $PSScriptRoot)
        $target = $skill.ResolveLinkTarget($true)
        if ($target) { $skill = $target }
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $skill.FullName)
    }
    $RepoRoot = (Get-Item -LiteralPath $RepoRoot).FullName
    if ([string]::IsNullOrWhiteSpace($Ref) -or $Ref.StartsWith('-')) { throw '-Ref must name a git revision.' }
    if ([string]::IsNullOrWhiteSpace($RepoRelativePath)) {
        # Both repo copies and installed/junctioned dt-build skill directories.
        if ($Path.Replace('\', '/') -match '/dt-build/scripts/([^/]+)$') {
            $RepoRelativePath = 'skills/dt-build/scripts/' + $Matches[1]
        } else {
            throw '-RepoRelativePath is required outside a dt-build/scripts directory.'
        }
    }
    $RepoRelativePath = $RepoRelativePath.Replace('\', '/')
    if ($RepoRelativePath.StartsWith('/') -or $RepoRelativePath -match '(^|/)\.\.?(/|$)|:' ) {
        throw '-RepoRelativePath must be a repository-relative file path without dot segments.'
    }
    if ($Fetch) { $null = Invoke-RevisionGit -Arguments @('fetch', 'origin') }
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
        ref_head = $refHead
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
