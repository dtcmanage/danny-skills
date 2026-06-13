#!/usr/bin/env node
// brand-preamble.mjs - assemble a brand style preamble from RESOLVED values.
//
// This helper does NOT know any brand values. The agent reads the current
// palette hex and typography from the canonical design system at request time
// and passes them in here; this script only templates them into a deterministic
// preamble string. That keeps token values living in code, never hand-copied
// into the skill.
//
// Usage (either form):
//   node brand-preamble.mjs --primary "#0b1b2b" --accent "#c9a227" --font "Myriad Pro" [--radius "tight"] [--notes "..."]
//   node brand-preamble.mjs --json '{"primary":"#0b1b2b","accent":"#c9a227","font":"Myriad Pro","radius":"tight","notes":"..."}'
//
// Prints the preamble to stdout. Append it to an image prompt.

const args = process.argv.slice(2);
function flag(name, def = null) {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
}

let vals = {};
const json = flag("--json");
if (json) {
  try {
    vals = JSON.parse(json);
  } catch (err) {
    console.error(`ERROR: --json is not valid JSON: ${err.message}`);
    process.exit(2);
  }
} else {
  vals = {
    primary: flag("--primary"),
    accent: flag("--accent"),
    font: flag("--font"),
    radius: flag("--radius"),
    notes: flag("--notes"),
  };
}

if (!vals.primary || !vals.accent || !vals.font) {
  console.error("ERROR: primary, accent, and font are required (the agent supplies them from the design system)");
  process.exit(2);
}

const radius = vals.radius || "tight";
const parts = [
  `Brand styling:`,
  `use ${vals.primary} as the primary color and ${vals.accent} as the accent color;`,
  `set all typography in ${vals.font};`,
  `use a ${radius} corner radius and a clean, institutional finish.`,
  `Apply the brand palette and type faithfully, and render any in-image text in ${vals.font}.`,
];
if (vals.notes) parts.push(String(vals.notes));

process.stdout.write(parts.join(" ") + "\n");
