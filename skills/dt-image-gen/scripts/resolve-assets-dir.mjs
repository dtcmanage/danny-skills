#!/usr/bin/env node
// resolve-assets-dir.mjs - deterministic project assets-folder resolution.
//
// Returns the directory generated images should be saved into for a project:
// the first existing conventional assets folder, else <root>/assets/generated.
// Prints the absolute path to stdout.
//
// Usage:
//   node resolve-assets-dir.mjs --root "<project root>" [--create]

import { existsSync, mkdirSync, statSync } from "node:fs";
import { resolve, join } from "node:path";

const args = process.argv.slice(2);
function flag(name, def = null) {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
}
const create = args.includes("--create");

const root = flag("--root");
if (!root) {
  console.error("ERROR: --root is required");
  process.exit(2);
}
const rootAbs = resolve(root);
if (!existsSync(rootAbs) || !statSync(rootAbs).isDirectory()) {
  console.error(`ERROR: --root is not a directory: ${rootAbs}`);
  process.exit(1);
}

// Preference order for an existing conventional assets folder.
const candidates = ["assets", join("src", "assets"), join("public", "assets"), "public", "static"];
for (const c of candidates) {
  const p = join(rootAbs, c);
  if (existsSync(p) && statSync(p).isDirectory()) {
    console.log(p);
    process.exit(0);
  }
}

// None found: default to <root>/assets/generated.
const fallback = join(rootAbs, "assets", "generated");
if (create) {
  mkdirSync(fallback, { recursive: true });
}
console.log(fallback);
