# markdown-section-diff.ps1
# Computes section-level ADDED / CHANGED / REMOVED statuses between a plan markdown
# and a design markdown. Parsed at H2 (##) section granularity.

Set-StrictMode -Version Latest

function Normalize-SectionBody {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    $normalized = $Text -replace "`r", ""
    $normalized = [regex]::Replace($normalized, "[ \t]+", " ")
    $normalized = [regex]::Replace($normalized, "\n{3,}", "`n`n")
    return $normalized.Trim()
}

function Get-MarkdownSections {
    param([string]$Text)

    $sections = New-Object System.Collections.Generic.List[object]
    $working = if ($null -eq $Text) { "" } else { $Text -replace "`r", "" }
    $matches = [regex]::Matches($working, '(?m)^##\s+(.+?)\s*$')

    if ($matches.Count -eq 0) {
        $sections.Add([pscustomobject]@{
            Title = "Document"
            Body  = $working.Trim()
        })
        return $sections
    }

    $firstIdx = $matches[0].Index
    $preamble = $working.Substring(0, $firstIdx).Trim()
    if ($preamble.Length -gt 0) {
        $sections.Add([pscustomobject]@{
            Title = "Preamble"
            Body  = $preamble
        })
    }

    for ($i = 0; $i -lt $matches.Count; $i++) {
        $title = $matches[$i].Groups[1].Value.Trim()
        $start = $matches[$i].Index + $matches[$i].Length
        $end = if ($i -lt $matches.Count - 1) { $matches[$i + 1].Index } else { $working.Length }
        $length = [Math]::Max(0, $end - $start)
        $body = if ($length -gt 0) { $working.Substring($start, $length).Trim() } else { "" }

        $sections.Add([pscustomobject]@{
            Title = $title
            Body  = $body
        })
    }

    return $sections
}

function New-MarkdownSectionDiff {
    param(
        [Parameter(Mandatory)]
        [string]$PlanText,

        [Parameter(Mandatory)]
        [string]$DesignText
    )

    $planSections = Get-MarkdownSections -Text $PlanText
    $designSections = Get-MarkdownSections -Text $DesignText

    $planMap = @{}
    foreach ($s in $planSections) {
        if (-not $planMap.ContainsKey($s.Title)) {
            $planMap[$s.Title] = $s
        }
    }

    $designMap = @{}
    foreach ($s in $designSections) {
        if (-not $designMap.ContainsKey($s.Title)) {
            $designMap[$s.Title] = $s
        }
    }

    $allTitles = New-Object System.Collections.Generic.List[string]
    foreach ($s in $designSections) {
        if (-not $allTitles.Contains($s.Title)) { $allTitles.Add($s.Title) }
    }
    foreach ($s in $planSections) {
        if (-not $allTitles.Contains($s.Title)) { $allTitles.Add($s.Title) }
    }

    $diffRows = New-Object System.Collections.Generic.List[object]

    foreach ($title in $allTitles) {
        $planExists = $planMap.ContainsKey($title)
        $designExists = $designMap.ContainsKey($title)

        $planBody = if ($planExists) { [string]$planMap[$title].Body } else { "" }
        $designBody = if ($designExists) { [string]$designMap[$title].Body } else { "" }

        $planNorm = Normalize-SectionBody -Text $planBody
        $designNorm = Normalize-SectionBody -Text $designBody

        $status = "UNCHANGED"
        if (-not $planExists -and $designExists) {
            $status = "ADDED"
        }
        elseif ($planExists -and -not $designExists) {
            $status = "REMOVED"
        }
        elseif ($planNorm -ne $designNorm) {
            $status = "CHANGED"
        }

        $diffRows.Add([pscustomobject]@{
            Title        = $title
            Status       = $status
            PlanLength   = $planNorm.Length
            DesignLength = $designNorm.Length
            PlanBody     = $planBody
            DesignBody   = $designBody
        })
    }

    $added = @($diffRows | Where-Object { $_.Status -eq "ADDED" }).Count
    $changed = @($diffRows | Where-Object { $_.Status -eq "CHANGED" }).Count
    $removed = @($diffRows | Where-Object { $_.Status -eq "REMOVED" }).Count
    $unchanged = @($diffRows | Where-Object { $_.Status -eq "UNCHANGED" }).Count

    return [pscustomobject]@{
        Summary = [pscustomobject]@{
            Added     = $added
            Changed   = $changed
            Removed   = $removed
            Unchanged = $unchanged
            Total     = $diffRows.Count
        }
        Sections = $diffRows
    }
}
