#!/usr/bin/env bash
# Builds CaC's static replay viewer into OUTPUT, like
# coworld/tools/build_replay_viewer.nim does for the other games: pinned
# dependencies, the pinned art revision, and index.html beside the bundle.
# CaC stages its own browser assets with games/cac/tools/build_web.sh.
set -euo pipefail
output="${1:?Usage: build_replay_viewer.sh OUTPUT}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ "$output" != /* || -L "$output" ]]; then
  echo "Replay bundle output must be an absolute directory, not a symlink" >&2
  exit 1
fi
case "$root/" in
  "$output"/*) echo "Replay bundle output must not contain the repository" >&2
    exit 1 ;;
esac

export POLYWORLD_ART="${POLYWORLD_ART:-$(dirname "$root")/polyworld_art}"
(cd "$root" && nim r --hints:off coworld/tools/sync_dependencies.nim)
expected="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["revision"])' \
  "$root/coworld/assets.json")"
actual="$(git -C "$POLYWORLD_ART" rev-parse HEAD)"
if [[ "$expected" != "$actual" ]]; then
  echo "Asset revision mismatch: expected $expected, got $actual" >&2
  exit 1
fi

build="$root/tmp/coworld/cac-replay-viewer"
CAC_WEB_DIR="$build" POLYWORLD_REPO="$root" \
  "$root/games/cac/tools/build_web.sh" -d:replayViewer
rm -rf "$output"
mkdir -p "$output"
for suffix in js wasm data; do
  cp "$build/cac.$suffix" "$output/cac.$suffix"
done
cp "$build/cac.html" "$output/index.html"
cp "$root/games/cac/web/loading/cnc-wordmark.svg" "$output/loading-logo.svg"
