# Run a Gota match

POST `/v1/games/gota/run` with `Content-Type: application/json`.
Supply `Authorization: Bearer <token>` when the operator has configured a token.
This is a server-specific shared token, not an Observatory token. Unauthenticated
use is supported only when the server binds to loopback.

The JSON object contains:

- `seed`: required signed 32-bit integer, recorded in the replay.
- `players`: exactly ten objects in seat order (0–9), each with `source`: BASIC
  text, 1–65536 UTF-8 bytes. All policies are supplied by the caller, so all ten
  logs are returned. No policy references, file paths, or download URLs are accepted.
- `config`: optional object with `max_ticks` (1–28800, default 28800 battle ticks
  at 24 ticks/second). Draft time is additional. Other game settings use the
  compiled Gota defaults. Unknown fields are errors.

Only Gota is supported. The route leaves room for other game names later.

## Complete Python example

Run from a directory containing `my-bot.bas`. This uses only Python's standard
library. Set FAST_XP_URL to the server's origin and FAST_XP_TOKEN if required.

```python
import json
import os
from pathlib import Path
import urllib.request

base = os.environ.get("FAST_XP_URL", "http://127.0.0.1:8080")
source = Path("my-bot.bas").read_text()
body = {
    "seed": 743478993,
    "players": [{"source": source} for _ in range(10)],
}
headers = {"Content-Type": "application/json"}
if token := os.environ.get("FAST_XP_TOKEN"):
    headers["Authorization"] = "Bearer " + token
request = urllib.request.Request(
    base + "/v1/games/gota/run",
    data=json.dumps(body).encode(), headers=headers, method="POST",
)
with urllib.request.urlopen(request, timeout=180) as response:
    Path("gota.zip").write_bytes(response.read())
```

HTTP 200 returns `application/zip` containing `replay.replay` and
`logs/slot-0.txt` through `logs/slot-9.txt`. Bot source and internal result files
are not included. Save binary responses as bytes. The replay uses Polyworld's
existing replay format. Use a compatible Polyworld viewer to inspect it.
`Server-Timing` reports server validation, staging, game execution, and ZIP
creation in milliseconds; it excludes request upload and response transfer.

There is no polling endpoint or durable job history. Requests execute fresh
matches, even when repeated. A dropped connection does not currently cancel an
admitted match; retrying can duplicate computation. The worker has a 120-second
execution deadline. Allow additional client/proxy time for transfers.

## Errors and concurrency

Errors use JSON `{"error": "message"}`:

- 400: invalid JSON, unsupported fields, or invalid roster/configuration.
- 401: missing or incorrect configured bearer token.
- 404/405: unknown route or wrong method (405 can be plain text).
- 413: request exceeds the HTTP server's 4 MiB body limit.
- 415: content type is not application/json.
- 422: a bot failed to compile; the error identifies its seat and diagnostic.
- 503: match capacity is full; honor `Retry-After` and retry with backoff.
- 504: worker exceeded its execution deadline.
- 500: worker or server failed; consult the operator.

Runtime bot errors retain the game's existing behavior: disable that bot and
record its error in its log. A match can return 200 with disabled bots; inspect
logs before treating it as a valid performance benchmark.

For multiple matches, use bounded concurrent POST requests. There is no batch
submission, idempotency key, external policy fetching, or result persistence.
