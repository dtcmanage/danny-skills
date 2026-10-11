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
[ordered]@{ registration = $entry; lease = $lease; state = $state; approvals = (Get-DtJobApprovals -RunFolder $ResumeRunFolder) } | ConvertTo-Json -Depth 10
