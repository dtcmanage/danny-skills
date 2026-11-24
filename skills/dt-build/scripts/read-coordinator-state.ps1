#Requires -Version 7.0
# Compact state navigation, with complete fresh lifecycle and mandatory authorization reads.
param(
    [Parameter(Mandatory)][string]$RunFolder,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$BuildStatePath,
    [Parameter(Mandatory)][string]$CoordinatorId,
    [ValidateRange(0, 10000)][int]$Part = 0,
    [ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectSha
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Capture everything before printing; a failed verification never emits a partial success.
$recordText = & (Join-Path $PSScriptRoot 'read-resume-record.ps1') -RunFolder $RunFolder -RunId $RunId -BuildStatePath $BuildStatePath -CoordinatorId $CoordinatorId
foreach ($required in @('build-state.md', 'build-plan.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $RunFolder $required) -PathType Leaf)) { throw "DT_RESUME_SOURCE_MISSING: $required" }
}
$checkpoint = [IO.File]::ReadAllText($BuildStatePath)
if (-not (Test-Path -LiteralPath (Join-Path $RunFolder 'authority-digest.json'))) {
    $null = & (Join-Path $PSScriptRoot 'build-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath
}
try {
    $verification = & (Join-Path $PSScriptRoot 'verify-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -PreferDigest | ConvertFrom-Json
} catch {
    # Upgrade only a fully verified old snapshot. Changed bytes, coverage, pins, checkpoint
    # authority or approvals fail BOTH verifiers and cannot be silently repinned here.
    $legacy = & (Join-Path $PSScriptRoot 'verify-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -PreferDigest -LegacyArtifactKinds | ConvertFrom-Json
    $oldManifest = [IO.File]::ReadAllText((Join-Path $RunFolder 'authority-digest.json')) | ConvertFrom-Json
    $staging = Join-Path ([IO.Path]::GetTempPath()) ('dt-authority-migration-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = & (Join-Path $PSScriptRoot 'build-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -DryRun -OutputDirectory $staging
        $candidate = [IO.File]::ReadAllText((Join-Path $staging 'authority-digest.json')) | ConvertFrom-Json
        $oldSources = @($oldManifest.originals | Select-Object path, sha256, bytes, chars, extract) | ConvertTo-Json -Depth 8 -Compress
        $newSources = @($candidate.originals | Select-Object path, sha256, bytes, chars, extract) | ConvertTo-Json -Depth 8 -Compress
        if ($oldSources -cne $newSources -or $oldManifest.checkpoint_authority_sha256 -cne $candidate.checkpoint_authority_sha256) { throw 'DT_RESUME_MIGRATION_CHANGED: sources changed; use full-read fallback' }
        $recheck = & (Join-Path $PSScriptRoot 'verify-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -PreferDigest -LegacyArtifactKinds | ConvertFrom-Json
        if ($recheck.manifest_sha256 -cne $legacy.manifest_sha256) { throw 'DT_RESUME_MIGRATION_CHANGED: manifest changed' }
        # Publish the verified, fixed snapshot, pin last. A later source change fails verification.
        foreach ($name in @('authority-digest.md','authority-digest.json','authority-digest.json.sha256')) {
            [IO.File]::WriteAllBytes((Join-Path $RunFolder $name), [IO.File]::ReadAllBytes((Join-Path $staging $name)))
        }
    } finally { if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force } }
    $verification = & (Join-Path $PSScriptRoot 'verify-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -PreferDigest | ConvertFrom-Json
}
$digest = & (Join-Path $PSScriptRoot 'read-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -PreferDigest
$blocks = [Collections.Generic.List[string]]::new()
$blocks.Add("# Coordinator state digest`nNavigation is not permission. Mandatory sources below are complete, not summaries.")
$blocks.Add("## Checkpoint (full): $BuildStatePath`n$checkpoint")
$blocks.Add("## Verified run record (complete approvals, pending approvals and operator notes)`n$recordText")
# Roadmap implementation is deferred. Preserve the exact Milestones table header and current rows.
$milestones = [regex]::Matches($checkpoint, '(?m)^current_milestone:[^\S\r\n]*([^\r\n]*)$')
$roadmaps = [regex]::Matches($checkpoint, '(?m)^roadmap_path:[^\S\r\n]*([^\r\n]*)$')
if ($milestones.Count -gt 1 -or $roadmaps.Count -gt 1) { throw 'DT_RESUME_MILESTONE: duplicate cursor or roadmap field' }
$milestoneMatch = [regex]::Match($checkpoint, '(?m)^current_milestone:[^\S\r\n]*([^\r\n]*)$')
$roadmapMatch = [regex]::Match($checkpoint, '(?m)^roadmap_path:[^\S\r\n]*([^\r\n]*)$')
if ($milestoneMatch.Success -and -not $roadmapMatch.Success) { throw 'DT_RESUME_MILESTONE: roadmap_path required for current_milestone' }
if ($roadmapMatch.Success -and $milestoneMatch.Success) {
    $roadmapPath = $roadmapMatch.Groups[1].Value.Trim().Trim('`', '"', "'")
    if (-not [IO.Path]::IsPathFullyQualified($roadmapPath)) { $roadmapPath = Join-Path (Split-Path -Parent $BuildStatePath) $roadmapPath }
    $roadmap = [IO.File]::ReadAllText($roadmapPath)
    # One exact ID, optionally followed by parenthesized commentary. Never mine IDs from prose.
    $cursor = [regex]::Match($milestoneMatch.Groups[1].Value.Trim(), '^([^\s|(),]+)(?:\s+\([^\r\n]*\))?$')
    if (-not $cursor.Success) { throw 'DT_RESUME_MILESTONE: invalid current_milestone' }
    $id = $cursor.Groups[1].Value
    $tables = [regex]::Matches($roadmap, '(?ims)^## Milestones[^\S\r\n]*\r?\n(.*?)(?=^## |\z)')
    if ($tables.Count -ne 1) { throw 'DT_RESUME_MILESTONE: missing or ambiguous Milestones table' }
    $lines = @($tables[0].Groups[1].Value -split '\r?\n' | Where-Object { $_ -match '^\|' })
    $headers = @($lines | Where-Object { $_ -match '^\|\s*(?i:id)\s*\|' })
    $separators = @($lines | Where-Object { $_ -match '^\|\s*:?-{2,}' })
    $current = @($lines | Where-Object { ($_ -split '\|')[1].Trim() -ceq $id })
    if ($headers.Count -ne 1 -or $separators.Count -ne 1 -or $current.Count -ne 1 -or $current[0] -eq $headers[0]) { throw 'DT_RESUME_MILESTONE: current milestone row missing or ambiguous' }
    $rows = @($headers[0], $separators[0], $current[0])
    $blocks.Add("## Current roadmap rows (navigation only): $roadmapPath`n$($rows -join "`n")")
} else { $blocks.Add('## Current roadmap rows: no current_milestone/roadmap_path declared; use checkpoint next action after marking.') }
$blocks.Add(($digest -join "`n"))
$seen = [Collections.Generic.HashSet[string]]::new($(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
$null = $seen.Add([IO.Path]::GetFullPath($BuildStatePath))
foreach ($path in $verification.mandatory_paths) {
    if (-not $seen.Add([IO.Path]::GetFullPath($path))) { continue }
    $original = & (Join-Path $PSScriptRoot 'read-authority-original.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -Path $path
    $blocks.Add("## Mandatory original (full): $path`n$($original -join "`n")")
}
# Recheck after collecting sources; no mixture of changed authority may be presented as verified.
$null = & (Join-Path $PSScriptRoot 'verify-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -PreferDigest
$recordRecheck = & (Join-Path $PSScriptRoot 'read-resume-record.ps1') -RunFolder $RunFolder -RunId $RunId -BuildStatePath $BuildStatePath -CoordinatorId $CoordinatorId
if (($recordText -join "`n") -cne ($recordRecheck -join "`n") -or [IO.File]::ReadAllText($BuildStatePath) -cne $checkpoint -or
    ($roadmapMatch.Success -and $milestoneMatch.Success -and [IO.File]::ReadAllText($roadmapPath) -cne $roadmap)) { throw 'DT_RESUME_CHANGED: run record, checkpoint or roadmap changed during collection' }
$output = $blocks -join "`n`n"
# Never truncate an authorization source to fit the tool display. Large legacy runs use numbered parts.
$limit = 22000
$count = [int][Math]::Ceiling($output.Length / [double]$limit)
$hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($output))).ToLowerInvariant()
if ($Part -gt 0 -and -not $ExpectSha) { throw 'DT_RESUME_PART: -ExpectSha from the read plan is required' }
if ($ExpectSha -and $ExpectSha -cne $hash) { throw 'DT_RESUME_CHANGED: digest sha256 mismatch; restart the complete read' }
if ($Part -gt $count) { throw "DT_RESUME_PART: requested $Part; only $count parts" }
if ($count -gt 1 -and $Part -eq 0) {
    [ordered]@{ state = 'mandatory_reads_pending'; parts = $count; chars = $output.Length; sha256 = $hash; instruction = 'Run this command with -Part 1 through parts and -ExpectSha <sha256 from this plan>. Read every part in order. A mismatch fails; restart the complete read. Do not mark-bootstrap before all parts are read.' } | ConvertTo-Json -Compress
} elseif ($Part -gt 0) {
    $start = ($Part - 1) * $limit
    "State digest part $Part/$count; sha256=$hash`n" + $output.Substring($start, [Math]::Min($limit, $output.Length - $start))
} else { [Console]::Out.WriteLine($output) }
