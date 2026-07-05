# Shared-Input Routing

Canonical homes for reusable inputs:
- roadmap contract: `roadmap.md` (producer: dt-roadmap)
- roadmap schema: `skills/dt-roadmap/references/roadmap-schema.md`
- schema validator: `skills/dt-roadmap/scripts/roadmap-validator.ps1`
- contracts pack: run-local reference-pack file
- glossary pack: run-local reference-pack file

Phase 7A rules:
- dt-build does not duplicate roadmap schema content.
- File-level entitlements are resolved through `reference-manifest.md`.
- Missing/mismatched entitlement is a hard failure before spawn.

Input routing (roadmap preferred, not required):
- dt-build accepts either a `roadmap.md` or a finalized design (`design-final-*.md` — dt-review's
  current `design-final-<slug>.md` naming — / legacy `design-final.md` / `plan-draft.md`).
- Roadmap detection: frontmatter `schema_version` + a `## Milestones` section → use directly.
- Otherwise treat the input as a design and generate the roadmap via the canonical producer
  `skills/dt-roadmap/scripts/build-roadmap.ps1` (dt-build never re-implements milestone parsing).
- A design with no `## Implementation Sequence` / `## Validation Gates` runnable surface yields the
  producer's graceful "No milestones derivable" stop — an explanatory halt, never a crash.
- A standalone `dt-roadmap` pass remains preferred for heavy builds (many milestones, load-bearing/gate
  milestones, or anything needing a separately-reviewed contract).
