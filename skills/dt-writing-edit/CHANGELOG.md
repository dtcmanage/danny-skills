# dt-writing-edit changelog

- 0.2.11 (2026-10-01): model router consolidation: v1 evidence routing retired, roster-only resolver with effort, approve-roster.ps1 replaces approve-router-table.ps1, ladders.json replaces bridge-map.json

- 0.2.10 (2026-09-30): model router: read Claude weekly usage from the OAuth usage endpoint (5-minute cache, token never stored) and move Claude jobs to their Codex backup at 95%, same as Codex; weekly cost report shows the Claude weekly and 5-hour readings

- 0.2.9 (2026-09-30): model router: price GPT-6.1 Sol and Sonnet 5.5 so reports and canary stop showing them unpriced; canary finds claude.exe when claude.ps1 is absent and strips the session timestamp stamp and markdown fences before grading, and the code-review grader judges the whole answer (Claude models were never canaried, and fenced code failed every code task)

- 0.2.8 (2026-09-30): Router: GPT-6.1 Sol replaces GPT-6 Sol as the Codex Sol rung; research retries transient Codex failures, keeps Codex error output, and checks Artificial Analysis for launch-day scores.

- 0.2.7 (2026-09-28): Model router alerts refuse real delivery from tests.

- 0.2.6 (2026-09-28): Shared model router v2: cross-vendor roster, vendor-limit backups, offline research cadence (model router).

- 0.2.5 (2026-09-27): Model router: research grades must be confirmed by two runs, the current pick keeps its place without evidence, older models need a higher grade, protected work only moves up, and evidence routing waits for approval.

- 0.2.4 (2026-09-27): Model-router research now sends its profile schema inside the prompt, so research runs produce valid profiles.

- 0.2.3 (2026-09-27): Clarify model-router guardrails for editing.

- 0.2.2 (2026-09-03): Adopt the shared CommonMark-safe local file-link contract: forward-slash destinations, angle brackets for spaces, and backticked literals.

- 0.2.1 (2026-07-12): Inherited the established pack-wide versioning policy and release gate.

- 0.2.0 (2026-07-05): Deterministic original-untouched guarantee via SHA256 before/after hash in the change summary; review HTML on request only.
