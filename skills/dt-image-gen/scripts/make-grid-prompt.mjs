#!/usr/bin/env node
// make-grid-prompt.mjs - deterministic 5x5 numbered-grid prompt assembly.
//
// Emits a single-image prompt that produces a grid of distinct variations on one
// concept, each cell numbered, so N options cost one generation. Output goes to
// stdout for gen-image.sh --prompt.
//
// Usage:
//   node make-grid-prompt.mjs --concept "<concept>" [--rows 5] [--cols 5]

const args = process.argv.slice(2);
function flag(name, def = null) {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
}

const concept = flag("--concept");
if (!concept) {
  console.error("ERROR: --concept is required");
  process.exit(2);
}
const rows = parseInt(flag("--rows", "5"), 10);
const cols = parseInt(flag("--cols", "5"), 10);
if (!Number.isInteger(rows) || !Number.isInteger(cols) || rows < 1 || cols < 1) {
  console.error("ERROR: --rows and --cols must be positive integers");
  process.exit(2);
}
const n = rows * cols;

const prompt = [
  `A single image containing a ${rows}x${cols} grid (${n} cells) of distinct variations of: ${concept}.`,
  `Lay the cells out in an even ${rows}-row by ${cols}-column grid with consistent framing and scale across every cell, thin uniform gutters, and a plain neutral background.`,
  `Number every cell sequentially from 1 to ${n}, left-to-right then top-to-bottom, showing the number in a small solid white circle with black text in the top-left corner of that cell.`,
  `Each cell explores a genuinely different take - composition, angle, color emphasis, lighting, or mood - while keeping the same subject and intent.`,
  `Do not add any title, caption, watermark, or text outside the cells.`,
].join(" ");

process.stdout.write(prompt + "\n");
