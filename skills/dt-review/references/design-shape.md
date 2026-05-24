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

## `design-final.md` required sections

- Title line
- Metadata lines including date/framework status
- Final accepted design body
- `## Dialogue Log` with per-round entries

## `design-final.md` required sections

- Title line
- Metadata lines including date/framework status
- Final accepted design body
- `## Dialogue Log` with per-round entries
- TL;DR
- Key architectural decisions
- Top risks
- Open questions
- Round-by-round summary
- Glossary changes (`Added`, `Changed`, `Removed`)
- Promotion candidates
- `## Ambiguity Closures`

## Ambiguity closure block schema

For every finding flagged `AMBIGUOUS_ROOT_CAUSE`, include:
- `finding_id`
- `candidate_dimensions` (exactly two)
- `missing_evidence`
- `temporary_primary`
- `closure_status` (`closed` or `carry_forward`)
- `owner` (default `Danny`)
- `closure_date_or_next_review`

If no ambiguous findings exist, still include `## Ambiguity Closures` with `- None this run.`

## Compatibility behavior

- Unknown major `shape_version` -> ask Danny whether to attempt adaptation.
- Deprecated version -> accept with explicit notice.
- Missing required section -> surface the exact gap and pause.
