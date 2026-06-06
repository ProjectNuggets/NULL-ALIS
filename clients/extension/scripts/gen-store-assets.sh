#!/usr/bin/env bash
# Reproducible Chrome Web Store promo-asset generator for the nullalis
# extension.
#
# Produces store/assets/promo-440x280.png: the CWS "small promo tile"
# (440×280) in the nullalis brand purple with the white "n" brand mark and
# the "nullalis" wordmark, reusing the styling of scripts/gen-icons.sh.
#
# Run from the extension root: `bash scripts/gen-store-assets.sh`. Requires
# ImageMagick 7 (`magick`), same as gen-icons.sh. The output PNG is committed,
# so a contributor without ImageMagick still has the asset; re-run only when
# the brand mark changes.
set -euo pipefail

OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/store/assets"
mkdir -p "$OUT_DIR"

BG="#5B3DF5"      # nullalis brand purple (matches gen-icons.sh)
FG="#FFFFFF"      # wordmark white

# Same font-discovery fallback chain as gen-icons.sh so the script is
# reproducible on Linux CI and macOS dev boxes alike.
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

W=440
H=280
SCALE=3                       # render at 3x, downsample for clean edges
SW=$((W * SCALE))
SH=$((H * SCALE))

# Layout (at full scale): a rounded-square white tile with a purple "n" on the
# left, the white "nullalis" wordmark to its right — the toolbar icon's visual
# language, blown up for the store tile. The tile and the wordmark are each
# built off-canvas and composited at exact offsets so placement is predictable
# regardless of font-metric quirks.
TILE=$((120 * SCALE))
TILE_RADIUS=$(awk "BEGIN{printf \"%d\", $TILE*0.22}")
TILE_X=$((44 * SCALE))
TILE_Y=$(((SH - TILE) / 2))
GLYPH_PT=$(awk "BEGIN{printf \"%d\", $TILE*0.62}")

WORD_PT=$((46 * SCALE))
WORD_X=$((192 * SCALE))           # left edge of the wordmark block
WORD_W=$((204 * SCALE))           # wordmark block width
WORD_H=$((70 * SCALE))            # wordmark block height
WORD_Y=$(((SH - WORD_H) / 2))     # vertically centered

# 1) brand-purple field
# 2) white rounded tile carrying a purple "n" (glyph clipped to the tile)
# 3) the white "nullalis" wordmark, centered in its own transparent block so
#    its vertical position is exact
magick -size "${SW}x${SH}" "xc:${BG}" \
  \( -size "${TILE}x${TILE}" xc:none \
       -fill "$FG" -draw "roundrectangle 0,0 $((TILE-1)),$((TILE-1)) ${TILE_RADIUS},${TILE_RADIUS}" \
       -font "$FONT" -fill "$BG" -pointsize "$GLYPH_PT" -gravity center -annotate +0+0 "n" \) \
  -gravity NorthWest -geometry "+${TILE_X}+${TILE_Y}" -compose over -composite \
  \( -size "${WORD_W}x${WORD_H}" xc:none \
       -font "$FONT" -fill "$FG" -pointsize "$WORD_PT" -gravity West -annotate +0+0 "nullalis" \) \
  -gravity NorthWest -geometry "+${WORD_X}+${WORD_Y}" -compose over -composite \
  -resize "${W}x${H}" \
  -depth 8 -strip \
  "${OUT_DIR}/promo-440x280.png"

echo "wrote ${OUT_DIR}/promo-440x280.png (${W}x${H})"
