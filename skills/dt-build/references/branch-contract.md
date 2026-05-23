# Branch Contract

Run branch:
- Authoritative state branch: `dt-build/<RUN_ID>`.
- Merge target default: `dev`.
- Optional alias may exist but is not the state carrier.

Chunk branches (multi-chunk milestones):
- `dt-build/<RUN_ID>/<milestone>-<chunk>`.
- Worktrees must remain under approved root and pass containment checks.

Commit boundaries:
- Milestone commits are scoped to milestone outputs.
- `.dt-build/<RUN_ID>/` artifacts are never added to milestone commits.
