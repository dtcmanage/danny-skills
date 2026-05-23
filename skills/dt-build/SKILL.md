---
name: dt-build
description: "Execute a validated roadmap contract end-to-end. Trigger on /dt-build or 'dt-build <roadmap-path>'."
disable-model-invocation: true
user-invocable: true
allowed-tools: "Bash(git:*) Bash(codex:*) Bash(pwsh:*) Read Write Edit Agent AskUserQuestion ScheduleWakeup"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 2.1.0
  changelog: "Phase 7B execution-parity refactor: deterministic codex-prompt assembly/verification scripts, dev compare-and-swap script, and execution-path parity guardrails."
---

# Build Executor

`dt-build` consumes a finalized `roadmap.md` contract and executes milestones on `dev`.
Phase 7A established deterministic roadmap-first intake. Phase 7B restores execution parity through deterministic execution-side scripts.

## When this fires

Trigger when all are true:
- Input artifact is `roadmap.md` produced by `dt-roadmap`.
- Repository is a git repo.
- Danny is asking to run the build stage, not planning/review.

Do NOT fire for:
- Plan authoring or redesign (`dt-plan`, `dt-review`).
- Roadmap production (`dt-roadmap`).

## Contract source of truth

- Canonical roadmap schema: `skills/dt-roadmap/references/roadmap-schema.md`.
- Canonical validator: `skills/dt-roadmap/scripts/roadmap-validator.ps1`.
- `dt-build` must read both through repo-relative paths; no copied schema is allowed.

## Procedure (7A intake + 7B execution)

1. Intake in one question:
- Repo path (absolute).
- Roadmap path (default: `<project>/design/roadmap.md`).
- Optional RUN_ID for resume check.
- Optional merge target (default `dev`).

2. Validate roadmap contract before any build setup:
- Run `skills/dt-roadmap/scripts/roadmap-validator.ps1 -RoadmapPath <roadmap> -SchemaPath <repo>/skills/dt-roadmap/references/roadmap-schema.md`.
- Fail closed on validator error.

3. Enforce legacy hard-cutover (Contract Freeze Gate):
- If a resume RUN_ID points to a pre-refactor `.dt-build/<RUN_ID>/` folder, reject intake.
- Pre-refactor is detected when run artifacts do not carry the intake marker (`intake_contract: roadmap-v1` in build-plan).
- Error must explicitly cite the Contract Freeze Gate decision: legacy pre-refactor run folders are historical-only and cannot be resumed by refactored dt-build.

4. Produce deterministic intake scaffolding:
- `build-state.md` via `scripts/write-build-state.ps1` (atomic full-file rewrite).
- `build-decision-log.md` scaffold.
- `build-plan.md` scaffold (roadmap-driven intake contract).
- Reference-pack files + `reference-manifest.md` via `scripts/build-reference-pack.ps1`.

5. Spawn preflight contract check:
- Resolve each chunk entitlement through `scripts/spawn-preflight.ps1`.
- Abort if any manifest mismatch or missing entitlement.

6. Execute milestones with deterministic execution-side procedures:
- Assemble Codex prompt bytes through `scripts/assemble-codex-prompt.ps1` (single canonical implementation; envelope boundary via repo-level `scripts/wrap-prompt-envelope.ps1`).
- Run the four-check prompt verify gate through `scripts/verify-codex-prompt.ps1` before every Codex invocation.
- Run verify/fix loops with a hard two-attempt budget per milestone; if still failing, escalate instead of spinning.
- Update `dev` only via compare-and-swap through `scripts/dev-cas-update.ps1` after rehearsal checks pass.

7. Guardrails:
- Branch drift detection via `scripts/check-drift.ps1`.
- Worktree containment hard-block via `scripts/check-worktree-containment.ps1`.
- Subagent prompt envelope boundaries are mandatory via repo-level `scripts/wrap-prompt-envelope.ps1`.
- Run-log writes route through repo-level `scripts/security/redact-secrets.ps1`.

## Required verification

- Real small build against an actual roadmap (`roadmap.md`) that exercises:
  - milestone-commit behavior
  - dev compare-and-swap flow
  - verify/fix loop budget behavior
- Execution parity check:
  - same milestone-commit outcome class as pre-refactor dt-build behavior
  - artifact integrity checks still pass
  - no regression to verify/fix budget policy

## References

- Subagent prompts: `references/subagent-prompts.md`
- Artifact integrity contract: `references/artifact-integrity.md`
- Run-artifact lifecycle: `references/run-artifact-lifecycle.md`
- Shared-input routing: `references/shared-input-routing.md`
- Resilience/security: `references/resilience-security.md`
- Branch contract: `references/branch-contract.md`
- Codex assembly byte contract: `references/codex-assembly-contract.md`
