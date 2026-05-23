---
name: dt-build
description: "Execute a validated roadmap contract end-to-end. Trigger on /dt-build or 'dt-build <roadmap-path>'."
disable-model-invocation: true
user-invocable: true
allowed-tools: "Bash(git:*) Bash(codex:*) Bash(pwsh:*) Read Write Edit Agent AskUserQuestion ScheduleWakeup"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 2.0.0
  changelog: "Phase 7A intake-parity refactor: roadmap-first intake, canonical dt-roadmap contract validation, and legacy run hard-cutover behavior."
---

# Build Executor

`dt-build` consumes a finalized `roadmap.md` contract and executes milestones on `dev`.
This Phase-7A scope is intake-parity only: deterministic intake scaffolding and contract validation.
Execution-parity behavior is Phase 7B and is intentionally not implemented here.

## When this fires

Trigger when all are true:
- Input artifact is `roadmap.md` produced by `dt-roadmap`.
- Repository is a git repo.
- Danny is asking to run the build stage, not planning/review.

Do NOT fire for:
- Plan authoring or redesign (`dt-plan`, `dt-review`).
- Roadmap production (`dt-roadmap`).
- Any Phase-7B execution-parity changes.

## Contract source of truth

- Canonical roadmap schema: `skills/dt-roadmap/references/roadmap-schema.md`.
- Canonical validator: `skills/dt-roadmap/scripts/roadmap-validator.ps1`.
- `dt-build` must read both through repo-relative paths; no copied schema is allowed.

## Procedure (Phase 7A)

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
- Pre-refactor is detected when run artifacts do not carry the new intake marker (`intake_contract: roadmap-v1` in build-plan).
- Error must explicitly cite the Contract Freeze Gate decision:
  legacy pre-refactor run folders are historical-only and cannot be resumed by refactored dt-build.

4. Produce deterministic intake scaffolding:
- `build-state.md` via `scripts/write-build-state.ps1` (atomic full-file rewrite).
- `build-decision-log.md` scaffold.
- `build-plan.md` scaffold (roadmap-driven intake contract).
- reference-pack files + `reference-manifest.md` via `scripts/build-reference-pack.ps1`.

5. Spawn preflight contract check:
- Resolve each chunk entitlement through `scripts/spawn-preflight.ps1`.
- Abort if any manifest mismatch or missing entitlement.

6. Guardrails:
- Branch drift check only (`scripts/check-drift.ps1`); no execution-loop changes in 7A.
- Worktree containment hard-block (`scripts/check-worktree-containment.ps1`).
- Run-log writes route through repo-level `scripts/security/redact-secrets.ps1`.

## Deterministic intake verification (7A exit gate)

- Use a frozen sample roadmap.
- Run intake dry-run twice.
- Require byte-identical outputs for:
  - `build-state.md`
  - `build-decision-log.md`
  - `build-plan.md`
- Run negative-path checks for roadmap contract failures:
  - dependency cycle
  - missing required column
  - `schema_version` major mismatch

Phase 7B must not start until these checks pass.

## References

- Subagent prompts: `references/subagent-prompts.md`
- Artifact integrity contract: `references/artifact-integrity.md`
- Run-artifact lifecycle: `references/run-artifact-lifecycle.md`
- Shared-input routing: `references/shared-input-routing.md`
- Resilience/security: `references/resilience-security.md`
- Branch contract: `references/branch-contract.md`
- Codex assembly byte contract: `references/codex-assembly-contract.md`
