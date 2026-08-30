Append-only friction notes. One line per invocation that hit friction.
2026-06-03 (tcm-database): merge failed on feat/margin-capture - branch checked out in a worktree, script tried to check it out in the primary tree ("already used by worktree"). Merged manually. -> v1.1.0 adds worktree-aware path.
2026-07-15 git-merge-feature: invoking the worktree-aware merge script from inside the target Windows worktree let the ff-only merge succeed but left an empty undeletable worktree directory and branch for manual cleanup.
