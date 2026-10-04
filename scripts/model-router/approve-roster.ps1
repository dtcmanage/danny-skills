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
    [switch]$ApproveEffort,
    [switch]$DeclineEffort,
    [switch]$RevokeEffort,
    [switch]$ApproveTie,
    [switch]$DeclineTie,
    [switch]$RevokeTie,
    [switch]$ApproveTiers,
    [switch]$RevokeTiers,
    [ValidateSet('standard','hard')][string]$Difficulty = 'standard',
    [string]$Job,
    [string[]]$Jobs
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'resolve-model.ps1')
. (Join-Path $PSScriptRoot 'publish-roster.ps1')
if ($Seed -or $Approve -or $Revoke -or $DeclineDrift -or $ApproveEffort -or $DeclineEffort -or $RevokeEffort -or $ApproveTie -or $DeclineTie -or $RevokeTie -or $ApproveTiers -or $RevokeTiers) { Assert-RouterWindowsOwner -Action 'Roster mutation' }
if ($Jobs) { $Jobs = @($Jobs | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

function Write-RouterApprovalJson {
    param([string]$Path, [object]$Value)
    $temp = Join-Path (Split-Path -Parent $Path) ('.router-approval.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try { [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $Value -Depth 40),[Text.UTF8Encoding]::new($false)); [IO.File]::Move($temp,$Path,$true) }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Get-RouterRosterProposalEvidenceErrors {
    param([object]$Proposal, [string[]]$SelectedJobs, [string]$ProposalPath)
    if (-not $Proposal.PSObject.Properties['changes']) {
        if ($ProposalPath -like '*-drift.json') { 'Legacy drift benchmark evidence; rerun the comparison.' }
        return
    }
    foreach ($change in @($Proposal.changes)) {
        if ($SelectedJobs -and $change.job -notin $SelectedJobs) { continue }
        # Research proposals carry pass_id; seed and non-bench bootstrap proposals do not.
        if ($change.PSObject.Properties['bench_evidence'] -or $Proposal.PSObject.Properties['pass_id'] -or $change.evidence -match '; Bench ') {
            $basis = if ($change.PSObject.Properties['bench_evidence']) { $change.bench_evidence } else { $null }
            $reason = Get-RouterBenchProposalEvidenceError -Job $change.job -Evidence $basis
            if ($reason) { "$($change.job)/$($change.slot): $reason" }
        }
    }
}

if (([int][bool]$Show + [int][bool]$Approve + [int][bool]$Revoke + [int][bool]$Seed + [int][bool]$DeclineDrift + [int][bool]$ApproveEffort + [int][bool]$DeclineEffort + [int][bool]$RevokeEffort + [int][bool]$ApproveTie + [int][bool]$DeclineTie + [int][bool]$RevokeTie + [int][bool]$ApproveTiers + [int][bool]$RevokeTiers) -ne 1) { throw 'Choose exactly one roster action.' }
$tierAction = $ApproveTiers -or $RevokeTiers
if ($tierAction -and $Job -notin @('deep-thinker','coder')) { throw '-ApproveTiers and -RevokeTiers require -Job deep-thinker or coder.' }
$tieAction = $ApproveTie -or $DeclineTie -or $RevokeTie
$effortAction = $ApproveEffort -or $DeclineEffort -or $RevokeEffort
if (($DeclineDrift -or $effortAction -or $tieAction) -and $Job -notin @(Get-RouterJobs)) { throw "Unknown roster job: $Job" }
if ($Job -and -not ($DeclineDrift -or $effortAction -or $tieAction -or $tierAction)) { throw '-Job requires a job-specific action.' }
if ($Jobs -and -not $Approve) { throw '-Jobs requires -Approve.' }
$approvalAction = {
$state = if ($Show) { Get-RouterStatePath } else { Get-RouterStateDir }
$rosterPath = Join-Path $state 'roster.json'
$marksPath = Join-Path $state 'drift-marks.json'
$declinesPath = Join-Path $state 'drift-declines.json'
$dir = Join-Path $state 'roster-proposals'
if (-not $Show) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
$latest = Read-RouterJsonObject -Path (Join-Path $dir 'latest.json')
if ($Show) {
    if ($latest -and $latest.PSObject.Properties['report'] -and (Test-Path -LiteralPath ([string]$latest.report))) { Get-Content -LiteralPath ([string]$latest.report) -Raw | Write-Output }
    else { 'No roster proposal.' | Write-Output }
    if ($latest -and $latest.PSObject.Properties['proposal']) {
        $proposal = Read-RouterJsonObject ([string]$latest.proposal)
        if ($proposal) {
            foreach ($reason in @(Get-RouterRosterProposalEvidenceErrors -Proposal $proposal -ProposalPath $latest.proposal)) { "Stale roster proposal; approval unavailable: $reason" | Write-Output }
            if ($proposal.PSObject.Properties['changes']) { foreach ($change in $proposal.changes) { if ($change.PSObject.Properties['bench_evidence']) { "Benchmark basis $($change.job)/$($change.slot): $(ConvertTo-Json $change.bench_evidence -Compress -Depth 10)" | Write-Output } } }
        }
    }
    $current = Read-RouterRoster
    "Current roster ($($current.source)):" | Write-Output
    @(Get-RouterJobs | ForEach-Object { [pscustomobject]@{ job=$_; first_effort=$current.roster.jobs.$_.first_effort; backup_effort=$current.roster.jobs.$_.backup_effort; tiers=$(if ($_ -in @('coder','deep-thinker') -and -not $current.roster.jobs.$_.PSObject.Properties['first_efforts'] -and -not $current.roster.jobs.$_.PSObject.Properties['backup_efforts']) { 'tiers not set' } else { $null }); first=$current.roster.jobs.$_.first; first_standard=(Get-RouterTierEffort $current.roster.jobs.$_ first standard); first_hard=$(if ($_ -in @('coder','deep-thinker')) { Get-RouterTierEffort $current.roster.jobs.$_ first hard } else { $null }); backup=$current.roster.jobs.$_.backup; backup_standard=(Get-RouterTierEffort $current.roster.jobs.$_ backup standard); backup_hard=$(if ($_ -in @('coder','deep-thinker')) { Get-RouterTierEffort $current.roster.jobs.$_ backup hard } else { $null }) } }) | Format-Table -AutoSize | Out-String -Width 400 | Write-Output
    $tieDir = Join-Path $state 'tie-proposals'
    if (Test-Path -LiteralPath $tieDir) {
        foreach ($file in @(Get-ChildItem -LiteralPath $tieDir -Filter '*.json')) {
            $tie = Read-RouterJsonObject $file.FullName
            if ($tie -and $tie.status -eq 'pending') { "Tie proposal $($tie.job), tier $($tie.tier): $(ConvertTo-Json $tie.configurations -Compress -Depth 5); run $($tie.run_id); pending" | Write-Output }
        }
    }
    $effortDir = Join-Path $state 'effort-proposals'
    if (Test-Path -LiteralPath $effortDir) {
        foreach ($file in @(Get-ChildItem -LiteralPath $effortDir -Filter '*.json')) {
            $swap = Read-RouterJsonObject $file.FullName
            "Effort proposal $($swap.job), tier $(if ($swap.PSObject.Properties['tier']) { $swap.tier } else { 'standard' }): $($swap.model), $($swap.current_effort) -> $($swap.proposed_effort), $($swap.status); report $($swap.report)" | Write-Output
            $basis = if ($swap.PSObject.Properties['bench_evidence']) { $swap.bench_evidence } else { $null }
            "Benchmark basis: $(ConvertTo-Json $basis -Compress -Depth 10)" | Write-Output
            if ($swap.status -eq 'pending') { $reason = Get-RouterBenchProposalEvidenceError -Job $swap.job -Evidence $basis; if ($reason) { "Stale effort proposal; approval unavailable: $reason" | Write-Output } }
        }
    }
} elseif ($Seed) {
    $proposal = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 30
    foreach ($name in @(Get-RouterJobs)) {
        foreach ($slot in @('first','backup')) {
            $proposal.jobs.$name | Add-Member -NotePropertyName "${slot}_effort" -NotePropertyValue (Get-RouterTierEffort $proposal.jobs.$name $slot standard) -Force
        }
    }
    $proposal.generated_at = (Get-Date).ToUniversalTime().ToString('o')
    $stem = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHHmmss') + '-seed'
    $path = Join-Path $dir ($stem + '.json'); $report = Join-Path $dir ($stem + '.md')
    Write-RouterApprovalJson $path $proposal
    $lines = @('# Model list proposal','','| Job | Current | Proposed | Evidence summary | Backup |','| --- | --- | --- | --- | --- |')
    foreach ($name in @(Get-RouterJobs)) { $lines += "| $name | $($proposal.jobs.$name.first) (effort $($proposal.jobs.$name.first_effort)$(if ($name -in @('coder','deep-thinker')) { "; standard $(Get-RouterTierEffort $proposal.jobs.$name first standard), hard $(Get-RouterTierEffort $proposal.jobs.$name first hard)" })) | $($proposal.jobs.$name.first) (effort $($proposal.jobs.$name.first_effort)$(if ($name -in @('coder','deep-thinker')) { "; standard $(Get-RouterTierEffort $proposal.jobs.$name first standard), hard $(Get-RouterTierEffort $proposal.jobs.$name first hard)" })) | Seeded from default roster | $($proposal.jobs.$name.backup) (effort $($proposal.jobs.$name.backup_effort)$(if ($name -in @('coder','deep-thinker')) { "; standard $(Get-RouterTierEffort $proposal.jobs.$name backup standard), hard $(Get-RouterTierEffort $proposal.jobs.$name backup hard)" })) |" }
    [IO.File]::WriteAllText($report,(($lines -join "`n") + "`n"),[Text.UTF8Encoding]::new($false))
    Write-RouterApprovalJson (Join-Path $dir 'latest.json') ([pscustomobject]@{proposal=$path;report=$report})
    "Seed proposal: $path" | Write-Output
} elseif ($tierAction) {
    $read = Read-RouterRoster
    if ($read.source -ne 'state') { throw 'Tier migration requires an approved roster.' }
    $current = $read.roster
    $entry = $current.jobs.$Job
    if ($ApproveTiers) {
        if ($entry.PSObject.Properties['first_efforts'] -or $entry.PSObject.Properties['backup_efforts']) { throw 'Tiers are already set; revoke them before approving again.' }
        $defaults = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 30
        if ($entry.first -cne $defaults.jobs.$Job.first -or $entry.backup -cne $defaults.jobs.$Job.backup) { throw 'Tier approval refused: first and backup models must match the default roster.' }
        $entry | Add-Member -NotePropertyName pre_tier_efforts -NotePropertyValue ([pscustomobject]@{first=$entry.first_effort;backup=$entry.backup_effort})
        foreach ($slot in @('first','backup')) {
            $entry | Add-Member -NotePropertyName "${slot}_efforts" -NotePropertyValue ($defaults.jobs.$Job.("${slot}_efforts") | ConvertTo-Json | ConvertFrom-Json)
            $entry.("${slot}_effort") = $entry.("${slot}_efforts").standard
        }
    } else {
        if (-not $entry.PSObject.Properties['pre_tier_efforts']) { throw 'No recorded tier approval to revoke.' }
        foreach ($slot in @('first','backup')) {
            $entry.PSObject.Properties.Remove("${slot}_efforts")
            $entry.("${slot}_effort") = $entry.pre_tier_efforts.$slot
        }
        $entry.PSObject.Properties.Remove('pre_tier_efforts')
    }
    # A tie is approved for exact efforts; when they change it must be re-confirmed, as -Approve already requires.
    $tieDropped = $false
    if ($entry.PSObject.Properties['tie_evidence'] -and (Get-RouterTieEvidenceError -Entry $entry -Evidence $entry.tie_evidence)) { $entry.PSObject.Properties.Remove('tie_evidence'); $tieDropped = $true }
    $errors = @(Test-RouterRoster $current)
    if ($errors.Count) { throw "Invalid tier roster: $($errors -join '; ')" }
    Write-RouterApprovalJson $rosterPath $current
    Publish-RouterRoster
    "Tiers $(if ($ApproveTiers) { 'approved' } else { 'revoked' }) for $Job.$(if ($tieDropped) { ' Tie approval dropped: its efforts no longer match; a new tied run must confirm it.' })" | Write-Output
} elseif ($tieAction) {
    $path = Join-Path $state ('tie-proposals/' + $Job + $(if ($Difficulty -eq 'hard') { '-hard' } else { '' }) + '.json')
    $current = (Read-RouterRoster).roster
    $entry = $current.jobs.$Job
    $replacedTier = if ($ApproveTie -and $entry.PSObject.Properties['tie_evidence'] -and $entry.tie_evidence.tier -cne $Difficulty) { [string]$entry.tie_evidence.tier } else { $null }
    if ($RevokeTie) {
        if (-not $entry.PSObject.Properties['tie_evidence']) { throw 'No approved tie to revoke.' }
        if ($entry.tie_evidence.tier -cne $Difficulty) { throw 'TIE_TIER_MISMATCH' }
        $entry.PSObject.Properties.Remove('tie_evidence')
        Write-RouterApprovalJson $rosterPath $current
        Publish-RouterRoster
        $proposal = Read-RouterJsonObject $path
        if ($proposal) { $proposal.status = 'revoked'; Write-RouterApprovalJson $path $proposal }
    } else {
        $proposal = Read-RouterJsonObject $path
        if (-not $proposal -or $proposal.type -cne 'tie' -or $proposal.job -cne $Job -or $proposal.status -cne 'pending') { throw 'No pending tie proposal for this job.' }
        if ($ApproveTie) {
            $reason = Get-RouterTieEvidenceError -Entry $entry -Evidence $proposal -CurrentBank
            if ($reason) { throw "TIE_STALE_EVIDENCE: $reason" }
            $evidence = [pscustomobject]@{tier=$proposal.tier;configurations=$proposal.configurations;run_id=$proposal.run_id;bank_hash=$proposal.bank_hash;approved_at=[datetimeoffset]::UtcNow.ToString('o')}
            $entry | Add-Member -NotePropertyName tie_evidence -NotePropertyValue $evidence -Force
            Write-RouterApprovalJson $rosterPath $current
            Publish-RouterRoster
            $proposal.status = 'approved'
        } else { $proposal.status = 'declined' }
        Write-RouterApprovalJson $path $proposal
    }
    "Tie action recorded for $Job.$(if ($replacedTier) { " It replaced the approved $replacedTier-tier tie; one tie per job is kept." })" | Write-Output
} elseif ($effortAction) {
    $path = Join-Path $state ('effort-proposals/' + $Job + $(if ($Job -in @('coder','deep-thinker')) { '-' + $Difficulty } else { '' }) + '.json')
    if (-not (Test-Path -LiteralPath $path) -and $Difficulty -eq 'standard') { $path = Join-Path $state ('effort-proposals/' + $Job + '.json') }
    $swap = Read-RouterJsonObject $path
    if (-not $swap -or $swap.type -ne 'effort-swap' -or $swap.job -cne $Job) { throw 'No effort proposal for this job.' }
    $current = (Read-RouterRoster).roster
    $entry = $current.jobs.$Job
    if ($ApproveEffort -and $Difficulty -eq 'hard' -and $Job -in @('coder','deep-thinker') -and -not $entry.PSObject.Properties['first_efforts']) { throw "EFFORT_TIERS_NOT_SET: approve tiers for $Job first (-ApproveTiers -Job $Job); without them this change would also lower standard work." }
    $expected = if ($RevokeEffort) { $swap.proposed_effort } else { $swap.current_effort }
    if ($entry.first -cne $swap.model -or (Get-RouterTierEffort $entry first $Difficulty) -cne $expected) { throw 'EFFORT_STALE_ROSTER: model or current effort changed.' }
    if ($RevokeEffort -and $swap.status -ne 'approved') { throw 'No approved effort swap to revoke.' }
    if (-not $RevokeEffort -and $swap.status -ne 'pending') { throw 'Effort proposal is not pending.' }
    $next = if ($Job -eq 'writer') { @{low='medium';medium='high';high='xhigh'}[[string]$swap.current_effort] } else { @{medium='low';high='medium'}[[string]$swap.current_effort] }
    # Declining or revoking must stay possible for a proposal filed under an older direction rule.
    if ($ApproveEffort -and (-not $next -or $next -cne $swap.proposed_effort)) { throw 'Invalid effort step.' }
    if ($ApproveEffort) {
        $basis = if ($swap.PSObject.Properties['bench_evidence']) { $swap.bench_evidence } else { $null }
        $reason = Get-RouterBenchProposalEvidenceError -Job $Job -Evidence $basis
        if ($reason) { throw "EFFORT_STALE_EVIDENCE: $reason" }
    }
    if ($DeclineEffort) { $swap.status = 'declined' }
    else {
        $value = if ($RevokeEffort) { $swap.current_effort } else { $swap.proposed_effort }
        if ($Job -in @('coder','deep-thinker') -and $swap.PSObject.Properties['tier'] -and $swap.tier -cne $Difficulty) { throw 'EFFORT_TIER_MISMATCH' }
        if ($Job -in @('coder','deep-thinker') -and $swap.PSObject.Properties['tier'] -and $entry.PSObject.Properties['first_efforts']) {
            $entry.first_efforts.$Difficulty = $value
            $entry.first_effort = $entry.first_efforts.standard
        } else {
            $entry.first_effort = $value
            if ($entry.PSObject.Properties['first_efforts']) { $entry.first_efforts.standard = $value }
        }
        $errors = @(Test-RouterRoster $current)
        if ($errors.Count) { throw "Invalid effort roster: $($errors -join '; ')" }
        Write-RouterApprovalJson $rosterPath $current
        Publish-RouterRoster
        $swap.status = if ($RevokeEffort) { 'revoked' } else { 'approved' }
    }
    Write-RouterApprovalJson $path $swap
    "Effort proposal $($swap.status) for $Job." | Write-Output
} elseif ($Approve) {
    if (-not $latest -or -not $latest.PSObject.Properties['proposal'] -or -not (Test-Path -LiteralPath ([string]$latest.proposal))) { throw 'No roster proposal to approve.' }
    $proposal = Get-Content -LiteralPath ([string]$latest.proposal) -Raw | ConvertFrom-Json -Depth 40
    $evidenceErrors = @(Get-RouterRosterProposalEvidenceErrors -Proposal $proposal -SelectedJobs $Jobs -ProposalPath $latest.proposal)
    if ($evidenceErrors.Count) { throw "ROSTER_STALE_EVIDENCE: $($evidenceErrors -join '; ')" }
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
        $old = $before.jobs.$name; $next = $proposal.jobs.$name
        $unchanged = $true
        foreach ($field in @('first','backup')) {
            if ($old.PSObject.Properties[$field] -and $next.PSObject.Properties[$field] -and $old.$field -cne $next.$field) { $unchanged = $false }
        }
        foreach ($slot in @('first','backup')) {
            $tier = if ($old.PSObject.Properties['tie_evidence']) { $old.tie_evidence.tier } else { 'standard' }
            if ((Get-RouterTierEffort $old $slot $tier) -cne (Get-RouterTierEffort $next $slot $tier)) { $unchanged = $false }
        }
        $next.PSObject.Properties.Remove('tie_evidence')
        if ($unchanged -and $old.PSObject.Properties['tie_evidence']) {
            $next | Add-Member -NotePropertyName tie_evidence -NotePropertyValue $old.tie_evidence
        }
    }
    $proposal.approved = $true; $proposal.approved_at = (Get-Date).ToUniversalTime().ToString('o')
    $errors = @(Test-RouterRoster -Roster $proposal)
    if ($errors.Count) { throw "Invalid roster proposal: $($errors -join '; ')" }
    Write-RouterApprovalJson $rosterPath $proposal
    Publish-RouterRoster
    $changed = @(Get-RouterJobs | Where-Object { $before.jobs.$_.first -ne $proposal.jobs.$_.first })
    if ($changed.Count) {
        Write-RouterApprovalJson $marksPath @((Read-RouterJsonArray -Path $marksPath) | Where-Object { $_.job -notin $changed })
        Write-RouterApprovalJson $declinesPath @((Read-RouterJsonArray -Path $declinesPath) | Where-Object { $_.job -notin $changed })
    }
    'Roster approved.' | Write-Output
} elseif ($Revoke) {
    if (-not (Test-Path -LiteralPath $rosterPath)) { throw 'No roster to revoke.' }
    $current = Get-Content -LiteralPath $rosterPath -Raw | ConvertFrom-Json -Depth 40
    $current.approved = $false
    Write-RouterApprovalJson $rosterPath $current
    Publish-RouterRoster
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
}
if ($Show) { & $approvalAction } else {
    $state = Get-RouterStateDir
    # One lock order: outcomes before roster. Publication only takes the reentrant roster lock.
    Use-RouterOutcomeMutex -StateDir $state -Action {
        Use-RouterRosterMutex -StateDir $state -Body $approvalAction
    }
}
