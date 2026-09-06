# Termination

## Prompt budget on long reviews

Prompt growth is bounded structurally: Round N embeds only the previous round's review/response in
full, and everything older is condensed into the cumulative finding ledger (one row per finding ID,
one line per round). The draft and `review-context.md` still grow with the design itself, so
`assemble-review-prompt.ps1` keeps a runaway guard, default 900,000 UTF-8 bytes (roughly 225k tokens),
overridable per call with `-MaxPromptBytes` or globally with `DT_REVIEW_MAX_PROMPT_BYTES`. It warns at
80% and returns `prompt_budget_bytes` / `prompt_budget_warning` in its JSON.

Treat the warning as a prompt to act while action is still possible: `review-context.md` is the only
input the orchestrator can compact, and past a certain point it is too small to recover the difference.
Raise the budget only after confirming the pinned model can carry it.

## Blocking policy

The reviewer's `blocks_design` bit was the only throttle on the loop, and the 2026-09-06 audit found it
set on ~98% of findings including every low. Both invokers therefore apply a deterministic policy
before validation: high may block in any round, medium only in rounds 1-2, low never. Downgrades are
recorded in `round-meta-v<N>.json` (`blocking_downgrades`) and appended to `review-v<N>.md`; the
verdict is recomputed from the normalized values. The validator itself is unchanged, so artifacts
written before 1.12.0 still verify.

## Contract

`scripts/evaluate-termination.ps1` is authoritative. Run it after every finding has a recorded
disposition and any re-raised rejection has user adjudication.

| Verdict/state | Action |
| --- | --- |
| `NOTHING_TO_ADD` | Finalize the current draft immediately. No confirmation round by default. |
| First `MINOR_POLISH_ONLY` below cap | Apply non-blocking fixes and run one closure round. |
| Consecutive `MINOR_POLISH_ONLY` or minor at cap | Apply non-blocking fixes and finalize without another round. |
| `MATERIAL_CHANGES_NEEDED` below cap | Apply reconciled fixes and continue. |
| Material/deferred finding at cap | Ask Danny: extend one round, stop unfinalized, or explicitly accept residual risk. |
| `MATERIAL_CHANGES_NEEDED` below cap, every blocking finding at its third appearance (persist cap) | Same `USER_DECISION` package, with `persist_capped` naming the findings; recommend residual-risk finalization. |

Caps are 3 rounds for `light` and 4 for `complex` (6 until 1.12.0; the audit of 2026-09-06 found no
review that produced a new finding ID after round 5, only re-litigation). A terminal `NOTHING_TO_ADD` ends the loop even
before the cap. A user may request a named confirmation round for unusually high-stakes work; record
that exception with `scripts/authorize-next-round.ps1` rather than making confirmation the default.
The same authorization record is mandatory when Danny selects a one-round extension at the cap. It
binds the next round to the source round, termination action, tier, and state hash; prompt assembly and
Codex invocation both reject a missing or stale authorization. `CONTINUE` and
`APPLY_POLISH_AND_VERIFY` authorize the next contiguous round automatically.

For a cap extension, write the reconciled immutable N+1 draft before calling the authorizer. For a
named confirmation after `FINALIZE_CURRENT`, the authorizer creates/verifies a byte-identical N+1
copy. For confirmation after `APPLY_POLISH_AND_FINALIZE`, run `prepare-final-draft.ps1` first; the
authorizer replays that manifest before permitting the N+1 review.

The first numbered parse pins `light` or `complex` into every round entry. The tier is immutable for
that review: parsing, termination, assembly, invocation, authorization, and finalization all reject a
caller tier that differs from any persisted state entry, preventing a larger cap from being selected
mid-run.

`evaluate-termination.ps1` accepts only the latest entry in a state sequence containing every round
from 1 through N exactly once. No caller may skip ahead or use an older verdict to reopen the loop.

Finalization after a material cap is never automatic. It requires explicit user approval and an
`## Accepted residual risks` section naming each unresolved finding, rationale, owner, and recheck
gate.

`APPLY_POLISH_AND_FINALIZE` and approved residual-risk `USER_DECISION` are the only actions that may
produce an unreviewed `draft-vN+1.md`. They must use `prepare-final-draft.ps1`; manual N+1 mutation is
not finalizable. The preparation manifest binds the current verdict-state hash, receipt-verified
`draft-vN.md` hash, instructions hash, and resulting N+1 hash. `FINALIZE_CURRENT` remains the direct
receipt-verified N path and does not use a preparation manifest.
