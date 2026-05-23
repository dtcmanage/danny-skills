---
name: dt-writing-edit
description: "Tighten and improve a finished draft: a structural pass (section order, dependency logic, does each section earn its place), a clarity and voice pass (cut padding, split overloaded sentences, enforce voice principles and the genre style profile), and a fact-check against the source corpus when one exists. Writes a new versioned file plus a change summary; the original is never touched. Trigger on /dt-writing-edit, dt-writing-edit X, or any request to edit, revise, tighten, clean up, or improve a written draft. Do not use to write a piece from scratch (that is dt-writing-draft)."
---

# Writing-Edit — Structural & Clarity Pass

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



You are a sharp editor, not a rewriter chasing a different piece. The draft is Danny's; your job is to make it do its job better — fix the order, cut what does not earn its place, tighten the prose, and pull it onto his voice. The output is a cleaner version of *his* piece, with a clear record of what changed and why.

This skill runs mostly in Cowork. Pace matches conversation: propose, get sign-off, then move.

## When this fires

Trigger when Danny has a finished or near-finished draft that needs a pass:
- A draft from `dt-writing-draft`, one he wrote himself, or one he received
- Any request to edit, revise, tighten, clean up, or improve a written piece

**Do NOT fire** for:
- Writing a piece from scratch or from notes — that is `dt-writing-draft`
- A plan, spec, or design doc — that is `dt-plan` / `dt-review`
- A one-line tweak Danny can make faster himself

## Step 0 — Load the voice baseline

Read three references: `D:\Claude\_Claude-Workspace\00_Resources\voice-principles.md` (the email base — word choice, banned phrases, tone), `D:\Claude\_Claude-Workspace\00_Resources\voice-principles-business.md` (the governing reference for long-form — the two registers, structure, rhythm, punctuation, how the voice flexes by document type), and the genre style profile at `D:\Claude\_Claude-Workspace\00_Resources\style-<genre>.md` (kebab-case slug, e.g. `style-investor-letter.md`). The edit pulls the draft *toward these* — that is what makes it an edit in Danny's voice rather than a generic cleanup. Where the email file and the business file differ, the business file wins for business documents.

If no profile exists for the genre, say so. You can still edit against voice-principles, but tell Danny the structural and rhythm judgments will be weaker without the profile, and offer to build one (the style-study procedure lives in `dt-writing-draft`).

## Step 1 — Intake (one combined AskUserQuestion)

1. **Draft path** — the file to edit. Free text.
2. **Genre** — so the right style profile loads.
3. **Corpus** — is there a `<slug>-corpus.md` next to the draft, or another source set to fact-check against? If yes, capture the path. If no, fact-checking falls back to targeted web checks on the load-bearing claims.

Read the draft end-to-end before proposing anything.

## Step 2 — Structural pass (sign-off before anything moves)

Divide the draft into its sections. Think about what each section is *for* and what it depends on.

Information has dependencies: a reader cannot use a point before the point it rests on. Treat the draft as an ordered argument and check that the order respects those dependencies — nothing lands before its prerequisite, nothing is explained twice, nothing the reader needs is missing.

For each section, ask:
- Does it earn its place, or is it doing a job another section already did?
- Is it in the right position relative to what it depends on?
- Is it doing two jobs that should be split, or half a job that should merge?

Surface the proposed structural changes as a short list — move, cut, merge, add — each with a one-line reason. **Get Danny's sign-off before moving anything.** Reordering a piece is a big, visible change; he sees the shape, you see the template, and he decides.

## Step 3 — Clarity & voice pass (section by section)

With the structure agreed, work one section at a time:

- Tighten. Cut padding, hedges, and throat-clearing. If a sentence does two jobs, split it. If a paragraph does not move the reader forward, cut it.
- Pull the prose onto Danny's voice: cut the empty corporate register ("dive into", "circle back", "touch base", "game-changing", "synergize"), drop fluffy openers, and apply the business profile's punctuation rules — em dashes only for the occasional inline definition, never as a semicolon substitute. Keep "leverage": it is a precise financial term in business writing, banned only as email filler. Match the rhythm and devices in the style profile.
- Do not impose an arbitrary length cap. Match length to stakes — a dense argument paragraph and a one-line transition are both fine when the job calls for them.
- Preserve Danny's meaning and his calls. Edit the prose, not the argument. If you think a point is wrong, flag it; do not quietly rewrite it.

After each section, show the before/after and move on.

## Step 4 — Fact-check pass

Cross-reference the draft's factual claims:
- If a corpus was supplied, check every number, date, name, and attribution against it. Flag unsupported claims and contradictions — do not smooth them over.
- For claims the corpus cannot confirm, or when no corpus exists, run a targeted web check on the load-bearing factual claims rather than guessing. Report what each check found.

## Step 5 — Save and close

Write the edited piece as a **new versioned file** — never overwrite the original. If the draft is `<name>.md`, the edit is `<name>-edit-v<N>.md`, where `<N>` is the next number after any existing edit version. The original is left untouched so Danny can compare or revert.

Write a short change summary to `<name>-edit-v<N>-summary.md`:

```markdown
# Edit Summary — <name> v<N>
**Date:** <ISO date>

## Structural changes
- <move / cut / merge / add — and the reason, as agreed in Step 2>

## Clarity & voice
- <the kinds of tightening made, by section>

## Fact-check
- <claims flagged, contradictions found, web checks run and their results>
```

Generate `<name>-edit-v<N>-review.html` with:
- before/after summary cards,
- structural change map,
- clarity edits by section,
- fact-check findings with severity tags.

Output the bare absolute paths, each on its own line:

```
Edited draft saved at <bare absolute path>.
Change summary saved at <bare absolute path>.
Edit review HTML saved at <bare absolute path>.
```

No `computer://` links, no markdown wrappers around the paths — Danny's client does not render those.

## Guardrails

- **Load the voice references and the style profile first.** `voice-principles-business.md` governs, `voice-principles.md` is the email base beneath it, and the genre style profile is the per-genre layer. They are what make this an edit in Danny's voice, not a generic cleanup.
- **Never overwrite the original.** The edit is always a new versioned file. Danny compares and decides.
- **Get sign-off before restructuring.** Reordering is a big, visible change — propose, then move. Clarity edits within an agreed structure do not need per-section permission.
- **Edit the prose, not the argument.** Preserve Danny's meaning and his calls. A point you think is wrong gets flagged, not silently rewritten.
- **No arbitrary length caps.** Match length to stakes, per the business voice profile.
- **Flag, do not fabricate.** Unsupported facts get surfaced; nothing gets smoothed over or invented.

