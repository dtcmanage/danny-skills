#Requires -Version 7.0
# Archive the old checkpoint and atomically replace it, retaining dt-job's current owned fields.
# Keep governing boundary/approval paths in the candidate; successors plan them with
# boundary-ledger.ps1. Do not copy ledger rows or require unchanged sources to be reread.
# Requires one plain-English status_line (at most 200 characters); it is not counted toward the 8 KiB cap.
param(
    [Parameter(Mandatory)][Alias('RunFolder')][string]$ResumeRunFolder,
    [Parameter(Mandatory)][Alias('BuildStatePath')][string]$ResumeBuildStatePath,
    [Parameter(Mandatory)][Alias('ContentPath')][string]$ResumeContentPath
)
. (Join-Path $PSScriptRoot 'dt-job.ps1')

function Get-CheckpointCountedBytes {
    # The 8 KiB cap counts everything except the status_line, so a readable status never costs checkpoint room.
    param([string]$Text)
    return [Text.Encoding]::UTF8.GetByteCount([regex]::Replace($Text, '(?m)^status_line:[^\r\n]*(?:\r?\n|$)', ''))
}

function Assert-CheckpointStatusLine {
    # status_line: one plain-English sentence, at most 200 characters, saying the current milestone, what is
    # running, what is waiting and on what, and the next step. Danny reads it from his phone, so glued
    # tokens ("M09phase2j0359;nativej0360queuedRust", CC v2.1, Nov 22) are refused.
    param([string]$Text)
    $lines = @([regex]::Matches($Text, '(?m)^status_line:[ \t]*([^\r\n]*)$'))
    if ($lines.Count -ne 1) { throw 'DT_CHECKPOINT_STATUS_LINE: exactly one status_line line required (plain English, one sentence, at most 200 characters: milestone, what runs, what waits and on what, next step)' }
    $status = $lines[0].Groups[1].Value.Trim()
    if (-not $status -or $status -match '^__[A-Z_]+__$' -or $status -eq 'none') { throw 'DT_CHECKPOINT_STATUS_LINE: status_line is empty; write one plain-English sentence' }
    if ($status.Length -gt 200) { throw "DT_CHECKPOINT_STATUS_LINE: status_line is $($status.Length) characters; the limit is 200" }
    $words = @($status -split '\s+' | Where-Object { $_ })
    if ($words.Count -lt 6) { throw "DT_CHECKPOINT_STATUS_LINE: status_line has $($words.Count) words; write a plain sentence, not a code" }
    foreach ($word in $words) {
        $bare = $word.Trim('`', '"', "'", '(', ')', '[', ']', ',', ';', '.', ':')
        # Paths, URLs and commit SHAs are allowed; any other run of more than 24 characters is glued text.
        if ($bare.Length -le 24 -or $bare -match '[/\\]' -or $bare -match '^[0-9a-f]{7,40}$') { continue }
        throw "DT_CHECKPOINT_STATUS_LINE: compressed token '$bare' in status_line; use spaced plain words"
    }
}

$candidate = Read-DtJobText -Path $ResumeContentPath
if ((Get-CheckpointCountedBytes $candidate) -gt 8192) { throw 'DT_CHECKPOINT_SIZE: checkpoint exceeds 8 KiB (status_line excluded); archive history in the run folder (build-decision-log.md, checkpoint-history/) and retain current boundaries/pointers' }
foreach ($field in @('run_status', 'last_consumed_event_seq')) {
    if ([regex]::Matches($candidate, "(?m)^${field}:.*$").Count -ne 1) { throw "DT_CHECKPOINT_SHAPE: exactly one $field line required" }
}
Assert-CheckpointStatusLine $candidate
$result = Invoke-DtJobLocked -RunFolder $ResumeRunFolder -Action {
    $entry = Get-DtJobRegistryEntry -RunFolder $ResumeRunFolder
    if ($null -eq $entry -or -not (Test-DtCtxSamePath $entry.build_state_path $ResumeBuildStatePath)) { throw 'DT_CHECKPOINT_IDENTITY: checkpoint does not match run registration' }
    $old = Read-DtJobText -Path $ResumeBuildStatePath
    $state = Get-DtJobRunState -BuildStatePath $ResumeBuildStatePath
    $next = [regex]::Replace($candidate, '(?m)^run_status:.*$', "run_status: $($state.run_status)")
    $next = [regex]::Replace($next, '(?m)^last_consumed_event_seq:.*$', "last_consumed_event_seq: $($state.last_consumed_event_seq)")
    if ((Get-CheckpointCountedBytes $next) -gt 8192) { throw 'DT_CHECKPOINT_SIZE: final checkpoint exceeds 8 KiB (status_line excluded)' }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($old))).ToLowerInvariant()
    $archive = Join-Path $ResumeRunFolder "checkpoint-history/$hash.md"
    if (-not (Test-Path -LiteralPath $archive)) { Write-DtJobAtomic -Path $archive -Content $old }
    Write-DtJobAtomic -Path $ResumeBuildStatePath -Content $next
    [ordered]@{ checkpoint = [IO.Path]::GetFullPath($ResumeBuildStatePath); history = $archive; bytes = [Text.Encoding]::UTF8.GetByteCount($next) }
}
$result | ConvertTo-Json -Compress
