# Run-Artifact Lifecycle

Artifact classes:
- Ephemeral scratch: per-invocation prompt assembly files; delete after consume/verify.
- Retained audit record: reference-pack files, `reference-manifest.md`, `build-log-<RUN_ID>.md`.
- Retained execution provenance: redacted chunk output, model/effort/CLI provenance JSON, acceptance rows,
  and prompt/reference hashes. Full assembled prompts remain ephemeral.
- Retained decision record: `build-plan.md`, `build-state.md`, `build-decision-log.md`.
- Orchestration state (written only by `scripts/dt-job.ps1`, the watcher, and the launcher): `jobs/` (one
  `<job_id>.json` per job, a per-job `jobs/<job_id>/` folder holding `spec.json`, `stdout.log`, `stderr.log`,
  and `summary.json`, plus `events.jsonl`, `reads.jsonl`, `locks/`), `coordinator.lease`, `coordinator.lock`,
  `context-baseline.json`, `irreversible.json`, `approvals.json`, `launches.jsonl`, `notifications.jsonl`,
  `rotations.jsonl`, `kill-failed.json`, and `step-errors.json`. Never hand-edit them.

Lifecycle controls:
- Retained artifacts live under `.dt-build/<RUN_ID>/`.
- Cleanup is executed through one orchestrator cleanup path.
- No scratch prompt artifacts should survive run finalization.
- Orchestration state files stay out of milestone commits; they live in the run folder, never in the worktree diff.
- The tree-hash temporary index writes git objects into the repository's object store, which `git gc` reclaims; nothing else cleans them.
