# dt-review changelog

- 1.7.1 (2026-08-11): State the ambiguity-only field contract: missing_evidence and candidate_dimensions must be empty unless AMBIGUOUS_ROOT_CAUSE, so an ordinary evidence gap no longer trips semantic validation.

- 1.7.0 (2026-07-13): Structured review engine with deterministic finding lifecycle, authorization and termination state, hard process timeouts, integrity-bound prompt/finalization receipts, and fail-closed recovery.

- 1.6.2 (2026-07-12): Inherited the established pack-wide versioning policy and release gate.

- 1.6.1 (2026-07-12): Refreshed active pins to GPT-5.6 Terra for balanced/preflight work and GPT-5.6 Sol for complex rounds; retained explicit medium effort so global Ultra/Max settings cannot leak into review runs; removed Spark from shared fallback paths; made model/effort resolution fail closed and native exit/output validation explicit.

- 1.5.0 (2026-07-05): Single design doc at convergence only, named design-final-<slug>.md; per-round verdicts persisted to scratch verdicts.json for deterministic re-raise tracking; scratch cleanup is an explicit scripted finalization step.
