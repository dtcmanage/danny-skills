# dt-ship changelog

- 0.1.3 (2026-08-29): Surface merge-feature's worktree_dir_leftover in the ship summary's purged list so a git-deregistered leftover directory is reported instead of failing the ship before push.

- 0.1.2 (2026-07-12): Inherited the established pack-wide versioning policy and release gate.

- 0.1.1 (2026-07-06): verify-hash URL probes now cache-bust and retry (5x15s) to absorb CDN edge lag, reporting probe_attempts; new preflight-cwd step fails fast before any mutation when the invoking shell sits inside the worktree slated for purge
- 0.1.0 (2026-07-05): Initial release: one-command close-out - gate, ff-only merge via git-merge-feature, push, .ship.json-driven deploy with live {HOST} resolution, proof-of-live (commit-hash probe + browser-smoke), guaranteed worktree/branch purge; fail-closed JSON summary.
