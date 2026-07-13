# Recovery and Resume

`design\_review` is the active state machine. For round N, inspect steps 1-6 in order, then choose the
matching branch in steps 7-9 and resume at the first missing/invalid transition:

1. `draft-v<N>.md`
2. `prompts\codex-critique-prompt-v<N>.md`
3. `review-v<N>.json`, rendered `review-v<N>.md`, `codex-stream-v<N>.log`, and `round-meta-v<N>.json`
4. Round N entry in `verdicts.json`
5. `dispositions-v<N>.json` plus a `## Orchestrator Response` appended to `review-v<N>.md`
6. Every finding in round state has a disposition; required adjudication is resolved
7. Cap extension: reconciled `draft-v<N+1>.md`, then `round-authorizations.json`
8. Post-terminal confirmation: byte-identical N+1 via the authorizer after `FINALIZE_CURRENT`, or
   preparation instructions + manifest + N+1 before authorization after `APPLY_POLISH_AND_FINALIZE`
9. Terminal polish/residual finalization: preparation instructions, N+1, and
   `finalization-manifest-v<N+1>.json` without a new-round authorization

Existing well-formed artifacts are immutable except the orchestrator response append. Once round N
exists in `verdicts.json`, `invoke-codex-round.ps1` refuses a same-round reviewer replay. Recovery may
rerun `parse-verdict.ps1 -FeedbackPath review-v<N>.md` only when its sibling `review-v<N>.json` is
byte-identical; its persisted SHA-256
receipt must match, and existing dispositions/adjudication remain untouched. A changed structured
artifact requires explicit state repair rather than an in-place overwrite. Pass `-Tier` with the
review's invocation tier on every numbered recovery parse. The parser requires `round-meta-v<N>.json`
and rechecks both `metadata.round == N` and `metadata.tier == -Tier` before initial persistence or an
identical reparse; a missing, malformed, or mismatched receipt is refused.
Likewise, `record-dispositions.ps1` writes only to the latest contiguous state entry and stores a
SHA-256 receipt for `dispositions-v<N>.json`. A byte-identical replay returns `already_recorded`
without rewriting state; a changed second write, partial legacy disposition state, or retroactive
earlier-round write requires explicit repair.
Resume only from the latest contiguous state entry. Before reassembling or invoking N+1, let the scripts
revalidate any exceptional authorization against the current `verdicts.json` hash; never reconstruct or
copy an authorization by hand.

Both live invocation and recovery parsing use the same semantic validator. It rechecks duplicate IDs,
exact cumulative `prior_finding_checks` coverage, lifecycle labels, ambiguity fields, mechanical verdict,
and the rule that `REGRESSION` requires an earlier ACCEPT/COUNTER while a prior REJECT must be REOPENED
for user adjudication.

If Codex fails, times out, or returns invalid structured output before round state is persisted, retain
the redacted stream, remove any `.tmp.*` review, and rerun the same invoke step. Invocation canonically
reassembles and rebinds the prompt to current draft/state/authorization hashes before retrying. Rename a legacy malformed Markdown review to
`review-v<N>.partial.<YYYYMMDD-HHMMSS>.md` before retrying.

If a final design and scratch both exist, finalization was interrupted. Reconcile glossary state,
then rerun `finalize-review.ps1`; it accepts a byte-identical final as an idempotent resume and
refuses a differing overwrite.
