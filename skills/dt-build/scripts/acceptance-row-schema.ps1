# Shared acceptance-row schema for <run-folder>/acceptance-rows.jsonl.
# Dot-sourced by append-acceptance-row.ps1 (write-time validation) and
# build-acceptance-ledger.ps1 (read-time classification). Schema lives in
# references/acceptance-contract.md, "Acceptance row schema".

function Get-AcceptanceRowValue {
    param($Row, [string]$Name)
    if ($null -eq $Row -or -not $Row.PSObject.Properties[$Name]) { return $null }
    return $Row.$Name
}

function Test-AcceptanceRowLegacy {
    # A row written before `status` was part of the documented writer contract.
    # Its stored fields are kept verbatim; readers must not guess a verdict from it.
    param($Row)
    return $null -ne $Row -and -not $Row.PSObject.Properties['status']
}

function Get-AcceptanceRowSchemaErrors {
    param($Row)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Row) { $errors.Add('row is empty') | Out-Null; return @($errors) }
    $mid = [string](Get-AcceptanceRowValue $Row 'milestone_id')
    if ([string]::IsNullOrWhiteSpace($mid)) { $errors.Add('milestone_id is required') | Out-Null }
    if ([string](Get-AcceptanceRowValue $Row 'commit_sha') -notmatch '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$') {
        $errors.Add('commit_sha must be a full 40/64-hex object id') | Out-Null
    }
    $accepted = Get-AcceptanceRowValue $Row 'accepted'
    if ($accepted -isnot [bool]) { $errors.Add('accepted must be true or false') | Out-Null }
    $status = [string](Get-AcceptanceRowValue $Row 'status')
    if ([string]::IsNullOrWhiteSpace($status)) { $errors.Add('status is required (PASS, APPROVED_DOWNGRADE or BLOCKED)') | Out-Null }
    elseif ($status -cnotin @('PASS', 'APPROVED_DOWNGRADE', 'BLOCKED')) { $errors.Add("status '$status' is not PASS, APPROVED_DOWNGRADE or BLOCKED") | Out-Null }
    if ($accepted -is [bool]) {
        if ($accepted -and $status -cnotin @('PASS', 'APPROVED_DOWNGRADE')) { $errors.Add('accepted true requires status PASS or APPROVED_DOWNGRADE') | Out-Null }
        if (-not $accepted -and $status -cin @('PASS', 'APPROVED_DOWNGRADE')) { $errors.Add("status $status requires accepted true") | Out-Null }
    }
    $tests = [string](Get-AcceptanceRowValue $Row 'tests')
    $checks = @(Get-AcceptanceRowValue $Row 'checks' | Where-Object { $null -ne $_ })
    if ([string]::IsNullOrWhiteSpace($tests) -and $checks.Count -eq 0) {
        $errors.Add('tests text or checks records are required') | Out-Null
    }
    $commands = Get-AcceptanceRowValue $Row 'command_results'
    if ($null -eq $commands -or @($commands).Count -eq 0) { $errors.Add('command_results is required') | Out-Null }
    elseif ($status -ceq 'PASS' -and @($commands | Where-Object { $_.exit_code -ne 0 }).Count -gt 0) {
        $errors.Add('status PASS requires every command_results exit_code to be 0') | Out-Null
    }
    $hasId = -not [string]::IsNullOrWhiteSpace([string](Get-AcceptanceRowValue $Row 'dispatch_id'))
    $hasPath = -not [string]::IsNullOrWhiteSpace([string](Get-AcceptanceRowValue $Row 'provenance_path'))
    if ($hasId -ne $hasPath) { $errors.Add('dispatch_id and provenance_path must be recorded together') | Out-Null }
    return @($errors)
}

function Get-LegacyRowEvidenceNote {
    # Describe what a legacy row and its milestone's original gate output say,
    # without converting either into an acceptance verdict.
    param($Row, [string]$RunFolder, [string]$MilestoneId)
    $missing = @(@('status', 'tests/checks') | Where-Object {
        if ($_ -eq 'status') { -not $Row.PSObject.Properties['status'] }
        else { -not $Row.PSObject.Properties['tests'] -and -not $Row.PSObject.Properties['checks'] }
    })
    $parts = @("record incomplete: legacy acceptance row lacks $($missing -join ', '); historical acceptance is not inferred")
    $parts += "row says accepted=$([string](Get-AcceptanceRowValue $Row 'accepted'))"
    if (-not $RunFolder) { return ($parts -join ' · ') }
    $gatePath = Join-Path (Join-Path (Join-Path $RunFolder 'milestones') $MilestoneId) 'acceptance.json'
    if (-not (Test-Path -LiteralPath $gatePath)) { $parts += 'no original gate output at milestones/' + $MilestoneId + '/acceptance.json'; return ($parts -join ' · ') }
    try { $gate = Get-Content -LiteralPath $gatePath -Raw | ConvertFrom-Json -Depth 40 -DateKind String }
    catch { $parts += 'original gate output unreadable'; return ($parts -join ' · ') }
    $rowId = [string](Get-AcceptanceRowValue $Row 'dispatch_id')
    $gateId = [string](Get-AcceptanceRowValue $gate 'dispatch_id')
    $hash = (Get-FileHash -LiteralPath $gatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $match = if ($rowId -and $rowId -ceq $gateId) { 'dispatch matches' } else { 'dispatch does NOT match' }
    $parts += "original gate output milestones/$MilestoneId/acceptance.json status=$([string](Get-AcceptanceRowValue $gate 'status')) ($match; sha256 $($hash.Substring(0,12)))"
    $parts += 'append a schema-valid row via append-acceptance-row.ps1 to resolve'
    return ($parts -join ' · ')
}
