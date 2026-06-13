---
name: dt-image-gen
description: "Generate raster/bitmap images and visual assets via Codex's built-in gpt-image-2 engine (runs on Danny's ChatGPT subscription - no API key, no per-image billing). Use WHENEVER an image or visual representation is the right output: photos, illustrations, icons, logos, mockups (UI/product), marketing graphics, banners, infographics, textures, sprites, concept art, or any pixel image - whether Danny asks explicitly ('/dt-image-gen', 'generate/make an image/graphic/logo/mockup/banner/illustration') OR Claude itself decides a generated picture best answers the request. Do NOT use for genuine data charts/diagrams better authored as Mermaid/SVG/code, for extending an existing SVG/vector icon or logo system, or for simple shapes/wireframes better drawn directly in HTML/CSS/canvas."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash Read Write Edit"
compatibility: "Windows with Codex CLI authenticated to a ChatGPT Plus/Pro/Business/Enterprise subscription (built-in image_gen tool); driven through the Bash tool. Requires the danny-skills repo present."
metadata:
  version: 0.1.0
  changelog: "Initial release. Thin orchestration layer over Codex's built-in image_gen engine: gen-image.sh drives Codex headless and collects/moves the output (never hands Codex a save path - it mis-resolves bash paths), make-gallery.mjs renders a master-detail contact sheet. Modes: single, batch, 5x5 grid-variation. Brand styling is opt-in."
---

# Image Generation

Generate bitmap images and visual assets on demand. This skill is a thin, reliable wrapper around
**Codex's built-in `image_gen` tool** (the `gpt-image-2` engine). It runs on Danny's ChatGPT
subscription - no `OPENAI_API_KEY`, no per-image billing. It does not reimplement generation; it adds
the parts the bare engine lacks: reliable file handling, a grid-variation workflow, optional TCM brand
styling, and a review gallery.

## When this fires

Fire whenever the right output is a generated picture, including when Claude decides that on its own:
- `/dt-image-gen`, or "generate/make an image, graphic, logo, icon, mockup, banner, illustration, poster, infographic, texture, sprite, concept art"
- "make a marketing image / hero image / social post / product shot / UI mockup"
- any moment in other work where a raster visual is the natural deliverable

Do NOT fire for:
- genuine data charts or diagrams that should be authored as **Mermaid / SVG / code** (honor the global "use a Mermaid diagram or chart for dense information" preference)
- extending or matching an existing **SVG/vector** icon set, logo system, or illustration library in a repo - edit those natively
- simple shapes, wireframes, or boxes-and-arrows better drawn directly in HTML/CSS/canvas
- a small edit to an existing source asset that already has an editable native format

## Core discipline: never hand Codex a save path

Codex resolves a caller-supplied save path through .NET/PowerShell, so a bash path like
`/tmp/x.png` lands at `C:\tmp\x.png` - the wrong place. **Always** let Codex write to its default
`generated_images` dir and let `gen-image.sh` collect the newest file and move it. The wrapper does
this for you; never instruct Codex to "save to <path>".

## Where images are saved

Default to the current project's assets folder (`assets/`, `public/`, `src/assets/`, or similar). If
none is obvious, create `assets/generated/` at the project root. If Danny names a destination, use it.
If there is no project context, ask for a destination or use a named scratch folder. The wrapper never
overwrites: a name collision becomes `name-v2.png`, `name-v3.png`, etc.

## Procedure - single image

1. **Craft the prompt.** For anything non-trivial, read Codex's prompting guidance first:
   `C:\Users\Danny\.codex\skills\.system\imagegen\references\prompting.md` and
   `C:\Users\Danny\.codex\skills\.system\imagegen\references\sample-prompts.md`.
   Structure the prompt: scene/backdrop -> subject -> key details -> constraints -> intended use.
   Put any literal in-image text in quotes and specify typography, color, and placement. State the
   intended use (ad, UI mock, infographic) so the polish level is right.
2. **Generate.** Run the wrapper through the Bash tool (resolve `<skill-dir>` to this SKILL.md's folder):

   ```bash
   bash "<skill-dir>/scripts/gen-image.sh" \
     --prompt "<full prompt>" \
     --dest "<project assets dir>" \
     --name "<slug>"
   ```

   stdout is the saved Windows path; progress goes to stderr.
3. **Review.** Open the saved file with the Read tool to view it. Judge subject, composition, text
   accuracy, and any stated constraints.
4. **Iterate** with one targeted change at a time, re-stating critical constraints, until it lands.
5. **Report** the saved path in backticks.

## Mode - grid variation (cheap exploration)

The most efficient way to explore many options: one generation that contains a numbered grid, so 25
options cost one image instead of 25.

1. Build a single prompt for a **5x5 grid (25 cells)** of distinct variations on the concept, each cell
   numbered 1-25 in a small white circle at the top-left, even spacing, consistent framing.
2. Generate once with `--name <concept>-grid` (count 1).
3. View the grid, present it, and let Danny pick a cell number.
4. **Regenerate the winner** as a full single image at native resolution, reusing that cell's concept
   in a clean single-image prompt with `--name <concept>-final`.

## Mode - batch variants

For genuinely separate variants (not a grid), pass `--count N`. Each is a separate Codex turn
(~57k tokens each), so prefer the grid mode for wide exploration and reserve `--count` for a small
number of final-quality alternates.

```bash
bash "<skill-dir>/scripts/gen-image.sh" --prompt "<prompt>" --dest "<dir>" --name "<slug>" --count 3
```

## Reference images

Pass one or more reference images with repeated `--ref <file>` (style, composition, mood, or subject
guidance). In the prompt, label each by role ("style reference", "subject to place", "edit target").
Codex does not accept PDFs - if a reference is a PDF, convert a page to JPEG/PNG first (ImageMagick or
Ghostscript if present; otherwise ask Danny for an image-format export).

## Brand styling - opt in only

Default output is **not** TCM-branded. Apply TCM styling only when Danny asks for it ("on-brand",
"TCM brand", "our colors", "for the firm"). When he does:
- Pull the current palette hex values and typography from the canonical design system (per the global
  rule, token values live in code - read the design-system guideline/tokens; never hand-copy values
  from memory).
- Append a style preamble to the prompt, e.g. deep navy primary, gold accent, Myriad Pro typography,
  tight corner radius, clean institutional finish - using the actual current values.
- Keep genuine UI work conformant to the design system; a generated mockup is a reference, not a
  shippable component.

## Gallery review

When there is more than one image to compare (a batch, a set of finals, or several grids), build a
contact sheet and report its path:

```bash
node "<skill-dir>/scripts/make-gallery.mjs" --dir "<assets dir>" --title "<short title>"
```

It writes `gallery.html` into that folder (master-detail: the thumbnail rail navigates, the large
preview pane stays fixed). It must live beside the images. For a single image, skip the gallery - just
view and report the path.

## Reporting

- Backtick every Windows path (especially any with spaces) so it stays clickable.
- Report each saved image path and the gallery path when one was built.
- Note that generation used Codex's built-in engine on the subscription (no API key, no extra billing).

## Guardrails

- Never instruct Codex to save to a specific path; the wrapper collects and moves the file.
- Never hand-copy design tokens from memory; read current values from the design system when branding.
- Do not use this skill for code-native charts/diagrams (Mermaid/SVG) or existing vector/logo systems.
- Default off-brand; style for TCM only on request.
- Do not overwrite an existing asset; the wrapper versions filenames automatically.
- Save into the current project's assets folder unless Danny names a destination.
