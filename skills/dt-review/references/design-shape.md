# Design Shape Contract (`design-final-<slug>.md`)

Filename contract: `design-final-<slug>.md`, where `<slug>` is 2-4 kebab-case words derived from the
plan/project name (e.g. `design-final-lp-statement-linking.md`). A bare `design-final.md` is legacy —
consumers still accept it as input, but the producer must never emit it.

- **Producer:** dt-review
- **Consumers:** dt-visualize-design, dt-roadmap
- **Version field:** frontmatter `shape_version`
- **Current accepted version:** `1`

## Required frontmatter

The file must start with:

```yaml
---
shape_version: 1
---
```

## `design-final-<slug>.md` required content

- Title line
- Metadata lines already present in the accepted draft (for example date, scope, framework state)
- Final accepted design body
- `## Build-intake revalidation` when Round 0 created `review-context.md`; each row carries claim, evidence/source, checked-at time, and recheck gate
- `## Accepted residual risks` only when Danny explicitly approves finalization at the cap; each unresolved finding is a `### <finding-id>` entry with non-empty Rationale, Owner, and Recheck gate fields

## Retention rule

`design-final-<slug>.md` is the only retained review artifact, written once at convergence — never
per round.

`FINALIZE_CURRENT` copies only receipt-verified `draft-vN.md`. An unreviewed `draft-vN+1.md` is
eligible only when `prepare-final-draft.ps1` deterministically derived it from that reviewed source:
exact, non-overlapping replacements for all current `ACCEPT`/`COUNTER` polish findings, or the exact
residual-risk section append for every current blocking/deferred finding. `finalize-review.ps1` must
validate and replay the state/source/final hash-bound manifest before retaining it.

Do not copy any of the following into the final file:
- per-round review text
- verdict history
- stream-log paths
- prompt provenance
- dialogue logs
- glossary changelog sections
- ambiguity-closure bookkeeping that belongs to the review process rather than the final design
- `VERDICT:` lines, round headings, prompt/review/log paths, or orchestrator responses

If an `AMBIGUOUS_ROOT_CAUSE` finding remains unresolved, do not finalize yet. Resolve it in the
active review loop or stop and ask Danny.

## Compatibility behavior

- Unknown major `shape_version` -> ask Danny whether to attempt adaptation.
- Deprecated version -> accept with explicit notice.
- Missing frontmatter or missing final accepted design body -> surface the exact gap and pause.
