---
name: dt-prototype
description: "Prototype unresolved logic or UI questions before adversarial review: build either a one-command runnable terminal TUI for behavior/state validation or a multi-variant UI switcher route for visual comparison. Trigger on /dt-prototype or 'dt-prototype [question]'. Do NOT use for final production implementation, full design critique (that belongs to dt-review, whether it runs before or after prototyping), or roadmap/build execution."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash(pwsh:*) Read Write Edit AskUserQuestion"
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 1.1.0
  changelog: "Initial Anthropic-standard Phase 3 release. Adapted from Matt Pocock's prototype skill (MIT) with dt-pipeline routing and vendored starter templates for logic TUI (TypeScript/Python) and UI variant switcher."
---

# Prototype

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

Do NOT generate the HTML companion automatically. Build it only when Danny explicitly asks. The render harness stays available; skipping it is the default.



Adapted from Matt Pocock's prototype skill (MIT) - see `references/ATTRIBUTION.md`.

`dt-prototype` is the conditional stage between planning and adversarial review. Use it when a question
needs behavior you can press on, not just prose you can read.

## When this fires

Trigger when at least one of these is true:
- The plan includes a state machine, reducer, classifier, policy engine, or transition logic that is hard to
  validate in plain text.
- The open question is primarily visual ("which layout/hierarchy should win?").
- Danny asks to prototype, sandbox, or "let me play with it" before locking a design.

Do NOT fire for:
- Final implementation quality work (tests, abstractions, production hardening).
- Adversarial design critique — that belongs to `dt-review`, whether it runs before or after prototyping.
- Build decomposition/execution (`dt-build`), or roadmap contract work.

## Branch selection

Pick exactly one branch:

1. `logic`
- Use for behavior/state questions.
- Read `references/LOGIC.md`.
- Output: one-command-runnable terminal TUI prototype.

2. `ui`
- Use for "what should this look like?" questions.
- Read `references/UI.md`.
- Output: multiple radically different UI variants switchable on one route.

If ambiguous and Danny is not reachable, choose based on surrounding code shape:
- backend/module-heavy context -> `logic`
- page/component-heavy context -> `ui`

State the assumption explicitly at the top of the output notes.

## Procedure

1. Intake in one question:
- Target project path.
- Prototype question to answer (single sentence).
- Branch (`logic` or `ui`), if not already explicit.
- Preferred runtime/tooling if the project has multiple options.

2. Load branch guidance and template assets:
- For `logic`: `references/LOGIC.md`, plus `assets/logic-prototype.ts.template` or
  `assets/logic-prototype.py.template` based on project stack.
- For `ui`: `references/UI.md`, plus `assets/variant-switcher.tsx.template`.

3. Build the prototype near the target code:
- Keep it obviously throwaway (`prototype` in file/route naming).
- Preserve host project conventions (routing, package manager, file structure).
- Ensure exactly one command runs it.
- Verify the one command — do not just assert it. Actually run the single command, confirm the
  process starts and serves (or the TUI renders), then stop it. For a TUI, drive it with a trivial
  scripted input if possible (for example piping a quit keystroke); if scripted input is not
  feasible, record in `NOTES.md` why not and what was verified instead.

4. Capture the answer:
- Write `NOTES.md` next to the prototype with:
  - the question,
  - what was observed,
  - the decision to keep/delete/fold.
- `NOTES-view.html` is on request only. Do NOT generate the HTML companion automatically. Build it
  only when Danny explicitly asks. The render harness stays available; skipping it is the default.
  When Danny asks, write `NOTES-view.html` beside `NOTES.md` with:
  - question/status summary cards,
  - observed behavior flow (Mermaid or SVG),
  - keep/delete/fold decision panel.

5. Exit with cleanup intent:
- Recommend deleting throwaway scaffolding after the decision is absorbed.
- If Danny is offline, leave explicit cleanup TODOs in `NOTES.md`.

## Guardrails

- Prototype fast; do not over-engineer.
- No persistence by default unless persistence is the question being tested.
- No new framework/toolchain if the host already has a standard one.
- Keep the logic core portable and pure when running the `logic` branch.
- For UI branch, variants must be structurally different, not color tweaks.
- Do not present prototype output as production-ready code.


