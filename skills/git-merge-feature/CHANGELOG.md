# git-merge-feature changelog

- 1.2.3 (2026-09-03): Branch delete falls back to -D only after proving main contains the branch tip, so a feature branch created with an origin/main upstream no longer fails the -PurgeWorktree purge before the push.

- 1.2.2 (2026-08-29): Worktree purge is resilient on Windows: retry transient delete denials, then distinguish still-registered (hard fail under -PurgeWorktree) from deregistered-with-leftover-directory (direct delete fallback, soft-continue with worktree_dir_leftover in JSON) so a locked directory no longer aborts the merge chain before branch delete.

- 1.2.1 (2026-07-12): Inherited the established pack-wide versioning policy and release gate.

- 1.2.0 (2026-07-05): Opt-in -PurgeWorktree makes post-merge worktree/branch cleanup a hard guarantee (dt-ship passes it); JSON gains worktree_path/worktree_removed/rerere_enabled; default behavior unchanged.
