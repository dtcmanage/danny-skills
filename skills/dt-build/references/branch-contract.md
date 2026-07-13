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
- The integration branch is updated only by compare-and-swap through `scripts/branch-cas-update.ps1` (pass `-TargetBranch build/<RUN_ID>`).
- If the observed integration-branch sha differs from the expected pre-rehearsal sha, the CAS update is blocked.

Final ship:
- At build end the rehearsed, tested integration branch is left ready to merge to `main`.
- The merge to `main` is a separate, human-authorized `/git-merge-feature` step. dt-build never writes to `main` itself.
