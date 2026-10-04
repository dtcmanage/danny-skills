# Model router roster schema (v1)

`roster.json` is a JSON object with `schema_version: 1`, an ISO `generated_at` timestamp, Boolean `approved`, and `approved_at` (ISO timestamp when approved, otherwise null). `category_jobs` maps every category to one job. `jobs` is keyed by job; each value has `first` (model ID), `first_vendor` (`codex` or `claude`), `backup` (model ID or null), `backup_vendor` (vendor or null), `first_effort`, and `backup_effort`. Both effort fields are required. Allowed text values are `low`, `medium`, and `high`; `max` and `xhigh` are invalid. Both illustrator fields must be null; every other job requires an allowed value in both slots. Writers use the fixed policy: fast `low`, coder `medium`, deep thinker `high`, writer `medium`, illustrator null. Missing or invalid values return `ROSTER_EFFORT: <job>/<slot>`; non-null illustrator effort returns `ROSTER_EFFORT_ILLUSTRATOR: must be null`.

Categories and jobs: `mechanical` -> `fast`; `routine-coding`, `complex-coding`, `ui-frontend` -> `coder`; `code-review`, `planning`, `deep-research`, `math`, `analysis` -> `deep-thinker`; `long-form-writing` -> `writer`; `image-generation` -> `illustrator`.

Validation requires every category and job, with no extra keys. Each populated model slot has a matching vendor. First and backup use different vendors. Only `illustrator` may have a null backup, and its backup must be null. No model matched by `frontier-models.json` may occupy a slot. At most five distinct model IDs may appear across all slots. Validation errors have stable named prefixes.


## Approved quota ties

A non-shadow tied bench run files `<state>/tie-proposals/<job>.json` only when
its two tested model-and-effort configurations equal the roster job's first and
backup configurations. It records `type: tie`, `status: pending`, `job`, `tier`,
`configurations` (candidate and incumbent, each with model and effort), `run_id`
and `bank_hash`. Identical pending, declined, approved or revoked evidence keeps its
original proposal, status and run ID; a later tied run does not ask again.
Use `approve-roster.ps1 -ApproveTie -Job <job>` to approve it,
`-DeclineTie -Job <job>` to decline it, or `-RevokeTie -Job <job>` to remove
approved tie evidence. Approval revalidates both models, both efforts and the
current task bank; it leaves first and backup unchanged.

The optional roster job field `tie_evidence` carries `tier`, `configurations`,
`run_id`, `bank_hash`, and `approved_at`. It is published with the roster.
The supported tier is `standard`. Full and `-Jobs` roster approval preserve
existing tie evidence when both models and efforts are unchanged, and drop it
when either slot changes. Evidence becomes void if either model, either effort,
or the bank hash changes. The bench records `bench/bank-hash.json` with
`task_bank_sha256` and `written_at` at run time and whenever golden approval is
written. Tie evidence is checked against the bank hash recorded at the last
bench or golden-review run; edits to the bank take effect at the next such run.
Resolve reads that file without starting Python. An absent or unreadable
hash voids the evidence, with the existing `roster-tie-invalid:<job>` alert.

With valid approved evidence and neither `-Lane` nor `-EscalateFrom`, the tie-break
reuses local weekly readings after the resolver's ordinary block evaluation.
Claude's normal 5-minute refresh and credential-identity check remain in place;
when that path is not evaluated, only an identity-validated local weekly cache
may be reused. Codex uses whichever of primary or secondary has `window_minutes: 10080`;
a 300-minute window or a window without `window_minutes` is not weekly evidence.
Missing readings, failed credential identity,
nonweekly windows, future timestamps or readings older than 6 hours keep first
choice. Both percentages are rounded to one decimal, with midpoints away from zero,
before comparison: a strictly greater than 5.0-point difference selects the lower-use vendor, while
exactly 5.0 or less keeps first choice. Both observation times use the same US
Eastern format, and the reason describes the final chosen model after overrides.

Lane, drift, escalation, 95 percent quota blocks, vendor incident blocks and
protected handling retain precedence. Ordinary Claude usage refreshes, stale
incident recovery and the bounded Codex catalog retry retain their existing
behavior. A tie-selected vendor and a catalog fallback undergo the ordinary
block evaluation, including its bounded Claude refresh. The weekly comparison
itself adds no network or model call.
