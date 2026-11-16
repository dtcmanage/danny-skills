# dt-memory-hygiene changelog

- 0.4.1 (2026-11-16): Markdown table rows no longer count as long lines, so the workspace directory table does not trigger hygiene on every audit.

- 0.4.0 (2026-11-16): The size check holds workstation, substation and repo CLAUDE.md/MEMORY.md to 1,500 words (MEMORY.md also 150 lines); root files and the workspace directory keep root limits; evidence copies, underscore meta folders and the auto-memory inbox are skipped.

- 0.3.2 (2026-10-18): Anchor runnable script paths to resolved skill and repository roots (FS-117).

- 0.3.1 (2026-09-03): Adopt the shared CommonMark-safe local file-link contract: forward-slash destinations, angle brackets for spaces, and backticked literals.

- 0.3.0 (2026-08-30): Advisory Residency Sweep for CLAUDE.md files: re-test resident rules against the Residency Test, surface relocation candidates once, honor a residency:keep marker as the no-re-nag ledger. Detector emits word_count for every file and enforces a 4000-word word_max on CLAUDE.md files (the deterministic measurement dt-session-audit's root write gate uses); empty-file crash fixed.

- 0.2.1 (2026-07-12): Inherited the established pack-wide versioning policy and release gate.

- 0.2.0 (2026-07-05): Mandatory post-pass detector re-run with before/after metrics (no improvement = not done); report HTML on request only.
