#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
polyworld_repo="${POLYWORLD_REPO:-$project_dir/../..}"
web_dir="${CAC_WEB_DIR:-$project_dir/build/web}"
nim_command="${NIM:-nim}"
# Homebrew's preinstalled Emscripten cache may be read-only.
export EM_CACHE="${EM_CACHE:-$project_dir/build/emscripten-cache}"
mkdir -p "$EM_CACHE"

for tool in "$nim_command" emcc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing $tool. Install Nim and Emscripten, then put both on PATH." >&2
    exit 1
  fi
done
nim_version="$("$nim_command" --version)"
if [[ "$nim_version" =~ Version[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
  if (( BASH_REMATCH[1] < 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] < 2) || \
      (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] == 2 && BASH_REMATCH[3] < 10) )); then
    echo "CaC requires Nim 2.2.10 or later. Set NIM to a supported compiler." >&2
    exit 1
  fi
fi
if [[ ! -f "$polyworld_repo/src/polyworld/common.nim" ]]; then
  echo "Set POLYWORLD_REPO to the Polyworld repository containing src/polyworld/." >&2
  exit 1
fi
polyworld_repo="$(cd -- "$polyworld_repo" && pwd)"
art_dir="${POLYWORLD_ART:-$(dirname -- "$polyworld_repo")/polyworld_art}"
if [[ ! -d "$art_dir/cac" ]]; then
  echo "Clone polyworld_art beside Polyworld, or set POLYWORLD_ART." >&2
  exit 1
fi
mkdir -p "$web_dir"
web_dir="$(cd -- "$web_dir" && pwd)"
stage_dir="$web_dir/assets"
art_stage="$stage_dir/polyworld_art"

# The browser displays these before the game asset pack is available. Keep the
# small, flat Polyworld courtyard and logo separate from the wasm preload.
loading_dir="$web_dir/loading"
mkdir -p "$loading_dir"
cp "$project_dir"/web/loading/*.svg "$loading_dir/"
cp "$art_dir/cac/cards/fonts/Grenze-SemiBold.ttf" "$loading_dir/"
cp "$art_dir/cac/cards/fonts/OFL.txt" "$loading_dir/"
cp "$art_dir"/cac/ui/hud/class-*.svg "$loading_dir/"

# Keep the downloadable asset pack small. Screenshots, source prompts and the
# unrelated Polyworld games' models are deliberately outside the package.
rm -rf "$art_stage"
mkdir -p "$art_stage/fonts" "$art_stage/themes" "$art_stage/icons"
mkdir -p "$art_stage/cac/cards" "$art_stage/cac/vfx" \
  "$art_stage/cac/ui" "$art_stage/cac/battlefield"
# Only the CharGen parts, palettes, rig and clips of the six hero looks.
chargen_dir="$art_dir/characters/chargen"
(cd "$project_dir" && "$nim_command" r --hints:off \
  --out:"$web_dir/list_hero_assets" tools/list_hero_assets.nim) |
while IFS= read -r path; do
  mkdir -p "$art_stage/characters/chargen/$(dirname -- "$path")"
  cp "$chargen_dir/$path" "$art_stage/characters/chargen/$path"
done
for font in Rubik-Regular.ttf Rubik-Bold.ttf; do
  cp "$art_dir/fonts/$font" "$art_stage/fonts/"
done
cp -R "$art_dir/themes/main" "$art_stage/themes/"
cp -R "$art_dir/ui" "$art_stage/"
cp "$art_dir"/icons/*.png "$art_stage/icons/"
for directory in fonts frames icons; do
  cp -R "$art_dir/cac/cards/$directory" "$art_stage/cac/cards/"
done
# The game crops every illustration to the card's art window when it loads
# it; stage them cropped already, so the download holds only what is drawn.
(cd "$project_dir" && "$nim_command" r --hints:off \
  --out:"$web_dir/stage_card_art" tools/stage_card_art.nim \
  "$art_dir/cac/cards/art" "$art_stage/cac/cards/art")
cp -R "$art_dir/cac/vfx/textures" "$art_stage/cac/vfx/"
cp -R "$art_dir/cac/ui/hud" "$art_stage/cac/ui/"
cp -R "$art_dir/cac/battlefield/textures" "$art_stage/cac/battlefield/"

if [[ -d "$project_dir/players" ]]; then
  mkdir -p "$stage_dir/players"
  cp "$project_dir"/players/*.bas "$stage_dir/players/" 2>/dev/null || true
fi

cd "$project_dir"
POLYWORLD_REPO="$polyworld_repo" CAC_WEB_DIR="$web_dir" \
  "$nim_command" c -d:emscripten "$@" src/cac.nim
echo "Browser game built: $web_dir/cac.html"
