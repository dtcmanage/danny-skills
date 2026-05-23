param(
    [Parameter(Mandatory)]
    [string]$RoadmapPath,

    [string]$SchemaPath = "",

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-FrontmatterBlock {
    param([string]$Text)

    if ($Text -notmatch '(?ms)^---\s*\r?\n(.*?)\r?\n---\s*') {
        return $null
    }
    return $Matches[1]
}

function Get-YamlScalar {
    param(
        [string]$Yaml,
        [string]$Key
    )

    $pattern = "(?m)^" + [regex]::Escape($Key) + "\s*:\s*(.+)$"
    $match = [regex]::Match($Yaml, $pattern)
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value.Trim().Trim("'").Trim('"')
}

function Get-SectionBody {
    param(
        [string]$Text,
        [string]$Heading
    )

    $escaped = [regex]::Escape($Heading)
    $pattern = "(?ms)^##\s+" + $escaped + "\s*\r?\n(.*?)(?=^##\s+|\z)"
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) {
        return $null
    }
    return $match.Groups[1].Value.Trim()
}

function Convert-MarkdownTable {
    param([string]$SectionBody)

    if ([string]::IsNullOrWhiteSpace($SectionBody)) {
        return @()
    }

    $tableLines = @()
    foreach ($line in ($SectionBody -split "`r?`n")) {
        if ($line.Trim().StartsWith('|')) {
            $tableLines += $line
        }
        elseif ($tableLines.Count -gt 0) {
            break
        }
    }

    if ($tableLines.Count -lt 2) {
        return @()
    }

    $headerCells = ($tableLines[0].Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
    $rows = @()

    for ($i = 2; $i -lt $tableLines.Count; $i++) {
        $rowLine = $tableLines[$i].Trim()
        if (-not $rowLine.StartsWith('|')) { continue }
        $cells = ($rowLine.Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        $obj = [ordered]@{}
        for ($c = 0; $c -lt $headerCells.Count; $c++) {
            $name = $headerCells[$c]
            $value = if ($c -lt $cells.Count) { $cells[$c] } else { "" }
            $obj[$name] = $value
        }
        $rows += [pscustomobject]$obj
    }

    return $rows
}

function Split-DependencyList {
    param([string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    if ($Raw -in @('-', 'none', 'None', 'n/a', 'N/A')) { return @() }

    $clean = $Raw -replace '[\[\]]', ''
    $parts = $clean -split ','
    return @($parts | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-Major {
    param([string]$VersionText)

    $match = [regex]::Match($VersionText, '^(\d+)')
    if (-not $match.Success) { return $null }
    return [int]$match.Groups[1].Value
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptDir
$resolved = (Get-Item -LiteralPath $skillRoot).ResolveLinkTarget($true)
if ($resolved) { $skillRoot = $resolved.FullName }

if ([string]::IsNullOrWhiteSpace($SchemaPath)) {
    $SchemaPath = Join-Path $skillRoot 'references\roadmap-schema.md'
}

if (-not (Test-Path -LiteralPath $RoadmapPath)) {
    throw "SCHEMA_REQUIRED_SECTION_MISSING: roadmap file not found: $RoadmapPath"
}
if (-not (Test-Path -LiteralPath $SchemaPath)) {
    throw "SCHEMA_REQUIRED_SECTION_MISSING: schema file not found: $SchemaPath"
}

$roadmapRaw = Get-Content -LiteralPath $RoadmapPath -Raw
$schemaRaw = Get-Content -LiteralPath $SchemaPath -Raw

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

$roadmapFrontmatter = Get-FrontmatterBlock -Text $roadmapRaw
if (-not $roadmapFrontmatter) {
    $errors.Add('SCHEMA_REQUIRED_SECTION_MISSING: missing roadmap frontmatter block')
}

$schemaVersionText = if ($roadmapFrontmatter) { Get-YamlScalar -Yaml $roadmapFrontmatter -Key 'schema_version' } else { $null }
if (-not $schemaVersionText) {
    $errors.Add('SCHEMA_REQUIRED_COLUMN_MISSING: frontmatter schema_version is required')
}

$schemaHeaderMajorText = $null
if ($schemaRaw -match '(?m)^producer_current_version\s*:\s*(.+)$') {
    $schemaHeaderMajorText = $Matches[1].Trim().Trim("'").Trim('"')
}
else {
    $errors.Add('SCHEMA_REQUIRED_COLUMN_MISSING: schema producer_current_version is required in roadmap-schema.md')
}

$roadmapMajor = if ($schemaVersionText) { Get-Major -VersionText $schemaVersionText } else { $null }
$producerMajor = if ($schemaHeaderMajorText) { Get-Major -VersionText $schemaHeaderMajorText } else { $null }

if ($null -eq $roadmapMajor) {
    $errors.Add('SCHEMA_REQUIRED_COLUMN_MISSING: schema_version must begin with an integer major')
}
if ($null -eq $producerMajor) {
    $errors.Add('SCHEMA_REQUIRED_COLUMN_MISSING: producer_current_version must begin with an integer major')
}
if (($null -ne $roadmapMajor) -and ($null -ne $producerMajor) -and ($roadmapMajor -ne $producerMajor)) {
    $errors.Add("SCHEMA_VERSION_MISMATCH: roadmap schema_version major '$roadmapMajor' does not match producer_current_version major '$producerMajor'")
}

$requiredSections = @(
    'Milestones',
    'Chunks',
    'Verification Manifest',
    'Dependency Graph (Mermaid)',
    'Sequential Gantt (Mermaid)'
)

$sectionMap = @{}
foreach ($section in $requiredSections) {
    $body = Get-SectionBody -Text $roadmapRaw -Heading $section
    if ($null -eq $body) {
        $errors.Add("SCHEMA_REQUIRED_SECTION_MISSING: missing section '## $section'")
    }
    $sectionMap[$section] = $body
}

$milestones = Convert-MarkdownTable -SectionBody $sectionMap['Milestones']
$chunks = Convert-MarkdownTable -SectionBody $sectionMap['Chunks']
$manifest = Convert-MarkdownTable -SectionBody $sectionMap['Verification Manifest']

function Assert-Columns {
    param(
        [array]$Rows,
        [string[]]$Required,
        [string]$TableName,
        [System.Collections.Generic.List[string]]$ErrorsRef
    )

    if ($Rows.Count -eq 0) {
        $ErrorsRef.Add("SCHEMA_REQUIRED_SECTION_MISSING: table '$TableName' has no data rows")
        return
    }

    $props = @($Rows[0].PSObject.Properties.Name)
    foreach ($col in $Required) {
        if ($props -notcontains $col) {
            $ErrorsRef.Add("SCHEMA_REQUIRED_COLUMN_MISSING: table '$TableName' missing required column '$col'")
        }
    }
}

Assert-Columns -Rows $milestones -Required @('id', 'name', 'dependencies', 'chunks', 'verification-mode', 'baseline-floor', 'acceptance-checks', 'decision-basis') -TableName 'Milestones' -ErrorsRef $errors
Assert-Columns -Rows $chunks -Required @('chunk-slug', 'milestone-id', 'model-routing', 'reference-pack-entitlement') -TableName 'Chunks' -ErrorsRef $errors
Assert-Columns -Rows $manifest -Required @('check-id', 'milestone-id', 'execution-scope', 'prerequisites', 'mode', 'procedure') -TableName 'Verification Manifest' -ErrorsRef $errors

if ($sectionMap['Dependency Graph (Mermaid)'] -and ($sectionMap['Dependency Graph (Mermaid)'] -notmatch '(?ms)(```|~~~)mermaid\s*\r?\n\s*graph\s+TD')) {
    $errors.Add("SCHEMA_REQUIRED_SECTION_MISSING: dependency graph section must contain a mermaid graph TD block")
}
if ($sectionMap['Sequential Gantt (Mermaid)'] -and ($sectionMap['Sequential Gantt (Mermaid)'] -notmatch '(?ms)(```|~~~)mermaid\s*\r?\n\s*gantt')) {
    $errors.Add("SCHEMA_REQUIRED_SECTION_MISSING: gantt section must contain a mermaid gantt block")
}

$milestoneIds = @($milestones | ForEach-Object { [string]$_.id })
$idSet = New-Object System.Collections.Generic.HashSet[string]

foreach ($id in $milestoneIds) {
    if ([string]::IsNullOrWhiteSpace($id)) {
        $errors.Add('MILESTONE_INDEPENDENCE_VIOLATION: milestone id cannot be blank')
        continue
    }
    if (-not $idSet.Add($id)) {
        $errors.Add("MILESTONE_INDEPENDENCE_VIOLATION: duplicate milestone id '$id'")
    }
}

$adj = @{}
foreach ($m in $milestones) {
    $mid = [string]$m.id
    $deps = Split-DependencyList -Raw ([string]$m.dependencies)
    $adj[$mid] = $deps

    foreach ($dep in $deps) {
        if (-not $idSet.Contains($dep)) {
            $errors.Add("MILESTONE_INDEPENDENCE_VIOLATION: milestone '$mid' depends on unknown id '$dep'")
        }
        if ($dep -eq $mid) {
            $errors.Add("DEPENDENCY_CYCLE: milestone '$mid' depends on itself")
        }
    }
}

$color = @{}
foreach ($id in $idSet) { $color[$id] = 'white' }

function Visit-Node {
    param(
        [string]$Node,
        [hashtable]$Adj,
        [hashtable]$Color,
        [System.Collections.Generic.List[string]]$ErrorsRef,
        [System.Collections.Generic.List[string]]$PathStack
    )

    $Color[$Node] = 'gray'
    $PathStack.Add($Node)

    foreach ($next in $Adj[$Node]) {
        if (-not $Color.ContainsKey($next)) { continue }
        if ($Color[$next] -eq 'gray') {
            $cycle = (($PathStack + $next) -join ' -> ')
            $ErrorsRef.Add("DEPENDENCY_CYCLE: $cycle")
            continue
        }
        if ($Color[$next] -eq 'white') {
            Visit-Node -Node $next -Adj $Adj -Color $Color -ErrorsRef $ErrorsRef -PathStack $PathStack
        }
    }

    [void]$PathStack.RemoveAt($PathStack.Count - 1)
    $Color[$Node] = 'black'
}

foreach ($id in $idSet) {
    if ($color[$id] -eq 'white') {
        $path = New-Object System.Collections.Generic.List[string]
        Visit-Node -Node $id -Adj $adj -Color $color -ErrorsRef $errors -PathStack $path
    }
}

$chunkSlugSet = New-Object System.Collections.Generic.HashSet[string]
$chunksByMilestone = @{}
foreach ($mId in $idSet) { $chunksByMilestone[$mId] = 0 }

foreach ($chunk in $chunks) {
    $slug = [string]$chunk.'chunk-slug'
    $mId = [string]$chunk.'milestone-id'
    $routing = [string]$chunk.'model-routing'
    $entitlement = [string]$chunk.'reference-pack-entitlement'

    if ([string]::IsNullOrWhiteSpace($slug)) {
        $errors.Add('CHUNK_PARALLELISM_FEASIBILITY_VIOLATION: chunk-slug cannot be blank')
    }
    elseif (-not $chunkSlugSet.Add($slug)) {
        $errors.Add("CHUNK_PARALLELISM_FEASIBILITY_VIOLATION: duplicate chunk-slug '$slug'")
    }

    if (-not $idSet.Contains($mId)) {
        $errors.Add("MILESTONE_INDEPENDENCE_VIOLATION: chunk '$slug' references unknown milestone-id '$mId'")
    }
    else {
        $chunksByMilestone[$mId] = [int]$chunksByMilestone[$mId] + 1
    }

    if ([string]::IsNullOrWhiteSpace($routing)) {
        $errors.Add("CHUNK_PARALLELISM_FEASIBILITY_VIOLATION: chunk '$slug' missing model-routing")
    }
    if ([string]::IsNullOrWhiteSpace($entitlement)) {
        $errors.Add("CHUNK_PARALLELISM_FEASIBILITY_VIOLATION: chunk '$slug' missing reference-pack-entitlement")
    }
}

foreach ($mId in $idSet) {
    if ([int]$chunksByMilestone[$mId] -lt 1) {
        $errors.Add("MILESTONE_INDEPENDENCE_VIOLATION: milestone '$mId' has no chunk rows")
    }
}

$allowedScopes = @('milestone_local', 'integration', 'integration_only')
$allowedModes = @('machine-checkable', 'agent')

foreach ($item in $manifest) {
    $checkId = [string]$item.'check-id'
    $mId = [string]$item.'milestone-id'
    $scope = [string]$item.'execution-scope'
    $mode = [string]$item.mode

    if (-not $idSet.Contains($mId)) {
        $errors.Add("MILESTONE_INDEPENDENCE_VIOLATION: verification check '$checkId' references unknown milestone-id '$mId'")
    }
    if ($allowedScopes -notcontains $scope) {
        $errors.Add("SCHEMA_REQUIRED_COLUMN_MISSING: verification check '$checkId' has invalid execution-scope '$scope'")
    }
    if ($allowedModes -notcontains $mode) {
        $errors.Add("SCHEMA_REQUIRED_COLUMN_MISSING: verification check '$checkId' has invalid mode '$mode'")
    }
}

$result = [pscustomobject]@{
    roadmap_path = (Resolve-Path -LiteralPath $RoadmapPath).Path
    schema_path = (Resolve-Path -LiteralPath $SchemaPath).Path
    schema_version_major = $roadmapMajor
    producer_major = $producerMajor
    milestone_count = $milestones.Count
    chunk_count = $chunks.Count
    verification_item_count = $manifest.Count
    pass = ($errors.Count -eq 0)
    errors = @($errors)
    warnings = @($warnings)
}

if (-not $result.pass) {
    if ($Json) {
        $result | ConvertTo-Json -Depth 6
        exit 1
    }
    throw (("Roadmap validation failed:`n- " + ($errors -join "`n- ")))
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
}
else {
    Write-Output ("PASS: roadmap schema validated ({0} milestones, {1} chunks, {2} verification checks)" -f $result.milestone_count, $result.chunk_count, $result.verification_item_count)
}
