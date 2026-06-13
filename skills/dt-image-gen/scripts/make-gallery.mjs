#!/usr/bin/env node
// make-gallery.mjs - dt-image-gen contact-sheet viewer
//
// Scans a directory for generated images and writes a single self-contained
// gallery.html next to them. Master-detail layout: a scrollable thumbnail rail
// navigates; the large preview pane stays fixed and does not reflow as you
// click through (lowers attention cost during file-by-file review).
//
// Usage:
//   node make-gallery.mjs --dir "<image dir>" [--title "<title>"] [--out gallery.html]
//
// Images are referenced by relative filename, so the gallery must live in the
// same folder as the images. Prints the absolute path of the written file.

import { readdirSync, statSync, writeFileSync } from "node:fs";
import { join, resolve, basename } from "node:path";

const args = process.argv.slice(2);
function flag(name, def = null) {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
}

const dir = flag("--dir");
if (!dir) {
  console.error("ERROR: --dir is required");
  process.exit(2);
}
const dirAbs = resolve(dir);
const title = flag("--title", "Image gallery");
const outName = flag("--out", "gallery.html");

const IMG_RE = /\.(png|jpe?g|webp|gif)$/i;
let entries;
try {
  entries = readdirSync(dirAbs)
    .filter((f) => IMG_RE.test(f) && f !== outName)
    .map((f) => ({ f, m: statSync(join(dirAbs, f)).mtimeMs }))
    .sort((a, b) => a.m - b.m)
    .map((e) => e.f);
} catch (err) {
  console.error(`ERROR: cannot read directory: ${dirAbs}\n${err.message}`);
  process.exit(1);
}

if (entries.length === 0) {
  console.error(`ERROR: no images found in ${dirAbs}`);
  process.exit(1);
}

const esc = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const thumbs = entries
  .map(
    (f, i) => `
      <button class="thumb${i === 0 ? " active" : ""}" data-src="${esc(f)}" data-name="${esc(f)}">
        <img src="${esc(f)}" alt="${esc(f)}" loading="lazy" />
        <span class="cap">${esc(f)}</span>
      </button>`
  )
  .join("");

const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${esc(title)}</title>
<style>
  :root {
    --navy: #0b1b2b; --navy-2: #12263b; --line: #1f3346; --gold: #c9a227;
    --text: #e8eef5; --muted: #8aa0b6;
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; margin: 0; }
  body {
    font-family: "Myriad Pro", "Segoe UI", system-ui, sans-serif;
    background: var(--navy); color: var(--text);
    display: grid; grid-template-rows: auto 1fr; height: 100vh;
  }
  header {
    padding: 14px 20px; border-bottom: 1px solid #1f3346;
    display: flex; align-items: baseline; gap: 14px;
  }
  header h1 { font-size: 16px; margin: 0; font-weight: 600; letter-spacing: .2px; }
  header .meta { color: var(--muted); font-size: 13px; }
  header .gold { color: var(--gold); }
  main { display: grid; grid-template-columns: 280px 1fr; min-height: 0; }
  /* Master: scrollable thumbnail rail (this is what navigates). */
  .rail { overflow-y: auto; border-right: 1px solid #1f3346; padding: 10px; background: var(--navy-2); }
  .thumb {
    display: grid; grid-template-rows: auto auto; gap: 6px; width: 100%;
    background: transparent; border: 1px solid transparent; border-radius: 6px;
    padding: 8px; margin-bottom: 8px; cursor: pointer; text-align: left; color: var(--text);
  }
  .thumb:hover { border-color: #2a4a66; background: #16314a; }
  .thumb.active { border-color: var(--gold); background: #16314a; }
  .thumb img { width: 100%; aspect-ratio: 1 / 1; object-fit: cover; border-radius: 4px; background: #0a1622; }
  .thumb .cap { font-size: 12px; color: var(--muted); word-break: break-all; }
  /* Detail: fixed preview pane - does NOT reflow as you click thumbnails. */
  .stage { display: grid; grid-template-rows: 1fr auto; min-height: 0; padding: 18px; gap: 12px; }
  .stage .frame {
    min-height: 0; display: flex; align-items: center; justify-content: center;
    background:
      linear-gradient(45deg, #0c1a28 25%, transparent 25%, transparent 75%, #0c1a28 75%) 0 0/24px 24px,
      linear-gradient(45deg, #0c1a28 25%, #0f2030 25%, #0f2030 75%, #0c1a28 75%) 12px 12px/24px 24px,
      #0f2030;
    border: 1px solid #1f3346; border-radius: 8px; overflow: hidden;
  }
  .stage .frame img { max-width: 100%; max-height: 100%; object-fit: contain; display: block; }
  .stage .label { color: var(--muted); font-size: 13px; word-break: break-all; }
  .stage .label b { color: var(--text); font-weight: 600; }
</style>
</head>
<body>
  <header>
    <h1>${esc(title)}</h1>
    <span class="meta"><span class="gold">${entries.length}</span> image${entries.length === 1 ? "" : "s"} &middot; click a thumbnail to preview</span>
  </header>
  <main>
    <nav class="rail">${thumbs}
    </nav>
    <section class="stage">
      <div class="frame"><img id="preview" src="${esc(entries[0])}" alt="${esc(entries[0])}" /></div>
      <div class="label">Showing: <b id="label">${esc(entries[0])}</b></div>
    </section>
  </main>
<script>
  const rail = document.querySelector(".rail");
  const preview = document.getElementById("preview");
  const label = document.getElementById("label");
  rail.addEventListener("click", (e) => {
    const btn = e.target.closest(".thumb");
    if (!btn) return;
    document.querySelectorAll(".thumb").forEach((t) => t.classList.remove("active"));
    btn.classList.add("active");
    preview.src = btn.dataset.src;
    preview.alt = btn.dataset.name;
    label.textContent = btn.dataset.name;
  });
</script>
</body>
</html>
`;

const outPath = join(dirAbs, outName);
writeFileSync(outPath, html, "utf8");
console.log(outPath);
