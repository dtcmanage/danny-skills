# dt-visualize-design render contract

- Inputs: `plan-draft.md`, finalized design (`design-final-<slug>.md`; legacy `design-final.md` accepted).
- Output: `design-view.html` next to the design file by default.
- Post-render verification: shared checker `scripts/visualize/verify-html-artifact.ps1 -RequireMermaid`.
- Uses shared renderer `scripts/visualize/html-builder.ps1` in mode `design-diff`.
- Uses shared section diff engine `scripts/visualize/markdown-section-diff.ps1`.
- Requires dependency-provenance footer parity with Phase 2 fallback behavior.
