# FS-63: Codex job-wrapper capacity backoff

Completed October 13, 2026, 11:13 AM ET in `fix/codex-capacity-backoff`, based on
`dfe60f09f5c2a69f87e0dcce04bd8882219e9c2a`. No version bumps, merge, push, live job
relaunch, or nested delegation. All implementation writes are in this worktree.

## Behavior

- The shared process helper recognizes capacity and overload diagnostics on stderr,
  including the selected-model refusal, named model/server/service overload,
  overload error codes, and over/at-capacity wording. It returns the matched signal
  as `failure_detail` and `failure_category: capacity` on a failed process.
- The chunk wrapper handles capacity before connectivity/status diagnosis. It waits
  **5, 10, then 20 minutes** and retries the identical invocation, with at most four
  capacity attempts and **35 minutes of scheduled waiting**. `-CapacityBackoffMs`
  accepts an array for fixtures; an empty array disables retries. Execution time is
  additional to the wait budget, and each capacity retry gets a fresh attempt timeout.
- Model, effort, prompt, output path, and the outer chunk attempt number remain the
  same. A run pin is honored. Capacity does not select a backup, escalate, create a
  usage block, or emit the `vendor-error:` alert used for unexplained failures.
- Each wait goes to stderr, the redacted stream, and provenance with ET start/resume
  timestamps. `dispatch_attempts` records every launch and its duration/exit/signal;
  `capacity_backoffs` records waits. Provenance is saved before sleeping. Earlier
  streams are retained with attempt separators.
- Retries start fresh execs and remove retained output before launch. A capacity
  refusal's partial final message is removed immediately; exhausted capacity has
  no output path/hash. This preserves today's output-path retry semantics; it does
  not roll back project files written by a worker before refusal.
- Exhaustion reports `CODEX_CAPACITY_EXHAUSTED`, category `capacity`, and the matched
  signal. Successful recovery clears the terminal failure while retaining attempt
  evidence. Capacity bypasses the probes that would have recorded a degraded status
  and `ROUTER_UNEXPLAINED`.
- Usage-limit handling remains the existing `environment` / `ROUTER_LIMIT` vendor-block
  path, with `failure_detail: quota`; it does not enter capacity backoff.
- Outcome mining retains capacity and its detail on both provenance and acceptance
  paths, drops inappropriate unexplained diagnoses, and excludes capacity from model
  quality/drift calculations. The cost-report unexplained alert reader only consumes
  `vendor-error:` deliveries, which capacity never produces.

## Verification

Every executed suite was inspected first: PowerShell fake CLIs, isolated router state,
no Python and no pytest. The production schedule was tested through the existing
clock/sleep seam; short schedules performed actual millisecond sleeps. Main comparisons
ran from a `git archive dfe60f0` snapshot inside this worktree, without changing branches.

| Suite/check | Main dfe60f0 | Branch | Delta | Result/evidence |
| --- | ---: | ---: | ---: | --- |
| `scripts/model-router/tests/test-consumer-wiring.ps1` | 343 | 343 | 0 | Full suites, exit 0; both `SUMMARY: 343 passed` |
| `skills/dt-build/scripts/tests/test-host-adapters.ps1` | 142 | 142 | 0 | Full suites, exit 0; both `SUMMARY: 142 passed` |
| `scripts/model-router/tests/test-codex-capacity-backoff.ps1` | 0 (absent) | 104 | +104 | Full new suite, exit 0; `SUMMARY: 104 passed` |
| Executed assertion total | 485 | 589 | +104 | No assertion removals or skipped portions in executed suites |
| PowerShell parse | N/A | 4 files | N/A | Both helpers, outcome importer, and new fixture parse without errors |
| Shared test ownership | N/A | valid JSON | N/A | New suite declared under `model router` release-summary ownership |
| Whitespace | N/A | clean | N/A | `git diff --check` |
| Live vendor recovery / original three jobs | N/A | unverified | N/A | No live Codex dispatch or job relaunch performed |

The +104 comprises 17 signal recognition/exclusion checks, 82 chunk checks (including
recovery/exhaustion follow-ups), one shared-process classification check, and four
outcome-import checks. The chunk fixtures prove identical actual CLI argv/prompt,
pinned model/effort, exact waits, pre-sleep provenance, ET logging, clean output,
terminal exhaustion, quota precedence, and a simulated **74-minute first attempt**
followed by successful retries despite a 1-second attempt timeout. The outcome fixture
imports 20 passing quality observations plus 11 capacity events; all 11 retain their
detail, none retain unexplained diagnosis, and no quality drift/bench request occurs.

Full passing output: [fs-63-verification.log](<D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-codex-capacity-backoff/_planning/fs-63-verification.log>).
Line endings and trailing whitespace are normalized for Git.
SHA-256: `dd00a92015f06f5e3a3d5f57268ebd55ae2affb967e3972454bff9fbe291f202`.

To repeat the new capacity suite:

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills-codex-capacity-backoff"
pwsh -NoProfile -File scripts/model-router/tests/test-codex-capacity-backoff.ps1
```

## Deferred until the coordinator lifts the quiet window

No Python was started, including harmless Python transitively invoked by larger
PowerShell suites. Counts/deltas for these deferred checks remain unverified.

Full existing outcome-import suite: its fixture computes bench-bank identity using Python.

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills-codex-capacity-backoff"
pwsh -NoProfile -File scripts/model-router/tests/test-update-outcomes.ps1
```

Outcome concurrency: drift proposal validation can invoke Python even with its fake bench.

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills-codex-capacity-backoff"
pwsh -NoProfile -File scripts/model-router/tests/test-outcome-concurrency.ps1
```

Full dt-build regression: starts Python for bootstrap measurements and later fixture commands.

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills-codex-capacity-backoff"
pwsh -NoProfile -File skills/dt-build/scripts/test-dt-build-regressions.ps1
```

Shared-process bench transport regression: uses a Python appserver peer.

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills-codex-capacity-backoff"
pwsh -NoProfile -File scripts/model-router/tests/test-bench-json-transport.ps1
```

Router report/routing pytest coverage:

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills-codex-capacity-backoff"
python -m pytest scripts/model-router/tests/test_cost_report.py scripts/model-router/tests/test_routing_compliance.py -q
```

The packaged release gate was not run: this task explicitly forbids version bumps,
and its full gate includes the deferred regression suite. Integration/release owns
versioning and the final release gate.

## Rebase and close-out notes

`68cc7f4` was inspected read-only. Its sandbox changes are not included. On a later
rebase, keep a single `failure_detail` property, preserve both sandbox details, and
allow outcome detail import for **environment and capacity**. Keep both independent
helper functions added near the start of `invoke-codex-process.ps1`. Shared release
consumers are unchanged; the new fixture has its own ownership entry.

The coordinator's pre-existing `_planning/fs-63-task.txt` and
`_planning/fs-63-wrapper.log` remain untouched and unstaged. The session audit found
only task-specific instructions/state, captured here; no canonical scaffold writes
or workspace sync were performed under the worktree-only/no-push scope.

Automatic approval review rejected cleanup of the temporary baseline directory,
archive, and individual scratch logs with only `blocked by policy` as its reason.
They remain untracked under `_planning/fs-63-main/`, `_planning/fs-63-main.tar`, and
the individual `fs-63-*.log` test outputs. The consolidated verification log above
is the committed evidence. No alternate deletion mechanism was attempted.
