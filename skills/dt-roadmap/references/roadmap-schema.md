# Roadmap Contract Schema (`roadmap.md`)

Single canonical schema for the Phase-6 roadmap contract consumed by Phase-7 dt-build intake.

- **Producer:** dt-roadmap
- **Consumers:** dt-build
- **Canonical location:** `skills/dt-roadmap/references/roadmap-schema.md` (this file)
- **Contract kind:** hard contract (fail closed on violations)

## Version header

```yaml
producer_current_version: 1.0.0
schema_version: 1
```

- `producer_current_version` is semver for the roadmap producer.
- `schema_version` is the roadmap document major contract in frontmatter.
- **Major-match rule:** `roadmap.md` frontmatter `schema_version` major must equal
  `producer_current_version` major.

## Required `roadmap.md` shape

Frontmatter (required):

```yaml
---
schema_version: 1
source_artifact: <absolute-or-project path to design source>
generated_at_utc: <ISO-8601 timestamp>
---
```

Body sections (required):

1. `## Milestones`
- Markdown table required columns (exact names):
  - `id`
  - `name`
  - `dependencies`
  - `chunks`
  - `verification-mode`
  - `baseline-floor`
  - `acceptance-checks`
  - `decision-basis`

2. `## Chunks`
- Markdown table required columns (exact names):
  - `chunk-slug`
  - `milestone-id`
  - `model-routing`
  - `reference-pack-entitlement`

3. `## Verification Manifest`
- Markdown table required columns (exact names):
  - `check-id`
  - `milestone-id`
  - `execution-scope`
  - `prerequisites`
  - `mode`
  - `procedure`

4. `## Dependency Graph (Mermaid)`
- Contains one mermaid `graph TD` block.

5. `## Sequential Gantt (Mermaid)`
- Contains one mermaid `gantt` block.

## Validation expectations

`skills/dt-roadmap/scripts/roadmap-validator.ps1` must reject with a named error when any of these occur:

- `SCHEMA_VERSION_MISMATCH`: roadmap `schema_version` major differs from schema `producer_current_version` major.
- `SCHEMA_REQUIRED_SECTION_MISSING`: required section absent.
- `SCHEMA_REQUIRED_COLUMN_MISSING`: required table column absent.
- `DEPENDENCY_CYCLE`: milestone dependency graph contains a cycle.
- `MILESTONE_INDEPENDENCE_VIOLATION`: duplicate ids, unknown dependency ids, or milestone lacks chunk coverage.
- `CHUNK_PARALLELISM_FEASIBILITY_VIOLATION`: invalid chunk routing/entitlement or chunk table cannot support parallel chunk execution.

## Compatibility policy

- **Breaking change** (renamed/removed columns, table restructure, changed required semantics): bump `schema_version` major and `producer_current_version` major.
- **Non-breaking additive change** (new optional column/section): keep `schema_version` major, bump `producer_current_version` minor.
- dt-build reads this file directly by repo-relative path and must not keep a second copy.
