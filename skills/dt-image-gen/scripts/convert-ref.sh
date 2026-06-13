#!/usr/bin/env bash
# convert-ref.sh - convert a non-raster reference (e.g. a brand-book PDF) into a
# PNG Codex can accept as a -i reference. Codex rejects PDFs.
#
# Detects an available converter (pdftoppm / Ghostscript / ImageMagick) and
# converts the first page. If the input is already a raster image, prints its
# path unchanged. If no converter is present, fails clear, naming what to install.
#
# Usage:
#   bash convert-ref.sh <input> [output.png]
# stdout: the absolute path of the usable raster reference.
set -euo pipefail

IN="${1:-}"
OUT="${2:-}"
[ -n "$IN" ] || { echo "[convert-ref] ERROR: input file required" >&2; exit 2; }
[ -f "$IN" ] || { echo "[convert-ref] ERROR: input not found: $IN" >&2; exit 2; }

win_path() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

ext="$(lower "${IN##*.}")"
case "$ext" in
  png|jpg|jpeg|webp|gif)
    # Already a raster reference Codex accepts; pass through.
    win_path "$IN"; exit 0;;
esac

if [ "$ext" != "pdf" ]; then
  echo "[convert-ref] ERROR: unsupported reference type .$ext (expected pdf or a raster image)" >&2
  exit 2
fi

if [ -z "$OUT" ]; then OUT="${IN%.*}.png"; fi
OUTBASE="${OUT%.png}"

if command -v pdftoppm >/dev/null 2>&1; then
  # pdftoppm writes <prefix>-1.png for page 1; normalize to $OUT.
  pdftoppm -png -r 200 -f 1 -l 1 "$IN" "$OUTBASE" >/dev/null 2>&1
  if [ -f "${OUTBASE}-1.png" ]; then mv -f "${OUTBASE}-1.png" "$OUT"; fi
  [ -f "$OUT" ] || { echo "[convert-ref] ERROR: pdftoppm produced no output" >&2; exit 1; }
  win_path "$OUT"; exit 0
fi

if command -v magick >/dev/null 2>&1; then
  magick -density 200 "${IN}[0]" "$OUT" >/dev/null 2>&1
  [ -f "$OUT" ] || { echo "[convert-ref] ERROR: ImageMagick produced no output" >&2; exit 1; }
  win_path "$OUT"; exit 0
fi

if command -v gs >/dev/null 2>&1; then
  gs -dQUIET -dBATCH -dNOPAUSE -sDEVICE=png16m -r200 -dFirstPage=1 -dLastPage=1 \
     -sOutputFile="$OUT" "$IN" >/dev/null 2>&1
  [ -f "$OUT" ] || { echo "[convert-ref] ERROR: Ghostscript produced no output" >&2; exit 1; }
  win_path "$OUT"; exit 0
fi

echo "[convert-ref] ERROR: no PDF converter found. Install one of:" >&2
echo "  - poppler (pdftoppm)   winget install -e --id oschwartz10612.Poppler  (or via MSYS2)" >&2
echo "  - ImageMagick (magick) winget install -e --id ImageMagick.ImageMagick" >&2
echo "  - Ghostscript (gs)     winget install -e --id ArtifexSoftware.GhostScript" >&2
echo "  Or export the brand reference page to PNG/JPG yourself and pass that instead." >&2
exit 3
