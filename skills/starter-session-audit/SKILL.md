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

### D. New Context

You shared a fact about yourself, your work, or your world that Cowork didn't previously know. Contact details, schedules, relationships, project updates, or anything that changes how Cowork should approach future tasks.

**What to look for:** Information that would help Cowork in a future session if it remembered it.

**Example:** "My rent went up to $2,600 starting next month." "Sarah is my new manager."

## Step 3: Filter Against What's Already Saved

For each finding from Step 2, check whether it's already captured in the workspace files you loaded in Step 1. Skip anything that's already written down. Only surface genuinely new findings.

## Step 4: Present Findings

Present each finding in this format:

```
**[Number]. [What happened]**

- **The rule/fact:** [Exact wording to save, written as a clear instruction or statement]
- **Where it goes:** [File path and section name]
- **Why:** [One sentence on why this matters for future sessions]
```

Group findings into two categories:

**Recommend (apply unless you object):** Clear-cut findings where the right action is obvious.

**Your call:** Findings where there's a judgment call or where you might want to phrase the rule differently.

If there are no findings, say so: "Clean session. Nothing new to capture." Don't manufacture findings.

## Step 5: Apply Approved Changes

After you approve (all, some, or none), write the approved changes to the appropriate files. For each change, confirm what was written and where.

**Important:** Never write changes without approval. Always present findings first and wait.
