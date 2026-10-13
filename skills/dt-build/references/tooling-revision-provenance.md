# Tooling revision provenance

A run that pins dt-build tooling to exact bytes uses this to accept published releases without a hand approval (FS-68).

When a run observer detects changed tooling bytes, invoke `scripts/resolve-tooling-revision.ps1 -Path <installed-file> -Json`. It compares exact bytes (including line endings) against the local `origin/main` history of danny-skills. For files outside an installed `dt-build/scripts` directory, supply `-RepoRelativePath <repo-path>`; use `-RepoRoot <danny-skills-checkout>` when the helper is outside the source repo or its skill junction. The helper never fetches unless `-Fetch` is explicitly passed. Its `ref_head` records the locally observed reference snapshot; `commit_date` is Eastern time with its numeric offset, and `is_ref_head` means the head blob matches, even if the matching commit predates head.

Accept an `ON_MAIN` result (exit 0) and record the transition's previous and new byte size/SHA256, blob id, matching commit, commit date, ref and ref head in the run's evidence log. A published tooling revision needs no new hand approval. Stop for `NOT_ON_MAIN` (exit 3), rather than stopping for every changed hash. An invocation or IO failure (exit 2) proves nothing: correct the error and retry before accepting the transition. This establishes tooling provenance only; all existing run authority and restrictions still apply.
