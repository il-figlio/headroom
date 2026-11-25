#!/bin/zsh
set -eu
cd "${0:A:h:h}"
ICONSET="$PWD/.build-headboard/Headboard.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" Resources/Headboard.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" Resources/Headboard.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/Headboard.icns
echo "Built Resources/Headboard.icns"
