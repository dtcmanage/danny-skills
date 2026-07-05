# dt-build — CHANGELOG

Historical `metadata.changelog` entries, relocated verbatim from the SKILL.md frontmatter on
2026-07-05 so the skill no longer loads ~1,000 words of history on every fire. Newest first; new
entries go at the top. The connective lead-ins ("Prior ...", "Previous ...") are preserved exactly
as they appeared in the original single frontmatter string.

## 2.6.0

2.6.0 roadmap-preferred-not-required intake: dt-build now accepts a finalized design (design-final.md / plan-draft.md) as input, not only a dt-roadmap roadmap.md. New procedure steps 2 (detect roadmap vs design), 2.5 (auto-generate the roadmap from a design via the canonical skills/dt-roadmap/scripts/build-roadmap.ps1 — no re-implemented milestone parsing, no schema duplication), and 2.6 (validate, formerly step 2). A roadmap is preferred for heavier builds (many milestones or any load-bearing/gate milestone, which dt-build now recommends a reviewed dt-roadmap pass for) but is never a hard requirement; when a design lacks an Implementation Sequence / Validation Gates surface the build STOPS with the producer's graceful explanatory message instead of crashing. 'When this fires' and references/shared-input-routing.md updated to document design-or-roadmap intake.

## 2.5.0

Prior 2.5.0 trunk-based-branch-model: integration target moved off the retired dev branch to a short-lived build/<RUN_ID> branch cut from main (2026-05-28 workspace-wide trunk migration); per-milestone accepted work compare-and-swaps onto build/<RUN_ID>, and the rehearsed branch is left for a separate human-authorized /git-merge-feature to main (dt-build never writes to main). scripts/dev-cas-update.ps1 renamed to scripts/branch-cas-update.ps1 and generalized (mandatory -TargetBranch/-ExpectedTargetSha; output keys target_branch/expected_target_sha/observed_target_sha; CAS_* error prefixes). branch-contract.md, resilience-security.md, and subagent-prompts.md updated.

## 2.4.0

Prior 2.4.0 behavior retained: Per-milestone acceptance gate now evaluates EVERY verification-manifest row for a milestone, not just the first. Prior implementation (verify-milestone-acceptance.ps1) used `Select-Object -First 1` against the rows matched by milestone-id, so any milestone with multiple CHK-* checks had partial gate coverage — only the first check's procedure was parsed for artifacts/commands and only its named test command was run. Calibration event: 2026-05-27 db-durability build at file-sorter, where M02 reported PASS by running only CHK-M02-POPULATED-UPGRADE while CHK-M02-ROLLBACK and CHK-M02-STALE-V11-REGRESSION were silently skipped despite being load-bearing in the roadmap. v2.4.0 changes: (1) verify-milestone-acceptance.ps1 pools every matching verification row, extracts artifacts and commands per row, presence-checks each row's artifacts against the working tree, runs each row's named commands under -RunTests, and folds every exit code into the verdict. JSON output adds a `verification_checks` array (each element exposes check_id, procedure_text, artifacts_named/present/missing, commands_named, command_results, test_status, blockers) alongside the existing top-level fields (status/accepted/blockers/artifacts_missing/commands_named/command_results) which remain the rolled-up view consumed by build-acceptance-ledger.ps1. status is PASS only when every check's blockers are empty. (2) build-acceptance-ledger.ps1 surfaces the per-check breakdown in the HTML ledger as a Verification Check Detail section — one sub-table per milestone listing each CHK-* id, status badge, named artifacts (with missing markers), and named commands with exit codes. Markdown ledger remains the roll-up. (3) acceptance-contract.md updated to document that the gate evaluates every verification row per milestone — the contract previously read as if every check was enforced; v2.4.0 makes the implementation match.

## 2.3.1

Previous 2.3.1 acceptance gate fixes (pytest -> python -m pytest, downgrade_approved_by parser + APPROVED_DOWNGRADE status) are retained unchanged.
- 2.7.0 (2026-07-05): Per-milestone _build-state.md checkpoint (dt-pipeline template) with COMPLETE marking; build-run-review.html on request only; intake accepts design-final-*.md; frontmatter changelog relocated to CHANGELOG.md.
