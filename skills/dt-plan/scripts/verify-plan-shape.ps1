# Validate a plan-draft.md against the plan-shape contract
# (repo-level references/plan-shape.md) before it is handed to a consumer.
#
# dt-plan is the producer; this is the producer-side gate, so a shape gap
# surfaces at save time instead of at dt-review intake one skill later.
#
# Returns JSON:
#   { ok, path, shape_version, missing_sections, warnings, checks }
#
# Exit code is 0 whether or not the plan passes; read `ok`. A non-zero exit
# means the script could not evaluate the plan at all (unreadable path).

param(
    [Parameter(Mandatory)]
    [string]$Path,

    # Accepted for symmetry with the other pack scripts; output is always JSON.
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "PLAN_SHAPE: no plan file at '$Path'."
}

$raw = Get-Content -LiteralPath $Path -Raw
if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "PLAN_SHAPE: plan file at '$Path' is empty."
}

$missing = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

# --- frontmatter / shape_version -------------------------------------------
$shapeVersion = $null
if ($raw -match '(?s)\A---\r?\n(.*?)\r?\n---\r?\n') {
    $frontmatter = $Matches[1]
    if ($frontmatter -match '(?m)^shape_version\s*:\s*(\d+)\s*$') {
        $shapeVersion = [int]$Matches[1]
    } else {
        $missing.Add('frontmatter: shape_version')
    }
} else {
    $missing.Add('frontmatter block')
}

# Current accepted value is 1. An unknown major is a genuine user decision
# (the soft contract), not something this script silently adapts.
if ($null -ne $shapeVersion -and $shapeVersion -ne 1) {
    $warnings.Add("shape_version is $shapeVersion; the current accepted value is 1. Consumers will ask before adapting.")
}

# --- required sections ------------------------------------------------------
# Header text must match exactly: dt-review copies the plan verbatim to
# draft-v1.md and matches '^## Build-intake revalidation$' as a hard gate.
$requiredSections = [ordered]@{
    'Build-intake revalidation' = '(?m)^##\s+Build-intake revalidation\s*$'
    'Open Questions'            = '(?m)^##\s+Open Questions\s*$'
    'Out of Scope'              = '(?m)^##\s+Out of Scope\s*$'
}

foreach ($name in $requiredSections.Keys) {
    if ($raw -notmatch $requiredSections[$name]) {
        $missing.Add("## $name")
    }
}

# --- title and metadata lines ----------------------------------------------
if ($raw -notmatch '(?m)^#\s+\S') {
    $missing.Add('title line (# <Project> Plan)')
}

foreach ($field in @('Date', 'Surface', 'Scope', 'Dimension framework')) {
    if ($raw -notmatch ('(?m)^\*\*' + [regex]::Escape($field) + ':\*\*')) {
        $missing.Add("metadata line **$($field):**")
    }
}

# --- substantive body -------------------------------------------------------
$allH2 = [regex]::Matches($raw, '(?m)^##\s+(.+?)\s*$') | ForEach-Object { $_.Groups[1].Value }
$reserved = @('Build-intake revalidation', 'Open Questions', 'Out of Scope')
$substantive = @($allH2 | Where-Object { $reserved -notcontains $_ })
if ($substantive.Count -lt 1) {
    $missing.Add('at least one substantive section')
}

# --- revalidation table contents -------------------------------------------
# The section existing is what clears dt-review's Round-1 gate; an empty one
# still clears it but tells dt-build nothing, so warn rather than fail.
if ($raw -match '(?ms)^##\s+Build-intake revalidation\s*$(.*?)(?=^##\s|\z)') {
    $tableBody = $Matches[1]
    $rows = @([regex]::Matches($tableBody, '(?m)^\|(?!\s*-{2,})(?!\s*Claim\b).*\|\s*$'))
    if ($rows.Count -eq 0) {
        $warnings.Add('Build-intake revalidation section has no rows. Add one row per external claim, or a single row reading "No external claims - self-contained plan."')
    }
    if ($tableBody -match '<assumption>' -or $tableBody -match '<what the plan assumes') {
        $warnings.Add('Build-intake revalidation table still contains template placeholders.')
    }
}

# --- leftover placeholders --------------------------------------------------
if ($raw -match '(?m)^##\s+<Section \d') {
    $missing.Add('unfilled template section headers remain')
}

$ok = ($missing.Count -eq 0)

[pscustomobject]@{
    ok               = $ok
    path             = (Resolve-Path -LiteralPath $Path).Path
    shape_version    = $shapeVersion
    missing_sections = @($missing)
    warnings         = @($warnings)
    checks           = [pscustomobject]@{
        substantive_sections = $substantive.Count
        headings             = @($allH2)
    }
} | ConvertTo-Json -Depth 5
