# dt-plan changelog

- 1.2.0 (2026-08-30): Producer-side contract alignment with dt-review 1.9.0 and dt-build 2.9.x: plans now carry the required '## Build-intake revalidation' table that dt-review Round-1 hard-gates on; sections are written to plan-draft.md as they lock instead of one batched save; new scripts/verify-plan-shape.ps1 validates the plan at save time; Scope now tiers the Step 3 drive (light = one compressed pass, complex = full drive); added a settled-decisions ledger to stop re-litigating adjudicated calls; removed the forked references/{plan-shape,surface-templates}.md copies in favor of the repo-level originals; collapsed the self-cancelling HTML requirement block to a one-line dt-visualize-plan pointer.

- 1.1.1 (2026-07-12): Inherited the established pack-wide versioning policy and release gate.

- 1.1.0 (2026-07-05): Canonical Tech Stack Reference path (.md); HTML visual delegated to dt-visualize-plan on request only; deterministic ADR numbering via scripts/next-adr-number.ps1.
