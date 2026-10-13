#Requires -Version 7.0
# Shared deterministic authority inventory. No model calls, no authorization decisions.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AuthorityReadBudgetChars = 32000
$script:AuthorityReadCeilingChars = 96000

function Get-AuthorityHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-AuthorityCheckpointHash {
    param([string]$Text)
    # These two lines are owned by dt-job, not authorization. Resume/consume may change
    # them after an operator builds the digest; every other checkpoint character is pinned.
    $authority = [regex]::Replace($Text.Replace("`r`n", "`n"), '(?m)^(?:run_status|last_consumed_event_seq):[^\n]*(?:\n|$)', '')
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($authority))).ToLowerInvariant()
}

function Get-AuthorityAliases {
    param([string]$Text)
    $aliases = @{}
    foreach ($m in [regex]::Matches($Text, '(?m)^\s*(?:-\s*)?([A-Z][A-Z0-9_]*)=([^\r\n]+)')) {
        $value = $m.Groups[2].Value.Trim()
        # Values retain spaces to end of list item. Compressed alias-reference
        # definitions sometimes append an explicit sentence or unchanged-seal annotation.
        if (-not [IO.Path]::IsPathRooted($value)) {
            $value = ([regex]::new('(?i)\.\s+(?=Before\s*bootstrap\b)|\s+(?=unchanged\w*\b)').Split($value, 2))[0].TrimEnd('.')
        }
        $aliases[$m.Groups[1].Value] = $value
    }
    return $aliases
}

function Resolve-AuthorityLiteral {
    param([string]$Literal, [string]$Source, [string]$RunFolder, [hashtable]$Aliases)
    $value = $Literal.Trim().Replace('/', [IO.Path]::DirectorySeparatorChar)
    $visited = @{}
    while ($value -match '^([A-Z][A-Z0-9_]*)[/\\](.*)$' -and $Aliases.ContainsKey($Matches[1])) {
        $name = $Matches[1]; $tail = $Matches[2]
        if ($visited.ContainsKey($name)) { throw "AUTHORITY_ALIAS_CYCLE: $Literal" }
        $visited[$name] = $true
        $value = Join-Path $Aliases[$name] $tail
    }
    if ([IO.Path]::IsPathRooted($value)) { return [IO.Path]::GetFullPath($value) }
    $near = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Source) $value))
    if (Test-Path -LiteralPath $near) { return $near }
    return [IO.Path]::GetFullPath((Join-Path $RunFolder $value))
}

function Get-AuthorityCandidates {
    param([string]$Text, [hashtable]$Aliases)
    $ext = '(?:md|json|txt|ya?ml)'
    $patterns = @(
        ('`(?<path>[^`\r\n]+\.' + $ext + ')`'),
        ('\]\(<?(?<path>[^\r\n<>]+\.' + $ext + ')>?\)'),
        ('"(?<path>[^"\r\n]+\.' + $ext + ')"'),
        ('(?<![\w])(?<path>[a-zA-Z]:[\\/][^`"<>|\r\n]*?\.' + $ext + ')(?=[\s,;.)\]]|$)'),
        ('(?<![\w:/\\])(?<path>(?:[\w.-]+[\\/])+[\w.-]+\.' + $ext + ')')
    )
    if ($Aliases.Count) {
        $names = ($Aliases.Keys | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) }) -join '|'
        # A known alias can start after a glued prose word, but never in a path segment.
        $patterns = @('(?<![/\\])(?<path>(?:' + $names + ')[/\\](?:[^\s`"<>|{},;]+[/\\])?\{[^}\r\n]+\}|(?:' + $names + ')[/\\][^\s`"<>|{},;]*?\.' + $ext + ')') + $patterns
    }
    $occupied = [Collections.Generic.List[object]]::new()
    foreach ($pattern in $patterns) {
        foreach ($m in [regex]::Matches($Text, $pattern)) {
            $g = $m.Groups['path']
            if (@($occupied | Where-Object { $g.Index -lt $_.end -and ($g.Index + $g.Length) -gt $_.start }).Count) { continue }
            $occupied.Add(@{ start = $g.Index; end = $g.Index + $g.Length })
            $literal = $g.Value
            if ($pattern.StartsWith('"')) { $literal = ('"' + $literal + '"') | ConvertFrom-Json }
            if ($literal -match '^[a-z]+://' -or $literal -match 'authority-digest\.(md|json)$') { continue }
            $expanded = @($literal)
            if ($literal -match '^(.*)\{([^{}]+)\}(.*)$') {
                $prefix = $Matches[1]; $suffix = $Matches[3]
                $expanded = @($Matches[2] -split ',' | ForEach-Object { $prefix + $_.Trim() + $suffix })
            }
            foreach ($item in $expanded) { [pscustomobject]@{ literal = $item; index = $g.Index; explicit = ($pattern.StartsWith('`') -or $pattern.StartsWith('\]') -or $pattern.StartsWith('"')) } }
            # Compressed lists often give the directory only on the first member.
            if ($literal -match '^(.*[/\\])[^/\\]+\.' + $ext + '$') {
                $directoryPrefix = $Matches[1]
                $rest = $Text.Substring($g.Index + $g.Length)
                foreach ($sibling in [regex]::Matches($rest, '\G,\s*(?<file>[\w.-]+\.' + $ext + ')')) {
                    [pscustomobject]@{ literal = $directoryPrefix + $sibling.Groups['file'].Value; index = $g.Index + $g.Length + $sibling.Index; explicit = $true }
                }
            }
        }
    }
}

function Get-AuthorityEnumeration {
    param([string]$Boundary, [string]$RunFolder, [hashtable]$Aliases, [hashtable]$Stack = @{})
    if ($Stack.ContainsKey($Boundary)) { throw "AUTHORITY_INHERITANCE_CYCLE: $Boundary" }
    $Stack[$Boundary] = $true
    if (-not (Test-Path -LiteralPath $Boundary -PathType Leaf)) {
        $script:AuthorityDiagnostics.Add([pscustomobject]@{ source = $Boundary; candidate = $Boundary; resolved = $Boundary; reason = 'missing_named_original'; required = $true })
        throw "AUTHORITY_MISSING: $Boundary"
    }
    $json = [IO.File]::ReadAllText($Boundary) | ConvertFrom-Json
    $inherited = @()
    if ($json.PSObject.Properties['inherited_boundary']) {
        $parent = Resolve-AuthorityLiteral $json.inherited_boundary $Boundary $RunFolder $Aliases
        $inherited = @(Get-AuthorityEnumeration $parent $RunFolder $Aliases $Stack)
    } elseif ($json.PSObject.Properties['inherited_authority_sources']) {
        $inherited = @($json.inherited_authority_sources | ForEach-Object { Resolve-AuthorityLiteral $_ $Boundary $RunFolder $Aliases })
    } else { throw "AUTHORITY_ENUMERATION_MISSING: $Boundary" }
    $paths = @($Boundary) + $inherited
    foreach ($field in @('source_disposition', 'scope', 'approval_text')) {
        if (-not $json.PSObject.Properties[$field]) { throw "AUTHORITY_ENUMERATION_FIELD: $Boundary : $field" }
        $paths += Resolve-AuthorityLiteral $json.$field $Boundary $RunFolder $Aliases
    }
    $paths = @($paths | Sort-Object -Unique)
    foreach ($field in @('original_inherited_record_count', 'inherited_originals')) {
        if ($json.PSObject.Properties[$field] -and [int]$json.$field -ne $inherited.Count) { throw "AUTHORITY_ENUMERATION_COUNT: $Boundary : $field" }
    }
    if (-not $json.PSObject.Properties['required_original_records'] -or [int]$json.required_original_records -ne $paths.Count) { throw "AUTHORITY_ENUMERATION_COUNT: $Boundary : required_original_records" }
    $Stack.Remove($Boundary)
    return $paths
}

function Get-AuthorityInventory {
    param([string]$RunFolder, [string]$BuildStatePath)
    $root = [IO.Path]::GetFullPath($RunFolder)
    $checkpoint = [IO.Path]::GetFullPath($BuildStatePath)
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($checkpoint)
    $script:AuthorityDiagnostics = [Collections.Generic.List[object]]::new()
    $script:AuthorityCurrentBoundary = $null
    $script:AuthorityEnumeratedPaths = @()
    $script:AuthorityCheckpointFullReads = @()
    $checkpointText = [IO.File]::ReadAllText($checkpoint)
    $aliases = Get-AuthorityAliases $checkpointText
    $checkpointCandidates = @(Get-AuthorityCandidates $checkpointText $aliases | Sort-Object index)
    # STOP is the explicit current authority locator in compressed checkpoints.
    if ($aliases.ContainsKey('STOP')) {
        $boundary = Resolve-AuthorityLiteral 'STOP/next-operation-boundary.json' $checkpoint $root $aliases
        $script:AuthorityEnumeratedPaths = @(Get-AuthorityEnumeration $boundary $root $aliases)
        $script:AuthorityCurrentBoundary = $boundary
        foreach ($original in $script:AuthorityEnumeratedPaths) { $pending.Enqueue($original) }
    }
    foreach ($name in @('approvals.json', 'operator-notes.json', 'build-state.md', 'build-plan.md')) {
        $path = Join-Path $root $name
        if ($script:AuthorityEnumeratedPaths.Count -or (Test-Path -LiteralPath $path -PathType Leaf)) { $pending.Enqueue($path) }
    }
    $seen = @{}
    $records = [Collections.Generic.List[object]]::new()
    $missing = [Collections.Generic.List[string]]::new()
    while ($pending.Count) {
        $path = $pending.Dequeue()
        $key = $path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $missing.Add($path)
            $script:AuthorityDiagnostics.Add([pscustomobject]@{ source = $checkpoint; candidate = $path; resolved = $path; reason = 'missing_named_original'; required = $true })
            continue
        }
        $originalBytes = [IO.File]::ReadAllBytes($path)
        $text = [Text.Encoding]::UTF8.GetString($originalBytes).TrimStart([char]0xFEFF)
        $leaf = Split-Path -Leaf $path
        $kind = if ($path -eq $checkpoint) { 'checkpoint' } elseif ($leaf -match 'approval' -or $path -match '[/\\]approvals[/\\]') { 'approval' } elseif ($leaf -match 'operator-notes') { 'operator_notes' } else { 'boundary' }
        # Quote an index of operative lines, never generate or infer an approval. Full originals
        # govern every dependent action; the index intentionally cannot confer authority.
        $lines = @($text -split '\r?\n' | Where-Object { $_ -match '(?i)approv|authoriz|scope|restrict|boundary|must|never|only|do not|no (?:push|merge|deploy|production)|allowed|prohibit' })
        $extract = ($lines -join ' ').Trim()
        if (-not $extract) { $extract = 'No operative line recognized. Read original before any dependent action.' }
        if ($extract.Length -gt 160) { $extract = $extract.Substring(0, 160) + ' [index clipped; original controls]' }
        # The checkpoint is the graph root and always read in full, not an inherited original.
        if ($path -ne $checkpoint) {
            $records.Add([pscustomobject][ordered]@{ path = $path; sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($originalBytes)).ToLowerInvariant(); bytes = $originalBytes.Length; chars = $text.Length; kind = $kind; extract = $extract })
        }
        # An enumerated authority set is closed: evidence named within those originals
        # does not replace or expand its explicit source list. Legacy graphs recurse.
        if ($script:AuthorityEnumeratedPaths.Count -and $path -ne $checkpoint) { continue }
        $candidates = if ($path -eq $checkpoint) { $checkpointCandidates } else { @(Get-AuthorityCandidates $text $aliases) }
        foreach ($candidate in $candidates) {
            $resolved = Resolve-AuthorityLiteral $candidate.literal $path $root $aliases
            $required = $true
            if ($script:AuthorityEnumeratedPaths.Count) {
                # Only paths explicitly required before bootstrap supplement the enumeration.
                $line = ($text.Substring(0, $candidate.index) -split '\r?\n')[-1] + ($text.Substring($candidate.index) -split '\r?\n')[0]
                $leading = ($text.Substring(0, $candidate.index) -split '\r?\n')[-1]
                $required = $resolved -in $script:AuthorityEnumeratedPaths -or $leading -match '(?i)before\s*bootstrap.*read|also.*before\s*bootstrap.*read'
                # Bounded metadata clarifications are supplementary originals. Current
                # stop restrictions remain full reads; inherited metadata uses the index.
                if ($required -and $resolved -notin $script:AuthorityEnumeratedPaths -and $line -notmatch '(?i)necessary\s*metadata\s+clarifications\s+grant\s+no\s*new\s*authority') { $script:AuthorityCheckpointFullReads += $resolved }
            }
            if (Test-Path -LiteralPath $resolved -PathType Leaf) { if ($required) { $pending.Enqueue($resolved) }; continue }
            $script:AuthorityDiagnostics.Add([pscustomobject]@{ source = $path; candidate = $candidate.literal; resolved = $resolved; reason = $(if ($required) { 'missing_named_original' } else { 'non_authority_reference' }); required = $required })
            if ($required) { $missing.Add($resolved) }
        }
    }
    if ($missing.Count) { throw "AUTHORITY_MISSING: $($missing -join '; ')" }
    return @($records | Sort-Object path)
}

function Get-AuthorityMandatoryPaths {
    param([object[]]$Records, [string]$BuildStatePath)
    $paths = [Collections.Generic.List[string]]::new()
    $paths.Add([IO.Path]::GetFullPath($BuildStatePath))
    foreach ($record in $Records) {
        if (($script:AuthorityEnumeratedPaths.Count -eq 0 -and $record.kind -in @('approval', 'operator_notes')) -or
            $record.path -in $script:AuthorityCheckpointFullReads -or
            (Split-Path -Leaf $record.path) -in @('approvals.json', 'operator-notes.json', 'build-state.md', 'build-plan.md')) { $paths.Add($record.path) }
    }
    # The current boundary is the last boundary pointer in checkpoint order. All checkpoint
    # inline restrictions and complete approvals stay mandatory, regardless of digest size.
    $checkpointText = [IO.File]::ReadAllText($BuildStatePath)
    if ($script:AuthorityCurrentBoundary) {
        $paths.Add($script:AuthorityCurrentBoundary)
        return @($paths | Sort-Object -Unique)
    }
    $current = @($Records | Where-Object { $_.kind -eq 'boundary' -and $checkpointText.Contains((Split-Path -Leaf $_.path)) } | Sort-Object { $checkpointText.LastIndexOf((Split-Path -Leaf $_.path)) } | Select-Object -Last 1)
    if ($current.Count) { $paths.Add($current[0].path) }
    $newest = @($Records | Where-Object kind -eq 'boundary' | Sort-Object { (Get-Item -LiteralPath $_.path).LastWriteTimeUtc } | Select-Object -Last 1)
    if ($newest.Count) { $paths.Add($newest[0].path) }
    return @($paths | Select-Object -Unique)
}

function Get-AuthorityMarkdown {
    param([string]$RunFolder, [object[]]$Records, [string]$BuildStatePath)
    $body = Get-AuthorityMarkdownBody -RunFolder $RunFolder -Records $Records -BuildStatePath $BuildStatePath
    $mandatory = @(Get-AuthorityMandatoryPaths -Records $Records -BuildStatePath $BuildStatePath)
    # Fixed-width header keeps the measured boundary independent of warning state.
    $warningHeader = Get-AuthorityBudgetHeader -OverTarget $true
    $bootstrapChars = $body.Length + $warningHeader.Length + [IO.File]::ReadAllText($BuildStatePath).Length
    foreach ($record in $Records) { if ($record.path -in $mandatory) { $bootstrapChars += $record.chars } }
    $header = Get-AuthorityBudgetHeader -OverTarget ($bootstrapChars -gt $script:AuthorityReadBudgetChars)
    return $body.Replace("# Authority digest`n", "# Authority digest`n$header")
}

function Get-AuthorityBudgetHeader {
    param([bool]$OverTarget)
    $warning = 'WARNING: over_target; proceed with all current authority; confirm observed transcript on next resume.'
    $state = if ($OverTarget) { $warning } else { 'within_target'.PadRight($warning.Length, '.') }
    return "Budget: target $script:AuthorityReadBudgetChars chars; hard ceiling $script:AuthorityReadCeilingChars chars. $state`n"
}

function Get-AuthorityMarkdownBody {
    param([string]$RunFolder, [object[]]$Records, [string]$BuildStatePath)
    $lines = @('# Authority digest', '', 'Mechanical index only. Original records control authorization. Read each governing original IN FULL immediately before its dependent action.', '')
    $mandatory = @(Get-AuthorityMandatoryPaths -Records $Records -BuildStatePath $BuildStatePath)
    # Reserve the entire lean checkpoint ceiling so dt-job status/cursor changes do not
    # alter the deterministic clipping or invalidate a digest built before resume.
    $checkpointText = [IO.File]::ReadAllText($BuildStatePath).Replace("`r`n", "`n")
    $checkpointAuthority = [regex]::Replace($checkpointText, '(?m)^(?:run_status|last_consumed_event_seq):[^\n]*(?:\n|$)', '')
    $mandatoryChars = [math]::Max(8192, $checkpointAuthority.Length)
    $prefixes = @()
    $directories = @($Records | ForEach-Object { [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($RunFolder), (Split-Path -Parent $_.path)).Replace('\', '/') } | Sort-Object -Unique)
    $files = @($Records | ForEach-Object { Split-Path -Leaf $_.path } | Sort-Object -Unique)
    $lines += 'Paths relative to run. Dk[:n]suffix = first n characters of Dk + suffix. D:F lists directory/filenames. [clipped] extracts remain in JSON.'
    $common = @($directories | Where-Object { $_ -ne '.' })
    $prefix = if ($common.Count) { $common[0] } else { '' }
    foreach ($directory in $common) { while ($prefix -and -not $directory.StartsWith($prefix + '/')) { $prefix = ($prefix -replace '/?[^/]+$', '') } }
    if ($prefix) { $lines += "P=$prefix" }
    for ($d = 0; $d -lt $directories.Count; $d++) {
        $displayDirectory = if ($prefix -and $directories[$d].StartsWith($prefix + '/')) { 'P/' + $directories[$d].Substring($prefix.Length + 1) } else { $directories[$d] }
        for ($prior = 0; $prior -lt $d; $prior++) {
            $shared = 0
            while ($shared -lt [math]::Min($directories[$prior].Length, $directories[$d].Length) -and $directories[$prior][$shared] -ceq $directories[$d][$shared]) { $shared++ }
            $compressed = "D${prior}[:$shared]" + $directories[$d].Substring($shared)
            if ($compressed.Length -lt $displayDirectory.Length) { $displayDirectory = $compressed }
        }
        $lines += "D${d}=$displayDirectory"
    }
    for ($f = 0; $f -lt $files.Count; $f++) { $lines += "F${f}=$($files[$f])" }
    $lines += ''
    if ($script:AuthorityEnumeratedPaths.Count) {
        # Structured source lists need a reversible path index, not 99 repeated
        # permission excerpts. Each D:F member maps to exactly one hashed original.
        for ($d = 0; $d -lt $directories.Count; $d++) {
            $members = @($Records | Where-Object { [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($RunFolder), (Split-Path -Parent $_.path)).Replace('\', '/') -eq $directories[$d] } | ForEach-Object { 'F' + [array]::IndexOf($files, (Split-Path -Leaf $_.path)) })
            $lines += "D${d}:" + ($members -join ',')
        }
        $lines += @('', '## Diagnostics', 'Unresolved candidates:')
        foreach ($item in $script:AuthorityDiagnostics) { $lines += "- $($item.reason): ``$($item.candidate)``" }
        if (-not $script:AuthorityDiagnostics.Count) { $lines += '- none' }
        return ($lines -join "`n") + "`n"
    }
    foreach ($record in $Records) {
        if ($record.path -in $mandatory) { $mandatoryChars += $record.chars }
        $directory = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($RunFolder), (Split-Path -Parent $record.path)).Replace('\', '/')
        $display = 'D' + [array]::IndexOf($directories, $directory) + '/F' + [array]::IndexOf($files, (Split-Path -Leaf $record.path))
        $prefixes += "- $display : "
    }
    # Fit only inherited navigation text mechanically, never omit a path or a mandatory
    # original. A small per-record allowance avoids another 99-source bootstrap wall.
    $overhead = (($lines -join "`n") + "`n").Length + (($prefixes -join "`n") + "`n").Length
    $diagnosticLines = @('', '## Diagnostics', 'Unresolved candidates (required originals fail closed):')
    foreach ($item in $script:AuthorityDiagnostics) { $diagnosticLines += "- $($item.reason): ``$($item.candidate)``" }
    if (-not $script:AuthorityDiagnostics.Count) { $diagnosticLines += '- none' }
    $overhead += (($diagnosticLines -join "`n") + "`n").Length
    $overhead += (Get-AuthorityBudgetHeader -OverTarget $true).Length
    $allowance = if ($Records.Count) { [math]::Max(0, [math]::Min(196, [math]::Floor(($script:AuthorityReadBudgetChars - $mandatoryChars - $overhead) / $Records.Count))) } else { 196 }
    for ($i = 0; $i -lt $Records.Count; $i++) {
        $extract = [string]$Records[$i].extract
        if ($extract.Length -gt $allowance) { $extract = if ($allowance -lt 10) { ''.PadRight($allowance, '~') } else { $extract.Substring(0, $allowance - 10) + ' [clipped]' } }
        $lines += $prefixes[$i] + $extract
    }
    $lines += $diagnosticLines
    return ($lines -join "`n") + "`n"
}
