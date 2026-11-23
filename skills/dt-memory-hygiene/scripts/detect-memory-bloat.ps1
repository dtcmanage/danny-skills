param(
    [string]$RootPath = ".",
    # -Json matches the sibling audit scripts; -AsJson stays for older callers.
    [Alias('AsJson')]
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# Plain text for transcripts and logs: no ANSI color codes.
if (Get-Variable -Name PSStyle -ErrorAction SilentlyContinue) { $PSStyle.OutputRendering = 'PlainText' }

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
    # CLAUDE.md and MEMORY.md load every session, so token size is real context
    # cost and gets tight caps. CONTEXT.md and glossary.md are load-on-demand
    # reference files (dt-plan/dt-review/domain work pull them in as needed), so
    # size is NOT a per-session cost: token_max is only a runaway backstop and
    # long-line flagging is disabled (the mandated entry format is paragraph
    # prose). Duplication remains the live signal for them - duplicate entries
    # breed drift regardless of loading model. (Danny, 2026-06-12.)
    # These are root limits; each file gets its own copy before tier overrides.
    # Zero disables a size check. MEMORY.md must stay under 150 lines.
    return @{
        claude = @{ token_max = 7000; word_max = 4000; line_max = 0; long_lines_max = 24; duplicate_ratio_max = 0.12; avg_bullet_words_max = 42; min_bullets_for_density = 8 }
        memory = @{ token_max = 5000; word_max = 0; line_max = 149; long_lines_max = 18; duplicate_ratio_max = 0.10; avg_bullet_words_max = 36; min_bullets_for_density = 8 }
        context = @{ token_max = 20000; word_max = 0; line_max = 0; long_lines_max = 999; duplicate_ratio_max = 0.08; avg_bullet_words_max = 32; min_bullets_for_density = 6 }
        glossary = @{ token_max = 20000; word_max = 0; line_max = 0; long_lines_max = 999; duplicate_ratio_max = 0.08; avg_bullet_words_max = 32; min_bullets_for_density = 6 }
    }
}

function Is-IgnoredPath {
    param([string]$Path)
    # Separator-neutral so the same exclusions hold on Linux and Windows.
    $p = '/' + ([IO.Path]::GetRelativePath($root, $Path).ToLowerInvariant() -replace '\\', '/')
    foreach ($dirName in @('.git', 'node_modules', '.dt-build', 'dist', 'build')) {
        if ($p.Contains("/$dirName/")) { return $true }
    }
    # Copies, not live scaffolding: build evidence, underscore meta folders (_audit, _archive,
    # _handoffs) below the workspace, and the harness auto-memory inbox (root projects\), which
    # dt-session-audit drains under its own rules.
    $segments = @([IO.Path]::GetRelativePath($root, $Path) -split '[\\/]' | Select-Object -SkipLast 1)
    if ($segments.Count -and $segments[0] -eq 'projects') { return $true }
    foreach ($s in $segments) {
        if ($s -eq 'evidence' -or ($s.StartsWith('_') -and $s -ne '_Claude-Workspace')) { return $true }
    }
    return $false
}

function Get-FileTier {
    # Root tier: files directly in the workspace root, plus the _Claude-Workspace directory
    # file (a cross-workstation map, not a workstation). Everything else has the
    # 1,500-word workstation/substation/repo budget. The assistant workspace kit's Claude/
    # folder is a template of a whole workspace root, so it gets the same two root slots.
    param([IO.FileInfo]$File)
    $dir = $File.DirectoryName.TrimEnd('\', '/')
    $roots = @($root.TrimEnd('\', '/'))
    $kit = [regex]::Match(($dir -replace '\\', '/'), '^(.*/assistant-workspace-kit/Claude)(?:/|$)')
    if ($kit.Success) { $roots += $kit.Groups[1].Value }
    foreach ($candidate in $roots) {
        $normalizedDir = $dir -replace '\\', '/'
        $normalizedRoot = $candidate -replace '\\', '/'
        if ($normalizedDir -eq $normalizedRoot) { return 'root' }
        if ($normalizedDir -eq "$normalizedRoot/_Claude-Workspace") { return 'root' }
    }
    return 'non-root'
}

# RootPath is the workspace root holding root CLAUDE.md, not a workstation.
$root = (Get-Item -LiteralPath (Resolve-Path -LiteralPath $RootPath).Path).FullName
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

    $tier = Get-FileTier -File $f
    $t = $thresholds[$kind].Clone()
    if ($tier -eq "non-root" -and $kind -in @("claude", "memory")) {
        $t.word_max = 1500
    }
    $raw = Get-Content -LiteralPath $f.FullName -Raw
    if ($null -eq $raw) { $raw = "" }
    $lines = @(Get-Content -LiteralPath $f.FullName)

    $nonEmpty = @($lines | Where-Object { $_.Trim().Length -gt 0 })
    $normalized = @($nonEmpty | ForEach-Object { ($_ -replace '\s+', ' ').Trim().ToLowerInvariant() })
    $dupCount = 0
    if (@($normalized).Count -gt 0) {
        $groups = $normalized | Group-Object
        $dupCount = @($groups | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Count - 1 } | Measure-Object -Sum).Sum
        if (-not $dupCount) { $dupCount = 0 }
    }
    $dupRatio = if (@($nonEmpty).Count -gt 0) { [double]$dupCount / [double]@($nonEmpty).Count } else { 0.0 }

    # Markdown table rows are one line per row by design (the workspace directory and routing
    # tables), so they never count as long lines; word and token limits still cover them.
    $longLines = @($lines | Where-Object { $_.Length -gt 220 -and $_ -notmatch '^\s*\|' }).Count

    $bulletLines = @($lines | Where-Object { $_ -match '^\s*[-*]\s+' })
    $bulletWordCounts = @()
    foreach ($b in $bulletLines) {
        $wc = ([regex]::Matches($b, "\b[\w'-]+\b")).Count
        $bulletWordCounts += $wc
    }
    $avgBulletWords = if ($bulletWordCounts.Count -gt 0) { [double](($bulletWordCounts | Measure-Object -Average).Average) } else { 0.0 }

    $tokenEst = Get-TokenEstimate -Text $raw
    $wordCount = ([regex]::Matches($raw, "\b[\w'-]+\b")).Count

    $hitToken = $tokenEst -gt $t.token_max
    $hitWords = ($t.word_max -gt 0) -and ($wordCount -gt $t.word_max)
    $hitLines = ($t.line_max -gt 0) -and (@($lines).Count -gt $t.line_max)
    $hitLong = $longLines -gt $t.long_lines_max
    $hitDup = $dupRatio -gt $t.duplicate_ratio_max
    $hitDensity = (@($bulletLines).Count -ge $t.min_bullets_for_density) -and ($avgBulletWords -gt $t.avg_bullet_words_max)

    $score = 0
    if ($hitToken) { $score += 2 }
    if ($hitWords) { $score += 2 }
    if ($hitLines) { $score += 2 }
    if ($hitLong) { $score += 1 }
    if ($hitDup) { $score += 1 }
    if ($hitDensity) { $score += 1 }

    $shouldRun = $hitToken -or $hitWords -or $hitLines -or $hitLong -or $hitDup -or $hitDensity -or ($score -ge 3)

    $results += [pscustomobject]@{
        file = $f.FullName
        kind = $kind
        tier = $tier
        line_count = @($lines).Count
        token_est = $tokenEst
        word_count = $wordCount
        long_lines = $longLines
        duplicate_ratio = [math]::Round($dupRatio, 4)
        bullet_count = @($bulletLines).Count
        avg_bullet_words = [math]::Round($avgBulletWords, 2)
        bloat_score = $score
        thresholds = $t
        trigger_flags = [pscustomobject]@{
            token = $hitToken
            words = $hitWords
            lines = $hitLines
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

if ($Json) {
    $overall | ConvertTo-Json -Depth 8
    exit 0
}

Write-Output ("Scanned files: {0}" -f $overall.scanned_files)
Write-Output ("Flagged files: {0}" -f $overall.flagged_files)
Write-Output ("should_run_hygiene={0}" -f $overall.should_run_hygiene)
Write-Output ""

if ($overall.flagged_files -gt 0) {
    Write-Output "Flagged:"
    # One explicit line per file: table formatting truncates long paths to the console width.
    foreach ($r in @($results | Where-Object { $_.should_run_hygiene } | Sort-Object bloat_score -Descending)) {
        $hits = @($r.trigger_flags.PSObject.Properties | Where-Object { $_.Value } | ForEach-Object { $_.Name }) -join ','
        Write-Output ("- {0} | kind={1} tier={2} tokens={3} words={4} lines={5} long_lines={6} duplicate_ratio={7} avg_bullet_words={8} score={9} triggers={10}" -f
            $r.file, $r.kind, $r.tier, $r.token_est, $r.word_count, $r.line_count, $r.long_lines, $r.duplicate_ratio, $r.avg_bullet_words, $r.bloat_score, $hits)
    }
} else {
    Write-Output "No files exceeded bloat trigger thresholds."
}
