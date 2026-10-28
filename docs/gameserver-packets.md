# Gameserver packets

Outer protocol **3**. [GotA payloads](../examples/gods_of_the_arena/packets.md) · [Hosting](gameserver.md).

One binary WebSocket message per packet at `/ws`. Fields are in wire order,
little endian, without padding. `string` and `seq[T]` have a `uint32` length
prefix. Types below describe the wire, so boolean flags are `uint32` (0 or 1).

## Common header — 64 bytes

Every packet starts with this header; the packet tables list only its body.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `magic` | `array[4, char]` | PWRM. |
| `version` | `uint32` | Exactly 3. |
| `kind` | `uint32` | Packet ID below. |
| `delivery` | `uint64` | Server delivery counter per connection, starting at 1; clients send 0. |
| `match` | `uint32` | Match generation within room; starts at 0, increments on start. |
| `server` | `uint64` | Server monotonic send time in microseconds; client sends 0. |
| `echo` | `uint64` | Client echoes the latest received server timestamp unchanged. |
| `received` | `uint64` | Client's cumulative delivery acknowledgement; paired with `echo`. |
| `measuredAt` | `uint64` | Server time of the latest RTT measurement; 0 means unavailable. |
| `rtt` | `uint32` | Latest server-measured round trip in microseconds. |
| `jitter` | `uint32` | Absolute difference between consecutive RTT samples, in microseconds. |

The server validates the echo against its delivery record, then subtracts its
original send time from its current monotonic time. Client clocks never enter
this calculation. RTT includes the client's processing and acknowledgement
turnaround. New measurements arrive with subsequent ordinary server packets.
Replayed ticks get fresh transport timestamps; timing is not simulation state.

Normal traffic is one submission per command and one authoritative packet per
tick. The tick's command list confirms new submissions. Explicit CommandAck
packets resolve retransmissions. Hashes, catch-up, and room/status changes still
use their required control packets. Clients also acknowledge applied ticks.
Receipts and timestamp echoes ride on outgoing packets, with a
100 ms fallback when otherwise idle. Keepalives run only after 3 seconds idle.


## Shared records

### GameIdentity

Exact equality is required for all three fields.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `game` | `string` | Game name; nonempty, ≤96 bytes. |
| `gameplay` | `uint32` | Gameplay version. |
| `protocol` | `uint32` | Game payload protocol; nonzero. |

### Participant

One connected guest may own multiple seats or spectate.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `id` | `uint32` | Nonzero guest ID. |
| `name` | `string` | Display name; ≤64 bytes. |
| `connected` | `uint32` | Connected = 1. |
| `ready` | `uint32` | Ready = 1. |

### Seat

A seat has no server-side team or human/bot classification.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `owner` | `uint32` | Participant ID; 0 means unclaimed. |
| `name` | `string` | Seat name; ≤96 bytes. |

### RoomListing

Public room browser entry.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `id` | `string` | Room ID; ≤64 bytes. |
| `name` | `string` | Room name; ≤96 bytes. |
| `phase` | `uint32` | RoomPhase value. |
| `occupied` | `uint32` | Claimed seats. |
| `seats` | `uint32` | Total seats. |

### Command

Retained command ownership and bytes inside a TickPacket.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `participant` | `uint32` | Submitting participant. |
| `seat` | `uint32` | Owned seat index. |
| `sequence` | `uint64` | Participant command sequence. |
| `payload` | `string` | Opaque game command; ≤4,096 bytes. |

### RoomPhase

Shared phase values carried as `uint32`.

| Value | Phase |
| --- | --- |
| 0 | Lobby |
| 1 | Playing |
| 2 | Waiting |
| 3 | Ended |
| 4 | Desynced; also fatal abort or exhausted limits |

## 0. Hello — Client → server

Identify the game and player, or reconnect an existing guest.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `identity` | `GameIdentity` | Exact game, gameplay version and payload protocol. |
| `name` | `string` | Display name; ≤64 bytes. |
| `token` | `string` | Empty for a new guest; private reconnect token otherwise; ≤64 bytes. |

## 1. Welcome — Server → client

Assign the guest identity and private reconnect token.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `participant` | `uint32` | Nonzero participant ID. |
| `token` | `string` | Private token; ≤64 bytes. Never broadcast. |

## 2. ListRooms — Client → server

Request public rooms matching the exact game identity.

| Body | Size |
| --- | --- |
| None; header only | 64 bytes total |

## 3. RoomList — Server → client

Return compatible public rooms.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `rooms` | `seq[RoomListing]` | At most 64 rooms. |

## 4. CreateRoom — Client → server

Create a room with opaque game setup.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `name` | `string` | Room name; ≤96 bytes. |
| `flag` | `uint32` | Public = 1, unlisted = 0. |
| `tickRate` | `uint32` | 1–120 ticks/second. |
| `number` | `uint32` | 1–64 seats. |
| `payload` | `string` | Opaque setup blob; ≤65,536 bytes. |

## 5. JoinRoom — Client → server

Join by room ID; joins during a match are spectators.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `room` | `string` | Room ID; ≤64 bytes. Also works for unlisted rooms. |

## 6. RoomState — Server → client

Replace the local room snapshot after lobby changes or reconnection.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `room` | `string` | Room ID; empty clears membership; ≤64 bytes. |
| `name` | `string` | Room name; ≤96 bytes. |
| `participant` | `uint32` | Room owner ID. |
| `revision` | `uint32` | Setup/roster revision. |
| `phase` | `uint32` | RoomPhase value. |
| `tickRate` | `uint32` | Simulation ticks/second. |
| `flag` | `uint32` | Explicit pause = 1; otherwise 0. Not room visibility. |
| `payload` | `string` | Opaque setup; ≤65,536 bytes. |
| `participants` | `seq[Participant]` | At most 64. |
| `seats` | `seq[Seat]` | At most 64; array index is seat ID. |

## 7. ConfigureRoom — Client → server

Owner changes lobby settings; clears readiness and increments revision.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `name` | `string` | Room name; ≤96 bytes. |
| `flag` | `uint32` | Public = 1, unlisted = 0. |
| `tickRate` | `uint32` | 1–120 ticks/second. |
| `number` | `uint32` | Seat count must remain unchanged. |
| `payload` | `string` | Opaque setup; ≤65,536 bytes. |

## 8. ClaimSeat — Client → server

Claim an empty lobby seat or rename your own seat.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `seat` | `uint32` | Zero-based seat index. |
| `name` | `string` | Seat name; ≤96 bytes. |

## 9. ReleaseSeat — Client → server

Release your lobby seat; an already empty seat is accepted.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `seat` | `uint32` | Zero-based seat index. |

## 10. Ready — Client → server

Confirm the current setup is loaded and report its initial state hash.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `revision` | `uint32` | Must match current room revision. |
| `hash` | `uint64` | Initial game digest; all controllers must agree. |

## 11. StartMatch — Client → server

Owner starts once all seats are owned and all controllers are connected, ready and hash-matched.

| Body | Size |
| --- | --- |
| None; header only | 64 bytes total |

## 12. BeginMatch — Server → client

Start or reconstruct the match using the preceding RoomState; header carries the match ID.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `revision` | `uint32` | Agreed setup revision. |
| `hash` | `uint64` | Agreed initial state hash. |

## 13. SubmitCommand — Client → server

Queue opaque input for an owned seat; server assigns the next tick in receipt order.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `seat` | `uint32` | Seat owned by sender. |
| `sequence` | `uint64` | Consecutive from 1 across all sender seats; identical retransmissions are deduplicated. |
| `payload` | `string` | Opaque game command; ≤4,096 bytes. |

## 14. CommandAck — Server → client

Resolve a retransmitted command's queue acceptance, not gameplay success.
New commands are confirmed by their inclusion in TickPacket.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `sequence` | `uint64` | Accepted command sequence. |
| `tick` | `uint32` | Assigned execution tick. |

## 15. TickPacket — Server → client

Execute this immutable tick once, including ticks with no commands.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `tick` | `uint32` | Next consecutive simulation tick. |
| `commands` | `seq[Command]` | Server receipt order; at most 1,024 commands. |

## 16. AppliedTick — Client → server

Acknowledge that simulation has executed through this tick.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `tick` | `uint32` | Last applied simulation tick. |

## 17. Catchup — Client → server

Request retained ticks after the last applied tick.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `tick` | `uint32` | Last applied tick; server sends at most 16 ticks per batch. |

## 18. CaughtUp — Server → client

End a catch-up batch; does not authorize skipping ticks.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `tick` | `uint32` | Last tick in this batch. |
| `number` | `uint32` | Current server tick; request another batch if behind. |

## 19. ReportHash — Client → server

Compare state at tick 0 and every simulation-second boundary; mismatches stop the match.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `tick` | `uint32` | Multiple of tickRate; not ahead of server or backward for sender. |
| `hash` | `uint64` | Game digest; next tick waits for every controller to agree. |

## 20. MatchStatus — Server → client

Publish running, waiting, completed or failed state.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `flag` | `uint32` | Explicit pause = 1, otherwise 0; other waits can still apply. |
| `phase` | `uint32` | RoomPhase value. |
| `tick` | `uint32` | Latest emitted tick. |
| `detail` | `string` | Status or failure explanation; ≤4,096 bytes. |

## 21. LeaveRoom — Client → server

Leave a lobby/completed room or spectate elsewhere; live controllers must first end the match.

| Body | Size |
| --- | --- |
| None; header only | 64 bytes total |

## 22. KickParticipant — Client → server

Room owner removes another participant from the lobby.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `participant` | `uint32` | Participant to remove. |

## 23. ReturnLobby — Client → server

Owner reopens an ended/failed room and clears history, pause and readiness.

| Body | Size |
| --- | --- |
| None; header only | 64 bytes total |

## 24. FinishMatch — Client → server

Report the final state; all controllers must agree before the match ends.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `tick` | `uint32` | Actual final tick; may fall between hash checkpoints. |
| `hash` | `uint64` | Final game digest. |

## 25. Received — Client → server

Idle fallback to release outgoing traffic credit; normally carried in the header.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `sequence` | `uint64` | Optional cumulative delivery ID; 0 uses the header acknowledgement. |

## 26. Keepalive — Both directions

Application heartbeat; client sends after 3 seconds without outgoing traffic, server disconnects after 15 seconds without traffic.

| Body | Size |
| --- | --- |
| None; header only | 64 bytes total |

## 27. Failure — Server → client

Report an invalid request or packet; does not necessarily stop the match.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `detail` | `string` | Diagnostic; ≤4,096 bytes. |

## 28. AbortMatch — Client → server

A controller explicitly stops the match for everyone, including on fatal client errors or quitting.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `detail` | `string` | Reason; ≤4,096 bytes. First fatal diagnostic is retained. |

## 29. PauseMatch — Client → server

A controller pauses or resumes the current match; spectators cannot.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `flag` | `uint32` | 1 pauses new ticks; 0 resumes only when connection and hash barriers also pass. |

## Shared rules

| Concern | Rule |
| --- | --- |
| Server scope | Identity, membership, ownership, timeline and hash comparison only. Setup and command blobs stay opaque. |
| Match validation | SubmitCommand, AppliedTick, Catchup, ReportHash, FinishMatch, AbortMatch and PauseMatch require the current header match ID. |
| Delivery | Consecutive per socket; resets on reconnect. Pre-identification failures can use delivery 0. |
| Commands | Sequence spans all seats of one participant and survives reconnect. Gaps, zero or altered retransmissions fail. |
| Hash barrier | Mandatory at startup, every simulated second and finish. Missing controller hashes wait indefinitely; mismatches stop visibly. No state repair. |
| Spectator hashes | Compared with retained checkpoints; mismatch stops the room, but absent spectator reports do not block it. |
| Disconnect / lag | Missing controller or controller more than six ticks behind pauses production. Reconnect retains seats and requires catch-up. |
| Explicit pause | Already-emitted ticks still execute. Pending commands stay on the next tick. Resume resets the clock deadline; no time catch-up burst. |
| Quit | Live controller sends AbortMatch then LeaveRoom. Spectator sends LeaveRoom. No simulated winner is invented. |
| Recovery | Same live client reconnects with its private token and VMs intact. Browser reload/process restart recovery is unsupported. |
| Room IDs / tokens | 48 lowercase hex characters from 24 random bytes; unlisted room ID grants access, reconnect token stays private. |
| Validation | Truncation, invalid enums/flags, oversized counts and trailing bytes fail. Display names reject blank/control characters; UTF-8 is not independently checked. |
| History | Kept until ReturnLobby or last participant leaves; server restart loses it. Includes opaque commands, never bot programs or weights. |
| Versions | Exact only. Incompatible outer layout changes bump RoomProtocolVersion; game payload and gameplay versions are separate. |

## Limits

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

## Source

| File | Owns |
| --- | --- |
| [rooms.nim](../src/polyworld/rooms.nim) | Wire codec and IDs. |
| [relays.nim](../src/polyworld/relays.nim) | Timeline, limits and mandatory hashes. |
| [roomclients.nim](../src/polyworld/roomclients.nim) | Acknowledgements and catch-up. |
| [connections.nim](../src/polyworld/connections.nim) | Windy transport. |
| [gameserver.nim](../tools/gameserver.nim) | Mummy event loop. |
