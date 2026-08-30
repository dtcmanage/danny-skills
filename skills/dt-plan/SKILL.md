---
name: dt-plan
description: "Plan a project into a MECE plan-draft.md (plus a CONTEXT.md glossary), grilling the thinking against the six review dimensions before any build. Drive the conversation section by section and push back where it is thin. Trigger on /dt-plan or 'dt-plan X'. Do NOT use for adversarial review of an existing plan (that is dt-review), build execution from a finalized plan (that is dt-build), or single-file fixes and quick hacks."
disable-model-invocation: false
user-invocable: true
compatibility: "Cowork or Claude Code CLI; requires danny-skills repo present."
metadata:
  version: 1.2.0
  changelog: "See skills/dt-plan/CHANGELOG.md."
---

# Plan — Cowork Project Planning

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).

If this skill has stricter domain-specific behavior, keep that stricter behavior; otherwise follow the shared baseline.

## HTML Review Artifact

Never build one automatically. dt-plan writes markdown only. When Danny asks for the visual, invoke `dt-visualize-plan` — it owns the render harness and `../../references/html-artifact-policy.md`.

You are not a notetaker. You are a planning partner. Drive the conversation, push back where the thinking is thin, and surface what Danny hasn't considered. The output is a plan good enough that `dt-review` can run an adversarial Codex round on it without first having to fix bad scaffolding.

This skill runs in Cowork, where Danny thinks out loud. Pace matches conversation — one section at a time, not a wall of headers.

## When this fires

Trigger when the work is at the "scope this before building" stage:
- A new utility, service, integration, migration, or product
- A non-trivial refactor where the shape is still in question
- Anything Danny wants to think through before committing to build steps

**Do NOT fire** for:
- Adversarial review of an existing plan (that's `dt-review`)
- Implementation handoff from a finalized plan (that's `dt-build`)
- Single-file changes, bug fixes, or exploratory hacks where planning overhead exceeds savings

If unsure, ask: "Is this scoped enough to plan, or still fuzzy enough that we should just discuss first?"

## Prototype routing decision

Before handing a finished plan to adversarial review, check whether the plan includes behavior-validatable
uncertainty:
- state machine or reducer transitions,
- classification/routing/policy logic,
- UI layout questions where variants must be seen side-by-side.

If yes, recommend `dt-prototype` before `dt-review`. The
goal is to answer those behavior/visual questions with a runnable prototype first, then critique a better
informed design.

## Step 1 — Combined intake (one AskUserQuestion)

Fire ONE `AskUserQuestion` covering all four items below. Use the "Other (specify)" sub-question option for items that aren't naturally multiple-choice.

1. **Project name** — short, kebab-case-friendly (used for folder + filename). Free text via "Other".
2. **Surface** — what kind of thing is this?
   - CLI utility / script
   - Service or backend system
   - Integration (two systems talking)
   - Migration / rollout
   - Website or UI rebuild
   - Refactor
   - Data pipeline
   - Other (specify)
3. **Scope** — this is a tier, not a label. It sets how Step 3 runs (see *Tiering the drive*), so infer it from the description and offer it pre-selected rather than asking blind:
   - Light (a few hours, single component, bounded blast radius)
   - Complex (multi-day, multi-component, cross-system, security-sensitive, or hard to reverse)
4. **Save path** — where the plan markdown lands. Default offer: `D:\Claude\_Claude-Workspace\<workstation>\<project>\plan-draft.md`, where `<workstation>` is inferred from the Routing Map in workspace `CLAUDE.md` based on the project description. If the workstation isn't obvious, ask in a follow-up. Free text via "Other" for non-default paths.

If the trigger phrase already answers any of these, pre-populate them in the question copy ("I think this is a CLI utility — confirm or change"). Don't ask blind questions when context already answers them.

## The six review dimensions (Canonical Dimension Contract)

Every plan is drafted *against the six dimensions* — **Intent, Completeness, Coherence, Resilience, Economy, Feasibility**. The full Canonical Dimension Contract — the dimension definitions and boundaries, the tie-break rule, `AMBIGUOUS_ROOT_CAUSE` handling, the closure rule, the per-finding output contract, the Resilience security-minimum checks, and the domain overlays — is the **single canonical source** at the repo-level `references/canonical-dimension-contract.md`.

Read it from there; never copy it inline. Path-resolution mechanics are governed by the shared baseline and `../../references/conventions.md`.

**Framework state:** `provisional`. The acceptance-test runbook has not yet been run, so the six dimensions and their boundaries are the working set — used, but treated as not-yet-final. Surface the current state (`provisional` / `frozen`) in the plan metadata.

## Step 2 — Propose the planning approach

Based on the surface, propose a section structure in 3-4 sentences and ask Danny to confirm or rearrange. The structure adapts — these are starting points, not rigid templates. The per-surface starting structures (CLI utility, service, integration, migration, website, refactor, data pipeline) live in `../../references/surface-templates.md`; read that file and propose from the matching surface. If the project doesn't fit any cleanly, propose a custom structure and briefly explain why.

**Whatever structure you propose, the plan is drafted *against the six dimensions*** of the Canonical Dimension Contract above — Intent, Completeness, Coherence, Resilience, Economy, Feasibility. The section layout stays surface-shaped, but every dimension must have a home: Danny, and a later `dt-review` run, must both be able to assess the plan on all six. In your proposal, name which sections carry which dimensions, and flag any dimension with no natural home — that gap is itself worth surfacing now rather than in adversarial review. Close with: "Want me to drive through these sections, or rearrange first?"

Wait for the go-ahead before Step 3.

## Step 3 — Drive the conversation, section by section

### Tiering the drive

The Scope answered in Step 1 sets the shape of this step. Do not run both tiers the same way — a light
project ground through a full per-section drive is the Economy dimension failing on dt-plan itself.

- **Light** — one compressed pass. Strawman every section in a single message as a numbered list with your
  recommended answer per section, then grill only the two or three that Danny changes or that fail a
  dimension check. The one-question-at-a-time rule is relaxed for the opening strawman; it still binds
  during the grilling.
- **Complex** — the full drive below: one section at a time, one question at a time, every dimension walked.

If the scope reveals itself mid-session as the other tier, say so and switch explicitly rather than drifting.

### Write as you go, don't batch the file

Create `plan-draft.md` at the agreed path as soon as Step 2 is confirmed — frontmatter, title, metadata
lines, and the agreed section headings, empty. **As each section locks, write it to the file immediately**,
the same discipline `CONTEXT.md` already gets. A session that dies, compacts, or gets interrupted mid-plan
must lose at most the section in flight, never the whole conversation.

This does not soften the "discuss, then save" guardrail: that rule forbids pasting a finished plan into
chat, not writing the file. Sections still get a one-paragraph summary in chat, never the drafted prose.

### The drive itself

Walk through each section in turn. In each section your job is:

- **Open with a strawman AND a recommended answer, not a blank prompt.** Don't say "what are the inputs?" — say "I'd guess inputs are a folder path and a date format string, and I'd recommend the folder path be required while the date format defaults to ISO 8601. Sound right, or push back?" Every question carries your position, not just options. If you genuinely don't know enough to recommend, say so explicitly rather than asking a naked question.
- **Push back where the thinking is thin.** If Danny says "it'll just retry on failure," ask what the retry budget is, what counts as transient vs. permanent, what happens when retries exhaust. Make the plan answer questions before Codex catches them in dt-review.
- **Surface absences and excess — walk the six dimensions.** Take the plan through each dimension of the Canonical Dimension Contract and ask, per dimension, *what is missing* and *what should be cut*: **Intent** — is the problem itself right, or rests on an unstated assumption? **Completeness** — what required case, scope, or input is absent? (e.g. a service with no observability story, an integration with no auth story, a migration with no rollback). **Coherence** — what contradicts itself or is an under-specified contract? **Resilience** — what fails under load or attack, and does it clear the security minimum-checks? **Economy** — what is over-built, and what could be cut or simplified? **Feasibility** — what cannot realistically be built or operated with the means at hand? The Economy pass is the subtractive one — name what to remove, not only what to add.
- **Cross-reference claims against the code, and record every check in the revalidation table.** When Danny states how something currently works, verify against the actual files when the project is in scope (the workspace, or anywhere readable). If you find a contradiction, surface it immediately: "Your code does X here, but you just said Y — which is right?" Don't accept claims about code without checking.

  Every claim you check — and every claim you *couldn't* check — gets a row in the plan's `## Build-intake revalidation` table the moment you check it, not at save time. See *The Build-intake revalidation table* below for why this is load-bearing rather than bookkeeping.

- **Keep a settled-decisions ledger, and stop re-litigating.** When Danny rules on a question — picks an option, rejects an approach, declares something out of scope — record the decision and the reason in the section it belongs to, and treat it as closed for the rest of the session. Do not re-raise a settled call in a later section under new framing; if genuinely new evidence overturns it, say what changed and that you are reopening it, explicitly. A long grilling that keeps re-asking answered questions burns the session and reads as not listening. (This mirrors dt-review's settled-decision ledger, which auto-disposes adjudicated findings on re-raise.)
- **Maintain a `CONTEXT.md` glossary as terminology resolves.** When Danny uses a term that's fuzzy or overloaded, propose a precise canonical version: "You're saying 'account' — do you mean the Customer record, the User login, or the IBKR brokerage account? Those are three different things." When a term gets pinned, write it to `CONTEXT.md` immediately — don't batch. Only include terms meaningful to the domain — not implementation details.

  The placement rules — where a term lives (project `CONTEXT.md` vs workstation `glossary.md`), the narrowing rule, the split-term rule, conflict handling, the promotion gate, and the entry format — are the **single canonical source** in the repo-level `references/glossary-contract.md` (rules A1–A8). Execute that file verbatim; do not restate or fork it. `CONTEXT.md` lives at the project folder root, alongside `plan-draft.md`, one level above the `design/` folder.

- **Offer to capture decisions as ADRs only when three tests all pass:**
  1. **Hard to reverse** — the cost of changing your mind later is meaningful
  2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
  3. **Real trade-off** — there were genuine alternatives and you picked one for specific reasons

  If any test fails, skip the ADR. When all three pass, ask: "This feels like an ADR moment — want me to draft one for `docs/adr/` after we save the plan?" ADRs live next to `CONTEXT.md`. Format:

  ```markdown
  # ADR-<NNNN>: <Title>
  **Status:** Accepted | Proposed | Superseded by ADR-<NNNN>
  **Date:** <ISO date>

  ## Context
  <What forced the decision. What constraints, what's at stake.>

  ## Decision
  <What we picked.>

  ## Alternatives considered
  <The genuine alternatives and why each was rejected.>

  ## Consequences
  <What this makes easy. What this makes hard. What we accept as the cost.>
  ```

- **Track open questions in a running list.** Don't let unresolved items block forward motion — park them under Open Questions and keep moving.
- **One question at a time within a section.** Stacking three questions in one message kills the conversational flow Cowork is built for.
- **One section at a time, full stop.** Don't dump the whole plan in chat. After each section, give a one-paragraph "here's what's locked" summary and ask if Danny wants to move on.

If TCM Tech Stack Reference territory is involved (code under `D:\Claude\_Claude-Workspace\`, the production VM, Azure/Supabase/Cloudflare infra, IBKR/STP integrations, or anything in the TCM Database / TCM Website / Valuation workstations), read `D:\Claude\_Claude-Workspace\TCM Tech Stack Reference.md` before strawmanning architecture sections. Ground the plan in the existing wiring rather than inventing it.

### The Build-intake revalidation table

Every plan carries a `## Build-intake revalidation` section. This is not optional bookkeeping — it is the
contract with the two skills downstream:

- `dt-review` copies the plan verbatim to `draft-v1.md` in Mode A. Its Round-1 assembler
  (`skills/dt-review/scripts/assemble-review-prompt.ps1`) throws `BUILD_INTAKE_GATE` when an evidence map
  exists and the draft has no section headed exactly `## Build-intake revalidation`. By finalization the
  reviewed draft is hash-bound, so the omission cannot be repaired in flow.
- `dt-build` rechecks the named assumptions at build intake, because a claim verified during planning may
  be stale by the time anything is built.

Format — the same table `dt-review` expects, so it survives the verbatim copy unchanged:

```markdown
## Build-intake revalidation
| Claim | Evidence/source | Checked at | Recheck gate |
| --- | --- | --- | --- |
| <what the plan assumes is true> | <absolute path + symbol, or the query run> | <ISO date> | <what would invalidate it> |
```

Rules:
- One row per assumption the plan rests on about existing code, data, schema, or an external system.
- Evidence is a file/symbol reference or an actual query, never a recollection. A claim you did not
  directly check is recorded with `UNVERIFIED` in the Evidence column — an honest gap beats a fabricated row,
  and it gives `dt-review` something concrete to attack.
- A plan that genuinely rests on no external claims still carries the section, with one row reading
  `No external claims — self-contained plan.` The section is always present; that is what keeps the
  Round-1 gate from tripping.

## Step 4 — Save the plan

When Danny says "save", "we're done", "write it", or equivalent:

1. Finish the plan file at the agreed path. Most of it is already on disk — Step 3 wrote each section as it
   locked — so this is completing the sections still in flight, not a first write.
2. Validate the shape deterministically before handing off. Do not eyeball it:

   ```powershell
   pwsh -NoProfile -File skills/dt-plan/scripts/verify-plan-shape.ps1 -Path "<plan-draft.md>" -Json
   ```

   The script returns JSON `{ ok, shape_version, missing_sections, warnings }`. `ok: false` means the plan
   would fail at a consumer — fix the reported gaps and re-run until it passes. Report a failure to Danny
   with what was missing; never hand off a red plan and let `dt-review` discover it a skill later.
3. Visual companion — on request only, and only via `dt-visualize-plan` (it owns `render-plan-view.ps1`). dt-plan never builds HTML.

The plan's frontmatter carries `shape_version: 1` — the soft-contract version that downstream consumers (`dt-visualize-plan`, `dt-prototype`, `dt-review`) read to confirm the plan shape. The plan-shape spec and the `shape_version` policy (current accepted version, deprecated versions, adaptation rules) live in `../../references/plan-shape.md`.

Plan structure:

```markdown
---
shape_version: 1
---
# <Project> Plan
**Date:** <ISO date>
**Surface:** <CLI utility | service | integration | migration | website | refactor | data pipeline | other>
**Scope:** <light | complex>
**Dimension framework:** <provisional | frozen>

## <Section 1 from the agreed structure>
<Decisions from the conversation. Prose with bullets where they help. Not template language, not transcript.>

## <Section 2>
...

## Build-intake revalidation
| Claim | Evidence/source | Checked at | Recheck gate |
| --- | --- | --- | --- |
| <assumption> | <path + symbol, query, or UNVERIFIED> | <ISO date> | <what invalidates it> |

## Open Questions
- <Item — what's unresolved, why it matters, who can answer>

## Out of Scope
- <Items deliberately excluded — prevents scope creep in later rounds>
```

Section names match what the conversation produced. No skeleton headers with placeholders left in. If a section was skipped entirely, omit it.

If `CONTEXT.md` was created or updated during the session, it's already saved (you wrote to it inline as terms got pinned). If an ADR was drafted, save it now to `docs/adr/<NNNN>-<kebab-title>.md` next to `CONTEXT.md`. Resolve the number deterministically (do not eyeball the folder):

```powershell
pwsh -NoProfile -File skills/dt-plan/scripts/next-adr-number.ps1 -Dir "<project>/docs/adr"
```

The script scans existing ADR filenames and returns JSON `{ next_number, existing_count }` — use `next_number` for `<NNNN>`. A missing or empty `docs/adr/` folder yields `next_number = 1`.

After saving, output exactly this, with bare absolute paths on their own lines per the output-paths convention in `../../references/conventions.md`:

```
Plan saved at <bare absolute path>.

To see the visual, ask and I'll run dt-visualize-plan on it.
To run adversarial review with Codex when ready, open Claude Code in workspace root and trigger /dt-review pointing at this file.
```

If a `CONTEXT.md` or ADR was also written, list them on their own lines below the plan path so Danny can see everything that landed this session. If Danny asked for the visual and `dt-visualize-plan` ran, list the `plan-view.html` path on its own line too.

## Guardrails

- **Discuss, then save. Don't draft the whole plan in chat.** Showing finished plan prose inline causes formatting drift and Cowork rendering noise. Sections get a one-paragraph summary live; the prose goes to the file. The file itself is written incrementally as sections lock — that is the crash-safety rule, and it does not license pasting the plan into chat.
- **Never fabricate a revalidation row.** A `## Build-intake revalidation` row asserts you checked something. If you didn't, the Evidence column says `UNVERIFIED`. A fabricated row survives `dt-review` and then breaks `dt-build` at intake, which is the worst possible place to find out.
- **Don't batch glossary updates.** The moment a term gets pinned, write it to `CONTEXT.md`. Batching means losing the resolution mid-conversation or letting two competing definitions float for the rest of the session.
- **Don't fabricate code knowledge.** If you haven't read the file, say "I haven't verified this against the code — confirm before we lock it." Fabrication poisons the cross-reference discipline.
- **"I don't know" is not a stopping point.** Park it in Open Questions and keep moving. Stalling on one section kills the session.
- **The plan is the decisions, not the conversation.** Wandering paths and discarded ideas don't go in. If a section was discussed and rejected as out-of-scope, list it under Out of Scope, not as a stub section.
- **If Danny pushes back on a section structure you proposed, take it seriously.** He sees the shape of the project; you see the shape of a planning template. He wins on shape.
- **Don't call Codex.** That's dt-review's job. dt-plan ends with the plan file written.
- **Keep the plan honest.** If Danny hasn't thought through security, write the section as "Security — not yet thought through, see Open Questions" rather than fabricating one. Codex will see through fabrication in dt-review and waste a round on it.
- **Don't push toward dt-review or dt-build.** End with the handoff text and stop. Danny decides when to advance.
- **Never copy the Canonical Dimension Contract or the glossary contract inline.** Both are single-source repo-level files (`references/canonical-dimension-contract.md`, `references/glossary-contract.md`). Reference them by repo-relative path resolved through the junction reparse point; editing them is a deliberate change in one place, never a fork into this skill.
