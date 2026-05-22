# Recovery and Resume

The design folder is the state machine. Resume at the first missing artifact in sequence.

Per round N, canonical sequence:
1. `design/prompts/codex-critique-prompt-v<N>.md`
2. `design/codex-feedback-v<N>.md`
3. `design/codex-stream-v<N>.log`
4. `design/claude-response-v<N>.md`
5. `design/draft-v<N+1>.md` (skipped on terminal verdicts)

## Resume rule

- Identify highest N and first missing artifact in sequence.
- Resume from the step that creates that artifact.
- Existing well-formed artifacts are immutable.

## Malformed feedback rule

When `codex-feedback-v<N>.md` exists but the verdict parser cannot find a valid `VERDICT:` token:
1. Rename the file to `codex-feedback-v<N>.partial.<YYYYMMDD-HHMMSS>.md`.
2. Re-run codex invoke for the same round.

If the file is well-formed but verdict token is unknown, treat as `MATERIAL_CHANGES_NEEDED` in normal flow
and record the malformed verdict note in Dialogue Log.
