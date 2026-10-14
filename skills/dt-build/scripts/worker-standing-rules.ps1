function Get-WorkerFixRoundRule {
    param([ValidateRange(1, 2147483647)][int]$MaxFixRounds = 2)
    return "Run the full named test selection without early-stop flags (no --maxfail, -x or --exitfirst); classify every failure, fix them together, then rerun the full selection. Allow at most $MaxFixRounds fix rounds (a round is a batch of fixes followed by a full rerun, not an individual failing test). Keep going on the most promising path while the remaining failures are narrowing. Stop early if the same failing set appears in two consecutive rounds, or when the round budget is spent; report remaining failures."
}
