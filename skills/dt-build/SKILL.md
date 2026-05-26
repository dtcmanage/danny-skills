---
name: dt-build
description: "Execute a validated roadmap contract end-to-end. Trigger on /dt-build or 'dt-build [roadmap-path]'."
disable-model-invocation: true
user-invocable: true
allowed-tools: "Bash(git:*) Bash(codex:*) Bash(pwsh:*) Read Write Edit Agent AskUserQuestion ScheduleWakeup"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 2.2.0
  changelog: "Skill propagation gate: when the built repo is the danny-skills plugin repo, diff skills/ between merge base and build branch, materialize per-skill directory junctions in the four external surfaces via scripts/verify-skill-junctions.ps1 -Create, and hard-fail the build on any junction failure, wrong target, setup gap, or orphan. Closes the recurring CLI/Codex invisible-new-skill gap."
---

# Build Executor

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).

If this skill has stricter domain-specific behavior, keep that stricter behavior; otherwise follow the shared baseline.

## HTML Review Artifact Requirement

For any artifact this skill produces for Danny to review, generate an HTML companion per `../../references/html-artifact-policy.md`.

Baseline requirement:
- Keep the primary machine/edit artifact (for example `.md`, `.json`, `.csv`) when needed.
- Also emit a review-first `.html` artifact in the same artifact family/folder.
- Include visual structure (cards/tables) plus at least one flow/state visualization (Mermaid or SVG).
- Report both output paths in the final skill output.



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

6.5 Emit review artifact:
- Generate `build-run-review.html` in the run artifact folder with:
  - milestone status cards,
  - execution timeline,
  - verify/fix loop outcomes,
  - blockers/escalations panel.

7. Guardrails:
- Branch drift detection via `scripts/check-drift.ps1`.
- Worktree containment hard-block via `scripts/check-worktree-containment.ps1`.
- Subagent prompt envelope boundaries are mandatory via repo-level `scripts/wrap-prompt-envelope.ps1`.
- Run-log writes route through repo-level `scripts/security/redact-secrets.ps1`.

8. Skill propagation gate (danny-skills builds only):
- Fires only when the built repo is the `danny-skills` plugin repo. Detect by reading `<repo>/.claude-plugin/plugin.json` and confirming `name == "danny-skills"` and a top-level `skills/` directory exists. Skip the gate otherwise.
- Detect new skill folders added by this build run:
  - Resolve the merge base: `git merge-base <merge_target> <build_branch>`.
  - List added skill folders: `git diff --name-only --diff-filter=A -M <merge_base> <build_branch> -- skills/`, then keep paths matching `^skills/[^/]+/` and reduce to unique top-level skill names.
  - A folder rename (old removed, new added) surfaces as a new skill on the new side and an orphan in the propagation report; the build does not auto-clean the orphan.
  - Do NOT fire for SKILL.md-only or content-only edits where the skill folder name is unchanged.
- For each new skill name, invoke the repo-level propagator:
  `pwsh -NoProfile -File <repo>/scripts/verify-skill-junctions.ps1 -RepoRoot <repo> -NewSkills <names...> -Create -Json`
  Targets reconciled by the script: `$CODEX_HOME\skills`, `~\.agents\skills`, `D:\Claude\skills`, `_Claude-Workspace\.claude\skills`. Cowork is auto-propagated by its whole-folder junction and is not touched here.
- Hard fail the build (block dev compare-and-swap; mark the run failed) when any of these surface in the script output:
  - any row with status `missing`, `wrong_target`, `create_failed`, or `collision_not_junction`,
  - any entry in `setup_gaps` (a target parent directory does not exist; never auto-create it),
  - any entry in `orphans` introduced by this run.
- Append the full propagation JSON to the build-final summary and surface a "Skill Propagation" panel in `build-run-review.html` listing per-(skill, location) status, any setup gaps, and any orphans.
- The same script is callable ad-hoc for retroactive sweeps with no `-NewSkills` (scans all skills in the repo) and without `-Create` (report-only).

## Required verification

- Real small build against an actual roadmap (`roadmap.md`) that exercises:
  - milestone-commit behavior
  - dev compare-and-swap flow
  - verify/fix loop budget behavior
- Execution parity check:
  - same milestone-commit outcome class as pre-refactor dt-build behavior
  - artifact integrity checks still pass
  - no regression to verify/fix budget policy
- Report bare absolute paths for primary run artifacts and `build-run-review.html`.

## References

- Subagent prompts: `references/subagent-prompts.md`
- Artifact integrity contract: `references/artifact-integrity.md`
- Run-artifact lifecycle: `references/run-artifact-lifecycle.md`
- Shared-input routing: `references/shared-input-routing.md`
- Resilience/security: `references/resilience-security.md`
- Branch contract: `references/branch-contract.md`
- Codex assembly byte contract: `references/codex-assembly-contract.md`
- Skill propagation gate (one-shot / build-final): repo-level `scripts/verify-skill-junctions.ps1`
