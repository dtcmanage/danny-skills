# dt-image-gen — plan-draft

**Status:** draft for review (2026-06-13). Process chosen: direct author + build (no dt-review).

## What it is
A Claude-side orchestration skill that drives **Codex's built-in `image_gen` tool** to generate
on-brand graphics. Runs on Danny's ChatGPT Business subscription — no API key, no per-image billing.
It does **not** reimplement image generation: Codex's `.system/imagegen` skill already does that well.
`dt-image-gen` is the thin, reliable, TCM-branded wrapper around it, adding the three things Codex's
bare skill lacks: brand defaults, a grid-variation workflow, and a gallery review surface.

## Engine (verified by live spike)
- Invocation: `codex exec --dangerously-bypass-approvals-and-sandbox -s danger-full-access`, prompt on
  **stdin via the Bash tool** (per the "drive Codex via Bash, not PowerShell" memory).
- Output: Codex writes PNGs to `%USERPROFILE%\.codex\generated_images\<uuid>\`.
- Cost/scale: ~57k tokens per image; default output ~1254x1254 px.

## Critical design rule (from the spike)
Never trust Codex to save to a target path. Cross-shell path translation breaks: `/tmp/...` was
resolved by .NET to `C:\tmp\...`, not Bash's `/tmp`. **Pattern:** let Codex generate to its default
`generated_images` dir, then the wrapper collects the newest PNG(s) and moves them to the destination
using real Windows paths.

## Components
1. **`SKILL.md`** — house-style; triggers; the workflow Claude follows.
2. **Engine wrapper (Bash)** — takes prompt + destination dir; invokes Codex headless; collects newest
   output(s) from `generated_images`; moves to dest; returns paths. Visible progress instrumentation
   (long-running-work rule).
3. **Design-system defaults** — reusable style preamble carrying the TCM palette (navy/blue, gold
   accent) + Myriad Pro typography; auto-converts a supplied brand/design-system PDF -> JPEG reference
   (Codex won't accept PDF).
4. **Grid-variation mode** — one generation prompted as a 5x5 numbered grid = 25 options for the cost
   of one image; Claude views it; Danny picks a cell; wrapper re-runs that cell's prompt at full res.
5. **Gallery viewer** — contact-sheet HTML written into the project assets folder (list navigates,
   image pane static — master-detail default), opens locally.

## Decisions locked
- Scope: full v1 (single + batch + grid-variation + gallery).
- Save location: the current project's assets folder.
- Deferred: transparency/chroma-key, CLI/API fallback for large batches, Kling/video, 700-prompt library.

## Build steps
1. Cut a worktree on `danny-skills` (agent-run repo work -> worktree mandatory).
2. Engine wrapper + path-collection; smoke-test a single image into a scratch project assets folder.
3. Design-system style preamble + PDF->JPEG reference handling.
4. Grid-variation + batch modes.
5. Gallery viewer HTML.
6. Author `SKILL.md` + triggers; bump version in `plugin.json` and `marketplace.json`.
7. Smoke-test from a fresh invocation; merge to `main`.

## Decisions resolved (post-review of open questions)
- Triggers: broad — fire whenever a raster image/visual is the right output, including when Claude decides so itself; carve-outs for code-native charts/diagrams (Mermaid/SVG), existing vector/logo systems, simple shapes.
- Default dimensions/quality: leave to Codex's default (~1254px).
- Brand: off by default; opt in only when requested. Pull TCM palette/type from the design system at request time (never hand-copy values).

## As-built state (committed on feat/dt-image-gen, 0.9.39)
Scripted (deterministic):
- `scripts/gen-image.sh` — arg parse; headless `codex exec`; collect newest PNG from `generated_images` via `find -newer`; move to dest; slug sanitize; `-vN` collision versioning; `--count` loop; `--ref` passthrough to `codex -i`; cygpath Windows-path output.
- `scripts/make-gallery.mjs` — scan dir, sort by mtime, emit self-contained master-detail `gallery.html`.

Left as SKILL.md prose (AI-interpreted) — candidates for extraction:
- Grid-variation flow: builds the 5x5 grid prompt, then on cell pick RE-PROMPTS the concept from scratch rather than cropping/upscaling the chosen cell's actual pixels (determinism gap + composition-fidelity loss).
- PDF->JPEG reference conversion: prose "convert it first", no helper.
- Project assets-folder resolution: heuristic in prose.
- Brand preamble assembly: prose.

## Review questions (focus for adversarial pass)
1. Determinism boundary: which prose procedures should become deterministic scripts to match the repo's 0.9.18 "determinism-composability-extractions" standard? Is grid-cell crop-and-upscale the right model vs re-prompting?
2. Engine robustness: is the `find -newer MARKER` collection race-safe under concurrent Codex image writes? Failure modes if Codex emits multiple files or none.
3. Trigger calibration: is the broad "fire whenever a visual is wanted" description likely to over-trigger against the Mermaid/chart/code-native carve-outs?
4. Path discipline: any remaining path-translation hazard beyond the dest move (refs, gallery, brand PDF)?
5. Cost surface: grid (1 call/25 options) vs `--count` (N calls); is anything silently expensive?
6. Cross-surface visibility: new-skill junction reconciliation correctness.
