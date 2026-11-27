---
name: dt-roadmap
description: "Break a finalized design into a contract-grade roadmap.md plus milestone export artifacts for dt-build intake. Trigger on /dt-roadmap or 'dt-roadmap [design-path]'. Do NOT use for adversarial review (dt-review) or build execution (dt-build)."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash(pwsh:*) Read Write Edit AskUserQuestion"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 1.5.3
  changelog: "Full changelog relocated to skills/dt-roadmap/CHANGELOG.md (newest first)."
---

`<skill>` is this SKILL.md folder, resolved through links; `<danny-skills>` is the repo root two levels above it (see `../../references/conventions.md`).

# Roadmap Builder

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).

If this skill has stricter domain-specific behavior, keep that stricter behavior; otherwise follow the shared baseline.

## HTML Companion Policy (on-request only)

Do NOT generate the HTML companion automatically. Build it only when Danny explicitly asks. The
render harness stays available; skipping it is the default.

When Danny explicitly asks for `roadmap-view.html`, build it per `../../references/html-artifact-policy.md`
(cards/tables plus Mermaid dependency graph + Gantt) and verify it with the shared checker — see step 5.5.



Produce a contract-grade `roadmap.md` from a finalized design artifact and emit milestone tracking artifacts that
Phase 7 (`dt-build`) can consume deterministically.

## When this fires

Trigger when all are true:
- Input is a finalized design artifact (`design-final-<slug>.md` — dt-review's output naming, e.g.
  `design-final-lp-statement-linking.md`; legacy bare `design-final.md` is also accepted, as is
  `plan-draft.md` when review was skipped).
- Danny wants the build contract surface (`roadmap.md`) produced before dt-build intake refactor.
- Milestone output is needed as `milestones.xlsx`, with documented fallback when xlsx dependency is unavailable.

Do NOT fire for:
- Adversarial design critique or closure loops -- that is `dt-review`.
- Build execution, verification loops, or merge workflows -- that is `dt-build`.

## Input contract (design-doc sections the producer reads)

The producer is deterministic and filename-agnostic (the design path is passed as `-DesignPath`;
`design-final-<slug>.md`, legacy `design-final.md`, and `plan-draft.md` all work). It reads three named
sections from the design and fails closed if a milestone has no runnable command to lift.

1. **Milestone source** — primary: `## Implementation Sequence` (also accepted: `## Implementation Order`, `## Build Sequence`, `## Build Order`, `## Milestone Sequence`). Each top-level numbered list item (`1. ...`, `2. ...`) becomes one milestone, numbered M01, M02, ... in source order. The first sentence of the line becomes the milestone name. If the line leads with a bold title (`**Title.**  detail...`), that bolded title (<= 80 chars) becomes the name instead — so an author may write either a plain lead sentence or a `**Bold title.**` lead and both yield a clean short name. Fallbacks, in order: (a) the first `##`/`###` heading naming a milestone plan (milestone, phase, sequence, build order, implementation plan) — its numbered list, else its child headings; (b) legacy `### Phase ...` / `### Contract Freeze Gate ...` / `### Value Review ...` headings (pre-1.1.0 behavior); (c) numbered top-level deliverable sections (`## 1. <deliverable>`), skipping framing sections such as Overview or Risks. When none yields a milestone, the producer prints `NO_MILESTONES_DERIVABLE: No milestones derivable from design ...` naming every heading it looked for and exits 2 — an explanatory stop, never a stack trace.

2. **Verification commands** — `## Validation Gates` (also accepted: `## Acceptance Tests`, `## Milestone Acceptance Commands`). Each bullet must be tagged with a milestone-id and contain at least one backticked runnable command. The producer lifts every backticked entry verbatim into the verification manifest's `procedure` cell for that milestone. Accepted bullet shapes (ASCII only):
   ```
   - M01: <description>. `pytest tests/backend/test_x.py`
   - M02 - <description>. `python scripts/foo.py`
   - [M03] <description>. `pytest tests/test_y.py`
   ```
   A "runnable command" is anything `<danny-skills>/scripts/extract-named-artifacts.ps1` returns as an `artifact` or a `command` (see `references/roadmap-schema.md` for the canonical definition). Milestones with no lifted command appear under `## Producer Warnings` in the emitted roadmap; the validator hard-fails them with `VERIFICATION_NAMES_NO_RUNNABLE` so the gap is surfaced before dt-build runs. The producer lifts a wider runner set than the extractor (`python3`/`python3.N`, `bash`, `sh`, `./<path>`, `uv`, `npx`, `pnpm`, `make`, `go`, `cargo`, `.sh` paths) so the command reaches the manifest verbatim; until the shared extractor and dt-build's inline copy accept the same set, pair such a command with a recognized one or a backticked test-file path (for example `python -m pytest tests/test_x.py`) or the validator still fails the milestone.

The producer does NOT infer test paths, assign milestones to gates by prose matching, or invent commands. The design author owns concrete test file paths.

3. **Throughput and hardware** — carry the plan's measured hosts and decisions into the finalized design.
   Add a table with `milestone-id`, `dependencies` (`-` for independent), `execution` (`parallel` or
   `serial: <named cause>`), and `test-execution` (`parallel: <sharded command/budget>` or
   `serial: <named cause>`). Map every milestone and its chunk; name shared state, isolation and RAM needs
   in the section. Mark independent milestones/chunks concurrent only when their write surfaces are isolated.
   The producer copies this section and exports both execution columns; it never infers independence from order.

## Procedure

Before generation, author `## Milestone Surfaces` in the design: columns `milestone-id`,
`write-surface`, `provides`, `consumes`, `design-source` (design heading/requirement). Cover every
milestone, including shared lock/config/test files and moved files at both paths. Separate entries
with semicolons; use `-` for empty sets. Write surfaces are case-sensitive repo-relative paths/globs
(`/`, `*`, `?`, whole-segment `**`); other glob syntax is rejected. Interfaces use exact stable names
such as `module:slots`, `api:POST /release`, `schema:Slot`, `config:slot_lock`. Document existing
external interfaces in design-source. The producer computes dependencies from consumption and write
overlap, removes unsupported declared edges with `DEPENDENCY_UNJUSTIFIED` warnings and names serial
overlap causes. Consumption sets direction; otherwise use authored direction, then stable ID order.

### Required cutover or migration rehearsal milestone

For any cutover or migration, apply `00_Resources/build-process.md`, "Rehearse a cutover or migration
runbook end to end before the live attempt." Before generation, require a distinct rehearsal milestone
in the design's implementation sequence, with concrete runnable Validation Gates. Its acceptance must:

- Run every exact final runbook command in order on a disposable copy of real data, verifiers included,
  using the same interpreter flags, user and paths. Unit tests or piecewise runs do not count.
- Re-derive every gate's expected numbers from the current code; save the derivation and actual results.
- Inventory leftover authority/marker files, test installs and stale config refused by the new release;
  add cleanup steps and exercise them in the full rehearsal.
- Prove the check scripts themselves against the live old system, including selectors, quoting and
  expected values. Fix broken checks and rerun them; a harness failure does not trigger product rollback.
- Record the owner's answer about dependencies on the old system during the switch and the rollback
  dependency decision. When nothing uses it, keep it stopped and fix forward to preserve the export.
- Run steps exceeding worker time limits detached with logs and orchestrator monitoring, and read each
  gate's result before the next action. Never chain a push or deploy onto a test command.

Record the runbook revision, code SHA, data-copy identity, commands, results and rollback decision in the
milestone's evidence artifacts. Any change to those commands, code or gate expectations invalidates the
pass and requires a fresh full rehearsal. In `Milestone Surfaces`, have the rehearsal provide an explicit
interface such as `gate:cutover-rehearsal` and every live-switch milestone consume it, so the producer
retains the dependency. Inspect the generated dependency causes and verification manifest before export.
If the design lacks this milestone or runnable checks, stop and repair the design before generation;
never treat a generic final integration test as the rehearsal.

1. Intake in one question:
- Input design path.
- Output folder (default: same folder as input design).
- Optional override for roadmap path and milestone export directory.

2. Load and wrap upstream design content as data:
- Resolve repo root from this skill path (junction-safe convention).
- Use repo-level `<danny-skills>/scripts/wrap-prompt-envelope.ps1` whenever design text is pulled into any model prompt.
- Redact any logs/provenance text with repo-level `<danny-skills>/scripts/security/redact-secrets.ps1`.

3. Draft `roadmap.md` in the schema contract shape:
- Read `references/design-coverage.md`; inventory every requirement from the full design and assign exactly one milestone or an owned out-of-build row. Split inputs carry the same shared coverage table and build registry.
- Run `<skill>/scripts/build-roadmap.ps1 -DesignPath <design> -RoadmapPath <roadmap>`.
- Resolve any throughput Producer Warnings before intake. Keep the plan's serial reasons and shard commands;
  put the chosen runnable shard command in Validation Gates so acceptance executes it verbatim.
- Frontmatter includes `schema_version: 1`.
- Milestone table includes required contract columns.
- Chunk table includes required contract columns.
- Verification manifest includes required contract columns.
- Include Mermaid dependency graph + Gantt sections (Phase-2 shared fallback conventions apply).
- The script does NOT emit `roadmap-view.html` by default. Pass `-EmitRoadmapView` (or an explicit
  `-RoadmapViewPath`) only when Danny has explicitly asked for the HTML companion (see step 5.5).

4. Validate contract before export:
- Record one exact `gateCommand` for every milestone in a `## Milestone gate commands` section of the
  generated roadmap. Use one fenced JSON object keyed by milestone-id; each entry records `gateCommand`
  and the absolute path of its release ship configuration. Copy the command verbatim from that file,
  including flags, wrappers, conditionals and exit handling. Use the same command the final release gate
  runs for that milestone's scope; for example, retain `npm test` when it also runs contract checks,
  never substitute direct `vitest` or a selected test subset. If no ship configuration exists, record
  that absence and the explicit final gate command agreed in the design. Missing or ambiguous commands
  block export. Preserve this section when regenerating the roadmap.
- Compare each recorded command with the actual ship configuration and final gate before export.
  Put that exact command in the milestone's verification procedure, with targeted checks only as
  additional checks. `dt-build` must execute the recorded command at every milestone gate; final-only
  execution cannot cover earlier milestone acceptance. Carry the command source and comparison evidence
  with the roadmap so a later change invalidates the old gate result.
- Run `<skill>/scripts/roadmap-validator.ps1 -RoadmapPath <roadmap.md>`.
- Resolve dependency warnings against the design; missing surfaces, undeclared consumption/overlap,
  cycles and non-serial overlaps are errors. Review `Dependency Causes` before export.
- Do not continue on validator errors.

5. Emit milestone exports:
- Run `<skill>/scripts/milestones-to-xlsx.ps1 -RoadmapPath <roadmap.md> -OutputDirectory <dir>`.
- If xlsx provider is unavailable, fallback emits:
  - `milestones.csv`
  - `milestones-table.md`
  - debt tag: `regenerate milestones.xlsx before next milestone bump`

5.5 Review HTML (on-request only):
- Do NOT generate the HTML companion automatically. Build it only when Danny explicitly asks. The
  render harness stays available; skipping it is the default.
- When Danny asks: re-run `<skill>/scripts/build-roadmap.ps1` with `-EmitRoadmapView` to emit
  `roadmap-view.html` beside `roadmap.md`. It must contain summary cards, a milestone table, Mermaid
  dependency graph, Mermaid Gantt timeline, and dependency provenance.
- Then verify it deterministically with the shared checker (via Bash):
  `pwsh -NoProfile -File <repo>/scripts/visualize/verify-html-artifact.ps1 -Path <roadmap-view.html>
  -RequireMermaid -RequireText 'Dependency Provenance' -Json`.
  The `-RequireMermaid` checks drive the browser-smoke harness and assert a rendered `.mermaid svg`
  with no console errors; raw `graph TD` text does not satisfy the review artifact contract. Do not
  report the view as done if `status` is not `pass`.

6. Report outputs:
- Return absolute path to `roadmap.md`.
- Return produced milestone artifacts and whether xlsx primary or csv fallback path was used.
- Return absolute path to `roadmap-view.html` only when it was explicitly requested and built.

## Contract + dependency rules

- Canonical schema source is only `skills/dt-roadmap/references/roadmap-schema.md`.
- Producer/consumer major-match is enforced by validator:
  `roadmap.md` frontmatter `schema_version` major must match schema `producer_current_version` major.
- Reuse shared infra only:
  - `<danny-skills>/scripts/wrap-prompt-envelope.ps1`
  - `<danny-skills>/scripts/security/redact-secrets.ps1`
  - Phase-2 mermaid fallback conventions (vendored mermaid path + provenance/debt behavior).

## Guardrails

- Do not copy the roadmap schema into other skills.
- Do not start Phase 7A/7B work from this skill.
- Fail closed on schema violations (missing columns, dependency cycle, major-version mismatch).
