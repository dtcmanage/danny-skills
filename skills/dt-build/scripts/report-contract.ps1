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
# How a worker computes a test's tree_hash; named in the error when the field is missing or malformed.
$script:DtContractTreeHashHint = 'compute it with: pwsh -NoProfile -File "' + (Join-Path $PSScriptRoot 'dt-job.ps1') + '" tree-hash -WorkingTree "<worktree>"'

function Test-DtContractList {
    param($Value)
    return ($null -ne $Value -and $Value -is [System.Collections.IList] -and $Value -isnot [string])
}

function Test-DtContractInt {
    param($Value)
    return ($Value -is [int] -or $Value -is [long])
}

function Test-DtContractLocalPath {
    # An absolute local path. Relative paths and UNC or device paths (\\server\share, //server/share) are
    # rejected before any file system call, so a worker-supplied path never opens a network connection.
    param([string]$Path)
    if (-not $Path -or $Path -match '^[\\/]{2}') { return $false }
    return [System.IO.Path]::IsPathFullyQualified($Path)
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
                    if (-not $test.Contains($field)) {
                        $hint = if ($field -eq 'tree_hash') { "; $($script:DtContractTreeHashHint)" } else { '' }
                        $errors.Add("continuation tests[$i] missing field $field$hint") | Out-Null
                    }
                }
                if ($test.Contains('command') -and ($test['command'] -isnot [string] -or -not $test['command'])) { $errors.Add("continuation tests[$i].command must be a non-empty string") | Out-Null }
                if ($test.Contains('exit_code') -and -not (Test-DtContractInt $test['exit_code'])) { $errors.Add("continuation tests[$i].exit_code must be an integer") | Out-Null }
                if ($test.Contains('evidence_path') -and $test['evidence_path'] -isnot [string]) { $errors.Add("continuation tests[$i].evidence_path must be a string") | Out-Null }
                if ($test.Contains('tree_hash') -and ($test['tree_hash'] -isnot [string] -or $test['tree_hash'] -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$')) { $errors.Add("continuation tests[$i].tree_hash must be a git tree sha; $($script:DtContractTreeHashHint)") | Out-Null }
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

function Test-DtReportPathShaped {
    # NONE, or a single token that looks like a path: a drive or root prefix, or a slash with no spaces.
    param([string]$Entry)
    return ($Entry -ceq 'NONE' -or $Entry -match '^(?:[A-Za-z]:[\\/]|[\\/])' -or ($Entry -notmatch '\s' -and $Entry -match '[\\/]'))
}

function Get-DtReportSection {
    # A report field's entries: an inline value after the colon, then every non-blank line up to the next
    # field header or a code fence. $null when the header is absent.
    # -PathField also ends the field at a '---' line and, after its first entry, at the first non-blank line
    # that is not path-shaped, so prose after an unfenced report is not read as an entry while a second
    # path, even after a blank line, still is. Each entry drops a leading '- ' or '* ' bullet and
    # surrounding backticks.
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Name, [switch]$PathField)
    $lines = $Text -split '\r?\n'
    $headerPattern = '^\s*(?:' + (($script:DtReportHeaders | ForEach-Object { [regex]::Escape($_) }) -join '|') + '):'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match($lines[$i], '^\s*' + [regex]::Escape($Name) + ':(.*)$')
        if (-not $m.Success) { continue }
        $entries = New-Object System.Collections.Generic.List[string]
        $rawEntries = @($m.Groups[1].Value) + @($lines | Select-Object -Skip ($i + 1))
        for ($j = 0; $j -lt $rawEntries.Count; $j++) {
            $line = [string]$rawEntries[$j]
            if ($j -gt 0 -and ($line -cmatch $headerPattern -or $line -match '^\s*```')) { break }
            if ($PathField -and $line -match '^\s*---\s*$') { break }
            $entry = $line.Trim()
            if ($PathField) { $entry = ($entry -replace '^[-*]\s+', '') -replace '^`(.*)`$', '$1' }
            if (-not $entry) { continue }
            if ($PathField -and $entries.Count -gt 0 -and -not (Test-DtReportPathShaped $entry)) { break }
            $entries.Add($entry) | Out-Null
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

        $evidence = Get-DtReportSection -Text $Text -Name 'EVIDENCE_PATHS' -PathField
        if ($null -eq $evidence -or @($evidence).Count -eq 0) { $errors.Add('missing EVIDENCE_PATHS') | Out-Null }
        elseif (-not (@($evidence).Count -eq 1 -and $evidence[0] -ceq 'NONE')) {
            foreach ($path in $evidence) {
                if (-not (Test-DtContractLocalPath $path)) { $errors.Add("EVIDENCE_PATHS entry is not an absolute local path: $path") | Out-Null }
                elseif (-not (Test-Path -LiteralPath $path)) { $errors.Add("EVIDENCE_PATHS entry does not exist as an absolute path: $path") | Out-Null }
            }
        }

        $continuation = Get-DtReportSection -Text $Text -Name 'CONTINUATION_STATE' -PathField
        if ($null -eq $continuation -or @($continuation).Count -eq 0) { $errors.Add('missing CONTINUATION_STATE') | Out-Null }
        elseif (@($continuation).Count -gt 1) { $errors.Add("CONTINUATION_STATE must hold one entry, NONE or one path; found $(@($continuation).Count)") | Out-Null }
        elseif ($continuation[0] -cne 'NONE') {
            $path = $continuation[0]
            if (-not (Test-DtContractLocalPath $path)) { $errors.Add("CONTINUATION_STATE is not an absolute local path: $path") | Out-Null }
            elseif (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $errors.Add("CONTINUATION_STATE does not exist as an absolute path: $path") | Out-Null }
            else {
                foreach ($problem in (Get-DtContinuationRecord -Path $path -RunId $RunId -ChunkId $ChunkId).errors) { $errors.Add("CONTINUATION_STATE invalid: $problem") | Out-Null }
            }
        }
    }
    return [pscustomobject]@{ errors = @($errors); version = $version; warning = $warning }
}
