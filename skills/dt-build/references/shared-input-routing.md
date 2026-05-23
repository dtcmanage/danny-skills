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
