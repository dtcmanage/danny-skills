---
name: dt-build
description: "Execute a finalized build end-to-end. Trigger on /dt-build or 'dt-build [roadmap-or-design-path]'. Prefers a dt-roadmap roadmap.md for heavier builds but accepts a design-final.md directly and auto-generates the roadmap; a missing roadmap is never required or a crash."
disable-model-invocation: true
user-invocable: true
allowed-tools: "Bash(git:*) Bash(codex:*) Bash(pwsh:*) Read Write Edit Agent AskUserQuestion ScheduleWakeup"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 2.6.0
  changelog: "2.6.0 roadmap-preferred-not-required intake: dt-build now accepts a finalized design (design-final.md / plan-draft.md) as input, not only a dt-roadmap roadmap.md. New procedure steps 2 (detect roadmap vs design), 2.5 (auto-generate the roadmap from a design via the canonical skills/dt-roadmap/scripts/build-roadmap.ps1 — no re-implemented milestone parsing, no schema duplication), and 2.6 (validate, formerly step 2). A roadmap is preferred for heavier builds (many milestones or any load-bearing/gate milestone, which dt-build now recommends a reviewed dt-roadmap pass for) but is never a hard requirement; when a design lacks an Implementation Sequence / Validation Gates surface the build STOPS with the producer's graceful explanatory message instead of crashing. 'When this fires' and references/shared-input-routing.md updated to document design-or-roadmap intake. Prior 2.5.0 trunk-based-branch-model: integration target moved off the retired dev branch to a short-lived build/<RUN_ID> branch cut from main (2026-05-28 workspace-wide trunk migration); per-milestone accepted work compare-and-swaps onto build/<RUN_ID>, and the rehearsed branch is left for a separate human-authorized /git-merge-feature to main (dt-build never writes to main). scripts/dev-cas-update.ps1 renamed to scripts/branch-cas-update.ps1 and generalized (mandatory -TargetBranch/-ExpectedTargetSha; output keys target_branch/expected_target_sha/observed_target_sha; CAS_* error prefixes). branch-contract.md, resilience-security.md, and subagent-prompts.md updated. Prior 2.4.0 behavior retained: Per-milestone acceptance gate now evaluates EVERY verification-manifest row for a milestone, not just the first. Prior implementation (verify-milestone-acceptance.ps1) used `Select-Object -First 1` against the rows matched by milestone-id, so any milestone with multiple CHK-* checks had partial gate coverage — only the first check's procedure was parsed for artifacts/commands and only its named test command was run. Calibration event: 2026-05-27 db-durability build at file-sorter, where M02 reported PASS by running only CHK-M02-POPULATED-UPGRADE while CHK-M02-ROLLBACK and CHK-M02-STALE-V11-REGRESSION were silently skipped despite being load-bearing in the roadmap. v2.4.0 changes: (1) verify-milestone-acceptance.ps1 pools every matching verification row, extracts artifacts and commands per row, presence-checks each row's artifacts against the working tree, runs each row's named commands under -RunTests, and folds every exit code into the verdict. JSON output adds a `verification_checks` array (each element exposes check_id, procedure_text, artifacts_named/present/missing, commands_named, command_results, test_status, blockers) alongside the existing top-level fields (status/accepted/blockers/artifacts_missing/commands_named/command_results) which remain the rolled-up view consumed by build-acceptance-ledger.ps1. status is PASS only when every check's blockers are empty. (2) build-acceptance-ledger.ps1 surfaces the per-check breakdown in the HTML ledger as a Verification Check Detail section — one sub-table per milestone listing each CHK-* id, status badge, named artifacts (with missing markers), and named commands with exit codes. Markdown ledger remains the roll-up. (3) acceptance-contract.md updated to document that the gate evaluates every verification row per milestone — the contract previously read as if every check was enforced; v2.4.0 makes the implementation match. Previous 2.3.1 acceptance gate fixes (pytest -> python -m pytest, downgrade_approved_by parser + APPROVED_DOWNGRADE status) are retained unchanged."
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



`dt-build` consumes a finalized `roadmap.md` contract and executes milestones on a short-lived `build/<RUN_ID>` branch cut from `main`, leaving it rehearsed and tested for a separate human-authorized merge to `main`.
Phase 7A established deterministic roadmap-first intake. Phase 7B restores execution parity through deterministic execution-side scripts.

## When this fires

Trigger when all are true:
- Input artifact is **either** a `roadmap.md` produced by `dt-roadmap` **or** a finalized design
  (`design-final.md`, or `plan-draft.md` when review was skipped). A roadmap is *preferred* for heavier
  builds (many milestones, load-bearing/gate milestones, anything you want a reviewed contract for);
  it is **not** a hard requirement. When handed a design, dt-build auto-generates the roadmap itself
  (step 2.5) — a missing roadmap is never a crash or a refusal.
- Repository is a git repo.
- Danny is asking to run the build stage, not planning/review.

Do NOT fire for:
- Plan authoring or redesign (`dt-plan`, `dt-review`).
- Standalone roadmap production for review (`dt-roadmap`) — that skill is still the way to produce a
  curated, separately-reviewed contract. dt-build's auto-generation (step 2.5) is the convenience path
  for lighter builds, not a replacement for a deliberate dt-roadmap pass on heavy work.

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
- Input path — a `roadmap.md` **or** a finalized design (`design-final.md` / `plan-draft.md`).
  Default: `<project>/design/roadmap.md`, falling back to `<project>/design/design-final.md`.
- Optional RUN_ID for resume check.
- Optional integration branch (default `build/<RUN_ID>`, cut from `main`).

2. Resolve the input to a roadmap contract:
- If the input file already parses as a roadmap (frontmatter `schema_version` + a `## Milestones`
  section), treat it as the roadmap directly.
- Otherwise treat it as a design artifact and go to step 2.5 to generate one.

2.5 Auto-generate a roadmap from a design (only when step 2 found a design, not a roadmap):
- Run `skills/dt-roadmap/scripts/build-roadmap.ps1 -DesignPath <design> -RoadmapPath <project>/design/roadmap.md`,
  then proceed with that roadmap. This reuses the canonical dt-roadmap producer — dt-build does not
  re-implement milestone parsing or duplicate the schema.
- If the producer emits a `## Producer Warnings` section or throws "No milestones derivable", surface
  it and STOP: the design lacks an `## Implementation Sequence` / `## Validation Gates` surface with
  runnable commands. This is a graceful, explanatory stop — not a crash — and tells the author exactly
  what the design must add (or to run a deliberate `dt-roadmap` pass first).
- For a heavy build (the generated roadmap has many milestones or any load-bearing/gate milestone per
  `scripts/identify-load-bearing.ps1`), recommend in chat that Danny run a reviewed `dt-roadmap` pass
  before proceeding — then continue if he wants the auto-generated contract.

2.6 Validate the roadmap contract before any build setup:
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
- g. **Update the integration branch** (`build/<RUN_ID>`) via compare-and-swap through `scripts/branch-cas-update.ps1` after the per-milestone acceptance gate passes. dt-build never writes to `main`; the final merge of the rehearsed branch to `main` is a separate human-authorized `/git-merge-feature` step.

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
- Hard fail the build (block the integration-branch compare-and-swap; mark the run failed) when any of these surface in the script output:
  - any row with status `missing`, `wrong_target`, `create_failed`, or `collision_not_junction`,
  - any entry in `setup_gaps` (a target parent directory does not exist; never auto-create it),
  - any entry in `orphans` introduced by this run.
- Append the full propagation JSON to the build-final summary and surface a "Skill Propagation" panel in `build-run-review.html` listing per-(skill, location) status, any setup gaps, and any orphans.
- The same script is callable ad-hoc for retroactive sweeps with no `-NewSkills` (scans all skills in the repo) and without `-Create` (report-only).

## Required verification

- Real small build against an actual roadmap (`roadmap.md`) that exercises:
  - milestone-commit behavior
  - integration-branch compare-and-swap flow
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
