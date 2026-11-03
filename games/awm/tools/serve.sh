#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
web_dir="${AWM_WEB_DIR:-$project_dir/build/web}"
port="${AWM_PORT:-8080}"

if [[ "$web_dir" != /* ]]; then
  web_dir="$PWD/$web_dir"
fi
export AWM_WEB_DIR="$web_dir"

# Rebuild by default so browser code matches the source.
# AWM_SKIP_WEB_BUILD=1 reuses an already built browser bundle.
if [[ "${AWM_SKIP_WEB_BUILD:-0}" != "1" ]]; then
  "$project_dir/tools/build_web.sh" "$@"
fi

echo "Serving $web_dir on http://127.0.0.1:$port"
echo "Open: http://127.0.0.1:$port/awm.html"
exec python3 -m http.server "$port" --bind 127.0.0.1 --directory "$web_dir"
