# Release-time finding triage library: functions only, no param block, so it is
# safe to dot-source from scripts that have their own parameters (ship.ps1,
# build-acceptance-ledger.ps1). Policy and finding shape: release-triage.ps1.

$script:ReleaseCriticalClasses = @('core-flow', 'data-loss', 'security', 'deploy-rollback')
$script:KnownIssuesHeading = '## Known issues'

function Get-ReleaseTriageValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-ReleaseFindingKey {
    param($Finding)
    $id = [string](Get-ReleaseTriageValue $Finding 'id')
    $milestone = [string](Get-ReleaseTriageValue $Finding 'milestone')
    if ($milestone) { return "$milestone $id" }
    return $id
}

function Test-ReleaseFinding {
    # Returns a list of validation errors for one finding (empty = valid).
    param($Finding)
    $errors = @()
    $id = [string](Get-ReleaseTriageValue $Finding 'id')
    $label = if ($id) { $id } else { '<no id>' }
    if (-not $id) { $errors += "finding has no id" }
    $what = [string](Get-ReleaseTriageValue $Finding 'what')
    if (-not $what) { $what = [string](Get-ReleaseTriageValue $Finding 'title') }
    if (-not $what) { $errors += "${label}: missing 'what'" }
    if (-not [string](Get-ReleaseTriageValue $Finding 'where')) { $errors += "${label}: missing 'where'" }
    $critical = [string](Get-ReleaseTriageValue $Finding 'critical')
    if ($critical -and $critical -ne 'none') {
        if ($script:ReleaseCriticalClasses -notcontains $critical) {
            $errors += "${label}: critical '$critical' is not one of $($script:ReleaseCriticalClasses -join ', ')"
        } elseif (-not [string](Get-ReleaseTriageValue $Finding 'critical_scenario')) {
            $errors += "${label}: a critical finding needs 'critical_scenario' (the concrete failure)"
        }
    } elseif (-not [string](Get-ReleaseTriageValue $Finding 'why_not_blocking')) {
        $errors += "${label}: a non-critical finding needs 'why_not_blocking'"
    }
    return ,$errors
}

function Get-ReleaseFindingDecision {
    # 'block' only for a valid critical class; everything else is 'known-issue'.
    param($Finding)
    $critical = [string](Get-ReleaseTriageValue $Finding 'critical')
    if ($critical -and $script:ReleaseCriticalClasses -contains $critical) { return 'block' }
    return 'known-issue'
}

function Format-KnownIssueLine {
    param($Finding, [string]$Stage)
    $what = [string](Get-ReleaseTriageValue $Finding 'what')
    if (-not $what) { $what = [string](Get-ReleaseTriageValue $Finding 'title') }
    $type = [string](Get-ReleaseTriageValue $Finding 'type')
    $tags = @(@($type, $Stage) | Where-Object { $_ })
    $tagText = if ($tags.Count) { " ($($tags -join ', '))" } else { '' }
    $one = { param([string]$s) ($s -replace '\s*\r?\n\s*', ' ').Trim() }
    $key = Get-ReleaseFindingKey $Finding
    $whatText = (& $one $what).TrimEnd('.')
    $whereText = (& $one ([string](Get-ReleaseTriageValue $Finding 'where'))).TrimEnd('.')
    $whyText = (& $one ([string](Get-ReleaseTriageValue $Finding 'why_not_blocking'))).TrimEnd('.')
    return "- **$key**${tagText}: $whatText. Where: $whereText. Why it does not block: $whyText. Fix: next release."
}

function Get-KnownIssues {
    # Parses the "## Known issues" section of a deferred-findings.md.
    # Returns objects { key, line } in file order; empty when absent.
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $lines = [System.IO.File]::ReadAllLines($Path)
    $inSection = $false
    $items = @()
    foreach ($line in $lines) {
        if ($line -match '^##\s') {
            $inSection = ($line.Trim() -ieq $script:KnownIssuesHeading)
            continue
        }
        if ($inSection -and $line -match '^- \*\*(.+?)\*\*') {
            $items += [pscustomobject]@{ key = $Matches[1]; line = $line.Trim() }
        }
    }
    return $items
}

function Add-KnownIssues {
    # Appends lines under "## Known issues" (creating the section and file as
    # needed). Idempotent by key. Returns the keys actually appended.
    param([string]$Path, [object[]]$Entries)
    $existing = @(Get-KnownIssues -Path $Path | ForEach-Object { $_.key })
    $new = @($Entries | Where-Object { $existing -notcontains $_.key })
    if (-not $new.Count) { return @() }
    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($l in [System.IO.File]::ReadAllLines($Path)) { $lines.Add($l) }
    } else {
        $lines.Add('# Deferred findings'); $lines.Add('')
    }
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ieq $script:KnownIssuesHeading) { $start = $i; break }
    }
    if ($start -lt 0) {
        while ($lines.Count -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) { $lines.RemoveAt($lines.Count - 1) }
        if ($lines.Count) { $lines.Add('') }
        $lines.Add($script:KnownIssuesHeading); $lines.Add('')
        $lines.Add('Non-critical findings shipped unchanged under the release-time triage rule; each is fixed in the next release.')
        $lines.Add('')
        foreach ($e in $new) { $lines.Add($e.line) }
    } else {
        $end = $lines.Count
        for ($i = $start + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^##?\s') { $end = $i; break }
        }
        $insert = $end
        while ($insert -gt $start + 1 -and [string]::IsNullOrWhiteSpace($lines[$insert - 1])) { $insert-- }
        $offset = 0
        foreach ($e in $new) { $lines.Insert($insert + $offset, $e.line); $offset++ }
        if ($insert + $offset -lt $lines.Count -and -not [string]::IsNullOrWhiteSpace($lines[$insert + $offset])) {
            $lines.Insert($insert + $offset, '')
        }
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, (($lines -join "`n").TrimEnd() + "`n"))
    return @($new | ForEach-Object { $_.key })
}

function Invoke-ReleaseTriage {
    param([object[]]$Findings, [string]$Stage, [string]$RunFolder)
    $errors = @()
    foreach ($f in $Findings) { $errors += Test-ReleaseFinding $f }
    if ($errors.Count) {
        return [pscustomobject]@{ decision = 'invalid'; stage = $Stage; errors = $errors; blocking = @(); known_issues = @(); appended = @(); regate_required = $false; deferred_path = $null }
    }
    $blocking = @(); $known = @()
    foreach ($f in $Findings) {
        if ((Get-ReleaseFindingDecision $f) -eq 'block') {
            $blocking += [pscustomobject]@{ key = (Get-ReleaseFindingKey $f); critical = [string](Get-ReleaseTriageValue $f 'critical'); scenario = [string](Get-ReleaseTriageValue $f 'critical_scenario') }
        } else {
            $known += [pscustomobject]@{ key = (Get-ReleaseFindingKey $f); line = (Format-KnownIssueLine $f $Stage) }
        }
    }
    $deferredPath = $null; $appended = @()
    if ($RunFolder -and $known.Count) {
        $deferredPath = Join-Path $RunFolder 'deferred-findings.md'
        $appended = @(Add-KnownIssues -Path $deferredPath -Entries $known)
    }
    return [pscustomobject]@{
        decision        = $(if ($blocking.Count) { 'block' } else { 'ship' })
        stage           = $Stage
        errors          = @()
        blocking        = $blocking
        known_issues    = @($known | ForEach-Object { $_.key })
        appended        = $appended
        # A known issue never re-gates; only a critical fix changes the candidate.
        regate_required = [bool]$blocking.Count
        deferred_path   = $deferredPath
    }
}
