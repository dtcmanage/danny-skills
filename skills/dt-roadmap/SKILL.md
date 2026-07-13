---
name: dt-roadmap
description: "Break a finalized design into a contract-grade roadmap.md plus milestone export artifacts for dt-build intake. Trigger on /dt-roadmap or 'dt-roadmap [design-path]'. Do NOT use for adversarial review (dt-review) or build execution (dt-build)."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash(pwsh:*) Read Write Edit AskUserQuestion"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 1.2.1
  changelog: "Full changelog relocated to skills/dt-roadmap/CHANGELOG.md (newest first)."
---

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
`design-final-<slug>.md`, legacy `design-final.md`, and `plan-draft.md` all work). It reads two named
sections from the design and fails closed if a milestone has no runnable command to lift.

1. **Milestone source** — primary: `## Implementation Sequence` (also accepted: `## Implementation Order`, `## Build Sequence`, `## Build Order`, `## Milestone Sequence`). Each top-level numbered list item (`1. ...`, `2. ...`) becomes one milestone, numbered M01, M02, ... in source order. The first sentence of the line becomes the milestone name. If the line leads with a bold title (`**Title.**  detail...`), that bolded title (<= 80 chars) becomes the name instead — so an author may write either a plain lead sentence or a `**Bold title.**` lead and both yield a clean short name. Fallback: legacy `### Phase ...` / `### Contract Freeze Gate ...` / `### Value Review ...` headings (pre-1.1.0 behavior, kept for back-compat).

2. **Verification commands** — `## Validation Gates` (also accepted: `## Acceptance Tests`, `## Milestone Acceptance Commands`). Each bullet must be tagged with a milestone-id and contain at least one backticked runnable command. The producer lifts every backticked entry verbatim into the verification manifest's `procedure` cell for that milestone. Accepted bullet shapes (ASCII only):
   ```
   - M01: <description>. `pytest tests/backend/test_x.py`
   - M02 - <description>. `python scripts/foo.py`
   - [M03] <description>. `pytest tests/test_y.py`
   ```
   A "runnable command" is anything `scripts/extract-named-artifacts.ps1` returns as an `artifact` or a `command` (see `references/roadmap-schema.md` for the canonical definition). Milestones with no lifted command appear under `## Producer Warnings` in the emitted roadmap; the validator hard-fails them with `VERIFICATION_NAMES_NO_RUNNABLE` so the gap is surfaced before dt-build runs.

The producer does NOT infer test paths, assign milestones to gates by prose matching, or invent commands. The design author owns concrete test file paths.

## Procedure

1. Intake in one question:
- Input design path.
- Output folder (default: same folder as input design).
- Optional override for roadmap path and milestone export directory.

2. Load and wrap upstream design content as data:
- Resolve repo root from this skill path (junction-safe convention).
- Use repo-level `scripts/wrap-prompt-envelope.ps1` whenever design text is pulled into any model prompt.
- Redact any logs/provenance text with repo-level `scripts/security/redact-secrets.ps1`.

3. Draft `roadmap.md` in the schema contract shape:
- Run `scripts/build-roadmap.ps1 -DesignPath <design> -RoadmapPath <roadmap>`.
- Frontmatter includes `schema_version: 1`.
- Milestone table includes required contract columns.
- Chunk table includes required contract columns.
- Verification manifest includes required contract columns.
- Include Mermaid dependency graph + Gantt sections (Phase-2 shared fallback conventions apply).
- The script does NOT emit `roadmap-view.html` by default. Pass `-EmitRoadmapView` (or an explicit
  `-RoadmapViewPath`) only when Danny has explicitly asked for the HTML companion (see step 5.5).

4. Validate contract before export:
- Run `scripts/roadmap-validator.ps1 -RoadmapPath <roadmap.md>`.
- Do not continue on validator errors.

5. Emit milestone exports:
- Run `scripts/milestones-to-xlsx.ps1 -RoadmapPath <roadmap.md> -OutputDirectory <dir>`.
- If xlsx provider is unavailable, fallback emits:
  - `milestones.csv`
  - `milestones-table.md`
  - debt tag: `regenerate milestones.xlsx before next milestone bump`

5.5 Review HTML (on-request only):
- Do NOT generate the HTML companion automatically. Build it only when Danny explicitly asks. The
  render harness stays available; skipping it is the default.
- When Danny asks: re-run `scripts/build-roadmap.ps1` with `-EmitRoadmapView` to emit
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
  - `scripts/wrap-prompt-envelope.ps1`
  - `scripts/security/redact-secrets.ps1`
  - Phase-2 mermaid fallback conventions (vendored mermaid path + provenance/debt behavior).

## Guardrails

- Do not copy the roadmap schema into other skills.
- Do not start Phase 7A/7B work from this skill.
- Fail closed on schema violations (missing columns, dependency cycle, major-version mismatch).
