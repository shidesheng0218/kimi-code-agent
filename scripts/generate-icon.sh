#!/bin/zsh
# Regenerate media/AppIcon.icns from media/kimi-readme.svg.
# Uses only macOS built-ins: qlmanage renders the SVG, sips scales, iconutil packs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/media/kimi-readme.svg"
OUT="$ROOT/media/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

qlmanage -t -s 1024 -o "$WORK" "$SVG" >/dev/null 2>&1
SRC="$WORK/$(basename "$SVG").png"
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"

sips -z 16 16     "$SRC" --out "$SET/icon_16x16.png" >/dev/null
sips -z 32 32     "$SRC" --out "$SET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$SRC" --out "$SET/icon_32x32.png" >/dev/null
sips -z 64 64     "$SRC" --out "$SET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$SRC" --out "$SET/icon_128x128.png" >/dev/null
sips -z 256 256   "$SRC" --out "$SET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$SRC" --out "$SET/icon_256x256.png" >/dev/null
sips -z 512 512   "$SRC" --out "$SET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$SRC" --out "$SET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SRC" --out "$SET/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$SET" -o "$OUT"
echo "Wrote $OUT"
