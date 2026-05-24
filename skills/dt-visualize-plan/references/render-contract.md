# dt-visualize-plan Render Contract

Phase 2 render contract for `dt-visualize-plan`.

## Inputs

- Required: plan markdown path.
- Required: mode (`milestone-table-only`, `plan-plus-mermaid`, `ui-mockup`).
- Optional: explicit output path.
- Optional for UI mode: mockup provider + mockup artifact path.

## Output

- File: `plan-view.html` (default: next to plan file).
- Must open directly in browser without dev server.
- Must include:
  - Summary cards (surface, scope, mode, renderer)
  - Milestone table
  - Open questions block
  - Plan preview (redacted)
  - Dependency provenance footer

## Security/Dependency invariants

- Redaction: use repo-level `scripts/security/redact-secrets.ps1` before HTML escaping.
- Mermaid:
  - Prefer MCP when available.
  - Fallback to vendored `assets/visualize/vendored/mermaid-10.9.3.min.js`.
  - No remote mermaid URL in output.
  - Initialize with `securityLevel: 'strict'`.
  - Browser verification must find `.mermaid svg`; raw Mermaid text is a failure.
- Fallback behavior must be explicit in provenance footer, including debt tags where applicable.
