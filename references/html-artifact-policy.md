# HTML Review Artifact Policy

Use this policy for any skill output intended for Danny to review.

This policy follows the HTML-first approach in Anthropic's "The unreasonable effectiveness of HTML":

- Prefer reviewable `.html` artifacts over long linear markdown.
- Increase information density with tables, cards, timelines, and diagrams.
- Improve scanability with visual hierarchy, spacing, and responsive layout.
- Use interaction when it improves comprehension (tabs, collapsibles, copy buttons, toggles).
- Keep raw source artifacts (`.md`, `.json`, etc.) for machine/edit workflows, but always pair them with an HTML review surface.

## Required Output Contract

1. For every review artifact, emit an HTML companion file in the same artifact family/folder.
2. The HTML must be a single self-contained file (no external build step).
3. The HTML must include, at minimum:
   - a top summary strip (status, key metrics, timestamp, source files),
   - a structure map (table of contents and/or workflow diagram),
   - at least one visual representation of flow/state (Mermaid or SVG),
   - a risk/open-questions section with clear severity/priority cues.
4. If the artifact is decision-oriented, include side-by-side alternatives/tradeoffs.
5. If the artifact is process-oriented, include a timeline/sequence view.
6. If the artifact is code-oriented, include annotated snippets/diff summaries.
7. Include a copyable "refresh command" when regeneration is scriptable.

## Presentation Style

- Optimize for quick executive skim first, deep dive second.
- Avoid wall-of-text sections longer than one screen without visual breakpoints.
- Use semantic color intentionally for status/risk, not decoration.
- Default to mobile-friendly responsive behavior.

## Allowed Visualization Mechanisms

- Mermaid (flowchart, sequence, gantt).
- Inline SVG diagrams.
- HTML/CSS cards, grids, tables, timelines.
- Lightweight JavaScript for tabs, filtering, and copy/export controls.

## Delivery Rule

When a skill produces an artifact for review, "done" means:

- primary artifact generated,
- HTML review artifact generated,
- both paths reported.
