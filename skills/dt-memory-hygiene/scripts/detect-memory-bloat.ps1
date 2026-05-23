param(
    [string]$RootPath = ".",
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-FileKind {
    param([string]$Name)
    switch -Regex ($Name) {
        '^CLAUDE\.md$' { return "claude" }
        '^MEMORY\.md$' { return "memory" }
        '^CONTEXT\.md$' { return "context" }
        '^glossary\.md$' { return "glossary" }
        default { return "other" }
    }
}

function Get-TokenEstimate {
    param([string]$Text)
    return [int][math]::Ceiling($Text.Length / 4.0)
}

function Get-BloatThresholds {
    return @{
        claude = @{ token_max = 7000; long_lines_max = 24; duplicate_ratio_max = 0.12; avg_bullet_words_max = 42; min_bullets_for_density = 8 }
        memory = @{ token_max = 5000; long_lines_max = 18; duplicate_ratio_max = 0.10; avg_bullet_words_max = 36; min_bullets_for_density = 8 }
        context = @{ token_max = 3200; long_lines_max = 14; duplicate_ratio_max = 0.08; avg_bullet_words_max = 32; min_bullets_for_density = 6 }
        glossary = @{ token_max = 3200; long_lines_max = 14; duplicate_ratio_max = 0.08; avg_bullet_words_max = 32; min_bullets_for_density = 6 }
    }
}

function Is-IgnoredPath {
    param([string]$Path)
    $p = $Path.ToLowerInvariant()
    return ($p -like '*\.git\*' -or $p -like '*\node_modules\*' -or $p -like '*\.dt-build\*' -or $p -like '*\dist\*' -or $p -like '*\build\*')
}

$root = Resolve-Path -LiteralPath $RootPath
$thresholds = Get-BloatThresholds

$targets = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object {
        $_.Name -in @("CLAUDE.md", "MEMORY.md", "CONTEXT.md", "glossary.md") -and
        -not (Is-IgnoredPath -Path $_.FullName)
    }

$results = @()

foreach ($f in $targets) {
    $kind = Get-FileKind -Name $f.Name
    if ($kind -eq "other") { continue }

    $t = $thresholds[$kind]
    $raw = Get-Content -LiteralPath $f.FullName -Raw
    $lines = Get-Content -LiteralPath $f.FullName

    $nonEmpty = @($lines | Where-Object { $_.Trim().Length -gt 0 })
    $normalized = @($nonEmpty | ForEach-Object { ($_ -replace '\s+', ' ').Trim().ToLowerInvariant() })
    $dupCount = 0
    if (@($normalized).Count -gt 0) {
        $groups = $normalized | Group-Object
        $dupCount = @($groups | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Count - 1 } | Measure-Object -Sum).Sum
        if (-not $dupCount) { $dupCount = 0 }
    }
    $dupRatio = if (@($nonEmpty).Count -gt 0) { [double]$dupCount / [double]@($nonEmpty).Count } else { 0.0 }

    $longLines = @($lines | Where-Object { $_.Length -gt 220 }).Count

    $bulletLines = @($lines | Where-Object { $_ -match '^\s*[-*]\s+' })
    $bulletWordCounts = @()
    foreach ($b in $bulletLines) {
        $wc = ([regex]::Matches($b, "\b[\w'-]+\b")).Count
        $bulletWordCounts += $wc
    }
    $avgBulletWords = if ($bulletWordCounts.Count -gt 0) { [double](($bulletWordCounts | Measure-Object -Average).Average) } else { 0.0 }

    $tokenEst = Get-TokenEstimate -Text $raw

    $hitToken = $tokenEst -gt $t.token_max
    $hitLong = $longLines -gt $t.long_lines_max
    $hitDup = $dupRatio -gt $t.duplicate_ratio_max
    $hitDensity = (@($bulletLines).Count -ge $t.min_bullets_for_density) -and ($avgBulletWords -gt $t.avg_bullet_words_max)

    $score = 0
    if ($hitToken) { $score += 2 }
    if ($hitLong) { $score += 1 }
    if ($hitDup) { $score += 1 }
    if ($hitDensity) { $score += 1 }

    $shouldRun = $hitToken -or $hitLong -or $hitDup -or $hitDensity -or ($score -ge 3)

    $results += [pscustomobject]@{
        file = $f.FullName
        kind = $kind
        line_count = @($lines).Count
        token_est = $tokenEst
        long_lines = $longLines
        duplicate_ratio = [math]::Round($dupRatio, 4)
        bullet_count = @($bulletLines).Count
        avg_bullet_words = [math]::Round($avgBulletWords, 2)
        bloat_score = $score
        thresholds = $t
        trigger_flags = [pscustomobject]@{
            token = $hitToken
            long_lines = $hitLong
            duplicate_ratio = $hitDup
            bullet_density = $hitDensity
            score_gate = ($score -ge 3)
        }
        should_run_hygiene = $shouldRun
    }
}

$overall = [pscustomobject]@{
    scanned_files = $results.Count
    flagged_files = @($results | Where-Object { $_.should_run_hygiene }).Count
    should_run_hygiene = (@($results | Where-Object { $_.should_run_hygiene }).Count -gt 0)
    files = $results
}

if ($AsJson) {
    $overall | ConvertTo-Json -Depth 8
    exit 0
}

Write-Output ("Scanned files: {0}" -f $overall.scanned_files)
Write-Output ("Flagged files: {0}" -f $overall.flagged_files)
Write-Output ("should_run_hygiene={0}" -f $overall.should_run_hygiene)
Write-Output ""

if ($overall.flagged_files -gt 0) {
    Write-Output "Flagged:"
    $results |
        Where-Object { $_.should_run_hygiene } |
        Sort-Object bloat_score -Descending |
        Select-Object file, kind, token_est, line_count, long_lines, duplicate_ratio, avg_bullet_words, bloat_score |
        Format-Table -AutoSize
} else {
    Write-Output "No files exceeded bloat trigger thresholds."
}
