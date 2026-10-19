function Test-ExternalApiContracts {
    param([string]$RoadmapPath, [string]$Text, [string]$MilestoneId, [string]$WorkingTree,
        [bool]$RunTests, [int]$TimeoutMs)
    $blockers = [Collections.Generic.List[string]]::new()
    $results = [Collections.Generic.List[object]]::new()
    $residuals = [Collections.Generic.List[string]]::new()
    $rows = @(Get-CoverageRows $Text 'External API Contracts' | Where-Object { $_['milestone-id'] -eq $MilestoneId })
    foreach ($row in $rows) {
        $service = $row['service']
        $samples = @($row['samples'] -split ';' | ForEach-Object { $_.Trim().Trim('`') } | Where-Object { $_ } | Select-Object -Unique)
        if (-not $service -or $samples.Count -lt 2) { $blockers.Add("API_SAMPLES_REQUIRED: $MilestoneId/$service needs saved auth and endpoint responses") }
        foreach ($sample in $samples) {
            $samplePath = Resolve-CoveragePath $RoadmapPath $sample
            if (-not (Test-Path -LiteralPath $samplePath -PathType Leaf) -or (Get-Item -LiteralPath $samplePath).Length -eq 0) {
                $blockers.Add("API_SAMPLE_MISSING: $MilestoneId/$service -> $sample")
            }
        }
        if ($row['credentials'] -eq 'unavailable') {
            $reason = $row['residual']
            if (-not $reason -or $reason -eq '-') { $reason = 'missing named residual; record credential source attempted and the owner/recheck gate' }
            $residual = "API_CREDENTIALS_UNAVAILABLE: $MilestoneId/${service}: $reason"
            $residuals.Add($residual); $blockers.Add($residual)
            continue
        }
        if ($row['credentials'] -ne 'available') { $blockers.Add("API_CREDENTIAL_STATE_REQUIRED: $MilestoneId/$service"); continue }
        foreach ($kind in @('auth-check', 'read-check')) {
            $commands = Extract-NamedArtifacts -Text ([string]$row[$kind])
            if (@($commands.commands).Count -eq 0) { $blockers.Add("API_LIVE_CHECK_REQUIRED: $MilestoneId/$service/$kind"); continue }
            if ($RunTests) {
                foreach ($command in $commands.commands) {
                    $r = Invoke-NamedCommand -WorkingTree $WorkingTree -Command $command -TimeoutMs $TimeoutMs -ExclusiveReason ''
                    $r | Add-Member -NotePropertyName check_id -NotePropertyValue "api-$service-$kind"
                    $results.Add($r)
                    if ($r.exit_code -ne 0) { $blockers.Add("API_LIVE_CONTRACT_FAILED: $MilestoneId/$service/$kind (exit=$($r.exit_code))") }
                }
            }
        }
    }
    return [pscustomobject]@{ blockers = $blockers.ToArray(); command_results = $results.ToArray(); residuals = $residuals.ToArray() }
}
