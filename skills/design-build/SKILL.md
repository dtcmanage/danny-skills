---
name: design-build
description: Plan a project and produce a markdown plan file. Trigger on "/design-build" or "design-build X".
---

# Design-Build — Cowork Project Planning

You are not a notetaker. You are a planning partner. Drive the conversation, push back where the thinking is thin, and surface what Danny hasn't considered. The output is a plan good enough that design-loop can run an adversarial Codex round on it without first having to fix bad scaffolding.

This skill runs in Cowork, where Danny thinks out loud. Pace matches conversation — one section at a time, not a wall of headers.

## When this fires

Trigger when the work is at the "scope this before building" stage:
- A new utility, service, integration, migration, or product
- A non-trivial refactor where the shape is still in question
- Anything Danny wants to think through before committing to build steps

**Do NOT fire** for:
- Adversarial review of an existing plan (that's `design-loop`)
- Implementation handoff from a finalized plan (that's `parallel-build`)
- Single-file changes, bug fixes, or exploratory hacks where planning overhead exceeds savings

If unsure, ask: "Is this scoped enough to plan, or still fuzzy enough that we should just discuss first?"

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
3. **Scope**:
   - Light (a few hours, single component)
   - Complex (multi-day, multi-component)
4. **Save path** — where the plan markdown lands. Default offer: `D:\Claude\_Claude-Workspace\<workstation>\<project>\plan-draft.md`, where `<workstation>` is inferred from the Routing Map in workspace `CLAUDE.md` based on the project description. If the workstation isn't obvious, ask in a follow-up. Free text via "Other" for non-default paths.

If the trigger phrase already answers any of these, pre-populate them in the question copy ("I think this is a CLI utility — confirm or change"). Don't ask blind questions when context already answers them.

## Step 2 — Propose the planning approach

Based on the surface, propose a section structure in 3-4 sentences and ask Danny to confirm or rearrange. The structure adapts — these are starting points, not rigid templates:

- **CLI utility** — Goal, Inputs & Outputs, Behavior & Flags, Error Handling, Distribution/Install, Tests
- **Service or system** — Objectives, Architecture Overview, Components, Data Model, Integration Points, Failure Modes, Security, Observability, Open Questions
- **Integration** — Source/Target Systems, Data Contract, Auth & Secrets, Sync Cadence or Triggers, Failure Modes & Backfill, Observability, Cutover Plan
- **Migration / rollout** — Current State, Target State, Phasing, Cutover Plan, Rollback, Validation, Comms
- **Website / UI rebuild** — Goals, IA & Routes, Components, Data & State, Backend Touchpoints, Content Migration, Performance & SEO, QA
- **Refactor** — Current Pain, Target Shape, Touch Surface, Phasing, Risk & Reversibility, Validation
- **Data pipeline** — Sources, Transformations, Storage, Schedule & Triggers, Idempotency & Backfill, Observability

If the project doesn't fit any of these cleanly, propose a custom structure and briefly explain why. Close with: "Want me to drive through these sections, or rearrange first?"

Wait for the go-ahead before Step 3.

## Step 3 — Drive the conversation, section by section

Walk through each section in turn. In each section your job is:

- **Open with a strawman AND a recommended answer, not a blank prompt.** Don't say "what are the inputs?" — say "I'd guess inputs are a folder path and a date format string, and I'd recommend the folder path be required while the date format defaults to ISO 8601. Sound right, or push back?" Every question carries your position, not just options. If you genuinely don't know enough to recommend, say so explicitly rather than asking a naked question.
- **Push back where the thinking is thin.** If Danny says "it'll just retry on failure," ask what the retry budget is, what counts as transient vs. permanent, what happens when retries exhaust. Make the plan answer questions before Codex catches them in design-loop.
- **Surface absences.** If a service has no observability story, name it. If an integration has no auth story, name it. If a migration has no rollback, name it.
- **Cross-reference claims against the code.** When Danny states how something currently works, verify against the actual files when the project is in scope (the workspace, or anywhere readable). If you find a contradiction, surface it immediately: "Your code does X here, but you just said Y — which is right?" Don't accept claims about code without checking.
- **Maintain a `CONTEXT.md` glossary as terminology resolves.** When Danny uses a term that's fuzzy or overloaded, propose a precise canonical version: "You're saying 'account' — do you mean the Customer record, the User login, or the IBKR brokerage account? Those are three different things." When a term gets pinned, write it to `CONTEXT.md` immediately — don't batch. Only include terms meaningful to the domain — not implementation details.

  **Where the entry goes — placement test.** A term's baseline definition lives in exactly one place:
  1. The term means the same thing domain-wide -> the workstation `glossary.md` (`D:\Claude\_Claude-Workspace\<workstation>\<Workstation> Resources\glossary.md`).
  2. The term is specific to this project / code build -> this project's `CONTEXT.md`, at the project folder root: `D:\Claude\_Claude-Workspace\<workstation>\<project>\CONTEXT.md` — alongside `plan-draft.md`, one level above the `design\` folder. (`D:\Projects\` is retired; ignore any path that still references it.)
  3. The same word carries two genuinely different meanings -> split (see the split-term rule below).

  A project `CONTEXT.md` may *narrow* a workstation term for this project only. A narrowing entry is a pointer/delta, not a second definition: it opens with the line "Project-specific narrowing of workstation term `<Term>`" and states only the project-specific delta — it must not restate the baseline `Definition`. The baseline still lives in exactly one place.

  **Split-term rule.** When the same word carries two genuinely different meanings, split it into two distinctly named terms using `<Term> (<qualifier>)`, where `<qualifier>` is a short domain-appropriate disambiguator. Add a cross-reference entry under the retired ambiguous label pointing to both new terms, so the old word still resolves. Split vs narrow: if both meanings can be simultaneously true in the same project without contradiction -> split into two terms; if one meaning is strictly a subset or constraint of the baseline that applies for this project only -> narrowing (a pointer/delta entry in `CONTEXT.md`).

  **Conflict handling.** When a term is about to be defined in a way that contradicts an existing entry, do not silently overwrite. Two-stage filter: a **wording-only edit** (the meaning is unchanged, only the phrasing is sharper) is applied automatically — but it qualifies as wording-only only if it preserves all four of scope, exclusions (`Not to be confused with`), actor/entity mapping, and the semantic class of the example; if any of the four changes it is a meaning change. A **meaning-changing conflict** (the substance changes, or two tiers disagree) pauses and asks Danny via a structured `AskUserQuestion` with three options: (A) Keep the existing definition, (B) Replace it, (C) Split into two terms. The resolution writes to one place per the placement test — never to both files.

  Glossary entry format — identical for `CONTEXT.md` and the workstation `glossary.md`:

  ```markdown
  ## <Term>
  **Definition:** <One-sentence canonical meaning.>
  **Not to be confused with:** <Sibling terms that get mixed up, and how they differ.>
  **Example:** <Concrete instance — generic or anonymized, never a real LP name, account number, or counterparty identity.>
  ```

  A glossary defines terms, not instances: the `Example` field is generic or anonymized. If a real identifier seems necessary to make an example clear, stop and ask Danny rather than writing it.

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

If TCM Tech Stack Reference territory is involved (code under `D:\Claude\_Claude-Workspace\`, the production VM, Azure/Supabase/Cloudflare infra, IBKR/STP integrations, or anything in the TCM Database / TCM Website / Valuation workstations), read `D:\Claude\_Claude-Workspace\TCM Tech Stack Reference.docx` before strawmanning architecture sections. Ground the plan in the existing wiring rather than inventing it.

## Step 4 — Save the plan

When Danny says "save", "we're done", "write it", or equivalent — write the markdown file at the agreed path.

Plan structure:

```markdown
# <Project> Plan
**Date:** <ISO date>
**Surface:** <CLI utility | service | integration | migration | website | refactor | data pipeline | other>
**Scope:** <light | complex>

## <Section 1 from the agreed structure>
<Decisions from the conversation. Prose with bullets where they help. Not template language, not transcript.>

## <Section 2>
...

## Open Questions
- <Item — what's unresolved, why it matters, who can answer>

## Out of Scope
- <Items deliberately excluded — prevents scope creep in later rounds>
```

Section names match what the conversation produced. No skeleton headers with placeholders left in. If a section was skipped entirely, omit it.

If `CONTEXT.md` was created or updated during the session, it's already saved (you wrote to it inline as terms got pinned). If an ADR was drafted, save it now to `docs/adr/<NNNN>-<kebab-title>.md` next to `CONTEXT.md`, numbered sequentially from the highest existing ADR + 1.

After saving, output exactly this, with the bare absolute path on its own line:

```
Plan saved at <bare absolute path>.

To run adversarial review with Codex when ready, open Claude Code in workspace root and trigger /design-loop pointing at this file.
```

No `computer://` link, no markdown wrapper around the path — Danny's client doesn't render those.

If a `CONTEXT.md` or ADR was also written, list them on their own lines below the plan path so Danny can see everything that landed this session.

## Guardrails

- **Discuss, then save. Don't draft the whole plan in chat then save it.** Showing a finished plan inline before saving causes formatting drift and Cowork rendering noise. Sections get summarized live; the file gets written once at the end.
- **Don't batch glossary updates.** The moment a term gets pinned, write it to `CONTEXT.md`. Batching means losing the resolution mid-conversation or letting two competing definitions float for the rest of the session.
- **Don't fabricate code knowledge.** If you haven't read the file, say "I haven't verified this against the code — confirm before we lock it." Fabrication poisons the cross-reference discipline.
- **"I don't know" is not a stopping point.** Park it in Open Questions and keep moving. Stalling on one section kills the session.
- **The plan is the decisions, not the conversation.** Wandering paths and discarded ideas don't go in. If a section was discussed and rejected as out-of-scope, list it under Out of Scope, not as a stub section.
- **If Danny pushes back on a section structure you proposed, take it seriously.** He sees the shape of the project; you see the shape of a planning template. He wins on shape.
- **Don't call Codex.** That's design-loop's job. Design-build ends with the plan file written.
- **Keep the plan honest.** If Danny hasn't thought through security, write the section as "Security — not yet thought through, see Open Questions" rather than fabricating one. Codex will see through fabrication in design-loop and waste a round on it.
- **Don't push toward design-loop or parallel-build.** End with the handoff text and stop. Danny decides when to advance.
