# Resilience and Security

Intake resilience controls in Phase 7A:
- Branch drift detection via `scripts/check-drift.ps1`.
- Worktree containment hard-block via `scripts/check-worktree-containment.ps1`.
- Resume compatibility gate rejects legacy pre-refactor run folders.
- Contract validation fails closed on schema and dependency violations.

Execution resilience controls in Phase 7B:
- Codex prompt assembly and verify gates run through deterministic scripts.
- Codex execution runs only through `scripts/invoke-codex-chunk.ps1`, with cache-verified model resolution,
  explicit effort, stdin prompt delivery, redacted logs, and retained provenance.
- Verify/fix automation is capped at two implementation failures per milestone. Environment, tooling, and
  approved contract-revision failures are recorded but do not consume implementation attempts.
- Integration-branch updates run through compare-and-swap (`scripts/branch-cas-update.ps1`) after rehearsal.

Shared posture:
- Use repo-level `references/security-posture.md` as the policy anchor.
- Route run-log writes through repo-level redaction module.
