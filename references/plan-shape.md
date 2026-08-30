# Plan Shape Contract (`plan-draft.md`)

The shape contract for the `plan-draft.md` that dt-plan produces. It is a **soft contract**: consumers degrade gracefully (via `AskUserQuestion`) rather than hard-rejecting, because the artifact is markdown consumed by LLM reasoning, not a strict API.

- **Producer:** dt-plan
- **Consumers:** dt-visualize-plan, dt-prototype, dt-review
- **Version field:** `shape_version` in frontmatter. Current accepted value: `1`.
- **Pinned at:** this file (repo-level `references/plan-shape.md`) — the single canonical home for the
  plan-shape spec. There is no per-skill copy; a duplicate under `skills/<name>/references/` is a fork and
  was removed on 2026-08-30.
- **Producer-side gate:** `skills/dt-plan/scripts/verify-plan-shape.ps1` checks a plan against this contract
  at save time, so a gap surfaces at the producer rather than at consumer intake.

## Required shape (`shape_version: 1`)

Frontmatter:
- `shape_version: 1` (required)

Body (surface-shaped; section names match what the conversation produced):
- `# <Project> Plan` title line
- Metadata lines: `**Date:**`, `**Surface:**`, `**Scope:**`, `**Dimension framework:**`
- One or more substantive sections (see `surface-templates.md` for per-surface starting structures)
- `## Build-intake revalidation` — required (added 2026-08-30; present even when the plan rests on no
  external claims, in which case it carries one row saying so)
- `## Open Questions` — required (present even if it lists nothing currently open)
- `## Out of Scope` — required (present even if empty)

### `## Build-intake revalidation`

The header text must match exactly. `dt-review` copies a Mode A plan verbatim to `draft-v1.md`, and
`skills/dt-review/scripts/assemble-review-prompt.ps1` throws `BUILD_INTAKE_GATE` at Round 1 when an
evidence map exists and the draft has no section headed exactly `## Build-intake revalidation`. Because the
reviewed draft is hash-bound by finalization, the omission cannot be repaired in flow — so the producer
carries the table, not the reviewer.

```markdown
## Build-intake revalidation
| Claim | Evidence/source | Checked at | Recheck gate |
| --- | --- | --- | --- |
```

One row per assumption about existing code, data, schema, or an external system. Evidence is a file/symbol
reference or an executed query; a claim not directly checked is recorded `UNVERIFIED` rather than omitted.
`dt-build` rechecks these rows at build intake.

This requirement was added within `shape_version: 1` rather than bumping the version: it is additive (no
required section renamed or removed), and `skills/dt-review/scripts/finalize-review.ps1` hard-codes
`shape_version: 1`, so a bump would break finalization in a skill that had just shipped. Plans written
before the addition are handled by the soft contract below — surfaced via `AskUserQuestion`, never silently
adapted.

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


