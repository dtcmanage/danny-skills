param(
    [string]$Path = "",
    [string]$Text = "",
    [switch]$Recurse,
    [string[]]$Extensions = @(".md", ".txt", ".log", ".jsonl"),
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# check-downgrade-language.ps1
# ----------------------------
# Deterministic scanner for verbal signatures of "I substituted something thinner
# without flagging it as a downgrade." Reads a file, a folder (with -Recurse), or
# a -Text argument; returns JSON listing matches per phrase, with file:line
# evidence.
#
# Exit codes:
#   0 -- clean (no banned phrases found, or all matches were inside a
#        downgrade_approved_by: danny block)
#   1 -- one or more banned phrases found outside an approval block
#   2 -- usage error (no input, path not found)
#
# The phrase list is calibrated against the 2026-05-27 file-sorter learning-loop
# post-mortem. Tune by editing $BannedPhrases below; keep the list narrow enough
# that false positives are rare but wide enough that a half-hearted build review
# trips it.

$BannedPhrases = @(
    'compatible fallback',
    'deterministic fallback',
    'hash fallback',
    'production can replace',
    'contract stable',
    'scaffold implementation',
    'thinner test',
    'placeholder until',
    'mocked acceptance',
    'happy path only',
    'partial verifier',
    'compatible with deterministic',
    'or-deterministic-hash-fallback'
)

# Co-occurrence rule: "for now" + "later" in the same paragraph fires too.
$CoOccurrenceRule = @{
    name     = 'for-now-and-later'
    needles  = @('for now', 'later')
    scope    = 'paragraph'
}

# Conditional ban: "verifier passes" triggers only if any artifact-missing
# language is also present in the same input.
$ConditionalRule = @{
    name      = 'verifier-passes-with-missing-artifact'
    primary   = 'verifier passes'
    context_needles = @('not shipped', 'no model file', 'manifest only', 'placeholder', 'fallback', 'not yet present')
}

function Get-InputFiles {
    param([string]$Path, [switch]$Recurse, [string[]]$Extensions)
    $files = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $files = @((Resolve-Path -LiteralPath $Path).Path)
    } elseif (Test-Path -LiteralPath $Path -PathType Container) {
        $searchOpt = if ($Recurse) { @{Recurse = $true} } else { @{} }
        $files = Get-ChildItem -LiteralPath $Path @searchOpt -File `
            | Where-Object { $Extensions -contains $_.Extension.ToLowerInvariant() } `
            | Select-Object -ExpandProperty FullName
    } else {
        throw "INPUT_PATH_NOT_FOUND: $Path"
    }
    return $files
}

function Get-ApprovedRanges {
    # Returns a list of {start_line, end_line} ranges where the approval block
    # is active. The block is defined as: a line containing `downgrade_approved_by:`
    # extends approval to the next blank line.
    param([string[]]$Lines)
    $ranges = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match 'downgrade_approved_by\s*:') {
            $start = $i + 1
            $end = $i + 1
            for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
                if ($Lines[$j].Trim() -eq '') { $end = $j; break }
                $end = $j + 1
            }
            $ranges += @{ start = $start; end = $end }
        }
    }
    return $ranges
}

function Test-LineApproved {
    param([int]$LineNumber, [array]$Ranges)
    foreach ($r in $Ranges) {
        if ($LineNumber -ge $r.start -and $LineNumber -le $r.end) { return $true }
    }
    return $false
}

function Scan-Content {
    param([string]$SourceLabel, [string]$Content)
    # NOTE: do NOT name a local variable $matches -- PowerShell's -match
    # operator implicitly rebinds the automatic $Matches (case-insensitive
    # variable name) on every call, which would corrupt the accumulator.
    $hits = New-Object System.Collections.Generic.List[object]
    $lines = $Content -split "(`r`n|`n)"
    # The split keeps the line terminators as separate elements; collapse.
    $lines = @($lines | Where-Object { $_ -ne "`n" -and $_ -ne "`r`n" })
    $approvedRanges = Get-ApprovedRanges -Lines $lines

    # Substring scan over all banned phrases.
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineNumber = $i + 1
        foreach ($phrase in $BannedPhrases) {
            if ($line.ToLowerInvariant().Contains($phrase.ToLowerInvariant())) {
                $hits.Add([pscustomobject]@{
                    rule          = "banned-phrase"
                    phrase        = $phrase
                    source        = $SourceLabel
                    line_number   = $lineNumber
                    line          = $line.Trim()
                    approved      = (Test-LineApproved -LineNumber $lineNumber -Ranges $approvedRanges)
                }) | Out-Null
            }
        }
        # Conditional rule: "verifier passes" + artifact-missing context.
        if ($line.ToLowerInvariant().Contains($ConditionalRule.primary.ToLowerInvariant())) {
            $contextHit = $false
            foreach ($needle in $ConditionalRule.context_needles) {
                if ($Content.ToLowerInvariant().Contains($needle.ToLowerInvariant())) { $contextHit = $true; break }
            }
            if ($contextHit) {
                $hits.Add([pscustomobject]@{
                    rule          = $ConditionalRule.name
                    phrase        = $ConditionalRule.primary
                    source        = $SourceLabel
                    line_number   = $lineNumber
                    line          = $line.Trim()
                    approved      = (Test-LineApproved -LineNumber $lineNumber -Ranges $approvedRanges)
                }) | Out-Null
            }
        }
    }

    # Paragraph-scope co-occurrence rule.
    $paragraphs = ($Content -split '(?:\r?\n){2,}')
    $offsetLine = 1
    foreach ($p in $paragraphs) {
        $allPresent = $true
        foreach ($needle in $CoOccurrenceRule.needles) {
            if (-not $p.ToLowerInvariant().Contains($needle.ToLowerInvariant())) {
                $allPresent = $false; break
            }
        }
        if ($allPresent) {
            $hits.Add([pscustomobject]@{
                rule          = $CoOccurrenceRule.name
                phrase        = ($CoOccurrenceRule.needles -join ' + ')
                source        = $SourceLabel
                line_number   = $offsetLine
                line          = ($p -split "(`r`n|`n)")[0].Trim()
                approved      = $false
            }) | Out-Null
        }
        $offsetLine += (($p -split "(`r`n|`n)").Count + 1)
    }

    # Force array return semantics so the caller can foreach the result even
    # when the list has 0 or 1 element.
    $out = @()
    foreach ($h in $hits) { $out += $h }
    return ,$out
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$allHits = New-Object System.Collections.Generic.List[object]

if ($Text) {
    foreach ($h in (Scan-Content -SourceLabel "<inline-text>" -Content $Text)) { $allHits.Add($h) | Out-Null }
}

if ($Path) {
    $files = Get-InputFiles -Path $Path -Recurse:$Recurse -Extensions $Extensions
    foreach ($f in $files) {
        $content = [System.IO.File]::ReadAllText($f)
        foreach ($h in (Scan-Content -SourceLabel $f -Content $content)) { $allHits.Add($h) | Out-Null }
    }
}

if (-not $Text -and -not $Path) {
    Write-Error "USAGE: provide -Path <file-or-folder> and/or -Text <string>"
    exit 2
}

$allMatches = $allHits.ToArray()
$unapproved = @($allMatches | Where-Object { -not [bool]$_.approved })

$result = [pscustomobject]@{
    matches_total      = $allMatches.Count
    matches_unapproved = $unapproved.Count
    matches            = $allMatches
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
}
else {
    if ($allMatches.Count -eq 0) {
        Write-Output "PASS: no downgrade language detected."
    } else {
        foreach ($m in $allMatches) {
            $tag = if ($m.approved) { "APPROVED" } else { "BLOCKER " }
            Write-Output ("[{0}] {1}:{2}  rule={3}  phrase='{4}'`n          line: {5}" -f $tag, $m.source, $m.line_number, $m.rule, $m.phrase, $m.line)
        }
        Write-Output ""
        Write-Output ("Summary: {0} total, {1} unapproved." -f $result.matches_total, $result.matches_unapproved)
    }
}

if ($unapproved.Count -gt 0) { exit 1 } else { exit 0 }
