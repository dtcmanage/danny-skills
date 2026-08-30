# dt-pipeline changelog

- 0.1.2 (2026-08-30): Review-phase spawn prompt must state dt-review's subagent cap-gate contract: USER_DECISION and A/B/C packages are sent to the orchestrator via SendMessage immediately, never idled on.

- 0.1.1 (2026-07-12): Inherited the established pack-wide versioning policy and release gate.

- 0.1.0 (2026-07-05): Initial release: one-command plan -> dt-review -> dt-build orchestration with stage-aware intake, ~10-minute status pulse, rolling _build-state.md crash-resume checkpoint, prod-write single-threading, end-of-run merge prompt.
