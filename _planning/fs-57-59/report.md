# FS-57 / FS-58 / FS-59 resume report

Worktree: `D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-dt-job-approve-lock-selection`

Branch: `fix/dt-job-approve-lock-selection`
HEAD remains WIP `81e8949436812e9871928952f5d257e21a0a0f60`. Changes remain uncommitted.

**Code and eligible PowerShell verification are finished. Python verification and rollout are pending.** The File Sorter j-0028 quiet window remains authoritative until the coordinator releases it; reaching about 1 PM ET does not itself authorize tests. No Python, pytest, grader, installer, live dt-job, model dispatch, commit, version bump, merge, deployment, or canonical scaffold write was performed in this resume. All launched test processes were owned fixtures and have exited.

## Changes and causes

### FS-57: approval while a coordinator closes out

The old operator guard refused approval while any watcher coordinator lived. The WIP instead queues an external operator's exact pending boundary, preserving who requested it, when, the operation/event sequence, run context, and coordinator PID/start identity. Self-approval through coordinator/job environment and coordinator ancestry remains refused. Consumption waits for the recorded identity to exit, supersedes changed boundaries, and recovers interrupted persistence without duplicating approval/event history.

This resume adds assertions that both the receipt and durable approval history say `applied`. Repeated immediate approvals now work without a queue file: only the latest exact operation, while runnable and with no pending approval, is idempotent. An older operation is refused. A queue repeat must also match its operation. The watcher fixture's array append fix from WIP is retained and verified in the full suite.

### FS-58: one machine lock and separate admission/execution budgets

The WIP introduced the fixed OS lock and authoritative grading admission. This resume completes the two requested layers:

- Explicit helper: `scripts/pytest-lock.py` and raw-argv PowerShell adapter. It adds no pytest plugin, test, fixture, marker, option, or normal output. It removes only the installer-owned guard plugin/path from the child environment, preserving the sealed gate's original pytest loading and Python path. Ownership metadata remains available to verified descendants. The new sealed fixture compares named plugin inventory, complete `sys.path`, collected node IDs, and retained stdout/stderr bytes; only its fixture terminal reporter suppresses nondeterministic timing. Pytest's process-specific numeric manager registration ID is excluded from inventory comparison, since it differs between two ordinary baseline processes too.
- Automatic guard: `scripts/pytest-guard/danny_pytest_guard.py`, registered only in fixture child environments so far. It acquires at `pytest_configure` with `tryfirst`, releases at session finish, and uses `pytest_unconfigure` as error cleanup. It adds no tests, fixtures, markers, options or output lines. Waiting diagnostics go only to stderr. `DANNY_PYTEST_GUARD=0` performs no lock/helper work. Verified ancestor ownership is reused.

Both layers use `C:/ProgramData/DannyPytest/exclusive.lock` on Windows (`/tmp/danny-pytest-machine/exclusive.lock` elsewhere), not a sandbox-specific temp path. Atomic holder metadata contains PID, process start identity, command, ET start, token, admission state and held/released state. Waits default to 1800 seconds; OS handle closure/crash releases ownership. Inheritance requires a busy OS lock, matching admitted holder/token, matching process identity, and verified ancestry. A sibling with a copied environment token cannot inherit.

Verified waiting-process records prevent a raw guarded pytest waiting in configure from being mistaken for an executing legacy suite by the explicit helper. A matching Python-manager parent forwarding the same exact pytest invocation is also excluded; stale identities and different parent selections are not excluded. The explicit helper checks independent legacy pytest before launch, rechecking every 30 seconds with a 10-second subprocess bound. The auto-loaded guard performs no legacy inventory and starts no child process. No caller is killed to obtain admission.

ET timestamps use `ZoneInfo` when available and otherwise stdlib datetime arithmetic for US Eastern DST rules from 2007 onward. No tzdata installation or new dependency is required. Deferred tests force absent tzdata and cover winter/summer and both DST transition seconds.

`bench_engine.grade_answer` takes the lock before creating its timed grader subprocess and copies ownership afterward. Copied/private banks get the canonical helper from `grader-runner.py`. Direct `_grading.grade_python` also acquires before its deadline, then starts pytest directly under that context rather than adding another helper subprocess. Existing socket/no-network guards and result-ledger checks remain intact. Verified inherited contexts reuse the ancestor's completed admission rather than start another lock wait inside candidate timing.

The same budget separation now covers the Mac launcher, dt-job runner and milestone acceptance verifier. The latter two use a ready marker; their execution deadline starts after admission. Runner heartbeats continue while waiting. Command detection parses actual pytest executable/module/`pytest.main` invocations, including literal shell commands, rather than treating comments, output strings or filenames mentioning pytest as a pytest job.

`.ship.json` now invokes the explicit lock around `scripts/ship-gate.ps1`, which retains the original nine release checks and their failure exits. Lock contention/guard fixture drivers are verified separately; enclosing those drivers in an inherited production lock would invalidate their deliberate competing-owner cases. The release gate and packaging are not run here because Python verification and requested version bumps are pending.

### FS-59: model selection during execution

The old disclosure existed only in completion provenance. The WIP's two vendor wrappers publish immediately after selection into atomic `jobs/<job>/model-selection.json` and stderr. Individual/run status exposes the sidecar while jobs run. Worker start waits at most five seconds for disclosure, while queued dependency jobs return immediately. Retry wrappers publish their actual new selection; stderr retains history. Wrappers do not write lifecycle job JSON. These files are retained; their full regression suite is deferred because it launches Python.

### FS-62: explicitly deferred

This checkout has run-pin suffix appending and the wrapper's 240-character check, but **no review-authoring reservation implementation**. Searching `scripts/` and `skills/` found no reservation lifecycle to validate before reserving or release on pre-model refusal (`fs62-scope.log`). Moving only the wrapper check would not satisfy the requested fix. Under the “small and same-files” condition, FS-62 is left unchanged for the coordinator to repair in the tree containing review authoring/reservations. The required future regression is 227 + 21 = 248 refusal before reservation, cap-minus-suffix boundary acceptance, and release on every pre-model refusal. No reservation was consumed here.

## For File Sorter

**FS-58 correction (2026-10-13; Python verification deferred during the renewed 1 PM ET quiet window):** the auto-loaded guard now calls `pytest_lock(inventory=False)`. Inside pytest it only acquires/releases the shared OS lock, publishes ownership/waiter metadata, or reuses a verified ancestor. It starts **no child process**, including during waiting, ancestor verification, and error cleanup. Windows identity/ancestry checks use stdlib `ctypes` (`GetProcessTimes` and Toolhelp); Linux uses `/proc`, macOS uses in-process `libproc`. Both helper and guard use the same native process-start identity, with token, busy-lock, admitted-holder and ancestry checks retained. `DANNY_PYTEST_GUARD=0` remains a complete lock-work opt-out.

Legacy-pytest inventory is intentionally dropped from the auto-loaded path: File Sorter's production-state guard forbids the PowerShell inventory subprocess, and command-line inventory is unnecessary to serialize cooperating guarded sessions. **An independent unguarded legacy pytest does not participate in that serialization.** Use the explicit helper for legacy inventory before launch; its existing CIM/`ps` inventory remains enabled and bounded. No change to File Sorter's guard is needed.

The previous File Sorter dry run in `after-quiet/filesorter-dryrun.log` failed with `unsafe-powershell-wrapper` because our guard launched CIM from inside pytest. Its baseline also failed because the selected file was absent from the primary checkout; this was not a successful selection. The deferred rerun uses `file-sorter-release-20261013b`, where the requested heartbeat node and production-state bootstrap exist. See [fs-58-fix-report.md](<D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-dt-job-approve-lock-selection/_planning/fs-58-fix-report.md>) for the exact command and current verification limits. The new `pytest_guard_no_children` conftest denies `subprocess.Popen/run/call/check_*`, `os.system/popen/spawn*`, and fork APIs before configure; regression coverage exercises standalone ownership, ancestor reuse, waiting and error cleanup. These Python fixtures have been authored but **not executed** in the renewed quiet window.

**Loading:** proposed installer `scripts/install-pytest-guard.ps1 -Action Install` copies only `danny_pytest_guard.py` and `pytest-lock.py` into `%LOCALAPPDATA%/DannyPytest/guard`. It appends `danny_pytest_guard` to the Windows **User** `PYTEST_PLUGINS` value, appends that dedicated directory to User `PYTHONPATH`, and sets User `DANNY_PYTEST_GUARD_DIR` to that directory. Existing values are preserved in a rollback manifest. No site-packages, `.pth`, `sitecustomize`, Python dependency, executable PATH, `PYTEST_ADDOPTS`, or machine environment is changed. **Opt out: `DANNY_PYTEST_GUARD=0`.** The installer has not been run.

This is the least invasive stdlib-compatible registration: pytest interprets `PYTEST_PLUGINS`; Python only makes the dedicated directory importable. Every new non-pytest process inheriting Danny's User environment sees those three environment values. A non-pytest Python process also sees one extra `sys.path` directory from `PYTHONPATH`; it executes/imports no guard module automatically and takes no lock. The dedicated directory contains no ordinarily importable helper name that shadows a library: `pytest-lock.py` has a hyphen, and the guard name is specific. Pytest imports may create bytecode in the dedicated directory, never via an installer write to site-packages.

User-level registration covers newly started processes for Danny across repositories. Existing terminal/apps/services keep their old inherited environment until restarted. Other Windows accounts/SYSTEM and interpreters that ignore `PYTHONPATH` are not automatically covered; no rollout to those surfaces is claimed. Explicit helpers still use the same machine lock. Uninstall restores original environment values when unchanged, otherwise removes only owned entries while preserving later edits. It retains inert modules for processes still using the old environment.

**Dry run after the coordinator releases the quiet window:** from the pytest project's working directory, this single command accepts any given pytest selection, runs collection and the selection both without and with the fixture-scoped guard, and diffs stdout/stderr and collection summaries excluding timing:

```powershell
cd "<pytest project's absolute folder>"
python "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-dt-job-approve-lock-selection/scripts/compare-pytest-guard.py" -- <pytest selection> -q
```

For a concrete local probe, use the command in the verification table below. The dry run takes the shared explicit lock and inventories legacy pytest in its parent context, outside pytest; its guarded child proves native ancestor reuse without spawning. It sets guard environment only for its own children and does not install anything. The earlier probe passed, but both it and File Sorter's own selection must be rerun on the corrected Python code after the renewed quiet window before rollout. Opt-out prevents locking but does not erase the installer-added environment/path or remove the inert plugin registration from pytest's plugin inventory; explicit sealed helpers remove the owned loading entries.

## Verification table

Commands below run from this worktree. Evidence paths are relative to `_planning/fs-57-59/`. **All pytest/grader-based rows are DEFERRED - quiet window**, including historical passes; none is presented as a final pass on the new Python code.

| Command | Exact counts / result | Evidence log |
| --- | --- | --- |
| `pwsh -NoProfile -File skills/dt-build/scripts/tests/test-dt-job.ps1` | PASS: **255** checks | `test-dt-job-final.log`, `test-dt-job-final.stderr.log`; also `test-dt-job-resume3.log` |
| `pwsh -NoProfile -File skills/dt-build/scripts/tests/test-dt-build-watcher.ps1` | PASS: **269** checks, full final watcher file | `test-dt-build-watcher-resume3.log`, `.stderr.log` |
| `pwsh -NoProfile -File scripts/tests/test-pytest-command.ps1` | PASS: **14** command fixtures; no Python started | `test-pytest-command-final.log` |
| `pwsh -NoProfile -File scripts/tests/test-pytest-admission.ps1` | PASS: **4** timing checks with PowerShell-only children/stub | `test-pytest-admission-verified.log` |
| `pwsh -NoProfile -File _planning/fs-57-59/verify-static.ps1` | PASS: **18** PowerShell ASTs, **2** JSON documents, **18** shared owner entries, **0** version/history changes, correct branch/HEAD and whitespace | `static-resume3.log` |
| `pwsh -NoProfile -File skills/dt-build/scripts/test-dt-build-regressions.ps1` | **DEFERRED - quiet window**: **0** checks executed now. Historical **225** checks before this resume; not a final rerun | Historical `test-dt-build-regressions-complete.log`; coordinator to capture `test-dt-build-regressions-after-quiet.log`, or use Mac matrix's suite logs |
| `pwsh -NoProfile -File scripts/model-router/tests/test-mac-regressions.ps1 -SuiteTimeoutSeconds 1800 -EvidencePath _planning/fs-57-59/mac-regressions-after-quiet` | **DEFERRED - quiet window**: **0** suites executed now. Matrix covers the three touched Python suites and wrapper regression; exact final counts must come from new `results.json` | Coordinator to capture `test-mac-regressions-after-quiet.log`, `mac-regressions-after-quiet/results.json` and per-suite logs; directory must be fresh |
| `pwsh -NoProfile -File scripts/pytest-lock.ps1 python -m pytest scripts/model-router/tests/test_bench_tasks.py scripts/model-router/tests/test_bench_runner.py scripts/model-router/tests/test_bench_integration.py -q` | **DEFERRED - quiet window**: **0** tests executed now. Optional focused rerun if needed after matrix, not a substitute for the matrix | Coordinator to capture `test-bench-all-after-quiet.log` |
| `python scripts/tests/test_pytest_lock.py -v` | **DEFERRED - quiet window**: **0** executed; **10** declared fixture cases | Coordinator to capture `test-pytest-lock-after-quiet.log` |
| `python scripts/tests/test_pytest_guard.py -v` | **DEFERRED - quiet window**: **0** executed; **7** declared fixture cases | Coordinator to capture `test-pytest-guard-after-quiet.log` |
| `python scripts/compare-pytest-guard.py -- scripts/tests/fixtures/pytest_guard_probe.py -q -p no:cacheprovider` | **DEFERRED - quiet window**: **0** executed; expect **1** collected/executed in each with/without run (not yet verified) | Coordinator to capture `guard-dry-run-after-quiet.log` |
| Git Bash smoke: `python scripts/pytest-lock.py -- python -m pytest scripts/tests/fixtures/pytest_guard_probe.py -q -p no:cacheprovider` from this worktree's Git Bash | **DEFERRED - quiet window**: **0** executed; expect **1** test | Coordinator to capture `git-bash-after-quiet.log`; `C:/Program Files/Git/bin/bash.exe` exists, though bash is not on this session's PATH |
| Installer/uninstaller actual User registration and full `.ship.json` gate | **NOT RUN**: **0** installations, **0** gate runs; rollout waits for dry run + Danny's go, release waits for tests/version transaction | Installer and gate ASTs checked in `static-resume3.log` |

Count explanations: job 255 = 244 existing + 9 WIP approval checks + 2 immediate-repeat checks. The failed prior full watcher attempt reached 255 before the new queue block; final 269 = those 255 + 3 queue assertions + 11 remaining static assertions. Earlier isolated 3 is not used as a full pass. Historical regression 225 = 217 existing + 8 live-selection checks. Historical original grading 86 = 53 task tests + 33 integration tests; the copied-bank fixture adds one task case. The previous combined run's 249 total was 248 passed + 1 failed (`test_executable_python_boundary` returned unknown); the prior Mac runner 162 total was 161 passed + 1 failed golden ledger. Neither failure is dismissed or represented as resolved by passing tests. They need the deferred final runs with complete outcome diagnostics now retained by assertions. Lock declarations 10 = original 5 + bounded-inventory + two admission/candidate-budget cases + stdlib ET + waiter/manager identity. Guard declarations are 7 new cases, not 7 passes.

The admission fixture had two setup failures (missing extracted-function globals), preserved in `test-pytest-admission.log` and `test-pytest-admission-final.log`; setting the fixture heartbeat and job-ID globals produced the verified four-check run. The added gate-list static check initially tried AST `SafeGetValue` on an array-expression block, which PowerShell refuses; it now reads literal AST nodes instead, preserving `static-gate-ast-diagnostic.log`, and the final static run passes. These failures occurred before any Python launch and are not product test failures hidden by a skip.

### Coordinator sequence after quiet-window release

First inspect Windows `Get-CimInstance Win32_Process` for actual Python/pytest commands. If another pytest is active, wait and recheck every 30 seconds; never kill it. Each helper also performs this inspection. Run the Mac matrix first, then the lock fixture driver, then the guard fixture driver, then the dry run/Git Bash smoke, **sequentially**. The matrix already includes `test-dt-build-regressions.ps1`; a separate full regression rerun is only needed if the matrix does not complete or further wrapper changes occur. Never run lock contention fixtures concurrently with an own pytest suite, and never enclose the entire contention driver inside an inherited explicit lock.

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-dt-job-approve-lock-selection"
pwsh -NoProfile -File scripts/model-router/tests/test-mac-regressions.ps1 -SuiteTimeoutSeconds 1800 -EvidencePath _planning/fs-57-59/mac-regressions-after-quiet *> _planning/fs-57-59/test-mac-regressions-after-quiet.log
```

After that command exits successfully, run each subsequent command separately and check its exit code/log before continuing:

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-dt-job-approve-lock-selection"
python scripts/tests/test_pytest_lock.py -v *> _planning/fs-57-59/test-pytest-lock-after-quiet.log
```

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-dt-job-approve-lock-selection"
python scripts/tests/test_pytest_guard.py -v *> _planning/fs-57-59/test-pytest-guard-after-quiet.log
```

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-dt-job-approve-lock-selection"
python scripts/compare-pytest-guard.py -- scripts/tests/fixtures/pytest_guard_probe.py -q -p no:cacheprovider *> _planning/fs-57-59/guard-dry-run-after-quiet.log
```

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-dt-job-approve-lock-selection"
& "C:/Program Files/Git/bin/bash.exe" -c 'python scripts/pytest-lock.py -- python -m pytest scripts/tests/fixtures/pytest_guard_probe.py -q -p no:cacheprovider' *> _planning/fs-57-59/git-bash-after-quiet.log
```

No tests are waived. Python syntax/import execution is also deferred. If any run nears its wrapper ceiling, preserve its actual PID, command, identity, output paths and current result in a checkpoint; return before the ceiling. Do not reclassify an infrastructure wait as a candidate failure or omit an unresolved outcome.

## Review-note resolutions (all 14)

| Note | Resolution / evidence / remaining verification |
| --- | --- |
| 1 | Canonical helper supplied by authoritative `grader-runner.py`; copied bank fixture retained. Full copied-bank/golden validation **DEFERRED - quiet window**. |
| 2 | Actual command/executable-argument detection replaces substring matching. **14** PS fixtures prove non-pytest mentions do not lock. No old/unrelated process was killed. |
| 3 | Queue status is set to applied before history persistence; both job/watcher assert durable status. Immediate approve twice without queue is covered; older repeat refused. Full **255 / 269** PS checks pass. |
| 4 | Stdlib ET fallback replaces any dependency on installing tzdata. Six transition/season assertions authored; runtime **DEFERRED - quiet window**. |
| 5 | Final artifact is this `_planning/fs-57-59/report.md`; no unspecified external copy. |
| 6 | Holder uses genuine multiline `-c` source and repr paths, retains stderr, checks marker and continued process liveness after it. Fixture execution **DEFERRED - quiet window**. |
| 7 | FS-59 wait fixture retains `-All` with `-JobId`. Historical **225** regression checks; current full suite **DEFERRED - quiet window** because it calls Python. |
| 8 | `param()` / `$args` adapter preserves child flags; only recognized leading helper options are parsed. `-ReadyFile` added before executable. Existing Python/-File/call-operator argv fixture retained; **DEFERRED - quiet window**. |
| 9 | Original wrapper deadline is historical; reboot left no old process alive. Only new owned fixture PIDs were launched. All have exited, with evidence preserved; no live test checkpoint required. |
| 10 | No Python suite ran here. Coordinator sequence explicitly keeps full matrix and contention drivers sequential. |
| 11 | Historical 86 = 53 + 33; copied-bank addition and 249 combined result explained above. Supported final matrix timeout is **1800**, with fresh evidence directory; **DEFERRED - quiet window**. |
| 12 | WIP `+=` array append retained. Full final watcher **269**, including all three new queue assertions and later static assertions, replaces failed 255 + isolated 3. |
| 13 | Engine acquires before timed subprocess and copies environment afterward; direct grader, Mac launcher, job runner and acceptance separate admission/execution. **4** PS timing checks pass; actual grader contention **DEFERRED - quiet window**. No-network boundary retained. |
| 14 | Contention success now uses a trivial private fixture instead of golden-suite startup under an unrealistic eight-second budget; hold exceeds candidate budget. Actual private candidate timeout case remains distinct. Child communication allows the separate 1800s admission bound and preserves diagnostics/outcome. Execution **DEFERRED - quiet window**. |

## Complete changed-file inventory

Relative to `dfe60f0`, including WIP and new uncommitted code (31 files):

- `.ship.json`
- `references/shared-component-owners.json`
- `scripts/pytest-lock.py`
- `scripts/pytest-lock.ps1`
- `scripts/pytest-command.ps1`
- `scripts/pytest-guard/danny_pytest_guard.py`
- `scripts/install-pytest-guard.ps1`
- `scripts/compare-pytest-guard.py`
- `scripts/ship-gate.ps1`
- `scripts/tests/test_pytest_lock.py`
- `scripts/tests/test_pytest_guard.py`
- `scripts/tests/test-pytest-command.ps1`
- `scripts/tests/test-pytest-admission.ps1`
- `scripts/tests/fixtures/pytest_guard_probe.py`
- `scripts/model-router/bench/bench_engine.py`
- `scripts/model-router/bench/grader-runner.py`
- `scripts/model-router/bench/tasks/_grading.py`
- `scripts/model-router/tests/test-mac-regressions.ps1`
- `scripts/model-router/tests/test_bench_runner.py`
- `scripts/model-router/tests/test_bench_tasks.py`
- `skills/dt-build/scripts/assemble-codex-prompt.ps1`
- `skills/dt-build/scripts/dt-build-watcher.ps1`
- `skills/dt-build/scripts/dt-job-runner.ps1`
- `skills/dt-build/scripts/dt-job.ps1`
- `skills/dt-build/scripts/invoke-claude-chunk.ps1`
- `skills/dt-build/scripts/invoke-codex-chunk.ps1`
- `skills/dt-build/scripts/model-selection.ps1`
- `skills/dt-build/scripts/test-dt-build-regressions.ps1`
- `skills/dt-build/scripts/tests/test-dt-build-watcher.ps1`
- `skills/dt-build/scripts/tests/test-dt-job.ps1`
- `skills/dt-build/scripts/verify-milestone-acceptance.ps1`

Task artifacts remain under `_planning/fs-57-59/`: original evidence, this report, static verifier/log, new PS logs and PID records, FS-62 scope evidence, and refreshed launcher inventory. The 15 disposable `edit*.py` scripts were removed after preserving this report/evidence. Canonical memory/session-audit writes are excluded by the task's explicit scaffold-write prohibition. Final Python passes, rollout, FS-62, versioning, and release remain coordinator work.
