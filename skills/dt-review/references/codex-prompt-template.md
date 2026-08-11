# Codex Review Prompt and Output Contract

`scripts/assemble-review-prompt.ps1` is the only prompt producer. Do not assemble a round prompt
freehand.

Its JSON receipt binds round/tier plus canonical prompt, draft, state, and required-authorization
paths/hashes. `invoke-codex-round.ps1` runs the assembler again, requires the supplied `PromptPath` to
resolve to that canonical prompt, and rechecks the receipt immediately before and after Codex runs.
This prevents a prompt for draft A from producing a review receipt for later draft B.

## Assembly

The script writes `design\_review\prompts\codex-critique-prompt-v<N>.md` in this order:

1. Round instructions and verdict calibration.
2. The trusted canonical dimension contract.
3. Envelope-wrapped current draft.
4. Optional envelope-wrapped `review-context.md` evidence map.
5. For Round 2+, envelope-wrapped prior review/response and cumulative `verdicts.json` state.

Only external/LLM-produced artifacts are wrapped with the shared
`scripts/wrap-prompt-envelope.ps1` primitive. Never wrap the whole assembled prompt; doing so marks
the procedure itself as untrusted data.

## Structured output

`scripts/invoke-codex-round.ps1` passes
`references/review-output-schema.json` through `codex exec --output-schema`, validates the semantic
contracts, and renders `review-v<N>.json` to human-readable `review-v<N>.md`.

Verdict calibration is mechanical:

- No findings: `NOTHING_TO_ADD`.
- Findings exist, none has `blocks_design: true`: `MINOR_POLISH_ONLY`.
- Any finding has `blocks_design: true`: `MATERIAL_CHANGES_NEEDED`.

Severity and finalization blocking are separate axes. Severity follows impact/reversibility; a
medium build-spec clarification can be non-blocking.

Finding IDs are stable across rounds. A new finding uses `R<N>-F<NN>`; a known root cause reuses its
original ID as `PERSISTING`, `REOPENED`, or `REGRESSION`. `prior_finding_checks` must cover every
finding in cumulative state so accepted commitments cannot silently disappear.

`candidate_dimensions` and `missing_evidence` are **ambiguity-only fields**. They describe which single
dimension a finding belongs to, never what the design is missing. When `ambiguous_root_cause` is `false`,
`candidate_dimensions` MUST be `[]` and `missing_evidence` MUST be `""`; when it is `true`, supply exactly
two candidate dimensions plus the evidence that would disambiguate them. Semantic validation rejects the
round otherwise. An evidence gap in the design is a normal finding — state it in `root_cause` and
`remediation`, not in `missing_evidence`.
