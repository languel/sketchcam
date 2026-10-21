#!/usr/bin/env bash
# Preserve the supplied artwork; frame it and generate Apple's macOS icon slots.
# Requires ImageMagick; iconutil ships with macOS. Does not build/launch the app.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:-$ROOT_DIR/artwork/sketchcam-icon-source.png}"
ASSETS="$ROOT_DIR/SketchCam/Resources/Assets.xcassets/AppIcon.appiconset"
EXPORT="$ROOT_DIR/build/icon"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
command -v magick >/dev/null || { echo 'ImageMagick is required' >&2; exit 1; }
mkdir -p "$EXPORT/SketchCam.iconset"

magick "$SOURCE" -colorspace sRGB -strip -background '#0b0b0b' -alpha remove -alpha off \
  -filter Lanczos -resize 824x824 -gravity center -extent 824x824 "$WORK/art.png"
magick -size 824x824 xc:none -fill white \
  -draw 'roundrectangle 0,0 823,823 184,184' "$WORK/mask.png"
magick "$WORK/art.png" "$WORK/mask.png" -alpha off -compose CopyOpacity -composite \
  -stroke '#303030' -strokewidth 1.5 -fill none \
  -draw 'roundrectangle 0.75,0.75 822.25,822.25 184,184' "$WORK/tile.png"
magick -size 1024x1024 xc:none "$WORK/tile.png" -geometry +100+100 \
  -compose Over -composite "$WORK/master.png"
for size in 16 32 64 128 256 512 1024; do
  magick "$WORK/master.png" -filter Lanczos -resize "${size}x${size}" \
    "PNG32:$ASSETS/icon_$size.png"
done
for size in 16 32 128 256 512; do
  cp "$ASSETS/icon_$size.png" "$EXPORT/SketchCam.iconset/icon_${size}x${size}.png"
  retina=$((size * 2))
  cp "$ASSETS/icon_$retina.png" "$EXPORT/SketchCam.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$EXPORT/SketchCam.iconset" -o "$EXPORT/SketchCam.icns"
echo "App icon assets generated; standalone icon: $EXPORT/SketchCam.icns"
