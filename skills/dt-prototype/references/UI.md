# UI Prototype

Use this branch when the question is visual: layout, hierarchy, affordances, or interaction framing.

## Success target

- Several radically different variants exist on one switchable route.
- Danny can flip variants instantly (URL param + arrows) and compare in context.
- `NOTES.md` captures the winning direction and what to fold into real code.

## Preferred shape

Default to embedding variants in an existing page/route. This keeps real context (density, nav, surrounding
components) and produces better decisions than a blank standalone page.

Use a brand-new throwaway route only when no existing route can host the prototype.

## Steps

1. State the question + variant count
- Default to 3 variants (cap at 5).
- Record in `NOTES.md`: route, variant keys, and what decision is being tested.

2. Draft structurally different variants
- Each variant should differ in layout and information hierarchy, not just style tokens.
- Keep them aligned to the host component system.

3. Add a switcher on one route
- Use `?variant=` URL param.
- Render one variant at a time.
- Add a floating bottom switcher from `assets/variant-switcher.tsx.template`.

4. Interaction requirements
- Left/right buttons cycle variants (wrap around).
- Keyboard arrows also cycle, but do not hijack input/textarea/contenteditable focus.
- Variant choice must persist in URL for shareable links.

5. Safety requirements
- Prototype switcher stays dev-only (hidden in production).
- Prototype writes should avoid production mutations unless specifically required.

6. Capture answer and cleanup intent
- `NOTES.md` must record:
  - winning variant (or mix),
  - why it won,
  - cleanup plan for losing variants + switcher.

## Anti-patterns

- Variants that are minor visual tweaks of the same structure.
- Shared layout abstraction that forces variants to converge.
- Forgetting to remove prototype switcher/variant shells after decision.

