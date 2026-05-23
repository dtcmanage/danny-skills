# prototype skill — Build Plan
**Date:** 2026-05-17
**Surface:** Claude Code skill authoring (custom)
**Scope:** light
**Repo:** dtcmanage/danny-skills

## Goal

Add a fourth skill, `prototype`, to the danny-skills pack. It builds throwaway
code that answers one design question, then gets deleted or absorbed. It is
adapted from the `prototype` skill in `mattpocock/skills`
(`skills/engineering/prototype/`, MIT) — not copied verbatim.

The pack's three pipeline skills each explicitly say *"skip for exploratory
throwaway code"* (`design-build` "Do NOT fire", `design-loop` "Do NOT fire",
`parallel-build` "tightly-coupled work"). That exclusion is a real gap.
`prototype` fills it: it answers the empirical questions that discussion alone
cannot — *does this state model hold up?*, *which layout?* — and feeds the
verdict back into the planning pipeline.

Target pipeline shape:

```
prototype  →  design-build  →  design-loop  →  parallel-build
(explore)      (plan)           (critique)       (implement)
```

`prototype` also runs as a side-branch: a `design-build` Open Question that is
empirical can be resolved by a prototype, then folded back into the plan.

## Source & Licensing

- Upstream: `mattpocock/skills`, `skills/engineering/prototype/` — SKILL.md +
  LOGIC.md + UI.md. License: MIT.
- We adapt, not fork: structure and routing concept are kept; the three
  adaptations in the next section change capture, environment, and framing.
- Attribution: credit `mattpocock/skills` (MIT) in the commit message and in
  the README skill entry, matching how commit `34001fd` already credits the
  same upstream for `design-build`.

## Skill Structure & Files

One skill, three files, mirroring upstream:

- `skills/prototype/SKILL.md` — frontmatter + branch-routing + shared rules.
- `skills/prototype/LOGIC.md` — terminal-app branch for state/logic questions.
- `skills/prototype/UI.md` — UI-variations branch for "what should this look
  like" questions.

`SKILL.md` instructs Claude to `Read` the relevant sibling file once the branch
is chosen. This is a plain file read, not a skill-loader feature, so it works
regardless of how Claude Code resolves skill assets (see Open Questions for the
fallback if sibling reads prove unreliable).

Frontmatter:

```yaml
name: prototype
description: Build a throwaway prototype to answer one design question, then
  delete or absorb it. Routes to a terminal app for state/logic questions or
  to several UI variations on one route for "what should this look like".
  Trigger on "/prototype", "prototype this", "let me play with it", "try a
  few designs".
```

## Branch Routing

`SKILL.md` identifies which question is being answered, then routes:

- *"Does this logic / state model feel right?"* → `LOGIC.md`.
- *"What should this look like?"* → `UI.md`.

Disambiguation rule (kept from upstream, made explicit): if the question is
genuinely ambiguous and Danny is unreachable, default by the surrounding code —
a backend module / pure function → LOGIC; a page or component → UI — and state
the assumption at the top of the prototype. If Danny *is* reachable, ask via one
`AskUserQuestion` rather than guessing, consistent with the rest of the pack.

## Adaptation 1 — Capture Convention

Upstream captures the answer in "commit message, ADR, issue, or NOTES.md".
The pack already has precise conventions (`design-build`: ADR format + 3-test
rule, `CONTEXT.md` glossary). A freelance `NOTES.md` would drift from those.

Adapted "When done" behavior, in priority order:

1. **Prototype spawned from a `design-build` Open Question.** The originating
   plan file is static and lives in Danny's workspace
   (`D:\Claude\_Claude-Workspace\...`), while the prototype runs in a code repo
   (`D:\Projects\...`) — two different locations. So the skill does NOT
   auto-edit the plan. It captures the verdict in the prototype's own commit
   message AND prints, in chat, the exact one-line verdict text for Danny to
   paste into the plan's Open Questions / Out of Scope section.
2. **Repo has `docs/adr/` or `CONTEXT.md`.** Offer an ADR using `design-build`'s
   3-test rule (hard to reverse / surprising / real trade-off) or a `CONTEXT.md`
   glossary entry, reusing `design-build`'s formats verbatim.
3. **Otherwise.** Capture in the commit message that deletes/absorbs the
   prototype. `NOTES.md` is dropped as a default.

The skill always states the question the prototype answered alongside the
answer — the answer without the question is not durable.

## Adaptation 2 — Environment

Upstream assumes a POSIX, JS/TS-flavored world. Danny's machine is Windows +
PowerShell; projects span Node, Python, and others.

- **One command to run.** Detect the runner from the project rather than
  assuming: `package.json` scripts → `npm`/`pnpm`; `pyproject.toml` /
  scripts → `py -3` (Danny's Python launcher, e.g. `thai-capital-website`'s
  `prepare:migration-csv` uses `py -3`); `Cargo.toml` → `cargo`. If no runner
  exists, the prototype is a single self-contained script invoked directly.
- **Paths.** Examples use Windows paths and backslashes.
- **LOGIC branch.** The terminal app must run in a standard Windows terminal;
  prefer a TUI approach with no native build step (see Open Questions on
  whether to prescribe a library).
- **UI branch.** `thai-capital-website` is Vite + React 18 + `react-router-dom`
  v6 + Tailwind + shadcn/ui, so sub-shape A (variants on an existing route via
  a `?variant=` search param + floating switcher bar) applies directly. Keep
  sub-shape B (a throwaway prototype route) for projects that have routing but
  no suitable host page, and treat "no router at all" as sub-shape B's
  standalone-page case rather than inventing a new top-level structure.

## Adaptation 3 — Weight Class (framing)

`design-loop` and `parallel-build` carry heavy machinery: Claude×Codex dialogue,
SHA-256 provenance, round logs, recovery state machines. `prototype` has none of
that, by design — throwaway code does not warrant an audit trail.

`SKILL.md` and the README must state this explicitly ("intentionally
lightweight — no Codex, no provenance, no round log") so a reader does not
mistake `prototype` for an unfinished skill next to its heavier siblings.

## Pipeline Integration

- **README.** Update the pipeline diagram to the four-skill shape above; add a
  `prototype` section; note it can run standalone or as a side-branch off
  `design-build` Open Questions; keep the existing install instructions.
- **design-build SKILL.md.** In the Open Questions handling, add one line: when
  an Open Question is empirical ("does this state model hold up?", "which
  layout?"), note that `/prototype` can resolve it. This is a *mention*, not a
  handoff — `design-build`'s "Don't push toward design-loop or parallel-build"
  guardrail stays intact; `prototype` is named the same way, not auto-invoked.
- **Trigger boundaries.** `prototype` fires on prototype / play / try-designs
  language and `/prototype`. The other three skills keep their existing "skip
  for exploratory throwaway code" exclusions, which now point at `prototype`
  by name. No trigger collides with `/design-build`, `/design-loop`,
  `/parallel-build`, or `/dt-session-audit`.
- **No auto-invocation.** No skill calls another. Danny decides each transition,
  consistent with how the pack already composes.

## Manifest & Versioning

- `plugin.json` and `.claude-plugin/marketplace.json`: bump `0.1.3 → 0.1.4`
  (additive change, pre-1.0).
- Both `description` strings enumerate the skills — add `prototype` to each.
- `marketplace.json` `keywords`: add `prototype` if it adds discovery value.
- Stays a single-plugin marketplace; no new plugin entry.

## Acceptance Criteria

- `skills/prototype/{SKILL.md,LOGIC.md,UI.md}` exist; SKILL.md frontmatter is
  valid (`name`, `description`) and matches the other skills' style.
- The skill routes LOGIC vs UI correctly and applies the three adaptations.
- `plugin.json` + `marketplace.json` bumped to `0.1.4`, descriptions updated.
- README updated: four-skill pipeline diagram + `prototype` section +
  unchanged install note.
- `design-build` SKILL.md references `/prototype` for empirical Open Questions,
  with its no-handoff guardrail intact.
- MIT attribution to `mattpocock/skills` present in commit message and README.
- Skill loads in Claude Code and the SKILL.md → LOGIC.md/UI.md sibling reads
  resolve.

## Open Questions

- **Capture loop across locations.** Adaptation 1 step 1 prints paste-text
  instead of editing the workspace plan. Is print-and-paste good enough, or
  should the skill write a verdict file into the code repo that Danny later
  carries into the plan? Resolve the exact mechanism.
- **Version bump.** `0.1.4` (additive) vs `0.2.0` (new skill = minor). Pack is
  pre-1.0; pick one convention and apply it.
- **Sub-files vs flattening.** If Claude Code does not reliably surface
  `LOGIC.md`/`UI.md` as readable siblings of `SKILL.md`, fall back to one
  `SKILL.md` with both branches inline. Confirm before authoring.
- **`/prototype` slash command.** Register a slash command to match the other
  skills, or rely on natural-language triggers only?
- **LOGIC TUI library.** Prescribe a specific cross-platform TUI library, or
  leave it project-driven? Prescribing aids consistency; leaving it open
  respects "match the project's conventions".
- **design-loop tier for this build.** Light (3 rounds) is the default; the
  capture-loop question may warrant complex (6 rounds). Danny picks at intake.

## Out of Scope

- Codex integration into `prototype` — it stays single-agent and lightweight.
- Auto-invocation or programmatic handoff between `prototype` and any other
  skill — all transitions remain Danny's call.
- A separate marketplace plugin entry — `prototype` ships inside the existing
  `danny-skills` plugin.
- A wholesale rewrite of upstream `LOGIC.md` / `UI.md` — this is an adaptation
  of their substance, not a from-scratch redesign.
- Changes to `parallel-build` or `dt-session-audit` beyond the manifest
  description string.

