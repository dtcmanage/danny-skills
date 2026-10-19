# Shared by the producer, validator and close-out renderer; no cwd-relative paths.
function Get-CoverageSection([string]$Text, [string]$Heading) {
    $m = [regex]::Match($Text, '(?ms)^## ' + [regex]::Escape($Heading) + '\s*\r?\n(.*?)(?=^## |\z)')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

function Get-CoverageScalar([string]$Text, [string]$Key) {
    $fm = [regex]::Match($Text, '(?s)\A---\s*\r?\n(.*?)\r?\n---')
    $m = [regex]::Match($fm.Groups[1].Value, '(?m)^' + [regex]::Escape($Key) + ':\s*(.+)$')
    return $m.Groups[1].Value.Trim().Trim('"', "'")
}

function Resolve-CoveragePath([string]$Document, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'COVERAGE_PATH_MISSING: name the design/build input path.' }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($Document))) $Path))
}

function Get-CoverageRows([string]$Text, [string]$Heading = 'Design Coverage') {
    $lines = @((Get-CoverageSection $Text $Heading) -split '\r?\n' | Where-Object { $_ -match '^\s*\|' })
    if ($lines.Count -lt 2) { return }
    $headers = @($lines[0].Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
    foreach ($line in ($lines | Select-Object -Skip 2)) {
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        $row = @{}
        for ($i = 0; $i -lt $headers.Count; $i++) { $row[$headers[$i]] = if ($i -lt $cells.Count) { $cells[$i] } else { '' } }
        Write-Output $row
    }
}

function Get-DesignRequirements([string]$Text) {
    $section = ''; $fence = ''; $lineNumber = 0
    foreach ($line in ($Text -split '\r?\n')) {
        $lineNumber++
        if ($line -match '^\s*(`{3,}|~{3,})') {
            $mark = $Matches[1].Substring(0, 1)
            if (-not $fence) { $fence = $mark } elseif ($fence -eq $mark) { $fence = '' }
            continue
        }
        if ($fence) { continue }
        if ($line -match '^##\s+(.+)$') { $section = $Matches[1]; continue }
        $sequence = $section -match '^(Implementation|Build|Milestone) (Sequence|Order)$'
        $inScope = $sequence -or ($section -match '(?i)\b(requirements?|behavio[u]?rs?|integrations?|implementation|build|functional)\b' -and $section -notmatch '^(Build-intake|Design Coverage|Coverage Builds)')
        if ($line -match '^###\s+(Phase\s+.*|Contract Freeze Gate.*|Value Review.*)$') {
            [pscustomobject]@{ id = "L$lineNumber"; text = $Matches[1].Trim() }
        } elseif ($inScope -and $line -match '^\s*(?:[-*+]\s+|\d+[.)]\s+)(.+)$') {
            $textValue = $Matches[1].Trim().Replace('|', '&#124;')
            [pscustomobject]@{ id = "L$lineNumber"; text = $textValue }
        }
    }
}

function Get-DesignMilestoneMap([string]$Text) {
    # Match build-roadmap's primary-section priority and phase fallback, including
    # designs containing both formats. Inventory all requirements, derive only real milestones.
    $items = @(); $offset = 0
    foreach ($heading in @('Implementation Sequence', 'Implementation Order', 'Build Sequence', 'Build Order', 'Milestone Sequence')) {
        $section = [regex]::Match($Text, '(?ms)^##\s+' + [regex]::Escape($heading) + '\s*\r?\n(.*?)(?=^##\s+|\z)')
        if ($section.Success) {
            $offset = $section.Groups[1].Index
            $items = @([regex]::Matches($section.Groups[1].Value, '(?m)^\d+[.)][ \t]+[^\r\n]+'))
            break
        }
    }
    if (-not $items.Count) {
        $offset = 0
        $items = @([regex]::Matches($Text, '(?m)^###\s+(Phase\s+[0-9A-Za-z\- ]+.*|Contract Freeze Gate.*|Value Review.*)$'))
    }
    $map = @{}; $index = 0
    foreach ($item in $items) {
        $index++
        $line = [regex]::Matches($Text.Substring(0, ($offset + $item.Index)), '\r?\n').Count + 1
        $map["L$line"] = 'M{0:D2}' -f $index
    }
    return $map
}

function New-DesignCoverage([string]$DesignPath) {
    $raw = Get-Content -Raw -LiteralPath $DesignPath
    $parent = Get-CoverageScalar $raw 'coverage_design'
    $origin = if ($parent) { Resolve-CoveragePath $DesignPath $parent } else { [IO.Path]::GetFullPath($DesignPath) }
    if ([IO.Path]::GetFileName($DesignPath) -match '^build-input(?:-|\.md$)' -and $origin -eq [IO.Path]::GetFullPath($DesignPath)) {
        throw 'COVERAGE_SOURCE_MISSING: build-input files must name the full unsplit design in coverage_design.'
    }
    $build = Get-CoverageScalar $raw 'coverage_build'
    if (-not $build) { $build = 'main' }
    $table = Get-CoverageSection $raw 'Design Coverage'
    if (-not $table) {
        $originRaw = Get-Content -Raw -LiteralPath $origin
        $milestoneMap = Get-DesignMilestoneMap $originRaw
        $rows = foreach ($req in @(Get-DesignRequirements $originRaw)) {
            # Only sequence/phase units in an unsplit design have an unambiguous owner.
            $mid = if ($origin -eq [IO.Path]::GetFullPath($DesignPath) -and $milestoneMap.ContainsKey($req.id)) { $milestoneMap[$req.id] } else { '-' }
            "| $($req.id) | $($req.text) | $build | $mid | - | - |"
        }
        $table = "| requirement-id | requirement | build-id | milestone-id | owner | reason |`n| --- | --- | --- | --- | --- | --- |`n" + ($rows -join "`n")
    }
    $builds = Get-CoverageSection $raw 'Coverage Builds'
    if (-not $builds) { $builds = "| build-id | input-path |`n| --- | --- |`n| $build | $([IO.Path]::GetFullPath($DesignPath)) |" }
    # Resolve paths before moving the table to a possibly different output directory.
    $buildRows = @(Get-CoverageRows ("## Coverage Builds`n$builds") 'Coverage Builds')
    $builds = "| build-id | input-path |`n| --- | --- |`n" + (($buildRows | ForEach-Object { "| $($_['build-id']) | $(Resolve-CoveragePath $DesignPath $_['input-path']) |" }) -join "`n")
    return [pscustomobject]@{ origin = $origin; build = $build; table = $table; builds = $builds }
}

function Test-DesignCoverage([string]$RoadmapPath, [string]$Text, [string[]]$MilestoneIds) {
    $errors = [Collections.Generic.List[string]]::new()
    $source = Get-CoverageScalar $Text 'coverage_design'
    if (-not $source) { $source = Get-CoverageScalar $Text 'source_artifact' }
    if (-not $source) { return 'COVERAGE_SOURCE_MISSING: name coverage_design (the full unsplit design), then emit Design Coverage.' }
    $source = Resolve-CoveragePath $RoadmapPath $source
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return "COVERAGE_SOURCE_MISSING: $source" }
    if ([IO.Path]::GetFileName($source) -match '^build-input(?:-|\.md$)') { return "COVERAGE_SOURCE_MISSING: use the full unsplit design, not $source" }
    $requirements = @(Get-DesignRequirements (Get-Content -Raw -LiteralPath $source))
    if (-not $requirements.Count) { $errors.Add('COVERAGE_EMPTY: no requirement units; add a Requirements list to the design.') }
    $rows = @(Get-CoverageRows $Text)
    $builds = @(Get-CoverageRows $Text 'Coverage Builds')
    $localBuild = Get-CoverageScalar $Text 'coverage_build'
    if (-not $localBuild) { $localBuild = 'main' }
    $buildMap = @{}
    foreach ($b in $builds) {
        $id = $b['build-id']
        if (-not $id -or $buildMap.ContainsKey($id)) { $errors.Add("COVERAGE_BUILD_INVALID: duplicate/empty build '$id'"); continue }
        $inputPath = Resolve-CoveragePath $RoadmapPath $b['input-path']
        $buildMap[$id] = $inputPath
    }
    if (-not $buildMap.ContainsKey($localBuild)) { $errors.Add("COVERAGE_BUILD_INVALID: local build '$localBuild' is missing") }
    foreach ($req in $requirements) {
        $matches = @($rows | Where-Object { $_['requirement-id'] -eq $req.id })
        if ($matches.Count -eq 0) { $errors.Add("COVERAGE_UNMAPPED: $($req.id): $($req.text)"); continue }
        if ($matches.Count -ne 1) { $errors.Add("COVERAGE_DUPLICATE: $($req.id) must have exactly one owner"); continue }
        $r = $matches[0]
        if ($r['requirement'] -cne $req.text) { $errors.Add("COVERAGE_STALE: $($req.id): $($req.text)") }
        if ($r['build-id'] -eq 'out-of-build') {
            if ($r['milestone-id'] -ne '-' -or -not $r['owner'] -or $r['owner'] -eq '-' -or -not $r['reason'] -or $r['reason'] -eq '-') {
                $errors.Add("COVERAGE_OWNER_REQUIRED: $($req.id) needs an out-of-build owner and reason, milestone-id '-'")
            }
        } elseif (-not $r['build-id'] -or -not $buildMap.ContainsKey($r['build-id']) -or $r['milestone-id'] -notmatch '^M\d+$') {
            $errors.Add("COVERAGE_UNMAPPED: $($req.id): $($req.text)")
        } elseif ($r['build-id'] -eq $localBuild -and $MilestoneIds -notcontains $r['milestone-id']) {
            $errors.Add("COVERAGE_MILESTONE_UNKNOWN: $($req.id) -> $($r['milestone-id'])")
        }
    }
    foreach ($r in $rows) {
        if (@($requirements | ForEach-Object { $_.id }) -notcontains $r['requirement-id']) { $errors.Add("COVERAGE_UNKNOWN: $($r['requirement-id'])") }
    }
    foreach ($b in $buildMap.Keys) {
        $inputPath = $buildMap[$b]
        if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) { $errors.Add("COVERAGE_BUILD_MISSING: $b -> $inputPath"); continue }
        $inputRaw = Get-Content -Raw -LiteralPath $inputPath
        if ($buildMap.Count -gt 1) {
            $peer = New-DesignCoverage $inputPath
            if ($peer.origin -ne $source -or $peer.build -ne $b -or $peer.table -cne (Get-CoverageSection $Text 'Design Coverage') -or $peer.builds -cne (Get-CoverageSection $Text 'Coverage Builds')) {
                $errors.Add("COVERAGE_SPLIT_MISMATCH: $b must carry the same shared coverage table, build registry and full design")
            }
            $peerIds = @((Get-DesignMilestoneMap $inputRaw).Values)
            foreach ($r in @($rows | Where-Object { $_['build-id'] -eq $b })) {
                if ($peerIds -notcontains $r['milestone-id']) { $errors.Add("COVERAGE_MILESTONE_UNKNOWN: $($r['requirement-id']) -> ${b}/$($r['milestone-id'])") }
            }
        }
    }
    return $errors.ToArray()
}

function Get-OutOfBuildChecklist([string]$Text) {
    $rows = @(Get-CoverageRows $Text | Where-Object { $_['build-id'] -eq 'out-of-build' })
    if ($rows.Count) {
        "## Out-of-build go-live checklist`n`nComplete each item and record evidence before switch-on; build PASS does not complete these items.`n"
        foreach ($r in $rows) { "- [ ] $($r['requirement-id']): $($r['requirement']) -- owner: $($r['owner']); reason: $($r['reason'])" }
    }
}
