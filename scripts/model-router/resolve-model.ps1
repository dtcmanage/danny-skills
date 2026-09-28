param(
    [Alias('Category')][string]$RouterResolveCliCategory,
    [Alias('Lane')][string]$RouterResolveCliLane,
    [Alias('Protected')][switch]$RouterResolveCliProtected,
    [Alias('EscalateFrom')][string]$RouterResolveCliEscalateFrom,
    [Alias('Catalog')][object]$RouterResolveCliCatalog,
    [Alias('TablePath')][string]$RouterResolveCliTablePath,
    [Alias('SkipModelCheck')][switch]$RouterResolveCliSkipModelCheck,
    [Alias('SendAlerts')][switch]$RouterResolveCliSendAlerts,
    [Alias('Json')][switch]$RouterResolveCliJson
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot 'vendor-limits.ps1')
. (Join-Path $PSScriptRoot '../resolve-codex-model.ps1')
. (Join-Path $PSScriptRoot 'send-router-alert.ps1')
. (Join-Path $PSScriptRoot 'run-router-research.ps1')

function Get-RouterFailureProbability {
    param([object]$Candidate)
    if ($Candidate.pass_samples -ge 10 -and $null -ne $Candidate.pass_rate) { return (1.0 - [double]$Candidate.pass_rate) }
    if ($Candidate.confirmed_grade -eq 'strong') { return 0.10 }
    return 0.25
}

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
    $map = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/bridge-map.json') -Raw | ConvertFrom-Json -Depth 10
    $match = @($map.lanes.claude.ladder | Where-Object { (Get-RouterAgentAlias -Model $_.model) -eq $family } | Select-Object -First 1)
    if ($match.Count) { return [string]$match[0].model }
    return $EscalateFrom
}

function Get-RouterModelTier {
    # Fixed size order used where "stronger" must not depend on per-category research scores:
    # protected work may only move up this order, and drift demotion steps up it.
    param([string]$Model)
    if ($Model -match '^claude-(haiku|sonnet|opus|fable)-') { return @{ haiku = 0; sonnet = 1; opus = 2; fable = 3 }[$Matches[1]] }
    if ($Model -match '^gpt-[0-9.]+-(luna|terra|sol|astra)$') { return @{ luna = 0; terra = 1; sol = 2; astra = 3 }[$Matches[1]] }
    return $null
}

function Get-RouterDriftStep {
    # Next non-frontier, selectable rung above a drift-flagged model on the lane ladder; $null when none.
    param([string]$Category, [string]$Lane, [string]$Model, [object]$Catalog, [string[]]$Skip = @())
    $map = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/bridge-map.json') -Raw | ConvertFrom-Json -Depth 10
    $ladder = @($map.lanes.$Lane.ladder)
    $ids = @($ladder | ForEach-Object { [string]$_.model })
    $index = [array]::IndexOf($ids, $Model)
    if ($index -lt 0) { return $null }
    for ($j = $index + 1; $j -lt $ids.Count; $j++) {
        if ($ladder[$j].frontier) { return $null }
        if ($Skip -contains $ids[$j]) { continue }
        if ($Lane -eq 'codex' -and $Category -ne 'image-generation' -and -not (Test-RouterCodexSelectable -ParsedCatalog (Get-CodexModelCatalog -Catalog $Catalog) -Model $ids[$j])) { continue }
        return $ids[$j]
    }
    return $null
}

function Resolve-RouterBridgeModel {
    # Bridge first picks match pre-router tiers until full research coverage is available.
    # Escalation moves one rung up the non-frontier lane ladder.
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Lane,
        [bool]$IsProtected,
        [string]$EscalateFrom,
        [object]$Catalog,
        [System.Collections.Generic.List[string]]$Alerts
    )
    $map = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/bridge-map.json') -Raw | ConvertFrom-Json -Depth 10
    $laneMap = $map.lanes.$Lane
    $mapped = [string]$laneMap.categories.$Category
    if (-not $mapped) { throw "BRIDGE_MAP: no $Category/$Lane mapping" }
    if ($IsProtected -and $Category -ne 'image-generation') {
        $protectedPick = [string]$laneMap.protected
        if (-not $protectedPick) { throw "BRIDGE_MAP: no protected pick for $Lane" }
        $mapped = $protectedPick
    }
    $ladder = @($laneMap.ladder | Where-Object { -not $_.frontier })
    $ids = @($ladder | ForEach-Object { [string]$_.model })
    $label = if ($IsProtected) { "$Category/$Lane protected" } else { "$Category/$Lane" }
    if ($EscalateFrom) {
        $index = [array]::IndexOf($ids, $EscalateFrom)
        if ($index -lt 0) { $model = $mapped; $mapping = "escalation source $EscalateFrom is not on the $Lane ladder; $label -> $mapped" }
        elseif ($index -eq $ids.Count - 1) { $model = $EscalateFrom; $mapping = "escalation from ${EscalateFrom}: already at the top of the $Lane ladder; same model retained" }
        else { $model = $ids[$index + 1]; $mapping = "escalation $EscalateFrom -> $model (one rung up the $Lane ladder)" }
    } else { $model = $mapped; $mapping = "$label -> $mapped" }
    if ($Lane -eq 'codex' -and $Category -ne 'image-generation') {
        $parsed = Get-CodexModelCatalog -Catalog $Catalog
        if (-not (Test-RouterCodexSelectable -ParsedCatalog $parsed -Model $model)) {
            $Alerts.Add("UNSELECTABLE_CODEX_MODEL: $model")
            $start = [array]::IndexOf($ids, $model)
            # Next rung up first, then down; image and unknown ids have no ladder position.
            $order = [System.Collections.Generic.List[int]]::new()
            if ($start -ge 0) {
                for ($i = $start + 1; $i -lt $ids.Count; $i++) { $order.Add($i) }
                for ($i = $start - 1; $i -ge 0; $i--) { $order.Add($i) }
            }
            $replacement = $null
            foreach ($i in $order) {
                if (Test-RouterCodexSelectable -ParsedCatalog $parsed -Model $ids[$i]) { $replacement = $ids[$i]; break }
            }
            if ($replacement) { $mapping += "; $model is not selectable, next ladder rung $replacement"; $model = $replacement }
            else { $mapping += "; $model is not selectable and no ladder rung is" }
        }
    }
    return [pscustomobject]@{ model = $model; reason = "bridge mode (no full research table yet): $mapping" }
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
    $first = [pscustomobject]@{ model=$entry.first; vendor=$entry.first_vendor }
    $backup = if ($null -ne $entry.backup) { [pscustomobject]@{ model=$entry.backup; vendor=$entry.backup_vendor } } else { $null }
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
        $map = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/bridge-map.json') -Raw | ConvertFrom-Json -Depth 10
        $ids = @($map.lanes.($chosen.vendor).ladder | Where-Object { -not $_.frontier } | ForEach-Object { [string]$_.model })
        $at = [array]::IndexOf($ids,$from)
        if ($at -ge 0) {
            if ($at -lt $ids.Count - 1) { $chosen = [pscustomobject]@{ model=$ids[$at + 1]; vendor=$chosen.vendor }; $reason = "Escalation: one rung up from $from." }
            else { $chosen = [pscustomobject]@{ model=$from; vendor=$chosen.vendor }; $reason = "Escalation: already at the top non-frontier model; same model retained." }
        }
    }
    if ($chosen -and (Get-Command Get-RouterVendorBlocked -ErrorAction SilentlyContinue)) {
        if (Get-RouterVendorBlocked -Vendor $chosen.vendor) {
            $blockedVendor = $chosen.vendor
            if (-not $Lane -and $other -and -not (Get-RouterVendorBlocked -Vendor $other.vendor)) { $chosen = $other; $reason = "Backup used: $blockedVendor at its usage limit." }
            else { $chosen = $null; $reason = "Wait: $blockedVendor at its usage limit; no available model for $job." }
        }
    }
    if ($chosen -and $chosen.vendor -eq 'codex' -and $Category -ne 'image-generation' -and $null -ne $localCatalog -and -not (Test-RouterCodexSelectable -ParsedCatalog $localCatalog -Model $chosen.model)) {
        $unselectable = $chosen.model
        $alerts.Add("roster-model-unselectable:$unselectable")
        if (-not $Lane -and $other -and $other.vendor -ne 'codex' -and -not ((Get-Command Get-RouterVendorBlocked -ErrorAction SilentlyContinue) -and (Get-RouterVendorBlocked -Vendor $other.vendor))) {
            $chosen = $other; $reason = $(if ($reason -like 'Backup used:*drifting.') { "$reason Backup $unselectable unselectable; first choice used." } else { "Backup used: $unselectable unselectable." })
        } else { $chosen = $null; $reason = "Wait: $unselectable unselectable on constrained or unavailable lane." }
    }
    $model = if ($chosen) { $chosen.model } else { $null }
    $result = [pscustomobject]@{ model=$model; agent_alias=$null; category=$Category; lane=$null; protected=$IsProtected; reason=$reason; table_source=$null; table_date=$null; validation_error=$Read.validation_error; alerts=@($alerts.ToArray()); ranked=[object[]]@($model | Where-Object { $_ }) }
    return (Complete-RouterResult -Result $result -Job $job -RosterSource state)
}

function Resolve-RouterModel {
    param(
        [Parameter(Mandatory)][string]$Category,
        [ValidateSet('codex','claude')][string]$Lane,
        [switch]$Protected,
        [string]$EscalateFrom,
        [object]$Catalog,
        [string]$TablePath,
        [switch]$SkipModelCheck,
        [switch]$SendAlerts,
        [switch]$ChatToStderr,
        [switch]$IgnoreApproval
    )
    $job = Get-RouterCategoryJob -Category $Category
    $rosterRead = Read-RouterRoster
    if ($rosterRead.source -eq 'state') {
        $result = Resolve-RouterRosterPick -Read $rosterRead -Category $Category -Lane $Lane -IsProtected ([bool]$Protected -or $Category -eq 'long-form-writing') -EscalateFrom $EscalateFrom -Catalog $Catalog
        if ($SendAlerts) { Send-RouterAlerts -Alerts @($result.alerts) -ChatToStderr:$ChatToStderr | Out-Null }
        return $result
    }
    if (-not $Lane) {
        $entry = $rosterRead.roster.jobs.$job
        $Lane = [string]$entry.first_vendor
        if ((Get-Command Get-RouterVendorBlocked -ErrorAction SilentlyContinue) -and (Get-RouterVendorBlocked -Vendor $Lane) -and $entry.backup_vendor) { $Lane = [string]$entry.backup_vendor }
    }
    if ($Category -eq 'image-generation' -and $Lane -ne 'codex') { throw 'LANE: image-generation has only codex' }
    $lookupCategory = if ($Category -in @('math','analysis')) { 'planning' } else { $Category }
    $EscalateFrom = Resolve-RouterEscalationAlias -EscalateFrom $EscalateFrom -Lane $Lane
    $alerts = [System.Collections.Generic.List[string]]::new()
    if ($rosterRead.validation_error) { $alerts.Add("router-roster-invalid: $($rosterRead.validation_error)") }
    $read = Read-RouterTable -TablePath $TablePath
    if ($rosterRead.validation_error) { $read.validation_error = (@($read.validation_error,$rosterRead.validation_error) | Where-Object { $_ }) -join '; ' }
    $laneTable = $read.table.categories.$lookupCategory.$Lane
    if ($read.table.source -eq 'seed') { $alerts.Add('router-seed-table-in-use') }
    if ($read.validation_error) { $alerts.Add("router-live-table-invalid: $($read.validation_error)") }
    $isProtected = [bool]$Protected -or $Category -eq 'long-form-writing'
    if ($read.table.source -ne 'research' -or $read.table.coverage -ne 'full' -or ($read.table.evidence_routing_approved -ne $true -and -not $IgnoreApproval)) {
        $bridge = Resolve-RouterBridgeModel -Category $lookupCategory -Lane $Lane -IsProtected $isProtected -EscalateFrom $EscalateFrom -Catalog $Catalog -Alerts $alerts
        $result = [pscustomobject]@{ model = $bridge.model; agent_alias = $(if ($Lane -eq 'claude') { Get-RouterAgentAlias -Model $bridge.model } else { $null }); category = $Category; lane = $Lane; protected = $isProtected; reason = $bridge.reason; table_source = $read.source; table_date = $read.table.generated_at; validation_error = $read.validation_error; alerts = @($alerts.ToArray()); ranked = @($bridge.model) }
        if ($SendAlerts) { Send-RouterAlerts -Alerts @($result.alerts) -ChatToStderr:$ChatToStderr | Out-Null }
        return (Complete-RouterResult -Result $result -Job $job -RosterSource default)
    }
    $bridgePick = Resolve-RouterBridgeModel -Category $lookupCategory -Lane $Lane -IsProtected $isProtected -Catalog $Catalog -Alerts $alerts
    $incumbentId = $bridgePick.model
    $incumbentRow = @($laneTable.candidates | Where-Object { $_.model -eq $incumbentId } | Select-Object -First 1)
    if ($incumbentRow.Count -eq 0 -or $incumbentRow[0].confirmed_grade -eq 'unknown') {
        $held = if ($EscalateFrom) { Resolve-RouterBridgeModel -Category $lookupCategory -Lane $Lane -IsProtected $isProtected -EscalateFrom $EscalateFrom -Catalog $Catalog -Alerts $alerts } else { $bridgePick }
        if (-not $EscalateFrom) {
            $drift = @(Read-RouterJsonArray -Path (Join-Path (Get-RouterStateDir) 'drift-flags.json') | Where-Object { $_.category -eq $Category -and $_.lane -eq $Lane -and $_.model -eq $held.model })
            if ($drift.Count) {
                $allFlagged = @(Read-RouterJsonArray -Path (Join-Path (Get-RouterStateDir) 'drift-flags.json') | Where-Object { $_.category -eq $Category -and $_.lane -eq $Lane } | ForEach-Object { [string]$_.model })
                $step = Get-RouterDriftStep -Category $Category -Lane $Lane -Model $held.model -Catalog $Catalog -Skip $allFlagged
                if ($step) { $held = [pscustomobject]@{ model = $step; reason = "drift demotion: $($held.model) -> $step (one rung up the $Lane ladder, never a frontier rung)" } }
                else { $alerts.Add("drift-no-alternative:$($held.model):$Category`:$Lane") }
            }
        }
        if ($Lane -eq 'codex' -and $Category -ne 'image-generation' -and $held.model -eq $laneTable.fallback -and -not (Test-RouterCodexSelectable -ParsedCatalog (Get-CodexModelCatalog -Catalog $Catalog) -Model $held.model)) {
            $alerts.Add("fallback_unselectable: $($laneTable.fallback)")
        }
        $result = [pscustomobject]@{ model = $held.model; agent_alias = $(if ($Lane -eq 'claude') { Get-RouterAgentAlias -Model $held.model } else { $null }); category = $Category; lane = $Lane; protected = $isProtected; reason = $(if ($EscalateFrom -or $held.model -ne $bridgePick.model) { $held.reason } else { 'incumbent kept: no confirmed evidence' }); table_source = $read.source; table_date = $read.table.generated_at; validation_error = $read.validation_error; alerts = @($alerts.ToArray()); ranked = @($held.model) }
        if ($SendAlerts) { Send-RouterAlerts -Alerts @($result.alerts) -ChatToStderr:$ChatToStderr | Out-Null }
        return (Complete-RouterResult -Result $result -Job $job -RosterSource default)
    }
    $incumbent = $incumbentRow[0]
    $all = @($laneTable.candidates | Sort-Object strength_rank | Where-Object { $_.confirmed_grade -in @('strong','capable') -and @($_.citations | Where-Object { $_.independent -eq $true }).Count -gt 0 })
    if ($Lane -eq 'codex' -and $Category -ne 'image-generation') {
        $parsed = Get-CodexModelCatalog -Catalog $Catalog
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($candidate in $all) {
            if (Test-RouterCodexSelectable -ParsedCatalog $parsed -Model $candidate.model) { $kept.Add($candidate) }
            else {
                $key = "UNSELECTABLE_CODEX_MODEL: $($candidate.model)"
                if (-not $alerts.Contains($key)) { $alerts.Add($key) }
            }
        }
        $all = @($kept.ToArray())
        if (-not (Test-RouterCodexSelectable -ParsedCatalog $parsed -Model $laneTable.fallback)) {
            $alerts.Add("fallback_unselectable: $($laneTable.fallback)")
        }
    }
    $eligible = @($all | Where-Object { -not $_.frontier })
    $incumbentSelectable = $Category -eq 'image-generation' -or $Lane -ne 'codex' -or (Test-RouterCodexSelectable -ParsedCatalog $parsed -Model $incumbentId)
    if ($incumbentSelectable -and -not $incumbent.frontier -and @($eligible | Where-Object { $_.model -eq $incumbentId }).Count -eq 0) { $eligible = @($incumbent) + $eligible }
    if ($eligible.Count -eq 0) {
        if ($read.table.source -ne 'seed') { $alerts.Add("no-eligible:$Category`:$Lane") }
        $result = [pscustomobject]@{ model = $laneTable.fallback; agent_alias = $(if ($Lane -eq 'claude') { Get-RouterAgentAlias -Model $laneTable.fallback } else { $null }); category = $Category; lane = $Lane; protected = $isProtected; reason = 'No eligible candidate; lane fallback.'; table_source = $read.source; table_date = $read.table.generated_at; validation_error = $read.validation_error; alerts = @($alerts.ToArray()); ranked = @() }
        if ($SendAlerts) { Send-RouterAlerts -Alerts @($result.alerts) -ChatToStderr:$ChatToStderr | Out-Null }
        return (Complete-RouterResult -Result $result -Job $job -RosterSource default)
    }
    $byStrength = @($eligible | Sort-Object strength_rank)
    $scores = @{}
    $rankedCandidates = [System.Collections.Generic.List[object]]::new()
    if ($isProtected -or $EscalateFrom) {
        foreach ($candidate in $byStrength) { $rankedCandidates.Add($candidate) }
    } else {
        $knownBurn = @($byStrength | Where-Object { $null -ne $_.est_burn })
        if ($knownBurn.Count -ne $byStrength.Count) {
            foreach ($candidate in $byStrength) { $rankedCandidates.Add($candidate) }
        } else {
            foreach ($candidate in $byStrength) {
                $index = [array]::IndexOf($byStrength, $candidate)
                $next = if ($index -gt 0) { $byStrength[$index - 1] } else { $null }
                $firstFailure = Get-RouterFailureProbability -Candidate $candidate
                $score = [double]$candidate.est_burn
                if ($next) {
                    $secondFailure = Get-RouterFailureProbability -Candidate $next
                    $score += $firstFailure * [double]$next.est_burn
                    $score += $firstFailure * $secondFailure * [double]$byStrength[0].est_burn
                } else {
                    $frontierFix = @($all | Where-Object { $_.frontier -and $_.strength_rank -lt $candidate.strength_rank } | Sort-Object strength_rank | Select-Object -First 1)
                    if ($frontierFix.Count -gt 0 -and $null -ne $frontierFix[0].est_burn) { $score += $firstFailure * [double]$frontierFix[0].est_burn }
                }
                $scores[$candidate.model] = $score
            }
            $remaining = @($byStrength | Sort-Object @{ Expression = { $scores[$_.model] } }, strength_rank)
            while ($remaining.Count -gt 0) {
                $minimum = [double]$scores[$remaining[0].model]
                $group = @($remaining | Where-Object { [double]$scores[$_.model] -le 1.10 * $minimum })
                $orderedGroup = if (@($group | Where-Object { $null -eq $_.est_seconds }).Count -gt 0) {
                    @($group | Sort-Object strength_rank)
                } else { @($group | Sort-Object est_seconds, strength_rank) }
                foreach ($candidate in $orderedGroup) { $rankedCandidates.Add($candidate) }
                $remaining = @($remaining | Where-Object { $group -notcontains $_ })
            }
        }
    }
    $incumbentGeneration = Get-RouterModelGeneration -Model $incumbentId
    $qualifying = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in $rankedCandidates) {
        if ($candidate.model -eq $incumbentId) { $qualifying.Add($candidate); continue }
        if ($candidate.frontier -or $candidate.confirmed_grade -notin @('strong','capable')) { continue }
        if ($isProtected) {
            $candidateTier = Get-RouterModelTier -Model ([string]$candidate.model)
            $incumbentTier = Get-RouterModelTier -Model $incumbentId
            if ($null -eq $candidateTier -or $null -eq $incumbentTier -or $candidateTier -le $incumbentTier) { continue }
        }
        $gradeComparison = (Get-RouterGradeRank $candidate.confirmed_grade) - (Get-RouterGradeRank $incumbent.confirmed_grade)
        if ($gradeComparison -lt 0) { continue }
        $generation = Get-RouterModelGeneration -Model $candidate.model
        if ($null -ne $generation -and $null -ne $incumbentGeneration -and $generation.vendor -eq $incumbentGeneration.vendor -and
            ($generation.major -lt $incumbentGeneration.major -or ($generation.major -eq $incumbentGeneration.major -and $generation.minor -lt $incumbentGeneration.minor)) -and $gradeComparison -le 0) { continue }
        if ($gradeComparison -eq 0) {
            if ($null -eq $candidate.est_burn -or $null -eq $incumbent.est_burn) { continue }
            $candidateCost = if ($scores.ContainsKey([string]$candidate.model)) { [double]$scores[$candidate.model] } else { [double]$candidate.est_burn }
            $incumbentCost = if ($scores.ContainsKey($incumbentId)) { [double]$scores[$incumbentId] } else { [double]$incumbent.est_burn }
            if ($candidateCost -ge $incumbentCost) { continue }
        }
        $qualifying.Add($candidate)
    }
    if (-not $EscalateFrom -and @($qualifying | Where-Object { $_.model -ne $incumbentId -and (Get-RouterGradeRank $_.confirmed_grade) -gt (Get-RouterGradeRank $incumbent.confirmed_grade) }).Count -gt 0) {
        $higher = @($qualifying | Where-Object { $_.model -ne $incumbentId -and (Get-RouterGradeRank $_.confirmed_grade) -gt (Get-RouterGradeRank $incumbent.confirmed_grade) })
        $qualifying = [System.Collections.Generic.List[object]]::new()
        foreach ($candidate in $higher) { $qualifying.Add($candidate) }
    }
    $rankedCandidates = $qualifying
    if ($rankedCandidates.Count -eq 0) {
        $result = [pscustomobject]@{ model = $laneTable.fallback; agent_alias = $(if ($Lane -eq 'claude') { Get-RouterAgentAlias -Model $laneTable.fallback } else { $null }); category = $Category; lane = $Lane; protected = $isProtected; reason = 'No qualifying selectable non-frontier candidate; lane fallback.'; table_source = $read.source; table_date = $read.table.generated_at; validation_error = $read.validation_error; alerts = @($alerts.ToArray()); ranked = @() }
        if ($SendAlerts) { Send-RouterAlerts -Alerts @($result.alerts) -ChatToStderr:$ChatToStderr | Out-Null }
        return (Complete-RouterResult -Result $result -Job $job -RosterSource default)
    }
    $driftApplied = $false
    $flagged = @(Read-RouterJsonArray -Path (Join-Path (Get-RouterStateDir) 'drift-flags.json') | Where-Object { $_.category -eq $Category -and $_.lane -eq $Lane } | ForEach-Object { [string]$_.model })
    $ranked = @($rankedCandidates.ToArray() | ForEach-Object { $_.model })
    if ($EscalateFrom) {
        $from = @($all | Where-Object { -not $_.frontier -and $_.model -eq $EscalateFrom })
        if ($from.Count -eq 0) { $chosen = $byStrength[0]; $reason = 'Escalation source not eligible; strongest eligible candidate.' }
        else {
            $stronger = @($all | Where-Object { -not $_.frontier -and $_.strength_rank -lt $from[0].strength_rank } | Sort-Object strength_rank)
            if ($stronger.Count) { $chosen = $stronger[-1]; $reason = 'Escalation: next stronger eligible candidate.' }
            else { $chosen = $from[0]; $reason = 'Escalation: no stronger eligible candidate; same model retained.' }
        }
    } elseif ($isProtected) { $chosen = $rankedCandidates[0]; $reason = 'Protected: strongest qualifying candidate.' }
    elseif (@($byStrength | Where-Object { $null -eq $_.est_burn }).Count) { $chosen = $rankedCandidates[0]; $reason = 'Uncalibrated burn: strength-rank order.' }
    else { $chosen = $rankedCandidates[0]; $reason = 'Lowest expected retry-adjusted burn; 10% time tie-break.' }
    if (-not $EscalateFrom -and $flagged -contains [string]$chosen.model) {
        # Drift: a flagged pick yields to the next qualifying unflagged candidate, then to the incumbent,
        # then one rung up the ladder; never to a frontier model.
        $flaggedModel = [string]$chosen.model
        $alternatives = @()
        if (-not $isProtected) { $alternatives += @($rankedCandidates | Where-Object { $_.model -ne $flaggedModel -and $flagged -notcontains [string]$_.model -and -not $_.frontier }) }
        if ($incumbentSelectable -and $incumbentId -ne $flaggedModel -and $flagged -notcontains $incumbentId) { $alternatives += @($incumbent) }
        if ($alternatives.Count) { $chosen = $alternatives[0]; $driftApplied = $true }
        else {
            $step = Get-RouterDriftStep -Category $Category -Lane $Lane -Model $flaggedModel -Catalog $Catalog -Skip $flagged
            # Evidence mode: never step onto a model the research confirms as weak for this category.
            if ($step -and @($laneTable.candidates | Where-Object { $_.model -eq $step -and $_.confirmed_grade -eq 'weak' }).Count) { $step = $null }
            if ($step) { $chosen = [pscustomobject]@{ model = $step; frontier = $false }; $driftApplied = $true }
            else { $alerts.Add("drift-no-alternative:$($flaggedModel):$Category`:$Lane") }
        }
        if ($driftApplied) { $ranked = @($chosen.model) + @($ranked | Where-Object { $_ -ne $chosen.model -and $flagged -notcontains $_ }) }
    }
    if ($driftApplied) { $reason += ' Drift demotion moved off a flagged model.' }
    $result = [pscustomobject]@{ model = $chosen.model; agent_alias = $(if ($Lane -eq 'claude') { Get-RouterAgentAlias -Model $chosen.model } else { $null }); category = $Category; lane = $Lane; protected = $isProtected; reason = $reason; table_source = $read.source; table_date = $read.table.generated_at; validation_error = $read.validation_error; alerts = @($alerts.ToArray()); ranked = $ranked }
    if ($SendAlerts) { Send-RouterAlerts -Alerts @($result.alerts) -ChatToStderr:$ChatToStderr | Out-Null }
    return (Complete-RouterResult -Result $result -Job $job -RosterSource default)
}

function Get-RouterPicksSnapshot {
    param([Parameter(Mandatory)][string]$TablePath)
    $picks = [System.Collections.Generic.List[object]]::new()
    foreach ($category in @(Get-RouterCategories)) {
        foreach ($lane in $(if ($category -eq 'image-generation') { @('codex') } else { @('codex','claude') })) {
            foreach ($protected in @($false,$true)) {
                $pick = Resolve-RouterModel -Category $category -Lane $lane -Protected:$protected -TablePath $TablePath -SkipModelCheck -IgnoreApproval
                $picks.Add([pscustomobject]@{ category = $category; lane = $lane; protected = $protected; model = $pick.model; reason = $pick.reason })
            }
        }
    }
    return @($picks.ToArray())
}

if ($MyInvocation.InvocationName -ne '.') {
    $resolveArgs = @{ Category = $RouterResolveCliCategory; Protected = $RouterResolveCliProtected; EscalateFrom = $RouterResolveCliEscalateFrom; Catalog = $RouterResolveCliCatalog; TablePath = $RouterResolveCliTablePath; SkipModelCheck = $RouterResolveCliSkipModelCheck; SendAlerts = $RouterResolveCliSendAlerts; ChatToStderr = $RouterResolveCliJson }
    if ($PSBoundParameters.ContainsKey('RouterResolveCliLane')) { $resolveArgs.Lane = $RouterResolveCliLane }
    $result = Resolve-RouterModel @resolveArgs
    if ($RouterResolveCliJson) { $result | ConvertTo-Json -Depth 12 -Compress } else { $result }
}
