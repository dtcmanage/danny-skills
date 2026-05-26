---
name: git-merge-feature
description: "Rebase a named feature branch onto dev then fast-forward merge it into dev and delete the branch. Use when a feature is complete and ready to land on dev. Trigger on /git-merge-feature [branch] or 'merge feature X to dev' or 'land feature X'."
---

# git-merge-feature — Rebase and Merge a Feature Branch into Dev

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).

If this skill has stricter domain-specific behavior, keep that stricter behavior; otherwise follow the shared baseline.


Takes a named feature branch, rebases it onto the latest `dev`, fast-forward merges it into `dev`, then deletes the branch. This is the clean, linear merge path — no merge commits.

## Input

The feature branch name. Can be the full name (`feature/nav-fix`) or just the suffix (`nav-fix` — the skill will resolve it).

## Steps

1. Identify the current repo root. If not inside a git repo, stop and say so.

2. Resolve the branch name. If the user gave a short name, check whether `feature/<name>` exists locally. If neither the exact name nor `feature/<name>` exists, stop and list the current local branches.

3. Ensure the feature branch has no uncommitted changes:
   ```
   git status
   ```
   If there are uncommitted changes on the feature branch, stop and ask Danny to commit or stash them first.

4. Pull latest `dev`:
   ```
   git checkout dev
   git pull origin dev
   ```

5. Rebase the feature branch onto `dev`:
   ```
   git checkout feature/<name>
   git rebase dev
   ```
   - If rebase conflicts: stop, report which files conflict, and wait for resolution. Do not proceed to merge until rebase is clean.

6. Fast-forward merge into `dev`:
   ```
   git checkout dev
   git merge --ff-only feature/<name>
   ```
   - If `--ff-only` fails (should not happen after a clean rebase): stop and report. Do NOT fall back to a regular merge or `--no-ff`.

7. Delete the feature branch:
   ```
   git branch -d feature/<name>
   ```

8. Report success: branch name merged, commit range landed, branch deleted.

## Rules

- Never use `git merge --no-ff` or `git merge` without `--ff-only`. If `--ff-only` fails, the rebase step was incomplete — rebase again, do not bypass.
- Never push `dev` to origin automatically after merging — that is a separate action Danny controls.
- Never delete the branch before confirming the merge succeeded.
- If rerere is not enabled globally, note it after a successful merge and suggest: `git config --global rerere.enabled true`.
