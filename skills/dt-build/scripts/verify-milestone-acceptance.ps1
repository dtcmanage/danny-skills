param(
    [Parameter(Mandatory)][string]$RoadmapPath,
    [Parameter(Mandatory)][string]$MilestoneId,
    [Parameter(Mandatory)][string]$WorkingTree,
    [switch]$RunTests,
    [ValidateRange(1000, 3600000)][int]$CommandTimeoutMs = 600000,
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
#   0 -- accepted (status == PASS) or artifact-only inspection completed
#   1 -- blocked (status == BLOCKED) -- either artifacts missing or tests failed
#   2 -- usage/contract error (roadmap unparseable, milestone not found, etc.)

function Resolve-SkillRepoRoot {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $skillRoot = Split-Path -Parent $scriptDir
    $original = (Resolve-Path -LiteralPath $skillRoot).Path
    $cursor = Get-Item -LiteralPath $original
    while ($null -ne $cursor) {
        $resolved = $null
        try { $resolved = $cursor.ResolveLinkTarget($true) } catch { }
        if ($resolved) {
            $suffix = [System.IO.Path]::GetRelativePath($cursor.FullName, $original)
            $skillRoot = if ($suffix -eq '.') { $resolved.FullName } else { Join-Path $resolved.FullName $suffix }
            break
        }
        $cursor = $cursor.Parent
    }
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

# NOTE: The body of Extract-NamedArtifacts below is the source-of-truth
# definition of what counts as a "runnable" artifact / command for this gate.
# A byte-identical copy lives at repo-level `scripts/extract-named-artifacts.ps1`
# and is dot-sourced by `skills/dt-roadmap/scripts/roadmap-validator.ps1` so the
# producer's validator enforces the same definition the consumer's gate enforces.
# If you change the regex here, also change the shared helper in the same release
# (and vice versa). The gate keeps an inline copy so it has no external
# dependency at run time; the shared helper exists for new consumers.
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
    # Remove fenced inline-code spans first. Otherwise `python -m pytest ...`
    # inside backticks is captured once as the full command and a second time as
    # the inner `pytest ...`, causing the same test suite to run twice.
    $inlineText = [regex]::Replace($Text, '`[^`]*`', ' ')
    $inlineCmd = [regex]::Matches($inlineText, '(?i)(?:^|\s)(pytest\s+[A-Za-z0-9_./\-\s]+|python\s+(?:scripts|backend|workers|tests)/[A-Za-z0-9_./-]+\.py(?:\s+[A-Za-z0-9_.\-\/=]+)*)')
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

function Normalize-Command {
    # The roadmap convention names commands as Python ecosystem invocations:
    #   pytest tests/foo.py
    #   python scripts/foo.py
    # When we run those through `pwsh -NoProfile`, the user's profile-supplied
    # PATH entries (incl. venv Scripts/) are stripped, so the bare `pytest`
    # entry-point binary isn't found and every gate command exits 1 even when
    # the tests would otherwise pass. Transforming `pytest ` to
    # `python -m pytest ` keeps the invocation portable: `python` itself is
    # generally on the system PATH and the `-m pytest` module runner does not
    # depend on `Scripts/` being on PATH.
    param([string]$Command)
    $trimmed = $Command.TrimStart()
    if ($trimmed -match '^(pytest)(\s|$)') {
        return ("python -m " + $trimmed)
    }
    return $Command
}

function Invoke-NamedCommand {
    param([string]$WorkingTree, [string]$Command, [int]$TimeoutMs)
    # Redirect to files instead of synchronously draining stdout and then stderr.
    # Sequential pipe reads can deadlock when both buffers fill (observed with a
    # high-volume Vitest run). File redirection also keeps the retained JSON small.
    $effectiveCommand = Normalize-Command -Command $Command
    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    $started = Get-Date
    $proc = $null
    try {
        # -EncodedCommand survives embedded quotes and spaces (a -Command "..."
        # wrapper truncates at the first inner double quote, e.g. quoted paths).
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($effectiveCommand))
        $proc = Start-Process -FilePath "pwsh" `
            -ArgumentList @("-NoProfile", "-EncodedCommand", $encoded) `
            -WorkingDirectory $WorkingTree `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile `
            -NoNewWindow -PassThru

        $completed = $proc.WaitForExit($TimeoutMs)
        $timedOut = -not $completed
        if ($timedOut) {
            try { $proc.Kill($true) } catch { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            [void]$proc.WaitForExit(5000)
        }

        $stdout = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -Raw -LiteralPath $stdoutFile } else { "" }
        $stderr = if (Test-Path -LiteralPath $stderrFile) { Get-Content -Raw -LiteralPath $stderrFile } else { "" }
        $exitCode = if ($timedOut) { 124 } else { $proc.ExitCode }
        $durationMs = [int][Math]::Round(((Get-Date) - $started).TotalMilliseconds)
        return [pscustomobject]@{
            command            = $Command
            effective_command  = $effectiveCommand
            exit_code          = $exitCode
            timed_out          = $timedOut
            timeout_ms         = $TimeoutMs
            duration_ms        = $durationMs
            termination_reason = if ($timedOut) { "command_timeout" } else { "process_exit" }
            stdout_tail        = ($stdout -split "`n" | Select-Object -Last 20) -join "`n"
            stderr_tail        = ($stderr -split "`n" | Select-Object -Last 20) -join "`n"
        }
    } finally {
        if ($proc) { $proc.Dispose() }
        if (Test-Path -LiteralPath $stdoutFile) { Remove-Item -LiteralPath $stdoutFile -Force }
        if (Test-Path -LiteralPath $stderrFile) { Remove-Item -LiteralPath $stderrFile -Force }
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
# Pool EVERY verification-manifest row whose milestone-id matches the requested
# milestone. The gate evaluates all named checks for that milestone, not just
# the first one. (Prior behavior used `Select-Object -First 1`, which silently
# skipped any second/third CHK-* row even when the roadmap explicitly named
# them as load-bearing -- calibration event: 2026-05-27 db-durability build at
# file-sorter, where M02 reported PASS by only running CHK-M02-POPULATED-UPGRADE
# while CHK-M02-ROLLBACK and CHK-M02-STALE-V11-REGRESSION were skipped.)
$matchingVerificationRows = @($verificationRows | Where-Object { $_.'milestone-id'.ToString().ToUpperInvariant().Trim() -eq $mid })

if (-not $milestoneRow) {
    Write-Error "MILESTONE_NOT_FOUND: $MilestoneId not present in ## Milestones"
    exit 2
}
if ($matchingVerificationRows.Count -eq 0) {
    Write-Error "VERIFICATION_CHECK_NOT_FOUND: no chk-* row for milestone-id=$MilestoneId in ## Verification Manifest"
    exit 2
}

$acceptanceText = [string]$milestoneRow.'acceptance-checks'
$accept = Extract-NamedArtifacts -Text $acceptanceText

# Per-check evaluation. Each verification row in the manifest produces an
# independent breakdown (check_id, procedure_text, artifacts/commands named in
# its procedure cell, presence check against the working tree, command exit
# codes when -RunTests, and per-check blockers). The top-level rolled-up view
# below preserves the existing fields the ledger consumes.
$verificationChecks = New-Object System.Collections.Generic.List[object]
$allArtifactsList = New-Object System.Collections.Generic.List[string]
foreach ($a in $accept.artifacts) { if (-not $allArtifactsList.Contains($a)) { $allArtifactsList.Add($a) | Out-Null } }
$allCommandsList = New-Object System.Collections.Generic.List[string]
$allCommandResults = New-Object System.Collections.Generic.List[object]
$topBlockers = New-Object System.Collections.Generic.List[string]
$procedureTexts = New-Object System.Collections.Generic.List[string]
$anyCommandFailed = $false
$anyCommandRan = $false

# Milestone-level acceptance-text artifacts (not tied to any single check, but
# still required to be present in the working tree).
$acceptancePresence = Test-ArtifactPresence -WorkingTree $WorkingTree -Artifacts $accept.artifacts
foreach ($m in $acceptancePresence.missing) {
    $msg = "named artifact missing (from milestone acceptance text): $m"
    if (-not $topBlockers.Contains($msg)) { $topBlockers.Add($msg) | Out-Null }
}

foreach ($vRow in $matchingVerificationRows) {
    $checkId = [string]$vRow.'check-id'
    $procedureText = [string]$vRow.procedure
    $procedureTexts.Add($procedureText) | Out-Null

    $extracted = Extract-NamedArtifacts -Text $procedureText
    $checkArtifacts = @($extracted.artifacts)
    $checkCommands = @($extracted.commands)
    $checkPresence = Test-ArtifactPresence -WorkingTree $WorkingTree -Artifacts $checkArtifacts

    foreach ($a in $checkArtifacts) {
        if (-not $allArtifactsList.Contains($a)) { $allArtifactsList.Add($a) | Out-Null }
    }
    foreach ($c in $checkCommands) {
        if (-not $allCommandsList.Contains($c)) { $allCommandsList.Add($c) | Out-Null }
    }

    $checkCommandResults = @()
    $checkTestStatus = "NOT_RUN"
    if ($RunTests) {
        if ($checkCommands.Count -eq 0) {
            $checkTestStatus = "NO_COMMAND_NAMED"
        } else {
            $anyFailedHere = $false
            foreach ($cmd in $checkCommands) {
                $r = Invoke-NamedCommand -WorkingTree $WorkingTree -Command $cmd -TimeoutMs $CommandTimeoutMs
                $r | Add-Member -NotePropertyName "check_id" -NotePropertyValue $checkId -Force
                $checkCommandResults += $r
                $allCommandResults.Add($r) | Out-Null
                $anyCommandRan = $true
                if ($r.exit_code -ne 0) { $anyFailedHere = $true; $anyCommandFailed = $true }
            }
            $checkTestStatus = if ($anyFailedHere) { "FAIL" } else { "PASS" }
        }
    }

    $checkBlockers = New-Object System.Collections.Generic.List[string]
    foreach ($m in $checkPresence.missing) {
        $msg = "named artifact missing: $m"
        $checkBlockers.Add($msg) | Out-Null
        $tagged = "[$checkId] $msg"
        if (-not $topBlockers.Contains($tagged)) { $topBlockers.Add($tagged) | Out-Null }
    }
    if ($checkTestStatus -eq "FAIL") {
        foreach ($r in $checkCommandResults | Where-Object { $_.exit_code -ne 0 }) {
            $msg = if ($r.timed_out) {
                "verification command timed out after $($r.timeout_ms)ms: $($r.command)"
            }
            else {
                "verification command failed (exit=$($r.exit_code)): $($r.command)"
            }
            $checkBlockers.Add($msg) | Out-Null
            $tagged = "[$checkId] $msg"
            if (-not $topBlockers.Contains($tagged)) { $topBlockers.Add($tagged) | Out-Null }
        }
    }
    if ($checkArtifacts.Count -eq 0 -and $checkCommands.Count -eq 0) {
        # This individual verification check names nothing runnable.
        $msg = "verification check names no concrete test file or command"
        $checkBlockers.Add($msg) | Out-Null
        $tagged = "[$checkId] $msg"
        if (-not $topBlockers.Contains($tagged)) { $topBlockers.Add($tagged) | Out-Null }
    }

    $verificationChecks.Add([pscustomobject]@{
        check_id          = $checkId
        procedure_text    = $procedureText
        artifacts_named   = $checkArtifacts
        artifacts_present = @($checkPresence.present)
        artifacts_missing = @($checkPresence.missing)
        commands_named    = $checkCommands
        command_results   = @($checkCommandResults)
        test_status       = $checkTestStatus
        blockers          = @($checkBlockers)
    }) | Out-Null
}

$allArtifacts = $allArtifactsList.ToArray()
$allCommands = $allCommandsList.ToArray()
$presence = Test-ArtifactPresence -WorkingTree $WorkingTree -Artifacts $allArtifacts
$commandResults = $allCommandResults.ToArray()

# Rolled-up test_status mirrors the per-check union.
$testStatus = "NOT_RUN"
if ($RunTests) {
    if (-not $anyCommandRan) {
        $testStatus = "NO_COMMAND_NAMED"
    } elseif ($anyCommandFailed) {
        $testStatus = "FAIL"
    } else {
        $testStatus = "PASS"
    }
}

# A final acceptance run must execute at least one command. Artifact presence is
# evidence, but it is not a test and cannot satisfy the four-axis PASS contract.
if ($RunTests -and $testStatus -eq "NO_COMMAND_NAMED") {
    $msg = "roadmap names no executable verification command across any check for $mid"
    if (-not $topBlockers.Contains($msg)) { $topBlockers.Add($msg) | Out-Null }
}

$blockers = $topBlockers.ToArray()

$accepted = $RunTests -and ($blockers.Count -eq 0) -and ($presence.missing.Count -eq 0) -and ($testStatus -eq "PASS")
$status = if (-not $RunTests) { "INSPECT_ONLY" } elseif ($accepted) { "PASS" } else { "BLOCKED" }

$result = [pscustomobject]@{
    milestone_id              = $mid
    acceptance_checks_text    = $acceptanceText
    verification_check_text   = ($procedureTexts -join "`n---`n")
    verification_checks       = $verificationChecks.ToArray()
    artifacts_named           = $allArtifacts
    artifacts_present         = $presence.present
    artifacts_missing         = $presence.missing
    commands_named            = $allCommands
    command_results           = $commandResults
    test_status               = $testStatus
    implemented_hint          = $false  # final ledger derives this from persisted milestone commit evidence
    tested                    = ($testStatus -eq "PASS")
    accepted                  = $accepted
    status                    = $status
    blockers                  = @($blockers)
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8
}
else {
    Write-Output ("Milestone {0}: {1}" -f $result.milestone_id, $result.status)
    Write-Output ("  Verification checks: {0}" -f $result.verification_checks.Count)
    foreach ($vc in $result.verification_checks) {
        Write-Output ("  - {0} [{1}]" -f $vc.check_id, $vc.test_status)
        foreach ($r in $vc.command_results) {
            Write-Output ("      [exit={0}] {1}" -f $r.exit_code, $r.command)
        }
        foreach ($m in $vc.artifacts_missing) {
            Write-Output ("      missing: {0}" -f $m)
        }
    }
    if ($result.blockers.Count -gt 0) {
        Write-Output "  Blockers:"
        $result.blockers | ForEach-Object { Write-Output "    - $_" }
    }
}

if ($status -in @("PASS", "INSPECT_ONLY")) { exit 0 } else { exit 1 }
