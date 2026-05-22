# Plan Shape Contract (`plan-draft.md`)

The shape contract for the `plan-draft.md` that dt-plan produces. It is a **soft contract**: consumers degrade gracefully (via `AskUserQuestion`) rather than hard-rejecting, because the artifact is markdown consumed by LLM reasoning, not a strict API.

- **Producer:** dt-plan
- **Consumers:** dt-visualize-plan, dt-prototype, dt-review 
- **Version field:** `shape_version` in frontmatter. Current accepted value: `1`.
- **Pinned at:** this file (`dt-plan/references/plan-shape.md`) — the single canonical home for the plan-shape spec.

## Required shape (`shape_version: 1`)

Frontmatter:
- `shape_version: 1` (required)

Body (surface-shaped; section names match what the conversation produced):
- `# <Project> Plan` title line
- Metadata lines: `**Date:**`, `**Surface:**`, `**Scope:**`, `**Dimension framework:**`
- One or more substantive sections (see `surface-templates.md` for per-surface starting structures)
- `## Open Questions` — required (present even if it lists nothing currently open)
- `## Out of Scope` — required (present even if empty)

Every plan must let a reader assess it on all six review dimensions (Intent, Completeness, Coherence, Resilience, Economy, Feasibility), even though the section layout is surface-shaped rather than dimension-shaped.

## `shape_version` policy

- **Current accepted version:** `1`.
- **Deprecated versions:** none yet. A version is deprecated (not removed) when superseded; deprecated plans are accepted by consumers **with an explicit notice**, never silently.
- **Major vs minor:** a **major** bump is reserved for breaking shape changes (renamed or removed required sections, restructured frontmatter). Additive, backward-compatible changes (a new optional section) do not bump the major.

### Consumer reject behavior (the soft contract)

A consumer reading a `plan-draft.md`:
- **Missing required section at load** → surface the specific gap via `AskUserQuestion` (e.g. "Plan is missing an 'Out of Scope' section — fill in now or proceed without?"). Do not silently proceed.
- **Unknown major `shape_version`** (e.g. `99`) → do NOT guess; ask via `AskUserQuestion` whether to attempt adaptation.
- **Deprecated version** → accept with an explicit notice surfaced to Danny.

dt-plan is the producer and writes `shape_version: 1`; the consumer behavior above is exercised at runtime by the first consumer skill (dt-visualize-plan, Phase 2). Until a consumer exists, this file is the authoritative spec of that behavior.


