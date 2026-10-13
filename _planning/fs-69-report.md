# FS-69 report

Implemented hermetic bench renderer injection, external browser-smoke discovery, full-scope Chromium preflight, and the test-machine README setting. No version bumps, push, or merge.

## Test changes

The following named tests change directly or inherit the changed run helper. Parameterized cases inherit the same change; names are listed once.

### scripts/model-router/tests/test_bench_tiers.py

The shared run helper injects the fixed PNG renderer, isolating tier efforts, quality-backed ties, reports, relabels, and effort proposals from Chromium.

- `test_tier_efforts_reports_and_beyond_never_gates`
- `test_per_model_and_legacy_efforts`
- `test_relabel_uses_first_choice_three_reps_and_never_writes_bank`
- `test_hard_effort_down_guard_in_real_tier_run`
- `test_better_is_separate_and_conflicting_winners_do_not_propose_swap`
- `test_explicit_override_controls_both_slots_and_writer_up`
- `test_equal_tier_efforts_skip_calibration_and_relabels`

### scripts/model-router/tests/test_bench_parallel.py

Both bench entry points inject the fixed PNG renderer so serial/parallel comparisons and spend halts have no browser dependency.

- `test_parallel_matches_serial_and_overlaps_calls`
- `test_spend_halt_stops_every_parallel_lane`

### scripts/model-router/tests/test_bench_private_bank.py

The shared run helper injects the fixed PNG renderer; coder runs include public ranked tasks while testing private-task tier discovery. Other helper callers also receive it for future bank changes.

- `test_engine_loads_private_and_duplicate_is_error`
- `test_private_hard_task_participates_in_tier_discovery`
- `test_review_marks_private_real_count_and_resets`
- `test_unavailable_approved_private_bank_is_explained`
- `test_missing_private_bank_can_be_reapproved`
- `test_engine_refuses_malformed_private_tasks`
- `test_loader_duplicate_ids_case_insensitively`
- `test_candidate_input_fallback_only_for_private`
- `test_sibling_location_and_old_bank_is_not_loaded`
- `test_engine_refuses_incomplete_private_task_metadata`

### scripts/model-router/tests/test_bench_quality.py

The shared run helper explicitly supplies the fake renderer for synthetic ranked tasks, keeping quality and spend tests independent of browser installation even when rendering metadata is extended.

- `test_swap_quality_gate`
- `test_higher_effort_wins_equal_passes`
- `test_lower_effort_wins`
- `test_quality_effort_up_requires_known_no_fewer_passes`
- `test_tie_requires_decided_no_difference`
- `test_null_quality_preserves_behavior`
- `test_quality_evidence_overrides_uninformative_passes`
- `test_spend_more_than_five_points_between_tasks`
- `test_unavailable_or_stale_700_call_cap`
- `test_named_threshold_overrides`
- `test_no_proposal_from_completed_tier_when_later_tier_halts`
- `test_comparison_recovers_baseline_and_completes_above_call_cap`
- `test_judge_outage_never_qualifies_effort_down`
- `test_ledger_rows_record_timing_cost_and_quota`

### scripts/model-router/tests/test_bench_runner.py

The shared run helper supplies the fake renderer for public-bank and overridden-bank runs, including writer/coder ranked tasks. Fast/illustrator runs also inherit the deterministic default.

- `test_rubric_full_prose_reaches_judge`
- `test_dated_price_tie_report`
- `test_reps_shadow_baseline`
- `test_environment_retry_and_quota`
- `test_identity_failure_earns_a_third_attempt`
- `test_deterministic_failure_no_retry`
- `test_rubric_self_weight_and_effort_up`
- `test_approved_gate_baseline_and_bank_reset`
- `test_quota_read_failure_is_unknown`
- `test_actual_approved_gate_deficit_fail_unknown`
- `test_blocked_judge_and_successful_retry`
- `test_judge_refresh_and_unavailable_up`
- `test_price_usage_and_malformed_dispatch`
- `test_pelican_manual_only`
- `test_judges_receive_all_rubric_source_evidence`
- `test_judge_effort_is_fixed_and_recorded`
- `test_invalid_judge_effort_is_rejected_before_dispatch`
- `test_exact_weighted_rubric_threshold`
- `test_quota_guard_defers_without_outcome_and_stops_queue`
- `test_guard_after_completed_call_preserves_only_real_outcome`
- `test_guard_after_completed_tier_suppresses_proposals_and_defers_all_ledger_rows`
- `test_guard_during_rubric_judging_creates_no_outcome_for_blocked_unit`
- `test_recovered_dispatch_unknown_is_not_quality_failure`

### scripts/model-router/tests/test_bench_ranked.py

The tier/count parity engine test supplies the fake renderer for its synthetic ranked task. The real rendering test probes the same resolution order and executable existence, skipping unresolved Chromium or Node with a clear installation reason.

- `test_tiers_counts_parity_relabels_and_informative_evidence`
- `test_real_svg_render`

### Existing deterministic ranked tests retained

`test_engine_dispatch_images_and_unavailable_judge` already supplies its own answer-sensitive fake renderer; `ranking()` and direct `rank_tasks()` fixtures already supply deterministic or fail-on-use renderers. They remain unchanged.

### Other bench callers audited

`test_bench_borrowed.py` runs only synthetic exact/rubric public/private banks without ranked tasks, so its four engine entry points need no renderer change. No additional Python `run_bench` callers were found under scripts. All six other test modules with ranked-task-capable engine calls now supply a renderer explicitly.

### PowerShell preflight fixture

`scripts/tests/test-test-preflight.ps1` now supplies a synthetic browser-smoke package outside the workspace, verifies full scope accepts its executable path, verifies full scope rejects a missing executable with the exact fix, and verifies gate scope ignores missing Chromium. Existing full/-Fix fixtures now use that synthetic installation instead of the machine browser.

### Bank identity fixture

`scripts/model-router/tests/fixtures/bench-bank-sha256.txt` was recomputed using `review.bank_hash`: the renderer is a versioned bank file, so editing it changes the identity. `test_baseline_fixture_and_empty_private` uses this refreshed baseline; no task count or grading criteria changed.

## Verification

| Check | Result |
| --- | --- |
| `pwsh -NoProfile -File scripts/tests/test-test-preflight.ps1` | Passed, exit 0; seven fixture assertions reported PASS. |
| `node --check scripts/model-router/bench/tasks/ui-frontend-card/harness/render-ranked.cjs` | Passed, exit 0. |
| `python -c` using `ast.parse` on all seven edited/new Python files | Passed. |
| `git diff --check` | Passed. |
| `pwsh -NoProfile -File scripts/test-preflight.ps1` (full) | Exit 1: UI harness node_modules missing; fix printed: run npm ci in the worktree UI harness. Chromium resolution passed via parent browser-smoke. |
| Python suites | Not run locally, per instruction; coordinator verification on VM remains pending. |

## Session audit

Used dt-session-audit for the close-out review. The no-local-Python-suite constraint and no-version/push/merge boundaries are scoped to this task and retained here. No new durable preferences or terminology require scaffold writes; workspace sync was omitted to honor the explicit no-push instruction.
