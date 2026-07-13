---
name: git-sync-features
description: "Rebase all active feature branches onto main at the start of a session. Use when there are multiple feature branches in a repo and you need to sync them before starting work. Trigger on /git-sync-features or 'sync feature branches' or 'sync all features'."
metadata:
  version: 0.1.1
---

# git-sync-features — Sync All Feature Branches onto main

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).


Rebase every active feature branch onto `main`. Run at the start of any session where feature branches are in play, so each starts from current `main` before new work begins. Branches checked out in a separate worktree are skipped (git cannot rebase them from the primary tree) and reported.

## Procedure

1. Confirm the working directory is inside a git repo. If not, stop and say so.

2. Run the deterministic sync script from this skill:

   ```powershell
   pwsh -NoProfile -File skills/git-sync-features/scripts/sync-features.ps1 -Json
   ```

   The script:
   - records the starting branch,
   - checks out `main` and runs `git pull origin main`,
   - enumerates local branches (excludes `main`),
   - skips any feature branch checked out in another worktree (reports it under `skipped_worktree`),
   - invokes the repo-level `scripts/git/rebase-onto-main.ps1` per remaining feature branch,
   - stops at the first conflict (does NOT `--skip` silently),
   - returns to the starting branch on clean completion,
   - emits a JSON summary.

3. Parse the JSON summary and report:
   - which branches rebased cleanly,
   - which branches were skipped because they are checked out in a worktree,
   - which branch (if any) hit a conflict and which files conflicted,
   - the starting branch the script returned to.

4. If `conflicted_branch` is set, the repo is left mid-rebase on that branch. Surface this to Danny — do not silently abort. He resolves and re-runs the skill (the script picks up any branches that didn't get processed).

5. If rerere is not enabled globally, note it and suggest: `git config --global rerere.enabled true`.

## Rules

- Never use `git rebase --skip` to bypass a conflict — always surface it.
- Never rebase `main` itself.
- Never push the rebased feature branches automatically — rebasing rewrites history; only push if Danny explicitly asks after syncing.
- Pass `-SkipPull` only when Danny has explicitly already pulled `main` and wants to skip the network round-trip.
