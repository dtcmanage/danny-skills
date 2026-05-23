# Build Plan — anthropic-refactor Phase 0 (Foundation) — 20260521-1959

## Scope
Phase 0 only of `design-final.md` (Anthropic-Standard Skill Pipeline Refactor). Purely additive
repo-level scaffolding. No pipeline-skill changes except the lone exception: the
dt-starter-session-audit Appendix-A -> pointer swap (audit is not a pipeline skill).

Approved by Danny: Phase 0 scope; one dt-build run = one phase; advance to Phase 1 only on explicit go-ahead.

## Run
RUN_ID: 20260521-1959
build_branch: dt-build/20260521-1959
base_sha: 973f2e677459c5917aa6cbac1d8fb885f5d376d0
merge_target: dev
target_repo: D:\Claude\_Claude-Workspace\Skill Creation\danny-skills

## Resolved decisions (Decision Ledger)
1. Plugin version: 0.7.0 (plan said 0.3.0 -> downgrade vs current 0.6.0; plan defect, local amendment). Amendment 1.
2. Mermaid pin: 10.9.3 (latest stable 10.x = plan baseline). Source jsdelivr npm. Acceptance date 2026-05-21.
3. Master checklist: anthropic-refactor/PROGRESS.md (project folder, NOT the repo).
4. CDC/glossary in Phase 0 = create canonical files additively; inline copies in dt-design-build/dt-design-loop
   stay until Phases 1/4 swap them to pointers. Audit Appendix-A -> pointer is the one live skill edit.

## Baseline verification floor
The repo is a skill pack: no build/test/lint/typecheck system exists. Baseline floor = none (skip).
Verification rests entirely on the plan-specified acceptance checks below.

## Milestones
| m# | name | verification-mode | execution scope |
|----|------|-------------------|-----------------|
| M1 | Repo scaffolding + canonical contract files | machine + agent (content fidelity) | milestone_local + integration (dirs/files exist; CDC verbatim) |
| M2 | Reference docs (conventions, security-posture, redaction-tests) | agent (completeness vs plan) | milestone_local |
| M3 | Security code primitives + verification | machine | integration (redaction corpus 0 leaks/<5% FP; envelope byte-identity) |
| M4 | Vendor mermaid 10.9.3 + upstream-deps | machine | integration (on-disk SHA256 == recorded) |
| M5 | skill-template scaffold + plugin bump 0.7.0 | machine | integration (JSON valid; scaffold present) |

## Verification manifest
- VM1 redaction-corpus: run scripts/security/redact-secrets.ps1 over the corpus in
  references/security-redaction-tests.md. Pass: 0 known-secret leaks; <5% false-positive on safe strings. (integration)
- VM2 envelope-byte-identity: scripts/wrap-prompt-envelope.ps1 produces the exact BEGIN/END+preamble
  envelope; identical output across repeated calls on a fixture. (integration)
- VM3 mermaid-integrity: on-disk SHA256 of assets/visualize/vendored/mermaid-10.9.3.min.js ==
  value recorded in references/upstream-skill-dependencies.md. (integration)
- VM4 json-validity: plugin.json + marketplace.json parse as valid JSON; both at version 0.7.0. (integration)
- VM5 scaffold-present: all 7 foundation dirs exist; references/skill-template/ has SKILL.md + 3 subfolders. (integration)
- VM6 cdc-fidelity: references/canonical-dimension-contract.md content matches the source inline CDC verbatim. (milestone_local M1)
- VM7 no-secret-in-artifacts: no raw secret value committed in any Phase 0 file. (integration)

## Routing
All chunks Claude. M3 (the two scripts) delegated to a Claude build subagent; M1/M2/M4/M5 authored by the
orchestrator directly (small additive foundation phase, house-style-critical content, full plan context in
hand; the heavyweight worktree/Codex/reference-pack fan-out is disproportionate to a half-day additive phase).
Recorded as a scaling decision in build-decision-log.md.
