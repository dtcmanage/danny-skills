# Category readings schema

Return one JSON object per category: `{ "category": string, "sources_checked": [{ "name": string, "comparable_results_found": boolean, "note": string }], "readings": [{ "benchmark": string, "version": string, "date": ISO date, "harness": string, "effort_class": string, "independent": boolean, "url": string, "results": [{ "model": candidate model ID, "score": finite number, "tasks": integer or null, "margin": finite number or null }] }] }`.

The category must equal the requested category. Every result model must be in the requested candidate list. Include only measured scores. Empty arrays are valid when the checked sources offer no comparable result. Extra fields may appear in returned JSON but are ignored and never persisted or used for routing.
