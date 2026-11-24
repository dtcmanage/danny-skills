#Requires -Version 7.0
# Build the instruction file a headless Claude coordinator starts with, fresh from the live CLAUDE.md files.
#
# The coordinator launches with Claude Code's own instruction loading turned off
# (CLAUDE_CODE_DISABLE_CLAUDE_MDS=1) and gets this file instead (--append-system-prompt-file). It is
# regenerated at every launch, so it is always a reflection of the current files: a rule edited in a
# CLAUDE.md reaches the next coordinator with nothing else to update and nothing to drift.
#
# Contents, in the order Claude Code itself would load them:
#   1. The root CLAUDE.md ($CLAUDE_CONFIG_DIR/CLAUDE.md), minus the sections in $ExcludeSections: memory
#      placement and the workstation routing map, which only matter to a session talking to Danny. Every other
#      section is included, so a new rule anywhere else reaches builds automatically. A missing heading
#      excludes nothing (fail-safe: more rules, never fewer).
#   2. Every CLAUDE.md from the workspace root down to the coordinator's working directory (workstation,
#      substation, repo), in full. The workspace directory (_Claude-Workspace/CLAUDE.md) is skipped: it is a
#      map of folders, not rules.
# Left out entirely: root MEMORY.md, harness auto-memory, UNIFIED-MEMORY.md, and @-imports (listed in the
# header so the coordinator can read one when an action needs a fact from it).
#
# Prints the output path on success. Exits non-zero (writing nothing) when the root CLAUDE.md is missing, so
# the launcher falls back to Claude Code's normal loading rather than starting a coordinator with no rules.
param(
    [Parameter(Mandatory)]
    [string]$WorkDir,

    [Parameter(Mandatory)]
    [string]$OutPath,

    [string]$ConfigDir = $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }),

    [string[]]$ExcludeSections = @('Memory System', 'Routing Map')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rootFile = Join-Path $ConfigDir 'CLAUDE.md'
if (-not (Test-Path -LiteralPath $rootFile -PathType Leaf)) {
    [Console]::Error.WriteLine("DT_BUILD_RULES_NO_ROOT: $rootFile not found")
    exit 2
}

$imports = [System.Collections.Generic.List[string]]::new()

function Remove-Imports {
    # Drop @path import lines (Claude Code would inline them); record them for the header.
    param([string]$Text, [string]$FromDir)
    $kept = foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*@(\S+)\s*$') {
            $target = $Matches[1]
            $resolved = if ([System.IO.Path]::IsPathRooted($target)) { $target } else { [System.IO.Path]::GetFullPath((Join-Path $FromDir $target)) }
            $imports.Add($resolved)
        }
        else { $line }
    }
    return ($kept -join "`n")
}

function Remove-Sections {
    # Remove each "## <name>" section (to the next heading of the same or higher level).
    param([string]$Text, [string[]]$Names)
    $out = [System.Collections.Generic.List[string]]::new()
    $skipLevel = 0
    foreach ($line in ($Text -split "`n")) {
        if ($line -match '^(#{1,6})\s+(.*?)\s*$') {
            $level = $Matches[1].Length
            $title = $Matches[2]
            if ($skipLevel -and $level -le $skipLevel) { $skipLevel = 0 }
            if (-not $skipLevel -and $Names -contains $title) { $skipLevel = $level; continue }
        }
        if (-not $skipLevel) { $out.Add($line) }
    }
    return ($out -join "`n")
}

$rootDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($rootFile))
$rootText = Remove-Sections -Text (Remove-Imports -Text ([System.IO.File]::ReadAllText($rootFile)) -FromDir $rootDir) -Names $ExcludeSections

# The chain from the filesystem root down to WorkDir, as Claude Code walks it; keep only files below the
# root CLAUDE.md's folder, skipping the root file itself and the workspace directory map.
$chain = [System.Collections.Generic.List[string]]::new()
$dir = [System.IO.Path]::GetFullPath($WorkDir)
while ($dir) {
    foreach ($name in @('CLAUDE.md', '.claude/CLAUDE.md')) {
        $candidate = Join-Path $dir $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $chain.Insert(0, [System.IO.Path]::GetFullPath($candidate)) }
    }
    $parent = Split-Path -Parent $dir
    if (-not $parent -or $parent -eq $dir) { break }
    $dir = $parent
}
$rootFull = [System.IO.Path]::GetFullPath($rootFile)
$workspaceMap = [System.IO.Path]::GetFullPath((Join-Path $rootDir '_Claude-Workspace/CLAUDE.md'))
$scoped = @($chain | Where-Object {
    $_ -ne $rootFull -and $_ -ne $workspaceMap -and $_.StartsWith($rootDir + [System.IO.Path]::DirectorySeparatorChar)
} | Select-Object -Unique)

# Read every scoped file first, so the header can list all @-imports found anywhere.
$bodies = [System.Collections.Generic.List[string]]::new()
foreach ($file in $scoped) {
    $text = Remove-Imports -Text ([System.IO.File]::ReadAllText($file)) -FromDir (Split-Path -Parent $file)
    $bodies.Add("<instructions source=`"$file`">`n$($text.Trim())`n</instructions>")
}

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('# Build coordinator instructions')
[void]$sb.AppendLine()
[void]$sb.AppendLine("Generated at launch from the live instruction files below (no timestamp, so unchanged files give byte-identical text and the prompt cache hits across coordinator handoffs); Claude Code's own CLAUDE.md loading is off for this session. These are Danny's standing rules: follow them as you would a loaded CLAUDE.md. Where dt-build's rulebook is more specific about running a build, the rulebook wins.")
[void]$sb.AppendLine()
[void]$sb.AppendLine("Sources: $rootFull (without sections: $($ExcludeSections -join ', '))$(if ($scoped) { '; ' + ($scoped -join '; ') })")
if ($imports.Count) {
    [void]$sb.AppendLine("Not loaded (read one only when an action needs a fact from it): $((@($imports) | Select-Object -Unique) -join '; ')")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("<instructions source=`"$rootFull`">")
[void]$sb.AppendLine($rootText.Trim())
[void]$sb.AppendLine('</instructions>')
foreach ($body in $bodies) {
    [void]$sb.AppendLine()
    [void]$sb.AppendLine($body)
}

$outFull = [System.IO.Path]::GetFullPath($OutPath)
$tmp = "$outFull.tmp"
[System.IO.File]::WriteAllText($tmp, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $tmp -Destination $outFull -Force
$outFull
