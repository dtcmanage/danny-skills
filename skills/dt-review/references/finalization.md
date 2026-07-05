# Finalization and Glossary Reconciliation

Finalization starts when termination criteria are met.

## 1) Final draft

Derive the design slug: 2-4 kebab-case words from the plan/project name (lowercase, hyphens, no
stop-word padding). Example: plan "LP Statement Linking" -> slug `lp-statement-linking`.

Copy the accepted scratch draft to `design\design-final-<slug>.md` (e.g.
`design\design-final-lp-statement-linking.md`). Never write a bare `design-final.md`.

This is the only point in the run where a design document is written. `design-final-<slug>.md` is
the only retained review artifact. Do not append round summaries, dialogue logs, or review
provenance.

## 2) Reconcile terminology

Locate `CONTEXT.md` using this precedence:
1. `D:\Claude\_Claude-Workspace\<workstation>\<project>\CONTEXT.md` (project root)
2. For Mode A arbitrary plan path: adjacent `CONTEXT.md` only if it matches project/workstation context
3. If unresolved: stop and ask Danny

For each glossary term:
- Drifted meaning -> update entry
- New load-bearing term -> add entry
- Stable term -> keep

Meaning-change conflicts require Danny A/B/C decision:
- A Keep existing
- B Replace with new definition
- C Split into two terms

## 3) Clean scratch state (explicit scripted step)

After `design-final-<slug>.md` is written successfully, run the cleanup command (via the Bash tool,
substituting the project's absolute `design` folder):

```
pwsh -NoProfile -Command "Remove-Item -LiteralPath '<project>\design\_review' -Recurse -Force"
```

Then confirm completion against this checklist:

- [ ] `design\_review\` no longer exists (prompts, `review-v<N>.md`, `codex-stream-v<N>.log`,
      `draft-v<N>.md`, and `verdicts.json` are all gone with it)
- [ ] `design\design-final-<slug>.md` exists and is the only retained review artifact

If finalization fails, do NOT run the cleanup — leave scratch state intact for recovery.

## 4) Output paths

Print bare absolute paths for:
- `design-final-<slug>.md`
- `CONTEXT.md` when changed/created

## 5) Stop and handoff

Ask Danny whether to proceed to implementation now or scope a new session. Do NOT generate an HTML
companion automatically. Build it only when Danny explicitly asks (that is `dt-visualize-design`).
