#Requires -Version 7.0
# Read-only, bounded authorization/identity record. Does not register, resume, consume or approve.
param(
    [Parameter(Mandatory)][Alias('RunFolder')][string]$ResumeRunFolder,
    [Parameter(Mandatory)][Alias('RunId')][string]$ResumeRunId,
    [Parameter(Mandatory)][Alias('BuildStatePath')][string]$ResumeBuildStatePath,
    [Parameter(Mandatory)][Alias('CoordinatorId')][string]$ResumeCoordinatorId
)
. (Join-Path $PSScriptRoot 'dt-job.ps1')
$entry = Get-DtJobRegistryEntry -RunFolder $ResumeRunFolder
if ($null -eq $entry -or $entry.run_id -cne $ResumeRunId -or
    -not (Test-DtCtxSamePath $entry.build_state_path $ResumeBuildStatePath) -or -not $entry.managed) {
    throw 'DT_RESUME_IDENTITY: supplied run/checkpoint does not match the managed registration'
}
$lease = Get-DtJobLease -RunFolder $ResumeRunFolder
if ($null -eq $lease -or $lease.coordinator_id -cne $ResumeCoordinatorId -or $lease.launched_by -ne 'watcher' -or
    ($lease.PSObject.Properties['released_utc'] -and $lease.released_utc)) {
    throw 'DT_RESUME_IDENTITY: coordinator does not hold the watcher lease'
}
$state = Get-DtJobRunState -BuildStatePath $ResumeBuildStatePath
if ($state.run_status -ne 'runnable') { throw "DT_RESUME_STOPPED: run_status $($state.run_status)" }
$wallPath = (Get-DtJobPaths -RunFolder $ResumeRunFolder).ContextWall
$wall = if (Test-Path -LiteralPath $wallPath) { try { Read-DtJobText -Path $wallPath | ConvertFrom-Json } catch { $null } } else { $null }
$automatic = $null; $coordinatorNote = $null
foreach ($note in @(Get-ChildItem -LiteralPath $ResumeRunFolder -Filter 'coordinator-handoff-*.md' -File | Sort-Object LastWriteTimeUtc -Descending)) {
    $first = ((Read-DtJobText -Path $note.FullName) -split '\r?\n', 2)[0]
    if ($first.StartsWith('# Automatic handoff:', [System.StringComparison]::Ordinal)) { if ($null -eq $automatic) { $automatic = $note } }
    elseif ($null -eq $coordinatorNote) { $coordinatorNote = $note }
}
$killHandoff = if ($null -ne $automatic -and ($null -eq $coordinatorNote -or $automatic.LastWriteTimeUtc -gt $coordinatorNote.LastWriteTimeUtc)) { $automatic.FullName } else { $null }
$firstLaunch = $null
$launchPath = (Get-DtJobPaths -RunFolder $ResumeRunFolder).Launches
if (Test-Path -LiteralPath $launchPath) {
    foreach ($line in ((Read-DtJobText -Path $launchPath) -split '\r?\n')) {
        try { $row = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -ne $row -and $row.PSObject.Properties['type'] -and $row.type -eq 'launch') {
            try { $firstLaunch = ConvertTo-DtJobUtc $row.launched_utc } catch { }
            break
        }
    }
}
$worktrees = [ordered]@{ recorded = @(Get-DtJobWorktrees -RunFolder $ResumeRunFolder | Select-Object -First 20); live_since_run_start = @(if ($null -ne $firstLaunch) { Get-DtJobLiveWorktrees -RunFolder $ResumeRunFolder -SinceUtc $firstLaunch | Select-Object -First 20 }) }
[ordered]@{ pin = (Get-DtJobRunPin -RunFolder $ResumeRunFolder); registration = $entry; lease = $lease; state = $state; approvals = (Get-DtJobApprovals -RunFolder $ResumeRunFolder); operator_notes = @(Get-DtJobOperatorNotes -RunFolder $ResumeRunFolder); evidence_notes = @(Get-DtJobEvidenceNotes -RunFolder $ResumeRunFolder); evidence_notes_label = $script:DtJobEvidenceNotesLabel; context_wall = $wall; kill_handoff = $killHandoff; worktrees = $worktrees } | ConvertTo-Json -Depth 10
