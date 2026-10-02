# Model router operator reference

Route work through `scripts/model-router/resolve-model.ps1`; request `-Json` for structured output. The roster contains five jobs, a first choice and an other-vendor backup per job, and a category-to-job map. The illustrator has no backup while only one image model exists. Each slot carries an effort (fast low, coder medium, deep thinker high, writer medium, illustrator none) that the resolver returns and the wrappers pass to the CLIs.

Use the approved state `roster.json` when valid. An absent `roster.json` raises `router-roster-missing`; a `roster.json` that is invalid or not approved raises `router-roster-invalid` with the error text. In both cases, the resolver uses `default-roster.json`. `ladders.json` defines the per-lane escalation ladder. Vendor limits and recorded refusal blocks can move a job to its backup; drift moves a job to its approved backup. When no eligible model is available, the resolver returns `wait`.

Keep code in `scripts/model-router/` and committed configuration in `references/model-router/`. Runtime readings, proposals, registry, alerts, outcomes, and cost reports live in `DT_MODEL_ROUTER_STATE` when set, otherwise in the `model-router/state` sibling of the main checkout. Worktrees share that state folder.

Rebuild a roster from scratch with `pwsh -NoProfile -File scripts/model-router/approve-roster.ps1 -Seed`, then run the same script with `-Show` to review the proposal and `-Approve` to approve it. Seeding alone leaves routing on the default roster.

The catalog check runs twice daily with a 30-second deadline. A failed check preserves the last good registry. New models are queued for research and trigger a canary. Alerts show a chat line, try a private Discord DM, and fall back to email; delivered keys fire once. `update-outcomes.ps1` records performance and flags drift. The monthly canary tests selected and flagged models. The weekly cost report compares subscription use with API-equivalent spend and DMs model use, frontier use, vendor quota use, Claude session use, and pending approvals.

Outcome writers share `Use-RouterOutcomeMutex` in `router-common.ps1`. Imports hold it before reading outcomes, the roster, drift marks and declines, through replacement and proposal updates; canary, research and build wrappers append through `Add-RouterOutcome`. Roster approval and proposal creation use the same lock so a concurrent import cannot overwrite an approval or decline. Alerts are delivered after releasing the lock. The persistent `outcomes.mutex` file is intentionally retained; its exclusive handle is released in `finally` or by the OS on process exit. Do not delete it while writers may be running. Contention waits up to 30 seconds, then raises `ROUTER_OUTCOME_MUTEX_TIMEOUT`; it never writes without the lock. This coordinates processes sharing one local state directory, not separate machines or non-cooperating manual writers.

## Main-session delegation

Every session that hands work to another model resolves the category through this router first; the session model is never inherited by a subagent or a `codex exec` call. The category guide, the cheap-first rule (collecting is `mechanical`, interpreting is `analysis`; round up only when the result cannot be checked), and worked examples live in `D:\Claude\_Claude-Workspace\00_Resources\model-routing.md`, loaded through the root `CLAUDE.md` rule (2026-09-30). Roster note: coder is Codex-first by policy since 2026-09-30. Weekly use is observable for both vendors; at 95%, a job moves to its other-vendor backup.

## v2: one roster across both vendors

v2 routes delegated work from a short roster (at most 5 models) defined in `roster-schema.md`. Eleven categories map to five jobs: `mechanical` to fast; `routine-coding`, `complex-coding`, and `ui-frontend` to coder; `code-review`, `planning`, `deep-research`, `math`, and `analysis` to deep thinker; `long-form-writing` to writer; `image-generation` to illustrator. Each job has a first choice and a backup on the other vendor. Frontier models are never on the roster.

A caller that passes `-Lane` gets that lane's member of the pair or a `wait`. A caller without a lane gets the first choice, or the backup when the first choice's vendor is blocked, unselectable, or drifting. `vendor-limits.ps1` reads Codex weekly use from local session logs and Claude weekly use from `GET https://api.anthropic.com/api/oauth/usage`, using the `claudeAiOauth.accessToken` in `.credentials.json` under `CLAUDE_CONFIG_DIR` (falling back to `~\.claude`) with `anthropic-beta: oauth-2025-04-20`. It reads `seven_day.utilization`; at 95% or more either vendor is blocked and the job moves to its other-vendor backup. Claude readings are cached in `<state>/claude-usage.json` for 5 minutes. The router never refreshes or logs the token; a missing or expired token produces no reading and does not block Claude; a failed request falls back to the last cached reading, or to no reading when none exists. A recorded limit refusal also blocks that vendor until reset. If both vendors are blocked, the resolver returns `status = wait`, never a weaker model. The 5-hour Claude session figure appears only in the weekly cost report.

Research runs per category (`run-router-research.ps1 -Categories`), reading the named sources in `benchmark-sources.json` and storing readings under `<state>/readings/`. `build-roster.ps1` turns readings into a proposal: two independent comparable leads and no trail win a category; the job's primary category decides a multi-category job; a change needs two consecutive conclusive passes that covered the job; the fast job clears a quality floor, then the lower list price wins. A change sends one Discord DM and writes a report under `<state>/roster-proposals/`.

Manage the roster with `approve-roster.ps1`: `-Show`, `-Approve` (uses the approved roster), `-Revoke` (clears approval and uses the default roster with an alert), and `-DeclineDrift -Job <job>` (keep the first choice after a drift alert). Drift on a first choice sends that job to its approved backup until Danny approves the swap proposal or declines it.
Use `-Approve -Jobs fast,coder` to approve only named jobs when a full proposal exceeds the five-model cap.

At ship, register the Windows Scheduled Tasks from the **main checkout** with `pwsh -NoProfile -File scripts/model-router/register-router-schedules.ps1 -Apply`. They run the monthly canary on day 1 at 04:00 ET, the weekly cost report on Monday at 07:00 ET, the full research cadence daily at 01:00 ET, and the model-release check daily at 13:00 ET. Do not register them from a build worktree.

From the repo root, run:

```powershell
Get-ChildItem scripts/model-router/tests/*.ps1 | ForEach-Object { pwsh -NoProfile -File $_.FullName; if ($LASTEXITCODE -ne 0) { throw "Failed: $($_.Name)" } }
pwsh -NoProfile -File scripts/verify-versioning-policy.ps1 -BaseRef main -Json
pwsh -NoProfile -File scripts/verify-skill-junctions.ps1 -RepoRoot (Get-Location).Path -Json
```
