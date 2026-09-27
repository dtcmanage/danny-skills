param(
    [string]$Category,
    [string]$Lane,
    [switch]$Protected,
    [string]$EscalateFrom,
    [object]$Catalog,
    [string]$TablePath,
    [switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot '../resolve-codex-model.ps1')

function Get-RouterFailureProbability {
    param([object]$Candidate)
    if ($Candidate.pass_samples -ge 10 -and $null -ne $Candidate.pass_rate) { return (1.0 - [double]$Candidate.pass_rate) }
    if ($Candidate.grade -eq 'strong') { return 0.10 }
    return 0.25
}

function Resolve-RouterModel {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][ValidateSet('codex','claude')][string]$Lane,
        [switch]$Protected,
        [string]$EscalateFrom,
        [object]$Catalog,
        [string]$TablePath
    )
    if ($Category -notin @(Get-RouterCategories)) { throw "CATEGORY: Unknown category '$Category'" }
    if ($Category -eq 'image-generation' -and $Lane -ne 'codex') { throw 'LANE: image-generation has only codex' }
    $read = Read-RouterTable -TablePath $TablePath
    $laneTable = $read.table.categories.$Category.$Lane
    $alerts = [System.Collections.Generic.List[string]]::new()
    $all = @($laneTable.candidates | Sort-Object strength_rank | Where-Object { $_.grade -in @('strong','capable') -and @($_.citations | Where-Object { $_.independent -eq $true }).Count -gt 0 })
    if ($Lane -eq 'codex') {
        $parsed = Get-CodexModelCatalog -Catalog $Catalog
        $selectable = @(@($parsed.models) | Where-Object { $_.PSObject.Properties['slug'] -and $_.PSObject.Properties['visibility'] -and $_.visibility -eq 'list' } | ForEach-Object { [string]$_.slug })
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($candidate in $all) {
            if ($selectable -contains $candidate.model) { $kept.Add($candidate) }
            else { $alerts.Add("UNSELECTABLE_CODEX_MODEL: $($candidate.model)") }
        }
        $all = @($kept.ToArray())
    }
    $eligible = $all
    $nonfrontier = @($eligible | Where-Object { -not $_.frontier })
    if ($nonfrontier.Count -gt 0) { $eligible = $nonfrontier }
    $isProtected = [bool]$Protected -or $Category -eq 'long-form-writing'
    if ($eligible.Count -eq 0) {
        $alerts.Add("NO_ELIGIBLE_MODEL: $Category/$Lane; using fallback $($laneTable.fallback)")
        return [pscustomobject]@{ model = $laneTable.fallback; category = $Category; lane = $Lane; protected = $isProtected; reason = 'No eligible candidate; lane fallback.'; table_source = $read.source; table_date = $read.table.generated_at; alerts = @($alerts.ToArray()); ranked = @() }
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
                $next = if ($index -gt 0) { $byStrength[$index - 1] } else { $candidate }
                $firstFailure = Get-RouterFailureProbability -Candidate $candidate
                $secondFailure = Get-RouterFailureProbability -Candidate $next
                $scores[$candidate.model] = [double]$candidate.est_burn + $firstFailure * [double]$next.est_burn + $firstFailure * $secondFailure * [double]$byStrength[0].est_burn
            }
            foreach ($candidate in $byStrength) {
                $insert = $rankedCandidates.Count
                for ($i = 0; $i -lt $rankedCandidates.Count; $i++) {
                    $other = $rankedCandidates[$i]
                    $a = [double]$scores[$candidate.model]; $b = [double]$scores[$other.model]
                    $within = [math]::Abs($a - $b) -le 0.10 * [math]::Min($a, $b)
                    $before = if ($within) {
                        if ($null -ne $candidate.est_seconds -and $null -ne $other.est_seconds -and [double]$candidate.est_seconds -ne [double]$other.est_seconds) { [double]$candidate.est_seconds -lt [double]$other.est_seconds }
                        else { $candidate.strength_rank -lt $other.strength_rank }
                    } else { $a -lt $b }
                    if ($before) { $insert = $i; break }
                }
                $rankedCandidates.Insert($insert, $candidate)
            }
        }
    }
    $ranked = @($rankedCandidates.ToArray() | ForEach-Object { $_.model })
    if ($EscalateFrom) {
        $from = @($byStrength | Where-Object { $_.model -eq $EscalateFrom })
        if ($from.Count -eq 0) { $chosen = $byStrength[0]; $reason = 'Escalation source not eligible; strongest eligible candidate.' }
        else {
            $stronger = @($byStrength | Where-Object { $_.strength_rank -lt $from[0].strength_rank })
            if ($stronger.Count) { $chosen = $stronger[-1]; $reason = 'Escalation: next stronger eligible candidate.' }
            else { $chosen = $byStrength[0]; $reason = 'Escalation: no stronger eligible candidate; strongest retained.' }
        }
    } elseif ($isProtected) { $chosen = $byStrength[0]; $reason = 'Protected: strongest eligible candidate.' }
    elseif (@($byStrength | Where-Object { $null -eq $_.est_burn }).Count) { $chosen = $rankedCandidates[0]; $reason = 'Uncalibrated burn: strength-rank order.' }
    else { $chosen = $rankedCandidates[0]; $reason = 'Lowest expected retry-adjusted burn; 10% time tie-break.' }
    if ($chosen.frontier) { $reason += ' No non-frontier eligible.' }
    return [pscustomobject]@{ model = $chosen.model; category = $Category; lane = $Lane; protected = $isProtected; reason = $reason; table_source = $read.source; table_date = $read.table.generated_at; alerts = @($alerts.ToArray()); ranked = $ranked }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Resolve-RouterModel -Category $Category -Lane $Lane -Protected:$Protected -EscalateFrom $EscalateFrom -Catalog $Catalog -TablePath $TablePath
    if ($Json) { $result | ConvertTo-Json -Depth 12 -Compress } else { $result }
}
