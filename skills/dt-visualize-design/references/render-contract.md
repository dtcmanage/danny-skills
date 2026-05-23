# dt-visualize-design render contract

- Inputs: `plan-draft.md`, `design-final.md`.
- Output: `design-view.html` next to `design-final.md` by default.
- Uses shared renderer `scripts/visualize/html-builder.ps1` in mode `design-diff`.
- Uses shared section diff engine `scripts/visualize/markdown-section-diff.ps1`.
- Requires dependency-provenance footer parity with Phase 2 fallback behavior.
