---
name: git-merge-feature
description: "Rebase a named feature branch onto main then fast-forward merge it into main and delete the branch. Use when a feature is complete and ready to land on main. Trigger on /git-merge-feature [branch] or 'merge feature X to main' or 'land feature X'."
metadata:
  version: 1.2.0
  changelog:
    - "1.0.0 - Initial: resolve branch, rebase onto main, ff-only merge, delete branch via merge-feature.ps1."
    - "1.1.0 - Handle a feature branch checked out in a git worktree (the normal trunk-based case): the script now detects and merges it worktree-aware (rebase inside the worktree, ff-merge from the primary tree, remove the worktree before deleting the branch); SKILL.md documents the same fallback."
    - "1.2.0 - Post-merge purge hardening for dt-ship: new opt-in -PurgeWorktree switch makes worktree-remove/branch-delete failures hard errors (plus 'git worktree prune' after removal) so merged worktrees can never be silently left behind; default behavior without the switch is unchanged. JSON now always includes worktree_path, worktree_removed, and rerere_enabled (the rerere suggestion moved from prose re-checking into script output)."
---

# git-merge-feature — Rebase and Merge a Feature Branch into main

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).


Takes a named feature branch, rebases it onto the latest `main`, fast-forward merges it into `main`, then deletes the branch. This is the clean, linear merge path — no merge commits. `main` is live, so the feature must already pass its build, tests, and verification before this runs.

## Input

The feature branch name. Can be the full name (`feat/nav-fix`) or just the suffix (`nav-fix` — the script resolves bare `<name>`, then `feat/<name>`, then `feature/<name>`).

## Procedure

1. Confirm the working directory is inside a git repo. If not, stop and say so.

2. Run the deterministic merge script from this skill:

   ```powershell
   pwsh -NoProfile -File skills/git-merge-feature/scripts/merge-feature.ps1 -Branch "<name>" -Json
   ```

   The script:
   - resolves the branch (tries `<name>`, then `feat/<name>`, then `feature/<name>`),
   - blocks if the working tree on the feature branch has uncommitted changes,
   - checks out `main` and runs `git pull origin main`,
   - invokes the repo-level `scripts/git/rebase-onto-main.ps1` to rebase,
   - runs `git merge --ff-only` from `main` (no `--no-ff` fallback),
   - deletes the local feature branch on success,
   - emits a JSON summary with `commit_range`, `branch_deleted`, `worktree_path`, `worktree_removed`, `rerere_enabled`, and `status`.

   Pass `-PurgeWorktree` when the caller requires guaranteed cleanup (dt-ship always passes it): a failed worktree removal or branch deletion then becomes a hard error instead of a warning, and a successful removal is followed by `git worktree prune`. Without the switch, behavior is unchanged from 1.1.0 — existing callers are unaffected.

   When the resolved branch is checked out in a worktree (the normal trunk-based
   case — every feature lives in its own worktree), the script cannot check it
   out in the primary tree, so it switches to a worktree-aware path: it rebases
   inside that worktree, fast-forward merges from the primary tree, then removes
   the worktree before deleting the branch. The JSON summary sets
   `worktree_path` and `worktree_removed` in that case.

3. Parse the JSON summary and report:
   - the resolved branch name,
   - the commit range that landed on `main`,
   - whether the branch was deleted,
   - whether a worktree was removed (`worktree_path` / `worktree_removed`).

4. If the script returns an error:
   - **Uncommitted changes**: ask Danny to commit or stash, then retry.
   - **Rebase conflict**: the repo is mid-rebase; resolve or `git rebase --abort`, then retry.
   - **ff-only merge failed**: do NOT fall back to a regular merge. Re-run the script (it will re-rebase).
   - **Branch is checked out in a worktree** (`fatal: '<branch>' is already used by worktree at '<path>'`): expected under the trunk-based workflow. The updated script handles this automatically; if you are merging by hand, do it worktree-aware: (1) `git fetch origin`, then `git -C <worktree> rebase origin/main`; (2) from the primary tree on `main`, `git pull --ff-only origin main` then `git merge --ff-only <branch>`; (3) push only if Danny said ship; (4) after confirming the merge, `git worktree remove <worktree>` then `git branch -d <branch>`. Keep the ff-only guarantee; never remove the worktree or delete the branch before the merge is confirmed.

5. Read `rerere_enabled` from the JSON summary — do not re-run `git config` to check. If it is `false`, suggest after a successful merge: `git config --global rerere.enabled true`.

## Rules

- Never use `git merge --no-ff` or `git merge` without `--ff-only`. If `--ff-only` fails, the rebase was incomplete — re-run, do not bypass.
- Never push `main` to origin automatically after merging — that is a separate action Danny controls. (Pushing `main` IS the ship.)
- Never delete the branch before confirming the merge succeeded (the script enforces this).
- Pass `-SkipPull` only when Danny has explicitly already pulled `main`.
