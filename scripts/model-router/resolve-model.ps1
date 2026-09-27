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

function Resolve-RouterModel {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][ValidateSet('codex','claude')][string]$Lane,
        [switch]$Protected,
        [string]$EscalateFrom,
        [object]$Catalog,
        [string]$TablePath,
        [switch]$SkipModelCheck,
        [switch]$SendAlerts
    )
    if ($Category -notin @(Get-RouterCategories)) { throw "CATEGORY: Unknown category '$Category'" }
    if ($Category -eq 'image-generation' -and $Lane -ne 'codex') { throw 'LANE: image-generation has only codex' }
    $alerts = [System.Collections.Generic.List[string]]::new()
    if (-not $SkipModelCheck) {
        try {
            $check = Invoke-RouterModelCheck
            foreach ($alert in @($check.alerts)) { $alerts.Add([string]$alert) }
            if (@($check.new_models).Count -gt 0) {
                try { [void](Start-RouterResearchDetached) }
                catch { $alerts.Add('research-launch-error') }
            }
        } catch { $alerts.Add("catalog-check-error:resolver: $($_.Exception.Message)") }
    }
    $read = Read-RouterTable -TablePath $TablePath
    $laneTable = $read.table.categories.$Category.$Lane
    if ($read.source -eq 'seed') { $alerts.Add('router-seed-table-in-use') }
    if ($read.validation_error) { $alerts.Add("router-live-table-invalid: $($read.validation_error)") }
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
    $isProtected = [bool]$Protected -or $Category -eq 'long-form-writing'
    if ($eligible.Count -eq 0) {
        if ($read.table.source -ne 'seed') { $alerts.Add("no-eligible:$Category`:$Lane") }
        $result = [pscustomobject]@{ model = $laneTable.fallback; category = $Category; lane = $Lane; protected = $isProtected; reason = 'No eligible candidate; lane fallback.'; table_source = $read.source; table_date = $read.table.generated_at; validation_error = $read.validation_error; alerts = @($alerts.ToArray()); ranked = @() }
        if ($SendAlerts) { Send-RouterAlerts -Alerts $result.alerts | Out-Null }
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
    if ($chosen.frontier) { $reason += ' No non-frontier eligible.' }
    $result = [pscustomobject]@{ model = $chosen.model; category = $Category; lane = $Lane; protected = $isProtected; reason = $reason; table_source = $read.source; table_date = $read.table.generated_at; validation_error = $read.validation_error; alerts = @($alerts.ToArray()); ranked = $ranked }
    if ($SendAlerts) { Send-RouterAlerts -Alerts $result.alerts | Out-Null }
    return $result
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Resolve-RouterModel -Category $RouterResolveCliCategory -Lane $RouterResolveCliLane -Protected:$RouterResolveCliProtected -EscalateFrom $RouterResolveCliEscalateFrom -Catalog $RouterResolveCliCatalog -TablePath $RouterResolveCliTablePath -SkipModelCheck:$RouterResolveCliSkipModelCheck -SendAlerts:$RouterResolveCliSendAlerts
    if ($RouterResolveCliJson) { $result | ConvertTo-Json -Depth 12 -Compress } else { $result }
}
