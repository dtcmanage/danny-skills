---
name: starter-session-audit
description: "Simple end-of-session audit that scans for uncaptured corrections, preferences, and decisions, then proposes saving them to the right workspace file. Use this skill whenever you say 'audit this session,' 'session audit,' 'what did we miss,' or 'end of session check.' Works with any Cowork workspace that has a CLAUDE.md and MEMORY.md in the root folder."
---

# Starter Session Audit

A lightweight audit that runs at the end of any Cowork session. It catches things you told Cowork during the session that should be saved permanently so you never have to say them again.

## What This Skill Does

Two things, and only two things:

1. **Scans for uncaptured learnings.** Looks through the conversation for corrections you made, preferences you expressed, and decisions you stated that aren't already written in your workspace files.
2. **Proposes where to save each finding.** For each uncaptured learning, it tells you which file it belongs in, what section, and the exact wording. You approve or skip each one.

That's it. No file reorganization, no cleanup, no progress tracking. Just: "Did I learn anything this session that should be remembered?"

## The Core Principle: MEMORY.md Is a Snapshot, Not a Log

MEMORY.md is loaded into context at the start of every session. It must stay a **tight, canonical snapshot of current project state** — what's true now, what's done, what's next. It is not a changelog.

This means: when a session changes a project, you **revise that project's entry in place** — overwrite stale state with current state. You do **not** append a new narrative paragraph describing what changed this session. Detailed change history lives in git commits and project logs, not MEMORY.md.

Symptoms of doing it wrong (avoid these):

- A project entry that has grown into a 200+ word run-on paragraph.
- Multiple sentences narrating the same project's evolution across several sessions ("first we did X, then Y, then a follow-up did Z...").
- Commit hashes, migration numbers, and test counts piled up as a play-by-play. Keep only the *latest* such marker if it identifies current state; drop the trail.
- Verified-complete sub-tasks that no longer inform future work but are still listed.

A good MEMORY.md project entry is a few tight lines a future session can read in seconds and know exactly where things stand.

## Step 1: Discover Your Workspace

Find your workspace root dynamically. Look for a CLAUDE.md file in the mounted workspace folder. Read whatever workspace files exist. The audit adapts to your setup — it works whether you have one workstation or twenty.

Read these files if they exist:
1. Root CLAUDE.md (your standing instructions)
2. Root MEMORY.md (your accumulated context)
3. Any workstation CLAUDE.md and MEMORY.md files that were used during this session
4. Any project CLAUDE.md and MEMORY.md files that were used during this session
5. Any reference files that were loaded during this session (e.g., voice-principles.md)

## Step 2: Scan the Conversation

Go through the entire conversation from top to bottom. Look for these four signal types:

### A. Corrections

You fixed something Cowork produced. Maybe you changed a word, rewrote a sentence, adjusted a format, or said "no, do it this way instead." Each correction reveals a rule that Cowork should follow next time.

**What to look for:** Moments where you edited, rejected, or rewrote Cowork's output. Ask: what underlying preference or rule drove the change?

**Example:** You changed "Best regards" to "Thanks" on an email draft. The underlying rule: "Sign off with 'Thanks' for internal contacts."

### B. Explicit Preferences

You stated a preference directly. Words like "always," "never," "I prefer," "from now on," "I like it when," or "don't do that."

**What to look for:** Direct instructions about how you want things done, even casual ones.

**Example:** "I prefer bullet points over numbered lists." "Don't use exclamation points in subject lines."

### C. Decisions

You made a decision that affects future work. Chose one option over another, set a deadline, established a rule for a project, or resolved an ambiguity.

**What to look for:** Choices that should be recorded so Cowork doesn't re-ask the same question later.

**Example:** "Let's go with the $5,000 savings target." "Cancel the gym membership, keep Spotify."

### D. Project State Changes

The session moved a project forward, finished a task, changed an architecture, or otherwise changed the *current state* of something already tracked in MEMORY.md (or something new that should be).

**What to look for:** Work that changes what a future session needs to know about a project's status — a phase completed, a task done, a next step identified, a path or ID changed.

**Example:** "Phase 2 of the dashboard build is done; Phase 3 (renderer) is next." "The repo moved to a new path."

## Step 3: Filter Against What's Already Saved

For each finding from Step 2, check whether it's already captured in the workspace files you loaded in Step 1.

- **Corrections, preferences, decisions:** Skip anything already written down. Only surface genuinely new findings.
- **Project state changes:** Don't just check whether the project is mentioned — check whether the *current entry is still accurate*. If the session made the entry stale, the finding is a **revision** to that entry, not an addition.

## Step 4: Decide File and Shape for Each Finding

### Which file

Apply the two-test rule from CLAUDE.md:
- **Prescribes behavior** ("always," "never," "before X do Y") → CLAUDE.md, under the right section.
- **A fact about the world that can change** (status, paths, IDs, contacts, decisions) → MEMORY.md.

When unsure, say which file you think it belongs in and ask.

### How MEMORY.md entries are shaped

MEMORY.md changes are one of three operations — pick the right one:

1. **Revise in place** (the common case for project state changes). Rewrite the existing project entry so it reflects current reality. Replace stale status, prune verified-complete items that no longer inform future work, update changed paths/IDs. Do not append a new paragraph.
2. **Add a new entry** (only when the fact is genuinely new and has no home). Use the per-entry shape below.
3. **Append a discrete fact** to a stable list (a new contact, a new tool, a new credential location). Short list items, not narrative.

**Per-entry shape for any project in MEMORY.md.** Each project entry should fit this skeleton — keep it tight, a few lines, not a wall of text:

```
- **[Project name]** — [one-line identity: what it is, repo path, key IDs].
  - **Status:** [one line — the current phase/state in plain terms].
  - **Current state:** [the canonical snapshot — what is true right now, the
    facts a future session needs. Latest relevant markers only (one commit
    hash / migration number if it pins current state), not a trail of them].
  - **Next:** [what remains — the immediate next step(s) or open tasks].
  - **Done:** [optional — recently completed, verified items kept ONLY while
    they still give useful context. Drop an item once it no longer informs
    future work. This is not a permanent changelog.]
```

Not every entry needs every field — a dormant or low-priority project may just be identity + Status + Next. The point is consistency and tightness, not filling a template.

When you revise an entry, **rewrite the whole entry** to this shape. Carry forward every durable fact — paths, IDs, contacts, decisions, open tasks. Only cut the play-by-play change narrative and verified-complete noise. If you are unsure whether a detail is still relevant, **keep it and flag it** for Danny rather than deleting it.

Non-project MEMORY.md sections (who Danny is, the M365/Azure stack, service providers, etc.) are stable reference. Update a value in place when it changes; don't restructure them.

## Step 5: Present Findings

Present each finding in this format:

```
**[Number]. [What happened]**

- **Type:** [Correction / Preference / Decision / Project state]
- **Operation:** [for MEMORY.md: Revise in place / Add new entry / Append fact.
  For CLAUDE.md: Add rule]
- **Where it goes:** [File path and section / entry name]
- **The change:** [For a revision, show the rewritten entry — or the
  before/after of the part that changes. For an addition, show the exact
  text to add. For a CLAUDE.md rule, the exact wording.]
- **Why:** [One sentence on why this matters for future sessions]
```

For a **revise-in-place** finding, always show the proposed rewritten entry in full so Danny can see exactly what is being replaced and confirm nothing durable was dropped.

Group findings into two categories:

**Recommend (apply unless you object):** Clear-cut findings where the right action is obvious.

**Your call:** Findings where there's a judgment call — phrasing, or whether a detail should be pruned or kept.

If there are no findings, say so: "Clean session. Nothing new to capture." Don't manufacture findings.

## Step 6: Apply Approved Changes

After you approve (all, some, or none), write the approved changes to the appropriate files.

- For a **revise-in-place** change, replace the old entry with the rewritten one — do not leave both.
- After writing, confirm what was written and where, and note anything you kept-but-flagged as possibly stale so Danny can decide later.

**Important:** Never write changes without approval. Always present findings first and wait.
