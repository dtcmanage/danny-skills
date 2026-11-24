function Get-WorkerFixRoundRule {
    param([ValidateRange(1, 2147483647)][int]$MaxFixRounds = 2)
    return "Run the full named test selection without early-stop flags (no --maxfail, -x or --exitfirst); classify every failure, fix them together, then rerun the full selection. Allow at most $MaxFixRounds fix rounds (a round is a batch of fixes followed by a full rerun, not an individual failing test). Keep going on the most promising path while the remaining failures are narrowing. Stop early if the same failing set appears in two consecutive rounds, or when the round budget is spent; report remaining failures."
}

function Get-WorkerEnvironmentRule {
    param([switch]$ReadOnly)
    $verification = if ($ReadOnly) { 'Run authorized read-only verification and report failures with the failing command, evidence and remaining failures. Do not edit or repair files.' } else { 'Run your own verification and fix failures until green within the fix-round budget; do not return PARTIAL on the first repairable failure. Report a real blocker with the failing command, evidence and remaining failures.' }
    return $verification + ' Derive network/SSH allowances from the milestone gate and verification commands and their fixtures, including required hosts and credentials; never impose a blanket offline or no-SSH rule. Keep access inside existing authorization; report a conflict with an explicit boundary as a blocker. Read live git facts before work and before reporting: resolve the default branch using git symbolic-ref refs/remotes/origin/HEAD; if unavailable inspect existing local branches and repository configuration (main or master only when present), then git rev-parse <resolved-default-branch>, git rev-parse HEAD, git branch --show-current and git status --short; never copy current hashes or branch state from memory.'
}

function Get-WorkerHardwareRule {
    return 'Use the brief''s measured host, CPU/shard and RAM budgets. Run safe suites in parallel with pytest-xdist -n <budget> (pytest -n auto only within an allocated CPU budget) or the project''s sharded runner; run independent commands concurrently within the assigned cap. Keep the full selection. Serial work requires the plan''s named reason and evidence; report new contention for a decision revision. Isolate DB/file roots and ports before requesting exclusivity. FS-58 exclusive_reason is opt-in for the affected job only. If a budget or decision is missing, measure and record it before heavy work; never silently default to single-process execution. Test subprocesses are allowed; do not spawn nested agents.'
}

function Get-WorkerLogRule {
    return 'Write every log, test transcript and command-output file into the directory named by the DT_BUILD_LOG_DIR environment variable (the dispatch wrapper sets it inside the run folder), never into the worktree (logs there show up as changed files) or your home directory or the worktree''s parent; then read only the summary or the last 40 lines.'
}

function Get-WorkerLogDirectory {
    # Where a dispatched worker writes its logs: the dt-job's own folder (jobs/<id>/logs), else a logs folder beside
    # the report in the run folder, else a temp folder. Never the worktree, its parent, or the process cwd.
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$OutputPath, [string]$JobDirectory = $env:DT_JOB_DIR, [string]$Label = 'worker')
    $project = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('/', '\')
    $unsafe = { param([string]$Path)
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('/', '\')
        $comparison = if ([OperatingSystem]::IsWindows() -or [OperatingSystem]::IsMacOS()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        $full.Equals($project, $comparison) -or $full.StartsWith($project + [IO.Path]::DirectorySeparatorChar, $comparison) -or
            $full.Equals((Split-Path -Parent $project), $comparison) -or $full.Equals([IO.Path]::GetFullPath([Environment]::GetFolderPath('UserProfile')).TrimEnd('/', '\'), $comparison) -or
            (Split-Path -Parent $full).Equals([IO.Path]::GetTempPath().TrimEnd('/', '\'), $comparison)
    }
    $candidates = @()
    if ($JobDirectory) { $candidates += (Join-Path $JobDirectory 'logs') }
    if ($OutputPath) { $candidates += (Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))) 'logs') }
    foreach ($candidate in $candidates) {
        if (& $unsafe $candidate) { continue }
        try { New-Item -ItemType Directory -Path $candidate -Force | Out-Null; return [IO.Path]::GetFullPath($candidate) } catch { }
    }
    $safeLabel = ($Label -replace '[^\w.-]', '-')
    $fallback = Join-Path ([IO.Path]::GetTempPath()) ("dt-build-logs/{0}-{1}" -f $safeLabel, [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $fallback -Force | Out-Null
    return [IO.Path]::GetFullPath($fallback)
}
