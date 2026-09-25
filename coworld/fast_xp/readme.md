# Fast XP server

Minimal Mummy HTTP entry point for the XP-request service. Match execution,
policy fetching, caching, and authentication are not implemented yet.

From the Polyworld repository in its Nimby workspace:

```sh
nimby sync nimby.lock
nix develop .. --command nim r coworld/fast_xp/server.nim
```

The server defaults to `127.0.0.1:8080`. Set `FAST_XP_HOST` and `FAST_XP_PORT`
to choose another address. Stop it with Ctrl+C.

```sh
curl http://127.0.0.1:8080/healthz
```

`GET /healthz` returns `200` with `ok`. Other methods on that path return
`405`, and unknown paths return `404`.
