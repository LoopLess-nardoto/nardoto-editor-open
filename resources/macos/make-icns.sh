#!/usr/bin/env bash
# Regenera resources/macos/NardotoEditor.icns a partir do ícone do Nardoto Editor.
# Mantido no Git junto do ICO do Windows; sips e iconutil são exclusivos do macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/resources/nardoto-editor.png"
OUT="$ROOT/resources/macos/NardotoEditor.icns"

if [[ ! -f "$SRC" ]]; then
  echo "Icon source not found at: $SRC" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/NardotoEditor.iconset"
mkdir -p "$ICONSET"

# Each size needs a 2x file too, or Finder upscales the 1x on Retina.
for PT in 16 32 128 256 512; do
  sips -z "$PT" "$PT" "$SRC" --out "$ICONSET/icon_${PT}x${PT}.png" >/dev/null
  sips -z "$((PT * 2))" "$((PT * 2))" "$SRC" --out "$ICONSET/icon_${PT}x${PT}@2x.png" >/dev/null
done

iconutil --convert icns --output "$OUT" "$ICONSET"
echo "Wrote $OUT"
