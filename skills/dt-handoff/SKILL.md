---
name: dt-handoff
description: "Compact the current session into a single-use, paste-ready starting prompt for a fresh session, save it to the project's _handoffs folder, then run a session audit. Trigger when Danny says '/dt-handoff', 'hand this off', 'write a handoff', 'wrap this up for next time', or 'set up the next session'. Do not use for capturing memory or preferences mid-session - that is dt-session-audit's job."
argument-hint: "What should the next session focus on?"
---

# Handoff

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



Produce a self-contained handoff that lets a fresh session resume this work without re-reading the current conversation. The handoff is a starting prompt Danny can paste — or point a fresh session at — to pick up cleanly.

Run the steps in order. The handoff is written and reported **before** the session audit, so momentum is captured first.

## Step 0: Executable-next-phase gate (mandatory, runs before Step 1)

A handoff must point at an **executable next phase**, not bookmark something that isn't ready to be built. Before writing anything, identify the unmet prerequisites that would block the next session from starting work:

- Upstream dependencies that haven't shipped (a package version, a tag, a published artifact).
- Decisions Danny hasn't made (architecture choices, scope (a) vs (b), permission shape, vendor selection).
- Local-state work Danny hasn't done (credentials, key custody, account hardening, substrate setup).
- Verifications that haven't run (MFA confirmations, feature-availability checks).

If ANY of these are unmet, **do not write the handoff yet.** Instead:

1. **Surface every unmet prerequisite in chat**, in a numbered list. For each one, name it concretely and recommend a concrete solution or the specific check Danny can run to close it. Don't give a research paper — give the decision Danny needs to make and your recommendation.
2. **Wait for Danny to close them** or to explicitly say "park it anyway."
3. **Only then write the handoff** — and only for the now-executable next phase.

A handoff that says "start work when X, Y, and Z all become true" is the failure mode this gate exists to prevent. Burying conditions in artifacts wastes the next session's time and Danny's time. The chat is the right surface for unresolved conditions; the handoff is the right surface for ready-to-execute work.

If Danny explicitly says "park it pending external work" after seeing the prerequisites, that's the one path where a conditional handoff is acceptable — and the chat conversation that preceded it is the receipt that the conditions were surfaced first.

## Step 1: Locate the project and prep the handoff folder

Identify the root folder of the project this session worked on — for a code repo, the repo root; otherwise the workstation folder. If no project is apparent from the session, ask Danny which project this belongs to before continuing.

Pick a short kebab-case `<slug>` for today's handoff topic, then run the prep script:

```powershell
pwsh -NoProfile -File skills/dt-handoff/scripts/prep-handoff-folder.ps1 `
  -ProjectRoot "<project-root>" -Slug "<slug>" -Json
```

The script:
- creates `<project-root>\_handoffs\` if it does not exist,
- lists existing files in that folder (handoffs generated earlier but never consumed),
- returns deterministic target paths for today's handoff (`handoff_md_path`, `handoff_html_path`).

## Step 2: Check for stale handoffs

Read `existing_files` from the script output. If any files are present, surface them to Danny and ask whether each is stale (delete it) or still a pending pickup (keep it). Never auto-delete — a lingering file may be a real pending handoff.

## Step 3: Write the handoff

Write the markdown handoff with the Write tool to `handoff_md_path` from the script output (format: `handoff-YYYY-MM-DD-<slug>.md`). Never use `mktemp` or any bash temp-file command — this is a Windows/PowerShell environment.

Write it as a starting prompt, not a status report. Use this structure:

- **Your task** — one paragraph: what the next session should accomplish. If Danny passed arguments, treat them as the focus and shape this section around them.
- **Current state** — what is done and where things stand right now.
- **Next steps** — concrete, ordered actions.
- **Key files & artifacts** — paths and URLs with a one-line note each. Reference PRDs, plans, ADRs, issues, commits, and diffs by path; do not duplicate their content.
- **Decisions & gotchas** — choices already made and traps to avoid.
- **Suggested skills** — skills the next session should invoke, if any.

End the file with this line, with the real absolute path filled in:

> This is a single-use handoff. Once you have absorbed the context above, delete this file (`<absolute path>`) before doing anything else.

Also generate the HTML companion at `handoff_html_path` from the script output, optimized for skim review:
- summary cards (task, status, blockers),
- next-step sequence view,
- key files/artifacts table with quick links.

## Step 4: Report

Print the bare absolute paths of both handoff files on their own lines, followed by a one-line command to open the HTML review artifact:

```
ii "<absolute path to .html handoff>"
```

## Step 5: Run the session audit

After the handoff is written and reported, invoke the `dt-session-audit` skill to capture any uncaptured corrections, preferences, and decisions from the session.

