---
name: dt-image-gen
description: "Generate raster/bitmap images and visual assets via Codex's built-in gpt-image-2 engine (runs on Danny's ChatGPT subscription - no API key, no per-image billing). Use WHENEVER a generated picture is the right output: photos, illustrations, icons, logos, mockups (UI/product), marketing graphics, banners, infographics, textures, sprites, concept art - whether Danny asks explicitly ('/dt-image-gen', 'generate/make an image/graphic/logo/mockup/banner/illustration') OR Claude itself decides a raster image best answers the request. Code-native output WINS BY DEFAULT: genuine data charts/diagrams (Mermaid/SVG), existing vector/logo systems, and simple shapes stay code-native unless the user explicitly asks for a raster or art-directed image."
disable-model-invocation: false
user-invocable: true
allowed-tools: "Bash Read Write Edit"
compatibility: "Windows with Codex CLI authenticated to a ChatGPT Plus/Pro/Business/Enterprise subscription (built-in image_gen tool); driven through the Bash tool. Node required for helpers/gallery. Requires the danny-skills repo present."
metadata:
  version: 0.1.2
  changelog: "Release history: CHANGELOG.md (newest first)."
---

# Image Generation

## Shared Policy Baseline

Apply the shared deterministic and referencing baseline at `../../references/deterministic-reference-policy.md`.

Path resolution is governed by `../../references/conventions.md` (resolve from this `SKILL.md` location, never from `pwd`).

If this skill has stricter domain-specific behavior, keep that stricter behavior; otherwise follow the shared baseline.

Generate bitmap images and visual assets on demand. This skill is a thin, reliable wrapper around
**Codex's built-in `image_gen` tool** (the `gpt-image-2` engine). It runs on Danny's ChatGPT
subscription - no `OPENAI_API_KEY`, no per-image billing. It does not reimplement generation; it adds
what the bare engine lacks: a race-safe collection contract, a grid-variation workflow with deterministic
cell crop, optional brand styling, and a review gallery.

Throughout, `<skill-dir>` is the folder containing this `SKILL.md`. Run every script through the Bash tool.

## When this fires

Fire whenever the right output is a generated picture, including when Claude decides that on its own:
- `/dt-image-gen`, or "generate/make an image, graphic, logo, icon, mockup, banner, illustration, poster, infographic, texture, sprite, concept art"
- "make a marketing image / hero image / social post / product shot / UI mockup"
- any moment in other work where a raster visual is the natural deliverable

Do NOT fire (code-native wins by default) for:
- genuine data charts or diagrams that should be **Mermaid / SVG / code** (honor the global "use a Mermaid diagram or chart for dense information" preference)
- extending or matching an existing **SVG/vector** icon set, logo system, or illustration library
- simple shapes, wireframes, or boxes-and-arrows better drawn in HTML/CSS/canvas
- a small edit to an existing source asset that already has an editable native format

## Dependencies

Required (the wrapper fails clear if a needed one is missing): Codex CLI (authenticated), Bash, Node
(helpers + gallery), PowerShell. A PDF converter (`pdftoppm` / ImageMagick / Ghostscript) is required
**only** when a PDF reference is actually supplied.

## Core discipline: never hand Codex a save path

Codex resolves a caller-supplied save path through .NET/PowerShell, so a bash path like `/tmp/x.png`
lands at `C:\tmp\x.png`. `gen-image.sh` never hands Codex a target path - it lets Codex write to its
default `generated_images` dir and collects the result. Never tell Codex to "save to <path>".

## Where images are saved

Resolve the project's assets folder deterministically:

```bash
node "<skill-dir>/scripts/resolve-assets-dir.mjs" --root "<project root>" --create
```

It returns the first existing conventional folder (`assets/`, `src/assets/`, `public/`...) or creates
`assets/generated/`. If Danny names a destination, use it. If there is no project context, ask or use a
named scratch folder. The wrapper never overwrites: a collision becomes `name-v2.png`, etc.

## Procedure - single image

1. **Craft the prompt.** For anything non-trivial, read Codex's prompting guidance first - resolve the
   path from the user profile, never hardcode it: `$env:USERPROFILE\.codex\skills\.system\imagegen\references\prompting.md`
   (in bash contexts: `~/.codex/skills/.system/imagegen/references/prompting.md`) and `...\references\sample-prompts.md`
   in the same folder. If that path is absent (Codex updated or moved it), locate it with
   `Get-ChildItem $env:USERPROFILE\.codex\skills -Recurse -Filter 'imagegen*' -Directory` before falling back
   to prompting without the guidance.
   Structure: scene/backdrop -> subject -> key details -> constraints -> intended use. Put literal
   in-image text in quotes; specify typography, color, placement.
2. **Generate** (the wrapper wraps the prompt in a data envelope and enforces the collection contract):

   ```bash
   bash "<skill-dir>/scripts/gen-image.sh" --prompt "<full prompt>" --dest "<assets dir>" --name "<slug>"
   ```

   stdout is the saved Windows path; progress + the expected call-count estimate go to stderr.
3. **Review.** Open the saved file with the Read tool. Judge subject, composition, text accuracy, constraints.
4. **Iterate** with one targeted change at a time, restating critical constraints, until it lands.
5. **Report** the saved path in backticks.

## Mode - grid variation (cheap exploration, then refine the winner)

One generation containing a numbered grid gives many options for the price of one image; the chosen cell
is then cropped deterministically and refined at full resolution.

1. Build the grid prompt:
   ```bash
   node "<skill-dir>/scripts/make-grid-prompt.mjs" --concept "<concept>"
   ```
2. Generate once with that prompt (`--name <concept>-grid`). View the grid; let Danny pick a cell number.
3. Crop the chosen cell deterministically (known geometry):
   ```bash
   node "<skill-dir>/scripts/crop-grid-cell.mjs" --grid "<grid.png>" --cell <N> --rows 5 --cols 5 --out "<concept>-cell-<N>.png"
   ```
4. **Refine** (composition-preserving, NOT a pixel upscale): pass the crop as a reference with a clean
   full-resolution prompt:
   ```bash
   bash "<skill-dir>/scripts/gen-image.sh" --prompt "<refined prompt>" --ref "<concept>-cell-<N>.png" --dest "<assets dir>" --name "<concept>-final"
   ```

## Mode - batch variants

For genuinely separate variants (not a grid), pass `--count N`. Each is a separate Codex turn
(~57k tokens), so prefer grid mode for wide exploration. The wrapper prints the expected call count first.

```bash
bash "<skill-dir>/scripts/gen-image.sh" --prompt "<prompt>" --dest "<dir>" --name "<slug>" --count 3
```

## Reference images

Pass one or more with repeated `--ref <file>` (style, composition, mood, subject). Label each by role in
the prompt ("style reference", "subject to place", "edit target"). Codex does not accept PDFs - convert first:

```bash
bash "<skill-dir>/scripts/convert-ref.sh" "<brand-book.pdf>" "<out.png>"
```

It passes raster files through unchanged and fails clear (naming what to install) if no converter exists.

## Brand styling - opt in only

Default output is **not** TCM-branded. Apply TCM styling only when Danny asks ("on-brand", "TCM brand",
"our colors", "for the firm"). When he does:
- Pull the current palette hex + typography from the canonical design system (values live in code -
  read the design-system guideline/tokens; never hand-copy from memory).
- Build the preamble with the resolved values and append it to the prompt:
  ```bash
  node "<skill-dir>/scripts/brand-preamble.mjs" --primary "<navy hex>" --accent "<gold hex>" --font "<typeface>"
  ```
- A generated UI mockup is a reference, not a shippable component; real UI stays design-system conformant.

## Wrapper collection contract (how gen-image.sh stays reliable)

- Collection = before/after **UUID-directory set difference** under `generated_images`, not mtime.
- Per-run **lock** (`generated_images/.dt-image-gen.lock`, contents run-id|PID|start) serializes runs;
  a stale lock with no live owner is reclaimed; a live owner refuses with "run in progress". `--force-unlock`
  acts only after confirming no live owner.
- **Fail closed:** exactly one new PNG per generation; 0 or unexpected >1 is a typed error (with the
  Codex stream-log path). `--allow-extra` takes the newest and logs the rest without moving them.
- All `--ref`/`--dest` inputs are normalized to absolute paths at the boundary.

## Gallery review

When there is more than one image to compare, build a contact sheet and report its path:

```bash
node "<skill-dir>/scripts/make-gallery.mjs" --dir "<assets dir>" --title "<short title>"
```

It writes `gallery.html` into that folder (thumbnail rail navigates; fixed preview pane). It must live
beside the images. For a single image, skip the gallery - just view and report the path.

## Reporting

- Backtick every Windows path (especially any with spaces).
- Report each saved image path and the gallery path when built.
- Note that generation used Codex's built-in engine on the subscription (no API key, no extra billing).

## Guardrails

- Never instruct Codex to save to a specific path; the wrapper collects and moves.
- Never hand-copy design tokens from memory; read current values from the design system when branding.
- Do not use this skill for code-native charts/diagrams (Mermaid/SVG) or existing vector/logo systems.
- Default off-brand; style for TCM only on request.
- Do not overwrite an existing asset; the wrapper versions filenames.
- Save into the resolved project assets folder unless Danny names a destination.
- Grid refinement is composition-preserving, not a deterministic upscale - say so when reporting.
