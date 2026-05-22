# Finalization and Glossary Reconciliation

Finalization starts when termination criteria are met.

## 1) Final draft

Copy final accepted draft to `design/design-final.md`.

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

## 3) Write `design-summary.md`

Include:
- TL;DR
- key decisions
- top risks
- open questions
- round-by-round one-line summary
- glossary changelog (`Added`, `Changed`, `Removed`)
- promotion candidates
- `Ambiguity Closures` section per design-shape contract

## 4) Output paths

Print bare absolute paths for:
- `design-final.md`
- `design-summary.md`
- `CONTEXT.md` when changed/created

## 5) Stop and handoff

Ask Danny whether to proceed to implementation now or scope a new session.
