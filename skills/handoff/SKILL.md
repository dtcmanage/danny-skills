---
name: handoff
description: "Compact the current session into a single-use, paste-ready starting prompt for a fresh session, save it to the project's _handoffs folder, then run a session audit. Trigger when Danny says '/handoff', 'hand this off', 'write a handoff', 'wrap this up for next time', or 'set up the next session'. Do not use for capturing memory or preferences mid-session - that is starter-session-audit's job."
argument-hint: "What should the next session focus on?"
---

# Handoff

Produce a self-contained handoff that lets a fresh session resume this work without re-reading the current conversation. The handoff is a starting prompt Danny can paste — or point a fresh session at — to pick up cleanly.

Run the steps in order. The handoff is written and reported **before** the session audit, so momentum is captured first.

## Step 1: Locate the project

Identify the root folder of the project this session worked on — for a code repo, the repo root; otherwise the workstation folder. If no project is apparent from the session, ask Danny which project this belongs to before continuing.

Ensure the `_handoffs\` folder exists at that root. In PowerShell:

```
New-Item -ItemType Directory -Force "<project-root>\_handoffs"
```

## Step 2: Check for stale handoffs

List any existing files in `_handoffs\`. If any are present, they are handoffs generated earlier but never consumed. Tell Danny what is there and ask whether each is stale (delete it) or still a pending pickup (keep it). Never auto-delete — a lingering file may be a real pending handoff.

## Step 3: Write the handoff

Write the file with the Write tool to:

```
<project-root>\_handoffs\handoff-YYYY-MM-DD-<slug>.md
```

`<slug>` is a short kebab-case topic; the date is today. Never use `mktemp` or any bash temp-file command — this is a Windows/PowerShell environment.

Write it as a starting prompt, not a status report. Use this structure:

- **Your task** — one paragraph: what the next session should accomplish. If Danny passed arguments, treat them as the focus and shape this section around them.
- **Current state** — what is done and where things stand right now.
- **Next steps** — concrete, ordered actions.
- **Key files & artifacts** — paths and URLs with a one-line note each. Reference PRDs, plans, ADRs, issues, commits, and diffs by path; do not duplicate their content.
- **Decisions & gotchas** — choices already made and traps to avoid.
- **Suggested skills** — skills the next session should invoke, if any.

End the file with this line, with the real absolute path filled in:

> This is a single-use handoff. Once you have absorbed the context above, delete this file (`<absolute path>`) before doing anything else.

## Step 4: Report

Print the bare absolute path of the handoff file on its own line, followed by a one-line command to open it:

```
ii "<absolute path>"
```

## Step 5: Run the session audit

After the handoff is written and reported, invoke the `starter-session-audit` skill to capture any uncaptured corrections, preferences, and decisions from the session.
