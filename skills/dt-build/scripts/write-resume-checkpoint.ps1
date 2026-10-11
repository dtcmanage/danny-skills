#Requires -Version 7.0
# Archive the old checkpoint and atomically replace it, retaining dt-job's current owned fields.
param(
    [Parameter(Mandatory)][Alias('RunFolder')][string]$ResumeRunFolder,
    [Parameter(Mandatory)][Alias('BuildStatePath')][string]$ResumeBuildStatePath,
    [Parameter(Mandatory)][Alias('ContentPath')][string]$ResumeContentPath
)
. (Join-Path $PSScriptRoot 'dt-job.ps1')
$candidate = Read-DtJobText -Path $ResumeContentPath
if ([Text.Encoding]::UTF8.GetByteCount($candidate) -gt 8192) { throw 'DT_CHECKPOINT_SIZE: checkpoint exceeds 8 KiB; archive history in the run folder and retain current boundaries/pointers' }
foreach ($field in @('run_status', 'last_consumed_event_seq')) {
    if ([regex]::Matches($candidate, "(?m)^${field}:.*$").Count -ne 1) { throw "DT_CHECKPOINT_SHAPE: exactly one $field line required" }
}
$result = Invoke-DtJobLocked -RunFolder $ResumeRunFolder -Action {
    $entry = Get-DtJobRegistryEntry -RunFolder $ResumeRunFolder
    if ($null -eq $entry -or -not (Test-DtCtxSamePath $entry.build_state_path $ResumeBuildStatePath)) { throw 'DT_CHECKPOINT_IDENTITY: checkpoint does not match run registration' }
    $old = Read-DtJobText -Path $ResumeBuildStatePath
    $state = Get-DtJobRunState -BuildStatePath $ResumeBuildStatePath
    $next = [regex]::Replace($candidate, '(?m)^run_status:.*$', "run_status: $($state.run_status)")
    $next = [regex]::Replace($next, '(?m)^last_consumed_event_seq:.*$', "last_consumed_event_seq: $($state.last_consumed_event_seq)")
    if ([Text.Encoding]::UTF8.GetByteCount($next) -gt 8192) { throw 'DT_CHECKPOINT_SIZE: final checkpoint exceeds 8 KiB' }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($old))).ToLowerInvariant()
    $archive = Join-Path $ResumeRunFolder "checkpoint-history/$hash.md"
    if (-not (Test-Path -LiteralPath $archive)) { Write-DtJobAtomic -Path $archive -Content $old }
    Write-DtJobAtomic -Path $ResumeBuildStatePath -Content $next
    [ordered]@{ checkpoint = [IO.Path]::GetFullPath($ResumeBuildStatePath); history = $archive; bytes = [Text.Encoding]::UTF8.GetByteCount($next) }
}
$result | ConvertTo-Json -Compress
