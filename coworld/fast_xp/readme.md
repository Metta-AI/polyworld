# Fast XP server

Mummy API accepting an XP-request-style roster with inline `player.source` for
caller-supplied BASIC bots and `player.policy_ref` for opponents. Each player
specifies exactly one. Inline-only rosters run locally; selected references
return HTTP 501 until authorized bot fetching is implemented.

The native child-process runner reuses Coworld replay/log capture without a
container or child HTTP server. It returns logs only for inline-source seats;
policy-reference seats never expose logs, regardless of policy ownership.

From the Polyworld repository:

```sh
nimby sync nimby.lock
nix develop .. --command nim c coworld/fast_xp/gota_worker.nim
nix develop .. --command nim r coworld/fast_xp/server.nim
```

Open `/docs/llms.txt` for the agent documentation entry point, or read
[the run guide](docs/run.md). Documentation is embedded at compile time.
`GET /healthz` returns `ok`.

Environment:

- `FAST_XP_HOST`: bind address, default `127.0.0.1`.
- `FAST_XP_PORT`: port, default `8080`.
- `FAST_XP_WORKERS`: concurrent matches, default `2`, range 1–256.
- `FAST_XP_TOKEN`: shared bearer token; required for non-loopback binding.
- `FAST_XP_GOTA_WORKER`: executable path, default `gota_worker` beside server.

Use a trusted TLS proxy for remote access. The shared token gates this prototype;
it does not identify Observatory users or authorize access to submitted bots.
No submitted-policy fetching or caching is implemented. See `fetchPolicySource`
in server.nim for the TODO boundary.

Run the integration checks after building both executables:

```sh
nix develop .. --command nim c coworld/fast_xp/server.nim
nix develop .. --command python3 coworld/fast_xp/test_api.py
```
