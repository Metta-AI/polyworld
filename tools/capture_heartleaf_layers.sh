#!/bin/sh
# Render the reference layers from actual game geometry without opening windows.
set -eu
cd "$(dirname "$0")/.."
output="${1:-tmp/heartleaf-layers}"
mkdir -p "$output"
unset CAM_DIST CAM_X CAM_Z SIM_SECONDS
nim c --hints:off --nimcache:tmp/heartleaf-town/cache-layers \
  -d:takeScreenshot -d:sceneCapture \
  --out:tmp/heartleaf-town/layers examples/heartleaf/heartleaf.nim
for entry in ground:01-grass-and-paths buildings:02-buildings \
  vegetation:03-trees-and-vegetation props:04-props all:05-assembled; do
  layer="${entry%%:*}"
  name="${entry#*:}"
  HEARTLEAF_LAYER="$layer" SCREENSHOT_PATH="$output/$name-3d.png" \
    tmp/heartleaf-town/layers \
    --bot examples/heartleaf/players/base.bas:9 \
    --seek-tick 1500 --play=false --windowSize 1122x1402 \
    > "$output/$layer.log" 2>&1
done

# Compare the unchanged references and game captures when ImageMagick is present.
if command -v magick >/dev/null 2>&1; then
  reference=../polyworld_art/terrain/heartleaf/layers
  for entry in 01-grass-and-paths:Ground 02-buildings:Buildings 03-trees-and-vegetation:Vegetation 04-props:Props; do
    name="${entry%%:*}"
    label="${entry#*:}"
    magick "$reference/$name.png" -background '#171d17' -alpha remove -alpha off \
      -gravity north -background '#171d17' -splice 0x64 \
      -font Arial -pointsize 30 -fill '#e8eadf' -annotate +0+15 "2D reference | $label" \
      "$output/$name-2d-panel.png"
    magick "$output/$name-3d.png" -background '#171d17' -alpha remove -alpha off \
      -gravity north -background '#171d17' -splice 0x64 \
      -font Arial -pointsize 30 -fill '#e8eadf' -annotate +0+15 "3D game geometry | $label" \
      "$output/$name-3d-panel.png"
    magick "$output/$name-2d-panel.png" "$output/$name-3d-panel.png" +append \
      "$output/$name-comparison.png"
  done
  magick "$reference/01-grass-and-paths.png" "$reference/02-buildings.png" -compose over -composite \
    "$reference/03-trees-and-vegetation.png" -compose over -composite \
    "$reference/04-props.png" -compose over -composite "$output/05-assembled-2d.png"
  magick "$output/05-assembled-2d.png" "$output/05-assembled-3d.png" +append \
    "$output/05-assembled-comparison.png"
  magick montage "$output/01-grass-and-paths-comparison.png" \
    "$output/02-buildings-comparison.png" "$output/03-trees-and-vegetation-comparison.png" \
    "$output/04-props-comparison.png" -tile 2x2 -geometry 1122x733+14+14 \
    -background '#0f140f' "$output/layers-overview.png"
fi
