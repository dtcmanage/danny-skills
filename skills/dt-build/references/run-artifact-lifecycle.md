# Run-Artifact Lifecycle

Artifact classes:
- Ephemeral scratch: per-invocation prompt assembly files; delete after consume/verify.
- Retained audit record: reference-pack files, `reference-manifest.md`, `build-log-<RUN_ID>.md`.
- Retained decision record: `build-plan.md`, `build-state.md`, `build-decision-log.md`.

Lifecycle controls:
- Retained artifacts live under `.dt-build/<RUN_ID>/`.
- Cleanup is executed through one orchestrator cleanup path.
- No scratch prompt artifacts should survive run finalization.
