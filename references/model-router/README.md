# Model router operator reference

Route work through `scripts/model-router/resolve-model.ps1`; request `-Json` for structured output. The roster contains five jobs, a first choice and an other-vendor backup per job, and a category-to-job map. The illustrator has no backup while only one image model exists. Each slot carries an effort (fast low, coder standard medium / hard high, deep thinker standard medium / hard high, writer medium, illustrator none) that the resolver returns and the wrappers pass to the CLIs.

Use the approved state `roster.json` when valid. An absent `roster.json` raises `router-roster-missing`; a `roster.json` that is invalid or not approved raises `router-roster-invalid` with the error text. In both cases, the resolver uses `default-roster.json`. `ladders.json` defines the per-lane escalation ladder. Vendor limits and recorded refusal blocks can move a job to its backup; drift moves a job to its approved backup. When no eligible model is available, the resolver returns `wait`.

Keep code in `scripts/model-router/` and committed configuration in `references/model-router/`. Runtime readings, proposals, registry, alerts, outcomes, and cost reports live in `DT_MODEL_ROUTER_STATE` when set, otherwise in the `model-router/state` sibling of the main checkout. Worktrees share that state folder.

Rebuild a roster from scratch with `pwsh -NoProfile -File scripts/model-router/approve-roster.ps1 -Seed`, then run the same script with `-Show` to review the proposal and `-Approve` to approve it. Seeding alone leaves routing on the default roster.

The catalog check runs twice daily with a 30-second deadline. A failed check preserves the last good registry. A new non-frontier model is queued for release research; its job-scoped bench comparisons (one per job it could serve, never against a job it already holds) run in the overnight cadence with that release pass, not from the daytime check. Alerts show a chat line, try a private Discord DM, and fall back to email; delivered keys fire once. `update-outcomes.ps1` records performance and flags drift. Bench runs on new-model, research, drift and manual triggers; no monthly bench schedule. The weekly cost report compares subscription use with API-equivalent spend and DMs model use, frontier use, vendor quota use, Claude session use, and pending approvals.

Outcome writers share `Use-RouterOutcomeMutex` in `router-common.ps1`. Imports hold it before reading outcomes, the roster, drift marks and declines, through replacement and proposal updates; bench, research and build wrappers append through `Add-RouterOutcome`. Roster approval and proposal creation use the same lock so a concurrent import cannot overwrite an approval or decline. Alerts are delivered after releasing the lock. The persistent `outcomes.mutex` file is intentionally retained; its exclusive handle is released in `finally` or by the OS on process exit. Do not delete it while writers may be running. Contention waits up to 30 seconds, then raises `ROUTER_OUTCOME_MUTEX_TIMEOUT`; it never writes without the lock. This coordinates processes sharing one local state directory, not separate machines or non-cooperating manual writers.

## Difficulty tiers

Coder and deep-thinker default to `standard`; request `-Difficulty hard -DifficultyReason "<single-line reason, at most 240 characters>"` for hard work. Difficulty is lowercase in results and wrapper provenance; fast, writer and illustrator return null. A job without tier objects uses its scalar at both difficulties and treats tie evidence as standard.

Each tiered slot still requires its scalar `first_effort` / `backup_effort`, equal to the corresponding `first_efforts.standard` / `backup_efforts.standard`. Validation rejects mismatches and missing scalars; writers update both together. Defaults are medium at standard and high at hard for both tiered jobs. Legacy approved rosters remain unchanged until approval.

Use `approve-roster.ps1 -ApproveTiers -Job <deep-thinker|coder>` to adopt the default tiers for one job. Approval requires both models to match the default roster and records the previous scalars. `-RevokeTiers -Job` removes the tier objects and restores those scalars. Other jobs and model picks stay as approved. `-Show` retains scalar columns beside standard/hard columns and marks unmigrated tiered jobs "tiers not set". Seed reports show both efforts.

Inside dt-build's two-attempt budget, a standard first attempt retries with `-RetryAtHardFrom <failed model> -DifficultyReason "<reason>"`, retaining that model at hard effort. A first attempt already at hard retries with `-EscalateFrom <failed model> -Difficulty hard -DifficultyReason "<reason>"`, moving one non-frontier rung. A category without tiers (unprotected `mechanical`, which routes to the fast job) retries with `-EscalateFrom <failed model>` as before. Legacy callers without difficulty flags keep their escalation behavior. Like `-EscalateFrom`, `-RetryAtHardFrom` does not apply drift marks without `-Lane`; a constrained lane applies drift and may wait.

Bench caller effort overrides (including build-roster slot efforts) take precedence over roster tiers. Without an override, only coder and deep-thinker use roster tiers. The committed bank has no beyond tasks; the engine retains beyond support at hard effort, reported and never gating. Bank edits invalidate golden approval. Relabel proposals are skipped when standard and hard efforts are equal.

## Main-session delegation

Every session that hands work to another model resolves the category through this router first; the session model is never inherited by a subagent or a `codex exec` call. The category guide, the cheap-first rule (collecting is `mechanical`, interpreting is `analysis`; round up only when the result cannot be checked), and worked examples live in `D:\Claude\_Claude-Workspace\00_Resources\model-routing.md`, loaded through the root `CLAUDE.md` rule (2026-09-30). Roster note: coder is Codex-first by policy since 2026-09-30. Weekly use is observable for both vendors; at 95%, a job moves to its other-vendor backup.

## v2: one roster across both vendors

v2 routes delegated work from a short roster (at most 5 models) defined in `roster-schema.md`. Eleven categories map to five jobs: `mechanical` to fast; `routine-coding`, `complex-coding`, and `ui-frontend` to coder; `code-review`, `planning`, `deep-research`, `math`, and `analysis` to deep thinker; `long-form-writing` to writer; `image-generation` to illustrator. Each job has a first choice and a backup on the other vendor. Frontier models are never on the roster.

A caller that passes `-Lane` gets that lane's member of the pair or a `wait`. A caller without a lane gets the first choice, or the backup when the first choice's vendor is blocked, unselectable, or drifting. `vendor-limits.ps1` reads Codex weekly use from local session logs and Claude weekly use from `GET https://api.anthropic.com/api/oauth/usage`, using the `claudeAiOauth.accessToken` in `.credentials.json` under `CLAUDE_CONFIG_DIR` (falling back to `~\.claude`) with `anthropic-beta: oauth-2025-04-20`. It reads `seven_day.utilization`; at 95% or more either vendor is blocked and the job moves to its other-vendor backup. Claude readings are cached in `<state>/claude-usage.json` for 5 minutes. The router never refreshes or logs the token; a missing or expired token produces no reading and does not block Claude; a failed request falls back to the last cached reading, or to no reading when none exists. A recorded limit refusal also blocks that vendor until reset. If both vendors are blocked, the resolver returns `status = wait`, never a weaker model. The 5-hour Claude session figure appears only in the weekly cost report.

Research runs per category (`run-router-research.ps1 -Categories`), reading the named sources in `benchmark-sources.json` and storing readings under `<state>/readings/`. `build-roster.ps1` turns readings into a proposal: two independent comparable leads and no trail win a category; the job's primary category decides a multi-category job; a change needs two consecutive conclusive passes that covered the job; the fast job clears a quality floor, then the lower list price wins. A change sends one Discord DM and writes a report under `<state>/roster-proposals/`.

Manage the roster with `approve-roster.ps1`: `-Show`, `-Approve` (uses the approved roster), `-Revoke` (clears approval and uses the default roster with an alert), and `-DeclineDrift -Job <job>` (keep the first choice after a drift alert). Drift on a first choice sends that job to its approved backup until Danny approves the swap proposal or declines it.
Use `-Approve -Jobs fast,coder` to approve only named jobs when a full proposal exceeds the five-model cap.

At ship, register the Windows Scheduled Tasks from the **main checkout** with `pwsh -NoProfile -File scripts/model-router/register-router-schedules.ps1 -Apply`. They run the weekly cost report on Monday at 07:00 ET, the full research cadence daily at 01:00 ET, and the model-release check daily at 13:00 ET. Do not register them from a build worktree. Research runs only for a new frontier-vendor release (and its confirmation and follow-up passes) or on Danny's call. Refresh research (drift marks, readings older than six months) is queued only when the cadence is run by hand with `-Refresh`; the schedule never queues it (2026-10-06, after nightly re-queued refreshes repeated the same comparison).

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

Triggered comparisons stage outside outcome locks and revalidate roster model and effort before publication. Research offers incumbent effort-down even when it keeps the model. New-model checks retain release and day-seven research queues and refresh known frontier judges in bench/judge-config.json. Every triggered comparison is recorded in bench/trigger-log.jsonl with its requested identity (bank hash, judge pair, judge effort). A comparison whose job, candidate, incumbent, effort and identity already have a completed row is not run again: it logs a `duplicate` row and reuses the saved result from bench/triggered/, so a combined drift proposal still carries every job's evidence. Failed or unknown rows do not count as completed. Unknown alerts use stable identities. Weekly rubric reminders apply to the current bank and judge pair; rubric correction changes the bank hash and returns golden approval to shadow mode.

Use approve-roster.ps1 -ApproveEffort, -DeclineEffort or -RevokeEffort with -Job for separate effort proposals; approval and revocation revalidate exact model and effort; decline can close stale proposals. Coder and deep-thinker jobs without tier objects file no effort proposals and refuse effort approval or revocation until `-ApproveTiers -Job <job>`. Tier approval supersedes pending legacy proposals. The default roster routes deep-thinker standard work at medium effort.

## Private tasks and discrimination

The bench reads the committed tasks alongside a private bank at
`<state-parent>/bench-private-bank/<task-id>/`, beside the router state directory.
The private bank stays outside this public repo. A duplicate task id in the two
banks is an error. Golden review lists both banks and marks private tasks.
The combined hash includes every private file; adding, changing or removing any
task resets golden approval. An absent or empty private bank keeps the original
committed-bank hash. A missing or unreadable previously approved private bank is
named in the report.

Use `scripts/model-router/bench/add_task.py --state <state> --problem <file>
--answer <file> --job <job> --grader <exact|numeric> --difficulty <standard|hard>`
to add a private task. It creates the task folder and refuses to overwrite one.
`import_aider.py --source <local-clone> --ids <ids-file> --state <state>` imports
selected synthetic or licensed Python and JavaScript exercises as hard coder
tasks. `import_hle.py --source <local-jsonl> --ids <ids-file> --state <state>`
imports selected text-only exact-answer questions as hard deep-thinker tasks;
image and multiple-choice questions are skipped. Both importers refuse a bank
inside the repo. Check the source terms before importing. Never commit borrowed
exercise or question text, answers, imported tests, private bank files, source
exports, credentials, or reports that contain borrowed text.

Python exercises use the existing pytest grader. JavaScript exercises use
`nodetest`, a small dependency-free runner for the supplied test syntax and
matchers, with a timeout and no network. Its result reports skipped tests.
Golden review remains required before either kind of imported task can gate a
proposal.

A task that every tested configuration fails is reported as uninformative and
does not count toward parity. A private task that every configuration passes on
every rep in two consecutive completed runs of the same job and tier appears under
`proposed_drops`; Danny confirms removal, and the bench never removes it itself.
A tier without informative results is marked `insufficient_evidence` and cannot
support effort or tie proposals. A decided quality comparison supplies evidence
for effort-down and effort-up, even when pass counts do not separate the efforts.

## Ranked quality and proposals

Ranked tasks compare candidate and incumbent answers against the task's criteria.
Both frontier judges see the answers unlabeled, in a recorded random order.
SVG and HTML answers are rendered for judging. Results record each rep, judge
disagreements, invalid replies and the quality verdict: `candidate_better`,
`incumbent_better` or `no_difference`. Ranked tasks do not change pass counts.
Each verdict names the job, tier and both model-and-effort configurations.
For coder and deep-thinker, read the matching entry under `tiers`; the top-level
`quality_verdict` is null.

An unavailable answer is a draw (`answer_unavailable`), never a quality loss.
Unavailable judges, invalid replies and split judge votes also produce draws.
Draws alone do not establish a decided verdict. `no_difference` supplies tie
evidence only when at least one rep has both judges answer `no_difference`, or
the sides have actual wins that balance. A render failure loses that side's rep;
both renders failing is a draw.

The verdict narrows or adds proposals as follows:

- A model swap still needs the pass-fail gate and the existing winner conditions;
  it is blocked when the candidate loses on quality at any measured tier, and
  when the tier has ranked tasks but its verdict is undecided (judges unavailable,
  invalid replies or splits only). Draws never qualify a swap.
- Effort-down compares the lower effort as candidate with the current effort as
  incumbent. A quality loss blocks it, and so does an undecided verdict at a tier
  with ranked tasks. The writer never proposes effort-down.
- Effort-up compares the higher effort as candidate with the current effort as
  incumbent. A quality win can propose the higher effort when both pass-fail
  tables are known and the higher effort has no fewer passes, including equal counts,
  for coder, deep-thinker or writer, only at the measured tier. For the writer,
  strictly better means winning this quality verdict.
- A tie needs the existing parity conditions plus a decided `no_difference`.
  An insufficient-evidence tier cannot file a tie.

When a tier has no ranked task, its verdict is null and the previous proposal
rules apply. Each proposal that uses quality records its verdict, tier, both
configurations and run id. Approval re-reads that run's matching verdict and
refuses a changed tier, configuration, unsupported verdict or bank hash.
Proposals from before quality evidence was recorded retain their previous
approval behavior. Nothing changes routing without Danny's recorded approval;
resolving a model remains a lookup.

## Comparison spend stop

At the start of each job comparison the runner records both vendors' weekly
use, then reads them again between tasks. A move of more than 5 percentage
points by either vendor halts the comparison; exactly 5 points can continue.
A baseline must be a reading observed no more than 10 minutes before the
comparison started (`spend_baseline_max_age_minutes`); an older reading would
charge earlier jobs' use to this comparison. When a vendor starts without such a
reading, the runner rechecks between tasks and takes its first fresh reading as
that vendor's baseline. The 5-point rule
applies to each vendor once its baseline exists. While either baseline is missing,
a cap of 450 model calls, including answer and judge calls, applies across the
whole comparison and all its tiers. If a vendor's reading is later lost, that
vendor keeps its baseline and also goes under the cap, counted from the call
where the reading was lost, until a fresh reading returns. A reading more than
5 points below a vendor's baseline is treated as a weekly reset: it becomes the
new baseline and the report records the reset. The cap is a runaway guard: at
450 it is above every full comparison, so it stops only a comparison that has
grown well beyond the current bank. After the last task only the 5-point rule is
applied, so a comparison that finished is not discarded for reaching the cap.
The report's Codex quota column shows the weekly window. Readings marked stale, with future timestamps
or older than 6 hours are unavailable. Codex use comes from the 10080-minute
weekly window; the 300-minute window is not spend-stop evidence.
`spend_stop_points`, `spend_stop_model_calls`, `spend_reading_stale_hours` and
`spend_baseline_max_age_minutes` in `bench-config.json` default to 5, 450, 6 and 10; a persisted
`<state>/bench/judge-config.json` that lacks these keys takes them from
`bench-config.json`. Reports record the rules in force,
each baseline and its time, latest readings and call count. A halted comparison
marks its report and any completed per-tier reports `halted`; discrimination
history ignores halted runs. It files no proposal and exits without error so the
next job can still report.

## Bench ledger and timing

Every model call records `started_at_utc` and `duration_ms`; every tier records
`started_at_utc`, `finished_at_utc` and `wall_seconds`, and a multi-tier job sums
them. Per-vendor telemetry adds `calls`, `answer_calls`, `judge_calls`,
`dispatch_failures` and `duration_ms` (`total`, `p50`, `p95`, `max`) beside the
existing token, priced-cost and quota readings.

The engine appends one row per finished tier to `<state>/bench/ledger.jsonl`
(halted comparisons append the tiers that completed). A row carries the job, tier,
trigger, both configurations, bank hash, judges and judge effort, gate, verdict,
tasks passed per table, answer reps, wall time, and per vendor the call counts,
tokens, priced dollars, call latency and weekly-quota points moved. Reports stay
the evidence; the ledger is the long-run statistics record for assessing cost,
duration and quota per comparison over time.

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills\scripts\model-router\bench"
python bench_ledger.py --state "<state>" --summary
python bench_ledger.py --state "<state>" --backfill "<run>\report.json"
```

Backfill skips run ids already in the ledger. Ledger writes never fail a
comparison.

## Approved quota ties

A non-shadow tied bench run files `<state>/tie-proposals/<job>.json` for standard ties
and `<state>/tie-proposals/<job>-hard.json` for hard ties, only when
its two tested model-and-effort configurations equal the roster job's first and
backup configurations. It records `type: tie`, `status: pending`, `job`, `tier`,
`configurations` (candidate and incumbent, each with model and effort), `run_id`
and `bank_hash`. Identical pending, declined, approved or revoked evidence keeps its
original proposal, status and run ID; a later tied run does not ask again.
Use `approve-roster.ps1 -ApproveTie -Job <job>` to approve it,
`-DeclineTie -Job <job>` to decline it, or `-RevokeTie -Job <job>` to remove
approved tie evidence. Hard ties require `-Difficulty hard` on all three actions. Approval revalidates both models, both efforts and the
current task bank; it leaves first and backup unchanged.

The optional roster job field `tie_evidence` carries `tier`, `configurations`,
`run_id`, `bank_hash`, and `approved_at`. It is published with the roster.
The supported tiers are `standard` and `hard`. Full and `-Jobs` roster approval preserve
existing tie evidence when both models and efforts are unchanged, and drop it
when either slot changes. Evidence becomes void if either model, either effort,
or the bank hash changes. The bench records `bench/bank-hash.json` with
`task_bank_sha256` and `written_at` at run time and whenever golden approval is
written. Tie evidence is checked against the bank hash recorded at the last
bench or golden-review run; edits to the bank take effect at the next such run.
Resolve reads that file without starting Python. An absent hash file skips the tie without an alert; the Mac never runs the bench and never applies ties. A present unreadable or mismatched hash voids the evidence with the existing `roster-tie-invalid:<job>` alert.

With valid approved evidence and none of `-Lane`, `-EscalateFrom` or `-RetryAtHardFrom`, the tie-break
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
protected handling retain precedence. A vendor incident block needs a monitored
status-page component in outage (`partial_outage`, `major_outage` or
`under_maintenance`) at the time a dispatch fails; `degraded_performance` is
recorded in the diagnosis (`checks.status = degraded`) but never blocks, because
vendors leave it standing for days while calls succeed. The block clears when the
component is no longer in outage. Ordinary Claude usage refreshes, stale
incident recovery and the bounded Codex catalog retry retain their existing
behavior. A tie-selected vendor and a catalog fallback undergo the ordinary
block evaluation, including its bounded Claude refresh. The weekly comparison
itself adds no network or model call.
# Frontier requests

Frontier requests are Windows-only; the Mac never raises them.

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
