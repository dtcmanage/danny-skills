# extract-named-artifacts.ps1
# ---------------------------
# Shared deterministic extractor for "runnable artifacts" named in roadmap
# procedure / acceptance-checks text. Returns the file paths the text names
# and the pytest / python / pwsh / node / npm / bun command invocations
# it names.
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
    # Walks the procedure / acceptance text looking for explicit artifact paths
    # and command invocations. Heuristic but deterministic; the roadmap convention
    # is to name them concretely (file paths in backticks, pytest commands inline).
    param([string]$Text)
    $artifacts = New-Object System.Collections.Generic.List[string]
    $commands = New-Object System.Collections.Generic.List[string]

    # Backtick-quoted paths like `tests/backend/test_x.py` or `scripts/foo.py`.
    $backtickMatches = [regex]::Matches($Text, '`([^`]+)`')
    foreach ($m in $backtickMatches) {
        $candidate = $m.Groups[1].Value.Trim()
        # Whole-string command (pytest ..., python ...) -- treat as command.
        if ($candidate -match '^(pytest|python|pwsh|powershell|node|npm|bun)\b') {
            $commands.Add($candidate) | Out-Null
            # Also extract any file paths inside it.
            $pathMatches = [regex]::Matches($candidate, '(?:tests|scripts|backend|workers|policy|classifier)/[A-Za-z0-9_./-]+\.(?:py|ts|js|ps1)')
            foreach ($p in $pathMatches) { $artifacts.Add($p.Value) | Out-Null }
            continue
        }
        # Looks like a file path?
        if ($candidate -match '^(?:[A-Za-z0-9_-]+/)+[A-Za-z0-9_.-]+\.(?:py|ts|js|ps1|md|yaml|yml|json|html|sql)$') {
            $artifacts.Add($candidate) | Out-Null
        }
    }

    # Inline (no-backtick) `pytest <path>` and `python <script>` invocations.
    $inlineCmd = [regex]::Matches($Text, '(?i)(?:^|\s)(pytest\s+[A-Za-z0-9_./\-\s]+|python\s+(?:scripts|backend|workers|tests)/[A-Za-z0-9_./-]+\.py(?:\s+[A-Za-z0-9_.\-\/=]+)*)')
    foreach ($m in $inlineCmd) {
        $cmd = $m.Groups[1].Value.Trim()
        if (-not ($commands -contains $cmd)) { $commands.Add($cmd) | Out-Null }
        $pathMatches = [regex]::Matches($cmd, '(?:tests|scripts|backend|workers|policy|classifier)/[A-Za-z0-9_./-]+\.(?:py|ts|js|ps1)')
        foreach ($p in $pathMatches) {
            if (-not ($artifacts -contains $p.Value)) { $artifacts.Add($p.Value) | Out-Null }
        }
    }

    return [pscustomobject]@{
        artifacts = @($artifacts | Select-Object -Unique)
        commands  = @($commands | Select-Object -Unique)
    }
}
