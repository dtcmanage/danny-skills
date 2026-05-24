# Design Shape Contract (`design-final.md`)

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

## `design-final.md` required content

- Title line
- Metadata lines already present in the accepted draft (for example date, scope, framework state)
- Final accepted design body

## Retention rule

`design-final.md` is the only retained review artifact.

Do not copy any of the following into the final file:
- per-round review text
- verdict history
- stream-log paths
- prompt provenance
- dialogue logs
- glossary changelog sections
- ambiguity-closure bookkeeping that belongs to the review process rather than the final design

If an `AMBIGUOUS_ROOT_CAUSE` finding remains unresolved, do not finalize yet. Resolve it in the
active review loop or stop and ask Danny.

## Compatibility behavior

- Unknown major `shape_version` -> ask Danny whether to attempt adaptation.
- Deprecated version -> accept with explicit notice.
- Missing frontmatter or missing final accepted design body -> surface the exact gap and pause.
