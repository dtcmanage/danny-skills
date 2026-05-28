---
name: git-merge-feature
description: "Rebase a named feature branch onto main then fast-forward merge it into main and delete the branch. Use when a feature is complete and ready to land on main. Trigger on /git-merge-feature [branch] or 'merge feature X to main' or 'land feature X'."
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
   - emits a JSON summary with `commit_range`, `branch_deleted`, and `status`.

3. Parse the JSON summary and report:
   - the resolved branch name,
   - the commit range that landed on `main`,
   - whether the branch was deleted.

4. If the script returns an error:
   - **Uncommitted changes**: ask Danny to commit or stash, then retry.
   - **Rebase conflict**: the repo is mid-rebase; resolve or `git rebase --abort`, then retry.
   - **ff-only merge failed**: do NOT fall back to a regular merge. Re-run the script (it will re-rebase).

5. If rerere is not enabled globally, suggest after a successful merge: `git config --global rerere.enabled true`.

## Rules

- Never use `git merge --no-ff` or `git merge` without `--ff-only`. If `--ff-only` fails, the rebase was incomplete — re-run, do not bypass.
- Never push `main` to origin automatically after merging — that is a separate action Danny controls. (Pushing `main` IS the ship.)
- Never delete the branch before confirming the merge succeeded (the script enforces this).
- Pass `-SkipPull` only when Danny has explicitly already pulled `main`.
