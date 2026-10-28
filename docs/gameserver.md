# Polyworld gameserver

The gameserver is a WebSocket switchboard. It knows exact game identities,
participants, seats and ticks. Setup and command payloads are opaque bytes.
It never imports a game simulation, executes a bot, or receives bot programs,
weights or private VM memory. GotA is the first client integration.

## Run locally

Install the repository's locked Nim dependencies, then run from the checkout:

```sh
nim r tools/gameserver.nim --port 9911
nim r examples/gods_of_the_arena/gota.nim --server ws://127.0.0.1:9911/ws
```

The relay defaults to `ws://127.0.0.1:8090/ws`. `BIND` and `PORT` change the
listening address and port; `--port` overrides `PORT`. `GET /healthz` is a
health check. Native and browser
clients use Windy's WebSocket API. The server uses Mummy and one explicit room
event loop. Mummy's workers pass bounded events into that loop.

`--server` opens Multiplayer and connects automatically. Choose human and bot
seats in the lobby. Without `--server`, GotA opens the main menu as usual.

A normal graphical launch opens Single player, Multiplayer and Settings.
Native builds also offer Exit to OS. Single player defaults to one human and
nine base bots. Choose another seat, load local BASIC or ZIP policies, or
spectate ten bots. Match settings expose the existing game configuration.
Explicit `--bot`, `--replay`, headless and Coworld runs bypass the menu.

For the browser build, with Emscripten installed:

```sh
nim c -d:emscripten examples/gods_of_the_arena/gota.nim
python3 -m http.server 8776 --bind 127.0.0.1
```

Open `http://127.0.0.1:8776/examples/gods_of_the_arena/emscripten/gota.html`.
The bundled base policy is in the data bundle. The file picker reads local
`.bas` or policy `.zip` files into WASM memory. It does not upload their bytes.
An HTTPS game page needs a `wss://` relay.

## Rooms and ownership

Clients identify a game name, exact gameplay version, exact game payload
protocol version and display name. The outer binary protocol also has an
exact version. Different identities can use the same server but cannot join
the same room.

The creator chooses public or unlisted visibility, manages settings, removes
lobby participants and starts the match. Invite links include the server and
room identifier, never the reconnect token. Guest tokens are private and
remain only in the running client's memory.

Each participant may own several seats. A participant can bring only bots
and watch them play. Each bot runs solely in its owner's client. Remote seats
have no VM. Roster or settings changes invalidate readiness. All seats must
have an owner and all controlling clients must load the same setup before
Start succeeds. Spectators may join after the match starts.

## Timeline and mandatory hash checks

The server assigns consecutive command sequences to execution ticks in
receipt order. It sends immutable tick packets at the room's tick rate,
including empty packets. GotA uses 24 Hz. Every client applies the same packet
exactly once and never advances without a packet. The server checks seat
ownership and envelope bounds. Each game checks its own payload semantics.

Hash checking cannot be disabled. All controlling clients must agree before
startup. Every simulated second, the server waits for all controller hashes
before producing the next tick. Missing hashes pause progress. A differing
hash stops the match and reports the tick and hash values. Final states must
also agree. Historical hash checkpoints are retained, so a late spectator's
reports are checked against the same history. GotA's network digest includes
its immutable game configuration and its normal replay state digest.

A disconnected controller pauses the room indefinitely. Reconnection restores
the same participant, seats, unacknowledged command sequences and local VMs.
Missing packets are replayed before resuming. Outstanding hash and completion
reports are retransmitted. This supports connection interruptions while the
original application remains open, not browser refreshes or process restarts.
No substitute bots, state repair or silent desync recovery are performed.

Late spectators replay the setup and history without running bots. Slow
spectators do not hold up controllers. Disagreeing spectator hashes still
report a desync and stop the match. This is consistency checking, not
anti-cheat: clients remain trusted to submit their own commands and hashes.

## GotA command results and replays

In multiplayer, an immediate action return means that the command was queued.
It does not promise that the action will succeed when its server tick executes.
The existing BASIC action-result fields update from authoritative execution,
including rejected actions. Offline action returns retain their existing
immediate behavior. Human and local bot actions use the same submission path.
Bot mailbox messages travel in GotA's opaque game payload.

Normal game replays record executed action packets using the existing exact
replay format. Playback does not need the relay, bot source, weights or VM
memory. Use Save replay after a multiplayer match to save it natively or
download it in the browser. There are no historical replay compatibility
branches. The outer protocol is version 3 and the GotA command protocol is version 1;
gameplay rules and replay
format remain unchanged by this transport addition.

## Escape menu and pause

Escape opens Return to game, Pause/Resume match, Settings and Quit to main menu.
Opening it alone leaves the match running. Offline pause stops local simulation.
In multiplayer any controlling participant may pause or resume the room;
spectators cannot. The server stops emitting ticks, preserves pending commands
and retains mandatory hash barriers. Reconnection does not clear a pause.

Settings remain local and are persisted. A live controller quitting explicitly
aborts the match for everyone before leaving the room. Spectators can leave
without ending it. There is no silent controller replacement.

## Limits and failure behavior

The relay limits rooms to 64, guests to 512 and live sockets to 256. A room
supports up to 64 seats and 64 participants. Messages are at most 256 KiB,
setup blobs 64 KiB and individual commands 4 KiB. Each pending tick is bounded
by command count and encoded byte size. Exhausting pending/history capacity
stops the match visibly instead of dropping accepted commands.

History is limited to 128 MiB per room, 512 MiB across rooms, and
345,600 ticks per room. Transport credit is 512 KiB per participant, released
by receipt acknowledgements. Incoming
traffic is limited to 256 KiB per second per identified client. Catch-up sends
16 ticks per batch. A controller more than six ticks behind pauses production.
Inactive connections are closed after 15 seconds and can reconnect. There is
no timeout that removes a disconnected controller from an active match.

The first release has no accounts, chat, ranked matchmaking, cold recovery,
late players taking seats or authoritative anti-cheat. Restarting the relay
ends its rooms. Deployment to Softmax is separate from this implementation.

## Hosting

A container example is in `tools/gameserver/Dockerfile`. From the checkout:

```sh
docker compose -f tools/gameserver/compose.yaml up --build -d
```

The compose file publishes only loopback port 8090. Put the supplied
`tools/gameserver/nginx.conf` locations inside an existing TLS-enabled nginx
server block with your domain and certificate. Keep the relay private behind
that proxy and expose `/ws` as `wss://your-domain/ws`. The container runs as a
non-root user. Set host resource limits for the intended number of rooms.

## Extending another game

Use `rooms`, `roomclients` and `connections` for the shared protocol and Windy
transport. Define an exact `GameIdentity`, encode your setup and commands,
create the local simulation, and supply hashes. `menus` supplies common menu
widgets, settings storage and local policy selection. GotA's `multiplayer.nim`
shows game-owned payload validation and tick application; the relay imports
none of it.

Focused regressions are `tests/test_rooms.nim` and
`tests/test_gota_multiplayer.nim`. `tests/manual_gota_network.nim` supplies a
native Windy client that owns five base bots and can play against a browser
client. Its `GOTA_ROOM`, `GOTA_SEAT_START`, `GOTA_SEAT_COUNT`, `GOTA_NAME` and
`GOTA_SERVER` environment variables configure a local transport check.

## Validation of this implementation

The server echoes timestamped lifecycle events to stdout: connections,
identification and reconnects, room membership and settings, match starts,
pauses, resume requests, completion and stops. Rejected requests, timeouts,
and outgoing buffer limits include their reason. Names are escaped to keep
each event on one line. Reconnect tokens, invite codes and game payloads
are omitted, as are routine ticks, commands and successful hash checks.

GotA's F1 Network tab uses the normal Silky controls. Its scrolling graphs
show received/sent KB and packets per second, server-measured RTT, and the
absolute change between successive RTT samples. The ticks-per-second chart
counts simulation ticks actually executed per elapsed second, with a gray
line at the normal tick rate. Stalls lower it; catch-up can raise it above
the normal rate. RTT and jitter are averaged
over each second and the readouts update once per second. Counts include the
binary room envelope, but exclude WebSocket, TCP and TLS framing.

The delay controls add constant lag plus random jitter to each direction,
while preserving packet order. Reset clears the settings; already queued
packets finish their scheduled delay. RTT includes that delay and client
turnaround. Timestamps and echoes travel in ordinary packets, without ping
messages or comparisons between client and server clocks. State hashes
remain mandatory even when simulated lag makes the match wait.

The complete headless suite and CI suite pass, including deterministic replay
checks. The native graphical, headless, Coworld check and WASM builds pass.
A real native/WASM match with five privately owned bots on each client ended
at tick 496 with matching state hash 1986491943. Its normal replay plays
headlessly without a mismatch. The browser loaded both a local BASIC file
and a local ZIP, and returned from multiplayer to another local human match
without replacing its window.

A separate real-socket test disconnected a controlling native client at tick
100. That client, its peer and a late spectator all finished at tick 490 with
state hash 253292187. Regressions also inject initial, checkpoint and final
hash mismatches, missing hashes, lost acknowledgements, duplicate commands,
wrong seat ownership, malformed payloads and exhausted queues. They cover
two human seats, distributed bot owners and cross-client bot mail.

The local policy picker, invite join, lobby claims, readiness, gameplay,
match completion and return flows were exercised in the browser. A browser
replay download played headlessly with all 90 actions and matching hashes.
The Docker
and reverse-proxy files are hosting examples; a public TLS deployment has
not been performed here.

“Smooth network playback” in F1 → Network is enabled by default. Steady
packets play immediately. Bursts play at 90% of the normal tick interval,
shortening further as the queue grows (down to 20%) so playback catches up.
There is no fixed startup delay. Control messages and RTT receipts remain
immediate. History catch-up bypasses pacing; tick order, gameplay, and
mandatory hash checks are unchanged.
