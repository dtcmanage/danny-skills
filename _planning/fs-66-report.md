# FS-66: Test dependency manifest and preflight

Implemented on `fix/test-dependency-manifest`. Commit message:
`fix(tests): declare test dependencies and preflight them`.
No versions bumped, push performed, or merge performed.

## Dependency inventory

Grepped all repository `*.py` import statements before writing the manifest, then
checked imports using Python's AST and excluded standard-library and repository-local
modules. The scan covered 61 Python files before this change.

Direct third-party imports were `tiktoken`, `fastapi`, `pydantic`, `pytest`, and
`markdown_it`. The last was missing from the proposed list: `scripts/test-file-link-format.py`
uses it. Added `markdown-it-py==4.2.0`, matching the installed reference PC distribution.
The other eight pins are exactly those requested. `httpx` supports FastAPI's test
client; `tzdata` supplies Windows timezone data. Starlette and uvicorn remain explicit
requested dependencies. No further third-party Python imports were found.

## Changes

- Root `requirements-test.txt` declares all nine pinned distributions.
- `scripts/test-preflight.ps1` checks Python, Node, npm, every manifest import,
  the UI harness `node_modules`, and `ZoneInfo('America/New_York')`.
  It maps `markdown-it-py` to `markdown_it`. Without `-Fix`, each missing item
  gets a single line containing its exact repair command and the script exits 1.
  With `-Fix`, missing Python packages trigger the requested user-level pip install,
  and missing UI dependencies trigger `npm ci`; checks run again after installation.
  Missing executables receive Windows installation commands. Package names travel
  to Python on stdin, avoiding the restricted test-runner name in process arguments.
- `.ship.json` starts with preflight without `-Fix` and stops on failure. The new
  PowerShell test and Eastern unittest follow it before the existing gate steps.
- `scripts/eastern_time.py` supplies a shared timezone fallback for cost_report,
  the lock helper, and collect-usage. It prefers ZoneInfo; if data is absent, it
  uses second-Sunday-of-March / first-Sunday-of-November rules, UTC-4 / UTC-5.
  It handles the spring gap, autumn repeated hour and fold, and local week bounds.
  collect-usage also uses `timezone.utc` for naive input, avoiding another tzdata
  lookup. Consumer output formatting remains unchanged.
- README documents `pwsh -NoProfile -File scripts/test-preflight.ps1 -Fix`.
- Shared-component ownership entries declare the new scripts and tests.

## Verification

All execution output was redirected to TEMP; only summaries were read.

| Claim/change | Action | Exact check | Evidence |
| --- | --- | --- | --- |
| Missing dependencies fail clearly | Run PowerShell fixture test | `pwsh -NoProfile -File scripts/tests/test-test-preflight.ps1` | PASS; nonexistent package exits 1 and prints exact pip command with temporary requirements path |
| UI absence is detected | Run real preflight before installing harness | `pwsh -NoProfile -File scripts/test-preflight.ps1` | Exit 1; exact harness directory and npm command printed |
| Fix prepares this worktree | Run Fix, then read-only check | `pwsh -NoProfile -File scripts/test-preflight.ps1 -Fix`, then same without `-Fix` | Both exit 0; npm ci installs harness; all nine imports and Eastern zone pass |
| Fallback conversion is correct | Force ZoneInfoNotFoundError | `python -m unittest scripts/tests/test_eastern_time.py` | 4 tests pass; seven UTC cases cover Mar 8 and Nov 1 transitions, winter, summer, fold and round trips; local days are 23/25 hours |
| Report consumers work without tzdata | Import cost_report and collect-usage under forced fallback | Included in Eastern unittest | PASS; DST week is 167 hours and naive UTC timestamp converts to prior Eastern date |
| Lock edit is valid without executing it | Parse source only | `python -c` using `ast.parse` and a dynamically assembled lock filename | PASS; lock helper and its tests never executed |
| dt-build remains compatible | Run permitted regression suite | `pwsh -NoProfile -File skills/dt-build/scripts/test-dt-build-regressions.ps1` | Exit 0; 225 assertions passed |
| Gate starts with preflight | Parse ship JSON and check command prefix | Python JSON assertion | PASS; shared ownership JSON also parses |
| Patch is clean | Check whitespace | `git diff --check` | PASS |

TEMP logs: `fs66-preflight-test.log`, `fs66-et-test.log`, `fs66-preflight.log`,
`fs66-fix.log`, `fs66-preflight-ready.log`, `fs66-syntax.log`,
`fs66-structure.log`, and `fs66-regressions.log`.

## Coordinator follow-up

The full ship gate, pytest, dt-job suite, admission suite, and lock-helper tests
were not run, per the process-command-line restriction. No command launched by
this task included the restricted runner name in its arguments.

The release version validator was not run. This task explicitly forbids version
bumps, while the repository release policy requires affected skill/plugin bumps
for these runtime changes. The coordinator must handle the release transaction
and full gate on the authorized machine before shipping.

Close-out session audit: the process restriction and version-bump exception are
specific to this task; implementation state is captured here and in the commit.
No durable policy/memory changes were needed. Workspace upload was skipped under
the explicit no-push instruction. Existing task and wrapper log files were left untouched.

## Follow-up: gate scope

Scoped the ship preflight on the same `fix/test-dependency-manifest` worktree,
following commit `2cb539b`. Commit message:
`fix(tests): scope the ship-gate preflight to gate needs`.

### Gate dependency trace

Read every gate entry and traced the executable calls and Python imports in its
helpers. The gate's direct third-party Python dependency is **tiktoken**. Its
transitive dependencies are installed by pip normally; no separate gate pins are
needed. PowerShell 7, Python, Git, and Windows robocopy are the required tools.

| Gate step | Third-party Python imports reached | Tools and helper paths reached |
| --- | --- | --- |
| `scripts/test-preflight.ps1 -Scope gate` | `tiktoken` import probe | Python; discovery of pwsh, git, robocopy; no Node/npm discovery or UI dependency check |
| `scripts/tests/test-test-preflight.ps1` | Installed tiktoken in the healthy gate case; fixture modules/pip in negative and Fix cases | pwsh, Python; full-scope fixture discovers Node/npm but does not launch them; a temporary harness models UI absence |
| `python -m unittest scripts/tests/test_eastern_time.py` | None | Python stdlib unittest; imports eastern_time, cost_report, collect-usage; forces the Eastern fallback; does not call report main functions |
| `scripts/verify-versioning-policy.ps1 -BaseRef auto` | None | PowerShell, Git for release/history comparisons |
| `scripts/test-versioning-policy.ps1` | None | PowerShell, Git fixture repos; tools/build-plugin.ps1 performs real fixture packaging with robocopy and built-in archive commands |
| `skills/dt-review/tests/run-tests.ps1` | None | PowerShell review parsers, prompt/termination/finalization helpers, model-router helpers; fake Claude/Codex PowerShell scripts replace model CLIs |
| `skills/dt-review/tests/run-final-draft-tests.ps1` | None | PowerShell parse-verdict, record-dispositions, prepare-final-draft and finalize-review helpers |
| `skills/dt-build/scripts/tests/test-host-adapters.ps1` | None | PowerShell and Git fixture; invoke-codex-chunk uses a fake PowerShell Codex CLI |
| `skills/dt-build/scripts/tests/test-context-guard.ps1` | None | PowerShell context-guard/hooks/job/resume helpers, Git fixture; no Python or real model CLI launch |
| `skills/dt-build/scripts/tests/test-dt-job.ps1` | None | PowerShell job-runner fixtures and Git; restricted runner stand-in executes directly; optional Python lock-wrapper argv is inspected without starting Python |
| `skills/dt-build/scripts/test-dt-build-regressions.ps1` | `tiktoken` via measure-resume-bootstrap.py | Python measurement and a stdlib-only generated repair fixture; PowerShell rulebook/acceptance/router/job helpers, Git fixtures; model CLIs are fixture-backed |
| `tools/build-plugin.ps1 -BaseRef auto -ValidateOnly` | None | PowerShell and Git; calls version validator, returns before copying/archiving |

`markdown_it` is only used by the separate file-link-format suite, which the gate
does not call. FastAPI, httpx, pydantic, starlette, uvicorn and the Python test
runner package are not imported by these gate paths. The gate's timezone
consumers support the stdlib Eastern fallback, so tzdata and an installed
`America/New_York` database are not required. No gate step launches Node/npm or
the UI benchmark. Robocopy is included because the versioning **test** packages
a fixture even though the final packaging gate uses `-ValidateOnly`.

### Changes and verification

- `-Scope full` remains the default, with all nine manifest imports, timezone
  data, Node/npm and UI harness checks. Both scopes check the gate tools above.
- `-Scope gate` selects only the tiktoken pin from the existing manifest; no
  duplicate dependency manifest or version changes. Its repair command and
  `-Fix` invocation install only that selected requirement. Full Fix retains
  `pip install --user -r <manifest>` and UI `npm ci` when needed.
- `.ship.json` now explicitly invokes `-Scope gate`. README states that the gate
  checks its own needs while default full Fix prepares all suites.
- Added `-HarnessPath` for safe temporary-harness fixtures. Tests also shadow
  Python modules and pip in a temporary directory, record pip argv, and restore
  PYTHONPATH in finally; no real package installation or UI deletion occurs.

| Claim/change | Action | Exact check | Evidence |
| --- | --- | --- | --- |
| Missing full-only dependencies do not block gate | Temporary manifest contains tiktoken plus a nonexistent full-only package; harness path absent | `pwsh -NoProfile -File scripts/tests/test-test-preflight.ps1` | Exit 0; gate and gate Fix succeed; default full reports missing package and UI harness |
| Gate still requires its own dependency | Shadow tiktoken with an import failure | Same fixture suite | Gate exits 1 with exact scoped pip repair command |
| Fix respects both scopes | Fake pip records argv and makes fixture modules importable | Same fixture suite | Gate argv is `install --user tiktoken==0.12.0`; full argv is `install --user -r <temporary manifest>`; both rechecks succeed |
| Clean worktree UI absence is safe | Rename the real harness node_modules to a unique sibling, run gate check, restore in finally | `pwsh -NoProfile -File scripts/test-preflight.ps1 -Scope gate` | Exit 0 while node_modules absent; gate does not recreate it; restoration confirmed |
| Full behavior remains usable | Run default preflight after restoring harness | `pwsh -NoProfile -File scripts/test-preflight.ps1` | Exit 0 |
| Gate timezone path needs no database | Run fallback tests | `python -m unittest scripts/tests/test_eastern_time.py` | Four tests pass, including reporting consumers under forced missing timezone data |
| Bootstrap and build regressions remain compatible | Run permitted regression suite | `pwsh -NoProfile -File skills/dt-build/scripts/test-dt-build-regressions.ps1` | Exit 0; 225 assertions pass; log in TEMP: fs66-gate-regressions.log |
| Ship wiring and patch are valid | Parse JSON, check gate prefix, whitespace and changed release metadata paths | PowerShell prefix assertion; `git diff --check`; changed-file check | PASS; explicit gate scope, no whitespace errors, no skill/plugin version metadata changes |

The full gate is not executed: dt-job's direct runner stand-in would put the
forbidden text in a process command line, and the versioning packaging fixture's
robocopy argv includes a cache exclusion containing the same text. Release
version validation/packaging remain unverified under the explicit no-version-bump
instruction. No push or merge performed; existing untracked run artifacts remain
untouched. Session audit found no new reusable policy, facts or terminology;
task-only constraints and results are captured here. Workspace upload is skipped
under the explicit no-push instruction.
