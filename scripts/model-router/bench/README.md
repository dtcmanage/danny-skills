# Internal benchmark task bank and golden review

`generate-fixtures.py --output <temporary-folder>` reproduces seeded synthetic
fixtures without changing the bank. Retained legacy task fixtures and harness
support are copied from the bank; tests independently pin original source hashes.
The obsolete canary runner is removed; historical outcomes remain readable.

Python grader dependencies are pinned in `requirements-grading.txt`. The React
render harness owns `tasks/ui-frontend-card/harness/package.json` and its lockfile.
Provision these controlled dependencies outside candidate execution. The grader
never executes a candidate's install or download instructions. React renders in
JSDOM; Tailwind utilities are compiled and DOM selection/preservation are asserted.
This checks behavior and computed layout rules, not pixel appearance in Chromium.

Windows alone owns benchmark/research execution, approvals and reporting; Mac is an observer.

Quota guard refusals halt the comparison with `status: deferred` in the bench ledger,
including the blocked vendor and `resume_after_utc`. If no reset is known, that time
is a one-hour recheck (`resume_after_source: recheck`), not permission to bypass the guard.
Calls already in flight may finish; queued calls stop and blocked calls create no outcomes.

For read-only historical analysis, run `python scripts/model-router/bench/bench_outcomes.py
--state <router-state> --quota-blocked` to emit JSONL line numbers and complete rows matching
the old environment / `quota blocked` pattern. `--summary` instead reports pass/fail-only
rates by job, tier, model and effort. Unknown and ungraded rows are excluded from those
denominators; an all-unknown group has a null rate. Neither command edits history.
Comparative verdicts remain conservative: unresolved unknowns prevent a decision or proposal.

Research, eligible new-model detection and observed performance drift automatically request comparisons. Benchmark execution generates the golden-review page and pending state. The weekly report surfaces pending approval. To review the actual Windows bank, use the permanent router bench state:

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills"
python scripts/model-router/bench/review.py --state "../model-router/state/bench" --port 0
```

Open the printed `http://127.0.0.1:<port>` URL to save choices. The generated HTML
is also suitable for a read-only preview; its controls require the running server.
`--generate-only` writes a preview and pending state without opening a server.
State layout is `golden-approval.json` and `review/<date>-golden-review.html` under
the supplied folder. For synthetic validation, supply a temporary state folder instead. Only Danny approves the answers and rubrics.

All tasks must be approved for overall approval. Needs-change survives restarts.
Any bank byte/path change resets choices, regenerates HTML, and rejects stale
forms. SHA256 includes relative names and bytes of the entire task bank, including
support code and dependency lockfile; installed dependencies and Python caches
are excluded. Framework metadata remains provisional. The server binds only
127.0.0.1, rejects reserved ports and foreign Host/Origin, and uses a session CSRF
token. It sends no alerts and changes no runner, trigger, roster, or live state.

## Release test counts

The combined Windows gate declares 23 suites: the previous 20 plus cache-duration,
judge-effort and proposal-validity regressions. Read the generated evidence for the
actual pass/fail result; declared suites alone do not establish acceptance.

Each PowerShell benchmark suite increments its counter only after an existing
`Assert` succeeds, including checks inside loops and injected callbacks. The runner
captures both fresh refusal children, requires exactly one positive numeric summary
with zero failures from each, and adds those measured counts to its own checks.
Child output is prefixed so only the parent's final `SUMMARY` is authoritative.
A nonzero child exit, missing/empty summary, duplicate summary or invalid count
fails the parent. No count is inferred from scenario labels or assertion source lines.

Transport recovery: `turn/moderationMetadata` is accepted only with typed thread/turn
IDs bound to the active turn. Its raw metadata is discarded before event buffering.
Unknown methods and uncaptured warnings fail closed. Diagnostics retain at most eight
shape records with fixed field names, types and bounded lengths/hashes, never raw text
or metadata. The previously captured disabled-host warning remains the only warning
accepted; this repair adds no warning shape.

The disabled code-mode host still declares custom `functions.exec` and function
`functions.wait`. No tools means none usable; these two declarations are accepted
only after verified controls and the captured disabled-host warning for the same
turn. Tool invocation attempts remain forbidden. The final raw message may carry
`status: completed` and empty `annotations` and `logprobs`; other values fail closed.
Raw-evidence failures retain only a fixed reason (`raw_item_invalid:<fixed type or
OTHER>`, `response_count`, or `answer_mismatch`), never raw item data.

Every real comparison generates the installed app-server JSON schema before any model
call, writes `bench/protocol-schema.json`, and includes new methods in its report.
New methods are evidence, not authorization to accept them. Six structural failures
across signatures with no successful Codex completion halt all queued calls through
the shared spend guard; in-flight calls may finish. Structural failures have no retry;
timeouts retain the old retry rule. Completed tiers are retained but cannot qualify
proposals after a comparison halt. Halt alerts use the existing signature dedupe;
read-only ledger reporting never sends alerts.

Ranked quality is unknown without at least three jointly scored rounds. Missing answers
and unavailable judges cannot establish a tie. The ledger reader displays historical
unscored sides as unknown without rewriting saved rows or validating old tie approvals.

A coordinator may run one tiny transport probe with
`pwsh -NoProfile -File scripts/model-router/bench/smoke-transport.ps1 -Vendor codex -Model <non-frontier-model> -Live -OutDir <temporary-folder>`
(or `-Vendor claude` with a Claude model). Omitting `-Model` uses the configured fast
slot for that vendor and its effort. It uses the benchmark Codex transport or
the existing Claude `--safe-mode` launch. Without `-Live` it refuses before any call.
Each event is marked `seen` or `not-exercised`; success proves only exercised paths.
The sanitized report contains no raw model output, metadata or warning text. A warning
shape can be approved only in a follow-up after coordinator evidence; no smoke result
changes an allowlist automatically.
Any status other than `ok` exits nonzero. Reports preserve the failure category,
fixed detail and bounded reason. Job commands ending in `exit $LASTEXITCODE` preserve
the child exit code; an unknown smoke report is a failure.

## Codex structural failures

All Codex comparison failures use `codex_appserver.classify_failure` before
counting or retrying, including wrapper crashes, invalid output and engine
dispatch exceptions. Six structural failures across signatures with zero Codex
completions halt the comparison; structural reps are never retried. Transport
timeouts retain the old retry rule. Real identity changes and quota refusals
retain their named invalidation/deferral rules; missing identity fields are
structural. Auth failures use `auth:account` or `auth:unauthorized` and tell the
operator to re-authenticate. API-key auth remains rejected.

Final `codex error: serverOverloaded` and stream-drop errors are structural.
An outage halts cheaply at six and can be rerun; one such event after a success
leaves that rep unknown without retry. Claude retry behavior is unchanged.
