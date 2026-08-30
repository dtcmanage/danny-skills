# dt-review changelog

- 1.9.0 (2026-08-30): Cross-family reviewer lane (invoke-claude-round.ps1: a Claude critic for Codex-authored drafts), complex-tier effort parity (Sol at high effort, 600s budget, recorded-reason deviations), settled-decision ledger (adjudicated findings auto-dispose on re-raise instead of re-asking Danny), rolling prompt context (condensed cumulative finding ledger replaces the full verdicts.json embed), Round-1 hard gate for the Build-intake revalidation table, and an explicit subagent cap-gate SendMessage contract.

- 1.8.0 (2026-08-11): Make the prompt-size guard a configurable budget (default 900000 bytes, -MaxPromptBytes or DT_REVIEW_MAX_PROMPT_BYTES) that warns at 80% instead of hard-failing a long review at a fixed 250000.

- 1.7.2 (2026-08-11): Warn at every prompt assembly when review-context.md exists but the draft has no Build-intake revalidation section, so the finalizer's requirement surfaces while the draft is still editable.

- 1.7.1 (2026-08-11): State the ambiguity-only field contract: missing_evidence and candidate_dimensions must be empty unless AMBIGUOUS_ROOT_CAUSE, so an ordinary evidence gap no longer trips semantic validation.

- 1.7.0 (2026-07-13): Structured review engine with deterministic finding lifecycle, authorization and termination state, hard process timeouts, integrity-bound prompt/finalization receipts, and fail-closed recovery.

- 1.6.2 (2026-07-12): Inherited the established pack-wide versioning policy and release gate.

- 1.6.1 (2026-07-12): Refreshed active pins to GPT-5.6 Terra for balanced/preflight work and GPT-5.6 Sol for complex rounds; retained explicit medium effort so global Ultra/Max settings cannot leak into review runs; removed Spark from shared fallback paths; made model/effort resolution fail closed and native exit/output validation explicit.

- 1.5.0 (2026-07-05): Single design doc at convergence only, named design-final-<slug>.md; per-round verdicts persisted to scratch verdicts.json for deterministic re-raise tracking; scratch cleanup is an explicit scripted finalization step.
