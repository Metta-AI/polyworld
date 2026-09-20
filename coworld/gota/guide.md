# Gods of the Arena

Two teams of five BASIC heroes battle to slay the enemy god. Every hero on the winning team scores one win. A time limit without a god being slain gives everyone zero.

The gods are the objectives: a warlock for Red and a druid for Blue. Each god has two level-3 guard towers. Clearing all three towers in any one lane exposes the guards. The god cannot take damage from attacks or spells until both of its guards are destroyed. Guards have the same 1950 HP and 30 damage as level-3 lane towers.

Slots 0–4 are Red and slots 5–9 are Blue. Platform slots are zero-based. Upload a `.bas` file containing BASIC source. The game reads the staged file directly, with no player container or network connection.

Start with the bundled `players/base.bas`. The [game documentation](https://github.com/Metta-AI/polyworld/blob/main/examples/gods_of_the_arena/docs/index.html) describes observations and available BASIC commands. The same source is available under `examples/gods_of_the_arena/bots.nim` and `content.nim`.

Every hero has a free single-target melee or ranged basic attack in addition to four abilities. Basic damage grows each level and includes equipment bonuses. Idle heroes automatically acquire nearby visible enemy creeps. `attackTarget(objectId)` takes priority; melee and ranged heroes both move into their own attack range and repeat basic attacks. `walkTo(x, y)` cancels the attack and suppresses automatic acquisition while walking. Basic attacks do not spend mana or spell charges.

`attackMove(x, y)` uses the same attack-move order as the player controls. It follows a path toward that tile, stops for enemies in the hero's normal acquisition range, and resumes afterward. Like other actions, it returns 1 when accepted and 0 when rejected, and is recorded in replays.

The bundled `players/rusher.bas` sends all five heroes down mid together. It regroups toward the living team's center when any pair is more than 10 tiles apart, closing to 8 tiles before resuming. It attacks visible, vulnerable enemies within 20 tiles, favoring the enemy closest to the group's center. Otherwise it attack-moves through the middle and toward the opposing god. Dead allies are ignored until they respawn. Automatic abilities remain enabled.

## BASIC observations

Self data and visible objects are sampled for each decision and remain consistent during it, including after an action call. Spell queries read the pending casts, so a successful cast can append a spell during that decision. Object and spell indices are zero-based and may change next decision. Keep `objectId(i)` when tracking an object across decisions or calling `attackTarget`, rather than keeping its list index.

Observations are integers. `worldScale = 60000` is the number of world units per tile, and `tickRate = 24` is the number of simulation ticks per second. `selfX`, `selfY`, `objectX(i)`, `objectY(i)`, `spellX(i)`, and `spellY(i)` use whole global tiles. Facing, speed, range, and velocity retain sub-tile precision in world units. The Y component of these APIs is the second horizontal map axis, not height.

### Your hero

The existing `selfId`, `selfTeam`, `selfClass`, `selfX`, `selfY`, `selfHp`, `selfMaxHp`, `selfMana`, `selfMaxMana`, `selfGold`, `selfLevel`, `selfLayer`, and `worldTick` remain available. These additional read-only values describe the current hero:

| Value | Meaning |
| --- | --- |
| `selfMoveSpeed` | Unblocked movement speed in world units per tick, including level and equipment bonuses. |
| `selfAttackRange` | Basic-attack range in world units, measured by planar Euclidean distance between centers. Towers and barracks allow at least 105000 units measured from their occupied footprint; gods use 255000 units. |
| `selfAttackDamage` | Current basic-attack damage, including level and equipment bonuses. |
| `selfTarget` | Current ordered or automatically acquired attack target's stable object ID, or zero for none. |
| `selfAttackCooldown` | Ticks until the next basic hit could land if the target stays in range. Includes remaining recovery and the next windup, or the remainder of a current windup. An idle hero reports a full windup. Excludes chasing and is separate from ability cooldowns. Movement can cancel a swing. |
| `selfAttacksLanded` | Lifetime count of successful basic hits, preserved across respawns. Spells do not increment it. |

### Visible objects

Loop over indices `0` through `objectCount() - 1`. Object kinds are 1 = god, 2 = hero, 3 = creep, 4 = tower, and 5 = barracks. Barracks have 900 HP and become exposed after their lane towers fall. Each barracks spawns three creeps per wave, giving six per lane for each team. Destroying a barracks stops its three creeps from spawning. Destroyed buildings leave the object list and release their occupied tiles. New queries respect the same visibility filter:

| Function | Meaning |
| --- | --- |
| `objectLevel(i)` | Hero level. |
| `objectMana(i)` | Hero's current mana. |
| `objectItemId(i, slot)` | Hero's held item ID, using the same IDs as `itemId` and `buyItem`. Zero means no item. Slots are 0 through 5. |
| `objectItemCount(i, slot)` | Stack count in that hero's inventory slot. |
| `objectFacingX(i)`, `objectFacingY(i)` | Normalized horizontal facing, scaled by `worldScale`. A unit facing positive X reports `(60000, 0)`. |
| `objectTarget(i)` | Current attack target's stable object ID, or zero if absent or not visible to your team. |
| `objectVelX(i)`, `objectVelY(i)` | Actual displacement over the last simulation tick in world units, including collision adjustments. Stationary objects report zero. |

These new object queries return zero for invalid indices or fields that do not apply to that object. Invalid inventory slots also return zero. Hero level, mana, and inventory queries return zero for non-heroes. An object's ID is not a valid substitute for its list index.

### Pending spells and warnings

Loop over `0` through `spellCount() - 1`. This list contains unresolved casts from their start through impact, including projectiles and area warnings. Allied casts are observable; enemy casts require their aim position to be visible, matching the viewer's warning visibility. Completed effects are omitted.

| Function | Meaning |
| --- | --- |
| `spellAbility(i)` | Ability enum ID from `content.nim`, beginning at zero. Invalid indices return -1. |
| `spellCasterId(i)` | Caster's stable object ID, or zero if the enemy caster is hidden. |
| `spellX(i)`, `spellY(i)` | Aim/impact position or area center in whole global tiles. This is not the projectile's interpolated flight position. |
| `spellImpactTick(i)` | Absolute simulation tick at impact. Subtract `worldTick` to obtain the remaining ticks. |

Other invalid spell queries return zero. Visibility of an enemy warning does not reveal its hidden caster's identity.

## Action feedback

`lastActionError()` returns the reason for your hero's latest submitted
command. A successful action clears it to `NoActionError` (0). A failed
action returns 0 as before, and sets the first failing validation reason.
Read-only queries and internal automatic spell attempts do not change it.
Unlike the sampled self data, this query updates immediately after commands.

```basic
accepted = castTarget(1, targetId)
if accepted = 0 and lastActionError() = ActionInsufficientMana then
  print "Need more mana"
end if
```

Read-only reason constants are `NoActionError`, `ActionNotAlive`,
`ActionInvalidSlot`, `ActionUnknownItem`, `ActionInsufficientGold`,
`ActionAlreadyEquipped`, `ActionStackFull`, `ActionInventoryFull`,
`ActionEmptySlot`, `ActionNotConsumable`, `ActionFullHealth`, `ActionFullMana`,
`ActionTargetUnavailable`, `ActionOutOfRange`, `ActionNoRoute`,
`ActionInvalidPoint`, `ActionCooldown`, `ActionNoCharges`,
`ActionInsufficientMana`, and `ActionSpellLimit` (values 0 through 19).
Unavailable targets share a generic error without exposing hidden state.
This feedback is recorded deterministically through submitted replay actions.

For post-match analysis, the [replay extractor](../../docs/stats.md#gota-replay-events)
resimulates an exact-version replay and exposes typed damage, healing,
death, reward, and rejection events for all players. Its omniscient buffer
is not available to live BASIC policies.

## Terrain and execution

BASIC can inspect the complete static terrain with `terrainKind(x, y)`, `terrainWalkable(x, y)`, `terrainHeight(x, y)`, and `terrainWaterDepth(x, y)`. These use global tile coordinates on `selfLayer`. Each has an explicit `At(x, y, layer)` version, such as `terrainKindAt(x, y, GroundLayer)`. Read-only constants expose `mapWidth`, `mapHeight`, `mapLayers`, the layer names, and terrain kinds. Height and water depth use eighths of a tile; invalid or absent tiles return zero. The Terrain API section of the game documentation lists all constants and edge cases. Static terrain is available through fog, while enemy objects remain visibility-filtered. Walkability also includes team-known building footprints; unseen enemy destruction does not reveal newly open tiles.

BASIC `PRINT` output, compiler diagnostics, runtime errors, and VM lifecycle messages go to the owning player's private log. Each log is limited to 10 MiB. Runtime limit errors disable that VM; other seats continue. Invalid BASIC syntax fails the episode with a player failure diagnostic. Public game logs and action replays contain no BASIC source or private print output.

Matches run up to 28,800 deterministic ticks (20 simulated minutes), without real-time pacing. Replays run entirely in the browser with playback, seeking, speed, and loop controls. The server exposes `/healthz`; legacy clients are static stubs.

The Competition league runs every 30 minutes with at least two episodes per entrant. Separate baseline filler policies complete short rosters. Fillers are not ranked entrants. Standings use binary win scores and platform Elo.

## BASIC numbers and coordinates

BASIC uses [Bassy](https://github.com/treeform/bassy) with [Fixxy](https://github.com/treeform/fixxy) Q16.16 decimals enabled. Globals and arrays retain fractional values across decisions. `/` performs decimal division; `\` performs integer division. Decimal operands must fit -32768 through 32767.99998. Integer-only calculations retain the full signed 32-bit range. When converting large world-unit observations, divide them as integers first, for example `(selfAttackRange \ 100) / (worldScale \ 100)` in GotA.

`and`, `or`, `xor`, and `not` are bitwise. Comparisons produce -1 for true and 0 for false; conditions accept any nonzero number. Host flags and action results remain 1 or 0, so use `flag = 0` instead of `not flag` to negate a host flag.

`walkTo(x, y)`, `attackMove(x, y)`, and `castPoint(slot, x, y)` accept fractional tile coordinates. For example, `walkTo(selfX + 0.25, selfY - 0.25)` selects a point a quarter tile from the current tile center. Integers continue to name tile centers. IDs, slots, indices, and terrain queries require exact integers. Passing a fractional value to an integer argument raises a BASIC error instead of truncating it. Accepted fractional destinations are preserved in action replays.
