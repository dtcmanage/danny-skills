param(
    [Parameter(Mandatory)][string]$RoadmapPath,
    [Parameter(Mandatory)][string]$MilestoneId,
    [Parameter(Mandatory)][string]$WorkingTree,
    [switch]$RunTests,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# verify-milestone-acceptance.ps1
# -------------------------------
# Deterministic per-milestone acceptance gate. Parses the roadmap.md verification
# manifest, extracts the procedure for the named milestone, identifies the
# artifacts the procedure names (test files, pytest commands, script invocations),
# and verifies each one against the working tree. With -RunTests, runs the named
# pytest/python commands and folds their exit codes into the verdict.
#
# Returns JSON shaped to feed scripts/build-acceptance-ledger.ps1.
#
# Exit codes:
#   0 -- accepted (status == PASS)
#   1 -- blocked (status == BLOCKED) -- either artifacts missing or tests failed
#   2 -- usage/contract error (roadmap unparseable, milestone not found, etc.)

function Resolve-SkillRepoRoot {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $skillRoot = Split-Path -Parent $scriptDir
    $resolved = (Get-Item -LiteralPath $skillRoot).ResolveLinkTarget($true)
    if ($resolved) { $skillRoot = $resolved.FullName }
    return (Split-Path -Parent (Split-Path -Parent $skillRoot))
}

function Read-RoadmapText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "ROADMAP_NOT_FOUND: $Path"
    }
    return [System.IO.File]::ReadAllText($Path)
}

function Get-SectionText {
    param([string]$RoadmapText, [string]$Header)
    # Capture from `## <Header>` (newline-anchored) up to next `## ` or end.
    $pattern = '(?ms)^##\s+' + [regex]::Escape($Header) + '\s*\n(.*?)(?=^##\s|\z)'
    $m = [regex]::Match($RoadmapText, $pattern)
    if (-not $m.Success) {
        throw "ROADMAP_SECTION_MISSING: ## $Header"
    }
    return $m.Groups[1].Value
}

function Parse-MarkdownTableRows {
    # Returns array of ordered hashtables keyed by header column name.
    param([string]$SectionText)
    $lines = $SectionText -split "(`r`n|`n)" | Where-Object { $_ -match '^\|' }
    if ($lines.Count -lt 2) { return @() }
    $headerCells = ($lines[0] -split '\|') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $rows = @()
    for ($i = 2; $i -lt $lines.Count; $i++) {
        $cells = ($lines[$i] -split '\|') | ForEach-Object { $_.Trim() }
        $cells = @($cells | Where-Object { $_ -ne '' })
        if ($cells.Count -eq 0) { continue }
        if ($cells.Count -lt $headerCells.Count) { continue }
        $row = [ordered]@{}
        for ($c = 0; $c -lt $headerCells.Count; $c++) {
            $row[$headerCells[$c]] = $cells[$c]
        }
        $rows += [pscustomobject]$row
    }
    return $rows
}

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

function Test-ArtifactPresence {
    param([string]$WorkingTree, [string[]]$Artifacts)
    $present = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Artifacts) {
        $full = Join-Path $WorkingTree $a
        if (Test-Path -LiteralPath $full) {
            $present.Add($a) | Out-Null
        } else {
            $missing.Add($a) | Out-Null
        }
    }
    return [pscustomobject]@{
        present = @($present)
        missing = @($missing)
    }
}

function Invoke-NamedCommand {
    param([string]$WorkingTree, [string]$Command)
    # Run with cwd = WorkingTree, capture stdout/stderr + exit code.
    # Keep it simple: rely on the shell to parse the command string.
    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "pwsh"
        $startInfo.Arguments = "-NoProfile -Command `"$Command`""
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.UseShellExecute = $false
        $startInfo.WorkingDirectory = $WorkingTree
        $proc = [System.Diagnostics.Process]::Start($startInfo)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        return [pscustomobject]@{
            command  = $Command
            exit_code = $proc.ExitCode
            stdout_tail = ($stdout -split "`n" | Select-Object -Last 20) -join "`n"
            stderr_tail = ($stderr -split "`n" | Select-Object -Last 20) -join "`n"
        }
    } finally {
        if (Test-Path $stdoutFile) { Remove-Item $stdoutFile -Force }
        if (Test-Path $stderrFile) { Remove-Item $stderrFile -Force }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $WorkingTree)) {
    Write-Error "WORKING_TREE_NOT_FOUND: $WorkingTree"
    exit 2
}

$roadmapText = Read-RoadmapText -Path $RoadmapPath

try {
    $milestonesSection = Get-SectionText -RoadmapText $roadmapText -Header "Milestones"
    $verificationSection = Get-SectionText -RoadmapText $roadmapText -Header "Verification Manifest"
} catch {
    Write-Error $_.Exception.Message
    exit 2
}

$milestonesRows = Parse-MarkdownTableRows -SectionText $milestonesSection
$verificationRows = Parse-MarkdownTableRows -SectionText $verificationSection

$mid = $MilestoneId.ToUpperInvariant().Trim()
$milestoneRow = $milestonesRows | Where-Object { $_.id.ToString().ToUpperInvariant().Trim() -eq $mid } | Select-Object -First 1
$verificationRow = $verificationRows | Where-Object { $_.'milestone-id'.ToString().ToUpperInvariant().Trim() -eq $mid } | Select-Object -First 1

if (-not $milestoneRow) {
    Write-Error "MILESTONE_NOT_FOUND: $MilestoneId not present in ## Milestones"
    exit 2
}
if (-not $verificationRow) {
    Write-Error "VERIFICATION_CHECK_NOT_FOUND: no chk-* row for milestone-id=$MilestoneId in ## Verification Manifest"
    exit 2
}

$acceptanceText = [string]$milestoneRow.'acceptance-checks'
$procedureText = [string]$verificationRow.procedure

$accept = Extract-NamedArtifacts -Text $acceptanceText
$verify = Extract-NamedArtifacts -Text $procedureText

$allArtifacts = @($accept.artifacts + $verify.artifacts | Select-Object -Unique)
$allCommands = @($accept.commands + $verify.commands | Select-Object -Unique)

$presence = Test-ArtifactPresence -WorkingTree $WorkingTree -Artifacts $allArtifacts

$commandResults = @()
$testStatus = "NOT_RUN"
if ($RunTests) {
    if ($allCommands.Count -eq 0) {
        $testStatus = "NO_COMMAND_NAMED"
    } else {
        $anyFailed = $false
        foreach ($cmd in $allCommands) {
            $r = Invoke-NamedCommand -WorkingTree $WorkingTree -Command $cmd
            $commandResults += $r
            if ($r.exit_code -ne 0) { $anyFailed = $true }
        }
        $testStatus = if ($anyFailed) { "FAIL" } else { "PASS" }
    }
}

$blockers = New-Object System.Collections.Generic.List[string]
foreach ($m in $presence.missing) {
    $blockers.Add("named artifact missing: $m") | Out-Null
}
if ($testStatus -eq "FAIL") {
    foreach ($r in $commandResults | Where-Object { $_.exit_code -ne 0 }) {
        $blockers.Add("verification command failed (exit=$($r.exit_code)): $($r.command)") | Out-Null
    }
}
if ($testStatus -eq "NO_COMMAND_NAMED" -and $allArtifacts.Count -eq 0) {
    # Verification check named no concrete artifacts at all -- the roadmap is too
    # vague for the gate to enforce anything. Surface as a blocker so the operator
    # knows to tighten the roadmap.
    $blockers.Add("roadmap verification check names no concrete test file or command") | Out-Null
}

$accepted = ($blockers.Count -eq 0) -and ($presence.missing.Count -eq 0) -and ($testStatus -in @("PASS", "NOT_RUN", "NO_COMMAND_NAMED"))
# Treat NOT_RUN as pending acceptance: status PASS requires either tests ran green OR -RunTests was not requested AND artifacts all present.
$status = if ($accepted) { "PASS" } else { "BLOCKED" }

$result = [pscustomobject]@{
    milestone_id              = $mid
    acceptance_checks_text    = $acceptanceText
    verification_check_text   = $procedureText
    artifacts_named           = $allArtifacts
    artifacts_present         = $presence.present
    artifacts_missing         = $presence.missing
    commands_named            = $allCommands
    command_results           = $commandResults
    test_status               = $testStatus
    implemented_hint          = $true   # caller decides via git diff; this script only proves the acceptance side
    tested                    = ($testStatus -eq "PASS")
    accepted                  = $accepted
    status                    = $status
    blockers                  = @($blockers)
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
}
else {
    Write-Output ("Milestone {0}: {1}" -f $result.milestone_id, $result.status)
    if ($result.artifacts_missing.Count -gt 0) {
        Write-Output "  Missing artifacts:"
        $result.artifacts_missing | ForEach-Object { Write-Output "    - $_" }
    }
    if ($result.command_results.Count -gt 0) {
        Write-Output "  Commands run:"
        foreach ($r in $result.command_results) {
            Write-Output ("    [exit={0}] {1}" -f $r.exit_code, $r.command)
        }
    }
    if ($result.blockers.Count -gt 0) {
        Write-Output "  Blockers:"
        $result.blockers | ForEach-Object { Write-Output "    - $_" }
    }
}

if ($status -eq "PASS") { exit 0 } else { exit 1 }
