#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
polyworld_repo="${POLYWORLD_REPO:-$project_dir/../..}"
web_dir="${AWM_WEB_DIR:-$project_dir/build/web}"
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
    echo "AWM requires Nim 2.2.10 or later. Set NIM to a supported compiler." >&2
    exit 1
  fi
fi
if [[ ! -f "$polyworld_repo/src/polyworld/common.nim" ]]; then
  echo "Set POLYWORLD_REPO to the Polyworld repository containing src/polyworld/." >&2
  exit 1
fi
polyworld_repo="$(cd -- "$polyworld_repo" && pwd)"
data_dir="$(dirname -- "$polyworld_repo")/polyworld_data"
mkdir -p "$web_dir"
web_dir="$(cd -- "$web_dir" && pwd)"
stage_dir="$web_dir/assets"

# Keep the downloadable asset pack small. Screenshots, source prompts and the
# unrelated Polyworld games' models are deliberately outside the package.
mkdir -p "$stage_dir/polyworld_data/characters/mini_legion/human"
mkdir -p "$stage_dir/polyworld_data/fonts" "$stage_dir/polyworld_data/themes"
mkdir -p "$stage_dir/polyworld_data/awm/cards" "$stage_dir/polyworld_data/awm/vfx" \
  "$stage_dir/polyworld_data/awm/ui"
for character in archer footman mage; do
  cp "$data_dir/characters/mini_legion/human/$character.glb" \
    "$stage_dir/polyworld_data/characters/mini_legion/human/"
done
cp "$data_dir/characters/mini_legion/human/human_albedo.png" \
  "$stage_dir/polyworld_data/characters/mini_legion/human/"
for font in Rubik-Regular.ttf Rubik-Bold.ttf; do
  cp "$data_dir/fonts/$font" "$stage_dir/polyworld_data/fonts/"
done
cp -R "$data_dir/themes/main" "$stage_dir/polyworld_data/themes/"
cp -R "$data_dir/ui" "$stage_dir/polyworld_data/"
mkdir -p "$stage_dir/polyworld_data/icons"
cp "$data_dir"/icons/*.png "$stage_dir/polyworld_data/icons/"
for directory in art fonts frames icons; do
  cp -R "$data_dir/awm/cards/$directory" "$stage_dir/polyworld_data/awm/cards/"
done
cp -R "$data_dir/awm/vfx/textures" "$stage_dir/polyworld_data/awm/vfx/"
cp -R "$data_dir/awm/ui/hud" "$stage_dir/polyworld_data/awm/ui/"

if [[ -d "$project_dir/players" ]]; then
  mkdir -p "$stage_dir/players"
  cp "$project_dir"/players/*.bas "$stage_dir/players/" 2>/dev/null || true
fi

cd "$project_dir"
POLYWORLD_REPO="$polyworld_repo" AWM_WEB_DIR="$web_dir" \
  "$nim_command" c -d:emscripten "$@" awm.nim
echo "Browser game built: $web_dir/awm.html"
