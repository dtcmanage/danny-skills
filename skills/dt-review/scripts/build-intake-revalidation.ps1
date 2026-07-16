Set-StrictMode -Version Latest

function ConvertTo-DtReviewNormalizedMarkdown([string]$Value) {
    return (($Value -replace "`r`n", "`n" -replace "`r", "`n") -split "`n" |
        ForEach-Object { $_.TrimEnd() } |
        Join-String -Separator "`n").Trim()
}

function Get-DtReviewBuildIntakeSection([string]$ReviewContextPath) {
    if (-not (Test-Path -LiteralPath $ReviewContextPath -PathType Leaf)) {
        throw "Review context evidence map not found: $ReviewContextPath"
    }

    $context = [System.IO.File]::ReadAllText($ReviewContextPath)
    $matches = @([regex]::Matches($context, '(?ims)^## Build-intake revalidation\s*\r?\n(?<section>.*?)(?=^##\s|\z)'))
    if ($matches.Count -ne 1) {
        throw "Review context must contain exactly one Build-intake revalidation section: $ReviewContextPath"
    }

    $section = '## Build-intake revalidation' + "`n" + $matches[0].Groups['section'].Value.Trim()
    $normalizedSection = ConvertTo-DtReviewNormalizedMarkdown $section
    $lines = @(($normalizedSection -split "`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -lt 3 -or
        $lines[1] -notmatch '^\|\s*Claim\s*\|\s*Evidence/source\s*\|\s*Checked at\s*\|\s*Recheck gate\s*\|\s*$' -or
        $lines[2] -notmatch '^\|\s*:?-{3,}:?\s*\|\s*:?-{3,}:?\s*\|\s*:?-{3,}:?\s*\|\s*:?-{3,}:?\s*\|\s*$') {
        throw "Build-intake revalidation must begin with the canonical four-column table: $ReviewContextPath"
    }

    return ConvertTo-DtReviewNormalizedMarkdown $section
}

function Get-DtReviewBuildIntakeSectionFromDraft([string]$DraftBody) {
    $matches = @([regex]::Matches($DraftBody, '(?ims)^## Build-intake revalidation\s*\r?\n(?<section>.*?)(?=^##\s|\z)'))
    if ($matches.Count -eq 0) { return $null }
    if ($matches.Count -ne 1) {
        throw 'Draft contains more than one Build-intake revalidation section.'
    }
    return ConvertTo-DtReviewNormalizedMarkdown ('## Build-intake revalidation' + "`n" + $matches[0].Groups['section'].Value.Trim())
}

function Add-DtReviewBuildIntakeSection([string]$DraftBody, [string]$ReviewContextPath) {
    $expected = Get-DtReviewBuildIntakeSection -ReviewContextPath $ReviewContextPath
    $actual = Get-DtReviewBuildIntakeSectionFromDraft -DraftBody $DraftBody
    if ($null -ne $actual) {
        if ($actual -cne $expected) {
            throw 'Draft Build-intake revalidation does not exactly carry the review-context evidence map.'
        }
        return $DraftBody
    }
    return $DraftBody.TrimEnd() + "`n`n" + $expected + "`n"
}

function Assert-DtReviewBuildIntakeSection([string]$DraftBody, [string]$ReviewContextPath, [string]$Label = 'Draft') {
    $expected = Get-DtReviewBuildIntakeSection -ReviewContextPath $ReviewContextPath
    $actual = Get-DtReviewBuildIntakeSectionFromDraft -DraftBody $DraftBody
    if ($null -eq $actual) {
        throw "$Label must include the Build-intake revalidation section from review-context.md."
    }
    if ($actual -cne $expected) {
        throw "$Label Build-intake revalidation does not exactly carry the review-context evidence map."
    }
}
