# Linux owner and Windows/Mac router observers

`<danny-skills>` is the resolved danny-skills repo root; quote script paths when substituting it.

The Linux session host CT202 owns roster approval/revocation, publication, proposal generation, research,
outcomes importing (`<danny-skills>/scripts/model-router/update-outcomes.ps1`), benchmarking and
cost reports. SNOWWHITE (Windows) and Mac read the approved roster and observes its own subscriptions.
Mac-local raw dispatch events, quota readings, refusal/incident timers, drift and
alert markers remain local; they are separate from the Linux owner importer and writers.
Never run `update-outcomes.ps1` on Mac.

Linux reads its authoritative `model-router/state/roster.json` beside the permanent
main checkout. Approval/revocation and cadence entry atomically publish the validated
roster, including approval status, to sibling `model-router/shared/roster.json`.
Normal workspace sync delivers that snapshot; revocation reaches Mac only after sync.
Windows and Mac validate the shared file on every resolve, falling back to their local state roster only when the shared file is absent. Linux reads its state roster first, falling back to shared only when state is absent. Invalid or revoked preferred rosters use the default roster and alert semantics; they never revive cached approval.
Only the roster snapshot belongs in sync, never runtime caches or credentials.

Mac runtime defaults to `~/Library/Application Support/DannyModelRouter`, shared by
all local worktrees. Windows retains its existing sibling runtime path and ignored
state. Linux alone owns research, triggered internal benchmarking, approvals and
reporting. SNOWWHITE and Mac remain observers. The retired monthly canary is replaced by the
Linux-owned `scripts/model-router/bench` successor suites listed below. Reconcile the live monthly schedule during authorized deployment; changing the test harness alone does not change installed schedules.

## Configuration

| Variable | Meaning |
| --- | --- |
| `DT_MODEL_ROUTER_STATE` | Explicit machine-local runtime root; use isolated fixtures or deliberate operator configuration. |
| `DT_MODEL_ROUTER_SHARED` | Explicit shared snapshot directory. Without this, a runtime override uses `<state>/shared`; otherwise main-checkout sibling `model-router/shared`. |
| `DT_MODEL_ROUTER_CODEX_SESSIONS` | Local Codex session source; otherwise `CODEX_HOME/sessions`, then `~/.codex/sessions`. Never point Mac at Windows logs. |
| `CODEX_HOME` | Local Codex configuration/catalog root. |
| `DT_MODEL_ROUTER_CLAUDE_CREDENTIALS` | Exclusive explicit credential JSON file; disables Keychain fallback, including when missing. |
| `CLAUDE_CONFIG_DIR` | Claude config root with `.credentials.json`; otherwise `~/.claude/.credentials.json`. |
| `DT_MODEL_ROUTER_CLAUDE_KEYCHAIN_SERVICE` | Exact service label verified on this Mac for this account/config. No guessed default service. |

Verify the actual CLI-managed Keychain service and account locally without displaying
token bytes. A custom Claude config without an explicitly verified service reads only
its own file and reports unsupported Keychain source. Disagreeing available file and
Keychain tokens produce no new reading. Missing, locked, invalid or expired sources
produce no new reading. The existing cache policy keeps a same-locator reading for
five minutes, attempts refresh afterward and retains that reading on refresh failure;
reset expiry clears its used percentage. A changed locator or unidentified legacy
cache is rejected. Secrets stay in native CLI stores, never router state or sync.
The observer may call the authenticated subscription usage endpoint; it makes no paid
model calls, research, publication, external alert sends or Git sync.

## Portable verification boundary

The aggregate runs on the actual Linux owner host (CT202). It includes owner CLI
entry points, so Windows and Mac observers cannot run the complete selection. It
uses the standard build-test Python resolver and the current PowerShell installation.
Child interpreters inherit dt-build's shared startup-profile guard against the
Linux .NET JIT profile race.

On CT202:

```bash
cd "/home/danny/Claude/_Claude-Workspace/Skill Creation/danny-skills"
pwsh -NoProfile -File "<danny-skills>/scripts/model-router/tests/test-mac-regressions.ps1" -PythonWorkers 4
```

All 26 declared suites run, including router, benchmark, cost-report and dt-build
regressions. Named mutexes and process/output capture work on Linux. The Windows-only
`Start-Process -WindowStyle Hidden` option in benchmark integration is conditional;
no portable module is skipped. Windows file-sharing locks, junction behavior and
Windows sandbox arguments require separate native Windows wrapper evidence.
Benchmark PATH fixtures use npm's `.cmd` on Windows and an executable symlink on
Linux, followed by the host's native executable name. The `.cmd` process-vector
assertion remains exercised on Linux. Provision the UI grader in each fresh tree
with `npm ci --ignore-scripts` in
`<danny-skills>/scripts/model-router/bench/tasks/ui-frontend-card/harness` before
running the selection. The per-suite deadline remains 900 seconds; a stalled
fixture is a failure requiring diagnosis.
Use the generated per-suite evidence and final summary for the actual result;
the declared list alone is not a passing gate. Do not describe Linux fixtures as
native Windows or Mac acceptance.
`test-mac-observer.ps1` stands alone safely on Mac; actual Apply refusal
assertions are conditional on non-Mac, while installation fixtures use fake commands.
Mac reporting collection is a successful no-op before output/cache creation;
router cost reporting refuses non-Linux owner operations before writes. Integration
tests emulate Mac to verify both contracts. Exact check counts come from current
evidence, never historical fixture totals.

Each suite uses a bounded fresh child, isolated runtime/shared/session/config/temp
paths, exclusive missing Claude credentials and an isolated fixture Codex model cache.
Unexpected alert transport records a failure even if the alert API catches its throw.
Named suites replace these with their own fixtures. Root environment, HOME,
LOCALAPPDATA and user credential files remain untouched. Logs and exact per-suite
counts persist under the printed `EVIDENCE` path; fixtures are cleaned on errors.
Any child failure, timeout, missing count or unexpected alert fails the gate. Warnings
remain visible and full output is retained. Python uses `-B`, no pytest cache provider
and an owned `--basetemp` directory.

## Native Mac release verification

Record actual Mac credentials, service label, tool/model availability and launchd/login
evidence against the exact released commit in the release verification report.
Authenticated capture requires a **Mac-local session** or authorized working SSH
access. Windows fixtures cannot establish native operation. Preserve prior natural-login
evidence when the installed observer is unchanged; do not force another logout.

Replace `/absolute/main/danny-skills` with the synced permanent
checkout on `main`, and use the verified absolute PowerShell executable:

```powershell
cd "/absolute/main/danny-skills"
pwsh -NoProfile -File "<danny-skills>/scripts/model-router/router-state-inventory.ps1" -Json
pwsh -NoProfile -File "<danny-skills>/scripts/model-router/tests/test-mac-observer.ps1"
pwsh -NoProfile -File "<danny-skills>/scripts/model-router/run-mac-observer.ps1"
pwsh -NoProfile -File "<danny-skills>/scripts/model-router/resolve-model.ps1" -Category routine-coding -Json
pwsh -NoProfile -File "<danny-skills>/scripts/model-router/register-mac-router-schedules.ps1" -RepoPath "/absolute/main/danny-skills" -PwshPath "/absolute/pwsh"
```

Inventory is read-only and prints effective paths, provenance and availability, never
tokens. Credential status requires actual account/source checks.
Inspect the observer receipt at `<runtime>/mac-observer-receipt.json`; confirm fresh
local quota, approved shared roster availability and resolver backup/wait behavior
using local fixture refusals, without paid model calls or production refusal writes.

The installer defaults to preview with no writes; it rejects worktree installation.
For an authorized installation, after reviewing the preview, add `-Apply` to the same command.
It owns only `~/Library/LaunchAgents/com.danny.model-router.observer.plist`, renders
absolute paths and captured configuration, `RunAtLoad`, a four-hour `StartInterval`
(14400 seconds), finite observation and runtime stdout/stderr file logs. Reinstall
is idempotent. To uninstall, use the same command with `-Remove` instead of `-Apply`;
it bootouts only its own label and removes only its own plist.

Capture `launchctl print gui/<actual-uid>/com.danny.model-router.observer`, a new
runner receipt and a receipt after an actual login. Verify the released main code
arrived through normal sync, the exact subscription/service/account and CLI models,
default/override paths, backup/wait behavior, no extra Mac research/report schedules,
and no synced runtime or secret files before accepting native operation.
