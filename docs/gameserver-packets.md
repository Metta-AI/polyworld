# Gameserver packet reference

This documents the implemented **outer protocol version 2** on branch
`polyworld-gameserver`. It describes current behavior, not a proposed protocol.
The GotA payload reference is [here](../examples/gods_of_the_arena/packets.md).
Launch and hosting instructions are in [gameserver.md](gameserver.md).

## What the server understands

The server understands game identity, participants, room membership, seat
ownership, readiness, command sequences, execution ticks and state hashes.
It assigns the timeline and distributes the same ordered commands to everyone.

The server does not understand maps, heroes, teams, abilities, input commands,
bot programs or neural weights. Room setup and individual game commands are
length-prefixed byte strings. A human seat and a bot seat are identical to it.
One participant can own several seats or no seats. A participant owning at
least one seat is a **controller**; everyone else is a spectator.

Hashes are opaque `u64` values. The server compares them but cannot compute
the correct game state itself. This is consistency checking between trusted
clients, not authoritative simulation or anti-cheat.

## Transport and binary encoding

Connect using WebSocket at `/ws`. Each binary WebSocket message contains one
complete outer packet. Text messages are rejected. WebSocket provides message
framing; there is no extra whole-packet length prefix or application checksum.
Use `wss://` for public HTTPS clients and `ws://` for local development.

All fields below occur in the listed order, without alignment padding:

| Notation | Encoding |
| --- | --- |
| `u32` | Four bytes, unsigned little endian. |
| `u64` | Eight bytes, unsigned little endian. |
| `bool` | `u32`, exactly 0 or 1. |
| `bytes(N)` | `u32` byte count followed by that many bytes, at most N. |
| `text(N)` | Same encoding as bytes. N is a byte limit, not character count. |
| `T[]` | `u32` element count followed by consecutive T records. |

Text is intended for display, but the decoder does not independently validate
UTF-8. Guest, room and seat names must have non-whitespace content and cannot
contain bytes below 32 or DEL. Payloads can contain arbitrary binary bytes.
Truncated fields, oversized counts, invalid enums and trailing bytes fail.

### Common header: 24 bytes

| Offset | Field | Type | Meaning |
| --- | --- | --- | --- |
| 0 | magic | 4 bytes | ASCII `PWRM`, hex `50 57 52 4d`. |
| 4 | version | u32 | Exact outer protocol version, currently 2. |
| 8 | kind | u32 | Message ID from the tables below. |
| 12 | delivery | u64 | Server-to-client delivery counter; clients send 0. |
| 20 | match | u32 | Match generation within the current room. |
| 24 | body | varies | Only the fields belonging to this message kind. |

The in-memory `RoomMessage` has fields for every message. Those unused by a
kind are **not** serialized. For example, `ListRooms` is exactly 24 bytes.

Normal server deliveries start at 1 on each connection. Clients require
consecutive deliveries and acknowledge them with `Received`. Reconnection
resets this delivery counter; it does not reset the match's command sequence.
Some failures before identification use delivery 0.

`match` starts at 0 and increments when a room starts a match. It is not a
globally unique game ID; its context is the participant's current room.
`SubmitCommand`, `AppliedTick`, `Catchup`, `ReportHash`, `FinishMatch` and
`AbortMatch` and `PauseMatch` must carry the current match value. Lobby requests normally use 0.

### Nested records

| Record | Fields in wire order |
| --- | --- |
| Identity | `game:text(96), gameplay:u32, protocol:u32` |
| Participant | `id:u32, name:text(64), connected:bool, ready:bool` |
| Seat | `owner:u32, name:text(96)` |
| RoomListing | `id:text(64), name:text(96), phase:u32, occupied:u32, seats:u32` |
| Command | `participant:u32, seat:u32, sequence:u64, payload:bytes(4096)` |

Participant IDs are server-assigned and nonzero. Seat indices are zero-based
array positions. Seat owner 0 means unclaimed. Rooms and reconnect tokens are
currently 24 random bytes encoded as 48 lowercase hexadecimal characters.
Only the reconnecting participant receives its private token.

Room phases are `0 Lobby`, `1 Playing`, `2 Waiting`, `3 Ended`, `4 Desynced`.
`Desynced` is also used for a fatal client abort or exhausted match limits.

## Connection and room discovery packets

`C -> S` means client to server. `S -> C` means server to client.
The header is present on every row and is omitted from body descriptions.

| ID | Kind | Direction | Body in wire order | Purpose |
| --- | --- | --- | --- | --- |
| 0 | Hello | C -> S | `identity:Identity, name:text(64), token:text(64)` | Identify an exact game/version and display name. Empty token creates a guest; a known token reconnects that guest. |
| 1 | Welcome | S -> C | `participant:u32, token:text(64)` | Return identity and private reconnect token. |
| 2 | ListRooms | C -> S | Empty | Request public rooms matching the client's exact Identity tuple. |
| 3 | RoomList | S -> C | `rooms:RoomListing[]` | Up to 64 matching public rooms, with occupied and total seat counts. |
| 4 | CreateRoom | C -> S | `name:text(96), flag:bool, tickRate:u32, number:u32, payload:bytes(65536)` | Create a room. Flag means public; number is seat count; payload is game setup. |
| 5 | JoinRoom | C -> S | `room:text(64)` | Join a room by ID, including an unlisted room. |
| 6 | RoomState | S -> C | See below | Full room snapshot after membership, readiness or settings changes. |

`Hello` requires a nonempty game name and a nonzero game-payload protocol.
Compatibility is exact equality of all three Identity fields. No negotiation
or historical fallback exists. A reconnect token must match that identity.
A valid reconnect replaces an old half-open socket for the same guest.

Creating a room requires 1 to 64 seats and 1 to 120 ticks per second. A guest
can belong to only one room. Joining after startup makes the participant a
spectator; seats cannot be acquired during a match. An unlisted room is
accessible to anyone with its room ID, not protected by a separate password.

`RoomState` body, in order:

```text
room:text(64)
name:text(96)
participant:u32              # Room owner, not the receiving participant.
revision:u32
phase:u32
tickRate:u32
flag:bool                    # Explicit user pause, independent of other waits.
payload:bytes(65536)          # Opaque game setup.
participants:Participant[]   # At most 64.
seats:Seat[]                 # At most 64; array index is the seat number.
```

An empty room ID clears membership after leaving or being removed. The public
visibility flag is not present in RoomState; its flag field means paused. Seat records carry neither team
nor human/bot classification; those meanings belong to the game/client.

## Lobby and startup packets

| ID | Kind | Direction | Body in wire order | Purpose |
| --- | --- | --- | --- | --- |
| 7 | ConfigureRoom | C -> S | Same body as CreateRoom | Owner changes name, visibility, tick rate or opaque setup in the lobby. Seat count must remain unchanged. |
| 8 | ClaimSeat | C -> S | `seat:u32, name:text(96)` | Claim an unowned seat or update one's own seat name. |
| 9 | ReleaseSeat | C -> S | `seat:u32` | Release one's own seat; an already empty seat is also accepted. |
| 10 | Ready | C -> S | `revision:u32, hash:u64` | Confirm this revision was loaded and report the initial game-state digest. |
| 11 | StartMatch | C -> S | Empty | Owner requests startup after all seats and controlling clients are ready. |
| 12 | BeginMatch | S -> C | `revision:u32, hash:u64` | Announce the agreed setup and initial hash. Header carries the new match ID. |
| 21 | LeaveRoom | C -> S | Empty | Leave a lobby/completed room; a live spectator can also leave. Live controllers cannot abandon their seats. |
| 22 | KickParticipant | C -> S | `participant:u32` | Owner removes another participant in the lobby. |
| 23 | ReturnLobby | C -> S | Empty | Owner reopens an ended or failed room, clearing match history and readiness. |

Roster/settings changes increment revision and clear readiness. Start checks
that every seat is owned, each controller is connected and ready, and every
controller's initial hash agrees. Spectator readiness is not a start barrier.
The server stops with a diagnostic if initial hashes differ.

`BeginMatch` contains no new setup blob: the client uses the preceding
RoomState. The same BeginMatch is sent on reconnect and late spectating so
clients can resume or reconstruct the immutable initial setup.

## Commands, ticks and acknowledgements

| ID | Kind | Direction | Body in wire order | Purpose |
| --- | --- | --- | --- | --- |
| 13 | SubmitCommand | C -> S | `seat:u32, sequence:u64, payload:bytes(4096)` | Submit opaque game input for an owned seat. Client supplies no execution tick. |
| 14 | CommandAck | S -> C | `sequence:u64, tick:u32` | Confirm acceptance and the assigned execution tick. This is not gameplay success. |
| 15 | TickPacket | S -> C | `tick:u32, commands:Command[]` | Immutable ordered commands for one simulation tick, including an empty list. |
| 16 | AppliedTick | C -> S | `tick:u32` | Confirm simulation has executed through this tick. |
| 17 | Catchup | C -> S | `tick:u32` | Request history after the client's last applied tick. |
| 18 | CaughtUp | S -> C | `tick:u32, number:u32` | End a history batch: tick is last tick sent; number is the current server tick. |
| 25 | Received | C -> S | `sequence:u64` | Cumulative acknowledgement of server delivery IDs; releases transport credit. |

There are three distinct counters:

1. **Delivery:** server messages on this connection, acknowledged by Received.
2. **Command sequence:** consecutive commands from one participant in this
   match, shared across all its seats. Starts at 1 and survives reconnect.
3. **Simulation tick:** room-wide timeline, acknowledged by AppliedTick.

On a new SubmitCommand the server checks ownership, sequence and limits,
assigns `room.tick + 1`, appends in server receipt order, then sends CommandAck.
There is no sorting by hero/team and no lockstep input bundle per player.
Clients need not submit a command every tick. Empty TickPackets still advance
time. A sender executes its command only when that TickPacket arrives.

A retransmission reuses the original sequence, seat and identical bytes.
The server resends the original CommandAck without appending a second command.
A changed payload for the same sequence, a gap, or sequence 0 is rejected.
Clients keep pending commands until acknowledged and resend them on reconnect.

Command records have 20 bytes of overhead plus payload. TickPacket is
32 bytes when empty; SubmitCommand is 40 bytes plus payload; CommandAck is
36 bytes. These sizes exclude WebSocket and TCP/TLS overhead.

Catch-up returns at most 16 historical TickPackets, followed by CaughtUp.
History preserves command bytes, ownership, order and ticks. Its packets get
new delivery IDs when sent again. CaughtUp is a batch marker, not permission
to skip to the current tick. Clients apply only their next consecutive tick.
Buffered duplicate ticks must have identical contents apart from delivery ID.

## Mandatory hashes, status and errors

| ID | Kind | Direction | Body in wire order | Purpose |
| --- | --- | --- | --- | --- |
| 19 | ReportHash | C -> S | `tick:u32, hash:u64` | Digest of state after a simulation-second boundary, or initial tick 0. |
| 20 | MatchStatus | S -> C | `flag:bool, phase:u32, tick:u32, detail:text(4096)` | Running/waiting/completed/failed status and server's latest emitted tick. |
| 24 | FinishMatch | C -> S | `tick:u32, hash:u64` | Final tick and digest; final tick may fall between second boundaries. |
| 26 | Keepalive | Both | Empty | Application heartbeat request/reply. |
| 27 | Failure | S -> C | `detail:text(4096)` | Invalid request or packet diagnostic. No request ID or structured error code. |
| 28 | AbortMatch | C -> S | `detail:text(4096)` | A controller explicitly ends a live match, including fatal client errors or quitting. |
| 29 | PauseMatch | C -> S | `flag:bool` | A controller requests pause (1) or resume (0) for the header's current match. |

Hash checks cannot be disabled:

- Ready hashes form the startup barrier. ReportHash at tick 0 is compared
  with that agreed value; it is not a separate all-controller startup barrier.
- ReportHash ticks must be divisible by the room tick rate, must not be ahead
  of the server, and cannot go backward for that participant.
- After emitting a second-boundary tick, the server emits no subsequent tick
  until every controller has reported that boundary's matching hash.
- The first report establishes a retained checkpoint. Every subsequent report
  for that checkpoint is compared, including reports from late spectators.
- FinishMatch reports must agree on both tick and hash. The server waits for
  all controllers before declaring Ended. Missing reports have no timeout that
  lets simulation continue. A mismatch stops the match with tick/hash details.

The server cannot establish which disagreeing client is correct. It does not
send a state replacement, ignore a mismatch, or silently repair divergence.
Spectators do not block progress while catching up, but a disagreeing spectator
hash does stop the room. This is an explicit trust assumption of this version.

Disconnected controllers pause production indefinitely. A controller more
than six ticks behind also pauses production. During reconnect it must catch
up and acknowledge the current tick before resuming. The existing client keeps
its simulation and private VMs in memory, retransmits pending commands and its
latest hash/final report, and requests missing history. Browser reload or
process restart is not supported recovery. The relay never receives a VM
snapshot or bot source.

The client sends Keepalive every three seconds; the server closes an identified
connection after 15 seconds without incoming traffic. Closing a controller's
socket pauses its match, rather than removing its seats.

Failure is a request/format error and does not necessarily stop a match.
Desync, controller AbortMatch and exhausted pending/history limits produce a
fatal MatchStatus. The first fatal diagnostic is retained.

## Explicit pause and quitting

Any controller can request PauseMatch; spectators cannot. The request sets a
room pause flag and publishes MatchStatus immediately at the latest emitted
tick. TickPackets already emitted still execute. No new tick is produced while
the flag is set. Accepted pending commands remain assigned to the next tick.

The pause flag is carried in RoomState and MatchStatus. Phase remains Waiting,
which also covers connection, catch-up and hash waits. Flag 0 does not by itself
mean the simulation is running. Resume clears only the explicit pause flag;
the server still checks all controller connections and mandatory hashes before
returning to Playing. It resets its wall-clock deadline, so paused wall time
does not cause a burst of simulation ticks. Reconnecting preserves the pause.
Returning the room to the lobby clears it.

Opening a client's Escape menu does not itself request a pause. Quitting as a
live controller sends AbortMatch followed by LeaveRoom, visibly ending the
match for everyone. This is an explicit cancellation, not a simulated winner
or a successful FinishMatch. The current fatal-stop phase is Desynced even
for this cancellation; the diagnostic distinguishes a user quit from a hash
mismatch. A spectator can LeaveRoom without ending the match.

## Bounds and versioning

| Resource | Current bound |
| --- | --- |
| Entire outer packet | 256 KiB |
| Setup / command payload | 64 KiB / 4 KiB |
| Rooms / guests / live sockets | 64 / 512 / 256 |
| Seats / participants per room | 64 / 64 |
| Commands in one decoded tick | 1,024; pending byte accounting may stop earlier |
| Pending storage accounting | Each accepted command adds `2 * payload.len + 64`; admission also checks the pending half-wire budget |
| Retained room history | 128 MiB accounting budget, 345,600 ticks |
| Aggregate retained history | 512 MiB accounting budget |
| Unacknowledged outgoing bytes | 512 KiB per guest, then disconnect |
| Identified incoming traffic | 256 KiB per one-second accounting window |
| Client pending commands / buffered ticks | 4,096 / 128 |

History budgets include receipt/pending accounting, not just packet file size.
The 345,600-tick limit is four hours at 24 Hz, not four hours at every tick rate.
The server retains history while the room exists, until ReturnLobby clears it
or the last participant leaves and the room is removed. Server restart loses
all rooms and history.

Message IDs are currently implicit Nim enum ordinals. Reordering/inserting
members changes the wire format. Any incompatible outer change needs a new
RoomProtocolVersion. Game setup/command changes belong to the game's protocol
version. Gameplay changes belong to its gameplay/replay version. Only exact
versions are supported.

## Implementation references

- [rooms.nim](../src/polyworld/rooms.nim): field encoding, decoding and IDs.
- [relays.nim](../src/polyworld/relays.nim): ownership, sequencing, timeline,
  mandatory hash checks and bounds.
- [roomclients.nim](../src/polyworld/roomclients.nim): acknowledgements,
  buffering, retransmissions and catch-up.
- [connections.nim](../src/polyworld/connections.nim): Windy transport.
- [gameserver.nim](../tools/gameserver.nim): Mummy endpoint and event loop.
