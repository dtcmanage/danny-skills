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
. (Join-Path $PSScriptRoot '../resolve-codex-model.ps1')
. (Join-Path $PSScriptRoot 'check-new-models.ps1')
. (Join-Path $PSScriptRoot 'send-router-alert.ps1')
. (Join-Path $PSScriptRoot 'run-router-research.ps1')

function Get-RouterFailureProbability {
    param([object]$Candidate)
    if ($Candidate.pass_samples -ge 10 -and $null -ne $Candidate.pass_rate) { return (1.0 - [double]$Candidate.pass_rate) }
    if ($Candidate.grade -eq 'strong') { return 0.10 }
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

function Resolve-RouterBridgeModel {
    # Bridge mode (source 'seed', no research table yet): ignore eligibility and route exactly
    # as dt-build did before the router, from references/model-router/bridge-map.json.
    # Escalation moves one rung up the lane ladder; a frontier rung is reachable only that way.
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Lane,
        [bool]$IsProtected,
        [string]$EscalateFrom,
        [object]$Catalog,
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$Alerts
    )
    $map = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/bridge-map.json') -Raw | ConvertFrom-Json -Depth 10
    $laneMap = $map.lanes.$Lane
    $mapped = [string]$laneMap.categories.$Category
    if (-not $mapped) { throw "BRIDGE_MAP: no $Category/$Lane mapping" }
    if ($IsProtected) {
        $protectedPick = [string]$laneMap.protected
        if (-not $protectedPick) { throw "BRIDGE_MAP: no protected pick for $Lane" }
        $mapped = $protectedPick
    }
    $ladder = @($laneMap.ladder)
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
                if ($ladder[$i].frontier -and -not $EscalateFrom) { continue } # never a frontier first pick
                if (Test-RouterCodexSelectable -ParsedCatalog $parsed -Model $ids[$i]) { $replacement = $ids[$i]; break }
            }
            if ($replacement) { $mapping += "; $model is not selectable, next ladder rung $replacement"; $model = $replacement }
            else { $mapping += "; $model is not selectable and no ladder rung is" }
        }
    }
    return [pscustomobject]@{ model = $model; reason = "bridge mode (no research table yet): $mapping" }
}

function Resolve-RouterModel {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][ValidateSet('codex','claude')][string]$Lane,
        [switch]$Protected,
        [string]$EscalateFrom,
        [object]$Catalog,
        [string]$TablePath,
        [switch]$SkipModelCheck,
        [switch]$SendAlerts,
        [switch]$ChatToStderr
    )
    if ($Category -notin @(Get-RouterCategories)) { throw "CATEGORY: Unknown category '$Category'" }
    if ($Category -eq 'image-generation' -and $Lane -ne 'codex') { throw 'LANE: image-generation has only codex' }
    $alerts = [System.Collections.Generic.List[string]]::new()
    if (-not $SkipModelCheck) {
        try {
            $check = Invoke-RouterModelCheck
            foreach ($alert in @($check.alerts)) { $alerts.Add([string]$alert) }
        } catch { $alerts.Add("catalog-check-error:resolver: $($_.Exception.Message)") }
    }
    $read = Read-RouterTable -TablePath $TablePath
    $laneTable = $read.table.categories.$Category.$Lane
    if ($read.table.source -eq 'seed') { $alerts.Add('router-seed-table-in-use') }
    if ($read.validation_error) { $alerts.Add("router-live-table-invalid: $($read.validation_error)") }
    $isProtected = [bool]$Protected -or $Category -eq 'long-form-writing'
    if ($read.table.source -eq 'seed') {
        $bridge = Resolve-RouterBridgeModel -Category $Category -Lane $Lane -IsProtected $isProtected -EscalateFrom $EscalateFrom -Catalog $Catalog -Alerts $alerts
        $result = [pscustomobject]@{ model = $bridge.model; agent_alias = $(if ($Lane -eq 'claude') { Get-RouterAgentAlias -Model $bridge.model } else { $null }); category = $Category; lane = $Lane; protected = $isProtected; reason = $bridge.reason; table_source = $read.source; table_date = $read.table.generated_at; validation_error = $read.validation_error; alerts = @($alerts.ToArray()); ranked = @($bridge.model) }
        if ($SendAlerts) { Send-RouterAlerts -Alerts $result.alerts -ChatToStderr:$ChatToStderr | Out-Null }
        return $result
    }
    $all = @($laneTable.candidates | Sort-Object strength_rank | Where-Object { $_.grade -in @('strong','capable') -and @($_.citations | Where-Object { $_.independent -eq $true }).Count -gt 0 })
    if ($Lane -eq 'codex' -and $Category -ne 'image-generation') {
        $parsed = Get-CodexModelCatalog -Catalog $Catalog
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($candidate in $all) {
            if (Test-RouterCodexSelectable -ParsedCatalog $parsed -Model $candidate.model) { $kept.Add($candidate) }
            else { $alerts.Add("UNSELECTABLE_CODEX_MODEL: $($candidate.model)") }
        }
        $all = @($kept.ToArray())
        if (-not (Test-RouterCodexSelectable -ParsedCatalog $parsed -Model $laneTable.fallback)) {
            $alerts.Add("fallback_unselectable: $($laneTable.fallback)")
        }
    }
    $eligible = $all
    $nonfrontier = @($eligible | Where-Object { -not $_.frontier })
    if ($nonfrontier.Count -gt 0) { $eligible = $nonfrontier }
    if ($eligible.Count -eq 0) {
        if ($read.table.source -ne 'seed') { $alerts.Add("no-eligible:$Category`:$Lane") }
        $result = [pscustomobject]@{ model = $laneTable.fallback; agent_alias = $(if ($Lane -eq 'claude') { Get-RouterAgentAlias -Model $laneTable.fallback } else { $null }); category = $Category; lane = $Lane; protected = $isProtected; reason = 'No eligible candidate; lane fallback.'; table_source = $read.source; table_date = $read.table.generated_at; validation_error = $read.validation_error; alerts = @($alerts.ToArray()); ranked = @() }
        if ($SendAlerts) { Send-RouterAlerts -Alerts $result.alerts -ChatToStderr:$ChatToStderr | Out-Null }
        return $result
    }
    $byStrength = @($eligible | Sort-Object strength_rank)
    $rankedCandidates = [System.Collections.Generic.List[object]]::new()
    if ($isProtected -or $EscalateFrom) {
        foreach ($candidate in $byStrength) { $rankedCandidates.Add($candidate) }
    } else {
        $knownBurn = @($byStrength | Where-Object { $null -ne $_.est_burn })
        if ($knownBurn.Count -ne $byStrength.Count) {
            foreach ($candidate in $byStrength) { $rankedCandidates.Add($candidate) }
        } else {
            $scores = @{}
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
    $driftApplied = $false
    $flags = @(Read-RouterJsonArray -Path (Join-Path (Get-RouterStateDir) 'drift-flags.json') | Where-Object { $_.category -eq $Category -and $_.lane -eq $Lane })
    if ($isProtected -and -not $EscalateFrom) {
        foreach ($flag in $flags) {
            if ($byStrength[0].model -eq $flag.model) { $alerts.Add("drift-no-alternative:$($flag.model):$Category`:$Lane") }
        }
    }
    if (-not $EscalateFrom -and -not $isProtected) {
        foreach ($flag in $flags) {
            $position = -1
            for ($i = 0; $i -lt $rankedCandidates.Count; $i++) { if ($rankedCandidates[$i].model -eq $flag.model) { $position = $i; break } }
            if ($position -lt 0) { continue }
            if ($position + 1 -ge $rankedCandidates.Count) { $alerts.Add("drift-no-alternative:$($flag.model):$Category`:$Lane"); continue }
            $moveUp = $rankedCandidates[$position + 1]
            if ($moveUp.grade -notin @('strong','capable') -or -not @($moveUp.citations | Where-Object independent).Count) { $alerts.Add("drift-no-alternative:$($flag.model):$Category`:$Lane"); continue }
            $rankedCandidates[$position + 1] = $rankedCandidates[$position]
            $rankedCandidates[$position] = $moveUp
            if ($position -eq 0) { $driftApplied = $true }
        }
    }
    $ranked = @($rankedCandidates.ToArray() | ForEach-Object { $_.model })
    if ($EscalateFrom) {
        $from = @($all | Where-Object { $_.model -eq $EscalateFrom })
        if ($from.Count -eq 0) { $chosen = $byStrength[0]; $reason = 'Escalation source not eligible; strongest eligible candidate.' }
        else {
            $stronger = @($all | Where-Object { $_.strength_rank -lt $from[0].strength_rank } | Sort-Object strength_rank)
            if ($stronger.Count) { $chosen = $stronger[-1]; $reason = 'Escalation: next stronger eligible candidate.' }
            else { $chosen = $from[0]; $reason = 'Escalation: no stronger eligible candidate; same model retained.' }
        }
    } elseif ($isProtected) { $chosen = $byStrength[0]; $reason = 'Protected: strongest eligible candidate.' }
    elseif (@($byStrength | Where-Object { $null -eq $_.est_burn }).Count) { $chosen = $rankedCandidates[0]; $reason = 'Uncalibrated burn: strength-rank order.' }
    else { $chosen = $rankedCandidates[0]; $reason = 'Lowest expected retry-adjusted burn; 10% time tie-break.' }
    if ($driftApplied) { $reason += ' Drift demotion moved a flagged model down one eligible position.' }
    if ($chosen.frontier) { $reason += ' No non-frontier eligible.' }
    $result = [pscustomobject]@{ model = $chosen.model; agent_alias = $(if ($Lane -eq 'claude') { Get-RouterAgentAlias -Model $chosen.model } else { $null }); category = $Category; lane = $Lane; protected = $isProtected; reason = $reason; table_source = $read.source; table_date = $read.table.generated_at; validation_error = $read.validation_error; alerts = @($alerts.ToArray()); ranked = $ranked }
    if ($SendAlerts) { Send-RouterAlerts -Alerts $result.alerts -ChatToStderr:$ChatToStderr | Out-Null }
    return $result
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Resolve-RouterModel -Category $RouterResolveCliCategory -Lane $RouterResolveCliLane -Protected:$RouterResolveCliProtected -EscalateFrom $RouterResolveCliEscalateFrom -Catalog $RouterResolveCliCatalog -TablePath $RouterResolveCliTablePath -SkipModelCheck:$RouterResolveCliSkipModelCheck -SendAlerts:$RouterResolveCliSendAlerts -ChatToStderr:$RouterResolveCliJson
    if ($RouterResolveCliJson) { $result | ConvertTo-Json -Depth 12 -Compress } else { $result }
}
