# Model router roster schema (v1)

`roster.json` is a JSON object with `schema_version: 1`, an ISO `generated_at` timestamp, Boolean `approved`, and `approved_at` (ISO timestamp when approved, otherwise null). `category_jobs` maps every category to one job. `jobs` is keyed by job; each value has `first` (model ID), `first_vendor` (`codex` or `claude`), `backup` (model ID or null), and `backup_vendor` (vendor or null).

Categories and jobs: `mechanical` -> `fast`; `routine-coding`, `complex-coding`, `ui-frontend` -> `coder`; `code-review`, `planning`, `deep-research`, `math`, `analysis` -> `deep-thinker`; `long-form-writing` -> `writer`; `image-generation` -> `illustrator`.

Validation requires every category and job, with no extra keys. Each populated model slot has a matching vendor. First and backup use different vendors. Only `illustrator` may have a null backup, and its backup must be null. No model matched by `frontier-models.json` may occupy a slot. At most five distinct model IDs may appear across all slots. Validation errors have stable named prefixes.
