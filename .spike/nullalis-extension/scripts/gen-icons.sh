#!/usr/bin/env bash
# Reproducible icon generator for the nullalis extension.
#
# Produces public/icon-{16,48,128}.png: a rounded-square tile in the
# nullalis brand purple with a white lowercase "n" glyph. Run from the
# extension root: `bash scripts/gen-icons.sh`. Requires ImageMagick 7
# (`magick`). The output PNGs are committed; this script only needs to
# be re-run when the brand mark changes.
set -euo pipefail

OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/public"
BG="#5B3DF5"      # nullalis brand purple
FG="#FFFFFF"      # glyph white
# Prefer a bundled-by-the-OS bold sans. Fall back across common paths so
# the script is reproducible on Linux CI and macOS dev boxes alike.
FONT=""
for f in \
  /System/Library/Fonts/Helvetica.ttc \
  /System/Library/Fonts/Supplemental/Arial\ Bold.ttf \
  /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf \
  /usr/share/fonts/dejavu/DejaVuSans-Bold.ttf ; do
  if [ -f "$f" ]; then FONT="$f"; break; fi
done
if [ -z "$FONT" ]; then
  echo "no bold sans font found; install dejavu-fonts or run on macOS" >&2
  exit 1
fi

render() {
  local size="$1"
  # Corner radius ~22% of the tile, glyph point-size ~62% of the tile.
  local radius pt
  radius=$(awk "BEGIN{printf \"%d\", $size*0.22}")
  pt=$(awk "BEGIN{printf \"%d\", $size*0.62}")

  # Render at 4x then downsample for clean antialiasing at small sizes.
  local scale=$((size * 4))
  local sradius=$((radius * 4))
  local spt=$((pt * 4))

  magick -size "${scale}x${scale}" xc:none \
    -fill "$BG" \
    -draw "roundrectangle 0,0 $((scale-1)),$((scale-1)) ${sradius},${sradius}" \
    -font "$FONT" -pointsize "$spt" -fill "$FG" -gravity center \
    -annotate +0+0 "n" \
    -resize "${size}x${size}" \
    -depth 8 -strip \
    "${OUT_DIR}/icon-${size}.png"
  echo "wrote ${OUT_DIR}/icon-${size}.png (${size}x${size})"
}

render 16
render 48
render 128
