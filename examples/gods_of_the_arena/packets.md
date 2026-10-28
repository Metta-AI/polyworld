# GotA packets

Payload protocol **1**, gameplay **72**, outer protocol **3**.
[Outer packets](../../docs/gameserver-packets.md) carry these blobs unchanged.

## Identity

Sent inside Hello; GotA requires ten seats at 24 ticks/second.

| Field | Nim type | Value |
| --- | --- | --- |
| game | `string` | `gods_of_the_arena` |
| gameplay | `uint32` | 72 |
| protocol | `uint32` | 1 |

## Setup payload

JSON in CreateRoom, ConfigureRoom and RoomState, capped at 65,536 bytes.
Clients normalize names from room seats and force `playerSlot = 0`.

| Field | Nim value type | Carries / default |
| --- | --- | --- |
| `players` | `seq[PlayerConfig]` | Empty or ten names; replaced by seat names. |
| `seed` | `int32` | Match RNG seed; default 54. |
| `maxTicks` | `int32` | Battle cap excluding draft; default 28,800. |
| `spawnIntervalTicks` | `int32` | Creep wave interval; default 480. |
| `playerSlot` | `int32` | Forced to 0; human ownership is local. |
| `dayCount` | `int32` | Nonnegative shared config field. |
| `headlessTickRate` | `int32` | Retained in config; does not override the relay clock. |
| `waitForLlm` | `bool` | Retained in config; no server bot/LLM execution. |
| `mapPreset` | `MapConfig` | Generation settings below. |
| `draftMode` | `DraftMode` | unique, team or open. |

### mapPreset: MapConfig

Shape controls use generator units; only mapSize is the tile dimension.

| Field | Nim value type | Default | Meaning / accepted range |
| --- | --- | --- | --- |
| `mapSize` | `int` | 116 | Even tile dimension, 64 to 256. |
| `seed` | `int` | 54 | Map seed, fitting signed 32 bits. Separate from match seed. |
| `lakeCrossings` | `int` | 4 | Even count, 0 to 6. |
| `jungleRoads` | `int` | 32 | Even count, 18 to 50. |
| `highSize` | `float32` | 511 | High-ground control, 450 to 570. |
| `castleSize` | `float32` | 295 | Keep size control, 210 to 500. |
| `roadWidth` | `float32` | 52.7 | Road width control, 26 to 62. |
| `roadWobble` | `float32` | 73 | Road curvature control, 0 to 80. |
| `lakeWidth` | `float32` | 80 | Lake width control, 42 to 120. |
| `lakeWobble` | `float32` | 30 | Lake curvature control, 0 to 80. |
| `campRadius` | `float32` | 36 | Camp size control, 20 to 40. |
| `campScatter` | `float32` | 35 | Camp placement control, 0 to 60. |
| `stemLength` | `float32` | 50 | Camp connection control, 30 to 80. |
| `campsTouchRoads` | `bool` | true | Whether camp clearings may touch other roads. |

## Hero action layout — 32 bytes

SubmitCommand carries this record; TickPacket supplies its execution tick.
The action tables below use this layout and list all eight fields in wire order.

| Field | Nim wire type | Carries |
| --- | --- | --- |
| category | `uint32` | 0 = hero action. |
| heroId | `int32` | Entity ID of the hero owned by the outer seat. |
| kind | `uint32` | Action ID; gaps are intentional. |
| slot | `int32` | Ability or inventory slot. |
| first | `int32` | Action-specific argument. |
| second | `int32` | Action-specific argument. |
| offsetX | `int32` | Raw Q16.16 tile offset. |
| offsetY | `int32` | Raw Q16.16 tile offset. |

### ActionWalkTo

Move to a point.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `category` | `uint32` | 0 |
| `heroId` | `int32` | Acting hero entity ID |
| `kind` | `uint32` | 1 |
| `slot` | `int32` | 0 |
| `first` | `int32` | Tile X |
| `second` | `int32` | Tile Y |
| `offsetX` | `int32` | Destination offset X |
| `offsetY` | `int32` | Destination offset Y |

### ActionAttackTarget

Attack an entity.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `category` | `uint32` | 0 |
| `heroId` | `int32` | Acting hero entity ID |
| `kind` | `uint32` | 2 |
| `slot` | `int32` | 0 |
| `first` | `int32` | Target entity ID |
| `second` | `int32` | 0 |
| `offsetX` | `int32` | 0 |
| `offsetY` | `int32` | 0 |

### ActionBuyItem

Buy a shop item.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `category` | `uint32` | 0 |
| `heroId` | `int32` | Acting hero entity ID |
| `kind` | `uint32` | 3 |
| `slot` | `int32` | 0 |
| `first` | `int32` | Item ID |
| `second` | `int32` | 0 |
| `offsetX` | `int32` | 0 |
| `offsetY` | `int32` | 0 |

### ActionUseItem

Use an inventory item. Healing and mana consumables can target a living, visible allied hero within three tiles. A zero target uses the item on self. The owner spends the item and receives its cooldown.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `category` | `uint32` | 0 |
| `heroId` | `int32` | Acting hero entity ID |
| `kind` | `uint32` | 4 |
| `slot` | `int32` | 0 |
| `first` | `int32` | Inventory slot |
| `second` | `int32` | Allied hero ID, or 0 for self |
| `offsetX` | `int32` | 0 |
| `offsetY` | `int32` | 0 |

### ActionAttackMove

Move toward a point while acquiring targets.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `category` | `uint32` | 0 |
| `heroId` | `int32` | Acting hero entity ID |
| `kind` | `uint32` | 5 |
| `slot` | `int32` | 0 |
| `first` | `int32` | Tile X |
| `second` | `int32` | Tile Y |
| `offsetX` | `int32` | Destination offset X |
| `offsetY` | `int32` | Destination offset Y |

### ActionCastTarget

Cast an ability on an entity.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `category` | `uint32` | 0 |
| `heroId` | `int32` | Acting hero entity ID |
| `kind` | `uint32` | 6 |
| `slot` | `int32` | Ability slot |
| `first` | `int32` | Target entity ID |
| `second` | `int32` | 0 |
| `offsetX` | `int32` | 0 |
| `offsetY` | `int32` | 0 |

### ActionCastPoint

Cast an ability at a point.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `category` | `uint32` | 0 |
| `heroId` | `int32` | Acting hero entity ID |
| `kind` | `uint32` | 10 |
| `slot` | `int32` | Ability slot |
| `first` | `int32` | Tile X |
| `second` | `int32` | Tile Y |
| `offsetX` | `int32` | Aim offset X |
| `offsetY` | `int32` | Aim offset Y |

### ActionUseItemAt

Use an inventory item at a point.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `category` | `uint32` | 0 |
| `heroId` | `int32` | Acting hero entity ID |
| `kind` | `uint32` | 15 |
| `slot` | `int32` | Inventory slot |
| `first` | `int32` | Tile X |
| `second` | `int32` | Tile Y |
| `offsetX` | `int32` | Aim offset X |
| `offsetY` | `int32` | Aim offset Y |

### ActionLevelAbility

Spend a skill point on an ability.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `category` | `uint32` | 0 |
| `heroId` | `int32` | Acting hero entity ID |
| `kind` | `uint32` | 16 |
| `slot` | `int32` | Ability slot |
| `first` | `int32` | 0 |
| `second` | `int32` | 0 |
| `offsetX` | `int32` | 0 |
| `offsetY` | `int32` | 0 |

### ActionBuyback

Request respawn through buyback.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `category` | `uint32` | 0 |
| `heroId` | `int32` | Acting hero entity ID |
| `kind` | `uint32` | 17 |
| `slot` | `int32` | 0 |
| `first` | `int32` | 0 |
| `second` | `int32` | 0 |
| `offsetX` | `int32` | 0 |
| `offsetY` | `int32` | 0 |

### ActionDraft

Pick a hero class.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `category` | `uint32` | 0 |
| `heroId` | `int32` | Acting hero entity ID |
| `kind` | `uint32` | 18 |
| `slot` | `int32` | 0 |
| `first` | `int32` | Hero class ID |
| `second` | `int32` | 0 |
| `offsetX` | `int32` | 0 |
| `offsetY` | `int32` | 0 |

## Mailbox payload — 16 bytes + text

Send a bot message through SubmitCommand; every client receives the bytes,
even when delivery is restricted to a team inbox.

| Field | Nim wire type | Carries / rules |
| --- | --- | --- |
| `category` | `uint32` | 1 |
| `heroId` | `int32` | Sending hero entity ID; must match outer seat. |
| `target` | `int32` | 0–9: seat; -1: sender team; -2: everyone. Broadcast includes sender. |
| `text` | `string` | uint32 byte count + message; ≤1,024 bytes. |

## Arguments

| Argument | Rule |
| --- | --- |
| Seat / hero | Seat is world.heroes index; heroId is an entity ID, not seat + 1. |
| Ability slot | 0 passive, 1 primary, 2 secondary, 3 ultimate. |
| Inventory slot | Zero-based. ActionUseItem uses first; ActionUseItemAt uses slot. |
| Hero class ID | 0 VanguardKnight, 1 Ranger, 2 Arcanist, 3 DruidWarden, 4 DemonHunter, 5 DeathKnight, 6 Crossbowman, 7 Lich, 8 Warlock, 9 Berserker. |
| Point | x = first + offsetX / 65536; y = second + offsetY / 65536. Map Y is world Z. |
| Offsets | -32768 ≤ offsetX/offsetY < 32768. Validated even for actions that ignore them. |
| Unused fields | Tables show producer default 0; gameplay ignores them. |
| Encoding | Little endian, no padding. No inner header/version/tick. Negative arguments survive decoding for consistent gameplay rejection. |
| Mailbox | Invalid target, empty message or full 100-message inbox delivers nothing. Multiplayer return means queued, not recipient count. |

## Execution

| Step | Client behavior |
| --- | --- |
| 1 | Require current match and exactly world.tick + 1. |
| 2 | Validate every command: seat ownership, complete decoding, valid kind/offsets and matching heroId. |
| 3 | Deliver mailbox messages in packet order; queue actions for packet.tick. |
| 4 | Run one simulation tick; actions execute in packet order in the action phase. |
| 5 | Publish action results, sample metrics, send AppliedTick and required hashes. |
| 6 | Run only locally owned bot decisions and submit their commands. |

## Results, pause and hashes

| Concern | Behavior |
| --- | --- |
| Queuing | Immediate action return and CommandAck mean queued, not successful gameplay. lastAction.accepted updates on execution; offline calls remain immediate. |
| Invalid packet | Malformed bytes, unauthorized seat or wrong hero stops visibly; controller reports AbortMatch. |
| Rejected action | Cooldown, dead hero, bad target, insufficient gold, etc. produce deterministic rejection, not a protocol failure. |
| Pause | Generic PauseMatch only; no GotA action. Finish emitted ticks, then wait. Networking and mandatory hash checks remain active. |
| Escape | Return to game, pause/resume, settings, quit. Opening alone does not pause; gameplay input behind menu is blocked. |
| Quit | Controller: AbortMatch then LeaveRoom. Spectator: LeaveRoom only. |
| Hash upper 32 bits | Hashy digest of normalized immutable config JSON. |
| Hash lower 32 bits | Existing stateHash: map, draft, RNG, units, navigation, spells, shots and combat stats; exact fields in sim.nim. |
| Hash exclusions | Private VMs, mailbox queues, rendering and local performance. Two 32-bit digests, not a cryptographic 64-bit state hash. |
| Hash timing | Ready at setup; ReportHash at tick 0, 24, 48, etc.; FinishMatch at actual final tick. Comparisons are mandatory. |
| Replay | Format 6; records hero action attempts, setup, hashes and metrics, not mailbox commands or outer envelopes. Wall-clock pauses add no replay ticks. |
| Catch-up | Relay history includes mailbox messages and command ownership/order. Spectators reconstruct without VMs. |
| Reconnect | Original client retains simulation and private VMs. No state snapshots, VM transfers or automatic desync repair. |
| Versioning | Exact versions only. Payload changes bump GotaNetworkProtocol; gameplay changes bump ReplayGameVersion. |

## Source

| File | Owns |
| --- | --- |
| [multiplayer.nim](multiplayer.nim) | Codec and tick adapter. |
| [presets.nim](presets.nim) | Setup parser. |
| [replays.nim](replays.nim) | Action IDs and replay version. |
| [sim.nim](sim.nim) | Execution and state hash. |
| [bots.nim](bots.nim) | Mailbox and action feedback. |
