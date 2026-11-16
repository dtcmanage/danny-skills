Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:passed = 0
$script:failed = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if ($Condition) {
        $script:passed++
        Write-Output "PASS: $Name"
    } else {
        $script:failed++
        Write-Output "FAIL: $Name"
    }
}

function Write-Fixture([string]$Path, [int]$Words, [int]$Lines) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    # Short, unique, non-bullet lines isolate size budgets from other heuristics.
    $text = for ($i = 0; $i -lt $Lines; $i++) {
        $count = [int][math]::Floor($Words / $Lines)
        if ($i -lt ($Words % $Lines)) { $count++ }
        (@([string]$i) + @('a') * ($count - 1)) -join ' '
    }
    [IO.File]::WriteAllText($Path, ($text -join "`n"), [Text.UTF8Encoding]::new($false))
}

$detector = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../detect-memory-bloat.ps1'))
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('memory-bloat-' + [guid]::NewGuid().ToString('N'))
$cases = @(
    @{ path = 'CLAUDE.md'; words = 3900; lines = 100; tier = 'root'; max = 4000; word_hit = $false; line_hit = $false },
    @{ path = 'MEMORY.md'; words = 1600; lines = 100; tier = 'root'; max = 0; word_hit = $false; line_hit = $false },
    @{ path = 'workstation/CLAUDE.md'; words = 1600; lines = 100; tier = 'non-root'; max = 1500; word_hit = $true; line_hit = $false },
    @{ path = 'workstation/MEMORY.md'; words = 1400; lines = 160; tier = 'non-root'; max = 1500; word_hit = $false; line_hit = $true },
    @{ path = 'healthy/CLAUDE.md'; words = 1400; lines = 100; tier = 'non-root'; max = 1500; word_hit = $false; line_hit = $false },
    @{ path = 'healthy/MEMORY.md'; words = 1400; lines = 100; tier = 'non-root'; max = 1500; word_hit = $false; line_hit = $false },
    @{ path = 'workstation/substation/repo/CLAUDE.md'; words = 1501; lines = 100; tier = 'non-root'; max = 1500; word_hit = $true; line_hit = $false },
    @{ path = 'workstation/substation/repo/MEMORY.md'; words = 1501; lines = 100; tier = 'non-root'; max = 1500; word_hit = $true; line_hit = $false },
    @{ path = 'boundary/CLAUDE.md'; words = 1500; lines = 100; tier = 'non-root'; max = 1500; word_hit = $false; line_hit = $false },
    @{ path = 'boundary/MEMORY.md'; words = 1500; lines = 149; tier = 'non-root'; max = 1500; word_hit = $false; line_hit = $false },
    @{ path = 'line-boundary/MEMORY.md'; words = 1400; lines = 150; tier = 'non-root'; max = 1500; word_hit = $false; line_hit = $true },
    @{ path = 'workstation/CONTEXT.md'; words = 1600; lines = 160; tier = 'non-root'; max = 0; word_hit = $false; line_hit = $false },
    @{ path = 'workstation/glossary.md'; words = 1600; lines = 160; tier = 'non-root'; max = 0; word_hit = $false; line_hit = $false },
    # The workspace directory file is a cross-workstation map: root limits, not the 1,500 budget.
    @{ path = '_Claude-Workspace/CLAUDE.md'; words = 2200; lines = 50; tier = 'root'; max = 4000; word_hit = $false; line_hit = $false },
    @{ path = '_Claude-Workspace/Station/MEMORY.md'; words = 1600; lines = 50; tier = 'non-root'; max = 1500; word_hit = $true; line_hit = $false }
)
# Copies of scaffolding that are never live: evidence trees, underscore meta folders, and the
# harness auto-memory inbox. None may be scanned.
$ignored = @(
    '_Claude-Workspace/Station/evidence/run-1/CLAUDE.md',
    '_Claude-Workspace/Station/_audit/backup/MEMORY.md',
    '_Claude-Workspace/_archive/old/CLAUDE.md',
    'projects/D--Claude/memory/MEMORY.md'
)
try {
    foreach ($case in $cases) {
        Write-Fixture (Join-Path $fixtureRoot $case.path) $case.words $case.lines
    }
    foreach ($path in $ignored) { Write-Fixture (Join-Path $fixtureRoot $path) 5000 300 }
    # Exercise JSON and text modes through their public entry point.
    $report = & $detector -RootPath ($fixtureRoot + [IO.Path]::DirectorySeparatorChar) -AsJson | ConvertFrom-Json
    Assert-True ($report.scanned_files -eq $cases.Count) 'all fixture files discovered'
    foreach ($path in $ignored) {
        Assert-True (-not @($report.files | Where-Object file -eq (Join-Path $fixtureRoot $path)).Count) "$($path): copy not scanned"
    }
    foreach ($case in $cases) {
        $path = Join-Path $fixtureRoot $case.path
        $file = @($report.files | Where-Object file -eq $path)[0]
        Assert-True ($file.word_count -eq $case.words -and $file.line_count -eq $case.lines) "$($case.path): exact counts"
        Assert-True ($file.tier -eq $case.tier -and $file.thresholds.word_max -eq $case.max) "$($case.path): tier and word limit"
        Assert-True ($file.trigger_flags.words -eq $case.word_hit -and $file.trigger_flags.lines -eq $case.line_hit) "$($case.path): size flags"
        Assert-True ($file.should_run_hygiene -eq ($case.word_hit -or $case.line_hit)) "$($case.path): hygiene decision"
    }
    $expectedFlagged = @($cases | Where-Object { $_.word_hit -or $_.line_hit }).Count
    Assert-True ($report.should_run_hygiene -and $report.flagged_files -eq $expectedFlagged) 'aggregate flags match file decisions'
    $text = (& $detector -RootPath $fixtureRoot | Out-String)
    Assert-True ($text -match "Flagged files: $expectedFlagged") 'text mode reports flagged count'

    Write-Fixture (Join-Path $fixtureRoot 'CLAUDE.md') 4001 100
    Write-Fixture (Join-Path $fixtureRoot 'MEMORY.md') 1400 150
    $report = & $detector -RootPath $fixtureRoot -AsJson | ConvertFrom-Json
    $rootClaude = @($report.files | Where-Object { $_.tier -eq 'root' -and $_.kind -eq 'claude' })[0]
    $rootMemory = @($report.files | Where-Object { $_.tier -eq 'root' -and $_.kind -eq 'memory' })[0]
    Assert-True ($rootClaude.trigger_flags.words -and $rootClaude.should_run_hygiene) 'root CLAUDE.md over 4000 words triggers'
    Assert-True ($rootMemory.trigger_flags.lines -and $rootMemory.should_run_hygiene -and $rootMemory.thresholds.word_max -eq 0) 'root MEMORY.md line ceiling without word ceiling'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped temp root.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Output "SUMMARY: $script:passed passed; $script:failed failed"
if ($script:failed) { exit 1 }
