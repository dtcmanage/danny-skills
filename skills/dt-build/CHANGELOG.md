# dt-build — CHANGELOG

## 2.48.11

- Fix FS-112/113/114/116: verify approved retries, check worker changed-file reports, use heartbeat watchdogs, and document Windows process-start resource recovery.

## 2.48.10

- Fix FS-110 launch-time delegation for routine stops and FS-111 prose path filtering while retaining fail-closed named originals. The dt-job suite now routes every alert to a fake transport and asserts it (FS-115: a fixture alert reached Danny's real Discord).

## 2.48.9

- Run affected tests and fingerprint checks before each full rerun after a fix round (FS-109).

## 2.48.8

- FS-108 overlap starts only after testing and evidence collection end; never fix while a run tests the candidate.

## 2.48.7

- Start the fix round once a failed verdict and defect list are confirmed; report-only corrections run alongside (FS-108).

## 2.48.6

- Every pass runs end to end past failures; fix all findings in one round and repeat until one pass is fully clean (FS-107).

## 2.48.5

- Gate runs refresh the shard durations file automatically (FS-106).

## 2.48.4

- Balance test shards by work: prefer xdist worksteal or a queue; static shards split by recorded durations (FS-105).

## 2.48.3

- FS-103: sample job process-tree peak memory, expose it in status, and size host RAM slots from recent measured job history.

## 2.48.2

- Keep the FromJob relaunch test off the machine-wide pytest lock.

## 2.48.1

- Fix FS-101/FS-102: guard new temporary dt-job run folders, keep copied-run evidence readable, and relaunch saved jobs with exact path overrides and ancestry.

## 2.48.0

- Throughput and hardware: every long-running step gets an explicit parallel-or-serial decision with a named reason (Danny-directed 2026-10-17).

## 2.47.2

- Subagent and teammate coordinators wait for dt-job in the foreground and never end the turn while jobs run (idle-teammate stall, Oct 17).

## 2.47.1

- dt-job cancel kills and verifies the whole worker process tree; wrapper job object kills on close; test-dt-job alerts isolated from Discord (FS-96, FS-97).

## 2.47.0

- Local, reversible work never stops a managed run; lifecycle records are never byte-pinned; roll-forwards run only past the soft target; published tooling is adopted without a stop (FS-95).

## 2.46.1

- Approval files keep timestamp text on rewrite; approval timestamps compare as instants (FS-95).

## 2.46.0

- dt-job status (run level) reports run_status and the pending awaiting stop; watchers read it instead of event types (FS-94).

## 2.45.3

- Roll-forward reviews stay independent: compose archives earlier reviews outside the rollover folder, the prompt forbids consulting them and demands a JSON-only reply, and verify refuses while one remains.
- Roll-forward install names checkpoint lines that point at stop-folder files a rollover lacks (AUTHORITY_ROLLOVER_CHECKPOINT_POINTERS) instead of a bare AUTHORITY_MISSING.

## 2.45.2

- Roll-forward: {clause: X} supersession evidence also accepts an X later folded into a consolidated clause (the first live roll had 487 such drops).

## 2.45.1

- Chunk wrappers keep custody of the worker process tree: a job object tracks every descendant, the output drain is bounded at 30 s after the CLI exits, and orphans (one held a Codex wrapper 33 minutes at 12.7 GB on Oct 15) are stopped and recorded in provenance.

## 2.45.0

- Authority roll-forward record v2: clause text only with an evidence-only provenance sidecar (the first live roll composed 1.0M chars, mostly repeated absolute source paths); reviewed consolidation of restatements into one clause that keeps every restriction; verify refuses a record over the read ceiling.

## 2.44.0

- Add roll-authority-forward.ps1 (prepare, compose, verify, install): each stop rolls the governing stop records into one verbatim current record, drops stale clauses only with evidence and an independent single-dispatch review, appends drops to the evidence-only authority-history.jsonl, and repoints STOP. Digest discovery treats authority-history.jsonl as evidence only and parses .jsonl paths whole.

## 2.43.0

- Add -SingleDispatch to invoke-codex-chunk.ps1 and invoke-claude-chunk.ps1: capacity, offline and unexplained retries fail closed as single-dispatch-refused, recorded in provenance (single_dispatch, single_dispatch_refused_branch, Claude dispatch_count).

## 2.42.3

- The watcher restores run_status runnable when an approval recorded in approvals.json and the ledger was lost from a rewritten checkpoint; repairs are logged to watcher-repairs.jsonl.

## 2.42.2

- The context wall never blocks instruction and policy files (CLAUDE/AGENTS/MEMORY/CONTEXT.md, 00_Resources policy, skill SKILL.md and references); data files stay walled.

## 2.42.1

- Ad hoc runs keep a worker-written -OutputPath report and file the final chat message as <OutputPath>.final.md (provenance: worker_output_kept, final_message_path).

## 2.42.0

- Add data-only evidence notes (dt-job note -Evidence): stored in evidence-notes.json, shown labeled in status/wait, refused when they carry authorization language, and excluded from the authority digest.

## 2.41.2

- Watcher: a coordinator killed by a host restart is not a capacity refusal; the log fallback only counts a refusal in the last 40 lines.

## 2.41.1

- Blocked-report classifier ignores report headers, the verdict word and CHANGED_FILES paths, and matches whole-word denial phrases on one line; a content BLOCKED is no longer labeled sandbox_tool_denied.

## 2.41.0

- Managed runs: worker authority scope. The authority read contract binds the coordinator; worker briefs carry written restrictions and only the originals the task consumes.

## 2.40.2

- dt-job wait on a single job no longer requires -Any or -All; usage examples pass -TimeoutSec.

## 2.40.1

- Re-release of 2.40.0 with console-wrap-tolerant reason-cap test.

## 2.40.0

- Worker dispatch: -MaxFixRounds with a no-progress stop, -ValidateOnly, effective selection-reason length check (FS-62), ad-hoc output outside the project tree, prompt-sibling resolution, dt-job requeue and documented -DependsOn chaining.

## 2.39.0

- Revision resolver adds append-only proofs for pinned runtime files (protected rows unchanged) and ON_MAIN proofs against any repo via -RepoRoot, incl. the workspace repo.

## 2.38.5

- Model router bench (shared component): bench tests use a fake renderer, and the ranked renderer finds browser-smoke through DANNY_BROWSER_SMOKE_DIR outside the workspace tree; the task bank is unchanged (FS-69).

## 2.38.4

- Read-only Codex reviewers run in the real MXC sandbox (shared process wrapper); a blocked sandbox read is reported as a blocked review, not a pass.

## 2.38.3

- Model router bench (shared component): broken or quota-blocked Codex calls stay out of bench results; recovered dispatch failures no longer break quality ties.

## 2.38.2

- Worker standing rules: run the full named test selection without early-stop flags, classify and fix every failure per round; the two-attempt limit counts rounds, not failing tests (FS-60).

## 2.38.1

- Review-input guidance moved from SKILL.md into references/subagent-prompts.md to keep SKILL.md within its word cap (FS-56 follow-up).

## 2.38.0

- Review-input snapshot packets (prepare/verify-review-packet.ps1, references/review-inputs.md) let reviews pin mutable operator context as a snapshot; shared path identity treats slash spelling, case and trailing separators as one path (FS-56).

## 2.37.1

- Usage collection and the machine test lock use a shared Eastern-time helper that works without the tzdata package; test dependencies are declared in requirements-test.txt and preflighted by the ship gate (FS-66).

## 2.37.0

- New read-only resolve-tooling-revision.ps1 maps a tooling file's exact bytes to the danny-skills main commit that published it, so pinned runs can accept releases automatically and stop only on unpublished edits (FS-68).

## 2.36.1

- Watcher trusts a matching coordinator exit receipt over log text when classifying capacity refusals; a clean exit no longer stops a run as capacity (FS-67).

## 2.36.0

- dt-job approval queue applies and records correctly (FS-57); MODEL_SELECTION prints when the model resolves (FS-59); optional machine test lock that a job or acceptance entry opts into with exclusive_reason, never by default (FS-58)

## 2.35.1

- Codex jobs refused for vendor capacity are classified capacity (not ROUTER_UNEXPLAINED) and retry the same model and effort after 5, 10 and 20 minutes (35-minute bound), with attempts and waits in provenance; outcome mining excludes capacity from model quality.

## 2.35.0

- Managed resume reads a hash-verified authority digest at bootstrap and each governing original in full right before its action (32,000-character target, 96,000 ceiling); discovery handles compressed checkpoints (aliases, glued prose, brace lists, inherited_boundary enumeration). The watcher records context walls for coordinators that never marked bootstrap, the checkpoint installer stays allowed past the wall, and coordinator launches refused for vendor capacity back off 5/10/20 minutes without spending thrash or cap budgets.

## 2.34.2

- Routing-compliance counter counts router wrapper calls (no -Model) as routed, taking category from -Category or -Tier; cache version 4 re-tallies history.

## 2.34.1

- The dt-job test suite holds in-flight jobs on release files instead of Start-Sleep timers, so its queue, dependency, mutation-key, cancel and check-in scenarios no longer race the clock under load (two flakes seen on Oct 12 during concurrent suite runs; three concurrent runs pass after the change).

## 2.34.0

- The PreToolUse hook records each single-file read per coordinator in hook-reads.jsonl and denies the third full read of the same file, pointing to read-evidence slices; sliced reads still pass. The watcher's automatic kill handoff lists the killed coordinator's top repeated reads. Driven by a live coordinator that read one 20 KB boundary file 72 times before bootstrap.

## 2.33.0

- Run-level worker pin: dt-job pin -Vendor codex|claude -Model <id> (operator-only, or -PinVendor/-PinModel on register-run) stores the pin on the registration; dt-job start refuses a worker on the other vendor and passes DT_BUILD_RUN_PIN_VENDOR/MODEL to every job; both chunk wrappers dispatch on the pinned model without -Model and fail closed on a conflicting vendor or model; status, wait and read-resume-record show the pin, so handoffs no longer restate it.

## 2.32.0

- Every launch row records a checkpoint fingerprint (SHA-256 of the Next step section). The watcher stops a run after two consecutive launches that made no progress on an unchanged fingerprint, instead of waiting for six in an hour; the Discord alert names the coordinators and the last five commands of the dying one. Resume re-arms it like the other caps.

## 2.31.0

- read-evidence.ps1 takes -JobId <id> -File summary|stdout|stderr|spec|report|provenance and resolves the file from the job record, so coordinators stop guessing evidence names; a miss inside a job folder lists the files that exist, and a bare run-file name suggests its run-folder path. Status and wait envelopes carry a one-line evidence_hint.

## 2.30.1

- dt-job.ps1 and collect-usage.ps1 resolve the skill folder's link target before walking up to the repo root, so dt-job's Discord alert script and the router scripts are found when dt-build runs through the Codex skill junction; the dt-job suite loads the library through a real junction and checks the fallback.

## 2.30.0

- Job summaries and the status, wait and check-in envelopes carry report_verdict (the worker report's VERDICT), failure_category and wrapper_pass from the wrapper's provenance; a succeeded job whose report says FAIL or BLOCKED, or whose wrapper reported failure, now reads verdict fail with a blocker naming the report. Coordinators no longer open each report to learn the outcome.

## 2.29.0

- The PostToolUse hook records every git worktree add a coordinator runs in worktrees.jsonl. The watcher's automatic kill handoff lists the trees that coordinator created (recorded and live, by admin-directory creation time), and read-resume-record.ps1 returns worktrees (recorded and live since the run's first launch) so a successor reuses the right tree instead of creating a parallel one.

## 2.28.1

- The ship gate runs the host-adapter, context-guard, dt-job and wrapper regression suites before the plugin validate-only build. Get-DtCtxTokens finds newlines with a native reverse search instead of a per-byte PowerShell loop (multi-MB fixture reads drop from about 1.5 s to under 200 ms), so the context-guard timing check no longer flakes under load. The regression suite's hang scenario sends a prompt under the dispatch size guard again, and the guard has its own regression check.

## 2.28.0

- The watcher writes a compact handoff note, built from the job ledger and the coordinator log, for a coordinator it kills at its context limit; a coordinator's own note is never overwritten. read-resume-record.ps1 returns the newest such note as kill_handoff.

## 2.27.2

- Job envelopes decode a pwsh child's CLIXML stderr and strip ANSI colour codes, so a failed job's real error reaches the coordinator instead of being cut off inside one long XML line.

## 2.27.1

- hold no longer waits for a live watcher-launched coordinator to exit: it only adds a reason to Danny's DM. approve, resume and delegate still wait.

## 2.27.0

- Repeat-wall guard: when a coordinator uses up its working room without starting a job, the watcher records the files whose reads filled it (context-wall.json). The next coordinator sees them in its resume record, and the PreToolUse hook denies direct reads of them, sending the read to a mechanical worker.

## 2.26.0

- Added the hold verb: a delegate holding a stop on purpose records why, and the 15-minute escalation DM tells Danny who is holding it and why instead of saying nobody approved it.

## 2.25.2

- model router: read-only Codex workers on Windows can read files (unsandboxed with an unchanged-tree check); the ad-hoc wiring test uses the fixture Claude CLI.

## 2.25.1

- model router: chunk wrappers refuse prompts over 400,000 characters (PROMPT_TOO_LARGE) and point to path-plus-sha256 references.

## 2.25.0

- model router: chunk wrappers gain -AdHoc for one-off work outside a dt-build run (routing and accounting kept, dt-build envelope checks skipped).

## 2.24.0

- Operator notes: dt-job note adds standing instructions in operator-notes.json that run status, every wait and read-resume-record show in full; coordinators follow them and never copy them into the checkpoint.

## 2.23.0

- Approval delegation: dt-job delegate routes routine await-danny stops to a named session with no DM; the watcher DMs Danny after 15 unapproved minutes; production, install, Azure, irreversible and -AlwaysNotify stops always DM; finish sends a digest of delegated approvals.

## 2.22.1

- No job is stopped on time: -TimeoutSec is every job's expected duration and reconcile never ends a live job past it; stalls surface at check-ins.

## 2.22.0

- model router: chunk wrappers have no time limit under dt-job; activity check-ins flag stalls instead.

## 2.21.19

- model router: the bench lets Codex retry its own stream errors and names final errors by code.

## 2.21.18

- Coordinators get 250k tokens of working room past startup: wrap-up at baseline + 250k, handoff-only at + 280k. Managed Codex runs Sol at its 872k window (compaction at 800k) with the hard limit capped at 760k and the watcher backstop at 790k; Claude stays capped at 240k. SKILL.md no longer has drivers pass -TimeoutMs 600000.

## 2.21.17

- Coordinators get 150k tokens of working room past startup: wrap-up at baseline + 150k, handoff-only at + 180k, hard limit capped at 240k and watcher backstop at 252k to stay under Codex Sol's usable window.

## 2.21.16

- Managed Codex coordinators get the context hooks as trusted session flags and hand off at a safe point after the soft limit; past the hard limit only handoff steps run, and the watcher kills only as a backstop (30k tokens past hard or 10 minutes). Doc word limits restored.

## 2.21.15

- Use a lean bridge and source-rendered coordinator rulebook for managed Codex resumes; preserve authorization reads and strip the opt-out from all workers.

## 2.21.14

- Chunk wrappers default to 45 minutes for coder work and 30 for deep-thinker work instead of 10, and dt-job start raises a wrapper job's shorter -TimeoutSec, so builders are no longer killed mid-work.

## 2.21.13

- Exclude ledger-proven productive rotations from the thrash cap, retain a distinct 30-launch ceiling and consumed-cursor evidence, narrow managed resume bootstrap, archive bounded checkpoints, and add progress/baseline regression gates.

## 2.21.12

- Shared model router: ranked judging calls a winner only on a statistically significant lead over 16 rounds; lower-effort and swap proposals are blocked when they trail.

## 2.21.11

- Shared model router: new models read 'researched' after their release research pass instead of staying 'unprofiled'.

## 2.21.10

- Shared model router: bench call time limit is now set per job; deep-thinker calls get 15 minutes so hard questions can finish.

## 2.21.9

- Watcher, chunk wrappers and shared router messages state quota as X% used / Y% left with reset times in US Eastern, so a remaining-percent reading is never mistaken for usage.

## 2.21.8

- Shared model router: Codex prompts rejected as too large (input_too_large) now fail fast as a tooling failure, with no retry and an alert naming the prompt size and the limit.

## 2.21.7

- Model router bench runs model calls side by side (default 32 at once) and asks both judges at the same time; a deep-thinker comparison drops from hours to minutes.

## 2.21.6

- Model router usage reads as X% used / Y% left in the weekly report, limits CLI, and limit wait reasons; the weekly report adds a Codex usage line.

## 2.21.5

- A rotating coordinator no longer consumes its own continuation request, so the watcher always relaunches a successor; rotation steps now consume handled events first.

## 2.21.4

- Model router re-checks Codex limits live when a stale reading says Codex is blocked, so a usage reset is seen without waiting for a Codex run.

## 2.21.3

- Live test harness checks the real model router first and skips any vendor the router says to wait on, so live tests never run past the usage guard.

## 2.21.2

- Shared model router: DT_ROUTER_GUARD_OVERRIDE lifts the 95% quota guard for named vendors in one process, only on Danny explicit permission.

## 2.21.1

- Final-integration fixes: safe hook install on a settings file with no hooks key, managed start reachable from an interactive session, watcher triggers only on actionable events, hook binding independent of bootstrap order, live harness fixes for Codex 0.162 rollouts.

## 2.21.0

- Orchestration hardening: job ledger and bounded evidence, watcher and managed relaunch, context guard and hooks, report v3 and continuation, host adapters, scenario validation and adoption procedure.

## 2.20.6

- Shared model router scripts: declined effort swaps stay declined, one bench comparison at a time, research replies parse past a timestamp preface.

## 2.20.5

- Model router bench: each Codex bench call saves the app-server weekly rate-limit snapshot as a fresh reading (ephemeral turns write no rollout file, so the spend stop had no Codex baseline and hit the call cap); the runaway call cap rises to 700, above a two-tier deep-thinker job. A rep whose first two attempts were vendor identity failures gets a third attempt.

## 2.20.4

- Model router bench: per-call and per-tier timing, call counts and latency in telemetry, a bench ledger (state/bench/ledger.jsonl) recording cost, duration and quota per comparison; an undecided quality verdict no longer qualifies effort-down or swap proposals. Codex judge turns that send rendered images now pass the raw-evidence check (input_image), so Astra image judging works live. A spend baseline must be a reading observed within 10 minutes of the comparison start, so earlier jobs' use no longer halts a later comparison. A vendor-incident block now needs a status-page outage; degraded_performance is recorded but never blocks.

## 2.20.3

- Model router: new-model bench comparisons run in the overnight cadence with the release research pass (one per job the model does not already hold), never from the daytime catalog check.

## 2.20.2

- Model router: a triggered bench comparison with the same job, models, effort, bank and judges is run once (duplicates are logged, not re-run), and the nightly cadence no longer queues refresh research on its own; research runs only for a new frontier-vendor release or on Danny's call (run-router-cadence.ps1 -Refresh).

## 2.20.1

- Model router benchmark: private task bank beside the router state, Aider and HLE importers, a Node test grader, ranked quality tasks judged blind by both judges, quality verdicts that gate swap, effort and tie proposals and are rechecked at approval, a per-comparison spend stop, and valid UTF-8 bench output. The in-repo bank is now 25 tasks, so answer sheets need fresh approval.

## 2.20.0

- Add difficulty tiers to model routing: chunks run at standard (medium effort) or hard (high effort) through -Difficulty and -DifficultyReason, a failed standard attempt retries at hard with -RetryAtHardFrom before moving a model up, approved ties go to the vendor with more weekly quota left, and work harder than high effort waits on a frontier request Danny approves by name. The benchmark gains grounding tasks that catch made-up answers.

## 2.19.7

- Isolate model router benchmark calls from personal configuration, accept a single fenced answer with surrounding prose, and report first-attempt failures per model.

## 2.19.6

- Preserve UTF-8 model prompts and responses across redirected process and PowerShell shim boundaries.

## 2.19.5

- Correct model router starter-bank grading, fix judge effort and duration-aware usage pricing, bind proposal approval to current evidence, and retire the obsolete canary runner.

## 2.19.4

- Correct model router grading for typed React notes and malformed ledger entities.

## 2.19.3

- Make benchmark answers tool-free, reject shadow effort proposals, and ignore unrelated duplicate vendor status names.

## 2.19.2

- Use active CLI discovery for benchmarks, disable inherited time reminders, and price cache writes explicitly.

## 2.19.1

- Refresh a rejected automatic Codex catalog from the current CLI; preserve quota and fallback behavior.

## 2.19.0

- Expand shared model routing with triggered internal benchmarking, Mac-local observation and concurrent outcome safety.

## 2.18.1

- Update the shared vendor-failure diagnosis consumer version for degraded-component handling when the incident feed is unavailable.

## 2.18.0

- Add router diagnosis verdicts, vendor-incident failover, research and canary reliability, acknowledge support, and a routing compliance report with execution-aware command counts.

## 2.17.0

- model router consolidation: the routing section points at the shared router (one category per chunk, resolve without -Lane, dispatch on the returned vendor with -Effort, print MODEL_SELECTION, retry once on ROUTER_LIMIT, wait carries resume_after_et); context discipline trimmed to the load-bearing rules; wrappers take -Effort; bridge mode and the v1 table are gone

## 2.16.4

- model router: read Claude weekly usage from the OAuth usage endpoint (5-minute cache, token never stored) and move Claude jobs to their Codex backup at 95%, same as Codex; weekly cost report shows the Claude weekly and 5-hour readings

## 2.16.3

- model router: price GPT-6.1 Sol and Sonnet 5.5 so reports and canary stop showing them unpriced; canary finds claude.exe when claude.ps1 is absent and strips the session timestamp stamp and markdown fences before grading, and the code-review grader judges the whole answer (Claude models were never canaried, and fenced code failed every code task)

## 2.16.2

- Router: GPT-6.1 Sol replaces GPT-6 Sol as the Codex Sol rung; research retries transient Codex failures, keeps Codex error output, and checks Artificial Analysis for launch-day scores.

## 2.16.1

- Model router alerts refuse real delivery from tests.

## 2.16.0

- Roster dispatch: delegated work resolves by category without a lane and routes to the returned vendor; math and analysis categories; wrappers fail closed on router wait; no frontier escalation (model router v2).

## 2.15.2

- Model router: research grades must be confirmed by two runs, the current pick keeps its place without evidence, older models need a higher grade, protected work only moves up, and evidence routing waits for approval.

## 2.15.1

- Model-router research now sends its profile schema inside the prompt, so research runs produce valid profiles.

## 2.15.0

- Route build chunks through the shared model router with bridge defaults and evidence-based picks.

## 2.14.2

- Codex resolver never auto-routes frontier models (catalog description 'frontier', e.g. GPT-6 Astra, Fable-tier cost): complex and standard now resolve to GPT-6 Sol, light to Luna; frontier runs only as an explicit -Model override.

## 2.14.1

- Claude-lane provenance records the exact model version that ran (resolved_model from the CLI's JSON modelUsage, plus models_used and total_cost_usd) instead of the alias; a run outside the requested family or with no model report fails closed.

## 2.14.0

- Codex tier models are auto-selected from the live account catalog (codex debug models): the newest generation ranked by catalog priority maps to complex/standard/light, so new OpenAI releases are picked up with no edit; hardcoded 5.6 slugs removed, -Model is an explicit override that fails closed, provenance records model_ladder, and usage attribution keeps full gpt slugs.

## 2.13.1

- Corrected stale wording: Codex is the most-used orchestrator in practice (usage ledger); only its stage-2 hardening remains unbuilt.

## 2.13.0

- Automatic usage telemetry: collect-usage.ps1/.py sweep Claude Code and Codex session logs at intake and completion into a per-machine usage ledger and usage-dashboard.html, with one-time advisory alerts for bloated context, nested agents, resume messages, idle cache loss, and Opus overuse. Also lands the JSON acceptance-artifact fix (extract-named-artifacts and verify-milestone-acceptance recognize .json paths) and the local file-link contract wording.

## 2.12.0

- Context discipline and lane default: standing no-nested-agents, quiet-output, and ~100-tool-call checkpoint rules in every assembled prompt with a CONTINUATION_STATE report field; fresh-session continuation replaces resuming a working builder; thin-orchestrator rules; standard tier is the default and complex must be earned; dispatches stay in the orchestrator's family (codex-host verifies on Codex, claude-host should build on Codex); invoke-claude-chunk.ps1 starts a slim session (no MCP, no Agent tool) with -ReadOnly for verifiers.

## 2.11.2

- Shared canonical-dimension-contract.md: security minimum checks apply only to artifacts with external actors or untrusted input; no change to this skill's own files.

## 2.11.1

- Shared canonical-dimension-contract.md: Resilience security-minimum N/A standard scales to stakes; no change to this skill's own files.

## 2.11.0

- Enforce a mandatory pre-dispatch model-selection report and persist its reason and canonical line in both lane wrappers.

## 2.10.1

- Restore the Codex implementation lane on Windows: invoke-codex-chunk.ps1 runs substantive chunks unsandboxed via explicit default_permissions (Codex removed its Windows sandbox; workspace-write failed closed and blocked every command); provenance records the effective mode.

## 2.10.0

- Model-selection disclosure: every subagent dispatch states the selected model and a one-sentence reason in chat for tier-routing tracking.

## 2.9.1

- Dual-harness wording pass from the Codex harness review: harness contract + CLAUDE_DISPATCH abstraction used in steps 6.b/6.c/6.d/6.5, lane-neutral prompt assembly, Claude-tier preflight on codex-host, compatibility/invocation wording, ScheduleWakeup dropped from allowed-tools, approval posture recorded in Codex wrapper provenance. Codex orchestration remains unverified end-to-end.

## 2.9.0

- Two-lane model tiering: Claude-lane tier map (haiku/sonnet/opus), light-tier implementation allowed with escalate-on-retry, cross-model dispatch via new invoke-claude-chunk.ps1, milestone scope lock with DISCOVERED_ENHANCEMENTS report field (report contract v2), orchestrator-owned enhancement triage, deferred-findings section in the final ledger.

## 2.8.3

- Aligned light-tier Codex fallbacks with the canonical GPT-5.6 matrix while retaining strict cache validation.

## 2.8.2

- Added the pack-wide version-policy gate to danny-skills finalization.

Historical `metadata.changelog` entries, relocated verbatim from the SKILL.md frontmatter on
2026-07-05 so the skill no longer loads ~1,000 words of history on every fire. Newest first; new
entries go at the top. The connective lead-ins ("Prior ...", "Previous ...") are preserved exactly
as they appeared in the original single frontmatter string.

## 2.8.1

- Added deterministic GPT-5.6 routing and invocation provenance: Terra/medium for standard chunks,
  Sol/medium for load-bearing or second attempts, and Luna only for light preflight/routine work.
- Fixed the impossible parent/child Git ref contract by making `build/<RUN_ID>` the sole state carrier.
- Final ledgers now render append-only acceptance rows by default, require commit-backed implementation
  evidence, preserve semantic downgrade approvals, and avoid rerunning disposable-environment tests.
- Acceptance commands no longer duplicate inner pytest calls, use bounded file-redirected execution to
  avoid stdout/stderr deadlocks, and cannot PASS final acceptance without an executed command.
- Fixed fresh-process intake, stale `dev` defaults, junction root resolution, multi-check load-bearing
  detection, and non-blocking drift exits. Added dependency-preflight and attempt-category semantics.
- Hardened the canonical Codex wrapper with an internal process-tree timeout, structured report validation,
  effort/model compatibility checks, failure provenance, and redaction of both streams and retained output.
- Final ledger evidence now resolves the recorded commit in live Git history, rejects compound pseudo-PASS
  statuses and unapproved per-check downgrades, and blocks protected-branch intake/CAS mutations.
- Added a hermetic regression suite covering historical false-PASS cases, noisy/deadlocked commands, model
  fallback, malformed/hanging Codex processes, branch preparation/CAS, resume safety, and the two-attempt cap.

## 2.7.1

- `verify-milestone-acceptance.ps1` spawns named commands via `-EncodedCommand` so embedded double quotes
  (for example, quoted paths) no longer truncate the command.

## 2.7.0

- Added per-milestone `_build-state.md` checkpoints using the dt-pipeline template and COMPLETE marking.
- Made `build-run-review.html` on-request only and accepted `design-final-*.md` intake.
- Relocated frontmatter changelog history to this file.

## 2.6.0

- Roadmap-preferred-not-required intake: dt-build now accepts a finalized design (design-final.md / plan-draft.md) as input, not only a dt-roadmap roadmap.md. New procedure steps 2 (detect roadmap vs design), 2.5 (auto-generate the roadmap from a design via the canonical skills/dt-roadmap/scripts/build-roadmap.ps1 — no re-implemented milestone parsing, no schema duplication), and 2.6 (validate, formerly step 2). A roadmap is preferred for heavier builds (many milestones or any load-bearing/gate milestone, which dt-build now recommends a reviewed dt-roadmap pass for) but is never a hard requirement; when a design lacks an Implementation Sequence / Validation Gates surface the build STOPS with the producer's graceful explanatory message instead of crashing. 'When this fires' and references/shared-input-routing.md updated to document design-or-roadmap intake.

## 2.5.0

- Prior 2.5.0 trunk-based-branch-model: integration target moved off the retired dev branch to a short-lived build/<RUN_ID> branch cut from main (2026-05-28 workspace-wide trunk migration); per-milestone accepted work compare-and-swaps onto build/<RUN_ID>, and the rehearsed branch is left for a separate human-authorized /git-merge-feature to main (dt-build never writes to main). scripts/dev-cas-update.ps1 renamed to scripts/branch-cas-update.ps1 and generalized (mandatory -TargetBranch/-ExpectedTargetSha; output keys target_branch/expected_target_sha/observed_target_sha; CAS_* error prefixes). branch-contract.md, resilience-security.md, and subagent-prompts.md updated.

## 2.4.0

- Prior 2.4.0 behavior retained: Per-milestone acceptance gate now evaluates EVERY verification-manifest row for a milestone, not just the first. Prior implementation (verify-milestone-acceptance.ps1) used `Select-Object -First 1` against the rows matched by milestone-id, so any milestone with multiple CHK-* checks had partial gate coverage — only the first check's procedure was parsed for artifacts/commands and only its named test command was run. Calibration event: 2026-05-27 db-durability build at file-sorter, where M02 reported PASS by running only CHK-M02-POPULATED-UPGRADE while CHK-M02-ROLLBACK and CHK-M02-STALE-V11-REGRESSION were silently skipped despite being load-bearing in the roadmap. v2.4.0 changes: (1) verify-milestone-acceptance.ps1 pools every matching verification row, extracts artifacts and commands per row, presence-checks each row's artifacts against the working tree, runs each row's named commands under -RunTests, and folds every exit code into the verdict. JSON output adds a `verification_checks` array (each element exposes check_id, procedure_text, artifacts_named/present/missing, commands_named, command_results, test_status, blockers) alongside the existing top-level fields (status/accepted/blockers/artifacts_missing/commands_named/command_results) which remain the rolled-up view consumed by build-acceptance-ledger.ps1. status is PASS only when every check's blockers are empty. (2) build-acceptance-ledger.ps1 surfaces the per-check breakdown in the HTML ledger as a Verification Check Detail section — one sub-table per milestone listing each CHK-* id, status badge, named artifacts (with missing markers), and named commands with exit codes. Markdown ledger remains the roll-up. (3) acceptance-contract.md updated to document that the gate evaluates every verification row per milestone — the contract previously read as if every check was enforced; v2.4.0 makes the implementation match.

## 2.3.1

- Previous 2.3.1 acceptance gate fixes (pytest -> python -m pytest, downgrade_approved_by parser + APPROVED_DOWNGRADE status) are retained unchanged.
