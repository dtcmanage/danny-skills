# Build Decision Log — anthropic-refactor Phase 0 — 20260521-1959

Append-only. Latest at bottom.

## Plan Amendments
- Amendment 1 (spec_revision r0 -> r1): Plugin foundation-drop version changed from plan's 0.3.0 to 0.7.0.
  Reason: repo is already at 0.6.0; 0.3.0 would be a downgrade. Danny approved 0.7.0. The plan's later two
  milestone bumps shift accordingly (cutover -> 0.8.0, stabilization -> 1.0.0). To be recorded in the plan's
  Plan Amendments ledger when Phase 0 lands.

## Tactical decisions (orchestrator)
- T1: Scale-to-plan. Phase 0 is a half-day additive foundation phase in the danny-skills repo where the
  orchestrator already holds full plan context and house-style rules. Running the full heavyweight dt-build
  machinery (per-chunk worktrees, reference-pack files + run manifest, Codex on-disk prompt assembly + verify
  gate) is disproportionate. Decision: lightweight dt-build path. Orchestrator authors M1/M2/M4/M5 directly;
  M3 (the two security scripts = the only true "product code") delegated to a Claude build subagent. Full
  verification discipline preserved (machine checks run directly; per-milestone commit gates). Reference pack
  not materialized; CONTEXT.md serves as the shared terminology reference for subagent briefs.
- T2: Dirty-tree handling = scope-commit-only (no stash isolation). Unrelated WIP (M skills/dt-handoff/SKILL.md,
  untracked codex-root-skills/, tools/) left untouched in the working tree; every milestone commit adds only
  its specific Phase 0 paths. Phase 0 creates new top-level dirs that cannot collide with the WIP.
- T3: Run-folder .dt-build/20260521-1959/ is orchestrator scaffolding; never git add'd. PROGRESS.md lives in
  the anthropic-refactor project folder, not the repo, so it never enters a commit.
- T4: CDC/glossary interpretation (build-plan decision 4): Phase 0 creates the canonical files additively;
  pointer-swaps in the two pipeline skills deferred to Phases 1/4. Confirmed against plan text (Phases 1 and 4
  explicitly perform the CDC pointer swap; audit Appendix-A swap is the one explicit Phase 0 exception).
