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
