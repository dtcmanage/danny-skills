# Surface Templates

Per-surface starting structures for dt-plan's Step 2. These are **starting points, not rigid templates** — adapt to the project, and propose a custom structure (with a one-line reason) when none fits cleanly.

Whatever structure is chosen, the plan is still drafted against the six dimensions of the Canonical Dimension Contract (repo-level `references/canonical-dimension-contract.md`): the section layout stays surface-shaped, but every dimension must have a home.

- **CLI utility** — Goal, Inputs & Outputs, Behavior & Flags, Error Handling, Distribution/Install, Tests
- **Service or system** — Objectives, Architecture Overview, Components, Data Model, Integration Points, Failure Modes, Security, Observability, Open Questions
- **Integration** — Source/Target Systems, Data Contract, Auth & Secrets, Sync Cadence or Triggers, Failure Modes & Backfill, Observability, Cutover Plan
- **Migration / rollout** — Current State, Target State, Phasing, Cutover Plan, Rollback, Validation, Comms
- **Website / UI rebuild** — Goals, IA & Routes, Components, Data & State, Backend Touchpoints, Content Migration, Performance & SEO, QA
- **Refactor** — Current Pain, Target Shape, Touch Surface, Phasing, Risk & Reversibility, Validation
- **Data pipeline** — Sources, Transformations, Storage, Schedule & Triggers, Idempotency & Backfill, Observability
