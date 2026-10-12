# GotA in Universe

The game executes ten BASIC policies inside its existing native VM loop. Conductor owns the enclosing process,
deadline and result transport. A policy gets its own hero's observation and cannot access another policy's source.

The [host](host.py) accepts Conductor process input, stages the existing Coworld file protocol, and publishes the
result and compressed replay after the native process stops. It accepts raw UTF-8 BASIC up to 1 MiB per seat.
LLM network calls are disabled for this fast profile. The game must finish within 60 seconds of host startup and
within the attempt's outer deadline. A slow interactive coaching variant needs a separate, qualified runtime.

Build the game with `coworld/Dockerfile`, using `GAME=gods_of_the_arena` and `ENTRY=gota`. Build Conductor's runner
artifact independently. Compose them with this directory's Dockerfile, passing `GAME_IMAGE` and `RUNNER_IMAGE`.
Hosted preparation must pin both images by digest. Local development may use explicit local image tags.

Register command `["python3", "/opt/gota/host.py"]`, policy format `basic-source-v1`, and a 60-second outer
budget (including allocation). Publish [world.json](world.json) using the installed runtime's immutable name.
Seat IDs are `seat-0` through `seat-9`; the first five are red and the last five blue.

Private policy logs remain inside the attempt. The public replay excludes policy source and PRINT output.
