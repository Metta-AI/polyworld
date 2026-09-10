#!/usr/bin/env bash
set -euo pipefail
tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../tools" && pwd)"
exec nim r --hints:off --out:"$tool_dir/build_replay_viewer_lvd" \
  --nimcache:"$tool_dir/../../tmp/coworld/tool-cache/lvd" \
  "$tool_dir/build_replay_viewer.nim" lvd "$1"
