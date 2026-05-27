---
name: git-sync-features
description: "Rebase all active feature branches onto dev at the start of a session. Use when there are multiple feature branches in a repo and you need to sync them before starting work. Trigger on /git-sync-features or 'sync feature branches' or 'sync all features'."
---

# git-sync-features — Sync All Feature Branches onto Dev

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).


Rebase every active feature branch onto `dev`. Run at the start of any session where multiple feature branches are in play, so each starts from current `dev` before new work begins.

## Procedure

1. Confirm the working directory is inside a git repo. If not, stop and say so.

2. Run the deterministic sync script from this skill:

   ```powershell
   pwsh -NoProfile -File skills/git-sync-features/scripts/sync-features.ps1 -Json
   ```

   The script:
   - records the starting branch,
   - checks out `dev` and runs `git pull origin dev`,
   - enumerates local branches (excludes `main` and `dev`),
   - invokes the repo-level `scripts/git/rebase-onto-dev.ps1` per feature branch,
   - stops at the first conflict (does NOT `--skip` silently),
   - returns to the starting branch on clean completion,
   - emits a JSON summary.

3. Parse the JSON summary and report:
   - which branches rebased cleanly,
   - which branch (if any) hit a conflict and which files conflicted,
   - the starting branch the script returned to.

4. If `conflicted_branch` is set, the repo is left mid-rebase on that branch. Surface this to Danny — do not silently abort. He resolves and re-runs the skill (the script picks up any branches that didn't get processed).

5. If rerere is not enabled globally, note it and suggest: `git config --global rerere.enabled true`.

## Rules

- Never use `git rebase --skip` to bypass a conflict — always surface it.
- Never rebase `main` or `dev` themselves.
- Never push the rebased feature branches automatically — rebasing rewrites history; only push if Danny explicitly asks after syncing.
- Pass `-SkipPull` only when Danny has explicitly already pulled `dev` and wants to skip the network round-trip.
