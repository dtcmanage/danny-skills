# dt-roadmap Changelog

## 1.2.1

- Declared shared artifact-extraction ownership for the version-policy release gate.

Newest first. Relocated verbatim from the `metadata.changelog` frontmatter field in `SKILL.md`
(which now carries a one-line pointer here). New releases add a `## <version>` section at the top.

## 1.2.0

- design-final-slug intake + on-request HTML: intake now accepts `design-final-<slug>.md` (the new dt-review output naming, e.g. `design-final-lp-statement-linking.md`) alongside legacy `design-final.md` and `plan-draft.md`; scripts were already filename-agnostic (`-DesignPath` parameter, no literal matches in build-roadmap.ps1 / roadmap-validator.ps1). `roadmap-view.html` is now on-request only: `scripts/build-roadmap.ps1` gained an `-EmitRoadmapView` switch (default off; an explicit `-RoadmapViewPath` also counts as the request) and reports `roadmap_view_path: null` when skipped. When the view IS built, verification runs through the shared deterministic checker `scripts/visualize/verify-html-artifact.ps1 -RequireMermaid` (browser-smoke harness asserts a rendered `.mermaid svg` and no console errors) instead of the prose "validate in a browser" instruction. Frontmatter changelog relocated to this file.

## 1.1.1

- Bold-aware milestone naming: Get-FirstSentence in scripts/build-roadmap.ps1 now prefers a leading bold span (`**Title.**`) as the milestone name before the first-sentence fallback. The first-sentence regex `^(.+?[.!?])(\s|$)` only breaks on a terminator followed by whitespace, so an item that led with a bold title (period inside the `**`, no trailing space) skipped the title and captured the whole paragraph as the name — producing unreadable blob names in the milestone table, dependency graph, and Gantt (surfaced on the 2026-06-03 file-sorter learning-loop-date-extraction roadmap, which had to reword all 10 sequence items to plain sentences as a workaround). Fix: non-greedy `^\*\*(.+?)\*\*` capture, trimmed of trailing `.!?:`, returned when 1..80 chars, else falls through unchanged. Plain-sentence items are byte-for-byte unchanged. Input-contract doc updated to document the bold-title-as-name behavior. No schema_version or producer_current_version change (producer-internal name refinement).

## 1.1.0

- Prior: hardened producer + validator for dt-build per-milestone acceptance gate compatibility. (1) Added VERIFICATION_NAMES_NO_RUNNABLE schema check: each milestone's combined verification surface (acceptance-checks + every matching chk-* procedure cell) must name at least one runnable artifact — a backticked file path with an extension in the allowlist, a backticked or inline `pytest ...` / `python scripts|backend|workers|tests/...` command, or one of `pwsh|powershell|node|npm|bun`. Validator and gate share the same definition through repo-level `scripts/extract-named-artifacts.ps1` (byte-identical to the inline copy in `skills/dt-build/scripts/verify-milestone-acceptance.ps1`). (2) Broadened the input parser: primary path now reads milestones from a `## Implementation Sequence` (or `Implementation Order` / `Build Sequence` / `Build Order` / `Milestone Sequence`) section's enumerated top-level numbered list; legacy `### Phase ...` heading detection remains as a back-compat fallback. (3) Lifted concrete pytest/python commands verbatim from milestone-tagged bullets in the design's `## Validation Gates` section (tag convention: `- M<NN>: ... \`cmd\``) into procedure cells, replacing the prior stub prose. Producer surfaces any milestone without a lifted command in the new `## Producer Warnings` section so the validator's hard-fail is predictable. Bumped producer_current_version 1.0.0 -> 1.1.0 (additive enforcement, no schema_version major bump).

## 1.0.1

- Previous 1.0.1: scripted roadmap-view.html generation with vendored Mermaid rendering.
