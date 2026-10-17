function Get-WorkerFixRoundRule {
    param([ValidateRange(1, 2147483647)][int]$MaxFixRounds = 2)
    return "Run the full named test selection without early-stop flags (no --maxfail, -x or --exitfirst); classify every failure, fix them together, then rerun the full selection. Allow at most $MaxFixRounds fix rounds (a round is a batch of fixes followed by a full rerun, not an individual failing test). Keep going on the most promising path while the remaining failures are narrowing. Stop early if the same failing set appears in two consecutive rounds, or when the round budget is spent; report remaining failures."
}

function Get-WorkerHardwareRule {
    return 'Use the brief''s measured host, CPU/shard and RAM budgets. Run safe suites in parallel with pytest-xdist -n <budget> (pytest -n auto only within an allocated CPU budget) or the project''s sharded runner; run independent commands concurrently within the assigned cap. Keep the full selection. Serial work requires the plan''s named reason and evidence; report new contention for a decision revision. Isolate DB/file roots and ports before requesting exclusivity. FS-58 exclusive_reason is opt-in for the affected job only. If a budget or decision is missing, measure and record it before heavy work; never silently default to single-process execution. Test subprocesses are allowed; do not spawn nested agents.'
}
