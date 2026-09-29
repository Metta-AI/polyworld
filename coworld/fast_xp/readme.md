# Fast XP server

A synchronous Mummy API for Gota. Send inline `player.source` for your BASIC bot
and `player.policy_ref` for submitted opponents (exact `name:vN` or version UUID).
The native worker returns a replay and logs only for inline-source seats.

## Run locally

From the Polyworld repository, with pinned dependencies present:

```sh
nix develop .. --command nim c coworld/fast_xp/gota_worker.nim
nix develop .. --command nim c coworld/fast_xp/server.nim
/path/to/metta/.venv/bin/python coworld/fast_xp/run_local.py
```

The Python interpreter for `run_local.py` must have the Softmax CLI installed.
The launch script uses `softmax.auth.load_user_token` to load your saved personal
credential for `https://softmax.com/api`, enables team elevation, and starts the
server. It does not print the token or select a player credential. Sign in with
your user account using the Softmax CLI first. The server binds to localhost by
default. The Nix development shell must include OpenSSL development libraries
(`openssl` in its packages) for the server's HTTPS client.

Alternatively, supply `FAST_XP_OBSERVATORY_TOKEN` in the server environment and
start `coworld/fast_xp/server` directly. Personal team tokens also need
`FAST_XP_OBSERVATORY_ELEVATED=1`; scoped machine credentials do not. The launcher
preserves explicitly supplied token/elevation settings.

Open `/docs/llms.txt` for the agent documentation entry point, or read the
[run guide](docs/run.md). `GET /healthz` returns `ok`.

## Configuration

- `FAST_XP_HOST`: bind address, default `127.0.0.1`.
- `FAST_XP_PORT`: port, default `8080`.
- `FAST_XP_WORKERS`: simultaneous requests (fetching plus matches), default `2`, range 1–256.
- `FAST_XP_TOKEN`: bearer token for callers of this server; required for non-loopback binding.
- `FAST_XP_GOTA_WORKER`: executable path, default `gota_worker` beside server.
- `FAST_XP_OBSERVATORY_URL`: API root, default `https://softmax.com/api/observatory`.
- `FAST_XP_OBSERVATORY_TOKEN`: server-side credential for policy downloads, separate from `FAST_XP_TOKEN`.
- `FAST_XP_OBSERVATORY_ELEVATED`: `1` for personal team tokens, unset for scoped machine credentials.
- `FAST_XP_CACHE_DIR`: private source cache, default `$XDG_CACHE_HOME/polyworld-fast-xp/policies` (normally `~/.cache/...`).

Use a trusted TLS proxy for remote access. The shared fast-XP token does not
identify Observatory users. Policy-reference seats never expose source or logs,
even when the caller owns the policy. The worker inherits only runtime paths,
not the server's credentials.

Each request resolves each distinct selected policy reference once through
Observatory, including on warm-cache requests. Verified source bytes are cached
by SHA-256; no credentials, signed URLs or reference-to-source mappings are
persisted. Cache hits are checked against the expected size and hash; corrupt
entries are fetched again. Concurrent requests for the same content share a
download within this server process. Cache directories/files are private to the
local user. Remove the cache directory while the server is stopped to reclaim
space or force cold downloads; there is no automatic eviction yet.

The initial adapter accepts BASIC source files up to 1 MiB, not policy packages
or containers. HTTP fetches have a 10-second socket timeout and do not follow
redirects. Artifact downloads never carry the Observatory authorization headers.

## Checks

```sh
nix develop .. --command nim check coworld/fast_xp/server.nim
nix develop .. --command python3 coworld/fast_xp/test_api.py
```

Build both executables first. The API tests run a local fake Observatory/artifact
service, so they need neither a real token nor external network access.

For a real full-match cold/warm benchmark, see `benchmark_local.py --help`. It
uses the same saved personal token and verifies the known reference replay.
