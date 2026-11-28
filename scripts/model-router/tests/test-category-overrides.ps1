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
    # Five defaults, six including an exception: passes; move the sixth to a default: fails.
    $r = Copy-Roster
    Check-Valid $r 'five distinct defaults accepted'
    Set-Overrides $r ([pscustomobject]@{'ui-frontend'=(New-Exception)})
    $counts = Get-RouterRosterModelCounts $r
    Check ($counts.job_defaults -eq 5 -and $counts.all_models -eq 6) 'cap helper reports both counts'
    Check-Valid $r 'exception-only sixth model accepted'
    $r.jobs.writer.backup = 'gpt-6.2-sol'
    Expect-Error $r 'ROSTER_MODEL_CAP: maximum 5 distinct models'
    $counts = Get-RouterRosterModelCounts $r
    Check ($counts.job_defaults -eq 6 -and $counts.all_models -eq 6) 'sixth default counted once'
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
    "SUMMARY: $script:checks passed"
} finally {
    $env:DT_MODEL_ROUTER_STATE = $priorState
    $env:DT_MODEL_ROUTER_SHARED = $priorShared
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorAlert
    Remove-Item -LiteralPath $temp -Recurse -Force
}
