Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../router-common.ps1')
$script:checks = 0
function Check([bool]$Ok, [string]$Label) { if (-not $Ok) { throw "FAIL: $Label" }; $script:checks++ }
function Copy-Roster {
    return Get-Content (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 30
}
function Set-Overrides($Roster, $Value, [string]$Job = 'coder') {
    $Roster.jobs.$Job | Add-Member -NotePropertyName category_overrides -NotePropertyValue $Value -Force
}
function Expect-Error($Roster, [string]$Message) {
    Check (@(Test-RouterRoster $Roster) -ccontains $Message) $Message
}
function Check-Valid($Roster, [string]$Label) {
    $errors = @(Test-RouterRoster $Roster)
    Check ($errors.Count -eq 0) "$Label : $($errors -join '; ')"
}
function New-Exception([string]$Slot = 'first', [string]$Model = 'gpt-6.2-sol', [string]$Vendor = 'codex') {
    return [pscustomobject]@{ $Slot = [pscustomobject]@{model=$Model;vendor=$Vendor} }
}
$priorState = $env:DT_MODEL_ROUTER_STATE
$priorShared = $env:DT_MODEL_ROUTER_SHARED
$priorAlert = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
$temp = Join-Path ([IO.Path]::GetTempPath()) ('category-overrides-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$env:DT_MODEL_ROUTER_STATE = $temp
$env:DT_MODEL_ROUTER_SHARED = Join-Path $temp 'shared'
$env:DT_MODEL_ROUTER_ALERT_TRANSPORT = Join-Path $temp 'stub-transport.ps1'
[IO.File]::WriteAllText($env:DT_MODEL_ROUTER_ALERT_TRANSPORT, 'param([string]$Message)')
try {
    $r = Copy-Roster
    Check-Valid $r 'default roster validates'
    Check ($r.jobs.coder.first_vendor_pin -ceq 'codex') 'default coder is pinned'
    $livePath = Join-Path $PSScriptRoot '../../../../model-router/state/roster.json'
    $liveHash = (Get-FileHash -LiteralPath $livePath -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $livePath -Destination (Join-Path $temp 'roster.json')
    $liveCopy = Get-Content (Join-Path $temp 'roster.json') -Raw | ConvertFrom-Json -Depth 30
    Check-Valid $liveCopy 'live roster copy validates'
    Check ((Get-FileHash -LiteralPath $livePath -Algorithm SHA256).Hash -ceq $liveHash) 'live fixture unchanged'
    $r.jobs.coder.PSObject.Properties.Remove('first_vendor_pin')
    Check-Valid $r 'legacy absent pins and overrides validate'
    foreach ($job in @('coder','deep-thinker')) {
        $r = Copy-Roster; Set-Overrides $r ([pscustomobject]@{}) $job
        Check-Valid $r "$job empty map accepted"
    }
    foreach ($job in @('fast','writer','illustrator')) {
        $r = Copy-Roster; Set-Overrides $r ([pscustomobject]@{}) $job
        Expect-Error $r "ROSTER_OVERRIDE_JOB: $job"
    }
    foreach ($value in @($null, 'bad', 7, @(), @('bad'))) {
        $r = Copy-Roster; Set-Overrides $r $value
        Expect-Error $r 'ROSTER_OVERRIDE_SHAPE: coder'
    }
    foreach ($category in @('unknown','mechanical','math','long-form-writing')) {
        $r = Copy-Roster; Set-Overrides $r ([pscustomobject]@{$category=(New-Exception)})
        Expect-Error $r "ROSTER_OVERRIDE_CATEGORY: coder/$category"
    }
    $r = Copy-Roster; $r.category_jobs.mechanical = 'coder'
    Set-Overrides $r ([pscustomobject]@{mechanical=(New-Exception)})
    Expect-Error $r 'ROSTER_OVERRIDE_CATEGORY: coder/mechanical'
    foreach ($value in @($null, 'bad', 7, @(), ([pscustomobject]@{}), ([pscustomobject]@{other=(New-Exception)}))) {
        $r = Copy-Roster; Set-Overrides $r ([pscustomobject]@{'ui-frontend'=$value})
        Expect-Error $r 'ROSTER_OVERRIDE_SHAPE: coder/ui-frontend'
    }
    $badPicks = @($null, 'bad', 7, @(), ([pscustomobject]@{}),
        ([pscustomobject]@{model='gpt-6.2-sol'}), ([pscustomobject]@{vendor='codex'}),
        ([pscustomobject]@{model='gpt-6.2-sol';vendor='codex';effort='high'}),
        ([pscustomobject]@{model='';vendor='codex'}), ([pscustomobject]@{model='  ';vendor='codex'}),
        ([pscustomobject]@{model=1;vendor='codex'}), ([pscustomobject]@{model=$null;vendor='codex'}),
        ([pscustomobject]@{model='gpt-6.2-sol';vendor='other'}), ([pscustomobject]@{model='gpt-6.2-sol';vendor='CODEX'}),
        ([pscustomobject]@{model='gpt-6.2-sol';vendor='claude'}), ([pscustomobject]@{model='claude-sonnet-4-6';vendor='codex'}),
        ([pscustomobject]@{model='unknown';vendor='codex'}))
    foreach ($slot in @('first','backup')) {
        foreach ($pick in $badPicks) {
            $r = Copy-Roster; Set-Overrides $r ([pscustomobject]@{'ui-frontend'=[pscustomobject]@{$slot=$pick}})
            Expect-Error $r "ROSTER_OVERRIDE_SHAPE: coder/ui-frontend/$slot"
        }
        $r = Copy-Roster
        Set-Overrides $r ([pscustomobject]@{'ui-frontend'=(New-Exception $slot $r.jobs.coder.$slot $r.jobs.coder."${slot}_vendor")})
        Expect-Error $r "ROSTER_OVERRIDE_REDUNDANT: coder/ui-frontend/$slot"
    }
    $frontier = Get-Content (Join-Path $PSScriptRoot '../../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json
    foreach ($model in @($frontier.codex_models) + @('gpt-99-astra')) {
        $r = Copy-Roster; Set-Overrides $r ([pscustomobject]@{'ui-frontend'=(New-Exception first $model codex)})
        Expect-Error $r 'ROSTER_OVERRIDE_FRONTIER: coder/ui-frontend/first'
    }
    $r = Copy-Roster; Set-Overrides $r ([pscustomobject]@{'ui-frontend'=(New-Exception backup 'gpt-6.2-sol' codex)})
    Expect-Error $r 'ROSTER_OVERRIDE_VENDOR: coder/ui-frontend'
    foreach ($slot in @('first','backup')) {
        foreach ($pin in @('other','CODEX','',7,$null)) {
            $r = Copy-Roster; $r.jobs.coder | Add-Member -NotePropertyName "${slot}_vendor_pin" -NotePropertyValue $pin -Force
            Expect-Error $r "ROSTER_VENDOR_PIN: coder/$slot"
        }
        $r = Copy-Roster
        $offPin = if ($slot -eq 'first') { 'claude' } else { 'codex' }
        $r.jobs.coder | Add-Member -NotePropertyName "${slot}_vendor_pin" -NotePropertyValue $offPin -Force
        Expect-Error $r "ROSTER_VENDOR_PIN: coder/$slot"
        $r = Copy-Roster
        $r.jobs.coder | Add-Member -NotePropertyName "${slot}_vendor_pin" -NotePropertyValue $r.jobs.coder."${slot}_vendor" -Force
        $model = if ($offPin -eq 'claude') { 'claude-sonnet-4-6' } else { 'gpt-6.2-sol' }
        Set-Overrides $r ([pscustomobject]@{'ui-frontend'=(New-Exception $slot $model $offPin)})
        Expect-Error $r "ROSTER_VENDOR_PIN: coder/$slot/ui-frontend"
    }
    $r = Copy-Roster; $r.jobs.coder | Add-Member -NotePropertyName backup_vendor_pin -NotePropertyValue codex
    Expect-Error $r 'ROSTER_VENDOR_PIN: coder/backup'
    $r = Copy-Roster; $r.jobs.coder | Add-Member -NotePropertyName backup_vendor_pin -NotePropertyValue claude
    Set-Overrides $r ([pscustomobject]@{'ui-frontend'=[pscustomobject]@{first=[pscustomobject]@{model='gpt-6.2-sol';vendor='codex'};backup=[pscustomobject]@{model='claude-sonnet-4-6';vendor='claude'}}})
    Check-Valid $r 'both pinned slots accept on-pin exceptions'
    # Without pins, swapping both vendors is valid when the effective pair differs.
    $r = Copy-Roster; $r.jobs.coder.PSObject.Properties.Remove('first_vendor_pin')
    Set-Overrides $r ([pscustomobject]@{'ui-frontend'=[pscustomobject]@{first=[pscustomobject]@{model='claude-sonnet-4-6';vendor='claude'};backup=[pscustomobject]@{model='gpt-6.2-sol';vendor='codex'}}})
    Check-Valid $r 'unpinned exceptions can swap vendors'
    # Six defaults pass; an exception-only seventh does not count until made a default.
    $r = Copy-Roster
    Check-Valid $r 'five distinct defaults accepted'
    Set-Overrides $r ([pscustomobject]@{'ui-frontend'=(New-Exception)})
    $counts = Get-RouterRosterModelCounts $r
    Check ($counts.job_defaults -eq 5 -and $counts.all_models -eq 6) 'cap helper reports both counts'
    Check-Valid $r 'exception-only sixth model accepted'
    $r.jobs.writer.backup = 'gpt-6.2-sol'
    Check-Valid $r 'six distinct defaults accepted'
    $counts = Get-RouterRosterModelCounts $r
    Check ($counts.job_defaults -eq 6 -and $counts.all_models -eq 6) 'sixth default counted once'
    $r.jobs.coder.category_overrides.'ui-frontend'.first.model = 'gpt-5.6-sol'
    Check-Valid $r 'exception-only seventh model accepted'
    $counts = Get-RouterRosterModelCounts $r
    Check ($counts.job_defaults -eq 6 -and $counts.all_models -eq 7) 'exception-only seventh excluded from cap count'
    $r.jobs.'deep-thinker'.backup = 'gpt-5.6-sol'
    Expect-Error $r 'ROSTER_MODEL_CAP: maximum 6 distinct models'
    $r = Copy-Roster
    $counts = Get-RouterRosterModelCounts $r
    Check ($counts.job_defaults -eq 5 -and $counts.all_models -eq 5) 'shared defaults deduplicated and null backup excluded'
    foreach ($case in @('none','empty','first','backup','both','outside')) {
        $r = Copy-Roster; $entry = $r.jobs.coder
        $slots = @()
        if ($case -in @('first','both')) { $slots += 'first' }
        if ($case -in @('backup','both')) { $slots += 'backup' }
        $picks = [pscustomobject]@{}
        foreach ($slot in $slots) {
            $pick = if ($slot -eq 'first') { [pscustomobject]@{model='gpt-6.2-sol';vendor='codex'} } else { [pscustomobject]@{model='claude-sonnet-4-6';vendor='claude'} }
            $picks | Add-Member -NotePropertyName $slot -NotePropertyValue $pick
        }
        if ($case -eq 'empty') { Set-Overrides $r ([pscustomobject]@{}) }
        elseif ($case -ne 'none') { Set-Overrides $r ([pscustomobject]@{'ui-frontend'=$picks}) }
        if ($case -eq 'outside') { Set-Overrides $r ([pscustomobject]@{'ui-frontend'=(New-Exception)}) }
        $before = $entry | ConvertTo-Json -Depth 30 -Compress
        $category = if ($case -eq 'outside') { 'mechanical' } else { 'ui-frontend' }
        $effective = Get-RouterEffectiveSlots -Entry $entry -Category $category
        Check ($effective.override_slots -is [array] -and ($effective.override_slots -join ',') -ceq ($slots -join ',')) "$case override slot array"
        Check ($effective.first -ceq $(if ($slots -contains 'first') {'gpt-6.2-sol'} else {$entry.first}) -and $effective.first_vendor -ceq 'codex') "$case effective first"
        Check ($effective.backup -ceq $(if ($slots -contains 'backup') {'claude-sonnet-4-6'} else {$entry.backup}) -and $effective.backup_vendor -ceq 'claude') "$case effective backup"
        Check (($entry | ConvertTo-Json -Depth 30 -Compress) -ceq $before) "$case entry and efforts unchanged"
    }
    $r = Copy-Roster
    Set-Overrides $r ([pscustomobject]@{math=(New-Exception first 'claude-sonnet-4-6' claude)}) 'deep-thinker'
    Check-Valid $r 'deep-thinker exception validates'
    Check ((Get-RouterEffectiveSlots $r.jobs.'deep-thinker' math).first -ceq 'claude-sonnet-4-6') 'deep-thinker effective first'
    Check ((Get-RouterEffectiveSlots $r.jobs.'deep-thinker' 'routine-coding').override_slots.Count -eq 0) 'another multi-category job uses defaults'
    # Resolver integration uses only isolated catalogs, state and vendor seams.
    . (Join-Path $PSScriptRoot '../resolve-model.ps1')
    . (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
    $fixture = Enter-RouterTestCodexHome
    try {
        function Invoke-RestMethod { throw 'UNEXPECTED NETWORK' }
        function Invoke-WebRequest { throw 'UNEXPECTED NETWORK' }
        $script:blocked = @()
        function Get-RouterVendorBlocked {
            param($Vendor, $UsageReadings)
            return ($Vendor -in $script:blocked -or @(Read-RouterJsonArray (Join-Path $temp 'vendor-blocks.json') | Where-Object vendor -EQ $Vendor).Count -gt 0)
        }
        $catalog = Get-Content (Join-Path $env:CODEX_HOME 'models_cache.json') -Raw | ConvertFrom-Json
        $catalog.models += [pscustomobject]@{slug='gpt-6.2-sol';visibility='list';priority=1}
        $r = Copy-Roster
        $r.approved = $true; $r.approved_at = [datetimeoffset]::UtcNow.ToString('o')
        Set-Overrides $r ([pscustomobject]@{'ui-frontend'=[pscustomobject]@{first=[pscustomobject]@{model='gpt-6.2-sol';vendor='codex'};backup=[pscustomobject]@{model='claude-sonnet-4-6';vendor='claude'}}})
        function Save-ResolverRoster { Write-RouterJsonAtomic (Join-Path $temp 'roster.json') $r }
        Save-ResolverRoster
        $args = @{Category='ui-frontend';Catalog=$catalog;SkipModelCheck=$true}
        $pick = Resolve-RouterModel @args
        Check ($pick.model -ceq 'gpt-6.2-sol' -and $pick.effort -ceq 'medium' -and $pick.roster_source -ceq 'state') 'effective first model and inherited effort'
        Check ($pick.category_override -is [bool] -and $pick.category_override -and $pick.category_override_slots -is [array] -and ($pick.category_override_slots -join ',') -ceq 'first,backup') 'exception output fields'
        Check ($pick.reason -ceq 'roster job coder first choice (category exception ui-frontend)') 'exception reason'
        $normal = Resolve-RouterModel -Category routine-coding -Catalog $catalog -SkipModelCheck
        Check ($normal.model -ceq $r.jobs.coder.first -and -not $normal.category_override -and $normal.category_override_slots.Count -eq 0) 'default category unaffected'
        Check ((Resolve-RouterModel -Category mechanical -Protected -Catalog $catalog -SkipModelCheck).model -ceq $r.jobs.coder.first) 'protected remap uses coder defaults'
        Check ((Resolve-RouterModel @args -Lane claude).model -ceq 'claude-sonnet-4-6') 'lane uses effective backup'
        Write-RouterJsonAtomic (Join-Path $temp 'drift-marks.json') @(@{model='gpt-6.2-sol';job='coder'})
        Check ((Resolve-RouterModel @args).model -ceq 'claude-sonnet-4-6') 'exception drift uses effective backup'
        Check ((Resolve-RouterModel -Category routine-coding -Catalog $catalog -SkipModelCheck).model -ceq $r.jobs.coder.first) 'exception drift leaves default category alone'
        $wait = Resolve-RouterModel @args -Lane codex
        Check ($wait.status -ceq 'wait' -and $wait.reason -match 'gpt-6.2-sol drifting' -and $wait.category_override) 'constrained drift waits on exception model'
        Write-RouterJsonAtomic (Join-Path $temp 'drift-marks.json') @()
        $script:blocked = @('codex')
        Check ((Resolve-RouterModel @args).model -ceq 'claude-sonnet-4-6') 'vendor block uses effective backup'
        $script:blocked = @('codex','claude')
        Check ((Resolve-RouterModel @args).status -ceq 'wait') 'both effective vendors blocked wait'
        $script:blocked = @()
        $missing = $args.Clone(); $missing.Catalog = [pscustomobject]@{models=@($catalog.models | Where-Object slug -NE 'gpt-6.2-sol')}
        Check ((Resolve-RouterModel @missing).model -ceq 'claude-sonnet-4-6') 'unselectable exception uses effective backup'
        $pick = Resolve-RouterModel @args -RetryAtHardFrom 'gpt-6.2-sol' -DifficultyReason 'Synthetic failed standard check'
        Check ($pick.model -ceq 'gpt-6.2-sol' -and $pick.effort -ceq 'high' -and $pick.category_override) 'retry accepts effective model outside ladder'
        $pick = Resolve-RouterModel @args -EscalateFrom 'gpt-6.2-sol' -Difficulty hard -DifficultyReason 'Synthetic failed hard check'
        Check ($pick.model -ceq 'gpt-6.2-sol' -and $pick.effort -ceq 'high' -and $pick.category_override) 'escalation retains effective off-ladder model'
        $pick = Resolve-RouterModel @args -AfterRefusal codex -ResetAtUtc ([datetimeoffset]::UtcNow.AddHours(1))
        Check ($pick.model -ceq 'claude-sonnet-4-6' -and $pick.category_override) 'after refusal uses effective backup'
        Remove-Item (Join-Path $temp 'vendor-blocks.json') -ErrorAction SilentlyContinue
        function Resolve-RouterDispatchFailure { param($Vendor,$ErrorText) return [pscustomobject]@{verdict='vendor_incident';detail='synthetic';incident_id='fixture';checks=@()} }
        $errorPath = Join-Path $temp 'error.txt'; [IO.File]::WriteAllText($errorPath,'synthetic incident')
        $pick = Resolve-RouterModel @args -Diagnose codex -ErrorTextPath $errorPath
        Check ($pick.model -ceq 'claude-sonnet-4-6' -and $pick.verdict -ceq 'vendor_incident' -and $pick.category_override) 'diagnose uses effective backup'
        # A backup-only exception leaves the first choice intact.
        Set-Overrides $r ([pscustomobject]@{'ui-frontend'=(New-Exception backup 'claude-sonnet-4-6' claude)})
        Save-ResolverRoster
        $pick = Resolve-RouterModel @args
        Check ($pick.model -ceq $r.jobs.coder.first -and ($pick.category_override_slots -join ',') -ceq 'backup') 'backup-only override metadata'
        Check ((Resolve-RouterModel @args -Lane claude).model -ceq 'claude-sonnet-4-6') 'backup-only exception lane'
        Set-Overrides $r ([pscustomobject]@{'ui-frontend'=(New-Exception)})
        Save-ResolverRoster
        $pick = Resolve-RouterModel @args
        Check ($pick.model -ceq 'gpt-6.2-sol' -and ($pick.category_override_slots -join ',') -ceq 'first') 'first-only exception metadata'
        Check ((Resolve-RouterModel @args -Lane claude).model -ceq $r.jobs.coder.backup) 'first-only exception retains default backup'
        Set-Overrides $r ([pscustomobject]@{math=[pscustomobject]@{first=[pscustomobject]@{model='gpt-6-sol';vendor='codex'};backup=[pscustomobject]@{model='claude-opus-5-5';vendor='claude'}}}) 'deep-thinker'
        Save-ResolverRoster
        $firstLane = Resolve-RouterModel -Category math -Lane codex -Catalog $catalog -SkipModelCheck
        $otherLane = Resolve-RouterModel -Category math -Lane claude -Catalog $catalog -SkipModelCheck
        Check ($firstLane.model -ceq 'gpt-6-sol' -and $firstLane.effort -ceq $r.jobs.'deep-thinker'.first_efforts.standard) 'swapped vendor first lane inherits first effort'
        Check ($otherLane.model -ceq 'claude-opus-5-5' -and $otherLane.effort -ceq $r.jobs.'deep-thinker'.backup_efforts.standard) 'swapped vendor other lane inherits backup effort'
    } finally { Exit-RouterTestCodexHome $fixture }
    "SUMMARY: $script:checks passed"
} finally {
    $env:DT_MODEL_ROUTER_STATE = $priorState
    $env:DT_MODEL_ROUTER_SHARED = $priorShared
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorAlert
    Remove-Item -LiteralPath $temp -Recurse -Force
}
