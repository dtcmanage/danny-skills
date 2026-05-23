# Resilience and Security

Intake resilience controls in Phase 7A:
- Branch drift detection via `scripts/check-drift.ps1`.
- Worktree containment hard-block via `scripts/check-worktree-containment.ps1`.
- Resume compatibility gate rejects legacy pre-refactor run folders.
- Contract validation fails closed on schema and dependency violations.

Shared posture:
- Use repo-level `references/security-posture.md` as the policy anchor.
- Route run-log writes through repo-level redaction module.
