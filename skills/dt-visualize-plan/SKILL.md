---
name: dt-visualize-plan
description: "Render a plan-draft.md into a browser-openable plan-view.html artifact with milestone table, optional Mermaid dependency graph + Gantt, and optional UI mockup section. Trigger on /dt-visualize-plan or 'dt-visualize-plan [plan-path]'. Do NOT use for adversarial review (dt-review) or execution (dt-build)."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash(pwsh:*) Read Write Edit AskUserQuestion"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 1.0.2
  changelog: "Pointer-swap to shared output-paths convention in references/conventions.md instead of restating the no-computer-link rule inline."
---

# Visualize Plan

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



Turn a saved plan into a fast-read HTML artifact (`plan-view.html`) that catches structural issues before
adversarial review or build. This skill owns rendering and clarity, not decision-making or implementation.

## When this fires

Trigger when all are true:
- There is a saved plan artifact (`plan-draft.md` or equivalent design-plan markdown).
- Danny wants a visual pass (milestones, sequence clarity, dependencies, or UI mockup framing).
- The output should be a single file that opens locally with no dev server.

Do NOT fire for:
- Adversarial critique and redesign loops -- that is `dt-review`.
- Build decomposition/execution -- that is `dt-build`.

## Intake modes

Choose one mode at intake:

1. `milestone-table-only`
- Use when the plan is non-UI and dependency rendering would add noise.
- Output: summary cards + milestone table + open questions + redacted plan preview.

2. `plan-plus-mermaid`
- Use when sequencing/dependencies matter.
- Output: everything in mode 1, plus Mermaid dependency graph + Gantt.

3. `ui-mockup`
- Use when UI structure matters.
- Output: mode 2 plus UI mockup section (provider source noted in provenance footer).

If unsure, default to `plan-plus-mermaid`.

## Procedure

1. Collect input in one question:
- Plan file path.
- Mode (`milestone-table-only`, `plan-plus-mermaid`, `ui-mockup`).
- For `ui-mockup`: provider (`frontend-design`, `web-artifacts-builder`, `manual-single-variant`) and optional mockup file path.

2. Render with the shared builder:
- Call `scripts/render-plan-view.ps1` in this skill.
- Builder path is repo-level `scripts/visualize/html-builder.ps1`.
- Output convention: `plan-view.html` next to the source plan unless an explicit output path is provided.

3. Validate output quickly:
- Confirm `plan-view.html` exists.
- Confirm no remote Mermaid URL is present (must use vendored local `mermaid-10.9.3.min.js`).
- Confirm rendered Mermaid exists (`.mermaid svg` in the browser) when using `plan-plus-mermaid` or `ui-mockup`.
- Confirm "Dependency Provenance" footer is populated.
- Confirm the first viewport is skim-first (summary strip + key diagram/timeline, not a wall of prose).

4. Report result:
- Return the saved absolute path.
- If fallback mode was used, include debt tags exactly as shown in the footer.

## Security + dependency rules

- Redact before rendering: `html-builder.ps1` imports repo-level `scripts/security/redact-secrets.ps1`.
- Mermaid security mode must stay `securityLevel: 'strict'`.
- Never fetch Mermaid from a CDN; vendored asset only.
- If Mermaid MCP is unavailable, fallback to vendored client-side renderer.
- In any fallback mode, include the dependency provenance footer with active assets and debt tags.

## Guardrails

- Do not rewrite the plan content. Render only.
- Do not block on unavailable upstream skills if a documented fallback exists.
- Follow the output-paths convention in `../../references/conventions.md` (bare absolute paths, no `computer://` links).
- Keep this skill focused: rendering and surface clarity only.

