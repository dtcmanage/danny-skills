#!/usr/bin/env bash
# gen-image.sh - dt-image-gen engine wrapper
#
# Drives Codex's built-in image_gen tool headlessly (runs on Danny's ChatGPT
# subscription - no OPENAI_API_KEY, no per-image billing), then collects the
# generated PNG(s) from Codex's output dir and moves them into a destination
# folder using real filesystem paths.
#
# WHY collect-then-move: Codex resolves a caller-supplied save path through
# .NET/PowerShell, so a bash path like /tmp/x.png becomes C:\tmp\x.png and the
# file lands in the wrong place. We never hand Codex a target path. We let it
# write to its default generated_images dir and move the files ourselves.
#
# Usage:
#   bash gen-image.sh --prompt "<image prompt>" --dest "<output dir>" \
#        [--name <basename>] [--count <n>] [--ref <image>]...
#
# stdout: one absolute Windows path per saved image (machine-readable).
# stderr: progress and diagnostics.
set -euo pipefail

PROMPT=""
DEST=""
NAME="image"
COUNT=1
REFS=()

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prompt) PROMPT="${2:-}"; shift 2;;
    --dest)   DEST="${2:-}";   shift 2;;
    --name)   NAME="${2:-}";   shift 2;;
    --count)  COUNT="${2:-}";  shift 2;;
    --ref)    REFS+=("${2:-}"); shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "[dt-image-gen] ERROR: unknown argument: $1" >&2; exit 2;;
  esac
done

[ -n "$PROMPT" ] || { echo "[dt-image-gen] ERROR: --prompt is required" >&2; exit 2; }
[ -n "$DEST" ]   || { echo "[dt-image-gen] ERROR: --dest is required" >&2; exit 2; }
case "$COUNT" in (*[!0-9]*|"") echo "[dt-image-gen] ERROR: --count must be a positive integer" >&2; exit 2;; esac
[ "$COUNT" -ge 1 ] || { echo "[dt-image-gen] ERROR: --count must be >= 1" >&2; exit 2; }

command -v codex >/dev/null 2>&1 || { echo "[dt-image-gen] ERROR: codex CLI not found on PATH" >&2; exit 3; }

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
GEN_DIR="$CODEX_HOME/generated_images"
mkdir -p "$GEN_DIR"
mkdir -p "$DEST"

# Sanitize the base filename to a safe slug.
SAFE_NAME="$(printf '%s' "$NAME" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-//; s/-$//')"
[ -n "$SAFE_NAME" ] || SAFE_NAME="image"

# Build reference-image args for codex (-i FILE ...). Skip missing files.
REF_ARGS=()
for r in "${REFS[@]:-}"; do
  [ -n "$r" ] || continue
  if [ ! -f "$r" ]; then
    echo "[dt-image-gen] WARN: reference image not found, skipping: $r" >&2
    continue
  fi
  REF_ARGS+=( -i "$r" )
done

# Optional per-generation timeout (coreutils). Falls back to no timeout.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout 600"; fi

win_path() { cygpath -w "$1" 2>/dev/null || echo "$1"; }

CX_INSTRUCTIONS="Use your built-in image_gen tool to generate the image described below. Rules: do not write code, do not call any external API or CLI, do not set or use OPENAI_API_KEY. Generate exactly one image. Do not attempt to save it to any specific file path - just generate it; surrounding tooling collects the file. After the image is generated, print only the word DONE.

IMAGE REQUEST:
$PROMPT"

SAVED=()
for (( i=1; i<=COUNT; i++ )); do
  echo "[dt-image-gen] generation $i/$COUNT - invoking Codex image_gen ..." >&2
  MARKER="$(mktemp)"
  LOG="$(mktemp)"

  set +e
  if [ "${#REF_ARGS[@]}" -gt 0 ]; then
    printf '%s' "$CX_INSTRUCTIONS" | $TIMEOUT_BIN codex exec \
      --dangerously-bypass-approvals-and-sandbox -s danger-full-access \
      "${REF_ARGS[@]}" - >"$LOG" 2>&1
  else
    printf '%s' "$CX_INSTRUCTIONS" | $TIMEOUT_BIN codex exec \
      --dangerously-bypass-approvals-and-sandbox -s danger-full-access \
      - >"$LOG" 2>&1
  fi
  rc=$?
  set -e

  if [ $rc -ne 0 ]; then
    echo "[dt-image-gen] ERROR: codex exec failed (rc=$rc) on generation $i. Last lines:" >&2
    tail -n 20 "$LOG" >&2
    rm -f "$MARKER" "$LOG"
    exit 1
  fi

  # Collect PNG(s) created after MARKER, newest last.
  mapfile -t NEW < <(find "$GEN_DIR" -type f -iname '*.png' -newer "$MARKER" -printf '%T@\t%p\n' 2>/dev/null | sort -n | cut -f2-)
  rm -f "$MARKER" "$LOG"

  if [ "${#NEW[@]}" -eq 0 ]; then
    echo "[dt-image-gen] ERROR: Codex reported success but produced no new image on generation $i." >&2
    echo "[dt-image-gen]        Checked: $(win_path "$GEN_DIR")" >&2
    exit 1
  fi

  SRC="${NEW[-1]}"

  if [ "$COUNT" -eq 1 ]; then base="$SAFE_NAME"; else base="${SAFE_NAME}-$i"; fi
  TARGET="$DEST/$base.png"
  v=2
  while [ -e "$TARGET" ]; do TARGET="$DEST/${base}-v${v}.png"; v=$((v+1)); done

  cp "$SRC" "$TARGET"
  SAVED+=( "$TARGET" )
  echo "[dt-image-gen]   saved: $(win_path "$TARGET")" >&2
done

echo "[dt-image-gen] done - $COUNT image(s) saved to $(win_path "$DEST")" >&2

# Machine-readable result on stdout: one Windows path per line.
for p in "${SAVED[@]}"; do
  win_path "$p"
done
