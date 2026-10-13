# FS-67: coordinator capacity classification

Branch: `fix/dt-job-approve-lock-selection`.

## Before and after

Before, `Test-WatcherCapacityLaunch` returned true immediately for capacity launch metadata. A matching exit receipt returned true for a nonzero capacity exit, but every other receipt outcome fell through to a regex over the complete coordinator log. A clean context rotation could therefore be classified as capacity because the coordinator had read capacity-related material.

After, a parsed receipt whose `coordinator_id` matches is authoritative: the function returns true only when `failure_category` is `capacity` and `exit_code` is present, non-null, and nonzero. Every other matching receipt returns false without consulting the log or launch metadata. Missing outcome fields also return false. Receipt inspection now precedes capacity launch metadata.

When the receipt is absent, unparseable, missing its ID, or has a mismatched ID, existing capacity launch metadata handling and log fallback remain available. The launcher invokes Codex without `--json`, invokes Claude without a structured output format, and merges CLI output and stderr using `*>>`. There is no reliable refusal-only structure in these logs. The existing regex is retained with a one-line comment explaining that limitation. The coordinator-capacity fixture's JSON-shaped overload string is accepted by the regex, but does not establish a structured production stream.

Residual limitation: without an authoritative receipt, unstructured log content can still match capacity phrases. No launcher behavior was changed.

## Tests added

Ten classification fixtures were added beside the existing capacity fixtures:

- Exit 0/category null with capacity log text: false (live regression).
- Exit 1/category capacity, overriding tool-error launch metadata: true.
- Exit 0/category capacity: false.
- Exit 1/category tool_error with capacity log text and capacity launch metadata: false.
- Clean receipt overriding capacity launch metadata: false.
- No receipt with a refusal line: true.
- Partial/unparseable receipt with a refusal line: true.
- Receipt missing coordinator ID with a refusal line: true.
- Receipt with mismatched coordinator ID and a refusal line: true.
- Matching receipt missing outcome fields, overriding capacity launch metadata: false.

These add eleven assertions: ten case results and one fixture-count completeness assertion. A quoted assistant/tool-output fixture is not applicable because the fallback was not restricted to structured lines.

## Suite results

Both commands ran from this worktree with all output redirected to TEMP. Only summary lines were read from the suite logs.

| Suite | Command | Exit | Summary |
| :-- | :-- | :-- | :-- |
| Watcher | `pwsh -NoProfile -File skills/dt-build/scripts/tests/test-dt-build-watcher.ps1 *> "$env:TEMP/fs-67-test-dt-build-watcher.log"` | 0 | `SUMMARY: 289 passed` |
| Coordinator capacity | `pwsh -NoProfile -File skills/dt-build/scripts/tests/test-coordinator-capacity.ps1 *> "$env:TEMP/fs-67-test-coordinator-capacity.log"` | 0 | `SUMMARY: 7 passed` |

Log files: `C:/Users/Danny/AppData/Local/Temp/fs-67-test-dt-build-watcher.log` and `C:/Users/Danny/AppData/Local/Temp/fs-67-test-coordinator-capacity.log`. Exit codes were also saved to the corresponding `.exit.txt` files in TEMP.

## Verification and scope

| Claim/change | Action | Exact check | Evidence |
| :-- | :-- | :-- | :-- |
| Matching receipt overrides log and launch metadata | Reviewed function and exercised fixtures | Clean, tool-error, capacity, zero-exit, missing-outcome cases | Watcher suite: exit 0, 289 passed |
| Unusable receipt preserves fallback | Exercised absent, malformed, missing-ID, mismatched-ID fixtures | Refusal line remains capacity | Watcher suite: exit 0, 289 passed |
| Capacity retry behavior remains valid | Ran coordinator-capacity suite | Existing refusal, retry budget, bounded episode checks | Exit 0, 7 passed |
| Log structure assessment | Inspected launcher assembly | Plain CLI commands and merged `*>>` output | `launch-managed-coordinator.ps1` |

Implementation worker: router-selected `gpt-6.1-sol`, routine-coding, medium effort; parent reviewed the diff and ran both suites. No pytest, version bumps, pushes, or merges were performed. Existing unrelated planning artifacts were preserved. Session audit found no new durable memory to capture; the user-directed task record is this report.
