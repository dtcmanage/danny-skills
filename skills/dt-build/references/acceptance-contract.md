# Acceptance Contract

Hard verification gate for every milestone dt-build executes. Replaces the prior "verify at the end" pattern with per-milestone verify-before-complete. Closes the failure class surfaced by the 2026-05-27 file-sorter learning-loop build, where a build was reported complete while load-bearing E2E coverage, the human-edit ingestion hook, the real ONNX embedding model, and the proposal state-machine guards were all missing or substituted with placeholders that nominally satisfied a thinner test.

## Per-milestone protocol

For each milestone in the roadmap, in DAG order with load-bearing milestones first within a layer:

1. **Quote every verification check for the milestone.** Before writing any code, read **every** `CHK-MNN-*` row from the roadmap's `## Verification Manifest` section whose `milestone-id` matches the current milestone, and restate each procedure text verbatim in the milestone's `build-decision-log` entry. A milestone with three checks gets three quoted procedure blocks; the gate evaluates all of them.
2. **Quote the acceptance checks** for the same `mNN` from the `## Milestones` table.
3. **Build the chunk.** Per the existing build steps (assemble Codex prompt → verify → run).
4. **Run every verification check** named in step 1.
   - If a check names a test file path, the file must exist in the working tree.
   - If a check names a `pytest` command, that exact command must run and exit 0.
   - If a check names a script, that script must run and produce its named output artifact.
   - Every check must pass on its own merits. A milestone with three checks where two pass and one fails is `BLOCKED`, not `PASS`.
5. **Run the deterministic gates** (in this order):
   - `scripts/verify-milestone-acceptance.ps1` — pools **every** verification-manifest row whose `milestone-id` matches the requested milestone, confirms every artifact named across all of those checks exists in the working tree, and (with `-RunTests`) runs every named test command and folds every exit code into the verdict. JSON output exposes a `verification_checks` array with per-check `check_id`, `procedure_text`, `artifacts_named`, `artifacts_missing`, `commands_named`, `command_results`, and `blockers`; top-level `status` is the rolled-up view and is `PASS` only when every check's blockers are empty.
   - `scripts/check-downgrade-language.ps1` — scans the milestone's commit message, build-decision-log entry, and any per-chunk Codex output for banned phrases (see below).
6. **Mark the milestone status** using the four-axis split:
   - `implemented` — code changed for this milestone's chunks (chunk files touched between merge-base and HEAD).
   - `tested` — the verification command ran and exited 0.
   - `accepted` — every named artifact exists, every named command passed, no downgrade phrase fired.
   - `status` — `PASS` only when all three are true; otherwise `BLOCKED` with a list of named blockers.

**A milestone in any non-PASS state blocks every dependent milestone from starting**, regardless of the verify/fix loop budget. The two-attempt budget per milestone still governs how many times a chunk can be rebuilt; once the budget is exhausted in `BLOCKED` state, the milestone is escalated and dependent milestones do not start.

## Final ledger (replaces the build summary)

Every dt-build run produces a milestone acceptance ledger as both `.md` and `.html` artifacts (`build-acceptance-ledger.{md,html}` in the run folder), one row per milestone, with the four-axis split above plus a blockers column. The ledger is the final answer. A build that ships a freeform summary instead of a ledger has not honored this contract.

## Downgrade language ban

The following phrases trigger an automatic `BLOCKED` status when found in milestone notes, commit messages, build review files, or per-chunk Codex output (case-insensitive substring match, run by `scripts/check-downgrade-language.ps1`):

- `compatible fallback`
- `deterministic fallback`
- `hash fallback`
- `production can replace`
- `verifier passes` (when paired with any artifact-missing language)
- `contract stable`
- `scaffold implementation`
- `thinner test`
- `consolidated test` (when used to justify fewer files than the roadmap names)
- `placeholder until`
- `mocked acceptance`
- `happy path only`
- `for now` co-occurring with `later` in the same paragraph
- `partial verifier`
- `compatible with deterministic`

These phrases were calibrated against the file-sorter learning-loop post-mortem; they are the verbal signatures of "I substituted something thinner without flagging it as a downgrade." False positives are acceptable — Danny can override per-milestone by adding `downgrade_approved_by: <upn>` with a short rationale to the milestone's `build-decision-log` entry. The ledger surfaces approved downgrades as annotations rather than blockers.

## Downgrade approval (and spec-relaxation approval)

When a milestone is genuinely BLOCKED but the blocker is a spec the operator chooses to relax — a latency threshold that's tight for the target box, a stress-test concurrency level that's environment-bound, etc. — Danny can approve the downgrade without faking the implementation.

**Mechanism (wired in `scripts/build-acceptance-ledger.ps1`):**

1. In the run folder's `build-decision-log.md`, find the milestone's `## M<NN>` section.
2. On a line of its own, add:
   ```
   downgrade_approved_by: danny
   rationale: <one-line plain-language explanation>
   ```
3. Re-run `scripts/build-acceptance-ledger.ps1`. The ledger flips that milestone's status from `BLOCKED` to `APPROVED_DOWNGRADE` and surfaces the original blockers as annotations in the Notes column alongside the approver and rationale.

**`APPROVED_DOWNGRADE` is not `PASS`.** It is a third status that says "the gate caught a genuine spec violation and the operator owns the exception in writing." The build summary breaks it out separately so it stays visible in audit. A build with all milestones at `PASS` is the clean outcome; a build with one `APPROVED_DOWNGRADE` row is shipped-with-receipts. A build with even one `BLOCKED` row is not shipped.

If the downgrade has knock-on effects on a dependent milestone, the dependent milestone runs on its own merits — the approval does not cascade. Each milestone's status is computed independently against its own verification check.

## Load-bearing E2E ordering

Milestones flagged by `scripts/identify-load-bearing.ps1` get their verification tests written and run **before** any non-load-bearing milestone that depends on them is marked complete. Criteria the script uses (case-insensitive substring match on the milestone's name, acceptance-checks text, and verification-check procedure text):

- `load-bearing` / `load bearing`
- `gate` (as standalone word)
- `publish` (as verb in the procedure)
- `persistence` / `persists`
- `runtime flip`
- `end-to-end` / `E2E` / `e2e`
- `critical path`

The DAG still governs build order; this rule applies **within a DAG layer**: when multiple milestones become unblocked at the same time, the load-bearing one is built first. Its `accepted` status must be `YES` before any dependent non-load-bearing milestone's chunk is assembled.

## Test-count parity

The roadmap's Verification Manifest names test files explicitly (e.g., `pytest tests/backend/test_external_text_contract.py`). Before the build is marked complete, every named test file across **every** verification-manifest row for the milestone must exist in the working tree. The gate evaluates each CHK-* row independently — a milestone with three named checks gets three independent presence + command-exit checks, and the milestone is `PASS` only when all three are clean. The ledger surfaces missing files per milestone via the rolled-up `artifacts_missing` column and exposes the per-check breakdown (which check each missing artifact belongs to) in the HTML ledger's Verification Check Detail section.

**Calibration event (2026-05-27 db-durability build at file-sorter):** before v2.4.0, the gate took `Select-Object -First 1` against the verification rows for a milestone and silently skipped every check after the first. The M02 acceptance row reported PASS by running only `CHK-M02-POPULATED-UPGRADE`; `CHK-M02-ROLLBACK` and `CHK-M02-STALE-V11-REGRESSION` were ignored despite being load-bearing in the roadmap. v2.4.0 pools every matching row and runs all named commands.

If the build consolidated multiple named test files into one combined file (and that combined file's pytest run passes), the ledger row's `accepted` column is `YES` only when Danny has approved the consolidation in writing in the build-decision-log (`consolidation_approved_by: danny` with a short rationale); otherwise the milestone is `BLOCKED` with `consolidation_not_approved` as the blocker.

## Sequencing inside SKILL.md step 6

dt-build's "Execute milestones" step calls the deterministic gates in this order, per milestone:

1. Quote acceptance check from roadmap (manual restatement in build-decision-log).
2. Assemble + verify + run the Codex prompt (existing build chain).
3. `scripts/verify-milestone-acceptance.ps1 -RoadmapPath <r> -MilestoneId mNN -WorkingTree <wt> -RunTests` → must return `PASS`. On `BLOCKED`, escalate within the two-attempt budget.
4. `scripts/check-downgrade-language.ps1 -Path <milestone-notes-dir> -Json` → must return exit 0. Any nonzero exit is a blocker unless explicitly approved.
5. Append milestone row to the ledger (`scripts/build-acceptance-ledger.ps1` is a one-shot wrapper at run end, but per-milestone the rows are accumulated in `acceptance-rows.jsonl`).
6. Rewrite the pipeline checkpoint `_build-state.md` in the project's planning folder (SKILL.md step 6.h; canonical shape: `skills/dt-pipeline/templates/build-state-template.md`).
7. Move to next milestone (DAG order, load-bearing first within a layer).

When the build completes (or stops at the verify/fix budget cap), `scripts/build-acceptance-ledger.ps1` produces the final ledger. `build-run-review.html` is generated only when Danny explicitly asks (SKILL.md step 6.5); when built, it surfaces the ledger as the headline panel above the milestone status cards.

## What this gate does not prevent

- A roadmap whose verification checks are themselves too lax (the gate enforces what the roadmap says, not what a thorough roadmap would say). The dt-roadmap skill owns acceptance-check quality.
- A test file that exists but tests the wrong thing (the gate enforces presence + green exit, not semantic coverage). Adversarial review (dt-review) before dt-build, and human read of the ledger, catch this.
- A milestone genuinely outside the build scope flagged as missing because the roadmap didn't say so (the gate is contract-bound; if the roadmap didn't name an artifact, the gate doesn't ask for it).

The contract is: **whatever the roadmap explicitly names, the build must explicitly produce and verify.**
