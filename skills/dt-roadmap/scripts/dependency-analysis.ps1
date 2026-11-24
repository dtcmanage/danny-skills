# Pure analysis: no checkout enumeration, so new files and glob/glob collisions count.
function Get-SurfaceItems([string]$Cell) {
    return @($Cell.Split(';') | ForEach-Object { $_.Trim().Trim('`') } | Where-Object { $_ -and $_ -ne '-' })
}

function Read-MilestoneSurfaces([string]$Text) {
    $rows = [System.Collections.Generic.List[object]]::new()
    $section = [regex]::Match($Text, '(?ms)^## Milestone Surfaces\s*\r?\n(.*?)(?=^## |\z)')
    $headers = @()
    foreach ($line in ($section.Groups[1].Value -split '\r?\n')) {
        if ($line -notmatch '^\s*\|') { continue }
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        if ($cells -contains 'milestone-id') { $headers = $cells; continue }
        if (-not $headers.Count -or $cells[0] -match '^:?-+:?$') { continue }
        $row = [ordered]@{}
        foreach ($key in @('milestone-id', 'write-surface', 'provides', 'consumes', 'design-source')) { $row[$key] = '' }
        for ($i = 0; $i -lt $headers.Count; $i++) { $row[$headers[$i]] = if ($i -lt $cells.Count) { $cells[$i] } else { '' } }
        $rows.Add([pscustomobject]$row)
    }
    return ,$rows.ToArray()
}

# Intersect two glob automata. For paths, ** is a whole segment (zero or more
# directories); segment patterns support * and ?. No filesystem probes needed.
function Test-GlobIntersection([string]$Left, [string]$Right, [switch]$Segments) {
    $a = if ($Segments) { @($Left.ToCharArray() | ForEach-Object { [string]$_ }) } else { @($Left.Split('/')) }
    $b = if ($Segments) { @($Right.ToCharArray() | ForEach-Object { [string]$_ }) } else { @($Right.Split('/')) }
    $star = if ($Segments) { '*' } else { '**' }
    $todo = [System.Collections.Generic.Queue[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $todo.Enqueue(@(0, 0))
    while ($todo.Count) {
        $state = $todo.Dequeue(); $i = $state[0]; $j = $state[1]
        if (-not $seen.Add("$i,$j")) { continue }
        if ($i -eq $a.Count -and $j -eq $b.Count) { return $true }
        if ($i -lt $a.Count -and $a[$i] -ceq $star) { $todo.Enqueue(@(($i + 1), $j)) }
        if ($j -lt $b.Count -and $b[$j] -ceq $star) { $todo.Enqueue(@($i, ($j + 1))) }
        if ($i -eq $a.Count -or $j -eq $b.Count) { continue }
        $matches = if ($Segments) {
            $a[$i] -in @('*', '?') -or $b[$j] -in @('*', '?') -or $a[$i] -ceq $b[$j]
        } else {
            $a[$i] -ceq '**' -or $b[$j] -ceq '**' -or (Test-GlobIntersection $a[$i] $b[$j] -Segments)
        }
        if ($matches) {
            $ni = if ($a[$i] -ceq $star) { $i } else { $i + 1 }
            $nj = if ($b[$j] -ceq $star) { $j } else { $j + 1 }
            $todo.Enqueue(@($ni, $nj))
        }
    }
    return $false
}

function Test-DependencyPath([hashtable]$Adj, [string]$From, [string]$To) {
    $todo = [System.Collections.Generic.Queue[string]]::new(); $todo.Enqueue($From)
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    while ($todo.Count) {
        $id = $todo.Dequeue()
        if (-not $seen.Add($id)) { continue }
        foreach ($dep in @($Adj[$id])) {
            if ($dep -eq $To) { return $true }
            if ($dep) { $todo.Enqueue($dep) }
        }
    }
    return $false
}

function Get-MilestoneDependencyAnalysis([object[]]$Milestones, [object[]]$Surfaces) {
    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $edges = [System.Collections.Generic.List[object]]::new()
    $byId = @{}; $declared = @{}; $computed = @{}
    $ids = @($Milestones | ForEach-Object { [string]$_.id } | Sort-Object -CaseSensitive)
    foreach ($m in $Milestones) {
        $declared[$m.id] = @(([string]$m.dependencies -replace '[\[\]]', '') -split '[,;\s]+' | Where-Object { $_ -and $_ -notin @('-', 'none') })
        $computed[$m.id] = @()
    }
    foreach ($row in $Surfaces) {
        $id = $row.'milestone-id'
        if ($id -notin $ids -or $byId.ContainsKey($id)) { $errors.Add("DEPENDENCY_SURFACE_INVALID: unknown or duplicate milestone '$id'"); continue }
        $byId[$id] = $row
        foreach ($key in @('write-surface', 'provides', 'consumes', 'design-source')) {
            if ([string]::IsNullOrWhiteSpace($row.$key)) { $errors.Add("DEPENDENCY_SURFACE_INVALID: $id missing $key (use - for an empty set)") }
        }
        foreach ($path in @(Get-SurfaceItems $row.'write-surface')) {
            if ($path -match '[\\\[\]{}|]' -or $path -match '^/|^[A-Za-z]:|(^|/)\.\.?(/|$)' -or $path -match '(?<!^|/)\*\*|\*\*(?!/|$)' -or $path.EndsWith('/')) {
                $errors.Add("DEPENDENCY_SURFACE_INVALID: $id invalid repo-relative glob '$path'; use /, *, ?, and whole-segment **")
            }
        }
    }
    foreach ($id in $ids) { if (-not $byId.ContainsKey($id)) { $errors.Add("DEPENDENCY_SURFACE_MISSING: $id needs a Milestone Surfaces row") } }
    if ($errors.Count) { return [pscustomobject]@{ errors = @($errors); warnings = @($warnings); edges = @($edges); dependencies = $computed } }
    # Consumption establishes direction even when the provider sorts after its consumer.
    foreach ($consumer in $ids) {
        foreach ($provider in $ids) {
            if ($consumer -eq $provider) { continue }
            foreach ($item in @(Get-SurfaceItems $byId[$consumer].consumes)) {
                if (@(Get-SurfaceItems $byId[$provider].provides) -ccontains $item) {
                    $computed[$consumer] += $provider
                    $edges.Add([pscustomobject]@{ prerequisite = $provider; milestone = $consumer; cause = "consumes $item"; overlap = $false })
                    if (-not (Test-DependencyPath $declared $consumer $provider)) { $errors.Add("DEPENDENCY_CONSUMPTION_UNDECLARED: $consumer needs $provider; consumes $item") }
                }
            }
        }
    }
    for ($i = 0; $i -lt $ids.Count; $i++) {
        for ($j = $i + 1; $j -lt $ids.Count; $j++) {
            $a = $ids[$i]; $b = $ids[$j]
            foreach ($left in @(Get-SurfaceItems $byId[$a].'write-surface')) {
                foreach ($right in @(Get-SurfaceItems $byId[$b].'write-surface')) {
                    if (-not (Test-GlobIntersection $left $right)) { continue }
                    $cause = "write overlap $left <> $right"
                    # Honor semantic direction first, then an authored serial direction;
                    # for an otherwise unordered collision use stable ID order, never row order.
                    $reverse = (Test-DependencyPath $computed $a $b) -or
                        (-not (Test-DependencyPath $computed $b $a) -and (Test-DependencyPath $declared $a $b))
                    $before = if ($reverse) { $b } else { $a }; $after = if ($reverse) { $a } else { $b }
                    $computed[$after] += $before
                    $edges.Add([pscustomobject]@{ prerequisite = $before; milestone = $after; cause = $cause; overlap = $true })
                    if (-not (Test-DependencyPath $declared $a $b) -and -not (Test-DependencyPath $declared $b $a)) {
                        $errors.Add("DEPENDENCY_OVERLAP_UNDECLARED: $a and $b require serialization; $cause")
                    }
                }
            }
        }
    }
    foreach ($id in $ids) {
        $computed[$id] = @($computed[$id] | Sort-Object -Unique)
        if (Test-DependencyPath $computed $id $id) { $errors.Add("DEPENDENCY_CYCLE: computed surfaces/interfaces cycle at $id") }
        foreach ($dep in $declared[$id]) {
            $justified = @($edges | Where-Object { $_.milestone -eq $id -and $_.prerequisite -eq $dep }).Count -gt 0
            if (-not $justified) { $warnings.Add("DEPENDENCY_UNJUSTIFIED: $id -> $dep has no shared write surface or consumed interface") }
        }
    }
    return [pscustomobject]@{ errors = @($errors); warnings = @($warnings); edges = @($edges); dependencies = $computed }
}
