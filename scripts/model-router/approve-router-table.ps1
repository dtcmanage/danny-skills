param(
    [switch]$Show,
    [switch]$Approve,
    [switch]$Revoke,
    [string]$TablePath,
    [switch]$Roster,
    [switch]$Seed,
    [switch]$DeclineDrift,
    [string]$Job
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'resolve-model.ps1')

function Write-RouterApprovalJson {
    param([string]$Path, [object]$Value)
    $temp = Join-Path (Split-Path -Parent $Path) ('.router-approval.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try { [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $Value -Depth 40),[Text.UTF8Encoding]::new($false)); [IO.File]::Move($temp,$Path,$true) }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

if ($Roster) {
    if (([int][bool]$Show + [int][bool]$Approve + [int][bool]$Revoke + [int][bool]$Seed + [int][bool]$DeclineDrift) -ne 1) { throw 'Choose exactly one roster action.' }
    if ($DeclineDrift -and $Job -notin @(Get-RouterJobs)) { throw "Unknown roster job: $Job" }
    $state = Get-RouterStateDir
    $rosterPath = Join-Path $state 'roster.json'
    $marksPath = Join-Path $state 'drift-marks.json'
    $dir = Join-Path $state 'roster-proposals'
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $latest = Read-RouterJsonObject -Path (Join-Path $dir 'latest.json')
    if ($Show) {
        if ($latest -and $latest.PSObject.Properties['report'] -and (Test-Path -LiteralPath ([string]$latest.report))) { Get-Content -LiteralPath ([string]$latest.report) -Raw | Write-Output }
        else { 'No roster proposal.' | Write-Output }
        $current = Read-RouterRoster
        "Current roster ($($current.source)):" | Write-Output
        @(Get-RouterJobs | ForEach-Object { [pscustomobject]@{ job=$_; first=$current.roster.jobs.$_.first; backup=$current.roster.jobs.$_.backup } }) | Format-Table -AutoSize | Out-String | Write-Output
    } elseif ($Seed) {
        $proposal = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 30
        $proposal.generated_at = (Get-Date).ToUniversalTime().ToString('o')
        $stem = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHHmmss') + '-seed'
        $path = Join-Path $dir ($stem + '.json'); $report = Join-Path $dir ($stem + '.md')
        Write-RouterApprovalJson $path $proposal
        $lines = @('# Model list proposal','','| Job | Current | Proposed | Evidence summary | Backup |','| --- | --- | --- | --- | --- |')
        foreach ($name in @(Get-RouterJobs)) { $lines += "| $name | $($proposal.jobs.$name.first) | $($proposal.jobs.$name.first) | Seeded from v1 picks | $($proposal.jobs.$name.backup) |" }
        [IO.File]::WriteAllText($report,(($lines -join "`n") + "`n"),[Text.UTF8Encoding]::new($false))
        Write-RouterApprovalJson (Join-Path $dir 'latest.json') ([pscustomobject]@{proposal=$path;report=$report})
        "Seed proposal: $path" | Write-Output
    } elseif ($Approve) {
        if (-not $latest -or -not $latest.PSObject.Properties['proposal'] -or -not (Test-Path -LiteralPath ([string]$latest.proposal))) { throw 'No roster proposal to approve.' }
        $proposal = Get-Content -LiteralPath ([string]$latest.proposal) -Raw | ConvertFrom-Json -Depth 40
        $proposal.approved = $true; $proposal.approved_at = (Get-Date).ToUniversalTime().ToString('o')
        $errors = @(Test-RouterRoster -Roster $proposal)
        if ($errors.Count) { throw "Invalid roster proposal: $($errors -join '; ')" }
        $before = (Read-RouterRoster).roster
        Write-RouterApprovalJson $rosterPath $proposal
        $changed = @(Get-RouterJobs | Where-Object { $before.jobs.$_.first -ne $proposal.jobs.$_.first })
        if ($changed.Count) { Write-RouterApprovalJson $marksPath @((Read-RouterJsonArray -Path $marksPath) | Where-Object { $_.job -notin $changed }) }
        'Roster approved.' | Write-Output
    } elseif ($Revoke) {
        if (-not (Test-Path -LiteralPath $rosterPath)) { throw 'No roster to revoke.' }
        $current = Get-Content -LiteralPath $rosterPath -Raw | ConvertFrom-Json -Depth 40
        $current.approved = $false
        Write-RouterApprovalJson $rosterPath $current
        'Roster revoked.' | Write-Output
    } else {
        Write-RouterApprovalJson $marksPath @((Read-RouterJsonArray -Path $marksPath) | Where-Object { $_.job -ne $Job })
        "Drift declined for $Job." | Write-Output
    }
    return
}

if (([int][bool]$Show + [int][bool]$Approve + [int][bool]$Revoke) -ne 1) { throw 'Choose exactly one of -Show, -Approve, or -Revoke.' }
$path = if ($TablePath) { $TablePath } else { Join-Path (Get-RouterStateDir) 'router-table.json' }
if (-not (Test-Path -LiteralPath $path)) { throw "Router table not found: $path" }
$table = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 40
# Tables written before the approval step lack these fields; treat them as not approved.
foreach ($field in @('evidence_routing_approved','approved_picks')) {
    if (-not $table.PSObject.Properties[$field]) { $table | Add-Member -NotePropertyName $field -NotePropertyValue $(if ($field -eq 'approved_picks') { ,([object[]]@()) } else { $false }) }
}
$errors = @(Test-RouterTable -Table $table)
if ($errors.Count) { throw "Invalid router table: $($errors -join '; ')" }

if ($Show -or $Approve) {
    $bridgeMap = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/bridge-map.json') -Raw | ConvertFrom-Json
    $current = @(Get-RouterPicksSnapshot -TablePath $path)
    $rows = foreach ($pick in $current) {
        $old = @($table.approved_picks | Where-Object { $_.category -eq $pick.category -and $_.lane -eq $pick.lane -and [bool]$_.protected -eq [bool]$pick.protected } | Select-Object -First 1)
        $bridge = if ($pick.protected -and $pick.category -ne 'image-generation') { $bridgeMap.lanes.($pick.lane).protected } else { $bridgeMap.lanes.($pick.lane).categories.($pick.category) }
        [pscustomobject]@{ category = $pick.category; lane = $pick.lane; protected = $pick.protected; bridge_pick = $bridge; old_approved_pick = $(if ($old.Count) { $old[0].model } else { '' }); evidence_pick = $pick.model; reason = $pick.reason }
    }
    $rows | Format-Table -AutoSize | Out-String -Width 240 | Write-Output
}
if ($Approve) {
    if ($table.source -ne 'research' -or $table.coverage -ne 'full') { throw 'Only a full research table can be approved.' }
    $table.approved_picks = @($current)
    $table.evidence_routing_approved = $true
} elseif ($Revoke) { $table.evidence_routing_approved = $false }
if ($Approve -or $Revoke) {
    $json = ConvertTo-Json -InputObject $table -Depth 40
    $temp = Join-Path (Split-Path -Parent $path) ('.router-approval.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try { [IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($false)); [IO.File]::Move($temp,$path,$true) }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}
