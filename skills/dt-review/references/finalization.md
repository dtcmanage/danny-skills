# Finalization and Glossary Reconciliation

## 1. Prepare the accepted draft

Derive a 2-4 word kebab-case slug. `FINALIZE_CURRENT` uses the receipt-verified `draft-vN.md`
directly. Never hand-edit an unreviewed `draft-vN+1.md` for either other terminal action.

For `APPLY_POLISH_AND_FINALIZE`, create a JSON array with exactly one entry for every current
`ACCEPT` or `COUNTER` finding and no entry for `REJECT` findings. (`DEFER` prevents this action.) Each
entry carries the current `id`, `finding_hash`, `disposition`, and exact `old_text`/`new_text`. Each
`old_text` must occur exactly once in the receipt-verified source and replacements may not overlap.

For an explicitly approved `USER_DECISION`, create a JSON array covering exactly every current
finding where `blocks_design` is true or disposition is `DEFER`. Each entry carries `id`, `rationale`,
`owner`, and `recheck_gate`; all values are trimmed single lines. Then run:

```powershell
pwsh -NoProfile -File <skill>\scripts\prepare-final-draft.ps1 `
  -ProjectPath <project> -Round <N> -Tier <light|complex> `
  -InstructionsPath <scratch-json> [-ApprovedResidualRisk]
```

`-ApprovedResidualRisk` is valid only after Danny explicitly accepts that `USER_DECISION` outcome.
The preparer verifies the round receipt and current dispositions, writes only `draft-vN+1.md`, and
writes `finalization-manifest-vN+1.json` binding the action and SHA256 hashes of state, source draft,
source receipt, instructions, and prepared draft. Existing outputs must be byte-identical for an
idempotent resume. The residual path performs only this deterministic append:

```markdown
## Accepted residual risks

### R3-F01 - Concise risk name

- Rationale: Why accepting this risk is justified.
- Owner: Role accountable for the risk.
- Recheck gate: Concrete event or validation that revisits it.
```

## 2. Reconcile terminology before writing the final

Read repo-level `references/glossary-contract.md` and apply A1-A8. Resolve/create the project
`CONTEXT.md`, update drifted/new load-bearing terms, and surface meaning conflicts as A/B/C. Surface
promotion candidates under A6; never promote automatically. Record the resolved context path for
the finalization receipt.

## 3. Commit and clean atomically

Run the deterministic finalizer only after `evaluate-termination.ps1` returns a finalizable action:

```powershell
pwsh -NoProfile -File <skill>\scripts\finalize-review.ps1 `
  -ProjectPath <project> -DraftPath <accepted-draft> -Slug <slug> `
  -Round <N> -Tier <light|complex> -ContextPath <CONTEXT.md> -GlossaryReconciled
```

Add `-ApprovedResidualRisk` only after Danny explicitly chose that cap outcome. For every N+1 path,
the finalizer requires the preparation manifest, validates every bound hash, and replays deterministic
preparation to reject arbitrary post-preparation mutation. It also validates latest contiguous state,
terminal reviewed-draft SHA256, shape/title, forbidden review archaeology, exact residual-risk
coverage, canonical project `CONTEXT.md` receipt, existing-final identity, and reparse-aware scratch
containment. It writes atomically and deletes only the verified
`<project>\design\_review` folder.

## 4. Report

Report the bare absolute final path and changed context path. When invoked by a pipeline/subagent, return to the caller without an implementation question. Otherwise stop after the artifact handoff; Danny decides the next stage.
