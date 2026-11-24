#Requires -Version 7.0
# Compact state navigation, with complete fresh lifecycle and mandatory authorization reads.
param(
    [Parameter(Mandatory)][string]$RunFolder,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$BuildStatePath,
    [Parameter(Mandatory)][string]$CoordinatorId,
    [ValidateRange(0, 10000)][int]$Part = 0,
    [ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectSha,
    [ValidateSet('current', 'history')][string]$Section = 'current'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Capture everything before printing; a failed verification never emits a partial success.
$recordText = & (Join-Path $PSScriptRoot 'read-resume-record.ps1') -RunFolder $RunFolder -RunId $RunId -BuildStatePath $BuildStatePath -CoordinatorId $CoordinatorId
$record = ($recordText -join "`n") | ConvertFrom-Json
$fullRecord = $record | ConvertTo-Json -Depth 20 -Compress
if ($Section -eq 'history') { $recordText; return }
function Get-StateStableCheckpoint([string]$Text) {
    return [regex]::Replace($Text, '(?m)^status_line:[^\r\n]*(?:\r?\n)?', '')
}
function Get-StateHash([string]$Text) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}
$snapshotDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'dt-build/coordinator-snapshots'
function Initialize-StateSnapshotDirectory {
    if ($IsWindows) { $null = [IO.Directory]::CreateDirectory($snapshotDirectory); return }
    $mode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute
    $null = [IO.Directory]::CreateDirectory($snapshotDirectory, $mode)
    $item = Get-Item -LiteralPath $snapshotDirectory -Force
    if ($item.LinkType -or [IO.File]::GetUnixFileMode($snapshotDirectory) -ne $mode) { throw 'DT_RESUME_SNAPSHOT: snapshot directory must be private (0700) and not a link' }
}
function Get-StateAuthorityRecord($Record) {
    [ordered]@{ approvals = $Record.approvals; operator_notes = $Record.operator_notes; context_wall = $Record.context_wall } | ConvertTo-Json -Depth 20 -Compress
}
function Get-StateLiveEvidence {
    # dt-job explicitly returns before verb dispatch when dot-sourced. Preserve the
    # caller's run folder through its parameter binding; no verb is dispatched.
    . (Join-Path $PSScriptRoot 'dt-job.ps1') -RunFolder $RunFolder
    $live = @(Get-DtJobRecords -RunFolder $RunFolder | Where-Object { $_.status -in @('queued','running','blocked','orphaned') } | Select-Object job_id, status, kind, depends_on, status_reason, working_directory)
    $events = @(Get-DtJobEvents -RunFolder $RunFolder | Select-Object -Last 5)
    "## Live jobs and latest five events (evidence only)`n$([ordered]@{ jobs = $live; events = $events } | ConvertTo-Json -Depth 10 -Compress)"
}
$identity = "$([IO.Path]::GetFullPath($RunFolder))`n$RunId`n$([IO.Path]::GetFullPath($BuildStatePath))`n$CoordinatorId"
$snapshotPrefix = Get-StateHash $identity
if ($Part -gt 0) {
    # read-resume-record above revalidates the live registration, watcher lease and runnable state on EVERY part.
    Initialize-StateSnapshotDirectory
    if (-not $ExpectSha) { throw 'DT_RESUME_PART: -ExpectSha from the read plan is required' }
    $snapshotPath = Join-Path $snapshotDirectory "$snapshotPrefix-$ExpectSha.json"
    if (-not (Test-Path -LiteralPath $snapshotPath)) { throw 'DT_RESUME_CHANGED: snapshot missing; restart the complete read' }
    $snapshot = [IO.File]::ReadAllText($snapshotPath) | ConvertFrom-Json
    if ((Get-StateHash $snapshot.output) -cne $ExpectSha -or $snapshot.identity -cne $identity) { throw 'DT_RESUME_CHANGED: snapshot integrity mismatch' }
    # Lifecycle jobs and status updates may advance. Authority, cursor and next action may not.
    if ((Get-StateStableCheckpoint ([IO.File]::ReadAllText($BuildStatePath))) -cne $snapshot.checkpoint) { throw 'DT_RESUME_CHANGED: checkpoint changed; restart the complete read' }
    # Rediscover known paths and boundary references, including files absent at part 0.
    $fresh = & (Join-Path $PSScriptRoot 'verify-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -PreferDigest | ConvertFrom-Json
    if ($fresh.manifest_sha256 -cne $snapshot.manifest_sha256 -or (Get-StateAuthorityRecord $record) -cne $snapshot.authority_record) { throw 'DT_RESUME_CHANGED: authority changed; restart the complete read' }
    $count = [int][Math]::Ceiling($snapshot.output.Length / 22000.0)
    if ($Part -gt $count) { throw "DT_RESUME_PART: requested $Part; only $count parts" }
    $start = ($Part - 1) * 22000
    $tail = ''
    if ($Part -eq $count) {
        # Fresh evidence is outside the hashed snapshot, explicitly labelled as the final read.
        $tail = "`n`n## Final-part refreshed evidence (supersedes snapshot jobs/events)`n$(Get-StateLiveEvidence)"
    }
    $recheckText = & (Join-Path $PSScriptRoot 'read-resume-record.ps1') -RunFolder $RunFolder -RunId $RunId -BuildStatePath $BuildStatePath -CoordinatorId $CoordinatorId
    if (((($recheckText -join "`n") | ConvertFrom-Json) | ConvertTo-Json -Depth 20 -Compress) -cne $fullRecord) { throw 'DT_RESUME_CHANGED: run record changed during part collection' }
    if ($Part -eq $count) { Remove-Item -LiteralPath $snapshotPath -Force }
    "State digest part $Part/$count; sha256=$ExpectSha`n" + $snapshot.output.Substring($start, [Math]::Min(22000, $snapshot.output.Length - $start))
    if ($tail) { $tail }
    return
}
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
    $legacyOptions = @{ LegacyArtifactKinds = $true }
    try {
        $legacy = & (Join-Path $PSScriptRoot 'verify-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -PreferDigest @legacyOptions | ConvertFrom-Json
    } catch {
        $legacyOptions = @{ LegacyLifecycleLocators = $true }
        $legacy = & (Join-Path $PSScriptRoot 'verify-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -PreferDigest @legacyOptions | ConvertFrom-Json
    }
    $oldManifest = [IO.File]::ReadAllText((Join-Path $RunFolder 'authority-digest.json')) | ConvertFrom-Json
    $staging = Join-Path ([IO.Path]::GetTempPath()) ('dt-authority-migration-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = & (Join-Path $PSScriptRoot 'build-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -DryRun -OutputDirectory $staging
        $candidate = [IO.File]::ReadAllText((Join-Path $staging 'authority-digest.json')) | ConvertFrom-Json
        $oldSources = @($oldManifest.originals | Select-Object path, sha256, bytes, chars, extract) | ConvertTo-Json -Depth 8 -Compress
        $newSources = @($candidate.originals | Select-Object path, sha256, bytes, chars, extract) | ConvertTo-Json -Depth 8 -Compress
        # Lifecycle migration changes checkpoint hashing by removing status_line. The legacy
        # verifier already checked the old checkpoint hash; comparing it to the new algorithm is invalid.
        if ($oldSources -cne $newSources -or ($oldManifest.checkpoint_authority_sha256 -cne $candidate.checkpoint_authority_sha256 -and -not $legacyOptions.ContainsKey('LegacyLifecycleLocators'))) { throw 'DT_RESUME_MIGRATION_CHANGED: sources changed; use full-read fallback' }
        $recheck = & (Join-Path $PSScriptRoot 'verify-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -PreferDigest @legacyOptions | ConvertFrom-Json
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
# Avoid duplicate text only when a complete original will actually be included below.
foreach ($field in @('approvals', 'operator_notes')) {
    $leaf = if ($field -eq 'approvals') { 'approvals.json' } else { 'operator-notes.json' }
    if ((Join-Path $RunFolder $leaf) -in $verification.mandatory_paths) { $record.PSObject.Properties.Remove($field) }
}
$record.PSObject.Properties.Remove('evidence_notes')
$blocks.Add("## Verified run identity and recovery navigation`n$($record | ConvertTo-Json -Depth 20 -Compress)`nComplete approvals and standing operator notes appear here or as mandatory originals below. History: rerun with -Section history; event and job evidence: jobs/events.jsonl and jobs/<id>/. Multipart jobs/events are superseded by the final-part refreshed evidence; use that view before marking bootstrap.")
$blocks.Add((Get-StateLiveEvidence))
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
    $tables = [regex]::Matches($roadmap, '(?ims)^## Milestones[^\S\r\n]*\r?\n(.*?)(?=^## |\z)')
    if ($tables.Count -ne 1) { throw 'DT_RESUME_MILESTONE: missing or ambiguous Milestones table' }
    $lines = @($tables[0].Groups[1].Value -split '\r?\n' | Where-Object { $_ -match '^\|' })
    $headers = @($lines | Where-Object { $_ -match '^\|\s*(?i:id)\s*\|' })
    $separators = @($lines | Where-Object { $_ -match '^\|\s*:?-{2,}' })
    if ($headers.Count -ne 1 -or $separators.Count -ne 1) { throw 'DT_RESUME_MILESTONE: missing or ambiguous id column' }
    $data = @($lines | Where-Object { $_ -ne $headers[0] -and $_ -ne $separators[0] })
    $ids = @($data | ForEach-Object { ($_ -split '\|')[1].Trim() })
    if (-not $ids.Count) { throw 'DT_RESUME_MILESTONE: Milestones table has no data rows; add an active id and set current_milestone to that id' }
    if (@($ids | Group-Object -CaseSensitive | Where-Object Count -gt 1).Count) { throw 'DT_RESUME_MILESTONE: duplicate roadmap ids' }
    $current = @($data | Where-Object {
        $id = ($_ -split '\|')[1].Trim()
        $id -and [regex]::IsMatch($milestoneMatch.Groups[1].Value, '(?<![\p{L}\p{N}_.-])' + [regex]::Escape($id) + '(?![\p{L}\p{N}_.-])', [Text.RegularExpressions.RegexOptions]::None)
    })
    if (-not $current.Count) { throw "DT_RESUME_MILESTONE: no roadmap id in current_milestone '$($milestoneMatch.Groups[1].Value)'. Write exactly: current_milestone: $($ids[0]) (or replace $($ids[0]) with an active id from: $($ids -join ', '))." }
    $rows = @($headers[0], $separators[0]) + $current
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
$authorityRecheck = & (Join-Path $PSScriptRoot 'verify-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -PreferDigest | ConvertFrom-Json
if ($authorityRecheck.manifest_sha256 -cne $verification.manifest_sha256) { throw 'DT_RESUME_CHANGED: authority manifest changed during collection' }
$recheckText = & (Join-Path $PSScriptRoot 'read-resume-record.ps1') -RunFolder $RunFolder -RunId $RunId -BuildStatePath $BuildStatePath -CoordinatorId $CoordinatorId
if (((($recheckText -join "`n") | ConvertFrom-Json) | ConvertTo-Json -Depth 20 -Compress) -cne $fullRecord) { throw 'DT_RESUME_CHANGED: run record changed during collection' }
if ((Get-StateStableCheckpoint ([IO.File]::ReadAllText($BuildStatePath))) -cne (Get-StateStableCheckpoint $checkpoint) -or
    ($roadmapMatch.Success -and $milestoneMatch.Success -and [IO.File]::ReadAllText($roadmapPath) -cne $roadmap)) { throw 'DT_RESUME_CHANGED: run record, checkpoint or roadmap changed during collection' }
$output = $blocks -join "`n`n"
# Never truncate an authorization source to fit the tool display. Large legacy runs use numbered parts.
$limit = 22000
$count = [int][Math]::Ceiling($output.Length / [double]$limit)
$hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($output))).ToLowerInvariant()
if ($ExpectSha -and $ExpectSha -cne $hash) { throw 'DT_RESUME_CHANGED: digest sha256 mismatch; restart the complete read' }
if ($count -gt 1) {
    Initialize-StateSnapshotDirectory
    # Snapshots are temporary bootstrap artifacts, never durable run policy or history.
    Get-ChildItem -LiteralPath $snapshotDirectory -Filter '*.json' -File |
        Where-Object LastWriteTimeUtc -lt ([DateTime]::UtcNow.AddDays(-1)) | Remove-Item -Force
    $snapshot = [ordered]@{ identity = $identity; checkpoint = Get-StateStableCheckpoint $checkpoint; manifest_sha256 = $verification.manifest_sha256; authority_record = Get-StateAuthorityRecord ($fullRecord | ConvertFrom-Json); output = $output }
    $snapshotPath = Join-Path $snapshotDirectory "$snapshotPrefix-$hash.json"
    $temporary = "$snapshotPath.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, ($snapshot | ConvertTo-Json -Depth 12 -Compress))
    Move-Item -LiteralPath $temporary -Destination $snapshotPath -Force
    [ordered]@{ state = 'mandatory_reads_pending'; parts = $count; chars = $output.Length; sha256 = $hash; instruction = 'Run this command with -Part 1 through parts and -ExpectSha <sha256 from this plan>. All parts serve one verified snapshot. Read every part in order. Authority or checkpoint changes require restarting. Do not mark-bootstrap before all parts are read.' } | ConvertTo-Json -Compress
} else { [Console]::Out.WriteLine($output) }
