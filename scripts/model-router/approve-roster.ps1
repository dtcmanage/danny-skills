<#
.SYNOPSIS
Review and approve the model roster.
.DESCRIPTION
Use -Seed to create a proposal from the default roster, -Show to review it,
and -Approve [-Jobs <job,...>] to approve all or selected jobs.
Use -Revoke to clear approval so routing falls back to the default roster with an alert.
Use -DeclineDrift -Job <job> to keep the first choice after a drift alert.
.EXAMPLE
pwsh -NoProfile -File scripts/model-router/approve-roster.ps1 -Show
#>
param(
    [switch]$Show,
    [switch]$Approve,
    [switch]$Revoke,
    [switch]$Seed,
    [switch]$DeclineDrift,
    [string]$Job,
    [string[]]$Jobs
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'resolve-model.ps1')
if ($Jobs) { $Jobs = @($Jobs | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

function Write-RouterApprovalJson {
    param([string]$Path, [object]$Value)
    $temp = Join-Path (Split-Path -Parent $Path) ('.router-approval.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try { [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $Value -Depth 40),[Text.UTF8Encoding]::new($false)); [IO.File]::Move($temp,$Path,$true) }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

if (([int][bool]$Show + [int][bool]$Approve + [int][bool]$Revoke + [int][bool]$Seed + [int][bool]$DeclineDrift) -ne 1) { throw 'Choose exactly one roster action.' }
if ($DeclineDrift -and $Job -notin @(Get-RouterJobs)) { throw "Unknown roster job: $Job" }
if ($Job -and -not $DeclineDrift) { throw '-Job requires -DeclineDrift.' }
if ($Jobs -and -not $Approve) { throw '-Jobs requires -Approve.' }
$state = Get-RouterStateDir
Use-RouterOutcomeMutex -StateDir $state -Action {
$rosterPath = Join-Path $state 'roster.json'
$marksPath = Join-Path $state 'drift-marks.json'
$declinesPath = Join-Path $state 'drift-declines.json'
$dir = Join-Path $state 'roster-proposals'
[IO.Directory]::CreateDirectory($dir) | Out-Null
$latest = Read-RouterJsonObject -Path (Join-Path $dir 'latest.json')
if ($Show) {
    if ($latest -and $latest.PSObject.Properties['report'] -and (Test-Path -LiteralPath ([string]$latest.report))) { Get-Content -LiteralPath ([string]$latest.report) -Raw | Write-Output }
    else { 'No roster proposal.' | Write-Output }
    $current = Read-RouterRoster
    "Current roster ($($current.source)):" | Write-Output
    @(Get-RouterJobs | ForEach-Object { [pscustomobject]@{ job=$_; first=$current.roster.jobs.$_.first; first_effort=$current.roster.jobs.$_.first_effort; backup=$current.roster.jobs.$_.backup; backup_effort=$current.roster.jobs.$_.backup_effort } }) | Format-Table -AutoSize | Out-String | Write-Output
} elseif ($Seed) {
    $proposal = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 30
    foreach ($name in @(Get-RouterJobs)) {
        foreach ($slot in @('first','backup')) {
            $proposal.jobs.$name | Add-Member -NotePropertyName "${slot}_effort" -NotePropertyValue (Get-RouterJobEffort -Job $name) -Force
        }
    }
    $proposal.generated_at = (Get-Date).ToUniversalTime().ToString('o')
    $stem = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHHmmss') + '-seed'
    $path = Join-Path $dir ($stem + '.json'); $report = Join-Path $dir ($stem + '.md')
    Write-RouterApprovalJson $path $proposal
    $lines = @('# Model list proposal','','| Job | Current | Proposed | Evidence summary | Backup |','| --- | --- | --- | --- | --- |')
    foreach ($name in @(Get-RouterJobs)) { $lines += "| $name | $($proposal.jobs.$name.first) (effort $($proposal.jobs.$name.first_effort)) | $($proposal.jobs.$name.first) (effort $($proposal.jobs.$name.first_effort)) | Seeded from default roster | $($proposal.jobs.$name.backup) (effort $($proposal.jobs.$name.backup_effort)) |" }
    [IO.File]::WriteAllText($report,(($lines -join "`n") + "`n"),[Text.UTF8Encoding]::new($false))
    Write-RouterApprovalJson (Join-Path $dir 'latest.json') ([pscustomobject]@{proposal=$path;report=$report})
    "Seed proposal: $path" | Write-Output
} elseif ($Approve) {
    if (-not $latest -or -not $latest.PSObject.Properties['proposal'] -or -not (Test-Path -LiteralPath ([string]$latest.proposal))) { throw 'No roster proposal to approve.' }
    $proposal = Get-Content -LiteralPath ([string]$latest.proposal) -Raw | ConvertFrom-Json -Depth 40
    $before = (Read-RouterRoster).roster
    if ($Jobs) {
        $unknown = @($Jobs | Where-Object { $_ -notin @(Get-RouterJobs) } | Sort-Object -Unique)
        if ($unknown.Count) { throw "Unknown roster jobs: $($unknown -join ', ')" }
        $selected = $before | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
        foreach ($name in @($Jobs | Sort-Object -Unique)) {
            $selected.jobs.$name = $proposal.jobs.$name | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        }
        $proposal = $selected
    }
    foreach ($name in @(Get-RouterJobs)) {
        foreach ($slot in @('first','backup')) {
            $proposal.jobs.$name | Add-Member -NotePropertyName "${slot}_effort" -NotePropertyValue (Get-RouterJobEffort -Job $name) -Force
        }
    }
    $proposal.approved = $true; $proposal.approved_at = (Get-Date).ToUniversalTime().ToString('o')
    $errors = @(Test-RouterRoster -Roster $proposal)
    if ($errors.Count) { throw "Invalid roster proposal: $($errors -join '; ')" }
    Write-RouterApprovalJson $rosterPath $proposal
    $changed = @(Get-RouterJobs | Where-Object { $before.jobs.$_.first -ne $proposal.jobs.$_.first })
    if ($changed.Count) {
        Write-RouterApprovalJson $marksPath @((Read-RouterJsonArray -Path $marksPath) | Where-Object { $_.job -notin $changed })
        Write-RouterApprovalJson $declinesPath @((Read-RouterJsonArray -Path $declinesPath) | Where-Object { $_.job -notin $changed })
    }
    'Roster approved.' | Write-Output
} elseif ($Revoke) {
    if (-not (Test-Path -LiteralPath $rosterPath)) { throw 'No roster to revoke.' }
    $current = Get-Content -LiteralPath $rosterPath -Raw | ConvertFrom-Json -Depth 40
    foreach ($name in @(Get-RouterJobs)) {
        foreach ($slot in @('first','backup')) {
            $current.jobs.$name | Add-Member -NotePropertyName "${slot}_effort" -NotePropertyValue (Get-RouterJobEffort -Job $name) -Force
        }
    }
    $current.approved = $false
    Write-RouterApprovalJson $rosterPath $current
    'Roster approval cleared. Routing falls back to the default roster with an alert.' | Write-Output
} else {
    $current = Read-RouterRoster
    $model = [string]$current.roster.jobs.$Job.first
    $declines = @((Read-RouterJsonArray -Path $declinesPath) | Where-Object { $_.job -ne $Job -or $_.model -ne $model })
    $declines += [pscustomobject]@{model=$model;job=$Job;declined_at=(Get-Date).ToUniversalTime().ToString('o')}
    Write-RouterApprovalJson $declinesPath $declines
    Write-RouterApprovalJson $marksPath @((Read-RouterJsonArray -Path $marksPath) | Where-Object { $_.job -ne $Job })
    "Drift declined for $Job." | Write-Output
}

} # shared outcome / roster mutation lock
