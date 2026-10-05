# Model router operator reference

Route work through `scripts/model-router/resolve-model.ps1`; request `-Json` for structured output. The roster contains five jobs, a first choice and an other-vendor backup per job, and a category-to-job map. The illustrator has no backup while only one image model exists. Each slot carries an effort (fast low, coder standard medium / hard high, deep thinker standard medium / hard high, writer medium, illustrator none) that the resolver returns and the wrappers pass to the CLIs.

Use the approved state `roster.json` when valid. An absent `roster.json` raises `router-roster-missing`; a `roster.json` that is invalid or not approved raises `router-roster-invalid` with the error text. In both cases, the resolver uses `default-roster.json`. `ladders.json` defines the per-lane escalation ladder. Vendor limits and recorded refusal blocks can move a job to its backup; drift moves a job to its approved backup. When no eligible model is available, the resolver returns `wait`.

Keep code in `scripts/model-router/` and committed configuration in `references/model-router/`. Runtime readings, proposals, registry, alerts, outcomes, and cost reports live in `DT_MODEL_ROUTER_STATE` when set, otherwise in the `model-router/state` sibling of the main checkout. Worktrees share that state folder.

Rebuild a roster from scratch with `pwsh -NoProfile -File scripts/model-router/approve-roster.ps1 -Seed`, then run the same script with `-Show` to review the proposal and `-Approve` to approve it. Seeding alone leaves routing on the default roster.

The catalog check runs twice daily with a 30-second deadline. A failed check preserves the last good registry. New models are queued for research and trigger job-scoped bench comparisons. Alerts show a chat line, try a private Discord DM, and fall back to email; delivered keys fire once. `update-outcomes.ps1` records performance and flags drift. Bench runs on new-model, research, drift and manual triggers; no monthly bench schedule. The weekly cost report compares subscription use with API-equivalent spend and DMs model use, frontier use, vendor quota use, Claude session use, and pending approvals.

Outcome writers share `Use-RouterOutcomeMutex` in `router-common.ps1`. Imports hold it before reading outcomes, the roster, drift marks and declines, through replacement and proposal updates; bench, research and build wrappers append through `Add-RouterOutcome`. Roster approval and proposal creation use the same lock so a concurrent import cannot overwrite an approval or decline. Alerts are delivered after releasing the lock. The persistent `outcomes.mutex` file is intentionally retained; its exclusive handle is released in `finally` or by the OS on process exit. Do not delete it while writers may be running. Contention waits up to 30 seconds, then raises `ROUTER_OUTCOME_MUTEX_TIMEOUT`; it never writes without the lock. This coordinates processes sharing one local state directory, not separate machines or non-cooperating manual writers.

## Difficulty tiers

Coder and deep-thinker default to `standard`; request `-Difficulty hard -DifficultyReason "<single-line reason, at most 240 characters>"` for hard work. Difficulty is lowercase in results and wrapper provenance; fast, writer and illustrator return null. A job without tier objects uses its scalar at both difficulties and treats tie evidence as standard.

Each tiered slot still requires its scalar `first_effort` / `backup_effort`, equal to the corresponding `first_efforts.standard` / `backup_efforts.standard`. Validation rejects mismatches and missing scalars; writers update both together. Defaults are medium at standard and high at hard for both tiered jobs. Legacy approved rosters remain unchanged until approval.

Use `approve-roster.ps1 -ApproveTiers -Job <deep-thinker|coder>` to adopt the default tiers for one job. Approval requires both models to match the default roster and records the previous scalars. `-RevokeTiers -Job` removes the tier objects and restores those scalars. Other jobs and model picks stay as approved. `-Show` retains scalar columns beside standard/hard columns and marks unmigrated tiered jobs "tiers not set". Seed reports show both efforts.

Inside dt-build's two-attempt budget, a standard first attempt retries with `-RetryAtHardFrom <failed model> -DifficultyReason "<reason>"`, retaining that model at hard effort. A first attempt already at hard retries with `-EscalateFrom <failed model> -Difficulty hard -DifficultyReason "<reason>"`, moving one non-frontier rung. A category without tiers (unprotected `mechanical`, which routes to the fast job) retries with `-EscalateFrom <failed model>` as before. Legacy callers without difficulty flags keep their escalation behavior. Like `-EscalateFrom`, `-RetryAtHardFrom` does not apply drift marks without `-Lane`; a constrained lane applies drift and may wait.

Bench caller effort overrides (including build-roster slot efforts) take precedence over roster tiers. Without an override, only coder and deep-thinker use roster tiers. The 20-task bank has no beyond tasks; the engine retains beyond support at hard effort, reported and never gating. Bank edits invalidate golden approval. Relabel proposals are skipped when standard and hard efforts are equal.

## Main-session delegation

Every session that hands work to another model resolves the category through this router first; the session model is never inherited by a subagent or a `codex exec` call. The category guide, the cheap-first rule (collecting is `mechanical`, interpreting is `analysis`; round up only when the result cannot be checked), and worked examples live in `D:\Claude\_Claude-Workspace\00_Resources\model-routing.md`, loaded through the root `CLAUDE.md` rule (2026-09-30). Roster note: coder is Codex-first by policy since 2026-09-30. Weekly use is observable for both vendors; at 95%, a job moves to its other-vendor backup.

## v2: one roster across both vendors

v2 routes delegated work from a short roster (at most 5 models) defined in `roster-schema.md`. Eleven categories map to five jobs: `mechanical` to fast; `routine-coding`, `complex-coding`, and `ui-frontend` to coder; `code-review`, `planning`, `deep-research`, `math`, and `analysis` to deep thinker; `long-form-writing` to writer; `image-generation` to illustrator. Each job has a first choice and a backup on the other vendor. Frontier models are never on the roster.

A caller that passes `-Lane` gets that lane's member of the pair or a `wait`. A caller without a lane gets the first choice, or the backup when the first choice's vendor is blocked, unselectable, or drifting. `vendor-limits.ps1` reads Codex weekly use from local session logs and Claude weekly use from `GET https://api.anthropic.com/api/oauth/usage`, using the `claudeAiOauth.accessToken` in `.credentials.json` under `CLAUDE_CONFIG_DIR` (falling back to `~\.claude`) with `anthropic-beta: oauth-2025-04-20`. It reads `seven_day.utilization`; at 95% or more either vendor is blocked and the job moves to its other-vendor backup. Claude readings are cached in `<state>/claude-usage.json` for 5 minutes. The router never refreshes or logs the token; a missing or expired token produces no reading and does not block Claude; a failed request falls back to the last cached reading, or to no reading when none exists. A recorded limit refusal also blocks that vendor until reset. If both vendors are blocked, the resolver returns `status = wait`, never a weaker model. The 5-hour Claude session figure appears only in the weekly cost report.

Research runs per category (`run-router-research.ps1 -Categories`), reading the named sources in `benchmark-sources.json` and storing readings under `<state>/readings/`. `build-roster.ps1` turns readings into a proposal: two independent comparable leads and no trail win a category; the job's primary category decides a multi-category job; a change needs two consecutive conclusive passes that covered the job; the fast job clears a quality floor, then the lower list price wins. A change sends one Discord DM and writes a report under `<state>/roster-proposals/`.

Manage the roster with `approve-roster.ps1`: `-Show`, `-Approve` (uses the approved roster), `-Revoke` (clears approval and uses the default roster with an alert), and `-DeclineDrift -Job <job>` (keep the first choice after a drift alert). Drift on a first choice sends that job to its approved backup until Danny approves the swap proposal or declines it.
Use `-Approve -Jobs fast,coder` to approve only named jobs when a full proposal exceeds the five-model cap.

At ship, register the Windows Scheduled Tasks from the **main checkout** with `pwsh -NoProfile -File scripts/model-router/register-router-schedules.ps1 -Apply`. They run the weekly cost report on Monday at 07:00 ET, the full research cadence daily at 01:00 ET, and the model-release check daily at 13:00 ET. Do not register them from a build worktree.

From the repo root, run:

```powershell
Get-ChildItem scripts/model-router/tests/*.ps1 | ForEach-Object { pwsh -NoProfile -File $_.FullName; if ($LASTEXITCODE -ne 0) { throw "Failed: $($_.Name)" } }
pwsh -NoProfile -File scripts/verify-versioning-policy.ps1 -BaseRef main -Json
pwsh -NoProfile -File scripts/verify-skill-junctions.ps1 -RepoRoot (Get-Location).Path -Json
```
# Internal bench research gate

Research proposals stage candidate comparisons outside the outcome writer mutex.
After comparisons, publication reacquires the mutex and checks the complete roster
job identity, including model picks and efforts. A changed identity rejects the
staged result with `BENCH_STALE_ROSTER`.

UNKNOWN blocks publication even in shadow mode and for writer. Approved-bank
fast, coder and deep-thinker failures block publication; writer and shadow results
are advisory. Equal results are reported as tied; otherwise the better model is decided by pass count, then fewer fabrications, then fewer first-attempt failures;
a one-task candidate deficit remains visible in the proposal evidence with the
bench report path. Bench and historical canary outcomes do not enter real drift
rate calculations. Pending roster detection includes both slot efforts.

Triggered comparisons stage outside outcome locks and revalidate roster model and effort before publication. Research offers incumbent effort-down even when it keeps the model. New-model checks retain release and day-seven research queues and refresh known frontier judges in bench/judge-config.json. Failed/unknown results are in bench/trigger-log.jsonl; unknown alerts use stable identities. Weekly rubric reminders apply to the current bank and judge pair; rubric correction changes the bank hash and returns golden approval to shadow mode.

Use approve-roster.ps1 -ApproveEffort, -DeclineEffort or -RevokeEffort with -Job for separate effort proposals; actions revalidate exact model and effort.


## Approved quota ties

A non-shadow tied bench run files `<state>/tie-proposals/<job>.json` only when
its two tested model-and-effort configurations equal the roster job's first and
backup configurations. It records `type: tie`, `status: pending`, `job`, `tier`,
`configurations` (candidate and incumbent, each with model and effort), `run_id`
and `bank_hash`. Identical pending, declined, approved or revoked evidence keeps its
original proposal, status and run ID; a later tied run does not ask again.
Use `approve-roster.ps1 -ApproveTie -Job <job>` to approve it,
`-DeclineTie -Job <job>` to decline it, or `-RevokeTie -Job <job>` to remove
approved tie evidence. Approval revalidates both models, both efforts and the
current task bank; it leaves first and backup unchanged.

The optional roster job field `tie_evidence` carries `tier`, `configurations`,
`run_id`, `bank_hash`, and `approved_at`. It is published with the roster.
The supported tier is `standard`. Full and `-Jobs` roster approval preserve
existing tie evidence when both models and efforts are unchanged, and drop it
when either slot changes. Evidence becomes void if either model, either effort,
or the bank hash changes. The bench records `bench/bank-hash.json` with
`task_bank_sha256` and `written_at` at run time and whenever golden approval is
written. Tie evidence is checked against the bank hash recorded at the last
bench or golden-review run; edits to the bank take effect at the next such run.
Resolve reads that file without starting Python. An absent or unreadable
hash voids the evidence, with the existing `roster-tie-invalid:<job>` alert.

With valid approved evidence and neither `-Lane` nor `-EscalateFrom`, the tie-break
reuses local weekly readings after the resolver's ordinary block evaluation.
Claude's normal 5-minute refresh and credential-identity check remain in place;
when that path is not evaluated, only an identity-validated local weekly cache
may be reused. Codex uses whichever of primary or secondary has `window_minutes: 10080`;
a 300-minute window or a window without `window_minutes` is not weekly evidence.
Missing readings, failed credential identity,
nonweekly windows, future timestamps or readings older than 6 hours keep first
choice. Both percentages are rounded to one decimal, with midpoints away from zero,
before comparison: a strictly greater than 5.0-point difference selects the lower-use vendor, while
exactly 5.0 or less keeps first choice. Both observation times use the same US
Eastern format, and the reason describes the final chosen model after overrides.

Lane, drift, escalation, 95 percent quota blocks, vendor incident blocks and
protected handling retain precedence. Ordinary Claude usage refreshes, stale
incident recovery and the bounded Codex catalog retry retain their existing
behavior. A tie-selected vendor and a catalog fallback undergo the ordinary
block evaluation, including its bounded Claude refresh. The weekly comparison
itself adds no network or model call.
# Frontier requests

For a coder or deep-thinker piece that failed at hard effort (or has disagreeing
hard-tier answers), run `scripts/model-router/request-frontier.ps1 -Category <category>
-ProblemPath <file> -AttemptPaths <attempt-files> -AttemptVendor <codex|claude>
-StateDir <state>`. It makes one read-only scrutiny call on the other vendor's
deep thinker at high effort, using the canonical prompt envelope. Invalid or
uncited frontier verdicts become `retry_with_guidance`; `decompose` and retries
create no request or alert.

Only `needs_frontier` records `frontier-requests/<id>.json` and sends one keyed
alert. The request proposes the job's first-choice vendor's frontier model at
high effort, with a bounded problem summary, attempt hashes, scrutiny, and quota
note. The piece waits. Danny approves with `approve-roster.ps1 -ApproveFrontier
-RequestId <id> -Model <exact-proposed-model>`, or declines with `-DeclineFrontier
-RequestId <id>`. Both record the decision time.

`resolve-model.ps1 -Category <same-category> -FrontierRequest <id>` implies hard.
Pending waits without fallback; declined asks for decomposition. Approved requests
must include the decision time and matching named model, still marked frontier
in `ladders.json`. Consumption is locked and atomically recorded as used before
returning the model, permitting one dispatch. Unknown, mismatched, malformed, or
used requests fail closed. Ordinary difficulty and escalation never select frontier.

Resolve with `-FrontierRequest <id>`, then pass the returned model to the lane
wrapper through `-Model` and a `-SelectionReason` naming the request id. Approval
is consumed when the resolver returns the model, so a failed run needs a new
request. The scrutiny call runs without tools (Claude uses default permissions;
Codex uses the read-only sandbox).
