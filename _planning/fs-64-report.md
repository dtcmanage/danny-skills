# FS-64 authority bootstrap digest and FS-63 coordinator capacity handling

Implemented only in `fix/bootstrap-authority-digest`, based on main `dfe60f09f5c2a69f87e0dcce04bd8882219e9c2a`. No model delegation, version bump, merge, push or ship. No live run folder was read or written. Incident details below are Danny's supplied observations, not a new live inspection. All executable verification used fixtures.

## Root causes and changes

1. **Authority growth exhausted bootstrap.** Managed resume required every inherited authority original before the marker. The supplied incident has 99 originals and an unmarked coordinator at approximately 202,500 input tokens. The contract now budgets authority bootstrap at 32,000 characters (approximately 8,000 text tokens), consistent with the existing less-than-50,000 input-token target and 200,000 pre-marker wall. Actual tokenizer and marker measurements remain required; character sizing is not a token guarantee. A deterministic digest moves inherited full reads to immediately before their dependent actions. Current boundary, complete approvals, operator notes, checkpoint and current run state remain full bootstrap reads. A digest never grants authorization.
2. **An unmarked coordinator was invisible to wall recovery.** `Update-WatcherContextWall` returned without a bootstrap baseline. It now discovers the exact launch's transcript using cwd, host, launch time and unique coordinator prompt, measures pre-bootstrap usage, and records heavy reads since launch with a null baseline and `pre_bootstrap=true`. Discovery supplies measurement evidence only, not session authority. Existing marked-coordinator behavior remains. A capacity transcript without token usage cannot erase an earlier wall.
3. **Checkpoint installation was blocked at the wall.** The context hook allowed `write-build-state.ps1`, but omitted `write-resume-checkpoint.ps1`. The atomic checkpoint installer is now an allowed handoff command even past the hard limit. A heavy read chained ahead of it is still denied. The fixture actually installs a candidate and checks its archived predecessor.
4. **Capacity refusal consumed the failed-launch budgets.** The detached launcher now writes a coordinator exit receipt with `failure_category=capacity`; the watcher also recognizes historical refusal streams and synchronous launcher failures. Selected-model capacity and equivalent vendor overload refusals use 5/10/20-minute backoffs, bounded to 35 minutes from the episode's first refusal. Launches can retry at minute 5 and 15; continued refusal stops at minute 35, with reason `capacity` and a distinct recovery alert. Capacity launches spend none of the ordinary retry, consecutive-thrash, run cap or absolute launch-cap budgets. New triggers do not reset that capacity wait; operator resume re-arms it.

## Authority contract and implementation

`build-authority-digest.ps1` publishes `authority-digest.md`, `authority-digest.json` and the manifest SHA256 pin. The JSON records each original's absolute path, full-file SHA256, byte size, character size, kind and quoted mechanical extract. Discovery follows literal code-span paths, Markdown links, JSON strings, bare absolute paths and authority-like relative paths, recursively from the checkpoint and current run authority. Sources resolve beside their naming record, then beside the run. Referenced evidence is conservatively covered too; no workspace search or model call occurs.

`verify-authority-digest.ps1` verifies the manifest pin and Markdown hash, rediscovers the source graph, recomputes all original hashes/sizes, rejects missing/uncovered/duplicate originals and compares the Markdown with deterministic original extracts. Re-pinning a forged digest cannot change its mechanical contents. Every governing original remains controlling. Missing or contradictory authority stops the dependent action; failed verification requires original full reads before bootstrap, rather than silently skipping authorization.

The checkpoint is the discovery root and always read in full. Its authority text has a separate hash excluding only `run_status` and `last_consumed_event_seq`, the two fields owned by dt-job. Every original retains its full-file hash. This lets the operator build the digest while stopped and then issue resume without invalidating it. Other checkpoint changes fail verification. Markdown excerpt sizing reserves the entire 8 KiB lean-checkpoint ceiling, so owned-field changes do not change clipping. Navigation excerpts can be shortened mechanically; source paths and mandatory originals cannot be omitted. An oversized current authority set still fails closed.

`read-authority-digest.ps1` emits the verified Markdown in full. `read-authority-original.ps1` verifies the set and emits the complete governing original immediately before a dependent action, with a checked byte snapshot. `-BootstrapFallback` emits the full original for fallback bootstrap when the digest is stale. Script reads avoid evidence-wall, long-file and repeated-read limits; the hard context wall still requires handoff unless an already-open irreversible operation defers rotation. Coordinators invoke scripts and never edit digest authority content themselves.

The 99-original fixture includes long source names and large inherited records. It verifies full source coverage, mechanical index clipping inside the 32,000-character bootstrap allowance, and successful verification after operator-resume field changes. No claim is made about an actual resumed live coordinator's token baseline.

## Files

- New runtime scripts under `skills/dt-build/scripts/`: `authority-digest.ps1`, `build-authority-digest.ps1`, `verify-authority-digest.ps1`, `read-authority-digest.ps1`, `read-authority-original.ps1`.
- Updated runtime: `skills/dt-build/scripts/context-guard.ps1`, `dt-build-watcher.ps1`, `launch-managed-coordinator.ps1`; `skills/dt-build/hooks/coordinator-pretooluse.ps1`.
- Updated contracts: `skills/dt-build/references/managed-resume.md`, `adapter-claude.md`, `adapter-codex.md`, `resume-bootstrap-measurement.md`.
- New fixture suites: `skills/dt-build/scripts/tests/test-authority-digest.ps1`, `test-coordinator-capacity.ps1`.
- Expanded fixture suites: `skills/dt-build/scripts/tests/test-context-guard.ps1`, `test-dt-build-watcher.ps1`.
- Report and small evidence logs under `_planning/`.

`invoke-codex-chunk.ps1` is unchanged. The FS-63 job-wrapper change remains owned by `fix/codex-readonly-review-reads`. No skill/plugin version or changelog metadata changed; the release coordinator owns those gates and release.

## Verification

All commands below run from this worktree:

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-bootstrap-authority-digest"
```

Before execution, inspected suite and child-launch paths. The executed suites launch no Python, pytest, grader or live model process. The host-adapter wrapper runs a fake PowerShell Codex CLI with isolated credentials, model catalog and router state. Watcher alerts, launchers, transcripts and registry are isolated fixtures. The baseline watcher was independently replayed from a `git archive dfe60f0` source snapshot.

| Command | Main | Final | Delta and mechanism | Evidence log in `_planning/fs-64-evidence/` |
| --- | ---: | ---: | --- | --- |
| `pwsh -NoProfile -File skills/dt-build/scripts/tests/test-dt-job.ps1` | 244 | 244 | 0; existing job contracts preserved | `main-test-dt-job.log`, `final-test-dt-job.log` |
| `pwsh -NoProfile -File skills/dt-build/scripts/tests/test-context-guard.ps1` | 172 | 181 | +9: three checkpoint/handoff checks; three pre-bootstrap wall checks for each of Codex and Claude | `main-test-context-guard.log`, `final2-test-context-guard.log` |
| `pwsh -NoProfile -File skills/dt-build/scripts/tests/test-dt-build-watcher.ps1` | 266 | 275 | +9: captured capacity refusal, three backoffs, two retries, bounded stop, clear alert and operator re-arm | `pristine-main-test-dt-build-watcher.log`, `final2-test-dt-build-watcher.log` |
| `pwsh -NoProfile -File skills/dt-build/scripts/tests/test-host-adapters.ps1` | 142 | 142 | 0; both adapters keep existing structure/word limits and fake-wrapper checks | `main-test-host-adapters.log`, `test-host-adapters.log` |
| `pwsh -NoProfile -File skills/dt-build/scripts/tests/test-authority-digest.ps1` | 0 | 29 | New suite: 18 build/verify/budget/action-read contracts; six forged-content/full-reader/hook checks; two owned-field/authority-field checks; three 99-original scale checks | `test-authority-digest.log` |
| `pwsh -NoProfile -File skills/dt-build/scripts/tests/test-coordinator-capacity.ps1` | 0 | 7 | New suite: overload versus quota, detached receipt, ordinary retry exclusion, all cap exclusions, cross-trigger bound and preservation of prior wall without usage | `test-coordinator-capacity.log` |
| PowerShell AST parse of every changed `.ps1` | — | 13 scripts, 0 errors | Runtime and fixture syntax checked | `static-checks.log` |
| `git diff --check` | — | exit 0 | No whitespace errors | `static-checks.log` |
| `git diff --exit-code -- skills/dt-build/scripts/invoke-codex-chunk.ps1 skills/dt-build/SKILL.md skills/dt-build/CHANGELOG.md .claude-plugin/plugin.json .claude-plugin/marketplace.json` | — | exit 0 | Wrapper, versions and changelogs untouched | `static-checks.log` |

**Total: 878 passing assertions versus 824 in the four existing suites on main; +54 = 9 context + 9 watcher + 29 digest + 7 capacity.** No assertion was removed.

Intermediate failures were resolved: a timestamp assertion compared a deserialized `DateTime` with a string (now compares UTC ticks); the capacity scenario lacked a continuation trigger (now requests `managed_start`); the Claude adapter exceeded its 1,000-word limit by six words (wording shortened); a hook fixture used hashtables instead of deserialized objects (corrected); the first 99-source fixture did not force adaptive clipping (long source names now exercise that path). Partial counts in the earlier `final-*` logs are failed attempts, not pass claims. Full final logs above supersede them. The nine-assertion capacity-only integration probe also passed (`capacity-integration-probe.log`).

## DEFERRED verification

The quiet window prohibits pytest and requires confirming a suite starts no Python. Inspection found Python invocations at lines 46 and 56 of `test-dt-build-regressions.ps1`; therefore the whole suite was deferred rather than partially run. No pytest or Python was executed during this task. After the quiet window, the release coordinator should run:

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-bootstrap-authority-digest"
pwsh -NoProfile -File skills/dt-build/scripts/test-dt-build-regressions.ps1
```

Explicit token-budget remeasurement is also **DEFERRED**:

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-bootstrap-authority-digest"
python skills/dt-build/scripts/measure-resume-bootstrap.py --manifest skills/dt-build/scripts/tests/fixtures/resume-bootstrap-budget.json --repo-root . --canonical-root D:/Claude
```

Pytest routing compliance is **DEFERRED**:

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-bootstrap-authority-digest"
python -m pytest scripts/model-router/tests/test_routing_compliance.py -q
```

Live launch, actual bootstrap token measurement and operator recovery are **UNVERIFIED / NOT EXECUTED** under fixture-only authorization. Version-policy/release gates await the coordinator's requested version bumps; no merge/push/deploy was attempted.

## Exact operator recovery: core-durability-20260922

Run only after the coordinator releases and installs the fix. These are operator commands, not commands executed in this development session. The supplied live folder remains untouched. Resolve the checkpoint from its existing registry entry; do not guess or recursively search:

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills"
$recoveryRunFolder = 'D:/Claude/_Claude-Workspace/OneDrive Migration/File Sorter/file-sorter/.dt-build/core-durability-20260922/core-durability-20260922'
. ./skills/dt-build/scripts/dt-job.ps1
$registration = Get-DtJobRegistryEntry -RunFolder $recoveryRunFolder
if ($null -eq $registration) { throw 'Run registration missing; keep run stopped' }
pwsh -NoProfile -File skills/dt-build/scripts/build-authority-digest.ps1 -RunFolder $recoveryRunFolder -BuildStatePath $registration.build_state_path
if ($LASTEXITCODE -ne 0) { throw 'Digest build failed; keep run stopped' }
pwsh -NoProfile -File skills/dt-build/scripts/verify-authority-digest.ps1 -RunFolder $recoveryRunFolder -BuildStatePath $registration.build_state_path
if ($LASTEXITCODE -ne 0) { throw 'Digest verification failed; keep run stopped' }
```

Then issue `/dt-build resume core-durability-20260922` in the operator session. Resume clears the thrash stop and re-arms launch budgets. The coordinator must read the verified digest and mandatory originals before marking, then full governing originals immediately before dependent actions. Failed digest verification does not authorize resume-dependent work or waive originals.

## Close-out and retained artifacts

Session audit: the quiet window, fixtures-only scope, branch, release ownership and no-delegation instruction are task-specific and already captured here. No durable policy or memory changes are warranted; no scaffold writes or workspace sync occurred.

Automatic approval review rejected deletion of the temporary main-source fixture directory with `blocked by policy` and no further explanation. `_planning/fs-64-evidence/main-fixture/`, its ZIP and `_planning/fs-64-capacity-probe.ps1` are retained untracked and excluded from the commit. The pre-existing `_planning/fs-64-task.txt` and `_planning/fs-64-wrapper.log` are also excluded and preserved.
