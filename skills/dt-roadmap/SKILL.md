---
name: dt-roadmap
description: "Break a finalized design into a contract-grade roadmap.md plus milestone export artifacts for dt-build intake. Trigger on /dt-roadmap or 'dt-roadmap <design-path>'. Do NOT use for adversarial review (dt-review) or build execution (dt-build)."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash(pwsh:*) Read Write Edit AskUserQuestion"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 1.0.0
  changelog: "Initial Anthropic-standard release (Phase 6): contract-first roadmap producer with schema validator and milestones xlsx/csv fallback exporter."
---

# Roadmap Builder

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

4. Validate contract before export:
- Run `scripts/roadmap-validator.ps1 -RoadmapPath <roadmap.md>`.
- Do not continue on validator errors.

5. Emit milestone exports:
- Run `scripts/milestones-to-xlsx.ps1 -RoadmapPath <roadmap.md> -OutputDirectory <dir>`.
- If xlsx provider is unavailable, fallback emits:
  - `milestones.csv`
  - `milestones-table.md`
  - debt tag: `regenerate milestones.xlsx before next milestone bump`

6. Report outputs:
- Return absolute path to `roadmap.md`.
- Return produced milestone artifacts and whether xlsx primary or csv fallback path was used.

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
