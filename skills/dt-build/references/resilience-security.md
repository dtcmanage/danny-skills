# Resilience and Security

Intake resilience controls in Phase 7A:
- Branch drift detection via `scripts/check-drift.ps1`.
- Worktree containment hard-block via `scripts/check-worktree-containment.ps1`.
- Resume compatibility gate rejects legacy pre-refactor run folders.
- Contract validation fails closed on schema and dependency violations.

Execution resilience controls in Phase 7B:
- Codex prompt assembly and verify gates run through deterministic scripts.
- Codex execution runs only through `scripts/invoke-codex-chunk.ps1`, with cache-verified model resolution,
  explicit effort, a mandatory one-line selection reason, stdin prompt delivery, redacted logs, and retained
  provenance containing the canonical user-visible disclosure line.
- Verify/fix automation is capped at two implementation failures per milestone. Environment, tooling, and
  approved contract-revision failures are recorded but do not consume implementation attempts.
- Integration-branch updates run through compare-and-swap (`scripts/branch-cas-update.ps1`) after rehearsal.
- Single dispatch: when a step must launch exactly one child (a one-shot review), pass `-SingleDispatch` to
  `invoke-codex-chunk.ps1` or `invoke-claude-chunk.ps1`. Every branch that would relaunch the child (the Codex
  capacity backoff, offline recovery, the unexplained-failure retry) then fails closed with
  `failure_category: single-dispatch-refused`; provenance records `single_dispatch` and
  `single_dispatch_refused_branch` (and the dispatch count). Without the switch, behavior is unchanged.

Shared posture:
- Use repo-level `references/security-posture.md` as the policy anchor.
- Route run-log writes through repo-level redaction module.
