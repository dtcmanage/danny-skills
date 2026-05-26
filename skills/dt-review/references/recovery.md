# Recovery and Resume

The scratch folder is the state machine. Persistent final output is not.

Scratch location:
- `design\_review\`

Per round N, canonical scratch sequence:
1. `design\_review\prompts\codex-critique-prompt-v<N>.md`
2. `design\_review\review-v<N>.md`
3. `design\_review\codex-stream-v<N>.log`
4. `design\_review\draft-v<N+1>.md` (skipped on terminal verdicts)

## Resume rule

- Identify highest N and first missing scratch artifact in sequence.
- Resume from the step that creates that artifact.
- Existing well-formed scratch artifacts are immutable.

If `design\design-final.md` exists and `design\_review\` is absent, the review is already finalized.

## Malformed feedback rule

When `design\_review\review-v<N>.md` exists but the verdict parser cannot find a valid `VERDICT:` token:
1. Rename the file to `review-v<N>.partial.<YYYYMMDD-HHMMSS>.md`.
2. Re-run codex invoke for the same round.

If the file is well-formed but verdict token is unknown, treat as `MATERIAL_CHANGES_NEEDED` in normal flow
and note the malformed verdict during the active session output. Do not copy that note into
`design-final.md`.
