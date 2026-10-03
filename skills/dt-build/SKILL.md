---
name: dt-build
description: "Execute a finalized build end-to-end. Trigger on /dt-build or 'dt-build [roadmap-or-design-path]'. Prefers a dt-roadmap roadmap.md for heavier builds but accepts a finalized design directly (design-final-<slug>.md, legacy design-final.md) and auto-generates the roadmap; a missing roadmap is never required or a crash."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash(git:*) Bash(codex:*) Bash(pwsh:*) Read Write Edit Agent AskUserQuestion"
compatibility: "Cowork, Claude Code CLI, or Codex CLI (Codex is the most-used orchestrator in practice; its stage-2 hardening is not built); requires danny-skills repo present."
metadata:
  version: 2.19.3
  changelog: "Changelog moved to CHANGELOG.md (this skill folder); historical entries live there verbatim, newest first."
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

Exception — `build-run-review.html` is on-request only; see step 6.5 for the binding policy.



`dt-build` consumes a finalized `roadmap.md` contract and executes milestones on a short-lived `build/<RUN_ID>` branch cut from `main`, leaving it rehearsed and tested for a separate human-authorized merge to `main`.
Phase 7A established deterministic roadmap-first intake. Phase 7B restores execution parity through deterministic execution-side scripts.

## When this fires

Trigger when all are true:
- Input artifact is **either** a `roadmap.md` produced by `dt-roadmap` **or** a finalized design
  (`design-final-<slug>.md` — dt-review's current naming, slug describing what is being built — or the
  legacy `design-final.md`; accept anything matching `design-final-*.md` or `design-final.md`. Also
  `plan-draft.md` when review was skipped). A roadmap is *preferred* for heavier
  builds (many milestones, load-bearing/gate milestones, anything you want a reviewed contract for);
  it is **not** a hard requirement. When handed a design, dt-build auto-generates the roadmap itself
  (step 2.5) — a missing roadmap is never a crash or a refusal.
- Repository is a git repo.
- Danny is asking to run the build stage, not planning/review.

Invocation syntax: `/dt-build` on Claude surfaces (Claude Code CLI, Cowork); `$dt-build` from Codex.

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

## Model routing

Routing lives in the shared model router: `scripts/model-router/resolve-model.ps1`, operator reference `references/model-router/README.md`, session rules `00_Resources\model-routing.md`. dt-build adds only these rules.

- **One category per chunk,** recorded in `build-plan.md` at roadmap time. Load-bearing (`scripts/identify-load-bearing.ps1`), security-sensitive, and live-write chunks run `complex-coding` with `-Protected` (a load-bearing UI chunk runs `ui-frontend` protected); other implementation runs `routine-coding`; preflights, boilerplate, and mechanical edits run `mechanical`; verifiers and the final review run `code-review`, protected only for a load-bearing milestone. Protected must be earned: the selection reason names the flag, the boundary, or the live write.
- **Resolve without `-Lane`:** `pwsh -NoProfile -File scripts/model-router/resolve-model.ps1 -Category <c> -SendAlerts -Json` (plus `-Protected` when earned). The roster decides vendor, model, and effort. Frontier models run only on Danny's explicit request through `-Model` with a recorded reason.
- **Dispatch on the returned vendor** through the wrapper matching its returned `vendor` (`scripts/invoke-codex-chunk.ps1` or `scripts/invoke-claude-chunk.ps1`) with `-Category`, `-Protected` when earned, `-Effort <returned effort>`, and `-SelectionReason`; add `-ReadOnly` on the Claude wrapper for verifiers and reviews. On claude-host a Claude pick at the session's own effort may use a host-native Agent with the returned `agent_alias`; any other effort goes through the wrapper so `--effort` is pinned. Never hand-roll `codex exec` or `claude -p`, and never inherit the session model. Relay `ROUTER_ALERT:` once.
- **Print the line** before every substantive dispatch (build, continuation, retry, remediation, verifier, final review), one per parallel dispatch, preflights exempt: `MODEL_SELECTION: <dispatch_id> -> <resolved_model> (<category>[, protected][, escalated from <model>], effort <effort>): <one-sentence selection reason>; router: <router reason>`. The reason justifies category and protection. Pass the identical reason through `-SelectionReason`; the wrappers reject a blank, multiline, or over-240-character reason and persist the line. An Agent-tool dispatch names the inherited effort and sets `model` explicitly in the same message.
- **Retry one step up, once:** run the dispatch diagnosis before any `-EscalateFrom`; consume the wrapper result first. On `ROUTER_VENDOR_INCIDENT` re-dispatch once on the result's `backup_pick` and print its own `MODEL_SELECTION` line; this retry consumes no attempt, as for `ROUTER_LIMIT`. On `ROUTER_UNEXPLAINED` do not re-dispatch, escalate, or demote; stop the piece (the wrapper already retried once and paged). On `ROUTER_OFFLINE` the piece fails as `environment`; the orchestrator's own resume handles it. Only an implementation failure re-resolves with `-EscalateFrom <failed model>` for the second attempt. On `ROUTER_LIMIT` re-resolve without `-Lane`, dispatch once on the returned backup, and print a second line; this retry consumes no attempt. On `status = wait` stop the dispatch, write the result's `resume_after_et` into `_build-state.md`, send one DM with `pwsh -NoProfile -File scripts/model-router/send-router-alert.ps1 -Key "router-wait: <resume_after_et>"`, and tell Danny.
- **Frontier spend (alert only):** after step 6.i run `pwsh -NoProfile -File scripts/model-router/check-frontier-spend.ps1 -RunStartedAt <run start, ISO> -RunId <RUN_ID> -RemainingMilestones <n> -Json` and relay its `ROUTER_ALERT:` line if any.
- **Stop finished subagents** (TaskStop on claude-host) after collecting the report.

Harness terms: `claude-host` has the Agent tool; `codex-host` is any other orchestrator. CLAUDE_DISPATCH is the Claude-lane dispatch above; VERIFY_DISPATCH is a fresh read-only non-builder session on the vendor returned for `code-review`. Run `-Preflight -TimeoutMs 30000` on each wrapper once per category before its first substantive use; substantive calls set `-TimeoutMs 600000` under a 10-minute outer timeout. On Windows the Codex wrapper runs unsandboxed (Codex removed its Windows sandbox); containment is the scoped worktree plus independent verification, recorded in provenance.

## Context discipline

- **Never pull bulk payloads into the orchestrator.** Read the current milestone by line range, read each reference once at the step that needs it, keep only `-Json` verdict fields, redirect anything over about 40 lines to a file under the run folder and read the tail, hand the verifier a commit range instead of a diff, and give subagents paths, not pasted content.
- **Subagents write to files and checkpoint.** Every chunk prompt carries the standing rules `assemble-codex-prompt.ps1` appends (no nested agents, output to files, no idle waits, checkpoint after about 100 tool calls to `<run-folder>/milestones/<mid>/continuation-<n>.md`); a host-native Agent prompt carries the same text. A `CONTINUATION_STATE` path means a fresh builder on the same router pick continues as the same attempt with its own `MODEL_SELECTION` line. Never message a builder that has done substantive work; a correction is a fresh dispatch. Size chunks by coherence.
- **Restart at milestone boundaries.** After step 6.i, past about 150 tool calls since start or last compaction, tell Danny in one line that `_build-state.md` is current and the run can continue in a fresh session (`/dt-build` with the RUN_ID) or after `/compact`; continue if he does not respond.

## Usage telemetry (automatic)

`scripts/collect-usage.ps1` sweeps this machine's Claude Code and Codex session logs for dt-build runs
(orchestrators and wrapper-launched chunks, either host) and refreshes
`Skill Creation/dt-build-token-efficiency/usage/usage-ledger-<machine>.jsonl` plus `usage-dashboard.html`:
weighted tokens by model family, peak context, nested agents, resume messages, idle cache losses, and
Opus share per run. It is read-only against the logs, incremental, and never blocks a build.

- Run `pwsh -NoProfile -File scripts/collect-usage.ps1 -Quiet` once at intake (step 1) and once after the
  final ledger (step 6.5). The intake sweep is what captures earlier runs, including ones that never
  reached COMPLETE; there is no separate manual step.
- Relay any `DT_BUILD_USAGE_ALERT:` line to Danny verbatim, once. Alerts fire only the first time a run is
  flagged. They are advisory: never stop, retry, or re-plan a build because of one.
- Do not read the ledger or dashboard into your context; report the dashboard path only.

## Procedure (7A intake + 7B execution + 7C acceptance gate)

1. Intake in one question:
- Repo path (absolute).
- Input path — a `roadmap.md` **or** a finalized design (`design-final-*.md` / legacy `design-final.md`
  / `plan-draft.md`). Default: `<project>/design/roadmap.md`, falling back to
  `<project>/design/design-final.md` and then the newest `<project>/design/design-final-*.md`.
- Optional RUN_ID for resume check.
- Optional integration branch (default `build/<RUN_ID>`, cut from `main`).
- Optional merge target (default `main`); use an existing feature branch only when the build is explicitly
  continuing that isolated feature surface.
- Then run the usage sweep (`scripts/collect-usage.ps1 -Quiet`, see "Usage telemetry").

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

2.7 Preflight named dependencies before consuming any implementation attempt:
- Run the roadmap's environment, API, database, browser, credential-source, and toolchain probes against the
  actual target environment whenever the design depends on them.
- Classify failures as `environment`, `tooling`, `contract_revision`, or `implementation`. Only an
  `implementation` failure consumes the two-attempt automatic-agent budget. Persist the failure class and evidence.
- A design-required live database/browser/API replay is build acceptance unless the roadmap explicitly labels
  it as a later ship gate. Mock/unit parity alone cannot mark the build COMPLETE.

3. Enforce legacy hard-cutover (Contract Freeze Gate):
- If a resume RUN_ID points to a pre-refactor `.dt-build/<RUN_ID>/` folder, reject intake.
- Pre-refactor is detected when run artifacts do not carry the intake marker (`intake_contract: roadmap-v1` in build-plan).
- Error must explicitly cite the Contract Freeze Gate decision: legacy pre-refactor run folders are historical-only and cannot be resumed by refactored dt-build.

4. Produce deterministic intake scaffolding:
- `build-state.md` via `scripts/write-build-state.ps1` (atomic full-file rewrite).
- `build-decision-log.md` scaffold.
- `build-plan.md` scaffold (roadmap-driven intake contract).
- Reference-pack files + `reference-manifest.md` via `scripts/build-reference-pack.ps1`.
- The integration branch is the only run state carrier. Never create `dt-build/<RUN_ID>` as a leaf ref;
  chunk refs live below that namespace as `dt-build/<RUN_ID>/<milestone>-<chunk>`.
- Create or validate that carrier with `scripts/prepare-integration-branch.ps1 -RepoPath <repo>
  -IntegrationBranch <integration-branch> -MergeTarget <merge-target>` before any chunk worktree is created.
  On resume, pair intake's `-UseExistingIntegrationBranch` with this script's `-UseExisting`; a missing
  carrier is not resumable.

5. Spawn preflight contract check:
- Resolve each chunk entitlement through `scripts/spawn-preflight.ps1`.
- Abort if any manifest mismatch or missing entitlement.
- Capability-probe each distinct Codex category selected by the run and record the result before chunk dispatch.

5.5 Identify load-bearing milestones:
- Run `scripts/identify-load-bearing.ps1 -RoadmapPath <roadmap> -Json`.
- Persist the result in the run folder (`load-bearing.json`).
- Build execution in step 6 uses this set to reorder within each DAG layer: when multiple milestones become unblocked simultaneously, the load-bearing one is built first and its `accepted` status must be `PASS` before any dependent non-load-bearing milestone's chunk is assembled.

6. Execute milestones with deterministic execution-side procedures, **per-milestone in this order**:
- a. **Quote the verification check.** Restate the `chk-mNN` procedure text and the milestone's acceptance-checks text verbatim in the milestone's `build-decision-log` entry before any code is written.
- b. **Assemble and verify the chunk prompt (both lanes).** `scripts/assemble-codex-prompt.ps1` (single canonical implementation — the name is historical; both lane wrappers consume its verified output, which carries the identity headers and report contract each wrapper enforces; envelope boundary via repo-level `scripts/wrap-prompt-envelope.ps1`), then the four-check prompt verify gate through `scripts/verify-codex-prompt.ps1` before every chunk invocation on either lane.
- c. **Run the chunk through the canonical lane.** For Codex, call `scripts/invoke-codex-chunk.ps1`
  with the chunk's `-Category` (plus `-Protected` when earned), `-Effort <returned effort>` from the resolver, and `-SelectionReason`.
  For Claude, dispatch via CLAUDE_DISPATCH with the same brief and scoped worktree. Run the dispatch diagnosis before any
  `-EscalateFrom`; consume the wrapper result first. On `ROUTER_VENDOR_INCIDENT` re-dispatch once on the result's
  `backup_pick` and print its own `MODEL_SELECTION` line; this retry consumes no attempt, as for `ROUTER_LIMIT`.
  On `ROUTER_UNEXPLAINED` do not re-dispatch, escalate, or demote; stop the piece (the wrapper already retried once and paged).
  On `ROUTER_OFFLINE` the piece fails as `environment`; the orchestrator's own resume handles it.
  Only an implementation retry adds `-EscalateFrom <failed model>`. Do not hand-roll `codex exec` or `claude -p`.
  Automatic implementation failures consume at most two attempts;
  environment/tooling failures and an approved contract revision do not. Explicit human/root remediation that
  restores a fresh PASS may continue the run; it does not silently grant another automatic retry.
  After collecting the subagent's report, stop that subagent (TaskStop on claude-host) before the next step;
  never leave a finished agent idle.
- c1. **Handle a checkpoint return.** If the report's `CONTINUATION_STATE` names a path, follow "Subagents write to files and checkpoint" above before any verification; verify only when a report returns `NONE`.
- c2. **Hold the milestone scope lock.** Every build/fix prompt carries the scope-lock block from
  `references/subagent-prompts.md`: the chunk builds exactly what the milestone specifies — no speculative
  abstraction, no unrequested features, no extra files. Anything discovered mid-build (a missing feature,
  useful file, abstraction, or hardening) is reported in the chunk's `DISCOVERED_ENHANCEMENTS` field, never
  built into the diff.
- d. **Run independent semantic verification.** A fresh non-builder verifier (via VERIFY_DISPATCH) reviews every load-bearing,
  security-sensitive, live-write, or agent-verification milestone before acceptance. Record findings and the
  verifier surface/model, selection reason, and disclosure line. The builder never self-approves. The verifier also flags any diff content beyond
  the milestone's named artifacts and stated scope as an out-of-scope finding — built-but-unrequested work is
  a defect, not a bonus.
- e. **Run the acceptance gate.** `scripts/verify-milestone-acceptance.ps1 -RoadmapPath <r> -MilestoneId <mid> -WorkingTree <wt> -RunTests -Json` — must return PASS. On BLOCKED, the milestone does not count as complete and dependent milestones do not start.
- f. **Run the downgrade-language scan.** `scripts/check-downgrade-language.ps1 -Path <run-folder>/milestones/<mid> -Recurse -Json` — must return exit 0. Any unapproved match is a blocker unless Danny adds `downgrade_approved_by: danny` with a short rationale to the milestone's `build-decision-log` entry.
- g. **Append the acceptance row** to `<run-folder>/acceptance-rows.jsonl`. Include commit SHA, requested and
  resolved model, `category`, `escalated` (true when the accepted attempt used `-EscalateFrom`), selection reason, disclosure line, effort, CLI version, prompt/provenance hashes, verifier result, command results, artifact hashes,
  and downgrade status. This append-only row is the final ledger's source of truth.
- h. **Update the integration branch** (`<integration-branch>` from `build-plan.md`) via compare-and-swap through `scripts/branch-cas-update.ps1` after the per-milestone acceptance gate passes. dt-build never writes to `main`; the final merge of the rehearsed branch to `main` is a separate human-authorized `/git-merge-feature` step.
- i. **Rewrite the pipeline checkpoint.** After the milestone's acceptance gate passes (e–g) and the integration branch is updated (h), rewrite `_build-state.md` in the project's planning folder (the folder holding `plan-draft.md` / `design-final*.md` / `roadmap.md`, typically `<project>/design/`) as an atomic full-file rewrite from the canonical template `skills/dt-pipeline/templates/build-state-template.md` — reference that template, never duplicate its shape here. Record phase, current milestone, completed list (this milestone appended with its commit SHA), in-flight work, last commit SHA, uncommitted artifacts, and next step. This file is distinct from the run-folder `build-state.md` (dt-build's internal run scaffold from step 4): `_build-state.md` is the crash-resume checkpoint dt-pipeline and Danny read.
  Then run the frontier-spend check (alert only): `pwsh -NoProfile -File scripts/model-router/check-frontier-spend.ps1
  -RunStartedAt <run start, ISO> -RunId <RUN_ID> -RemainingMilestones <milestones not yet accepted> -Json`, and
  relay its `ROUTER_ALERT:` line if one prints.

- j. **Triage discovered enhancements.** The orchestrator collects every `DISCOVERED_ENHANCEMENTS` entry
  from the milestone's chunk reports plus any out-of-scope findings from the verifier, and decides each one
  itself — Danny is not consulted per item. The criterion is operational necessity vs. time: an item the
  built system cannot operate correctly without is dispatched as an addendum chunk (normal prompt/verify
  chain, its own acceptance evidence) before the next milestone starts; everything else — improvements,
  hardening, bells and whistles that can wait for a next version — goes to `<run-folder>/deferred-findings.md`
  with a one-line reason. Every add/defer call and its reason is recorded in the milestone's
  `build-decision-log` entry.

6.5 Emit acceptance ledger; review artifact on request only:
- Run one final integrated baseline/E2E rehearsal against the exact integration-branch SHA, including every
  design-required live environment check. Have a fresh non-builder verifier (via VERIFY_DISPATCH)
  review the combined diff. Persist
  `final-integration.json` with branch SHA, commands, environment, verifier provenance (on codex-host,
  include the wrapper's provenance JSON path), and PASS/BLOCKED.
  Do not mark COMPLETE if this gate is missing or BLOCKED.
- Run `scripts/build-acceptance-ledger.ps1 -RoadmapPath <r> -WorkingTree <wt> -OutDir <run-folder> -RunFolder <run-folder>`.
  - Omit `-RunTests` for the normal final ledger. It renders persisted `acceptance-rows.jsonl` evidence and
    does not rerun lifecycle-sensitive milestone tests. Use `-RunTests` only for an explicitly requested
    revalidation; it emits `build-acceptance-revalidation.{md,html}` and never overwrites original acceptance.
  - Emits `build-acceptance-ledger.md` and `build-acceptance-ledger.html`.
  - The ledger is the final answer for the build run — not a freeform summary.
  - When `<run-folder>/deferred-findings.md` exists, the ledger appends its content as a
    "Deferred / Next Version" section in both outputs — the record of what the orchestrator chose not to
    build and why. It is informational, never a blocker, and requires no review by Danny.
- Run the usage sweep again (`scripts/collect-usage.ps1 -Quiet`) and include the dashboard path in the final output.
- Feed the router's outcome history: `pwsh -NoProfile -File scripts/model-router/update-outcomes.ps1 -Json` (reads
  the run's provenance and acceptance rows; relay any `ROUTER_ALERT:` line once).
- Mark the run complete in the pipeline checkpoint: rewrite `_build-state.md` (same template and location as step 6.h) with `status: COMPLETE`, the final commit SHA, and no in-flight work.
- `build-run-review.html`: Do NOT generate the HTML companion automatically. Build it only when Danny explicitly asks. The render harness stays available; skipping it is the default. When Danny asks for it, generate `build-run-review.html` in the run artifact folder with:
  - the acceptance ledger as the headline panel (above the milestone status cards),
  - milestone status cards,
  - execution timeline,
  - verify/fix loop outcomes,
  - blockers/escalations panel,
  - downgrade-language matches panel (per-milestone, with approved/blocker badge).

7. Guardrails:
- Branch drift detection via `scripts/check-drift.ps1`; drift returns nonzero and blocks progress.
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
- Run this before marking the final checkpoint COMPLETE. Hard fail finalization when any of these surface in the script output:
  - any row with status `missing`, `wrong_target`, `create_failed`, or `collision_not_junction`,
  - any entry in `setup_gaps` (a target parent directory does not exist; never auto-create it),
  - any entry in `orphans` introduced by this run.
- Append the full propagation JSON to the build-final summary (the always-on record); when Danny has asked for the `build-run-review.html` companion (step 6.5), also surface a "Skill Propagation" panel in it listing per-(skill, location) status, any setup gaps, and any orphans.
- The same script is callable ad-hoc for retroactive sweeps with no `-NewSkills` (scans all skills in the repo) and without `-Create` (report-only).
- Before COMPLETE, run repo-level `scripts/verify-versioning-policy.ps1 -BaseRef <merge_target> -Json`.
  Any error in skill SemVer, current-first changelogs, manifest agreement, changed-skill bumps, or the plugin
  release bump blocks finalization. Persist the validator JSON beside the propagation evidence.

## Required verification

- Real small build against an actual roadmap (`roadmap.md`) that exercises:
  - milestone-commit behavior
  - integration-branch compare-and-swap flow
  - verify/fix loop budget behavior
- Execution parity check:
  - same milestone-commit outcome class as pre-refactor dt-build behavior
  - artifact integrity checks still pass
  - no regression to verify/fix budget policy
- Report primary run artifacts (including the acceptance ledger and `_build-state.md`) as clickable
  local file links under `../../references/conventions.md`; do the same for `build-run-review.html`
  when Danny asked for it.

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
- Version release gate (danny-skills only): repo-level `scripts/verify-versioning-policy.ps1`
- Pipeline checkpoint template (canonical `_build-state.md` shape, step 6.h): `skills/dt-pipeline/templates/build-state-template.md`
- Acceptance gate scripts (called by procedure step 6):
  - `scripts/verify-milestone-acceptance.ps1` — per-milestone artifact + command check
  - `scripts/check-downgrade-language.ps1` — banned-phrase scanner
  - `scripts/identify-load-bearing.ps1` — load-bearing-first ordering input
  - `scripts/build-acceptance-ledger.ps1` — final four-axis ledger (.md + .html), plus the
    deferred-findings section when present
- Claude-lane wrapper for codex-host and effort-mismatched Claude chunks: `scripts/invoke-claude-chunk.ps1`
- Usage telemetry collector: `scripts/collect-usage.ps1` (entry point) and `scripts/collect-usage.py`
