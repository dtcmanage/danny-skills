# report-contract.ps1
# -------------------
# The worker report and continuation record contracts, dot-sourced by both chunk wrappers,
# validate-continuation.ps1, and dt-job.ps1 so every reader validates the same way.
#
# Report version 3 adds VERDICT, EVIDENCE_PATHS, and CONTINUATION_STATE to version 2. A version 2
# report is still accepted during the transition, with a 'v2' warning.
#
# A continuation record is a markdown file whose first ```json block holds the fields in
# $script:DtContinuationFields; free notes may follow the block.

$script:DtReportVerdicts = @('PASS', 'FAIL', 'BLOCKED', 'PARTIAL')
$script:DtReportHeaders = @(
    'DT_BUILD_REPORT_VERSION', 'RUN_ID', 'chunk_id', 'attempt', 'VERDICT', 'CHANGED_FILES', 'COMMANDS_AND_RESULTS',
    'EVIDENCE_PATHS', 'UNRESOLVED_BLOCKERS', 'DISCOVERED_ENHANCEMENTS', 'CONTINUATION_STATE'
)
$script:DtContinuationFields = @('run_id', 'chunk_id', 'attempt', 'completed', 'tests', 'running_jobs', 'blockers', 'authorization', 'next_step')
$script:DtContinuationTestFields = @('command', 'exit_code', 'evidence_path', 'tree_hash', 'recorded_utc')

function Test-DtContractList {
    param($Value)
    return ($null -ne $Value -and $Value -is [System.Collections.IList] -and $Value -isnot [string])
}

function Test-DtContractInt {
    param($Value)
    return ($Value -is [int] -or $Value -is [long])
}

function Get-DtContinuationRecord {
    # The parsed record and its errors. -RunId/-ChunkId, when given, must match the record.
    param([Parameter(Mandatory)][string]$Path, [string]$RunId, [string]$ChunkId)
    $errors = New-Object System.Collections.Generic.List[string]
    $record = $null
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $errors.Add("continuation record not found: $Path") | Out-Null
        return [pscustomobject]@{ record = $null; errors = @($errors) }
    }
    $text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path)
    $block = [regex]::Match($text, '(?ms)^[ \t]*```json[ \t]*\r?\n(.*?)^[ \t]*```')
    if (-not $block.Success) {
        $errors.Add('continuation record has no ```json block') | Out-Null
        return [pscustomobject]@{ record = $null; errors = @($errors) }
    }
    try { $record = $block.Groups[1].Value | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch {
        $errors.Add("continuation record json does not parse: $($_.Exception.Message)") | Out-Null
        return [pscustomobject]@{ record = $null; errors = @($errors) }
    }
    if ($record -isnot [System.Collections.IDictionary]) {
        $errors.Add('continuation record json is not an object') | Out-Null
        return [pscustomobject]@{ record = $null; errors = @($errors) }
    }
    foreach ($field in $script:DtContinuationFields) {
        if (-not $record.Contains($field)) { $errors.Add("continuation record missing field $field") | Out-Null }
    }
    foreach ($field in @('run_id', 'chunk_id', 'next_step')) {
        if ($record.Contains($field) -and ($record[$field] -isnot [string] -or -not $record[$field])) { $errors.Add("continuation field $field must be a non-empty string") | Out-Null }
    }
    if ($record.Contains('attempt') -and -not ((Test-DtContractInt $record['attempt']) -and $record['attempt'] -ge 1)) { $errors.Add('continuation field attempt must be an integer of at least 1') | Out-Null }
    foreach ($field in @('completed', 'running_jobs')) {
        if (-not $record.Contains($field)) { continue }
        if (-not (Test-DtContractList $record[$field]) -or @($record[$field] | Where-Object { $_ -isnot [string] }).Count -gt 0) { $errors.Add("continuation field $field must be a list of strings") | Out-Null }
    }
    if ($record.Contains('blockers') -and -not (Test-DtContractList $record['blockers'])) { $errors.Add('continuation field blockers must be a list') | Out-Null }
    if ($record.Contains('authorization') -and -not ((Test-DtContractList $record['authorization']) -or $record['authorization'] -is [System.Collections.IDictionary])) { $errors.Add('continuation field authorization must be a list or an object') | Out-Null }
    if ($record.Contains('tests')) {
        if (-not (Test-DtContractList $record['tests'])) { $errors.Add('continuation field tests must be a list') | Out-Null }
        else {
            $i = 0
            foreach ($test in $record['tests']) {
                if ($test -isnot [System.Collections.IDictionary]) { $errors.Add("continuation tests[$i] must be an object") | Out-Null; $i++; continue }
                foreach ($field in $script:DtContinuationTestFields) {
                    if (-not $test.Contains($field)) { $errors.Add("continuation tests[$i] missing field $field") | Out-Null }
                }
                if ($test.Contains('command') -and ($test['command'] -isnot [string] -or -not $test['command'])) { $errors.Add("continuation tests[$i].command must be a non-empty string") | Out-Null }
                if ($test.Contains('exit_code') -and -not (Test-DtContractInt $test['exit_code'])) { $errors.Add("continuation tests[$i].exit_code must be an integer") | Out-Null }
                if ($test.Contains('evidence_path') -and $test['evidence_path'] -isnot [string]) { $errors.Add("continuation tests[$i].evidence_path must be a string") | Out-Null }
                if ($test.Contains('tree_hash') -and ($test['tree_hash'] -isnot [string] -or $test['tree_hash'] -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$')) { $errors.Add("continuation tests[$i].tree_hash must be a git tree sha") | Out-Null }
                if ($test.Contains('recorded_utc')) {
                    $stamp = [datetimeoffset]::MinValue
                    $value = $test['recorded_utc']
                    # -AsHashtable may already have read an ISO stamp as a DateTime.
                    if (-not ($value -is [datetime] -or ($value -is [string] -and [datetimeoffset]::TryParse($value, [ref]$stamp)))) { $errors.Add("continuation tests[$i].recorded_utc must be a timestamp") | Out-Null }
                }
                $i++
            }
        }
    }
    if ($RunId -and $record.Contains('run_id') -and [string]$record['run_id'] -cne $RunId) { $errors.Add("continuation run_id '$($record['run_id'])' does not match $RunId") | Out-Null }
    if ($ChunkId -and $record.Contains('chunk_id') -and [string]$record['chunk_id'] -cne $ChunkId) { $errors.Add("continuation chunk_id '$($record['chunk_id'])' does not match $ChunkId") | Out-Null }
    return [pscustomobject]@{ record = $record; errors = @($errors) }
}

function Get-DtReportSection {
    # A report field's entries: an inline value after the colon, then the following lines up to the next
    # field header, a code fence, or a blank line after the first entry. $null when the header is absent.
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Name)
    $lines = $Text -split '\r?\n'
    $headerPattern = '^\s*(?:' + (($script:DtReportHeaders | ForEach-Object { [regex]::Escape($_) }) -join '|') + '):'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match($lines[$i], '^\s*' + [regex]::Escape($Name) + ':(.*)$')
        if (-not $m.Success) { continue }
        $entries = New-Object System.Collections.Generic.List[string]
        if ($m.Groups[1].Value.Trim()) { $entries.Add($m.Groups[1].Value.Trim()) | Out-Null }
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $line = $lines[$j]
            if ($line -cmatch $headerPattern -or $line -match '^\s*```') { break }
            if (-not $line.Trim()) { if ($entries.Count -gt 0) { break } else { continue } }
            $entries.Add($line.Trim()) | Out-Null
        }
        return , @($entries)
    }
    return $null
}

function Get-ReportShapeResult {
    # Report shape errors plus the report version and its transition warning ('v2' or $null).
    param([string]$Text, [string]$RunId, [string]$ChunkId, [int]$ExpectedAttempt)
    $errors = New-Object System.Collections.Generic.List[string]
    $version = $null
    $warning = $null
    $versionMatch = [regex]::Match($Text, '(?m)^DT_BUILD_REPORT_VERSION:\s*([23])\s*$')
    if ($versionMatch.Success) { $version = [int]$versionMatch.Groups[1].Value }
    else { $errors.Add('missing or mismatched DT_BUILD_REPORT_VERSION') | Out-Null }
    if ($version -eq 2) { $warning = 'v2' }
    $required = @(
        @{ label = 'RUN_ID'; pattern = '(?m)^RUN_ID:\s*' + [regex]::Escape($RunId) + '\s*$' },
        @{ label = 'chunk_id'; pattern = '(?m)^chunk_id:\s*' + [regex]::Escape($ChunkId) + '\s*$' },
        @{ label = 'attempt'; pattern = '(?m)^attempt:\s*' + $ExpectedAttempt + '\s*$' },
        @{ label = 'CHANGED_FILES'; pattern = '(?m)^CHANGED_FILES:\s*$' },
        @{ label = 'COMMANDS_AND_RESULTS'; pattern = '(?m)^COMMANDS_AND_RESULTS:\s*$' },
        @{ label = 'UNRESOLVED_BLOCKERS'; pattern = '(?m)^UNRESOLVED_BLOCKERS:\s*$' },
        @{ label = 'DISCOVERED_ENHANCEMENTS'; pattern = '(?m)^DISCOVERED_ENHANCEMENTS:\s*$' }
    )
    foreach ($entry in $required) {
        if ($Text -notmatch $entry.pattern) { $errors.Add("missing or mismatched $($entry.label)") | Out-Null }
    }
    if ($version -eq 3) {
        $verdict = Get-DtReportSection -Text $Text -Name 'VERDICT'
        if ($null -eq $verdict -or @($verdict).Count -eq 0) { $errors.Add('missing VERDICT') | Out-Null }
        elseif ($script:DtReportVerdicts -cnotcontains $verdict[0]) { $errors.Add("VERDICT '$($verdict[0])' is not one of $($script:DtReportVerdicts -join ', ')") | Out-Null }

        $evidence = Get-DtReportSection -Text $Text -Name 'EVIDENCE_PATHS'
        if ($null -eq $evidence -or @($evidence).Count -eq 0) { $errors.Add('missing EVIDENCE_PATHS') | Out-Null }
        elseif (-not (@($evidence).Count -eq 1 -and $evidence[0] -ceq 'NONE')) {
            foreach ($path in $evidence) {
                if (-not [System.IO.Path]::IsPathFullyQualified($path) -or -not (Test-Path -LiteralPath $path)) { $errors.Add("EVIDENCE_PATHS entry does not exist as an absolute path: $path") | Out-Null }
            }
        }

        $continuation = Get-DtReportSection -Text $Text -Name 'CONTINUATION_STATE'
        if ($null -eq $continuation -or @($continuation).Count -eq 0) { $errors.Add('missing CONTINUATION_STATE') | Out-Null }
        elseif ($continuation[0] -cne 'NONE') {
            $path = $continuation[0]
            if (-not [System.IO.Path]::IsPathFullyQualified($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { $errors.Add("CONTINUATION_STATE does not exist as an absolute path: $path") | Out-Null }
            else {
                foreach ($problem in (Get-DtContinuationRecord -Path $path -RunId $RunId -ChunkId $ChunkId).errors) { $errors.Add("CONTINUATION_STATE invalid: $problem") | Out-Null }
            }
        }
    }
    return [pscustomobject]@{ errors = @($errors); version = $version; warning = $warning }
}
