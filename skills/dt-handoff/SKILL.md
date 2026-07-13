---
name: dt-handoff
description: "Compact the current session into a single-use, paste-ready starting prompt for a fresh session, save it to the project's _handoffs folder, then run a session audit. Trigger when Danny says '/dt-handoff', 'hand this off', 'write a handoff', 'wrap this up for next time', or 'set up the next session'. Also owns handoff validation: trigger on 'validate the handoff X', 'validate the build X', 'was this handoff acted on?', or '-validate <handoff-path>' to audit a handoff against deterministic evidence. Do not use for capturing memory or preferences mid-session - that is dt-session-audit's job."
argument-hint: "What should the next session focus on?"
metadata:
  version: 0.2.1
---

# Handoff

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).

If this skill has stricter domain-specific behavior, keep that stricter behavior; otherwise follow the shared baseline.

## HTML Companion Policy

Do NOT generate the HTML companion automatically. Build it only when Danny explicitly asks. The render harness stays available; skipping it is the default.

When Danny does ask, follow `../../references/html-artifact-policy.md`:
- Keep the primary machine/edit artifact (the `.md` handoff).
- Emit a review-first `.html` artifact in the same folder (`handoff_html_path` from the prep script).
- Include visual structure (cards/tables) plus at least one flow/state visualization (Mermaid or SVG).
- Report both output paths in the final skill output.

## Consumption Convention (binding, applies to every intaker)

When any session or skill intakes a handoff — loads it as the starting prompt for the work it describes — the intaker moves the file to `_handoffs\consumed\` immediately after successfully loading it. This applies to every consumer of a handoff, not just dt-handoff: dt-build, dt-plan, plain sessions, anything. Moving (never deleting) keeps the file recoverable if the work is interrupted, and makes status deterministic:

- A handoff in `_handoffs\consumed\` (or `consumed\_archive\`) is **CONSUMED**.
- A handoff anywhere else in `_handoffs\` is **OPEN**.

`scripts\handoff-registry.ps1` reads status straight from this layout — no content parsing, no guessing. `-Prune` moves CONSUMED files older than 30 days into `_handoffs\consumed\_archive\`; nothing is ever deleted.



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

## Step 2: Adjudicate stale handoffs via the registry

Run the registry script against the project root:

```powershell
pwsh -NoProfile -File skills/dt-handoff/scripts/handoff-registry.ps1 `
  -Root "<project-root>" -Json
```

Use its output — do not run a manual ask-per-file loop. If there are OPEN handoffs other than today's, present them to Danny **once** as a single numbered table (name, created, age in days) with your recommendation per row (likely stale vs likely pending, based on age and what this session covered). Danny answers once — e.g. "the first three are stale, keep 4" — and you act on the whole answer:

- Stale or superseded → move to `_handoffs\consumed\` (it was overtaken by events; consumed-by-supersession still counts as consumed). Never delete.
- Still pending → leave in place.

Then run the script once more with `-Prune` to sweep CONSUMED files older than 30 days into `consumed\_archive\`.

## Step 3: Write the handoff

Write the markdown handoff with the Write tool to `handoff_md_path` from the script output (format: `handoff-YYYY-MM-DD-<slug>.md`). Never use `mktemp` or any bash temp-file command — this is a Windows/PowerShell environment.

Write it as a starting prompt, not a status report. Use this structure:

- **Your task** — one paragraph: what the next session should accomplish. If Danny passed arguments, treat them as the focus and shape this section around them.
- **Current state** — what is done and where things stand right now.
- **Next steps** — concrete, ordered actions.
- **Key files & artifacts** — paths and URLs with a one-line note each. Reference PRDs, plans, ADRs, issues, commits, and diffs by path; do not duplicate their content.
- **Decisions & gotchas** — choices already made and traps to avoid.
- **Execution setup** — include by default for any build-type handoff (the next session writes code, runs migrations, or touches prod). Keep it one tight paragraph in this shape:

  > Run this build as an orchestrator: delegate the work to named subagents (e.g. `builder`, `verifier`) and keep the orchestrator itself out of file-editing. Single-thread all prod writes and other irreversible steps — issue one instruction, wait for it to complete, verify the result against the live system, then send the next; never queue instructions across an irreversible boundary. Maintain a rolling `_build-state.md` checkpoint in the project root: update it after each completed step with what shipped, what was verified, and what is next, so an interrupted build can resume cold.

  Skip this section only for non-build handoffs (research, drafting, review).
- **Suggested skills** — skills the next session should invoke, if any.

End the file with these lines, with the real absolute path filled in:

> This is a single-use handoff. After you have successfully loaded it, move it (`<absolute path>`) into the `_handoffs\consumed\` subfolder next to it — that is the binding intake convention; the move marks it consumed while keeping it recoverable. Then keep working from what you loaded.

Generate the HTML companion only if Danny explicitly asks (see HTML Companion Policy above). When asked, write it to `handoff_html_path` from the script output, optimized for skim review:
- summary cards (task, status, blockers),
- next-step sequence view,
- key files/artifacts table with quick links.

## Step 4: Report

Print the bare absolute path of the `.md` handoff on its own line. If an HTML companion was explicitly requested and built, also print its path and a one-line command to open it:

```
ii "<absolute path to .html handoff>"
```

## Step 5: Run the session audit

After the handoff is written and reported, invoke the `dt-session-audit` skill to capture any uncaptured corrections, preferences, and decisions from the session.

## Validate Mode

Trigger: Danny says "validate the handoff X", "validate the build X", "was this handoff acted on?", or passes `-validate <handoff-path>`. In this mode, skip Steps 0-5 entirely — nothing new is written to `_handoffs\`; the job is to audit whether an existing handoff was actually acted on and built to spec.

Procedure:

1. **Read the handoff** and every design, plan, or roadmap document it references by path. These define the claims to check.
2. **Gather deterministic evidence** — do not judge from memory or from the handoff's own prose:
   - `git log --oneline --since=<handoff date>` in the relevant repo(s), plus targeted `git show`/diffs for commits that claim the work.
   - Existence (and content spot-checks) of every artifact the handoff names — files, folders, scripts, docs.
   - If the handoff or its referenced design names a verify command, test suite, or gate — run it and capture the result.
3. **Produce a per-claim table**, one row per task, artifact, or requirement the handoff specifies: the claim, how it was checked (the specific command, file read, or test run), the concrete evidence, and a verdict of **PASS / FAIL / UNVERIFIED**. UNVERIFIED means you could not check it — say why and what would close it.
4. **Never bucket a mismatch as out-of-scope or pre-existing.** Every discrepancy gets investigated and lands as a FAIL with a recommended fix, or is escalated explicitly with the specific reason. No silent buckets (global rule).
5. **Close the loop:** if the verdict is that the handoff was fully acted on, move it to `_handoffs\consumed\` per the Consumption Convention (if it is not there already). If it was not, leave it OPEN and summarize the gap list as the next session's work.

