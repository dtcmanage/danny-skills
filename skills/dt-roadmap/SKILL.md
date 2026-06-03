---
name: dt-roadmap
description: "Break a finalized design into a contract-grade roadmap.md plus milestone export artifacts for dt-build intake. Trigger on /dt-roadmap or 'dt-roadmap [design-path]'. Do NOT use for adversarial review (dt-review) or build execution (dt-build)."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash(pwsh:*) Read Write Edit AskUserQuestion"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 1.1.1
  changelog: "1.1.1 bold-aware milestone naming: Get-FirstSentence in scripts/build-roadmap.ps1 now prefers a leading bold span (`**Title.**`) as the milestone name before the first-sentence fallback. The first-sentence regex `^(.+?[.!?])(\\s|$)` only breaks on a terminator followed by whitespace, so an item that led with a bold title (period inside the `**`, no trailing space) skipped the title and captured the whole paragraph as the name — producing unreadable blob names in the milestone table, dependency graph, and Gantt (surfaced on the 2026-06-03 file-sorter learning-loop-date-extraction roadmap, which had to reword all 10 sequence items to plain sentences as a workaround). Fix: non-greedy `^\\*\\*(.+?)\\*\\*` capture, trimmed of trailing `.!?:`, returned when 1..80 chars, else falls through unchanged. Plain-sentence items are byte-for-byte unchanged. Input-contract doc updated to document the bold-title-as-name behavior. No schema_version or producer_current_version change (producer-internal name refinement). Prior: hardened producer + validator for dt-build per-milestone acceptance gate compatibility. (1) Added VERIFICATION_NAMES_NO_RUNNABLE schema check: each milestone's combined verification surface (acceptance-checks + every matching chk-* procedure cell) must name at least one runnable artifact — a backticked file path with an extension in the allowlist, a backticked or inline `pytest ...` / `python scripts|backend|workers|tests/...` command, or one of `pwsh|powershell|node|npm|bun`. Validator and gate share the same definition through repo-level `scripts/extract-named-artifacts.ps1` (byte-identical to the inline copy in `skills/dt-build/scripts/verify-milestone-acceptance.ps1`). (2) Broadened the input parser: primary path now reads milestones from a `## Implementation Sequence` (or `Implementation Order` / `Build Sequence` / `Build Order` / `Milestone Sequence`) section's enumerated top-level numbered list; legacy `### Phase ...` heading detection remains as a back-compat fallback. (3) Lifted concrete pytest/python commands verbatim from milestone-tagged bullets in the design's `## Validation Gates` section (tag convention: `- M<NN>: ... \\`cmd\\``) into procedure cells, replacing the prior stub prose. Producer surfaces any milestone without a lifted command in the new `## Producer Warnings` section so the validator's hard-fail is predictable. Bumped producer_current_version 1.0.0 -> 1.1.0 (additive enforcement, no schema_version major bump). Previous 1.0.1: scripted roadmap-view.html generation with vendored Mermaid rendering."
---

# Roadmap Builder

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



Produce a contract-grade `roadmap.md` from a finalized design artifact and emit milestone tracking artifacts that
Phase 7 (`dt-build`) can consume deterministically.

## When this fires

Trigger when all are true:
- Input is a finalized design artifact (`design-final.md`, or `plan-draft.md` when review was skipped).
- Danny wants the build contract surface (`roadmap.md`) produced before dt-build intake refactor.
- Milestone output is needed as `milestones.xlsx`, with documented fallback when xlsx dependency is unavailable.

Do NOT fire for:
- Adversarial design critique or closure loops -- that is `dt-review`.
- Build execution, verification loops, or merge workflows -- that is `dt-build`.

## Input contract (design-final.md sections the producer reads)

The producer is deterministic. It reads two named sections from the design and fails closed if a milestone has no runnable command to lift.

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
- The same script also emits `roadmap-view.html` beside `roadmap.md` unless `-RoadmapViewPath` is supplied.

4. Validate contract before export:
- Run `scripts/roadmap-validator.ps1 -RoadmapPath <roadmap.md>`.
- Do not continue on validator errors.

5. Emit milestone exports:
- Run `scripts/milestones-to-xlsx.ps1 -RoadmapPath <roadmap.md> -OutputDirectory <dir>`.
- If xlsx provider is unavailable, fallback emits:
  - `milestones.csv`
  - `milestones-table.md`
  - debt tag: `regenerate milestones.xlsx before next milestone bump`

5.5 Generate review HTML:
- Use the `roadmap-view.html` emitted by `scripts/build-roadmap.ps1`.
- It must contain summary cards, a milestone table, Mermaid dependency graph, Mermaid Gantt timeline, and dependency provenance.
- Validate in a browser that `.mermaid svg` exists; raw `graph TD` text does not satisfy the review artifact contract.

6. Report outputs:
- Return absolute path to `roadmap.md`.
- Return produced milestone artifacts and whether xlsx primary or csv fallback path was used.
- Also return absolute path to `roadmap-view.html` (timeline/flowchart-based review artifact).

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
