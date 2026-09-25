# Gota run API

POST `/v1/games/gota/run` with `Content-Type: application/json`.

**Policy resolution and bot fetching are not implemented. Valid requests return
HTTP 501 with a JSON error. No match starts and no replay is produced yet.**

The roster uses the current XP-request shape:

```json
{
  "seed": 743478993,
  "roster": [
    {"slot": 0, "player": {"policy_ref": "my-bot:v12"}},
    {"slot": -1, "player": {"policy_ref": "relh:v231"}}
  ],
  "config": {"max_ticks": 28800}
}
```

- `player.policy_ref`: a submitted policy label such as `relh:v231`, or a
  policy-version UUID. Existence and access checks await the resolver.
- `slot`: 0–9 pins a Gota seat; -1 (the default) selects an entry for open seats.
  Intended behavior follows XP requests: the example pins your bot to seat zero
  and fills remaining seats with Richard's policy. Seat expansion is a TODO.
  Duplicate pinned seats and uncovered seats without an open-seat selector fail.
- `seed`: required signed 32-bit integer.
- `config.max_ticks`: optional battle tick limit, 1–28800, default 28800
  (20 simulated minutes at 24 ticks/second, plus drafting).

Inline sources, file paths, download URLs, `random`, and `top_n` selectors are
not supported. Unknown fields are rejected. This is a single-game endpoint;
it does not yet implement the full XP-request target/batch interface.

## Authentication and output

Supply `Authorization: Bearer <token>` when FAST_XP_TOKEN is configured. This is
currently a server-specific shared token, not Observatory user authentication.
Non-loopback binding requires a token. Caller identity, policy selection access,
and private log authorization remain TODOs alongside fetching.

The intended successful response is `application/zip`, containing
`replay.replay` and only the bot logs the caller may read. Opponent source and
unauthorized logs must stay inside the trusted runner. A reference alone grants
neither source nor log access. There is no polling endpoint.

## Current errors

Errors use JSON `{"error": "message"}` unless noted:

- 400: invalid JSON, roster, configuration, or unsupported fields.
- 401: missing or incorrect configured bearer token.
- 404/405: unknown route or wrong method (405 can be plain text).
- 413: request exceeds the HTTP server's 4 MiB body limit.
- 415: content type is not application/json.
- 501: policy resolution and bot fetching are not implemented. Retrying will not help.

GET `/healthz` and `/docs/llms.txt` remain available.
