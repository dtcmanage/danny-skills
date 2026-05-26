# Finalization and Glossary Reconciliation

Finalization starts when termination criteria are met.

## 1) Final draft

Copy the accepted scratch draft to `design\design-final.md`.

`design-final.md` is the only retained review artifact. Do not append round summaries, dialogue logs,
or review provenance.

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

## 3) Clean scratch state

After `design-final.md` is written successfully:
- delete `design\_review\prompts\`
- delete `design\_review\review-v<N>.md`, `design\_review\codex-stream-v<N>.log`, and scratch `draft-v<N>.md`
- delete `design\_review\` itself if empty

If finalization fails, leave scratch state intact for recovery.

## 4) Output paths

Print bare absolute paths for:
- `design-final.md`
- `CONTEXT.md` when changed/created

## 5) Stop and handoff

Ask Danny whether to proceed to implementation now or scope a new session.
