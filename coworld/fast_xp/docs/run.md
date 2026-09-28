# Gota run API

POST `/v1/games/gota/run` with `Content-Type: application/json`.

Supply your bot's BASIC source to iterate without uploading a policy version.
Use policy references for opponents:

```json
{
  "seed": 743478993,
  "roster": [
    {"slot": 0, "player": {"source": "print selfId\nend"}},
    {"slot": -1, "player": {"policy_ref": "relh:v231"}}
  ],
  "config": {"max_ticks": 28800}
}
```

**Policy fetching is still a TODO: requests selecting a `policy_ref` return
HTTP 501 before starting a match. Inline-only rosters run locally now.**
For example, `"roster": [{"player": {"source": "print selfId\nend"}}]`
uses the supplied script in all ten seats. Supply a complete BASIC bot to play
competitively; the short example only prints its ID.

- Each `player` requires exactly one of `source` or `policy_ref`.
- `source`: nonempty BASIC source text, preserved as supplied. Its seat's logs
  are returned to this request; no submitted-policy ownership lookup is needed.
- `policy_ref`: a submitted policy label such as `relh:v231`, or a policy-version
  UUID. These entries are opponents: their source, logs, and compilation details
  are private even if the caller happens to own the submitted policy.
- `slot`: 0–9 pins a Gota seat; -1 (the default) supplies an entry for open seats.
  Remaining seats are filled in ascending seat order, cycling through open
  entries in roster order. Duplicate pinned seats and uncovered seats without
  an open entry fail. A pinned entry is not also used to fill open seats.
- `seed`: required signed 32-bit integer.
- `config.max_ticks`: optional battle tick limit, 1–28800, default 28800
  (20 simulated minutes at 24 ticks/second, plus drafting).

File paths, download URLs, `random`, and `top_n` selectors are not supported.
Unknown fields, NUL characters, and empty source/reference strings are rejected.
This is a single-game endpoint, not the full XP-request target/batch interface.

## Authentication and output

Supply `Authorization: Bearer <token>` when FAST_XP_TOKEN is configured. This is
currently a server-specific shared token, not Observatory user authentication.
Non-loopback binding requires a token. Submitted-policy fetching will use the
runner's service credential; request-supplied source determines log visibility.

A successful response is `application/zip`, containing `replay.replay` and
`logs/slot-N.txt` for each seat populated from inline source. No bot source files
are included. Policy-reference seats never contribute logs to the response.
There is no polling endpoint. `Server-Timing` reports request processing time.

## Errors

Errors use JSON `{"error": "message"}` unless noted:

- 400: invalid JSON, roster, configuration, or unsupported fields.
- 401: missing or incorrect configured bearer token.
- 404/405: unknown route or wrong method (405 can be plain text).
- 413: request exceeds the HTTP server's 4 MiB body limit, including all sources.
- 415: content type is not application/json.
- 422: BASIC compilation failed; details are included only for inline-source seats.
- 500: game worker failed.
- 501: selected policy references cannot be fetched yet. Retrying will not help.
- 503: all workers are busy; retry after the `Retry-After` interval.
- 504: the match exceeded its execution deadline.

GET `/healthz` and `/docs/llms.txt` remain available.
