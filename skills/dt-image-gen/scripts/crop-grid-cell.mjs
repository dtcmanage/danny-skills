#!/usr/bin/env node
// crop-grid-cell.mjs - deterministically crop one cell out of a numbered grid PNG.
//
// The grid-variation flow generates a rows x cols grid in one image; once a cell
// is chosen, this extracts that cell's exact pixels (known geometry) to a PNG that
// is then passed to gen-image.sh as a --ref for composition-preserving refinement.
// This is a deterministic crop, NOT a pixel-preserving upscale.
//
// Dependency-free: uses only node:zlib. Supports 8-bit, non-interlaced, color
// type 2 (RGB) or 6 (RGBA) - which is what Codex's image_gen emits. Any other
// format fails clear.
//
// Usage:
//   node crop-grid-cell.mjs --grid "<grid.png>" --cell <N> [--rows 5] [--cols 5] --out "<cell.png>"

import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { inflateSync, deflateSync } from "node:zlib";

const args = process.argv.slice(2);
function flag(name, def = null) {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
}
function die(msg, code = 1) {
  console.error(`ERROR: ${msg}`);
  process.exit(code);
}

const gridPath = flag("--grid");
const outPath = flag("--out");
const cell = parseInt(flag("--cell", ""), 10);
const rows = parseInt(flag("--rows", "5"), 10);
const cols = parseInt(flag("--cols", "5"), 10);
if (!gridPath || !outPath) die("--grid and --out are required", 2);
if (!Number.isInteger(cell) || cell < 1) die("--cell must be a positive integer", 2);
if (!Number.isInteger(rows) || !Number.isInteger(cols) || rows < 1 || cols < 1) die("--rows/--cols must be positive integers", 2);
if (cell > rows * cols) die(`--cell ${cell} exceeds grid capacity ${rows * cols}`, 2);

const PNG_SIG = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

// --- CRC32 (PNG polynomial) ---
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

// --- decode PNG to raw pixels ---
const raw = readFileSync(resolve(gridPath));
if (!raw.subarray(0, 8).equals(PNG_SIG)) die("not a PNG file");

let width = 0, height = 0, bitDepth = 0, colorType = 0, interlace = 0;
const idat = [];
let off = 8;
while (off < raw.length) {
  const len = raw.readUInt32BE(off);
  const type = raw.toString("ascii", off + 4, off + 8);
  const data = raw.subarray(off + 8, off + 8 + len);
  if (type === "IHDR") {
    width = data.readUInt32BE(0);
    height = data.readUInt32BE(4);
    bitDepth = data[8];
    colorType = data[9];
    interlace = data[12];
  } else if (type === "IDAT") {
    idat.push(data);
  } else if (type === "IEND") {
    break;
  }
  off += 12 + len; // length(4) + type(4) + data + crc(4)
}

if (bitDepth !== 8) die(`unsupported PNG bit depth ${bitDepth} (need 8)`);
if (colorType !== 2 && colorType !== 6) die(`unsupported PNG color type ${colorType} (need 2 RGB or 6 RGBA)`);
if (interlace !== 0) die("interlaced PNG not supported");

const channels = colorType === 2 ? 3 : 4;
const inflated = inflateSync(Buffer.concat(idat));
const stride = width * channels;

// --- unfilter scanlines into a flat pixel buffer ---
const pixels = Buffer.alloc(height * stride);
function paeth(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}
let sp = 0;
for (let y = 0; y < height; y++) {
  const filter = inflated[sp++];
  const row = y * stride;
  for (let x = 0; x < stride; x++) {
    const rawByte = inflated[sp++];
    const a = x >= channels ? pixels[row + x - channels] : 0;
    const b = y > 0 ? pixels[row - stride + x] : 0;
    const c = x >= channels && y > 0 ? pixels[row - stride + x - channels] : 0;
    let val;
    switch (filter) {
      case 0: val = rawByte; break;
      case 1: val = rawByte + a; break;
      case 2: val = rawByte + b; break;
      case 3: val = rawByte + ((a + b) >> 1); break;
      case 4: val = rawByte + paeth(a, b, c); break;
      default: die(`unsupported PNG filter type ${filter}`);
    }
    pixels[row + x] = val & 0xff;
  }
}

// --- compute cell rectangle (cells numbered left-to-right, top-to-bottom) ---
const idx = cell - 1;
const colI = idx % cols;
const rowI = Math.floor(idx / cols);
const cw = Math.floor(width / cols);
const ch = Math.floor(height / rows);
const x0 = colI * cw;
const y0 = rowI * ch;
if (cw < 1 || ch < 1) die("computed cell size is empty");

// --- crop into a new raw buffer ---
const cropStride = cw * channels;
const crop = Buffer.alloc(ch * cropStride);
for (let y = 0; y < ch; y++) {
  const srcStart = (y0 + y) * stride + x0 * channels;
  pixels.copy(crop, y * cropStride, srcStart, srcStart + cropStride);
}

// --- re-encode (filter 0 on every scanline) ---
const filtered = Buffer.alloc(ch * (cropStride + 1));
for (let y = 0; y < ch; y++) {
  filtered[y * (cropStride + 1)] = 0; // filter: None
  crop.copy(filtered, y * (cropStride + 1) + 1, y * cropStride, (y + 1) * cropStride);
}
const compressed = deflateSync(filtered);

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, "ascii");
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([len, typeBuf, data, crcBuf]);
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(cw, 0);
ihdr.writeUInt32BE(ch, 4);
ihdr[8] = 8;             // bit depth
ihdr[9] = colorType;     // same color type
ihdr[10] = 0;            // compression
ihdr[11] = 0;            // filter
ihdr[12] = 0;            // interlace

const out = Buffer.concat([
  PNG_SIG,
  chunk("IHDR", ihdr),
  chunk("IDAT", compressed),
  chunk("IEND", Buffer.alloc(0)),
]);

writeFileSync(resolve(outPath), out);
console.log(resolve(outPath));
