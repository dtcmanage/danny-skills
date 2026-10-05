Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../resolve-model.ps1')
. (Join-Path $PSScriptRoot '../build-roster.ps1')
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
. (Join-Path $PSScriptRoot 'fixtures/bench-proposal-evidence.ps1')
$fixture = Enter-RouterTestCodexHome
$prior = $env:DT_MODEL_ROUTER_STATE
$priorShared = $env:DT_MODEL_ROUTER_SHARED
$env:DT_MODEL_ROUTER_SHARED = Join-Path $fixture.root 'shared'
$env:DT_MODEL_ROUTER_STATE = Join-Path $fixture.root 'difficulty-state'
[void][IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_STATE)
$script:checks = 0
function Check([bool]$Ok, [string]$Label) { if (-not $Ok) { throw "FAIL: $Label" }; $script:checks++ }
function Refused([scriptblock]$Action, [string]$Pattern) {
    $errorText = ''; try { & $Action | Out-Null } catch { $errorText = $_.Exception.Message }
    Check ($errorText -match $Pattern) "refused: $Pattern"
}
function Get-RouterVendorBlocked { param($Vendor, $UsageReadings) return $false }
function Get-RouterCachedWeeklyUsage { param($Vendor) return [pscustomobject]@{used_percent=$(if ($Vendor -eq 'codex') {70} else {20});observed_at_utc=[datetimeoffset]::UtcNow.ToString('o')} }
function Invoke-RestMethod { throw 'UNEXPECTED NETWORK' }
function Invoke-WebRequest { throw 'UNEXPECTED NETWORK' }
function Save-Roster { Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json') $script:roster }
try {
    $catalog = Get-CodexModelCatalog
    $script:roster = (Read-RouterRoster).roster
    $roster.approved = $true; $roster.approved_at = [datetimeoffset]::UtcNow.ToString('o')
    Save-Roster
    foreach ($job in @('coder','deep-thinker')) {
        foreach ($slot in @('first','backup')) {
            $bad = $roster | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
            $bad.jobs.$job.PSObject.Properties.Remove("${slot}_effort")
            Check (@(Test-RouterRoster $bad) -contains "ROSTER_EFFORT: $job/$slot") 'tier objects cannot replace required scalar'
            $bad = $roster | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
            $bad.jobs.$job.("${slot}_effort") = 'low'
            Check (@(Test-RouterRoster $bad) -contains "ROSTER_EFFORT_MISMATCH: $job/$slot") 'standard and scalar mismatch rejected'
        }
    }
    $normalized = Resolve-RouterModel -Category routine-coding -Difficulty HARD -DifficultyReason 'constraints' -Catalog $catalog
    Check ($normalized.difficulty -ceq 'hard' -and $normalized.effort -eq 'high') 'uppercase difficulty normalized'
    foreach ($category in @('mechanical','long-form-writing','image-generation')) {
        $pick = Resolve-RouterModel -Category $category -Catalog $catalog
        Check ($pick.PSObject.Properties['difficulty'] -and $null -eq $pick.difficulty) 'non-tiered default result carries null difficulty'
    }
    foreach ($category in @('routine-coding','analysis')) {
        foreach ($lane in @('codex','claude')) {
            $standard = Resolve-RouterModel -Category $category -Lane $lane -Catalog $catalog
            $hard = Resolve-RouterModel -Category $category -Lane $lane -Difficulty hard -DifficultyReason 'Interacting constraints' -Catalog $catalog
            Check ($standard.effort -eq 'medium' -and $standard.difficulty -eq 'standard' -and $hard.effort -eq 'high' -and $hard.difficulty -eq 'hard') "$category/$lane tier efforts"
        }
    }
    Refused { Resolve-RouterModel -Category analysis -Difficulty hard -Catalog $catalog } 'DIFFICULTY_REASON_REQUIRED'
    foreach ($reason in @("two`nlines", "two`rlines", ('x' * 241), '   ')) {
        Refused { Resolve-RouterModel -Category analysis -Difficulty hard -DifficultyReason $reason -Catalog $catalog } 'DIFFICULTY_REASON_REQUIRED'
    }
    Refused { Resolve-RouterModel -Category analysis -Difficulty standard -DifficultyReason 'unneeded' -Catalog $catalog } 'DIFFICULTY_REASON_REFUSED'
    foreach ($category in @('mechanical','long-form-writing','image-generation')) {
        $pick = Resolve-RouterModel -Category $category -Difficulty hard -DifficultyReason 'ignored tier' -Catalog $catalog
        Check ($null -eq $pick.difficulty -and $pick.effort -eq (Get-RouterJobEffort (Get-RouterCategoryJob $category))) "$category has no tier"
    }
    $retry = Resolve-RouterModel -Category routine-coding -RetryAtHardFrom gpt-6-luna -DifficultyReason 'Failed standard' -Catalog $catalog
    Check ($retry.model -eq 'gpt-6-luna' -and $retry.effort -eq 'high' -and $retry.difficulty -eq 'hard') 'retry same model at hard'
    $up = Resolve-RouterModel -Category routine-coding -EscalateFrom $retry.model -Difficulty hard -DifficultyReason 'Failed hard' -Catalog $catalog
    Check ($up.model -eq 'gpt-6.1-sol' -and $up.effort -eq 'high') 'escalate only after hard'
    Refused { Resolve-RouterModel -Category routine-coding -EscalateFrom gpt-6-luna -Difficulty standard -Catalog $catalog } 'ESCALATE_REQUIRES_HARD'
    Refused { Resolve-RouterModel -Category routine-coding -RetryAtHardFrom gpt-6-luna -EscalateFrom gpt-6-luna -DifficultyReason 'failed' -Catalog $catalog } 'RETRY_ESCALATION_CONFLICT'
    Refused { Resolve-RouterModel -Category routine-coding -RetryAtHardFrom gpt-6-astra -DifficultyReason 'failed' -Catalog $catalog } 'RETRY_MODEL_INVALID'
    Refused { Resolve-RouterModel -Category routine-coding -Lane claude -RetryAtHardFrom gpt-6-luna -DifficultyReason 'failed' -Catalog $catalog } 'RETRY_LANE_CONFLICT'
    $entry = $roster.jobs.coder
    Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'bench/bank-hash.json') @{task_bank_sha256='synthetic'}
    $tie = [pscustomobject]@{tier='hard';run_id='tier-run';bank_hash='synthetic';approved_at=$roster.approved_at;configurations=@{candidate=@{model=$entry.first;effort='high'};incumbent=@{model=$entry.backup;effort='high'}}}
    $entry | Add-Member -NotePropertyName tie_evidence -NotePropertyValue $tie
    Save-Roster
    Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog).model -eq $entry.first) 'hard tie ignored by standard'
    Check ((Resolve-RouterModel -Category routine-coding -Difficulty hard -DifficultyReason 'constraints' -Catalog $catalog).model -eq $entry.backup) 'hard tie used by hard'
    Check ((Resolve-RouterModel -Category routine-coding -Difficulty HARD -DifficultyReason 'constraints' -Catalog $catalog).model -eq $entry.backup) 'uppercase hard selects hard tie evidence'
    $writer = $roster.jobs.writer
    $writer | Add-Member -NotePropertyName tie_evidence -NotePropertyValue ([pscustomobject]@{tier='standard';run_id='writer-tier';bank_hash='synthetic';approved_at=$roster.approved_at;configurations=@{candidate=@{model=$writer.first;effort='medium'};incumbent=@{model=$writer.backup;effort='medium'}}})
    Save-Roster
    $writerHard = Resolve-RouterModel -Category long-form-writing -Difficulty hard -DifficultyReason 'ignored tier' -Catalog $catalog
    Check ($writerHard.reason -match 'Quota tie-break' -and $null -eq $writerHard.difficulty) 'writer treats hard as standard for tie evidence'
    $writer.PSObject.Properties.Remove('tie_evidence'); Save-Roster
    Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'drift-marks.json') @(@{job='coder';model=$entry.first})
    Check ((Resolve-RouterModel -Category routine-coding -RetryAtHardFrom $entry.first -DifficultyReason 'failed' -Catalog $catalog).model -eq $entry.first) 'unconstrained hard retry bypasses drift'
    Check ((Resolve-RouterModel -Category routine-coding -Lane codex -RetryAtHardFrom $entry.first -DifficultyReason 'failed' -Catalog $catalog).status -eq 'wait') 'constrained hard retry applies drift'
    Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'drift-marks.json') @()
    Check ((Resolve-RouterModel -Category routine-coding -RetryAtHardFrom $entry.first -DifficultyReason 'failed' -Catalog $catalog).model -eq $entry.first) 'retry bypasses quota tie'
    $entry.first_efforts.hard = 'medium'; Save-Roster
    Check ((Resolve-RouterModel -Category routine-coding -Difficulty hard -DifficultyReason 'constraints' -Catalog $catalog).alerts -contains 'roster-tie-invalid:coder') 'changed tier effort invalidates tie'
    $entry.PSObject.Properties.Remove('tie_evidence'); $entry.first_efforts.hard = 'high'
    Initialize-TestBenchEvidence
    $results = foreach ($tier in @('standard','hard')) {
        $current = Get-RouterTierEffort $entry first $tier
        Add-TestBenchEvidence ([pscustomobject]@{shadow=$false;raw_gate='pass';tier=$tier;effort_down_qualified=$true;incumbent=@{model=$entry.first;effort=$current;passed=1};effort_down=@{model=$entry.first;effort=$(if ($tier -eq 'hard') {'medium'} else {'low'})};report_paths=@{markdown='synthetic'}})
    }
    Save-Roster
    Save-RouterEffortProposal -Request ([pscustomobject]@{job='coder';candidate=$entry.backup;incumbent=$entry.first;effort='medium'}) -Bench ([pscustomobject]@{tiers=@($results)})
    foreach ($tier in @('standard','hard')) {
        $proposal = Read-RouterJsonObject (Join-Path $env:DT_MODEL_ROUTER_STATE "effort-proposals/coder-$tier.json")
        Check ($proposal.tier -eq $tier -and $proposal.status -eq 'pending') "$tier effort proposal filed separately"
    }
    Check ((Resolve-RouterModel -Category routine-coding -Difficulty hard -DifficultyReason 'constraints' -Catalog $catalog).effort -eq 'high') 'pending proposals do not change routing'
    $approvalOutput = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '../approve-roster.ps1') -ApproveEffort -Job coder -Difficulty hard 2>&1 | Out-String
    Check ($LASTEXITCODE -eq 0) "hard effort approval: $approvalOutput"
    $approved = (Read-RouterRoster).roster.jobs.coder
    Check ($approved.first_efforts.standard -eq 'medium' -and $approved.first_efforts.hard -eq 'medium') 'approval changes only the named tier'
    $published = Read-RouterJsonObject (Join-Path $env:DT_MODEL_ROUTER_SHARED 'roster.json')
    Check ($published.jobs.coder.first_efforts.hard -eq 'medium') 'published roster retains tier fields'
    $proposal = Read-RouterJsonObject (Join-Path $env:DT_MODEL_ROUTER_STATE 'effort-proposals/coder-hard.json')
    Check ($proposal.status -eq 'approved') 'tier approval recorded'
    & (Join-Path $PSScriptRoot '../approve-roster.ps1') -ApproveEffort -Job coder -Difficulty standard | Out-Null
    $standardApproved = (Read-RouterRoster).roster.jobs.coder
    Check ($standardApproved.first_effort -eq 'low' -and $standardApproved.first_efforts.standard -eq 'low') 'standard effort approval updates scalar and tier together'
    & (Join-Path $PSScriptRoot '../approve-roster.ps1') -RevokeEffort -Job coder -Difficulty standard | Out-Null
    $standardRevoked = (Read-RouterRoster).roster.jobs.coder
    Check ($standardRevoked.first_effort -eq 'medium' -and $standardRevoked.first_efforts.standard -eq 'medium') 'standard effort revocation updates scalar and tier together'
    Save-Roster
    Write-RouterJsonAtomic (Join-Path $env:DT_MODEL_ROUTER_STATE 'tie-proposals/coder-hard.json') ([pscustomobject]@{type='tie';job='coder';tier='hard';configurations=$tie.configurations;run_id='tier-run';bank_hash=$tie.bank_hash;status='pending'})
    $display = & (Join-Path $PSScriptRoot '../approve-roster.ps1') -Show | Out-String
    Check ($display -match 'Tie proposal coder, tier hard:' -and $display -match 'tier-run' -and $display -match 'gpt-6.1-sol' -and $display -match 'claude-opus-5-5') 'Show lists pending tie with both configurations and run'
    Check ($display -match 'first_standard' -and $display -match 'first_hard') 'Show displays both roster efforts'
    Check ($display -match 'first_effort' -and $display -match 'backup_effort') 'Show retains scalar columns beside tiers'
    $seedOutput = & (Join-Path $PSScriptRoot '../approve-roster.ps1') -Seed | Out-String
    $latest = Read-RouterJsonObject (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster-proposals/latest.json')
    $seedReport = Get-Content -LiteralPath $latest.report -Raw
    Check ($seedReport -match 'deep-thinker.*standard medium, hard high' -and $seedReport -match 'coder.*standard medium, hard high') 'seed report prints standard and hard efforts'
    $savedRoster = $roster | ConvertTo-Json -Depth 30
    foreach ($job in @('coder','deep-thinker')) {
        foreach ($slot in @('first','backup')) { $roster.jobs.$job.PSObject.Properties.Remove("${slot}_efforts"); $roster.jobs.$job.("${slot}_effort") = 'low' }
    }
    Save-Roster
    $display = & (Join-Path $PSScriptRoot '../approve-roster.ps1') -Show | Out-String
    Check ($display -match 'tiers not set') 'Show marks legacy tiered jobs'
    foreach ($job in @('coder','deep-thinker')) {
        $beforeMigration = (Read-RouterRoster).roster
        $others = ($beforeMigration.jobs.PSObject.Properties | Where-Object Name -ne $job | ForEach-Object Value) | ConvertTo-Json -Depth 30 -Compress
        & (Join-Path $PSScriptRoot '../approve-roster.ps1') -ApproveTiers -Job $job | Out-Null
        $migrated = (Read-RouterRoster).roster
        Check ($migrated.jobs.$job.first_effort -eq 'medium' -and $migrated.jobs.$job.backup_effort -eq 'medium' -and $migrated.jobs.$job.first_efforts.hard -eq 'high' -and $migrated.jobs.$job.backup_efforts.hard -eq 'high') 'migration writes default tiers and matching scalars'
        $afterOthers = ($migrated.jobs.PSObject.Properties | Where-Object Name -ne $job | ForEach-Object Value) | ConvertTo-Json -Depth 30 -Compress
        Check ($others -ceq $afterOthers) 'migration leaves every other job unchanged'
        & (Join-Path $PSScriptRoot '../approve-roster.ps1') -RevokeTiers -Job $job | Out-Null
        $revoked = (Read-RouterRoster).roster.jobs.$job
        Check ($revoked.first_effort -eq 'low' -and $revoked.backup_effort -eq 'low' -and -not $revoked.PSObject.Properties['first_efforts'] -and -not $revoked.PSObject.Properties['backup_efforts']) 'revocation restores recorded scalars and removes tiers'
    }
    $roster.jobs.coder.first = 'gpt-6-luna'; Save-Roster
    Refused { & (Join-Path $PSScriptRoot '../approve-roster.ps1') -ApproveTiers -Job coder } 'models must match'
    $roster.jobs.coder.first = 'gpt-6.1-sol'; $roster.jobs.coder.backup = 'claude-haiku-4-5-20251001'; Save-Roster
    Refused { & (Join-Path $PSScriptRoot '../approve-roster.ps1') -ApproveTiers -Job coder } 'models must match'
    $roster.jobs.coder.backup = 'claude-opus-5-5'; $roster.jobs.coder.first_effort = 'medium'; Save-Roster
    # Legacy roster (no tier objects): a hard-tier effort swap must be neither filed nor approvable.
    $roster = (Read-RouterRoster).roster
    foreach ($slot in @('first','backup')) { $roster.jobs.'deep-thinker'.("${slot}_effort") = 'high' }
    $roster.jobs.'deep-thinker' | Add-Member -NotePropertyName tie_evidence -NotePropertyValue ([pscustomobject]@{tier='standard';configurations=@(@{model=$roster.jobs.'deep-thinker'.first;effort='high'},@{model=$roster.jobs.'deep-thinker'.backup;effort='high'});run_id='synthetic';bank_hash='synthetic';approved_at=[datetimeoffset]::UtcNow.ToString('o')}) -Force
    Save-Roster
    $hardSwapPath = Join-Path $env:DT_MODEL_ROUTER_STATE 'effort-proposals/deep-thinker-hard.json'
    Save-RouterEffortProposal ([pscustomobject]@{job='deep-thinker';incumbent=$roster.jobs.'deep-thinker'.first;effort='high'}) (Add-TestBenchEvidence ([pscustomobject]@{tier='hard';shadow=$false;raw_gate='pass';effort_down_qualified=$true;incumbent=@{passed=1};effort_down=@{model=$roster.jobs.'deep-thinker'.first;effort='medium'};report_paths=@{markdown='fixture'}}))
    Check (-not (Test-Path -LiteralPath $hardSwapPath)) 'no hard-tier effort proposal is filed while tiers are not set'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $hardSwapPath))
    Write-RouterJsonAtomic $hardSwapPath ([pscustomobject]@{type='effort-swap';job='deep-thinker';tier='hard';model=$roster.jobs.'deep-thinker'.first;current_effort='high';proposed_effort='medium';status='pending'})
    Refused { & (Join-Path $PSScriptRoot '../approve-roster.ps1') -ApproveEffort -Job deep-thinker -Difficulty hard } 'EFFORT_TIERS_NOT_SET'
    Check ((Read-RouterRoster).roster.jobs.'deep-thinker'.first_effort -eq 'high') 'refused hard-tier approval leaves standard routing unchanged'
    Remove-Item -LiteralPath $hardSwapPath -Force
    $tierOutput = & (Join-Path $PSScriptRoot '../approve-roster.ps1') -ApproveTiers -Job deep-thinker | Out-String
    Check ($tierOutput -match 'Tie approval dropped' -and -not (Read-RouterRoster).roster.jobs.'deep-thinker'.PSObject.Properties['tie_evidence']) 'tier approval drops tie evidence recorded at other efforts'
    & (Join-Path $PSScriptRoot '../approve-roster.ps1') -RevokeTiers -Job deep-thinker | Out-Null
    $roster = (Read-RouterRoster).roster
    $legacySwapPath = Join-Path $env:DT_MODEL_ROUTER_STATE 'effort-proposals/coder-standard.json'
    $legacySwap = Read-RouterJsonObject $legacySwapPath
    $legacySwap.status = 'pending'; Write-RouterJsonAtomic $legacySwapPath $legacySwap
    & (Join-Path $PSScriptRoot '../approve-roster.ps1') -ApproveEffort -Job coder | Out-Null
    $legacyEffort = (Read-RouterRoster).roster.jobs.coder
    Check ($legacyEffort.first_effort -eq 'low' -and -not $legacyEffort.PSObject.Properties['first_efforts']) 'legacy effort approval preserves scalar-only roster'
    $roster = $savedRoster | ConvertFrom-Json -Depth 30; Save-Roster
    . (Join-Path $PSScriptRoot '../update-outcomes.ps1')
    $project = Join-Path $fixture.root 'Synthetic Workstation/synthetic-repo'
    $runFolder = Join-Path $project '.dt-build/tier-fixture/milestones/M04'
    [void][IO.Directory]::CreateDirectory($runFolder)
    $provenance = Join-Path $runFolder 'builder.provenance.json'
    Write-RouterJsonAtomic $provenance @{resolved_model='gpt-6.1-sol';category='routine-coding';tier='standard';difficulty='hard';difficulty_reason='constraints';pass=$true;attempt=1;workstation='Synthetic Workstation';dispatched_at_utc=[datetimeoffset]::UtcNow.ToString('o')}
    $sources = Join-Path $fixture.root 'synthetic-sources.json'
    Write-RouterJsonAtomic $sources @($project)
    Update-RouterOutcomes -SourcesPath $sources | Out-Null
    $indexed = @(Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.PSObject.Properties['provenance_path'] })
    Check ($indexed.Count -eq 1 -and $indexed[0].provenance_path -eq $provenance -and $indexed[0].workstation -eq 'Synthetic Workstation') 'outcome collector indexes provenance for workstation cost split'
    foreach ($job in @('coder','deep-thinker')) {
        foreach ($slot in @('first','backup')) { $roster.jobs.$job.PSObject.Properties.Remove("${slot}_efforts") }
    }
    Save-Roster
    Check (@(Test-RouterRoster $roster).Count -eq 0) 'old approved roster validates'
    $old = Resolve-RouterModel -Category analysis -Catalog $catalog
    Check ($old.effort -eq 'medium' -and $old.difficulty -eq 'standard' -and $old.roster_source -eq 'state') 'legacy default output shape and effort retained'
    # Fixed values captured from resolver 5b2e633, including difficulty.
    $baseline = Get-Content (Join-Path $PSScriptRoot 'fixtures/difficulty-router-baseline.json') -Raw | ConvertFrom-Json
    foreach ($row in $baseline) {
        $currentPick = Resolve-RouterModel -Category $row.category -Lane $row.lane -Catalog $catalog
        $currentJson = $currentPick | ConvertTo-Json -Depth 20 -Compress
        $expectedJson = $row.result | ConvertTo-Json -Depth 20 -Compress
        Check ($currentJson -ceq $expectedJson) "unchanged baseline JSON including difficulty: $($row.category)/$($row.lane)"
    }
    $hard = Resolve-RouterModel -Category analysis -Difficulty hard -DifficultyReason 'constraints' -Catalog $catalog
    Check ($hard.effort -eq $old.effort -and $hard.difficulty -eq 'hard') 'legacy single effort used by both tiers'
    foreach ($job in @(Get-RouterJobs)) {
        foreach ($slot in @('first','backup')) { if ($roster.jobs.$job.$slot -eq 'gpt-6.1-sol') { $roster.jobs.$job.$slot = 'gpt-5.6-sol' } }
    }
    Save-Roster
    $legacyRetry = Resolve-RouterModel -Category routine-coding -RetryAtHardFrom gpt-5.6-sol -DifficultyReason 'Failed standard' -Catalog $catalog
    Check ($legacyRetry.model -eq 'gpt-5.6-sol' -and $legacyRetry.effort -eq 'medium') 'hard retry retains an approved older model outside the current ladder'
    $roster.jobs.coder | Add-Member -NotePropertyName first_efforts -NotePropertyValue ([pscustomobject]@{standard='medium'})
    Check (@(Test-RouterRoster $roster) -contains 'ROSTER_TIER_EFFORT: coder/first/hard') 'incomplete tier object refused'
    "SUMMARY: $script:checks passed"
} finally { $env:DT_MODEL_ROUTER_STATE = $prior; $env:DT_MODEL_ROUTER_SHARED = $priorShared; Exit-RouterTestCodexHome $fixture }
