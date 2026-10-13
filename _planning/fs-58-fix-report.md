# FS-58 fixes

Date: October 13, 2026 (ET). Worktree: `D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-dt-job-approve-lock-selection`. Branch: `fix/dt-job-approve-lock-selection`; starting HEAD `a3d8925`, rebased onto main `327c840`.

The two product fixes and regression fixtures are ready for deferred Python verification. During File Sorter's renewed quiet window beginning at 1 PM ET, **no Python, pytest, lock/guard fixture driver, installer, model dispatch or delegation was run**. Only this worktree was edited. No version bumps, merge or push were performed.

## Root causes and changes

### Deterministic nested-owner failure

The failing entry is the **third form, `pwsh -CommandWithArgs`**. Its wrapper is:

```powershell
& $args[0] @($args | Select-Object -Skip 1); exit $LASTEXITCODE
```

PowerShell passes this inline array expression as one `System.Object[]` argument; it does not splat its members into the script. The WIP adapter wrapped that array again. Its option parser therefore missed `-TimeoutSec 1`, used the default 1800 seconds, and forwarded one nested array as the command. Native PowerShell argument binding flattens the array again, but only **after** the adapter has emitted its helper options and `--`. Python therefore receives `--timeout 1800 -- -TimeoutSec 1 <python> -c ...`; the helper attempts to launch **`-TimeoutSec` as the executable**, resulting in exit 1. A separate native `pwsh` child confirms this flattening without running Python. This occurs before the intended final child can write its argv snapshot. It is independent of pytest competition or ancestor-lock admission.

The PowerShell-only shim reproduces the old adapter's nested array and default timeout, and deliberately returns exit 1 for that malformed argv. It proves the argument-binding defect; it does **not** claim an actual Python rerun. The direct Python form has no PowerShell argument-binding boundary; its runtime verification remains deferred. The `pwsh -File` form forwards separate arguments correctly in the shim reproduction.

`scripts/pytest-lock.ps1` now unwraps one single array container before parsing helper options. Each argument remains separate, including child flags, spaced paths and literal shell characters. This supports the existing third form without rewriting its wrapper. The success and exact `['-v', '-q']` assertions remain unchanged. The Python test now reports the entry through `subTest` and captures stderr so a future failure identifies its form and reason. A PowerShell-only fixture covers `-File`, the original inline-array form, proper variable splatting, ready paths, default timeout and exit-code forwarding, plus the old-code reproduction.

### File Sorter production-state guard incompatibility

The auto-loaded guard's `pytest_configure` called the same inventory-enabled context as the explicit helper. That context launched `pwsh Get-CimInstance Win32_Process` from inside pytest, including during verified-ancestor dry runs. File Sorter's pre-import production-state guard rejected that launch and retained the violation as a session failure.

The guard now calls `pytest_lock(inventory=False)`. That path starts **no child process**: it acquires/releases the machine OS lock, writes holder/waiter metadata, and verifies ancestor reuse using native identity/ancestry queries. With no inherited token, it does not enumerate ancestry. With a token, Windows uses stdlib `ctypes` for Toolhelp and `GetProcessTimes`; macOS uses `libproc.proc_pidinfo`; Linux reads `/proc/<pid>/stat`. Native handle closure uses `finally`. Ancestor traversal stops at cycles, inaccessible identities or a reused parent PID whose creation time is younger than its child.

Legacy-suite command-line inventory is intentionally **dropped from the auto-loaded path**. Cooperating guarded sessions serialize through the OS lock without that inventory, and File Sorter forbids its subprocess implementation. An independent unguarded legacy pytest does not acquire this lock and therefore is not serialized by the automatic guard. The **explicit helper retains** its existing bounded CIM/`ps` inventory before launching pytest, with inventory enabled by default; no process is killed to obtain admission.

Both paths now store the same native process-start identity. Reuse still requires a busy OS lock, an admitted held record, the matching environment token, verified ancestry, and the holder's matching live creation identity. Explicit inventory validates guard waiter records against that native identity before mapping them into its CIM/`ps` rows; the existing exact Python-manager invocation exclusion remains intact. A copied token alone still cannot inherit. Opt-out, sealed environment handling and the machine lock location are unchanged.

The new `scripts/tests/fixtures/pytest_guard_no_children/conftest.py` patches `subprocess.Popen/run/call/check_call/check_output`, `os.system/popen/spawn*`, and available fork APIs to raise **before configure**, with denials retained through cleanup. Its probe verifies held/admitted ownership, token equality and an actually busy OS lock. The driver exercises fresh ownership and verified ancestor reuse, and applies the same conftest to waiting serialization, test failure and collection-error cleanup. Activation is restricted to driver-created child environments; unrelated repository collection stays inert. The lock driver also gets a direct native-mode context regression with subprocess inventory/Popen forbidden.

The Python regressions are authored, **not executed** during this renewed quiet window. Lock declarations increase **10 -> 11** (one native-mode context case); guard declarations increase **7 -> 8** (one child-denial case with standalone/ancestor subcases). Existing waiting and error-release cases are strengthened without increasing their case count.

## PowerShell-only verification

Before execution, source inspection confirmed that command detection only parses commands and that admission testing replaces the helper with a PowerShell stub and launches only PowerShell sleeps. The new adapter suite checks that `python` resolves to its `.ps1` shim in both parent and child. The native smoke compiles C# in-process with `Add-Type`, makes only Windows API/CIM queries, and starts no child. The real PowerShell adapter was **not** invoked against real Python: it always starts Python even with a non-pytest child.

Evidence paths below are under `_planning/fs-58-fix-verification/`.

| Claim/change | Action and exact check | Result | Evidence / limit |
| :-- | :-- | :-- | :-- |
| Adapter preserves all supported argv forms | `pwsh -NoProfile -File scripts/tests/test-pytest-lock-adapter.ps1` | **PASS, 12 checks** | `adapter.log`; includes deterministic old-code malformed-array reproduction and native-boundary flattening; actual Python deferred |
| Native Windows ABI/identity is available | `pwsh -NoProfile -File _planning/fs-58-fix-verification/native-api-smoke.ps1` | **PASS, 6 checks** | `native-api.log`; 568-byte struct, stable FILETIME equal to .NET, parent equal to CIM, parent age, nonexistent PID rejection. C# API smoke only, not execution of Python ctypes |
| Command detection remains correct | `pwsh -NoProfile -File scripts/tests/test-pytest-command.ps1` | **PASS, 14 checks** | `command.log`; static command cases, no Python |
| Admission/execution budgets remain separate | `pwsh -NoProfile -File scripts/tests/test-pytest-admission.ps1` | **PASS, 4 checks** | `admission.log`; PowerShell-only children/helper stub |
| Changed PowerShell syntax and patch whitespace | PowerShell `Parser.ParseFile` on adapter, adapter fixture and native smoke; `git diff --check` | **PASS, 3 parsed files; whitespace clean** | `source-checks.log` |
| Guard starts no children in real pytest | New early-denial conftest; standalone, inherited, waiting and error-release cases | **DEFERRED** | Full guard driver below; no Python claim based on source/API smoke |
| Python lock reuse, contention and native implementation | Full lock driver below | **DEFERRED** | Windows Python path not executed; new Linux/macOS native paths also unverified on native hosts |
| File Sorter collection and selected test remain identical | Corrected File Sorter dry run below | **DEFERRED** | Prior baseline selection was missing; compatibility must pass on valid selection |

Runtime PowerShell total: **36 = 12 + 6 + 14 + 4**; the three parse checks are separate. Adapter 12 = the first 11 checks plus the native-boundary flattening check added during final review.

## Earlier verification evidence

Read the requested `fs-57-59/report.md` File Sorter section and every top-level `fs-57-59/after-quiet/*.log`. These results apply to the WIP before this fix, not to the newly changed Python:

- Mac compatibility matrix: **23/23 suites, 2992 checks PASS**; the log explicitly leaves native Mac acceptance unverified.
- Guard: **7 PASS**; local probe dry run identical; Git Bash smoke **1 PASS**.
- dt-job **255**, watcher **278**, authority-digest **66**, coordinator-capacity **7**, context-guard **181**, capacity-backoff **104**, pytest-command **14**, admission **4**: all PASS.
- Lock driver: **9 PASS, 1 FAIL**, the nested-owner case. Danny reports the same failure in 3/3 isolated reruns; the supplied `lock.log` retains one full failing run.
- File Sorter dry run: **FAIL**. Without the guard, collection/selection exited 4 because the selected file was missing from the primary checkout. With the guard, they exited 4 with `unsafe-powershell-wrapper`. Both issues are accounted for: the code removes the forbidden launch, and the deferred command uses the release checkout where source inspection confirms the original node exists (line 220) and the production-state bootstrap exists.

The earlier report's **For File Sorter** section now describes zero-child admission, the legacy-inventory tradeoff, native ancestor reuse, the failed baseline and the corrected deferred dry run.

## Exact deferred commands

Run only after File Sorter's coordinator releases the renewed quiet window. Run **sequentially** with no competing pytest; wait for existing suites rather than terminate them. Do not enclose the lock/guard contention drivers in an inherited explicit lock. Each explicit helper still performs its own legacy-suite inventory. Retain the logs and investigate any nonzero exit; historical passes do not substitute for these reruns.

Lock suite (11 declared cases; nested-owner diagnostics identify all three entries):

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-dt-job-approve-lock-selection"
python scripts/tests/test_pytest_lock.py -v *> _planning/fs-58-fix-verification/lock-after-quiet.log
```

Guard suite (8 declared cases, including child-process denial):

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-dt-job-approve-lock-selection"
python scripts/tests/test_pytest_guard.py -v *> _planning/fs-58-fix-verification/guard-after-quiet.log
```

Local collection/selection probe (one test in each without/with run):

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-dt-job-approve-lock-selection"
python scripts/compare-pytest-guard.py -- scripts/tests/fixtures/pytest_guard_probe.py -q -p no:cacheprovider *> _planning/fs-58-fix-verification/probe-after-quiet.log
```

File Sorter selection dry run (original heartbeat node; corrected checkout, no installer):

```powershell
cd "D:/Claude/_Claude-Workspace/OneDrive Migration/File Sorter/file-sorter-release-20261013b"
python "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-dt-job-approve-lock-selection/scripts/compare-pytest-guard.py" -- tests/backend/test_core_classification_lease.py::test_active_processing_heartbeat_uses_replacement_grant_for_commit -q -p no:cacheprovider *> "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-dt-job-approve-lock-selection/_planning/fs-58-fix-verification/filesorter-after-quiet.log"
```

This dry run's inventory runs in its parent outside pytest. Its guarded child must reuse the parent lock without launching a child, and both collection and selection must exit 0 with identical normalized output. If File Sorter's release checkout moves before execution, its coordinator must select the then-current checkout containing this node; do not rerun the known-invalid primary-checkout selection.

Session audit: temporary quiet-window restrictions, the worktree-only commit boundary and these fix findings are captured here; no new global rule, terminology or scaffold write is needed. Workspace synchronization is excluded by Danny's no-push instruction.
