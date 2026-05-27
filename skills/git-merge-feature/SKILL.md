---
name: git-merge-feature
description: "Rebase a named feature branch onto dev then fast-forward merge it into dev and delete the branch. Use when a feature is complete and ready to land on dev. Trigger on /git-merge-feature [branch] or 'merge feature X to dev' or 'land feature X'."
---

# git-merge-feature — Rebase and Merge a Feature Branch into Dev

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).


Takes a named feature branch, rebases it onto the latest `dev`, fast-forward merges it into `dev`, then deletes the branch. This is the clean, linear merge path — no merge commits.

## Input

The feature branch name. Can be the full name (`feature/nav-fix`) or just the suffix (`nav-fix` — the script resolves it).

## Procedure

1. Confirm the working directory is inside a git repo. If not, stop and say so.

2. Run the deterministic merge script from this skill:

   ```powershell
   pwsh -NoProfile -File skills/git-merge-feature/scripts/merge-feature.ps1 -Branch "<name>" -Json
   ```

   The script:
   - resolves the branch (tries `<name>` then `feature/<name>`),
   - blocks if the working tree on the feature branch has uncommitted changes,
   - checks out `dev` and runs `git pull origin dev`,
   - invokes the repo-level `scripts/git/rebase-onto-dev.ps1` to rebase,
   - runs `git merge --ff-only` from `dev` (no `--no-ff` fallback),
   - deletes the local feature branch on success,
   - emits a JSON summary with `commit_range`, `branch_deleted`, and `status`.

3. Parse the JSON summary and report:
   - the resolved branch name,
   - the commit range that landed on `dev`,
   - whether the branch was deleted.

4. If the script returns an error:
   - **Uncommitted changes**: ask Danny to commit or stash, then retry.
   - **Rebase conflict**: the repo is mid-rebase; resolve or `git rebase --abort`, then retry.
   - **ff-only merge failed**: do NOT fall back to a regular merge. Re-run the script (it will re-rebase).

5. If rerere is not enabled globally, suggest after a successful merge: `git config --global rerere.enabled true`.

## Rules

- Never use `git merge --no-ff` or `git merge` without `--ff-only`. If `--ff-only` fails, the rebase was incomplete — re-run, do not bypass.
- Never push `dev` to origin automatically after merging — that is a separate action Danny controls.
- Never delete the branch before confirming the merge succeeded (the script enforces this).
- Pass `-SkipPull` only when Danny has explicitly already pulled `dev`.
