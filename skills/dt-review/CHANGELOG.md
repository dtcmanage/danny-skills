# dt-review changelog

- 1.6.1 (2026-07-12): Refreshed active pins to GPT-5.6 Terra for balanced/preflight work and GPT-5.6 Sol for complex rounds; retained explicit medium effort so global Ultra/Max settings cannot leak into review runs; removed Spark from shared fallback paths; made model/effort resolution fail closed and native exit/output validation explicit.

- 1.5.0 (2026-07-05): Single design doc at convergence only, named design-final-<slug>.md; per-round verdicts persisted to scratch verdicts.json for deterministic re-raise tracking; scratch cleanup is an explicit scripted finalization step.
