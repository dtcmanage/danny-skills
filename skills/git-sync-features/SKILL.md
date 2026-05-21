---
name: git-sync-features
description: "Rebase all active feature branches onto dev at the start of a session. Use when there are multiple feature branches in a repo and you need to sync them before starting work. Trigger on /git-sync-features or 'sync feature branches' or 'sync all features'."
---

# git-sync-features — Sync All Feature Branches onto Dev

Rebase every active feature branch onto `dev`. Run at the start of any session where multiple feature branches are in play, so each starts from current `dev` before new work begins.

## Steps

1. Identify the current repo root. If the working directory is not inside a git repo, stop and say so.

2. Check out `dev` and pull latest:
   ```
   git checkout dev
   git pull origin dev
   ```

3. List all local branches that are not `main` or `dev`:
   ```
   git branch --list
   ```
   Filter to feature branches only (exclude `main` and `dev`).

4. For each feature branch, in any order:
   ```
   git checkout feature/<name>
   git rebase dev
   ```

   - If rebase completes cleanly: record success.
   - If rebase hits a conflict: stop, report which branch conflicted and which files, and ask for resolution before continuing to the next branch. Do not skip a conflicted branch silently.

5. After all branches are processed, return to the branch that was active at the start of the session (or `dev` if unclear).

6. Report a summary: which branches rebased cleanly, which (if any) conflicted and were paused.

## Rules

- Never use `git rebase --skip` to bypass a conflict — always surface it.
- Never rebase `main` or `dev` themselves.
- Never push the rebased feature branches automatically — rebasing rewrites history; only push if Danny explicitly asks after syncing.
- If rerere is not enabled globally, note it and suggest: `git config --global rerere.enabled true`.
