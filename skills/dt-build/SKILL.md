---
name: dt-build
description: "Execute a validated roadmap contract end-to-end. Trigger on /dt-build or 'dt-build [roadmap-path]'."
disable-model-invocation: true
user-invocable: true
allowed-tools: "Bash(git:*) Bash(codex:*) Bash(pwsh:*) Read Write Edit Agent AskUserQuestion ScheduleWakeup"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 2.3.1
  changelog: "Acceptance gate fixes: (1) verify-milestone-acceptance.ps1 now transforms `pytest ...` to `python -m pytest ...` before subprocess invocation so `pwsh -NoProfile` (which strips the user's venv Scripts/ from PATH) finds the test runner — fixes false-BLOCKED on milestones whose verification check uses the roadmap's `pytest` convention. (2) build-acceptance-ledger.ps1 now reads `downgrade_approved_by: <upn>` markers from the run folder's build-decision-log.md per milestone; BLOCKED rows with an approval flip to a new `APPROVED_DOWNGRADE` status and surface the rationale + originally-blocked items as Notes annotations. Wires the approval mechanism the acceptance-contract.md already documented. APPROVED_DOWNGRADE is its own status (not PASS) so the audit trail stays visible. Previous 2.3.0 acceptance contract gate: Adds references/acceptance-contract.md (the contract) and four deterministic scripts: verify-milestone-acceptance.ps1 (artifact presence + named-command exit-code check), check-downgrade-language.ps1 (banned-phrase scanner with approval-block override), identify-load-bearing.ps1 (triggers load-bearing-first ordering within a DAG layer), build-acceptance-ledger.ps1 (final four-axis ledger as md+html). Closes the failure class surfaced by the 2026-05-27 file-sorter learning-loop build, where a build was reported complete while load-bearing E2E coverage, the human-edit ingestion hook, the real ONNX embedding model, and the proposal state-machine guards were all missing or substituted with placeholders that nominally satisfied a thinner test."
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

## Acceptance contract (per-milestone verify-before-complete)

**Read `references/acceptance-contract.md` before step 6 fires for the first time.** That reference is the binding contract for what counts as a milestone being "done." It replaces the prior "verify at the end" pattern with per-milestone artifact-presence + named-command + downgrade-language gates, enforced by four deterministic scripts:

- `scripts/verify-milestone-acceptance.ps1` — extracts artifacts the roadmap names for a milestone and confirms each exists in the working tree; with `-RunTests`, runs every named pytest/python command and folds exit codes into the verdict.
- `scripts/check-downgrade-language.ps1` — scans milestone notes, commit messages, and per-chunk output for the calibrated phrase list ("compatible fallback," "deterministic fallback," "production can replace," "scaffold implementation," "verifier passes" paired with artifact-missing context, etc.). Approval blocks (`downgrade_approved_by: danny`) suppress matches inside their range.
- `scripts/identify-load-bearing.ps1` — flags milestones whose name/acceptance/verification text contains `load-bearing`, `gate`, `publish`, `persistence`, `runtime flip`, `end-to-end`, `E2E`, or `critical path`. The build orders these first within their DAG layer.
- `scripts/build-acceptance-ledger.ps1` — aggregates per-milestone results into the final ledger as both `.md` and `.html`. The ledger is the build's final answer.

A milestone in any non-PASS state blocks every dependent milestone from starting, regardless of the verify/fix loop budget.

## Procedure (7A intake + 7B execution + 7C acceptance gate)

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

5.5 Identify load-bearing milestones:
- Run `scripts/identify-load-bearing.ps1 -RoadmapPath <roadmap> -Json`.
- Persist the result in the run folder (`load-bearing.json`).
- Build execution in step 6 uses this set to reorder within each DAG layer: when multiple milestones become unblocked simultaneously, the load-bearing one is built first and its `accepted` status must be `PASS` before any dependent non-load-bearing milestone's chunk is assembled.

6. Execute milestones with deterministic execution-side procedures, **per-milestone in this order**:
- a. **Quote the verification check.** Restate the `chk-mNN` procedure text and the milestone's acceptance-checks text verbatim in the milestone's `build-decision-log` entry before any code is written.
- b. **Assemble and verify the Codex prompt.** `scripts/assemble-codex-prompt.ps1` (single canonical implementation; envelope boundary via repo-level `scripts/wrap-prompt-envelope.ps1`), then the four-check prompt verify gate through `scripts/verify-codex-prompt.ps1` before every Codex invocation.
- c. **Run the chunk** under the hard two-attempt verify/fix budget. If still failing, escalate and STOP advancing to dependent milestones.
- d. **Run the acceptance gate.** `scripts/verify-milestone-acceptance.ps1 -RoadmapPath <r> -MilestoneId <mid> -WorkingTree <wt> -RunTests -Json` — must return PASS. On BLOCKED, the milestone does not count as complete and dependent milestones do not start.
- e. **Run the downgrade-language scan.** `scripts/check-downgrade-language.ps1 -Path <run-folder>/milestones/<mid> -Recurse -Json` — must return exit 0. Any unapproved match is a blocker unless Danny adds `downgrade_approved_by: danny` with a short rationale to the milestone's `build-decision-log` entry.
- f. **Append the acceptance row** to `<run-folder>/acceptance-rows.jsonl`.
- g. **Update `dev`** via compare-and-swap through `scripts/dev-cas-update.ps1` after the per-milestone acceptance gate passes.

6.5 Emit acceptance ledger + review artifact:
- Run `scripts/build-acceptance-ledger.ps1 -RoadmapPath <r> -WorkingTree <wt> -OutDir <run-folder> -RunFolder <run-folder> -RunTests`.
  - Emits `build-acceptance-ledger.md` and `build-acceptance-ledger.html`.
  - The ledger is the final answer for the build run — not a freeform summary.
- Generate `build-run-review.html` in the run artifact folder with:
  - the acceptance ledger as the headline panel (above the milestone status cards),
  - milestone status cards,
  - execution timeline,
  - verify/fix loop outcomes,
  - blockers/escalations panel,
  - downgrade-language matches panel (per-milestone, with approved/blocker badge).

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

- **Acceptance contract (per-milestone verify-before-complete):** `references/acceptance-contract.md` — binding contract for what counts as "milestone complete."
- Subagent prompts: `references/subagent-prompts.md`
- Artifact integrity contract: `references/artifact-integrity.md`
- Run-artifact lifecycle: `references/run-artifact-lifecycle.md`
- Shared-input routing: `references/shared-input-routing.md`
- Resilience/security: `references/resilience-security.md`
- Branch contract: `references/branch-contract.md`
- Codex assembly byte contract: `references/codex-assembly-contract.md`
- Skill propagation gate (one-shot / build-final): repo-level `scripts/verify-skill-junctions.ps1`
- Acceptance gate scripts (called by procedure step 6):
  - `scripts/verify-milestone-acceptance.ps1` — per-milestone artifact + command check
  - `scripts/check-downgrade-language.ps1` — banned-phrase scanner
  - `scripts/identify-load-bearing.ps1` — load-bearing-first ordering input
  - `scripts/build-acceptance-ledger.ps1` — final four-axis ledger (.md + .html)
