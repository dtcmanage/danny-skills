# Branch Contract

Run branch:
- The authoritative state carrier is the integration branch: `build/<RUN_ID>` by default.
- Cut it from the merge target (`main` by default) at intake.
- Never create a parent `dt-build/<RUN_ID>` ref. Git cannot store that leaf ref and child
  refs beneath `dt-build/<RUN_ID>/...` at the same time.

Chunk branches (multi-chunk milestones):
- `dt-build/<RUN_ID>/<milestone>-<chunk>`.
- Worktrees must remain under approved root and pass containment checks.

Commit boundaries:
- Milestone commits are scoped to milestone outputs.
- `.dt-build/<RUN_ID>/` artifacts are never added to milestone commits.

Integration-branch update:
- The integration branch is updated only by compare-and-swap through `<skill>/scripts/branch-cas-update.ps1` (pass `-RepoPath <project repo>` and `-TargetBranch build/<RUN_ID>`).
- If the observed integration-branch sha differs from the expected pre-rehearsal sha, the CAS update is blocked.

Accepted-chunk cleanup:
- After successful CAS, run `<skill>/scripts/cleanup-accepted-chunk.ps1 -RepoPath <project repo> -ChunkBranch <chunk-branch> -IntegrationBranch <integration-branch> -Json` for each accepted chunk, after its worker has terminated.
- The script requires the project repo explicitly and uses `git -C` throughout. It refuses `main`/`master`, verifies chunk ancestry against the integration branch (`CLEANUP_NOT_MERGED` on failure), and discovers the chunk worktree through `git worktree list --porcelain` unless `-WorktreePath` identifies that registered worktree.
- Uncommitted or untracked worktree changes stop cleanup with `CLEANUP_DIRTY_WORKTREE`. Clean worktrees are removed without force and pruned before `git branch -D` deletes the verified merged chunk. Do not substitute `git branch -d`, which checks against HEAD/upstream rather than the integration branch.
- JSON returns `pass`, `chunk_branch`, `integration_branch`, boolean `removed_worktree`/`deleted_branch`, `leftovers`, and nullable `error_code`. A surviving deregistered folder is reported in `leftovers` as `{code: worktree_dir_leftover, path: ...}` without failing cleanup; a still-registered worktree blocks branch deletion.

Final ship:
- At build end the rehearsed, tested integration branch is left ready to merge to `main`.
- The merge to `main` is a separate, human-authorized `/git-merge-feature` step. dt-build never writes to `main` itself.
