# dt-session-audit changelog

- 0.8.1 (2026-11-22): Command Center backstop and workspace upload use host-neutral paths (Linux session host first; cc.ps1 runs under pwsh).

- 0.8.0 (2026-11-16): Add the read-only AI-item exit backstop with transcript discovery, readiness checks, three exit choices and isolated HTTP regression tests.

- 0.7.1 (2026-11-16): Anchor the directory-drift script path as <skill>/scripts/.

- 0.7.0 (2026-11-16): Session audits run check-directory-drift.ps1 and route mismatches between the workspace folder list and the real folders as findings; linked worktrees are ignored.

- 0.6.1 (2026-10-18): Anchor runnable script paths to resolved skill and repository roots (FS-117).

- 0.6.0 (2026-10-13): Add a Command Center backstop to reconcile session open and finished items, move misplaced open-for-Danny memory entries, and report list writes.

- 0.5.1 (2026-09-03): Adopt the shared CommonMark-safe local file-link contract: forward-slash destinations, angle brackets for spaces, and backticked literals.

- 0.5.0 (2026-08-30): Residency Test and root write gate cover refine operations (a refine that would fail residency today relocates instead of growing root); condition 4 measured deterministically via detect-memory-bloat.ps1 word_count with References rows counted in the after-total; same gate extended to workstation CLAUDE.md writes minus the root-scope condition.

- 0.4.0 (2026-08-27): Residency Test for every rule finding: CLAUDE.md is a router, so a rule with a recognizable trigger routes to the owning reference file (and its References trigger row) instead of CLAUDE.md; only trigger-less rules stay resident. Added a four-condition root CLAUDE.md write gate (residency, true-at-root scope, no duplicate of a reference file, word ceiling respected by trimming not raising) with before/after word count reported. Destination-file sweep now enumerates Resources reference files alongside CLAUDE.md/MEMORY.md/CONTEXT.md/glossary.md, so routed findings cannot silently misfile into CLAUDE.md.

- 0.3.2 (2026-07-12): Inherited the established pack-wide versioning policy and release gate.

- 0.3.1 (2026-07-05): Workspace-upload step is platform-aware: workspace-sync.ps1 on the PC, workspace-sync.sh on the Mac (~/Claude).
- 0.3.0 (2026-07-05): Final workspace-upload step: run workspace-sync.ps1 after every audit so scaffolding edits reach GitHub immediately instead of waiting for the 4-hourly sync.
- 0.2.0 (2026-07-05): Deterministic scope-discovery sweep of existing memory files before routing; session-audit-view.html on request only.
