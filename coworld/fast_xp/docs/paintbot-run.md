# Paintbot run API

Start with [/docs/llms.txt](/docs/llms.txt) for the complete request and response
contract. POST /v1/games/paintbot-pw/run runs the native Paintbot teams game with
16 interleaved red/blue seats, glory behind_cogs=10 and behind_lives=5, the
default map and vision, and no external oracle.

## Packages

Use the same files you submit to Paintbot: raw BASIC or a ZIP containing exactly
manifest.json, policy.bas and model.bin. The production neural manifest schemas
paintbot-neural-basic/1 and paintbot-neural-basic/2 are supported. Contracts,
hashes, decoder settings and models are validated by the worker.

Limits are 128 KiB source, 16 MiB model and 8 KiB manifest, with 4 KiB additional
ZIP overhead. The complete package limit is 16920576 bytes; base64 encoding is
additional. JSON bodies are limited to 352 MiB. Encrypted, duplicate, extra,
oversized or corrupt ZIP entries are rejected. Archive paths are never extracted.

Initialization failures follow Paintbot's seat-forfeit behavior; check your
uploaded seat logs. BASIC compilation failures and worker failures fail that
game. Referenced seats' diagnostics are never returned. No response includes
bot source files, model files, credentials or artifact download URLs.

## Errors and timing

Errors use {"error":"message"}. 400 means invalid input, 404 an unknown route or
policy, 409 a policy without a downloadable file, 413 an oversized request or
upload, 415 the wrong content type, and 422 a policy compilation failure. 500
means the worker failed; 502 an upstream authorization/download/integrity failure;
503 means shutdown or missing server credentials; 504 means a fetch or game
execution timeout. 429 includes Retry-After when all 16 request admissions are used.

Each batch resolves its references once and caches verified artifacts by hash.
The worker duration includes process startup, staging, simulation and artifact
writing. It is not pure simulation time. Total server time excludes client
upload/download. Accepted work finishes even if the caller disconnects.

There are no automatic retries. Successful games in a batch remain available
when another game fails. Temporary files are removed after packaging.
