#Requires -Version 7.0
# Shared deterministic authority inventory. No model calls, no authorization decisions.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AuthorityReadBudgetChars = 32000

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

function Get-AuthorityInventory {
    param([string]$RunFolder, [string]$BuildStatePath)
    $root = [IO.Path]::GetFullPath($RunFolder)
    $checkpoint = [IO.Path]::GetFullPath($BuildStatePath)
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($checkpoint)
    foreach ($name in @('approvals.json', 'operator-notes.json', 'build-state.md')) {
        $path = Join-Path $root $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { $pending.Enqueue($path) }
    }
    $seen = @{}
    $records = [Collections.Generic.List[object]]::new()
    # Accept literal paths in code spans, Markdown links and JSON strings. Authority records
    # must name sources literally; no globs, prose paths or recursive workspace search.
    $rx = [regex]'`([^`\r\n]+\.(?:md|json|txt|ya?ml))`|\]\(<?([^\r\n<>]+\.(?:md|json|txt|ya?ml))>?\)|"([^"\r\n]+\.(?:md|json|txt|ya?ml))"|(?<![\w])([a-zA-Z]:[\\/][^`"<>|\r\n]*?\.(?:md|json|txt|ya?ml))(?=[\s,;.)\]]|$)|(?<![\w:/\\])((?:[\w.-]+[\\/])+[\w.-]+\.(?:md|json|txt|ya?ml))'
    while ($pending.Count) {
        $path = $pending.Dequeue()
        $key = $path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "AUTHORITY_MISSING: $path" }
        $originalBytes = [IO.File]::ReadAllBytes($path)
        $text = [Text.Encoding]::UTF8.GetString($originalBytes).TrimStart([char]0xFEFF)
        $kind = if ($path -eq $checkpoint) { 'checkpoint' } elseif ($path -match 'approval') { 'approval' } elseif ($path -match 'operator-notes') { 'operator_notes' } else { 'boundary' }
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
        foreach ($match in $rx.Matches($text)) {
            $literal = @($match.Groups | Select-Object -Skip 1 | Where-Object Success)[0].Value
            # JSON escaped Windows paths are decoded rather than guessed.
            if ($match.Groups[3].Success) { $literal = ('"' + $literal + '"') | ConvertFrom-Json }
            if ($literal -match '^[a-z]+://' -or $literal -match 'authority-digest\.(md|json)$') { continue }
            $resolved = if ([IO.Path]::IsPathRooted($literal)) { [IO.Path]::GetFullPath($literal) } else {
                $near = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $path) $literal))
                if (Test-Path -LiteralPath $near) { $near } else { [IO.Path]::GetFullPath((Join-Path $root $literal)) }
            }
            $pending.Enqueue($resolved)
        }
    }
    return @($records | Sort-Object path)
}

function Get-AuthorityMandatoryPaths {
    param([object[]]$Records, [string]$BuildStatePath)
    $paths = [Collections.Generic.List[string]]::new()
    $paths.Add([IO.Path]::GetFullPath($BuildStatePath))
    foreach ($record in $Records) {
        if ($record.kind -in @('approval', 'operator_notes') -or (Split-Path -Leaf $record.path) -eq 'build-state.md') { $paths.Add($record.path) }
    }
    # The current boundary is the last boundary pointer in checkpoint order. All checkpoint
    # inline restrictions and complete approvals stay mandatory, regardless of digest size.
    $checkpointText = [IO.File]::ReadAllText($BuildStatePath)
    $current = @($Records | Where-Object { $_.kind -eq 'boundary' -and $checkpointText.Contains((Split-Path -Leaf $_.path)) } | Sort-Object { $checkpointText.LastIndexOf((Split-Path -Leaf $_.path)) } | Select-Object -Last 1)
    if ($current.Count) { $paths.Add($current[0].path) }
    $newest = @($Records | Where-Object kind -eq 'boundary' | Sort-Object { (Get-Item -LiteralPath $_.path).LastWriteTimeUtc } | Select-Object -Last 1)
    if ($newest.Count) { $paths.Add($newest[0].path) }
    return @($paths | Select-Object -Unique)
}

function Get-AuthorityMarkdown {
    param([string]$RunFolder, [object[]]$Records, [string]$BuildStatePath)
    $lines = @('# Authority digest', '', 'Mechanical index only. Original records control authorization. Read each governing original IN FULL immediately before its dependent action.', '')
    $mandatory = @(Get-AuthorityMandatoryPaths -Records $Records -BuildStatePath $BuildStatePath)
    # Reserve the entire lean checkpoint ceiling so dt-job status/cursor changes do not
    # alter the deterministic clipping or invalidate a digest built before resume.
    $checkpointText = [IO.File]::ReadAllText($BuildStatePath).Replace("`r`n", "`n")
    $checkpointAuthority = [regex]::Replace($checkpointText, '(?m)^(?:run_status|last_consumed_event_seq):[^\n]*(?:\n|$)', '')
    $mandatoryChars = [math]::Max(8192, $checkpointAuthority.Length)
    $prefixes = @()
    foreach ($record in $Records) {
        if ($record.path -in $mandatory) { $mandatoryChars += $record.chars }
        $display = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($RunFolder), $record.path).Replace('\', '/')
        $prefixes += "- $($record.kind): ``$display``: "
    }
    # Fit only inherited navigation text mechanically, never omit a path or a mandatory
    # original. A small per-record allowance avoids another 99-source bootstrap wall.
    $overhead = (($lines -join "`n") + "`n").Length + (($prefixes -join "`n") + "`n").Length
    $allowance = if ($Records.Count) { [math]::Max(24, [math]::Min(196, [math]::Floor(($script:AuthorityReadBudgetChars - $mandatoryChars - $overhead) / $Records.Count))) } else { 196 }
    for ($i = 0; $i -lt $Records.Count; $i++) {
        $extract = [string]$Records[$i].extract
        if ($extract.Length -gt $allowance) { $extract = $extract.Substring(0, $allowance - 10) + ' [clipped]' }
        $lines += $prefixes[$i] + $extract
    }
    return ($lines -join "`n") + "`n"
}
