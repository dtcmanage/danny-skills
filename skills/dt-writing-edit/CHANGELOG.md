# dt-writing-edit changelog

- 0.3.33 (2026-10-13): Model router bench (shared component): bench tests use a fake renderer, and the ranked renderer finds browser-smoke through DANNY_BROWSER_SMOKE_DIR outside the workspace tree; the task bank is unchanged (FS-69).

- 0.3.32 (2026-10-13): Read-only Codex reviewers run in the real MXC sandbox (shared process wrapper); a blocked sandbox read is reported as a blocked review, not a pass.

- 0.3.31 (2026-10-13): Model router bench (shared component): broken or quota-blocked Codex calls stay out of bench results; recovered dispatch failures no longer break quality ties.

- 0.3.30 (2026-10-13): Shared process wrapper classifies Codex capacity refusals as capacity, and model router outcome recording treats them as vendor availability, not model quality.

- 0.3.29 (2026-10-11): model router: read-only Codex workers on Windows can read files (unsandboxed with an unchanged-tree check); the ad-hoc wiring test uses the fixture Claude CLI.

- 0.3.28 (2026-10-11): model router: chunk wrappers refuse prompts over 400,000 characters (PROMPT_TOO_LARGE) and point to path-plus-sha256 references.

- 0.3.27 (2026-10-11): model router: chunk wrappers gain -AdHoc for one-off work outside a dt-build run (routing and accounting kept, dt-build envelope checks skipped).

- 0.3.26 (2026-10-11): model router: chunk wrappers have no time limit under dt-job; activity check-ins flag stalls instead.

- 0.3.25 (2026-10-11): model router: the bench lets Codex retry its own stream errors and names final errors by code.

- 0.3.24 (2026-10-11): Shared model router: tests cover the chunk wrappers' per-job time limits.

- 0.3.23 (2026-10-11): Shared model router: ranked judging calls a winner only on a statistically significant lead over 16 rounds; lower-effort and swap proposals are blocked when they trail.

- 0.3.22 (2026-10-11): Shared model router: new models read 'researched' after their release research pass instead of staying 'unprofiled'.

- 0.3.21 (2026-10-11): Shared model router: bench call time limit is now set per job; deep-thinker calls get 15 minutes so hard questions can finish.

- 0.3.20 (2026-10-10): Shared model router quota messages now read X% used / Y% left with reset times in US Eastern.

- 0.3.19 (2026-10-10): Shared model router: Codex prompts rejected as too large (input_too_large) now fail fast as a tooling failure, with no retry and an alert naming the prompt size and the limit.

- 0.3.18 (2026-10-10): Model router bench runs model calls side by side (default 32 at once) and asks both judges at the same time; a deep-thinker comparison drops from hours to minutes.

- 0.3.17 (2026-10-10): Model router usage reads as X% used / Y% left in the weekly report, limits CLI, and limit wait reasons; the weekly report adds a Codex usage line.

- 0.3.16 (2026-10-10): Model router re-checks Codex limits live when a stale reading says Codex is blocked, so a usage reset is seen without waiting for a Codex run.

- 0.3.15 (2026-10-10): Shared model router: DT_ROUTER_GUARD_OVERRIDE lifts the 95% quota guard for named vendors in one process, only on Danny explicit permission.

- 0.3.14 (2026-10-07): Shared model router scripts: declined effort swaps stay declined, one bench comparison at a time, research replies parse past a timestamp preface.

- 0.3.13 (2026-10-07): Model router bench: each Codex bench call saves the app-server weekly rate-limit snapshot as a fresh reading (ephemeral turns write no rollout file, so the spend stop had no Codex baseline and hit the call cap); the runaway call cap rises to 700, above a two-tier deep-thinker job. A rep whose first two attempts were vendor identity failures gets a third attempt.

- 0.3.12 (2026-10-06): Model router bench: per-call and per-tier timing, call counts and latency in telemetry, a bench ledger (state/bench/ledger.jsonl) recording cost, duration and quota per comparison; an undecided quality verdict no longer qualifies effort-down or swap proposals. Codex judge turns that send rendered images now pass the raw-evidence check (input_image), so Astra image judging works live. A spend baseline must be a reading observed within 10 minutes of the comparison start, so earlier jobs' use no longer halts a later comparison. A vendor-incident block now needs a status-page outage; degraded_performance is recorded but never blocks.

- 0.3.11 (2026-10-06): Model router: new-model bench comparisons run in the overnight cadence with the release research pass (one per job the model does not already hold), never from the daytime catalog check.

- 0.3.10 (2026-10-06): Model router: a triggered bench comparison with the same job, models, effort, bank and judges is run once (duplicates are logged, not re-run), and the nightly cadence no longer queues refresh research on its own; research runs only for a new frontier-vendor release or on Danny's call (run-router-cadence.ps1 -Refresh).

- 0.3.9 (2026-10-05): Model router benchmark: private task bank beside the router state, Aider and HLE importers, a Node test grader, ranked quality tasks judged blind by both judges, quality verdicts that gate swap, effort and tie proposals and are rechecked at approval, a per-comparison spend stop, and valid UTF-8 bench output. The in-repo bank is now 25 tasks, so answer sheets need fresh approval.

- 0.3.8 (2026-10-04): Pick up the shared model router update: difficulty tiers for coder and deep-thinker work, quota tie-break, and the frontier request path. This skill's own routing is unchanged.

- 0.3.7 (2026-10-03): Isolate model router benchmark calls from personal configuration, accept a single fenced answer with surrounding prose, and report first-attempt failures per model.

- 0.3.6 (2026-10-03): Preserve UTF-8 model prompts and responses across redirected process and PowerShell shim boundaries.

- 0.3.5 (2026-10-03): Correct model router starter-bank grading, fix judge effort and duration-aware usage pricing, bind proposal approval to current evidence, and retire the obsolete canary runner.

- 0.3.4 (2026-10-02): Correct model router grading for typed React notes and malformed ledger entities.

- 0.3.3 (2026-10-02): Make benchmark answers tool-free, reject shadow effort proposals, and ignore unrelated duplicate vendor status names.

- 0.3.2 (2026-10-02): Use active CLI discovery for benchmarks, disable inherited time reminders, and price cache writes explicitly.

- 0.3.1 (2026-10-02): Refresh a rejected automatic Codex catalog from the current CLI; preserve quota and fallback behavior.

- 0.3.0 (2026-10-02): Expand shared model routing with triggered internal benchmarking, Mac-local observation and concurrent outcome safety.

- 0.2.13 (2026-10-02): Update the shared vendor-failure diagnosis consumer version for degraded-component handling when the incident feed is unavailable.

- 0.2.12 (2026-10-01): Consume shared model router diagnosis verdicts, vendor-incident failover, research and canary reliability, acknowledge support, and routing compliance reporting.

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
