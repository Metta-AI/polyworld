# Fast XP server

A synchronous Mummy API for Gota, Paintbot and Archers Warriors Mages. Send `player.source` for BASIC text, `player.package_base64` for a ZIP upload,
and `player.policy_ref` for submitted opponents (exact `name:vN` or version UUID).
The server returns a replay and logs only for uploaded seats.

## Run locally

From the Polyworld repository, with pinned dependencies present:

```sh
nix develop .. --command nim c coworld/fast_xp/gota_worker.nim
nix develop .. --command nim c coworld/fast_xp/server.nim
nix develop .. --command ./coworld/fast_xp/server
```

The server binds to localhost by default. To fetch submitted policies, supply
`FAST_XP_OBSERVATORY_TOKEN` in the server environment. Personal team tokens also
need `FAST_XP_OBSERVATORY_ELEVATED=1`; scoped machine credentials do not. Uploaded
bots and the dashboard work without an Observatory credential. The server does
not automatically load the Softmax CLI's saved credentials.
The Nix development shell must include OpenSSL development libraries
(`openssl` in its packages) for the server's HTTPS client.

Open `/docs/llms.txt` for the agent documentation entry point, or read the
[run guide](docs/run.md). `GET /healthz` returns `ok`.

## Configuration

- `FAST_XP_HOST`: bind address, default `127.0.0.1`.
- `FAST_XP_PORT`: port, default `8080`.
- `FAST_XP_WORKERS`: optional override for simultaneous game processes, range 1–256. By default the server detects available logical CPUs at startup, capped at 256. Every game worker runs at nice +10; the API keeps its normal priority. Up to 16 requests may be admitted, using 24 HTTP threads.
- `FAST_XP_TOKEN`: bearer token for callers of this server; required for non-loopback binding.
- `FAST_XP_GOTA_WORKER`: executable path, default `gota_worker` beside server.
- `FAST_XP_GAMES`: optional comma-separated list, `gota,paintbot-pw,awm`. By default all installed game commands are enabled. All routes share the same worker pool and admission limit.
- `FAST_XP_GOTA_COMMAND`: optional JSON argument array for a production Gota runner; overrides `FAST_XP_GOTA_WORKER`.
- `FAST_XP_PAINTBOT_COMMAND`: JSON argument array for Paintbot's unmodified production host and engine. No custom Paintbot worker is needed.
- `FAST_XP_AWM_COMMAND`: optional JSON argument array for the unmodified AWM Coworld executable; defaults to `awm` beside server.
- `FAST_XP_EXECUTION_SECONDS`: per-game deadline excluding queue time, default 120 for Gota or 300 for Paintbot; range 1–3600.
- `FAST_XP_BUILD_REVISION`: release identifier shown in dashboard metadata and startup logs.
- `FAST_XP_OBSERVATORY_URL`: API root, default `https://softmax.com/api/observatory`.
- `FAST_XP_OBSERVATORY_TOKEN`: server-side credential for policy downloads, separate from `FAST_XP_TOKEN`.
- `FAST_XP_OBSERVATORY_ELEVATED`: `1` for personal team tokens, unset for scoped machine credentials.
- `FAST_XP_CACHE_DIR`: private artifact cache, default `$XDG_CACHE_HOME/polyworld-fast-xp/policies` (normally `~/.cache/...`).

The hosted service binds to loopback behind Tailscale Serve and leaves
`FAST_XP_TOKEN` unset; Tailscale controls access. Use a trusted TLS proxy for remote access. The shared fast-XP token does not
identify Observatory users. Policy-reference seats never expose source or logs,
even when the caller owns the policy. The worker inherits only runtime paths,
not the server's credentials.

Each request resolves each distinct selected policy reference once through
Observatory, including on warm-cache requests. Verified artifact bytes are cached
by SHA-256; no credentials, signed URLs or reference-to-source mappings are
persisted. Cache hits are checked against the expected size and hash; corrupt
entries are fetched again. Concurrent requests for the same content share a
download within this server process. Cache directories/files are private to the
local user. Remove the cache directory while the server is stopped to reclaim
space or force cold downloads; there is no automatic eviction yet.

The adapter accepts raw BASIC and production ZIP policy packages up to the
game's 16 MiB package limit. The production loader reads exactly one `.bas` file
and its bundled resources; Gota still limits BASIC source to 64 KiB. Native neural
runners consume the model files without a player container. HTTP fetches have a 10-second socket timeout and do not follow
redirects. Artifact downloads never carry the Observatory authorization headers.

## Dashboard

Open `/` for the dark performance dashboard. `GET /v1/metrics?minutes=60`
returns its JSON data; supported windows are 15, 60 and 1440 minutes. The hosted
service uses Tailscale access, with no additional caller token.

Counters and latency histograms use fixed one-minute buckets, and host samples
are collected every five seconds. Both retain 24 hours in memory, resetting on
restart; the latest 100 game outcomes are retained for at most 24 hours. Chart
responses return at most 1441 host samples. Percentiles are approximate upper
bounds from 25%-wide histogram buckets. Successful single-request, batch-request,
and game durations are separate; failures and timeouts have their own counters.
A batch returning HTTP 200 can still contain failed games.
The latency chart marks each minute with completed games; dashed lines connect
idle gaps for readability. They are not latency measurements during idle time.

Request time excludes client upload/download. Preparation includes policy lookup,
artifact fetching and staging. Game execution includes subprocess startup and
artifact generation, not just simulation ticks. Memory is the service's cgroup
usage, including child workers; CPU is host utilization. Unsupported host counters
appear as unavailable. The EC2 instance type is read from DMI at startup, so it
updates after an instance resize/restart without a hardcoded deployment label.
It is unavailable on local machines or when DMI cannot be read. The dashboard does not alter worker counts or save metrics
to disk. It exposes no policy names, bot contents, logs, credentials or artifact URLs.

## Checks

```sh
nix develop .. --command nim check coworld/fast_xp/server.nim
nix develop .. --command nim r tests/test_fast_xp_metrics.nim
nix develop .. --command nim r tests/test_fast_xp_api.nim
nix develop .. --command nim r tests/test_fast_xp_queue.nim
```

Build both executables first. The Nim API tests run a local mock Observatory/artifact
service, so they need neither a real token nor external network access. The queue
tests use a Nim worker fixture and exercise the real 120-second execution deadline.

For a real full-match cold/warm benchmark, run
`nim r tests/bench_fast_xp.nim --output:/path/to/new-results` inside the Nix
shell, with the same credential environment variables as the server. It runs
three cold/warm pairs and checks repeated replay bytes. Options include
`--repetitions:3`, `--cpu:0`, and `--expected-replay-sha256:HASH` to compare against
a reference from the same game revision; older Gota versions have different replays.

The worker imports the production Gota executable entry point; it shares package
loading, neural runners and scoring rather than maintaining a separate game path.
Build with the committed dependency versions. For an isolated build, set
`POLYWORLD_DEPS` to a dedicated directory and run
`nim r coworld/tools/sync_dependencies.nim` in the workspace Nix shell first.

## Paintbot

Use an unmodified Paintbot release checkout. Build the ordinary production engine
with that release's dependencies, as its Dockerfile does:

```sh
cd /path/to/paintbot-pw
nim c -d:coworld -o:/path/to/paintbot examples/paintbot/paintbot.nim
```

Configure the existing runtime host, using Python 3 supplied by the deployment:

```sh
export FAST_XP_PAINTBOT_COMMAND='["python3","/path/to/paintbot-pw/coworld/paintbot/runtime/host.py","--engine","/path/to/paintbot"]'
```

Keep `host.py`, `seats.py`, `neural_package.py` and `oracle.py` together from the
same release. They are existing game runtime files, not fast-XP implementations.
Local staged files do not require boto3 or AWS credentials in the game process.
Fast-XP supplies the Coworld file handoff with verified hashes, disables pacing
and oracle calls, and gives each engine an ephemeral loopback contract port.
When the game publishes results or a player failure, fast-XP terminates its
process group and collects outputs. Worker temporary files stay inside the
request directory and are removed on completion or timeout.

Install `gota_worker` beside the server as usual to serve both games.
`GET /docs/llms.txt` describes every enabled game; per-game references are at
`/docs/gota/run.md`, `/docs/paintbot-pw/run.md` and `/docs/awm/run.md`. Metrics report installed
games and identify each recent game with its name and seat count.

For the Paintbot integration test, also compile the stock headless executable
(without `-d:coworld`) and set `FAST_XP_PAINTBOT_REPLAY` to its path. Run
`nim r tests/test_fast_xp_paintbot.nim /path/to/current-policy.zip`. This tests both
routes together, private log filtering, neural uploads, batching, deterministic
replays and every replay tick hash. Use `nim r tests/bench_paintbot.nim
--source:/path/to/base.bas --output:/path/to/new-results` for three full requests
through the configured production runner. Pure simulation timing is reported
only when the game itself supplies it; Paintbot's stock runner does not.

## Archers Warriors Mages

Build the stock Coworld executable, as `coworld/awm/compose.yaml` does:

```sh
nim c -d:coworld -o:coworld/fast_xp/awm examples/awm/src/awm.nim
```

It is detected beside the server, or can be selected with `FAST_XP_AWM_COMMAND`.
The API uses the linked league's Competition variant: five players, seeded
classes, 28,800 actions maximum. No game source changes or adapter executable
are required. Build the ordinary headless executable for replay verification,
set `FAST_XP_AWM_REPLAY`, and run `nim r tests/test_fast_xp_awm.nim` with all three
game commands installed. That check covers production rosters, uploaded ZIPs,
private-policy log filtering, deterministic repeats, ten-game batches and every
replay action hash.
