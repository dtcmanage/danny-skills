param(
    [Parameter(Mandatory)]
    [string]$RoadmapPath,

    [string]$OutputDirectory = "",

    [switch]$ForceCsvFallback
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

    $headers = ($tableLines[0].Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
    $rows = @()

    for ($i = 2; $i -lt $tableLines.Count; $i++) {
        $line = $tableLines[$i].Trim()
        if (-not $line.StartsWith('|')) { continue }
        $cells = ($line.Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        $obj = [ordered]@{}
        for ($c = 0; $c -lt $headers.Count; $c++) {
            $obj[$headers[$c]] = if ($c -lt $cells.Count) { $cells[$c] } else { "" }
        }
        $rows += [pscustomobject]$obj
    }

    return $rows
}

if (-not (Test-Path -LiteralPath $RoadmapPath)) {
    throw "Roadmap not found: $RoadmapPath"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptDir
$resolved = (Get-Item -LiteralPath $skillRoot).ResolveLinkTarget($true)
if ($resolved) { $skillRoot = $resolved.FullName }

$validatorPath = Join-Path $scriptDir 'roadmap-validator.ps1'
if (-not (Test-Path -LiteralPath $validatorPath)) {
    throw "Validator script not found: $validatorPath"
}

$null = & $validatorPath -RoadmapPath $RoadmapPath

$roadmapRaw = Get-Content -LiteralPath $RoadmapPath -Raw
$frontmatter = Get-FrontmatterBlock -Text $roadmapRaw
$schemaVersion = if ($frontmatter) { Get-YamlScalar -Yaml $frontmatter -Key 'schema_version' } else { '1' }

$milestonesSection = Get-SectionBody -Text $roadmapRaw -Heading 'Milestones'
$milestones = Convert-MarkdownTable -SectionBody $milestonesSection
if ($milestones.Count -eq 0) {
    throw "Milestones table is empty in roadmap: $RoadmapPath"
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Split-Path -Parent (Resolve-Path -LiteralPath $RoadmapPath).Path
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$exportRows = foreach ($m in $milestones) {
    [pscustomobject]@{
        id = [string]$m.id
        name = [string]$m.name
        dependencies = [string]$m.dependencies
        chunks = [string]$m.chunks
        verification_mode = [string]$m.'verification-mode'
        status = 'pending'
        percent_complete = 0
        owner = 'unassigned'
    }
}

$xlsxPath = Join-Path $OutputDirectory 'milestones.xlsx'
$csvPath = Join-Path $OutputDirectory 'milestones.csv'
$mdPath = Join-Path $OutputDirectory 'milestones-table.md'

$usedFallback = $ForceCsvFallback
$xlsxError = $null

if (-not $ForceCsvFallback) {
    $hasImportExcel = $null -ne (Get-Module -ListAvailable -Name ImportExcel)
    if ($hasImportExcel) {
        try {
            Import-Module ImportExcel -ErrorAction Stop
            $exportRows | Export-Excel -Path $xlsxPath -WorksheetName 'Milestones' -TableName 'Milestones' -AutoSize -ClearSheet
            @(
                [pscustomobject]@{ key = 'schema_version'; value = $schemaVersion },
                [pscustomobject]@{ key = 'generated_at_utc'; value = (Get-Date).ToUniversalTime().ToString('o') },
                [pscustomobject]@{ key = 'source_roadmap'; value = (Resolve-Path -LiteralPath $RoadmapPath).Path }
            ) | Export-Excel -Path $xlsxPath -WorksheetName 'Metadata' -TableName 'Metadata' -AutoSize -ClearSheet
        }
        catch {
            $usedFallback = $true
            $xlsxError = $_.Exception.Message
        }
    }
    else {
        $usedFallback = $true
        $xlsxError = 'ImportExcel module unavailable (anthropic-skills:xlsx unavailable in this environment).'
    }
}

if ($usedFallback) {
    $exportRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Milestones Table (Fallback)')
    $lines.Add('')
    $lines.Add('- debt: regenerate milestones.xlsx before next milestone bump')
    if ($xlsxError) {
        $lines.Add("- fallback-reason: $xlsxError")
    }
    $lines.Add("- schema_version: $schemaVersion")
    $lines.Add('')
    $lines.Add('| id | name | dependencies | chunks | verification_mode | status | percent_complete | owner |')
    $lines.Add('| :-- | :-- | :-- | :-- | :-- | :-- | --: | :-- |')

    foreach ($r in $exportRows) {
        $lines.Add("| $($r.id) | $($r.name) | $($r.dependencies) | $($r.chunks) | $($r.verification_mode) | $($r.status) | $($r.percent_complete) | $($r.owner) |")
    }

    Set-Content -LiteralPath $mdPath -Value ($lines -join "`n") -Encoding UTF8

    [pscustomobject]@{
        mode = 'csv_fallback'
        schema_version = $schemaVersion
        roadmap_path = (Resolve-Path -LiteralPath $RoadmapPath).Path
        milestones_csv = $csvPath
        milestones_table = $mdPath
        debt = 'regenerate milestones.xlsx before next milestone bump'
        fallback_reason = $xlsxError
    } | ConvertTo-Json -Depth 5
    exit 0
}

[pscustomobject]@{
    mode = 'xlsx'
    schema_version = $schemaVersion
    roadmap_path = (Resolve-Path -LiteralPath $RoadmapPath).Path
    milestones_xlsx = $xlsxPath
} | ConvertTo-Json -Depth 5
