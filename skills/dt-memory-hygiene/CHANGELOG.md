# dt-memory-hygiene changelog

- 0.3.0 (2026-08-30): Advisory Residency Sweep for CLAUDE.md files: re-test resident rules against the Residency Test, surface relocation candidates once, honor a residency:keep marker as the no-re-nag ledger. Detector emits word_count for every file and enforces a 4000-word word_max on CLAUDE.md files (the deterministic measurement dt-session-audit's root write gate uses); empty-file crash fixed.

- 0.2.1 (2026-07-12): Inherited the established pack-wide versioning policy and release gate.

- 0.2.0 (2026-07-05): Mandatory post-pass detector re-run with before/after metrics (no improvement = not done); report HTML on request only.
