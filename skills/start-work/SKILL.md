---
name: start-work
description: "Classify a unit of code work as light/medium/heavy and set up the right git surface: ship on main, a feat/ branch, or a worktree, with a name that matches the work. Trigger on /start-work, 'start a feature', 'set up a branch/worktree for X', or at the start of non-trivial code work. FAST-PATH: when the surface is already named in plain language — 'start a feat/feature named X' (-> feat branch, checked out) or 'make a new worktree/tree named X' (-> worktree, created and entered) — skip classification and just run it. Do NOT use for planning-only (dt-plan) or a trivial one-line edit you will ship immediately."
metadata:
  version: 0.1.1
---

# start-work — Classify and Set Up the Git Surface for a Unit of Work

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).


Decide where a piece of work should live before it starts — on `main`, a `feat/` branch, or a worktree — and create that surface with a name that describes the work. The tier rubric is the shared one in `_Claude-Workspace\00_Resources\git-workflow.md`; this skill applies it, recommends, lets Danny confirm, then sets up the git surface deterministically. It is agent-neutral: Claude and Codex both invoke it and follow the same recommendation.

## Fast-path: surface already named (no classification)

When Danny's request **already names the surface and a slug**, skip the classify-score-confirm dance entirely — he has made the decision, so just run it. This is the common, token-light path.

Detect it from plain language:

- **"start a feat/feature named `<slug>`"**, "new feature `<slug>`", "cut a branch for `<slug>`" → **medium**. Runs the script with `-Tier medium`, which creates and checks out `feat/<slug>` in the current tree.
- **"make a new worktree/tree named `<slug>`"**, "new worktree `<slug>`", "spin up a tree for `<slug>`" → **heavy**. Runs the script with `-Tier heavy`, which creates the worktree at `..\<repo>-<slug>`, then this skill **enters it** (see step E below).

Fast-path procedure:

A. Derive the slug from Danny's words: kebab-case, lowercase, 2-4 words. If he gave an exact name (even a jokey one like `fuck-yo-mama`), use it verbatim — do not sanitize beyond kebab-casing. The script still rejects empty/over-generic slugs (`new`, `wip`, `fix`, …); if it does, ask for an intent name.

B. Pass `-Prefix fix` instead of `feat` only if Danny framed it as a bug fix ("fix branch", "hotfix").

C. Run the deterministic script directly — **no `AskUserQuestion`, no tier rationale**:

   ```powershell
   pwsh -NoProfile -File skills/start-work/scripts/start-work.ps1 -Tier <medium|heavy> -Name <slug> -Json
   ```

D. **Medium:** report the branch; you are now on it. Done.

E. **Heavy:** read `worktree_path` from the script's JSON, then **call the `EnterWorktree` tool with that path** so the session switches into the new worktree. (Only the agent can switch the session; the script can only create the tree on disk.) The script already copies gitignored per-worktree env files (`.env.local`, `supabase/.env.local`, …) into the new tree, reported as `copied_env`. Report the worktree path, the branch, and any copied env. Done.

If the request is vague about the surface ("start work on X", "I need to do Y") rather than naming feat-vs-worktree, fall through to the full **## Procedure** below and classify.

## Procedure

1. Confirm the working directory is a git repo. If not, stop and say so. Then capture the **launch guard**: run `git rev-parse --show-toplevel` and `git worktree list`. Isolation is a property of the working *tree* (a directory with its own HEAD), not the branch — a `feat/` branch in the shared primary tree gives zero isolation, because one directory has one HEAD and another session's checkout flips it out from under you. If another session shares this toplevel, treat the work as needing its own worktree.

2. **Apply the worktree gate FIRST, before scoring size.** A worktree is **mandatory — no judgment call** — if ANY of these holds:
   - an **agent** (Codex or a Claude sub-agent) is doing the work, rather than Danny editing interactively by hand;
   - **another session or worktree is, or may be, open** on this repo (concurrent / multi-session);
   - an **app or server runs from this checkout** (switching the primary tree to an in-progress branch hijacks a running app that auto-reloads templates/assets — it serves the new files against stale in-memory code and 500s);
   - the work touches a **prod-critical path** (NAV, money, DB schema/migration, auth, the live deploy).

   If the gate fires, recommend **heavy (worktree)** regardless of size; the primary tree stays pinned to `main`. In practice almost all agent-run work trips the gate — that is intended.

   **Only if the gate is clear** (a human editing by hand, solo, sequential, nothing else in flight, no app running) score by size against the rubric in `git-workflow.md`: **Scope** (one file / a few / many) decides light vs medium. Criticality still beats size.

3. **Derive a meaningful name** from the work's intent: kebab-case, 2-4 words, `feat/` (or `fix/` for a bug fix). Never generic. "add CSV export to the trade log" -> `trade-log-csv-export`.

4. **Recommend and confirm.** Present the recommended tier first with a one-line reason (which axis drove it) and the proposed name, and let Danny confirm or override either.
   - Claude: use `AskUserQuestion` with the recommended tier as the first option (labeled Recommended), the proposed name embedded in the branch/worktree option labels, and "Other" available for a custom name.
   - Codex: ask Danny directly, presenting the same three tiers and the proposed name.

5. **Set up the surface** with the deterministic script:

   ```powershell
   pwsh -NoProfile -File skills/start-work/scripts/start-work.ps1 -Tier <light|medium|heavy> -Name <slug> -Json
   ```

   - `light` — stays on `main`, no branch.
   - `medium` — creates and checks out `feat/<slug>` in the primary tree. Use only when Danny is editing interactively AND no app/server runs from this checkout; if an agent is doing the work or a live app reads from this tree, recommend `heavy` instead (see the overrides).
   - `heavy` — creates a worktree at `..\<repo>-<slug>` on `feat/<slug>`; the primary tree stays on `main`.

   Pass `-Prefix fix` for a bug fix. The script refuses to run with a dirty tree for `medium`/`heavy` (commit or stash first).

6. **Report** the tier, the one-line rationale, the branch, and the worktree path (if any). For `heavy`, tell Danny the worktree directory to work in.

## Rules

- Do not run for planning-only work (`dt-plan` produces docs, not code) or for a trivial one-line edit being shipped immediately.
- Names must describe the work; reject generic names and ask for intent.
- The tier rubric and naming convention live in `git-workflow.md` — do not redefine them here.
- The script never pushes and never merges; it only sets up the branch/worktree from a current `main`. Landing is `/git-merge-feature`.
- Agent-neutral: the recommendation and setup are identical whether Claude or Codex runs it.
