# dt-build — CHANGELOG

## 2.10.0

- Model-selection disclosure: every subagent dispatch states the selected model and a one-sentence reason in chat for tier-routing tracking.

## 2.9.1

- Dual-harness wording pass from the Codex harness review: harness contract + CLAUDE_DISPATCH abstraction used in steps 6.b/6.c/6.d/6.5, lane-neutral prompt assembly, Claude-tier preflight on codex-host, compatibility/invocation wording, ScheduleWakeup dropped from allowed-tools, approval posture recorded in Codex wrapper provenance. Codex orchestration remains unverified end-to-end.

## 2.9.0

- Two-lane model tiering: Claude-lane tier map (haiku/sonnet/opus), light-tier implementation allowed with escalate-on-retry, cross-model dispatch via new invoke-claude-chunk.ps1, milestone scope lock with DISCOVERED_ENHANCEMENTS report field (report contract v2), orchestrator-owned enhancement triage, deferred-findings section in the final ledger.

## 2.8.3

- Aligned light-tier Codex fallbacks with the canonical GPT-5.6 matrix while retaining strict cache validation.

## 2.8.2

- Added the pack-wide version-policy gate to danny-skills finalization.

Historical `metadata.changelog` entries, relocated verbatim from the SKILL.md frontmatter on
2026-07-05 so the skill no longer loads ~1,000 words of history on every fire. Newest first; new
entries go at the top. The connective lead-ins ("Prior ...", "Previous ...") are preserved exactly
as they appeared in the original single frontmatter string.

## 2.8.1

- Added deterministic GPT-5.6 routing and invocation provenance: Terra/medium for standard chunks,
  Sol/medium for load-bearing or second attempts, and Luna only for light preflight/routine work.
- Fixed the impossible parent/child Git ref contract by making `build/<RUN_ID>` the sole state carrier.
- Final ledgers now render append-only acceptance rows by default, require commit-backed implementation
  evidence, preserve semantic downgrade approvals, and avoid rerunning disposable-environment tests.
- Acceptance commands no longer duplicate inner pytest calls, use bounded file-redirected execution to
  avoid stdout/stderr deadlocks, and cannot PASS final acceptance without an executed command.
- Fixed fresh-process intake, stale `dev` defaults, junction root resolution, multi-check load-bearing
  detection, and non-blocking drift exits. Added dependency-preflight and attempt-category semantics.
- Hardened the canonical Codex wrapper with an internal process-tree timeout, structured report validation,
  effort/model compatibility checks, failure provenance, and redaction of both streams and retained output.
- Final ledger evidence now resolves the recorded commit in live Git history, rejects compound pseudo-PASS
  statuses and unapproved per-check downgrades, and blocks protected-branch intake/CAS mutations.
- Added a hermetic regression suite covering historical false-PASS cases, noisy/deadlocked commands, model
  fallback, malformed/hanging Codex processes, branch preparation/CAS, resume safety, and the two-attempt cap.

## 2.7.1

- `verify-milestone-acceptance.ps1` spawns named commands via `-EncodedCommand` so embedded double quotes
  (for example, quoted paths) no longer truncate the command.

## 2.7.0

- Added per-milestone `_build-state.md` checkpoints using the dt-pipeline template and COMPLETE marking.
- Made `build-run-review.html` on-request only and accepted `design-final-*.md` intake.
- Relocated frontmatter changelog history to this file.

## 2.6.0

- Roadmap-preferred-not-required intake: dt-build now accepts a finalized design (design-final.md / plan-draft.md) as input, not only a dt-roadmap roadmap.md. New procedure steps 2 (detect roadmap vs design), 2.5 (auto-generate the roadmap from a design via the canonical skills/dt-roadmap/scripts/build-roadmap.ps1 — no re-implemented milestone parsing, no schema duplication), and 2.6 (validate, formerly step 2). A roadmap is preferred for heavier builds (many milestones or any load-bearing/gate milestone, which dt-build now recommends a reviewed dt-roadmap pass for) but is never a hard requirement; when a design lacks an Implementation Sequence / Validation Gates surface the build STOPS with the producer's graceful explanatory message instead of crashing. 'When this fires' and references/shared-input-routing.md updated to document design-or-roadmap intake.

## 2.5.0

- Prior 2.5.0 trunk-based-branch-model: integration target moved off the retired dev branch to a short-lived build/<RUN_ID> branch cut from main (2026-05-28 workspace-wide trunk migration); per-milestone accepted work compare-and-swaps onto build/<RUN_ID>, and the rehearsed branch is left for a separate human-authorized /git-merge-feature to main (dt-build never writes to main). scripts/dev-cas-update.ps1 renamed to scripts/branch-cas-update.ps1 and generalized (mandatory -TargetBranch/-ExpectedTargetSha; output keys target_branch/expected_target_sha/observed_target_sha; CAS_* error prefixes). branch-contract.md, resilience-security.md, and subagent-prompts.md updated.

## 2.4.0

- Prior 2.4.0 behavior retained: Per-milestone acceptance gate now evaluates EVERY verification-manifest row for a milestone, not just the first. Prior implementation (verify-milestone-acceptance.ps1) used `Select-Object -First 1` against the rows matched by milestone-id, so any milestone with multiple CHK-* checks had partial gate coverage — only the first check's procedure was parsed for artifacts/commands and only its named test command was run. Calibration event: 2026-05-27 db-durability build at file-sorter, where M02 reported PASS by running only CHK-M02-POPULATED-UPGRADE while CHK-M02-ROLLBACK and CHK-M02-STALE-V11-REGRESSION were silently skipped despite being load-bearing in the roadmap. v2.4.0 changes: (1) verify-milestone-acceptance.ps1 pools every matching verification row, extracts artifacts and commands per row, presence-checks each row's artifacts against the working tree, runs each row's named commands under -RunTests, and folds every exit code into the verdict. JSON output adds a `verification_checks` array (each element exposes check_id, procedure_text, artifacts_named/present/missing, commands_named, command_results, test_status, blockers) alongside the existing top-level fields (status/accepted/blockers/artifacts_missing/commands_named/command_results) which remain the rolled-up view consumed by build-acceptance-ledger.ps1. status is PASS only when every check's blockers are empty. (2) build-acceptance-ledger.ps1 surfaces the per-check breakdown in the HTML ledger as a Verification Check Detail section — one sub-table per milestone listing each CHK-* id, status badge, named artifacts (with missing markers), and named commands with exit codes. Markdown ledger remains the roll-up. (3) acceptance-contract.md updated to document that the gate evaluates every verification row per milestone — the contract previously read as if every check was enforced; v2.4.0 makes the implementation match.

## 2.3.1

- Previous 2.3.1 acceptance gate fixes (pytest -> python -m pytest, downgrade_approved_by parser + APPROVED_DOWNGRADE status) are retained unchanged.
