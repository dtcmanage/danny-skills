# Roadmap Contract Schema (`roadmap.md`)

Single canonical schema for the Phase-6 roadmap contract consumed by Phase-7 dt-build intake.

- **Producer:** dt-roadmap
- **Consumers:** dt-build
- **Canonical location:** `skills/dt-roadmap/references/roadmap-schema.md` (this file)
- **Contract kind:** hard contract (fail closed on violations)

## Version header

```yaml
producer_current_version: 1.2.0
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

Also require `## Design Coverage` and `## Coverage Builds`, with a full unsplit design in frontmatter
`coverage_design` (legacy `source_artifact` accepted) and local `coverage_build` (default `main`).
See `design-coverage.md` for the exact columns, requirement unit and split-build comparison rules.
`COVERAGE_UNMAPPED` lists every omitted/unowned item; duplicate/stale/invalid ownership and missing
sources fail closed. External API client milestones also carry `## External API Contracts` as defined
in dt-build's `references/fidelity-gates.md`; the producer preserves this table for live acceptance.

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

New roadmaps carry `dependency_analysis: 1` and `## Milestone Surfaces`, with columns
`milestone-id`, `write-surface`, `provides`, `consumes`, `design-source`. Every milestone needs one row;
empty sets use `-`, entries use semicolons. Paths are case-sensitive repo-relative globs supporting
`*`, `?` and whole-segment `**` (zero or more segments), without brackets, braces or parent traversal.
Interfaces are exact case-sensitive names (`module:`, `api:`, `schema:`, `config:`); consumption of
an interface provided by another milestone creates a directed edge. Interfaces with no local provider
refer to existing baseline/external contracts, documented in `design-source`.

The pure `dependency-analysis.ps1` helper intersects glob languages, including new files; it never
enumerates only existing paths. Overlapping writers must have a dependency path in either direction
and the later writer must declare `serial: <cause>`. Consumption paths must reach their provider.
The producer computes these edges, records `## Dependency Causes`, and removes declared edges with no
direct consumption/overlap cause, reporting `DEPENDENCY_UNJUSTIFIED` warnings. For write collisions it
prefers consumption direction, then authored direction, then stable ID order. Unrelated rows stay
independent regardless of their position. Cycles fail validation. Legacy roadmaps lacking both marker
and surfaces remain readable with `DEPENDENCY_LEGACY`; new builds regenerate them.

Named failures: `DEPENDENCY_SURFACE_MISSING`, `DEPENDENCY_SURFACE_INVALID`,
`DEPENDENCY_CONSUMPTION_UNDECLARED`, `DEPENDENCY_OVERLAP_UNDECLARED`, `DEPENDENCY_OVERLAP_NOT_SERIAL`.

New producers carry `## Throughput and hardware` verbatim from the design and append `execution` and
`test-execution` to Milestones and Chunks. Dependencies identify concurrent DAG branches; execution names
`parallel` or `serial: <cause>`; test-execution names the shard command/budget or serial cause. Preserve
these fields in milestone exports. Legacy contracts without them remain parseable; resolve their missing
decisions at build intake before dispatch. Do not treat a legacy sequential chain as evidence of exclusivity.

`<skill>/scripts/roadmap-validator.ps1` must reject with a named error when any of these occur:

- `SCHEMA_VERSION_MISMATCH`: roadmap `schema_version` major differs from schema `producer_current_version` major.
- `SCHEMA_REQUIRED_SECTION_MISSING`: required section absent.
- `SCHEMA_REQUIRED_COLUMN_MISSING`: required table column absent.
- `DEPENDENCY_CYCLE`: milestone dependency graph contains a cycle.
- `MILESTONE_INDEPENDENCE_VIOLATION`: duplicate ids, unknown dependency ids, or milestone lacks chunk coverage.
- `CHUNK_PARALLELISM_FEASIBILITY_VIOLATION`: invalid chunk routing/entitlement or chunk table cannot support parallel chunk execution.
- `VERIFICATION_NAMES_NO_RUNNABLE`: a milestone's combined verification surface (its `acceptance-checks` cell in `## Milestones` plus the `procedure` cell of every `chk-*` row whose `milestone-id` matches it in `## Verification Manifest`) names no runnable artifact. Added 1.1.0 to keep the producer in lock-step with the dt-build per-milestone acceptance gate (`<danny-skills>/skills/dt-build/scripts/verify-milestone-acceptance.ps1`).

## Runnable artifact definition (added 1.1.0)

A "runnable artifact" is anything the shared extractor `<danny-skills>/scripts/extract-named-artifacts.ps1` (byte-identical to the inline `Extract-NamedArtifacts` function inside `<danny-skills>/skills/dt-build/scripts/verify-milestone-acceptance.ps1`) returns as either an `artifacts` entry or a `commands` entry. Concretely, at least one of the following must appear in the milestone's combined verification surface:

- A backtick-quoted file path with at least one directory component and an extension in `{py, ts, js, ps1, md, yaml, yml, json, html, sql}`. Example: `` `tests/backend/test_durability_fresh_create_v11.py` ``.
- A backtick-quoted command beginning with one of `pytest`, `python`, `pwsh`, `powershell`, `node`, `npm`, `bun`. Example: `` `pytest tests/backend/test_durability_populated_v10_to_v11.py` ``.
- An inline (no-backtick) `pytest <args>` invocation. Example: `Run pytest tests/backend/test_x.py to ...`.
- An inline (no-backtick) `python <path>` invocation where `<path>` starts with `scripts/`, `backend/`, `workers/`, or `tests/` and ends in `.py`.

The shared extractor is the source-of-truth definition. dt-build's gate consumes the inline copy; dt-roadmap's validator dot-sources the shared helper. Both must remain byte-identical.

## Compatibility policy

- **Breaking change** (renamed/removed columns, table restructure, changed required semantics): bump `schema_version` major and `producer_current_version` major.
- **Non-breaking additive change** (new optional column/section, or tightening an existing required cell with an additional check): keep `schema_version` major, bump `producer_current_version` minor. `VERIFICATION_NAMES_NO_RUNNABLE` (1.1.0) is additive enforcement on cells that were already required: any roadmap whose verification surface already named a runnable artifact passes unchanged.
- dt-build reads this file directly by repo-relative path and must not keep a second copy.
