# FS-58 opt-in machine test lock

Branch: `fix/dt-job-approve-lock-selection`. No versions changed; no push or merge.

Danny's 2026-10-13 policy is implemented: parallel work is the default on
SNOWWHITE. Exclusivity is only for a named suite with documented overlap
failure, evidence, and an attempted workaround. The helper checks that a
reason is nonempty; the caller supplies the evidence, rather than a new
machine-wide enforcement system judging it.

## Default paths

- `assemble-codex-prompt.ps1`: removed the standing pytest-lock instruction.
- `dt-job-runner.ps1`: runs directly unless the spec has a nonempty string
  `exclusive_reason`. Missing, empty, whitespace and non-string fields do not
  opt in. No pytest command detection or blanket wrapping remains.
- `verify-milestone-acceptance.ps1`: runs each command directly unless its
  verification entry has a nonempty string `exclusive_reason`.
- Bench `bench_engine.py`, `grader-runner.py`, `tasks/_grading.py`: restored
  exactly to main, removing all machine-lock imports and wrapping.
- `test-mac-regressions.ps1`: restored exactly to main; direct suite execution.
- `.ship.json`: restored exactly to main, including its gateCommand. Git blob
  identity: `ecfc8453795f13cd187dd746f2563c96dd78764f` for both files.
- Watcher, both model chunk wrappers, and `model-selection.ps1`: unchanged from
  the task's starting commit. Their differences from main are solely the
  FS-57 approval-queue hook and FS-59 model disclosure/sidecar support.

Bench budgets remain main's values (including the 30-second local grader
budget and existing eight-slot grader semaphore). Under machine load, these
budgets can be sensitive; this change adds no lock or budget increase.

## Opt-in interface

- `dt-job.ps1 start -ExclusiveReason "<text>"` writes `exclusive_reason` to
  spec.json, the job record, and start/status receipts. Existing job records
  without this field remain readable.
- Roadmap verification entries can add an `exclusive_reason` column. Its
  reason is forwarded to each command and retained in command results.
  Table parsing preserves blank optional cells and optional trailing pipes.
- `pytest-lock.py --reason "<text>" -- <command>` and
  `pytest-lock.ps1 -Reason "<text>" <command>` reject missing or blank reasons
  with exit 2 and `EXCLUSIVE_REASON_REQUIRED`. Python's context-manager API
  also rejects missing/blank reasons. Waiting diagnostics print the caller's
  reason and holder; holder.json includes the holder's reason.
- Documented in `skills/dt-build/scripts/dt-job-usage.md` and the dt-job
  parameter comments. Array unwrapping and nested argv preservation remain.

## Files changed or removed

Modified:

```text
.ship.json
references/shared-component-owners.json
scripts/model-router/bench/bench_engine.py
scripts/model-router/bench/grader-runner.py
scripts/model-router/bench/tasks/_grading.py
scripts/model-router/tests/test-mac-regressions.ps1
scripts/model-router/tests/test_bench_runner.py
scripts/model-router/tests/test_bench_tasks.py
scripts/pytest-lock.ps1
scripts/pytest-lock.py
scripts/tests/test-pytest-admission.ps1
scripts/tests/test-pytest-lock-adapter.ps1
scripts/tests/test_pytest_lock.py
skills/dt-build/scripts/assemble-codex-prompt.ps1
skills/dt-build/scripts/dt-job-runner.ps1
skills/dt-build/scripts/dt-job.ps1
skills/dt-build/scripts/tests/test-dt-job.ps1
skills/dt-build/scripts/verify-milestone-acceptance.ps1
```

Added: `skills/dt-build/scripts/dt-job-usage.md` and this report.

Removed:

```text
scripts/compare-pytest-guard.py
scripts/install-pytest-guard.ps1
scripts/pytest-command.ps1
scripts/pytest-guard/danny_pytest_guard.py
scripts/ship-gate.ps1
scripts/tests/fixtures/pytest_guard_no_children/conftest.py
scripts/tests/fixtures/pytest_guard_no_children/probe.py
scripts/tests/fixtures/pytest_guard_probe.py
scripts/tests/test-pytest-command.ps1
scripts/tests/test_pytest_guard.py
```

Neither FS-57 nor FS-59 needs pytest-command.ps1. No remaining code references
it or ship-gate.ps1. Guard tests and blanket bench-wrapping tests were removed.

Ownership inventory: 421 entries before, 366 after. Removed 56 missing-file
entries (8 for files removed here, 48 for already-absent files), added the
adapter-test entry, and narrowed the Python helper's consumers to dt-build.
Every remaining ownership key exists; every previously declared existing
file retains its entry.

Cleanup limitation: command approval policy rejected deleting the ignored
`scripts/pytest-guard/__pycache__/danny_pytest_guard.cpython-314-pytest-9.1.1.pyc`
and recursive removal of the guard folders. All tracked guard source is
deleted. Empty directories are not git artifacts; the ignored compiled cache
still needs local cleanup. The rejection supplied only "blocked by policy".

## Verification

All test output was redirected outside _planning, to the Windows TEMP folder;
only summaries were read. No pytest or Python test suite was run. The allowed
PowerShell build-regression script invokes the existing production bootstrap
measurement CLI; it does not launch a Python test suite.

Run from this worktree:

| Command | Exit | Summary | Log under TEMP |
| --- | --- | --- | --- |
| `pwsh -NoProfile -File scripts/tests/test-pytest-lock-adapter.ps1` | 0 | `SUMMARY: 19 passed; no Python started` | fs58-rescope-adapter.log |
| `pwsh -NoProfile -File scripts/tests/test-pytest-admission.ps1` | 0 | `SUMMARY: 10 passed` | fs58-rescope-admission-final.log |
| `pwsh -NoProfile -File skills/dt-build/scripts/tests/test-dt-job.ps1` | 0 | `SUMMARY: 263 passed` (first run) | fs58-rescope-dt-job.log |
| `pwsh -NoProfile -File skills/dt-build/scripts/tests/test-dt-job.ps1` | 0 | `SUMMARY: 264 passed` (final receipt recheck) | fs58-rescope-dt-job-final.log |
| `pwsh -NoProfile -File skills/dt-build/scripts/test-dt-build-regressions.ps1` | 0 | `SUMMARY: 225 passed` | fs58-rescope-dt-build.log |

The adapter has 19 assertions (12 before): two obsolete reproduction checks
were removed and nine missing/blank reason checks were added. Acceptance
checks cover direct pytest stand-ins, documented
opt-in timing, quoting, receipt reason, and optional table cells. dt-job checks
run an actual unwrapped PowerShell pytest stand-in, persist a queued opted-in
job's reason, and inspect the real runner argv block without launching Python.
The dt-job count increased from 255 to 264 through nine new opt-in assertions;
the first run's 263 lacked the final status-receipt assertion added afterward.
Acceptance fixtures increased from 4 to 10 through six checks for opt-in reason
retention, direct default execution, and optional table-cell parsing. Build
regression assertions remain at 225.

| Claim | Exact check | Evidence |
| --- | --- | --- |
| Main defaults restored | `git diff main --exit-code -- .ship.json scripts/model-router/bench/bench_engine.py scripts/model-router/bench/grader-runner.py scripts/model-router/bench/tasks/_grading.py scripts/model-router/tests/test-mac-regressions.ps1 scripts/model-router/tests/test_bench_runner.py scripts/model-router/tests/test_bench_tasks.py` | Exit 0 |
| FS-57/59 supporting files preserved | Diff against starting HEAD for watcher, both wrappers and model-selection.ps1 | No changes |
| PowerShell syntax | PowerShell Parser.ParseFile on seven changed PS files | 7 passed |
| Ownership paths | Parse JSON, test every key, compare surviving original keys | 366 entries, 0 missing, 0 existing keys lost |
| Formatting | `git diff --check` | Passed |
| Python lock correctness | Deferred commands below | Unverified this session |

## Deferred until the other session's window ends (about 5:30 PM ET)

These commands have NOT been run. Coordinate the actual end of the window
before starting them; no default lock should be added to these commands.

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills-dt-job-approve-lock-selection"
python -B scripts/tests/test_pytest_lock.py -v *> "$env:TEMP/fs58-deferred-lock.log"
```

```powershell
cd "D:\Claude\_Claude-Workspace\Skill Creation\danny-skills-dt-job-approve-lock-selection"
python -B -m pytest scripts/model-router/tests/test_bench_runner.py scripts/model-router/tests/test_bench_tasks.py scripts/model-router/tests/test_bench_parallel.py scripts/model-router/tests/test_bench_private_bank.py -q -p no:cacheprovider *> "$env:TEMP/fs58-deferred-bench.log"
```

No version/release gate or ship gate was run: the coordinator owns version
bumps, and the Python checks remain deferred. Session audit: the policy is
captured in the helper and job usage documentation; transient verification
state is captured here. No canonical scaffold writes or workspace sync/push
were performed, respecting the task boundaries.
