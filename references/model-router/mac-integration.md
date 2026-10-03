# Windows/Mac router operation

Windows owns roster approval/revocation, publication, proposal generation, research,
outcomes importing (`scripts/model-router/update-outcomes.ps1`), benchmarking and
cost reports. Mac reads the approved roster and observes its own subscriptions.
Mac-local raw dispatch events, quota readings, refusal/incident timers, drift and
alert markers remain local; they are separate from the Windows importer and writers.
Never run `update-outcomes.ps1` on Mac.

Windows reads its authoritative `model-router/state/roster.json` beside the permanent
main checkout. Approval/revocation and cadence entry atomically publish the validated
roster, including approval status, to sibling `model-router/shared/roster.json`.
Normal workspace sync delivers that snapshot; revocation reaches Mac only after sync.
Mac validates the shared file on every resolve. Missing, invalid or revoked state
uses the existing default roster and alert semantics; it never revives cached approval.
Only the roster snapshot belongs in sync, never runtime caches or credentials.

Mac runtime defaults to `~/Library/Application Support/DannyModelRouter`, shared by
all local worktrees. Windows retains its existing sibling runtime path and ignored
state. Windows alone owns research, triggered internal benchmarking, approvals and
reporting. Mac remains an observer. The retired monthly canary is replaced by the
Windows-owned `scripts/model-router/bench` successor suites listed below. Reconcile the live monthly schedule during authorized deployment; changing the test harness alone does not change installed schedules.

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

From the permanent Windows primary checkout:

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills"
pwsh -NoProfile -File scripts/model-router/tests/test-mac-regressions.ps1
```

This actual-OS Windows-only gate declares 20 suites: the 14 retained suites plus
`test_bench_tasks.py`, `test_bench_review.py`, `test_bench_runner.py`,
`test-bench-runner.ps1`, `test_bench_integration.py`, and `test-bench-integration.ps1`.
The obsolete `test-canary.ps1` entry is removed. Use the generated per-suite evidence and final summary for the actual result; the declared list alone is not a passing gate.

M01 contains Windows authority, named-mutex and `Start-Process -WindowStyle Hidden`
fixtures. Do not run or describe the full gate as native Mac testing.
`test-mac-observer.ps1` stands alone safely on Mac; actual Apply refusal
assertions are conditional on non-Mac, while installation fixtures use fake commands.
Accepted Windows evidence executes 84 observer checks (prior 81 + 3); Mac expects 82 (prior 79 + 3) because the two real
non-Mac CLI inventory and Apply refusal assertions are skipped. The Windows-emulated Mac foundation has 58 checks: the prior 55 plus direct benchmark refusal, no state creation, and fresh-child CLI refusal. Quota has 72 checks after the credential-expiry correction.
These counts are fixture evidence, never native acceptance.

Each suite uses a bounded fresh child, isolated runtime/shared/session/config/temp
paths, exclusive missing Claude credentials and an isolated fixture Codex model cache.
Unexpected alert transport records a failure even if the alert API catches its throw.
Named suites replace these with their own fixtures. Root environment, HOME,
LOCALAPPDATA and user credential files remain untouched. Logs and exact per-suite
counts persist under the printed `EVIDENCE` path; fixtures are cleaned on errors.
Any child failure, timeout, missing count or unexpected alert fails the gate. Warnings
remain visible and full output is retained. Python uses `-B`, no pytest cache provider
and an owned `--basetemp` directory.

## Native Mac ship gate: UNVERIFIED

Actual Mac credentials, service label, tool/model availability and launchd/login
behavior remain **UNVERIFIED**. Authenticated capture requires a **Mac-local session**
(or separately authorized working SSH access). Windows fixtures cannot pass this gate.
Root also owns aggregate release/version bumps and the version-policy gate; no bump
or live installation is part of this milestone.

In that later session, replace `/absolute/main/danny-skills` with the synced permanent
checkout on `main`, and use the verified absolute PowerShell executable:

```powershell
cd "/absolute/main/danny-skills"
pwsh -NoProfile -File scripts/model-router/router-state-inventory.ps1 -Json
pwsh -NoProfile -File scripts/model-router/tests/test-mac-observer.ps1
pwsh -NoProfile -File scripts/model-router/run-mac-observer.ps1
pwsh -NoProfile -File scripts/model-router/resolve-model.ps1 -Category routine-coding -Json
pwsh -NoProfile -File scripts/model-router/register-mac-router-schedules.ps1 -RepoPath "/absolute/main/danny-skills" -PwshPath "/absolute/pwsh"
```

Inventory is read-only and prints effective paths, provenance and availability, never
tokens. Its credential status remains UNVERIFIED until actual account/source checks.
Inspect the observer receipt at `<runtime>/mac-observer-receipt.json`; confirm fresh
local quota, approved shared roster availability and resolver backup/wait behavior
using local fixture refusals, without paid model calls or production refusal writes.

The installer defaults to preview with no writes; it rejects worktree installation.
After preview approval at the later ship boundary, add `-Apply` to the same command.
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
