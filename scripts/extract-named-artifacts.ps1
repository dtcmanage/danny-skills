# extract-named-artifacts.ps1
# ---------------------------
# Shared deterministic extractor for "runnable artifacts" named in roadmap
# procedure / acceptance-checks text. Returns the file paths the text names
# and the command invocations it names: pytest, python/python3/python3.N,
# pwsh, powershell, node, npm, npx, pnpm, bun, bash, sh, uv, make, go, cargo
# (each followed by whitespace or the end), and ./executable paths.
#
# CONTRACT: This is the source-of-truth definition of what counts as
# "runnable" for the dt-build per-milestone acceptance gate. The body of
# Extract-NamedArtifacts here MUST remain byte-identical to the inline
# Extract-NamedArtifacts function in
# `skills/dt-build/scripts/verify-milestone-acceptance.ps1`. dt-build keeps
# its inline copy so the gate has no external dependency; dt-roadmap dot-
# sources this file so the validator enforces the same definition the gate
# enforces. If you change the regex here, also change the dt-build copy in
# the same release and bump dt-build's SKILL.md version.
#
# Consumers:
#   - skills/dt-roadmap/scripts/roadmap-validator.ps1 (dot-source)
#   - skills/dt-build/scripts/verify-milestone-acceptance.ps1 (byte-identical inline copy)

function Extract-NamedArtifacts {
    # Commands require an explicit code/command boundary. Never search prose for
    # a runner: removing `-n 8` from prose can otherwise invent `pytest green`.
    param([string]$Text)
    $artifacts = New-Object System.Collections.Generic.List[string]
    $commands = New-Object System.Collections.Generic.List[string]

    $snippets = [Collections.Generic.List[string]]::new()
    $fencePattern = '(?ms)^\s*(?<fence>`{3,}|~{3,})[^\r\n]*\r?\n(?<code>.*?)^\s*\k<fence>\s*$'
    foreach ($fence in [regex]::Matches($Text, $fencePattern)) {
        foreach ($line in ($fence.Groups['code'].Value -split '\r?\n')) { $snippets.Add($line.Trim()) }
    }
    $outsideFences = [regex]::Replace($Text, $fencePattern, ' ')
    foreach ($span in [regex]::Matches($outsideFences, '(?<!`)(?<ticks>`{1,2})(?!`)(?<code>[^\r\n]*?)\k<ticks>(?!`)')) {
        $snippets.Add($span.Groups['code'].Value.Trim())
    }
    # Command-marked values consume their line verbatim, preserving quoted paths.
    # If backticks supply the boundary, the span above already supplies the value.
    foreach ($marked in [regex]::Matches($outsideFences, '(?im)^\s*(?:[-*]\s+)?(?:\*\*)?(?:Test Command|Command|Runnable Command)(?:\*\*)?\s*:\s*(?:\*\*)?(?<code>[^\r\n]+)$')) {
        $candidate = $marked.Groups['code'].Value.Trim()
        if (-not $candidate.StartsWith('`')) { $snippets.Add($candidate) }
    }
    foreach ($candidate in $snippets) {
        # Whole-string command (pytest ..., python ...) -- treat as command.
        if ($candidate -match '^(?:(?:pytest|python(?:3(?:\.\d+)?)?|pwsh|powershell|node|npm|npx|pnpm|bun|bash|sh|uv|make|go|cargo)(?=\s|$)|\./\S)') {
            $commands.Add($candidate) | Out-Null
            # Also extract any file paths inside it.
            $pathMatches = [regex]::Matches($candidate, '(?<![A-Za-z0-9_./\\-])(?:tests|scripts|backend|workers|policy|classifier)/[A-Za-z0-9_./-]+\.(?:py|ts|json|js|ps1)(?![A-Za-z0-9_./-])')
            foreach ($p in $pathMatches) { $artifacts.Add($p.Value) | Out-Null }
            continue
        }
        # Looks like a file path?
        if ($candidate -match '^(?:[A-Za-z0-9_-]+/)+[A-Za-z0-9_.-]+\.(?:py|ts|js|ps1|sh|md|yaml|yml|json|html|sql)$') {
            $artifacts.Add($candidate) | Out-Null
        }
    }

    return [pscustomobject]@{
        artifacts = @($artifacts | Select-Object -Unique)
        commands  = @($commands | Select-Object -Unique)
    }
}
