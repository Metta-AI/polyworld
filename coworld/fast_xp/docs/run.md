# Gota run API

POST `/v1/games/gota/run` with `Content-Type: application/json`.

Supply your bot's BASIC source to iterate without uploading a policy version.
Use policy references for opponents:

```json
{
  "seed": 743478993,
  "roster": [
    {"slot": 0, "player": {"source": "print selfId\nend"}},
    {"slot": -1, "player": {"policy_ref": "109b99c1-3bb7-4276-b17e-378b43a97874"}}
  ],
  "config": {"max_ticks": 28800}
}
```

Policy references are resolved through Observatory using the server's credential.
Use `source` for BASIC text (up to 64 KiB), `package_base64` for an uploaded ZIP
(up to 16 MiB before base64 encoding), or `policy_ref` for a submitted policy version.
`package_base64` uses standard padded base64 without whitespace and Gota’s normal
policy format. The roster accepts 1–10 entries; the JSON request limit is 224 MiB.
The server downloads and runs referenced artifacts (up to 16 MiB).
The UUID above selects Richard's public benchmark policy. Both mixed and
inline-only rosters run locally.
For example, `"roster": [{"player": {"source": "print selfId\nend"}}]`
uses the supplied script in all ten seats. Supply a complete BASIC bot to play
competitively; the short example only prints its ID.

- Each `player` requires exactly one of `source`, `package_base64`, or `policy_ref`.
- `source`: nonempty BASIC source text, preserved as supplied. Its seat's logs
  are returned to this request; no submitted-policy ownership lookup is needed.
- `policy_ref`: a submitted policy label such as `my-bot:v12`, or a policy-version
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

The hosted service uses Tailscale for access. Callers do not need an API token
or an Authorization header. Submitted-policy fetching uses the server's configured
Observatory credential (an elevated personal team token locally, or a scoped
machine credential); request-supplied bots determine log visibility.

A successful response is `application/zip`, containing `replay.replay` and
`logs/slot-N.txt` for each seat populated from `source` or `package_base64`. No bot source files
are included. Policy-reference seats never contribute logs to the response.
There is no polling endpoint. `Server-Timing` reports total request processing time, policy resolution/fetching,
worker execution, and ZIP packaging in milliseconds. Fetching includes cache
verification; worker execution includes compilation, gameplay, replay and logs.

## Errors

Errors use JSON `{"error": "message"}` unless noted:

- 400: invalid JSON, roster, configuration, or unsupported fields.
- 404: unknown route or policy version.
- 405: wrong method (can be plain text).
- 409: policy version has no downloadable player file.
- 413: JSON request exceeds 224 MiB, or an uploaded package exceeds 16 MiB.
- 415: content type is not application/json.
- 422: Policy loading or BASIC compilation failed; details are included only for uploaded seats.
- 500: game worker failed.
- 502: Observatory rejected the server credential, a fetch failed, or downloaded
  bytes did not match the expected size/hash. Policy artifacts must be raw BASIC or ZIP packages
  of at most 16 MiB. The error message identifies the failing stage without
  exposing credentials, source or signed URLs.
- 503: all workers are busy, or the server has no Observatory credential for
  reference fetching. Busy requests may retry after the `Retry-After` interval;
  missing credentials require server configuration.
- 504: a policy fetch timed out or the match exceeded its 120-second execution deadline.

GET `/healthz` and `/docs/llms.txt` remain available.
