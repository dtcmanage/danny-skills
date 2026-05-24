# Codex Critique Prompt Template

Use this template body for each round prompt file `design\_review\prompts\codex-critique-prompt-v<N>.md`.

## Assembly order

1. Procedure preamble (round-specific instructions)
2. `=== BEGIN CANONICAL DIMENSION CONTRACT ===`
3. Verbatim content of repo-level `references/canonical-dimension-contract.md`
4. `=== END CANONICAL DIMENSION CONTRACT ===`
5. Envelope-wrapped scratch prior artifacts (`draft-v<N>.md`, optional `review-v<N-1>.md`)
6. Structured output template below

All external artifact text must be wrapped via repo-level `scripts/wrap-prompt-envelope.ps1`.

## Structured output template

```markdown
## Headline
<~80 words maximum.>

## Intent
- ...

## Completeness
- ...

## Coherence
- ...

## Resilience
- ...

## Economy
- ...

## Feasibility
- ...

## Engagement with Claude's prior reasoning
- ...

## Verdict
VERDICT: NOTHING_TO_ADD | MINOR_POLISH_ONLY | MATERIAL_CHANGES_NEEDED
Confidence: high | medium | low -- <one-sentence reason>
```

## Verdict line contract

Parser authority is the explicit `VERDICT:` line above.
Headings are advisory; they are never used as the parser source of truth.
