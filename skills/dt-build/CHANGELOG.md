# dt-build — CHANGELOG

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
