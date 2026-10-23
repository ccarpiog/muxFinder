#!/bin/bash
# Regenerates the app icon and the menu bar icon in Resources/ from this folder's sources
# (PLAN.md D28; dev only: the outputs are committed and scripts/build-app.sh only copies them).
#
#   scripts/dev/icon/build-icon.sh
#
# - Compiles glyph.swift (the mark) and compose.swift (plate + mark) into a private temporary
#   folder, removed on exit.
# - Resources/AppIcon.icns: the macOS composites at 16, 32, 64, 128, 256, 512 and 1024 px in
#   Apple's iconset names. Above 32 px the background is plate.png (1024 × 1024, opaque,
#   painted with the ChatGPT prompt in README.md); at 32 px and below, and at every size when
#   plate.png is missing (with a warning), it is BRIEF.md's two-stop gradient. The mark is
#   drawn natively at each size, never scaled.
# - Resources/MenuBarIcon.png, @2x, @3x: the mark in black on transparency (a template image)
#   for an 18 pt menu bar slot, drawn natively on a 24/18 larger canvas so it fills about 15 of
#   the 18 pt like system symbols, then centre-cropped (a crop, not a scale).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$ROOT/Resources"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/muxfinder-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/variant"
mkdir -p "$STAGE/bin" "$STAGE/out" "$OUT"

echo "Compiling the renderers..."
swiftc -swift-version 6 -O -o "$STAGE/bin/glyph" "$HERE/glyph.swift"
swiftc -swift-version 6 -O -o "$WORK/compose" "$HERE/compose.swift"
cp "$HERE/BRIEF.md" "$STAGE/BRIEF.md"

if [ -f "$HERE/plate.png" ]; then
  width="$(sips -g pixelWidth "$HERE/plate.png" | awk '/pixelWidth/ { print $2 }')"
  height="$(sips -g pixelHeight "$HERE/plate.png" | awk '/pixelHeight/ { print $2 }')"
  if [ "$width" != 1024 ] || [ "$height" != 1024 ]; then
    echo "error: plate.png is ${width}x${height}, expected 1024x1024" >&2
    exit 1
  fi
  cp "$HERE/plate.png" "$STAGE/out/plate.png"
else
  echo "warning: no plate.png; the app icon uses the gradient at every size." >&2
fi

echo "Compositing the app icon..."
for size in 16 32 64 128 256 512 1024; do
  # compose repeats the missing-plate warning at every size; show its stderr only on failure.
  if ! "$WORK/compose" --variant "$STAGE" --size "$size" 2> "$WORK/compose.err"; then
    cat "$WORK/compose.err" >&2
    exit 1
  fi
done

# Apple's iconset names: each point size at 1× and 2×.
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
cp "$STAGE/out/macos-16.png" "$ICONSET/icon_16x16.png"
cp "$STAGE/out/macos-32.png" "$ICONSET/icon_16x16@2x.png"
cp "$STAGE/out/macos-32.png" "$ICONSET/icon_32x32.png"
cp "$STAGE/out/macos-64.png" "$ICONSET/icon_32x32@2x.png"
cp "$STAGE/out/macos-128.png" "$ICONSET/icon_128x128.png"
cp "$STAGE/out/macos-256.png" "$ICONSET/icon_128x128@2x.png"
cp "$STAGE/out/macos-256.png" "$ICONSET/icon_256x256.png"
cp "$STAGE/out/macos-512.png" "$ICONSET/icon_256x256@2x.png"
cp "$STAGE/out/macos-512.png" "$ICONSET/icon_512x512.png"
cp "$STAGE/out/macos-1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns -o "$OUT/AppIcon.icns" "$ICONSET"

echo "Rendering the menu bar icon..."
for scale in 1 2 3; do
  slot=$((18 * scale))
  case "$scale" in
    1) name="MenuBarIcon.png" ;;
    *) name="MenuBarIcon@${scale}x.png" ;;
  esac
  "$STAGE/bin/glyph" --size $((24 * scale)) --fill 000000 --out "$WORK/$name"
  sips -c "$slot" "$slot" "$WORK/$name" > /dev/null
  cp "$WORK/$name" "$OUT/$name"
done

echo "Wrote $OUT/AppIcon.icns and $OUT/MenuBarIcon{,@2x,@3x}.png"
