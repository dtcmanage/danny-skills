# command-intake.ps1
# ------------------
# Shared dt-roadmap intake checks for verification commands. Dot-source AFTER
# `<danny-skills>/scripts/extract-named-artifacts.ps1`: every "is this a
# command dt-build will run" decision delegates to Extract-NamedArtifacts, so
# the producer and validator never keep a second runner list.
#
# dt-build's acceptance gate only executes what Extract-NamedArtifacts returns
# as a command from a matching Verification Manifest procedure cell. Anything
# command-like the extractor does not return is silently skipped there. These
# helpers make that gap an explicit early failure instead:
#   - Test-IsExecutableCommand: the extractor returns the text as a command.
#   - Get-UnsupportedCommandWrappers: command-like text the gate would skip or
#     only partially run (tool wrappers such as `Bash(...)`, shell preambles such
#     as `cd x && pytest`, env/sudo/prompt prefixes). Wrappers are reported,
#     never unwrapped or rewritten.
# Harmless prose identifiers (`tag_clusters`, `foo()`, `make-believe`) are not
# command-like and are ignored.

# Tool-call wrappers. Any `Name(` form with one of these names is a wrapper,
# whatever it contains.
$script:CommandIntakeToolWrapper = '(?i)^(?:bash|sh|zsh|shell|pwsh|powershell|cmd|terminal)\s*\('
# One-word prefixes that hide a runner from the extractor.
$script:CommandIntakePrefix = '(?i)^(?:\$|>|sudo|time|nohup|exec|command|env)\s+'
$script:CommandIntakeAssignments = '^(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+'
$script:CommandIntakePreamble = '(?i)^(?:cd|pushd|source|\.|export|set|setlocal)\s+\S'
$script:CommandIntakeControl = '&&|\|\||;|\|'

function Test-IsExecutableCommand {
    # True when dt-build's extractor would return the whole candidate as a command.
    param([string]$Candidate)
    if ([string]::IsNullOrWhiteSpace($Candidate) -or $Candidate.Contains('`')) { return $false }
    $hit = Extract-NamedArtifacts -Text ('`' + $Candidate.Trim() + '`')
    return (@($hit.commands).Count -gt 0)
}

function Test-IsNamedRunnable {
    # True when the extractor returns the candidate as a command or a file artifact.
    param([string]$Candidate)
    if ([string]::IsNullOrWhiteSpace($Candidate) -or $Candidate.Contains('`')) { return $false }
    $hit = Extract-NamedArtifacts -Text ('`' + $Candidate.Trim() + '`')
    return ((@($hit.commands).Count + @($hit.artifacts).Count) -gt 0)
}

function Remove-CommandIntakeQuotes {
    param([string]$Text)
    $t = $Text.Trim()
    if ($t.Length -ge 2 -and (($t[0] -eq '"' -and $t[-1] -eq '"') -or ($t[0] -eq "'" -and $t[-1] -eq "'"))) {
        return $t.Substring(1, $t.Length - 2).Trim()
    }
    return $t
}

function Test-HidesExecutableCommand {
    # True when stripping a wrapper, prefix or preamble would expose a command.
    param([string]$Candidate)
    $c = Remove-CommandIntakeQuotes $Candidate
    if ([string]::IsNullOrWhiteSpace($c)) { return $false }
    if (Test-IsExecutableCommand $c) { return $true }
    $segments = @([regex]::Split($c, $script:CommandIntakeControl) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($segment in $segments) {
        $s = Remove-CommandIntakeQuotes $segment
        for ($i = 0; $i -lt 4; $i++) {
            $next = [regex]::Replace($s, $script:CommandIntakeAssignments, '')
            $next = [regex]::Replace($next, $script:CommandIntakePrefix, '')
            $next = Remove-CommandIntakeQuotes $next
            if ($next -eq $s) { break }
            $s = $next
        }
        if (Test-IsExecutableCommand $s) { return $true }
    }
    return $false
}

function Test-IsUnsupportedWrapperCandidate {
    # Classifies one backticked span.
    param([string]$Candidate)
    $c = $Candidate.Trim()
    if ([string]::IsNullOrWhiteSpace($c)) { return $false }
    if ($c -match $script:CommandIntakeToolWrapper) { return $true }
    $call = [regex]::Match($c, '^[A-Za-z][A-Za-z0-9_.-]*\s*\((.*)\)\s*$')
    if ($call.Success) { return (Test-HidesExecutableCommand $call.Groups[1].Value) }
    # Supported as written: the gate runs it verbatim. Keeps the current runner set.
    if (Test-IsExecutableCommand $c) { return $false }
    if ($c -match $script:CommandIntakePreamble -and $c -match $script:CommandIntakeControl) { return $true }
    return (Test-HidesExecutableCommand $c)
}

function Get-UnsupportedCommandWrappers {
    # Returns every unsupported command-like snippet in $Text (backticked spans
    # and unbackticked prose), in source order, deduplicated.
    param([string]$Text)
    $found = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Text)) { return ,@() }
    foreach ($m in [regex]::Matches($Text, '`([^`]+)`')) {
        $candidate = $m.Groups[1].Value.Trim()
        if ((Test-IsUnsupportedWrapperCandidate $candidate) -and -not $found.Contains($candidate)) { $found.Add($candidate) | Out-Null }
    }
    # Unbackticked text: the extractor's inline pass can lift an inner
    # `pytest ...` out of `Bash(cd x && pytest ...)`, so the wrapper must fail here
    # rather than run a different command from a different directory.
    $inline = [regex]::Replace($Text, '`[^`]*`', ' ')
    $patterns = @(
        '(?i)\b(?:bash|sh|zsh|shell|pwsh|powershell|cmd|terminal)\([^)]*\)?',
        '(?i)(?:^|(?<=\s))(?:cd|pushd|source)\s+\S+\s*(?:&&|;|\|\|)[^.;]*'
    )
    foreach ($p in $patterns) {
        foreach ($m in [regex]::Matches($inline, $p)) {
            $snippet = $m.Value.Trim()
            if (-not $found.Contains($snippet)) { $found.Add($snippet) | Out-Null }
        }
    }
    foreach ($m in [regex]::Matches($inline, '\b[A-Za-z][A-Za-z0-9_.-]*\(([^()]*)\)')) {
        $snippet = $m.Value.Trim()
        if ((Test-HidesExecutableCommand $m.Groups[1].Value) -and -not $found.Contains($snippet)) { $found.Add($snippet) | Out-Null }
    }
    return ,@($found)
}
