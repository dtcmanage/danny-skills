param(
    [Alias('Category')][string]$RouterResolveCliCategory,
    [Alias('Lane')][string]$RouterResolveCliLane,
    [Alias('Protected')][switch]$RouterResolveCliProtected,
    [Alias('EscalateFrom')][string]$RouterResolveCliEscalateFrom,
    [Alias('Catalog')][object]$RouterResolveCliCatalog,
    [Alias('SkipModelCheck')][switch]$RouterResolveCliSkipModelCheck,
    [Alias('SendAlerts')][switch]$RouterResolveCliSendAlerts,
    [Alias('AfterRefusal')][ValidateSet('codex','claude')][string]$RouterResolveCliAfterRefusal,
    [Alias('RefusalText')][string]$RouterResolveCliRefusalText,
    [Alias('ResetAtUtc')][datetimeoffset]$RouterResolveCliResetAtUtc,
    [Alias('Diagnose')][ValidateSet('codex','claude')][string]$RouterResolveCliDiagnose,
    [Alias('ErrorTextPath')][string]$RouterResolveCliErrorTextPath,
    [Alias('Json')][switch]$RouterResolveCliJson
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot 'vendor-limits.ps1')
. (Join-Path $PSScriptRoot '../resolve-codex-model.ps1')
. (Join-Path $PSScriptRoot 'send-router-alert.ps1')

function Test-RouterCodexSelectable {
    param([object]$ParsedCatalog, [string]$Model)
    $row = @($ParsedCatalog.models | Where-Object { $_.PSObject.Properties['slug'] -and $_.slug -eq $Model } | Select-Object -First 1)
    if ($row.Count -eq 0) { return $false }
    # The shared ladder enforces visibility, retirement notices and slug rules. Isolate
    # one row so its newest-generation filter cannot hide an older valid candidate.
    $copy = $row[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    if ($copy.PSObject.Properties['description'] -and [string]$copy.description -match 'frontier') {
        $copy.description = '' # Explicit frontier candidates remain available to the router.
    }
    return (@(Get-CodexModelLadder -Catalog ([pscustomobject]@{ models = @($copy) })) -contains $Model)
}

function Get-RouterAgentAlias {
    # Host-native Agent dispatch takes a family alias, not a model id: map the router's
    # Claude pick (claude-<family>-...) to opus, sonnet, haiku, or fable. Null when the
    # model has no Agent alias; dispatch it through invoke-claude-chunk.ps1 instead.
    param([Parameter(Mandatory)][string]$Model)
    $match = [regex]::Match($Model.ToLowerInvariant(), '^claude-(opus|sonnet|haiku|fable)-')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value
}

function Resolve-RouterEscalationAlias {
    param([string]$EscalateFrom, [string]$Lane)
    if ($Lane -ne 'claude' -or -not $EscalateFrom) { return $EscalateFrom }
    $family = ($EscalateFrom -replace '\[1m\]$','').ToLowerInvariant()
    if ($family -notin @('haiku','sonnet','opus','fable')) { return $EscalateFrom }
    $map = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/ladders.json') -Raw | ConvertFrom-Json -Depth 10
    $match = @($map.lanes.claude.ladder | Where-Object { (Get-RouterAgentAlias -Model $_.model) -eq $family } | Select-Object -First 1)
    if ($match.Count) { return [string]$match[0].model }
    return $EscalateFrom
}

function Complete-RouterResult {
    param([object]$Result, [string]$Job, [string]$RosterSource)
    $vendor = if ($Result.model -like 'claude-*') { 'claude' } elseif ($null -eq $Result.model) { $null } else { 'codex' }
    $Result.lane = $vendor
    $Result.agent_alias = if ($vendor -eq 'claude') { Get-RouterAgentAlias -Model $Result.model } else { $null }
    $Result | Add-Member -NotePropertyName status -NotePropertyValue $(if ($null -eq $Result.model) { 'wait' } else { 'ok' })
    $Result | Add-Member -NotePropertyName job -NotePropertyValue $Job
    $Result | Add-Member -NotePropertyName vendor -NotePropertyValue $vendor
    $Result | Add-Member -NotePropertyName roster_source -NotePropertyValue $RosterSource
    return $Result
}

function Resolve-RouterRosterPick {
    param([object]$Read, [string]$Category, [string]$Lane, [bool]$IsProtected, [string]$EscalateFrom, [object]$Catalog)
    $job = Get-RouterCategoryJob -Category $Category
    if ($IsProtected -and $job -eq 'fast') { $job = 'coder' }
    $entry = $Read.roster.jobs.$job
    $first = [pscustomobject]@{ model=$entry.first; vendor=$entry.first_vendor; effort=$entry.first_effort }
    $backup = if ($null -ne $entry.backup) { [pscustomobject]@{ model=$entry.backup; vendor=$entry.backup_vendor; effort=$entry.backup_effort } } else { $null }
    $quotaWait = $false
    $chosen = $first
    $other = $backup
    $reason = "roster job $job first choice"
    $alerts = [System.Collections.Generic.List[string]]::new()
    if ($Lane -and $Lane -ne $first.vendor) { $chosen = $backup; $other = $first; $reason = "roster job $job lane $Lane" }
    if ($EscalateFrom -and -not $Lane) {
        $sourceVendor = if ($EscalateFrom -like 'gpt-*') { 'codex' } elseif ($EscalateFrom -like 'claude-*' -or $EscalateFrom -match '^(haiku|sonnet|opus|fable)(\[1m\])?$') { 'claude' } else { $null }
        $target = if ($first.vendor -eq $sourceVendor) { $first } else { $backup }
        if ($sourceVendor -and $chosen -and $target -and $chosen.vendor -ne $sourceVendor) { $other = $chosen; $chosen = $target }
    }
    if ($null -eq $chosen) { $reason = 'No Claude image model is available.' }
    $localCatalog = $Catalog
    if ($null -eq $localCatalog) { try { $localCatalog = Get-CodexModelCatalog } catch { $localCatalog = $null } }
    if ($chosen -and -not $Lane -and -not $EscalateFrom) {
        $marks = @(Read-RouterJsonArray -Path (Join-Path (Get-RouterStateDir) 'drift-marks.json') | Where-Object { $_.PSObject.Properties['model'] -and $_.PSObject.Properties['job'] -and $_.model -eq $chosen.model -and $_.job -eq $job })
        if ($marks.Count) {
            if ($other) { $old = $chosen; $chosen = $other; $other = $old; $reason = "Backup used: $($old.model) drifting." }
            else { $alerts.Add("roster-drift-no-backup:$($chosen.model)"); $reason = "Roster model $($chosen.model) drifting; no backup available." }
        }
    } elseif ($chosen -and $Lane) {
        $marks = @(Read-RouterJsonArray -Path (Join-Path (Get-RouterStateDir) 'drift-marks.json') | Where-Object { $_.PSObject.Properties['model'] -and $_.PSObject.Properties['job'] -and $_.model -eq $chosen.model -and $_.job -eq $job })
        if ($marks.Count) { $reason = "Wait: $($chosen.model) drifting on constrained lane $Lane."; $chosen = $null }
    }
    if ($chosen -and $EscalateFrom) {
        $sourceVendor = if ($EscalateFrom -like 'gpt-*') { 'codex' } elseif ($EscalateFrom -like 'claude-*' -or $EscalateFrom -match '^(haiku|sonnet|opus|fable)(\[1m\])?$') { 'claude' } else { $null }
        $source = if ($Lane -and $sourceVendor -and $sourceVendor -ne $Lane) { $chosen.model } else { $EscalateFrom }
        $from = Resolve-RouterEscalationAlias -EscalateFrom $source -Lane $chosen.vendor
        $map = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/ladders.json') -Raw | ConvertFrom-Json -Depth 10
        $ids = @($map.lanes.($chosen.vendor).ladder | Where-Object { -not $_.frontier } | ForEach-Object { [string]$_.model })
        $at = [array]::IndexOf($ids,$from)
        if ($at -ge 0) {
            if ($at -lt $ids.Count - 1) { $chosen = [pscustomobject]@{ model=$ids[$at + 1]; vendor=$chosen.vendor; effort=$chosen.effort }; $reason = "Escalation: one rung up from $from." }
            else { $chosen = [pscustomobject]@{ model=$from; vendor=$chosen.vendor; effort=$chosen.effort }; $reason = "Escalation: already at the top non-frontier model; same model retained." }
        }
    }
    if ($chosen -and (Get-Command Get-RouterVendorBlocked -ErrorAction SilentlyContinue)) {
        if (Get-RouterVendorBlocked -Vendor $chosen.vendor) {
            $blockedVendor = $chosen.vendor
            $incident = @(Read-RouterJsonArray -Path (Join-Path (Get-RouterStateDir) 'vendor-blocks.json') | Where-Object { $_.vendor -eq $blockedVendor -and $_.PSObject.Properties['reason'] -and $_.reason -eq 'vendor_incident' })
            $blockReason = if ($incident.Count) { 'under a vendor incident' } else { 'at its usage limit' }
            if (-not $Lane -and $other -and -not (Get-RouterVendorBlocked -Vendor $other.vendor)) { $chosen = $other; $reason = "Backup used: $blockedVendor $blockReason." }
            else { $chosen = $null; $quotaWait = $true; $reason = "Wait: $blockedVendor $blockReason; no available model for $job." }
        }
    }
    if ($chosen -and $chosen.vendor -eq 'codex' -and $Category -ne 'image-generation' -and $null -ne $localCatalog -and -not (Test-RouterCodexSelectable -ParsedCatalog $localCatalog -Model $chosen.model)) {
        # Older clients can overwrite the shared cache. Only an automatic cache
        # rejection gets one bounded current-CLI check; caller catalogs stay fixed.
        if ($null -eq $Catalog) {
            try {
                $cli = Get-Command codex -CommandType Application,ExternalScript -ErrorAction Stop | Select-Object -First 1
                $freshCatalog = Update-CodexModelCatalog -CodexCliPath $cli.Source -TimeoutMs 15000
                # Evaluate the returned snapshot, never the race-prone cache file.
                if (Test-RouterCodexSelectable -ParsedCatalog $freshCatalog -Model $chosen.model) {
                    $localCatalog = $freshCatalog
                }
            } catch { # Keep the cached rejection and existing fallback on failure.
            }
        }
        if (-not (Test-RouterCodexSelectable -ParsedCatalog $localCatalog -Model $chosen.model)) {
            $unselectable = $chosen.model
            $alerts.Add("roster-model-unselectable:$unselectable")
            if (-not $Lane -and $other -and $other.vendor -ne 'codex' -and -not ((Get-Command Get-RouterVendorBlocked -ErrorAction SilentlyContinue) -and (Get-RouterVendorBlocked -Vendor $other.vendor))) {
                $chosen = $other; $reason = $(if ($reason -like 'Backup used:*drifting.') { "$reason Backup $unselectable unselectable; first choice used." } else { "Backup used: $unselectable unselectable." })
            } else { $chosen = $null; $reason = "Wait: $unselectable unselectable on constrained or unavailable lane." }
        }
    }
    $model = if ($chosen) { $chosen.model } else { $null }
    $result = [pscustomobject]@{ model=$model; agent_alias=$null; effort=$(if ($chosen) { $chosen.effort } else { $null }); category=$Category; lane=$null; protected=$IsProtected; reason=$reason; table_source=$null; table_date=$null; validation_error=$Read.validation_error; alerts=@($alerts.ToArray()); ranked=[object[]]@($model | Where-Object { $_ }) }
    $resume = if ($quotaWait) {
        $vendors = @($first, $backup | Where-Object { $null -ne $_ -and (-not $Lane -or $_.vendor -eq $Lane) } | ForEach-Object { $_.vendor })
        Get-RouterResumeAfter -Vendors $vendors
    } else { [pscustomobject]@{ resume_after_utc=$null; resume_after_source=$null; resume_after_et=$null } }
    foreach ($name in @('resume_after_utc','resume_after_source','resume_after_et')) {
        $result | Add-Member -NotePropertyName $name -NotePropertyValue $resume.$name
    }
    return (Complete-RouterResult -Result $result -Job $job -RosterSource $Read.source)
}

function Resolve-RouterModel {
    param(
        [Parameter(Mandatory)][string]$Category,
        [ValidateSet('codex','claude')][string]$Lane,
        [switch]$Protected,
        [string]$EscalateFrom,
        [object]$Catalog,
        [switch]$SkipModelCheck,
        [switch]$SendAlerts,
        [switch]$ChatToStderr,
        [ValidateSet('codex','claude')][string]$AfterRefusal,
        [string]$RefusalText,
        [datetimeoffset]$ResetAtUtc,
        [ValidateSet('codex','claude')][string]$Diagnose,
        [string]$ErrorTextPath
    )
    if ($Diagnose) {
        if (-not $ErrorTextPath) { throw 'DIAGNOSE_ERROR_TEXT_PATH_REQUIRED: supply -ErrorTextPath with -Diagnose.' }
        $diagnosis = Resolve-RouterDispatchFailure -Vendor $Diagnose -ErrorText ([IO.File]::ReadAllText((Convert-Path -LiteralPath $ErrorTextPath)))
        if ($diagnosis.verdict -ne 'vendor_incident') { return $diagnosis }
        # Constrain the backup to the other vendor, including when drift would
        # otherwise select the failed vendor again. This is not quality escalation.
        $backupArgs = @{ Category=$Category; Lane=$(if ($Diagnose -eq 'codex') { 'claude' } else { 'codex' }); Protected=$Protected; Catalog=$Catalog; SkipModelCheck=$SkipModelCheck; SendAlerts=$SendAlerts; ChatToStderr=$ChatToStderr }
        $result = Resolve-RouterModel @backupArgs
        foreach ($name in @('verdict','detail','incident_id','checks')) {
            $result | Add-Member -NotePropertyName $name -NotePropertyValue $diagnosis.$name
        }
        return $result
    }
    # Fresh incident records block dispatch without any network check. Stale
    # records reuse the shared status cache and component-specific recovery logic.
    $now = [datetimeoffset](& $script:RouterDiagnosisClock)
    $staleVendors = @(Read-RouterJsonArray -Path (Join-Path (Get-RouterStateDir) 'vendor-blocks.json') | Where-Object {
        $_.PSObject.Properties['reason'] -and $_.reason -eq 'vendor_incident' -and
        ($now - [datetimeoffset]$_.blocked_at_utc).TotalSeconds -ge 300
    } | ForEach-Object { $_.vendor } | Select-Object -Unique)
    foreach ($vendor in $staleVendors) { $null = Resolve-RouterDispatchFailure -Vendor $vendor -ErrorText '' }
    $recorded = $null
    if ($AfterRefusal) {
        if ($Lane -eq $AfterRefusal) { throw 'AFTER_REFUSAL_LANE_CONFLICT: omit -Lane or choose the other vendor after a refusal.' }
        $blockArgs = @{ Vendor=$AfterRefusal; Reason='refusal' }
        if ($PSBoundParameters.ContainsKey('ResetAtUtc')) { $blockArgs.ResetAtUtc = $ResetAtUtc }
        elseif ($RefusalText) {
            $refusal = Test-RouterLimitRefusal -Vendor $AfterRefusal -Text $RefusalText
            if ($refusal.reset_at_utc) { $blockArgs.ResetAtUtc = [datetimeoffset]$refusal.reset_at_utc }
        }
        $recorded = Add-RouterVendorBlock @blockArgs
    }
    $rosterRead = Read-RouterRoster
    $result = Resolve-RouterRosterPick -Read $rosterRead -Category $Category -Lane $Lane -IsProtected ([bool]$Protected -or $Category -eq 'long-form-writing') -EscalateFrom $EscalateFrom -Catalog $Catalog
    $result | Add-Member -NotePropertyName vendor_block_recorded -NotePropertyValue $recorded
    if ($rosterRead.source -eq 'default') {
        $alert = if (Test-Path -LiteralPath $rosterRead.path) {
            $errorText = if ($rosterRead.validation_error) { $rosterRead.validation_error } else { 'ROSTER_NOT_APPROVED: roster is not approved' }
            "router-roster-invalid: $errorText"
        } else { 'router-roster-missing' }
        $result.alerts = @($result.alerts) + @($alert)
    }
    if ($SendAlerts) { Send-RouterAlerts -Alerts @($result.alerts) -ChatToStderr:$ChatToStderr | Out-Null }
    return $result
}

function Get-RouterPicksSnapshot {
    $picks = [System.Collections.Generic.List[object]]::new()
    foreach ($category in @(Get-RouterDispatchCategories)) {
        foreach ($lane in $(if ($category -eq 'image-generation') { @('codex') } else { @('codex','claude') })) {
            foreach ($protected in @($false,$true)) {
                $pick = Resolve-RouterModel -Category $category -Lane $lane -Protected:$protected -SkipModelCheck
                $picks.Add([pscustomobject]@{ category = $category; lane = $lane; protected = $protected; model = $pick.model; effort = $pick.effort; reason = $pick.reason })
            }
        }
    }
    return @($picks.ToArray())
}

if ($MyInvocation.InvocationName -ne '.') {
    $resolveArgs = @{ Category = $RouterResolveCliCategory; Protected = $RouterResolveCliProtected; EscalateFrom = $RouterResolveCliEscalateFrom; Catalog = $RouterResolveCliCatalog; SkipModelCheck = $RouterResolveCliSkipModelCheck; SendAlerts = $RouterResolveCliSendAlerts; ChatToStderr = $RouterResolveCliJson }
    if ($PSBoundParameters.ContainsKey('RouterResolveCliLane')) { $resolveArgs.Lane = $RouterResolveCliLane }
    if ($PSBoundParameters.ContainsKey('RouterResolveCliAfterRefusal')) { $resolveArgs.AfterRefusal = $RouterResolveCliAfterRefusal }
    if ($PSBoundParameters.ContainsKey('RouterResolveCliRefusalText')) { $resolveArgs.RefusalText = $RouterResolveCliRefusalText }
    if ($PSBoundParameters.ContainsKey('RouterResolveCliResetAtUtc')) { $resolveArgs.ResetAtUtc = $RouterResolveCliResetAtUtc }
    if ($PSBoundParameters.ContainsKey('RouterResolveCliDiagnose')) { $resolveArgs.Diagnose = $RouterResolveCliDiagnose }
    if ($PSBoundParameters.ContainsKey('RouterResolveCliErrorTextPath')) { $resolveArgs.ErrorTextPath = $RouterResolveCliErrorTextPath }
    $result = Resolve-RouterModel @resolveArgs
    if ($RouterResolveCliJson) { $result | ConvertTo-Json -Depth 12 -Compress } else { $result }
}
