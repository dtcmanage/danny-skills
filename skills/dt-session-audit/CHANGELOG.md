# dt-session-audit changelog

- 0.4.0 (2026-08-27): Residency Test for every rule finding: CLAUDE.md is a router, so a rule with a recognizable trigger routes to the owning reference file (and its References trigger row) instead of CLAUDE.md; only trigger-less rules stay resident. Added a four-condition root CLAUDE.md write gate (residency, true-at-root scope, no duplicate of a reference file, word ceiling respected by trimming not raising) with before/after word count reported. Destination-file sweep now enumerates Resources reference files alongside CLAUDE.md/MEMORY.md/CONTEXT.md/glossary.md, so routed findings cannot silently misfile into CLAUDE.md.

- 0.3.2 (2026-07-12): Inherited the established pack-wide versioning policy and release gate.

- 0.3.1 (2026-07-05): Workspace-upload step is platform-aware: workspace-sync.ps1 on the PC, workspace-sync.sh on the Mac (~/Claude).
- 0.3.0 (2026-07-05): Final workspace-upload step: run workspace-sync.ps1 after every audit so scaffolding edits reach GitHub immediately instead of waiting for the 4-hourly sync.
- 0.2.0 (2026-07-05): Deterministic scope-discovery sweep of existing memory files before routing; session-audit-view.html on request only.
