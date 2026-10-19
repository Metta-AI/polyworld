# GotA multiplayer packet reference

This documents the implemented **GotA payload protocol version 1**. The
[gameserver packet reference](../../docs/gameserver-packets.md) defines the
outer WebSocket envelope, rooms, acknowledgements, ticks and hash barriers.
This document defines what GotA puts inside that envelope.

The relay never parses the formats below. Every GotA client parses and
validates them, reconstructs the same world and executes the same tick packets.
Bot programs, ZIP files, neural weights and VM memory stay on their owner.

## Identity and versions

GotA sends this Identity in the outer Hello:

| Field | Current value | Source |
| --- | --- | --- |
| game | `gods_of_the_arena` | ReplayGame in replays.nim. |
| gameplay | 70 | ReplayGameVersion in replays.nim. |
| protocol | 1 | GotaNetworkProtocol in multiplayer.nim. |

The outer protocol is independently version 2. The replay format version is
independently 6; it is not a field in Hello. Clients support only their exact
gameplay and protocol versions. There is no legacy payload decoder.

GotA requires exactly ten seats and 24 ticks per second. Seat numbers are
zero-based indices in `world.heroes`. A hero's entity ID is a separate signed
integer; never assume `heroId == seat + 1`. The current seat-to-hero mapping is
established by deterministic world construction.

## What crosses the wire

| Game-owned data | Outer carrier | Representation |
| --- | --- | --- |
| Match setup | CreateRoom / ConfigureRoom / RoomState `payload` | UTF-8 JSON for GotaConfig, at most 64 KiB. |
| Hero action | SubmitCommand `payload`, later Command `payload` in TickPacket | Fixed 32-byte binary record. |
| Bot mailbox message | Same command carriers | Binary fields plus length-prefixed text, at most 1,040 bytes. |
| State digest | Ready / ReportHash / FinishMatch `hash` | u64 containing two 32-bit digests. |

There are no per-frame unit position, HP, terrain, animation, inventory or
rendering packets. Each client simulates those from setup and commands. There
is also no server action-result packet: gameplay acceptance/rejection is
computed by every client when the command executes.

## Setup blob

Setup is currently JSON, although the surrounding protocol and commands are
binary. It is parsed with `parseConfig` from [presets.nim](presets.nim).
The emitted field names are camelCase. The parser also accepts the shared
configuration's snake_case aliases and fills omitted fields with defaults.

| Field | JSON type | Meaning in the shared configuration |
| --- | --- | --- |
| players | Array of `{ "name": string }` | Omitted/empty or ten entries. Network preparation overwrites names from room seats. |
| seed | Integer | Match RNG seed, default 54 through GotA's parser. |
| maxTicks | Positive integer | Battle duration cap, excluding draft time. Default 28,800 ticks (20 minutes). |
| spawnIntervalTicks | Positive integer | Creep wave interval; default 480 ticks. |
| playerSlot | Integer, 0 to 10 | Offline human slot setting. Network preparation forces this to 0 in shared config. Local human ownership is kept separately. |
| dayCount | Nonnegative integer | Shared configuration field; retained in the config, not a network scheduler setting. |
| headlessTickRate | Integer | Local headless pacing field; does not override the relay's 24 Hz clock. |
| waitForLlm | Boolean | Local execution field; does not create a server-side bot or LLM service. |
| mapPreset | Object | Procedural map generation settings listed below. |
| draftMode | String | `unique`, `team` or `open`. |

The last three execution-related fields remain in the serialized configuration
and its digest even though the relay owns multiplayer pacing. They are not
additional network commands.

Map preset fields and current defaults:

| Field | Default | Meaning / accepted range |
| --- | --- | --- |
| mapSize | 116 | Even tile dimension, 64 to 256. |
| seed | 54 | Map seed, fitting signed 32 bits. Separate from match seed. |
| lakeCrossings | 4 | Even count, 0 to 6. |
| jungleRoads | 32 | Even count, 18 to 50. |
| highSize | 511 | High-ground control, 450 to 570. |
| castleSize | 295 | Keep size control, 210 to 500. |
| roadWidth | 52.7 | Road width control, 26 to 62. |
| roadWobble | 73 | Road curvature control, 0 to 80. |
| lakeWidth | 80 | Lake width control, 42 to 120. |
| lakeWobble | 30 | Lake curvature control, 0 to 80. |
| campRadius | 36 | Camp size control, 20 to 40. |
| campScatter | 35 | Camp placement control, 0 to 60. |
| stemLength | 50 | Camp connection control, 30 to 80. |
| campsTouchRoads | true | Whether camp clearings may touch other roads. |

These shape controls use the generator's control scale, not direct tile counts.
Only mapSize is explicitly the square map dimension. Float controls must be
finite. [generation/configs.nim](generation/configs.nim) owns validation.

For example, this valid short setup uses defaults for omitted fields:

```json
{
  "seed": 54,
  "maxTicks": 28800,
  "spawnIntervalTicks": 480,
  "draftMode": "team",
  "mapPreset": { "mapSize": 116, "seed": 54 }
}
```

On loading a room, every client parses the blob, normalizes playerSlot and
player names, generates the map and constructs the initial world. Only seats
owned by that client may load local bot sources. Other seats have no bot VM.
Ready carries the resulting digest, not the literal JSON's hash alone.

## Command encoding

All integers are little endian. Signed values are encoded using their raw
32-bit two's-complement representation. There is no structure padding,
float32 field, inner magic, inner version or execution tick in a command.
Compatibility comes from Hello; execution tick comes from TickPacket.

The first `u32` is a category: **0 = hero action, 1 = mailbox message**.
Other categories are invalid. Both forms then carry `heroId:i32`.

### Category 0: hero action, exactly 32 bytes

| Byte offset | Field | Type | Meaning |
| --- | --- | --- | --- |
| 0 | category | u32 | 0. |
| 4 | heroId | i32 | Acting hero's entity ID, checked against the outer seat. |
| 8 | kind | u32 | Action ID below. The in-memory replay uses u8, but the wire uses u32. |
| 12 | slot | i32 | Ability or inventory slot for actions that use this field. |
| 16 | first | i32 | Target, tile X, item ID or class ID depending on kind. |
| 20 | second | i32 | Tile Y for point actions; otherwise unused. |
| 24 | offsetX | i32 | Raw Q16.16 offset from tile center. |
| 28 | offsetY | i32 | Raw Q16.16 offset from tile center. |

Action IDs reuse the existing replay action IDs. Gaps are intentional and
must not be renumbered. `unused` means the game action ignores that field;
producers normally write zero. The wire decoder still validates both offsets
for every action, including actions that do not use coordinates.

| ID | Action | slot | first | second | Offsets |
| --- | --- | --- | --- | --- | --- |
| 1 | ActionWalkTo | unused | Tile X | Tile Y | Destination offset. |
| 2 | ActionAttackTarget | unused | Target entity ID | unused | unused |
| 3 | ActionBuyItem | unused | Item ID | unused | unused |
| 4 | ActionUseItem | unused | Inventory slot | unused | unused |
| 5 | ActionAttackMove | unused | Tile X | Tile Y | Destination offset. |
| 6 | ActionCastTarget | Ability slot | Target entity ID | unused | unused |
| 10 | ActionCastPoint | Ability slot | Tile X | Tile Y | Aim offset. |
| 15 | ActionUseItemAt | Inventory slot | Tile X | Tile Y | Aim offset. |
| 16 | ActionLevelAbility | Ability slot | unused | unused | unused |
| 17 | ActionBuyback | unused | unused | unused | unused |
| 18 | ActionDraft | unused | Hero class ID | unused | unused |

Notice that ordinary UseItem puts the inventory slot in **first**, while
UseItemAt uses **slot**. This follows the current replay representation.
Inventory indices are zero-based. Ability slots are 0 passive, 1 primary,
2 secondary, 3 ultimate. Whether a slot can actually be cast or upgraded is
validated by gameplay rules at execution, not by the structural decoder.

Draft class IDs are 0 VanguardKnight, 1 Ranger, 2 Arcanist, 3 DruidWarden,
4 DemonHunter, 5 DeathKnight, 6 Crossbowman, 7 Lich, 8 Warlock, 9 Berserker.
Item IDs and entity IDs use the current gameplay version's definitions.

### Coordinates and signed values

Coordinates use tile centers. `first` and `second` name the integer tile and
the offsets represent its fractional displacement:

```text
x = first  + offsetX / 65536
y = second + offsetY / 65536
-32768 <= offsetX, offsetY < 32768
```

Thus `(12.25, 9.75)` is tile `(12, 10)` plus raw offsets `(16384, -16384)`.
The horizontal map Y corresponds to the world's Z axis. Negative tile/slot
arguments survive transport so gameplay can reject them consistently; a
structurally valid command is not a promise that its action is legal.

Example payload for hero 7 walking to `(12.25, 9.75)`:

```text
00 00 00 00   category = action
07 00 00 00   heroId = 7
01 00 00 00   kind = WalkTo
00 00 00 00   slot = 0
0c 00 00 00   first = 12
0a 00 00 00   second = 10
00 40 00 00   offsetX = 16384
00 c0 ff ff   offsetY = -16384
```

Wrapping this in SubmitCommand produces 72 bytes. A TickPacket with just this
command is 84 bytes. Both counts exclude WebSocket/TCP/TLS overhead.

### Category 1: bot mailbox message

| Byte offset | Field | Type | Meaning |
| --- | --- | --- | --- |
| 0 | category | u32 | 1. |
| 4 | heroId | i32 | Sending hero's entity ID, checked against the outer seat. |
| 8 | target | i32 | Recipient seat, or broadcast selector. |
| 12 | text length | u32 | Byte length, at most 1,024. |
| 16 | text | bytes | Exactly that many message bytes. |

Targets are `0..9` for one seat, `-1` for the sender's team, and `-2` for all
seats. Broadcasts include the sender. Other targets deliver to nobody. Empty
messages and full inboxes also deliver nothing; each inbox holds 100 messages.
The receiving mailbox exposes the sender's seat ID for direct messages and
the negative selector for broadcasts.

This is **bot mailbox traffic**, not lobby chat. All participants, including
opponents and spectators, receive the opaque TickPacket containing it. Team
routing controls which in-game inbox receives it; it does not provide network
confidentiality. No bot source or weights are included.

Multiplayer sendChat returns 1 for successful local queuing, not the number of
recipients that eventually accepted the message. Offline sendChat retains its
immediate delivery-count return.

## Execution and rejection

For each TickPacket, a client:

1. Requires the current match and exactly `world.tick + 1`.
2. Validates every command before executing any: the participant owns the
   outer seat, the payload decodes fully, and heroId matches that seat's hero.
3. Delivers mailbox entries in packet order before the simulation tick, and
   queues hero actions with `action.tick = packet.tick`.
4. Executes one normal simulation tick. Hero actions run in packet order at
   the simulation's action phase, including during drafting. Mail and actions
   are therefore separate phases, even if interleaved in the packet.
5. Publishes locally computed action acceptance, samples metrics and sends
   AppliedTick. At checkpoints it sends ReportHash; at the end, FinishMatch.
6. Otherwise runs eligible locally owned bot decisions against that resulting
   state and submits their next commands. Remote seats never run a VM.

Two failures have different meanings:

- **Malformed/unauthorized input:** unknown category/kind, truncated or trailing
  bytes, invalid fractional offsets, wrong owner or wrong hero. This is a
  protocol failure, reported visibly; the controller can send AbortMatch.
- **Legal packet, rejected action:** dead hero, cooldown, insufficient gold,
  invalid target, invalid slot, forbidden draft pick or other gameplay rule.
  Every client evaluates the same action and obtains the same rejection.
  This does not become a successful action or stop the match.

Human actions and local bot actions share this path. The immediate command
return says only that local queuing succeeded. CommandAck says only that the
relay assigned a tick. Neither says that the hero bought, moved or cast.
The existing action feedback, including structured `lastAction.accepted`, is
updated when the authoritative command executes. There is no separate remote
result RPC. Offline execution remains immediate.

## Pause and the Escape menu

Escape opens an in-match menu with Return to game, Pause/Resume match,
Settings, and Quit to main menu. Opening the menu does not automatically pause.
The modal blocks gameplay clicks and shortcuts behind it. Settings change
local presentation preferences, not shared game rules or identity mid-match.

Offline pause stops local simulation ticks and can be resumed from the same
menu. Multiplayer pause uses the generic PauseMatch request, not a GotA action
payload. Every client finishes any already-emitted ticks, then waits. Rendering
and networking stay responsive, and hash checks remain mandatory. Only a
controller may pause/resume. Quit by a controller explicitly aborts the match
before releasing its seats; spectator departure does not stop the match.

Pause affects wall-clock pacing only. It does not add gameplay ticks or actions
to normal replays, so replay playback has no real-time pause gap to reproduce.

## Hash contents and replay relationship

The network digest is computed as:

```text
configHash = HashySeed
addHashy(configHash, game.config.toJson())
networkHash = (uint64(configHash) << 32) | game.stateHash()
```

The upper half is a 32-bit digest of the normalized immutable config. The
lower half is the existing 32-bit replay state digest, returned in a u64.
It covers the generated map hash and explicitly enumerated authoritative
state such as draft state, RNG, heroes, buildings, camps, creeps, navigation
state, active spells, tower shots and combat statistics. See `stateHash` in
[sim.nim](sim.nim) for the exact fields. It is not a raw-memory hash.

This is **not a 64-bit state hash or a cryptographic digest**. The two halves
have separate 32-bit collision limits. Mandatory comparison detects differing
digests but cannot prove that equal digests mean identical state. Private VM
state, mailbox queues, rendering state and local performance measurements are
not part of the replay-state digest. The server does not verify hash coverage.

Ready reports the initial digest. Start also sends ReportHash at tick 0 and
checks BeginMatch's agreed hash. Subsequent reports occur at ticks 24, 48, 72
and so on, after simulation. FinishMatch carries the actual final tick and
digest, even between boundaries. The relay's mandatory barriers, retained
checkpoints and mismatch behavior are specified in the outer reference.

Normal replays record executed hero action attempts, including rejected ones,
plus setup/configuration, per-tick state hashes and metrics. They do not store
the outer envelopes, command acknowledgements, bot VMs or mailbox commands.
Replay playback needs no bots because the resulting hero actions are already
recorded. Relay catch-up history **does** contain mailbox payloads and outer
ownership/order metadata, so it is different from a normal replay file.

Late spectators reconstruct from setup and authoritative tick history with
no bot VMs. Reconnecting controllers retain their original local simulation
and private VMs. There is no game-state snapshot, bot-state transfer or
automatic desync repair packet.

## Design points to preserve when changing the protocol

- Keep the server independent of these action IDs and all GotA config fields.
- Keep slot, seat, participant, hero/entity and class IDs distinct.
- Preserve the difference between queue acknowledgement and gameplay result.
- Change GotaNetworkProtocol for incompatible payload/interpretation changes.
  Change ReplayGameVersion for incompatible gameplay/replay behavior.
- Consider JSON normalization, hash coverage/width and mailbox visibility
  explicitly when revising the design. They are current design choices, not
  guarantees supplied by the generic transport.

Source of truth: [multiplayer.nim](multiplayer.nim) owns the payload codec and
tick adapter; [replays.nim](replays.nim) owns action IDs; [sim.nim](sim.nim)
owns execution; [bots.nim](bots.nim) owns mailbox routing and bot feedback.
