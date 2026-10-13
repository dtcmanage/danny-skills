# FS-64 authority bootstrap digest and FS-63 coordinator capacity handling

Implemented only in `fix/bootstrap-authority-digest`, based on main `dfe60f09f5c2a69f87e0dcce04bd8882219e9c2a`, with this follow-up committed on top of `f7a16bb`. No model delegation, version bump, merge, push or ship. The original commit used fixtures only. This follow-up reads the explicitly authorized live run/checkpoint; every acceptance write is under this worktree's `_planning/fs-64-live-dryrun/`. No live run or checkpoint writes, Python or pytest execution occurred.

## Real-data discovery follow-up (2026-10-13)

The original tokenizer treated `solelyRUN/operator-notes.json` as a literal relative path and missed alias definitions, sibling filenames and brace lists. The live inherited set also does not come from prose: STOP's `inherited_boundary` links six predecessors, whose base `inherited_authority_sources` array enumerates 71 originals. The chain contributes seven four-record STOP bundles: **71 + 7 x 4 = 99**, equivalently the current four plus 95 inherited originals. Each boundary's declared inherited/required counts are checked against the resolved, deduplicated set. Missing originals, missing enumeration fields, count mismatches and cycles fail closed.

Discovery now retains spaced absolute and relative alias values, resolves forward/recursive aliases, recognizes known aliases after glued prose, inherits directories across comma siblings, and expands brace lists. The structured enumeration controls inherited coverage; incidental evidence inside those originals does not recursively expand that controlling set. Legacy literal graphs still recurse. Checkpoint references explicitly requiring reads supplement the enumerated set. Unresolved non-authority references are reported in Markdown and manifest diagnostics; named required originals fail the build, with all discovered missing candidates written to `authority-diagnostics.json` in the output folder. The regression includes two missing inherited originals plus a missing checkpoint-required original and checks that all three appear.

Mandatory reads are the checkpoint, complete run approvals/notes, build-state/build-plan, explicit current STOP boundary, and the current WORK stop records. The checkpoint's four metadata clarifications expressly granting no new authority are retained as supplemental originals for full reads before dependent actions. Historical `next-approval.md` proposal texts are indexed originals rather than 99 repeated mandatory approval reads; the complete current `approvals.json` remains mandatory. Original kind classification uses filenames/approval directories, so a folder containing `after-approval` does not turn every source into an approval.

Repeated long paths also exceeded the budget. Markdown now uses reversible directory/filename tables and shared directory prefixes. Structured sets retain every source path there and the mechanical extracts in JSON. An independent fixture decoder reconstructs every manifest path from the Markdown. Current authority remains full reads; paths, hashes and originals are never omitted to fit.

### Live read-only acceptance

Executed the reproducible probe:

```powershell
cd "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills-bootstrap-authority-digest"
pwsh -NoProfile -File _planning/fs-64-live-acceptance.ps1
```

It invokes the builder with `-DryRun -OutputDirectory _planning/fs-64-live-dryrun` and independently invokes the verifier with `-DigestDirectory` pointing there. DryRun rejects missing output, output under either protected source directory, and a junction disguising source-run output. Normal operator publication commands below remain unchanged.

| Claim/change | Action and exact check | Evidence/result |
| --- | --- | --- |
| Complete inherited authority | Resolve structured chain and check every declared count | **99**: current STOP four + inherited 95 |
| Complete discovery | Independently rediscover and verify every original hash/byte/character size | **109 originals**: 99 + four run records + four metadata clarifications + two WORK stop records; checkpoint is the separate root |
| Candidate diagnostics | Compare rebuilt diagnostics to pinned manifest; inspect Markdown diagnostics | **0 unresolved live candidates** |
| Digest size | Measure emitted Markdown and full mandatory authority text | **3,833 Markdown characters; 31,968 combined bootstrap authority characters / 32,000**; 32-character headroom |
| Original reads deferred | Sum byte lengths of the 102 indexed originals outside mandatory paths | **466,400 bytes** moved out of authority bootstrap, still required before dependent actions |
| Mandatory full authority reads | Sum checkpoint plus seven pinned mandatory originals | **28,137 bytes**; 28,135 characters (build-plan has two extra UTF-8 bytes) |
| Mutable identity read | Keep registered run/lease verification separate from immutable authority pin | Lease **338 bytes**; registration/lease/resume-record reads remain required and outside this authority-only byte metric/budget |
| Read-only live sources | Compare all 109 original hashes/sizes/extracts, complete checkpoint hash and run-root filenames/lengths/write timestamps before/after probe | All unchanged; external pair build and independent verification both **PASS** |

Live checkpoint is **7,998 bytes**. Total indexed authority plus checkpoint is 494,531 characters. The full original bytes are 494,537 = 466,400 deferred + 28,137 mandatory; the six-byte character delta is UTF-8 encoding (two in build-plan, four in deferred originals). This is a character-budget/discovery proof, not a tokenizer or actual coordinator-bootstrap measurement. The mandatory current set is close to its budget; additions must pass verification again.

Evidence: `_planning/fs-64-live-dryrun/acceptance.json`, external digest pair/pin, and `_planning/fs-64-evidence/followup-live-acceptance.log`. The acceptance JSON/log and probe are committed; the generated live pair remains local and untracked because it contains live authority extracts and becomes stale when those sources change. The sanitized fixture is `skills/dt-build/scripts/tests/fixtures/authority-checkpoint-compressed.md`.

### Fully rerun PowerShell suites

All six suites from the original report are rerun in full, with isolated fixture registry/transcript/router/launcher/alert state. No pytest/Python/model process runs. Counts compare this follow-up to `f7a16bb` (and the original main baseline).

| Suite | Main | f7a16bb | Follow-up | Delta from f7a16bb and evidence |
| --- | ---: | ---: | ---: | --- |
| `test-dt-job.ps1` | 244 | 244 | 244 | 0; `followup-test-dt-job.log` |
| `test-context-guard.ps1` | 172 | 181 | 181 | 0; `followup-test-context-guard.log` |
| `test-dt-build-watcher.ps1` | 266 | 275 | 275 | 0; `followup-test-dt-build-watcher.log` |
| `test-host-adapters.ps1` | 142 | 142 | 142 | 0; `followup-test-host-adapters.log` |
| `test-authority-digest.ps1` | 0 | 29 | 51 | +22; `followup-test-authority-digest.log` |
| `test-coordinator-capacity.ps1` | 0 | 7 | 7 | 0; `followup-test-coordinator-capacity.log` |

**Total: 900 passing assertions; +22 from f7a16bb's 878 and +76 from main's 824.** All 29 original digest assertions remain. The 22 additions are: eight sanitized-shape/discovery/diagnostic/budget checks; recursive and spaced-relative alias resolution; brace expansion; alternate-location verification; independent Markdown decoding; forged diagnostics rejection; two DryRun destination checks plus junction protection; missing mandatory approvals; missing-original failure and all-three diagnostics; count mismatch and alias cycle rejection. Logs live under `_planning/fs-64-evidence/`. PowerShell AST parsing covers five touched `.ps1` files with zero errors; whitespace and unchanged wrapper/version/changelog checks pass (`followup-static-checks.log`).

The first follow-up runs caught two corrected PowerShell issues: array concatenation precedence had suppressed legacy candidate patterns, and summing an empty deferred set under StrictMode lacked a `Sum` property. Final complete logs supersede those failed attempts. The budget rejection during development was a real finding: mandatory current reads remain intact; reversible path tables and deferred expressly non-authorizing metadata resolved it.

## Root causes and changes

1. **Authority growth exhausted bootstrap.** Managed resume required every inherited authority original before the marker. The supplied incident has 99 originals and an unmarked coordinator at approximately 202,500 input tokens. The contract now budgets authority bootstrap at 32,000 characters (approximately 8,000 text tokens), consistent with the existing less-than-50,000 input-token target and 200,000 pre-marker wall. Actual tokenizer and marker measurements remain required; character sizing is not a token guarantee. A deterministic digest moves inherited full reads to immediately before their dependent actions. Current boundary, complete approvals, operator notes, checkpoint and current run state remain full bootstrap reads. A digest never grants authorization.
2. **An unmarked coordinator was invisible to wall recovery.** `Update-WatcherContextWall` returned without a bootstrap baseline. It now discovers the exact launch's transcript using cwd, host, launch time and unique coordinator prompt, measures pre-bootstrap usage, and records heavy reads since launch with a null baseline and `pre_bootstrap=true`. Discovery supplies measurement evidence only, not session authority. Existing marked-coordinator behavior remains. A capacity transcript without token usage cannot erase an earlier wall.
3. **Checkpoint installation was blocked at the wall.** The context hook allowed `write-build-state.ps1`, but omitted `write-resume-checkpoint.ps1`. The atomic checkpoint installer is now an allowed handoff command even past the hard limit. A heavy read chained ahead of it is still denied. The fixture actually installs a candidate and checks its archived predecessor.
4. **Capacity refusal consumed the failed-launch budgets.** The detached launcher now writes a coordinator exit receipt with `failure_category=capacity`; the watcher also recognizes historical refusal streams and synchronous launcher failures. Selected-model capacity and equivalent vendor overload refusals use 5/10/20-minute backoffs, bounded to 35 minutes from the episode's first refusal. Launches can retry at minute 5 and 15; continued refusal stops at minute 35, with reason `capacity` and a distinct recovery alert. Capacity launches spend none of the ordinary retry, consecutive-thrash, run cap or absolute launch-cap budgets. New triggers do not reset that capacity wait; operator resume re-arms it.

## Authority contract and implementation

`build-authority-digest.ps1` publishes `authority-digest.md`, `authority-digest.json` and the manifest SHA256 pin. The JSON records each original's absolute path, full-file SHA256, byte size, character size, kind and quoted mechanical extract, plus enumeration and diagnostics. Structured checkpoint discovery is described above; legacy literal graphs follow code spans, Markdown links, JSON strings, bare absolute and relative paths recursively. Sources resolve beside their naming record, then beside the run. No workspace search or model call occurs.

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

## Original f7a16bb fixture verification

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

Live coordinator launch, actual bootstrap token measurement and operator recovery remain **UNVERIFIED / NOT EXECUTED**. The authorized live discovery/verification dry run is proven above. Version-policy/release gates await the coordinator's requested version bumps; no merge/push/deploy was attempted.

## Exact operator recovery: core-durability-20260922

Run only after the coordinator releases and installs the fix. These live publication commands were not executed in development; this follow-up used only external DryRun output. Resolve the checkpoint from its existing registry entry; do not guess or recursively search:

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

Session audit (`dt-session-audit`): the quiet window, read-only live acceptance scope, branch, release ownership and no-delegation instruction are task-specific and captured here. Discovery findings belong in the implementation/report, not canonical scaffold memory. No durable policy/memory changes are warranted; no scaffold writes occurred. Workspace upload/sync is skipped under Danny's explicit no-push instruction.

Follow-up cleanup: automatic approval review rejected deletion of `_planning/fs-64-parser-probe/` with `blocked by policy` and no additional explanation. The temporary development probe is retained untracked and excluded from this commit. No approval request or alternate deletion was attempted.

Automatic approval review rejected deletion of the temporary main-source fixture directory with `blocked by policy` and no further explanation. `_planning/fs-64-evidence/main-fixture/`, its ZIP and `_planning/fs-64-capacity-probe.ps1` are retained untracked and excluded from the commit. The pre-existing `_planning/fs-64-task.txt` and `_planning/fs-64-wrapper.log` are also excluded and preserved.

## Headroom follow-up (2026-10-13)

Committed on top of `387230c` in this worktree. The **32,000-character soft target** still controls digest routing and navigation clipping. Exceeding it proceeds with all current authority, `budget_state: "over_target"` in verification JSON and a visible Markdown-header warning. Only above the **96,000-character hard ceiling** stops with `AUTHORITY_BOOTSTRAP_BUDGET` and an operator suggestion to consolidate or supersede old stop records. This supersedes the earlier single-budget stop wording. The manifest pins both constants; mismatched fields fail verification. Fixed-width headers let resume-owned status/cursor changes cross the target without invalidating authority or adding characters; the full digest reader renders the currently verified warning. Managed-resume step 2 and measurement guidance require observed-transcript confirmation on the next over-target resume.

| Claim/change | Action / exact check | Evidence/result |
| --- | --- | --- |
| Soft/hard thresholds and current authority | Full `test-authority-digest.ps1` rerun; exact 32,000, 32,001, 96,000, 96,001 boundaries; full current-original read; manifest mismatches; cursor-only 32,000 -> 32,004 transition | **66 passing assertions**, versus 51 before (+15); soft-over and exact ceiling proceed, hard-over stops with recovery message |
| Live discovery and budget | Rerun `fs-64-live-acceptance.ps1`, external DryRun build plus independent verification | **109 originals; 99 enumerated; 0 unresolved; 3,989 Markdown characters; 32,124 bootstrap authority characters; `over_target`**; 124 above target, **63,876 below ceiling** |
| All current authority and read-only sources | Before/after inventories, checkpoint hash and root-file metadata | **28,137 mandatory bytes / 28,135 characters; 466,400 deferred bytes; 494,531 total authority characters; checkpoint 7,998 bytes; lease 338 bytes**; all live sources unchanged |
| Syntax and protected files | AST parse five changed PowerShell scripts; whitespace and protected wrapper/version/changelog comparisons | **0 parse errors; all checks pass** |

The live size increase is exactly **156 characters**, entirely the new budget/warning header: 3,833 -> 3,989 Markdown and 31,968 -> 32,124 bootstrap authority. Original counts, mandatory/deferred sizes and source contents have zero delta. All acceptance output remains under `_planning/fs-64-live-dryrun/`: `acceptance.json`, `headroom-live-acceptance.log`, `headroom-test-authority-digest.log`, `headroom-static-checks.log`, and the local untracked digest pair/pin. The test's earlier failed assertion stripped a source's final space when comparing process output; it now strips only process-added newlines and verifies complete text.

No Python, pytest, nested delegation, version bumps, merge, push or live coordinator launch. The next-resume observed-transcript/token check remains **UNVERIFIED / DEFERRED**. Session audit: task-only constraints and implementation decisions are captured here; no durable scaffold writes warranted, and workspace sync is skipped under the explicit no-push instruction. Pre-existing untracked artifacts are preserved and excluded.
