# Gods of the Arena

**New GotA week: everyone needs to update their bot.** Handle the draft, spend ability points, buy only in your own keep, and review the new BASIC number semantics and lane rewards; start from the updated `players/base.bas`.

Two teams of five BASIC heroes battle to slay the enemy god. Every hero on the winning team scores one win. A time limit without a god being slain gives everyone zero.

The gods are the objectives: Hades for Red and Zeus for Blue. Each god has two level-3 guard towers. Clearing all three towers in any one lane exposes the guards. The god cannot take damage from attacks or spells until both of its guards are destroyed. Guards have the same 3900 HP and 60 damage as level-3 lane towers.

Slots 0–4 are Red and slots 5–9 are Blue. Platform slots are zero-based. Upload a `.bas` file containing BASIC source. The game reads the staged file directly, with no player container or network connection.

Start with the bundled `players/base.bas`. The [game documentation](https://github.com/Metta-AI/polyworld/blob/main/examples/gods_of_the_arena/docs/index.html) describes observations and available BASIC commands. The same source is available under `examples/gods_of_the_arena/bots.nim` and `content.nim`.

The baseline is a playable reference for all 68 GotA host functions. It drafts
missing roles, farms lanes, prioritizes last hits, pushes exposed buildings and
the enemy god, upgrades and explicitly casts spells, leads area shots, dodges
visible warnings, and uses enemy stats and equipment to judge fights. It also
shops, stacks and uses recovery items, returns to spawn, uses portal scrolls,
and buys back when affordable. Actions are conditional on a useful opportunity,
so one match need not exercise every mechanic. Its observation scans are bounded
and its main decisions run every six ticks. Automatic spells remain enabled.
Spell ranges and shapes are not queryable, so their small policy table must
follow balance changes in `content.nim`; health, damage, costs, and ranks use
live observations. This is an editable starting point, not an optimal policy.

Every hero has a free single-target melee or ranged basic attack in addition to four abilities. Basic damage grows each level and includes equipment bonuses. Idle heroes automatically acquire nearby visible enemy creeps. `attackTarget(objectId)` takes priority; melee and ranged heroes both move into their own attack range and repeat basic attacks. `walkTo(x, y)` cancels the attack and suppresses automatic acquisition while walking. Basic attacks do not spend mana or spell charges.

`attackMove(x, y)` uses the same attack-move order as the player controls. It follows a path toward that tile, stops for enemies in the hero's normal acquisition range, and resumes afterward. Like other actions, it returns 1 when accepted and 0 when rejected, and is recorded in replays.

The bundled `players/rusher.bas` sends all five heroes down mid together. It regroups toward the living team's center when any pair is more than 10 tiles apart, closing to 8 tiles before resuming. It attacks visible, vulnerable enemies within 20 tiles, favoring the enemy closest to the group's center. Otherwise it attack-moves through the middle and toward the opposing god. Dead allies are ignored until they respawn. Automatic abilities remain enabled.

## Drafting

Every live match starts with a shared pool of ten heroes. A seeded random
team picks first. Teams alternate, and each team's players pick in spawn
order. Each hero can be selected once across both teams. Combat, waves,
and the battle clock wait until all ten players have drafted.

Only the active player's BASIC script runs during drafting, once every
half second. Every player, including humans, has ten simulation seconds to
pick. At the deadline, the game picks a random available hero if the player
has not chosen one. The bundled base and rusher scripts try to fill
five roles: frontline, carry, mage, support, and fighter. This is a policy
preference, not a draft rule. Any combination of available heroes is allowed.
Their normal movement and combat logic runs after drafting.

| Data or command | Meaning |
| --- | --- |
| `drafting` | 1 during drafting, 0 during battle. |
| `draftTurnId` | ID of the player picking now, or 0 after drafting. |
| `draftPlayerCount()` | Number of players in the public roster. |
| `draftPlayerId(i)` | Player ID at zero-based spawn index `i`, or 0 if invalid. |
| `draftPlayerTeam(i)` | Team at spawn index `i`: Red 0, Blue 1, invalid -1. |
| `draftedClass(id)` | Hero class picked by player ID, or -1 if unpicked or invalid. Both teams' picks are public. |
| `heroAvailable(class)` | 1 if the class is valid and unpicked, otherwise 0. |
| `heroRole(class)` | Frontline 0, carry 1, mage 2, support 3, fighter 4, invalid -1. |
| `draftHero(class)` | Selects a hero on your turn. Returns 1 on success, 0 on rejection. |

`selfClass` is -1 until your pick. Class constants are `VanguardKnight`,
`Ranger`, `Arcanist`, `DruidWarden`, `DemonHunter`, `DeathKnight`,
`Crossbowman`, `Lich`, `Warlock`, and `Berserker`, with IDs 0 through 9.
Draft queries update immediately. Other sampled self data updates next
turn. `worldTick` includes draft ticks for action replay timing.

```basic
if drafting then
  for candidate = 0 to 9
    if heroAvailable(candidate) then
      draftHero(candidate)
      exit for
    end if
  next
else
  attackMove(mapWidth / 2, mapHeight / 2)
end if
```

`lastActionError()` reports `ActionNotDrafting`, `ActionNotDraftTurn`,
`ActionUnknownHero`, or `ActionHeroTaken` for rejected picks. Normal game
commands are rejected with `ActionDrafting` while players are picking.
In player mode, select an available hero in the drafting screen and click
**Lock in hero** when it is your turn. The current picker appears above
the hero grid. Picked heroes turn gray and show their player and team.
The countdown shows the active pick's remaining time. Space pauses or
resumes drafting, including the countdown. Drafting has a separate budget
of up to 100 simulation seconds for ten players. The configured `maxTicks`
and CLI duration flags limit battle time only, starting after the last pick.

## Ability progression

Heroes start at level 1 with one ability point and all four abilities locked.
Each hero level grants another point. Points remain banked until a command
spends them. `levelAbility(slot)` spends one point to unlock rank 1 or upgrade
an already learned ability. Slots 0, 1, 2, and 3 correspond to Q, W, E, and R.

Q, W, and E have four ranks requiring hero levels 1, 3, 5, and 7.
R has three ranks requiring hero levels 6, 12, and 18. Each additional rank
adds 50% of the rank-1 damage, healing, or mana restoration, rounded down.
Mana costs, range, charge capacity, and timing stay the same. An upgrade
preserves spent charges and running cooldowns. Pending spells retain the
rank they had when cast. Respawning preserves learned ranks and banked
points and refills only learned abilities.

Hero stats, including basic-attack damage, still grow automatically with
hero level. Ability ranks never increase automatically. The bundled base
and rusher policies explicitly spend points, prioritizing R, W, E, then Q.
Their existing automatic casting uses only learned abilities. Custom
policies can bank points or choose another order. At level 20, fully ranking
all four abilities leaves five banked points.

| BASIC function | Meaning |
| --- | --- |
| `levelAbility(slot)` | Unlock or upgrade. Returns 1 on success, 0 on rejection. |
| `abilityPoints()` | Current unspent points. |
| `abilityLevel(slot)` | Current rank, with 0 meaning locked. |
| `abilityMaxLevel(slot)` | Rank limit: 4 for slots 0-2, 3 for slot 3. |
| `abilityRequiredLevel(slot)` | Hero level required for the next rank, or 0 at maximum rank. |
| `canLevelAbility(slot)` | 1 when alive with a point and the required level, otherwise 0. |
| `abilityDamage(slot)` | Damage per target at the learned rank, or 0 when locked. |
| `abilityHeal(slot)` | Healing per target at the learned rank, or 0 when locked. |
| `abilityRestore(slot)` | Mana restoration at the learned rank, or 0 when locked. |
| `abilityManaCost(slot)` | Mana cost of a cast, including while locked. |

These queries update immediately after commands and return 0 for invalid
slots. `abilityCharges(slot)`, `abilityCooldown(slot)`, and
`abilityRecharge(slot)` remain available. Locked abilities have no charges.
Upgrade actions and rejected attempts are recorded for deterministic replays.

```basic
if canLevelAbility(3) then
  levelAbility(3)
elseif canLevelAbility(1) then
  levelAbility(1)
end if
```

Player controls use Shift+Q/W/E/R, Shift-click on an ability, or its gold
"+" button to spend a point. The HUD shows current ranks, locked abilities,
and available points.

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
| `selfPortalCooldown` | Ticks before another Portal Scroll can be used, shared across all inventory stacks and preserved through death. |
| `selfChannelTicks` | Ticks remaining in the current teleport channel, or zero. |
| `selfStunTicks`, `selfRootTicks` | Ticks remaining in these control effects, or zero. |

### Shop, potions, and spawn recovery

Purchases only work inside your own keep, including its spawn room. Elsewhere,
`buyItem(id)` returns 0 with `ActionOutsideKeep`. `canShop()` returns 1 when
purchases are allowed, and `inOwnSpawn()` returns 1 inside your living hero's
own spawn room. These queries read live state.

Inside that spawn room, health and mana each recover at **20% of maximum per
second**, capped at maximum. The larger keep and the enemy spawn give no such
recovery. Normal passive mana regeneration still applies. Damage does not
turn off spawn recovery, and dead heroes cannot recover until they respawn.

| ID | Item | Gold | Effect |
| --- | --- | --- | --- |
| 1 | Health Potion | 30 | 120 health over 10 seconds. |
| 2 | Vitality Elixir | 75 | 90 health immediately. |
| 22 | Mana Potion | 45 | 90 mana over 10 seconds. |
| 3 | Mana Elixir | 90 | 60 mana immediately. |

Each stacks to **8** per slot. `useItem(slot)` spends one dose. Any positive
incoming damage interrupts both active potion regeneration effects; movement
and attacks do not. Health items share a **10-second** cooldown, and mana items
share a separate **10-second** cooldown. Cooldowns begin on use and survive
interruption and death. Full health/mana or a cooldown rejects use without
spending a dose. `itemCooldown(slot)` returns live remaining ticks (24 per
second), or 0 for empty/invalid slots. Inventory icons show stack counts and
remaining cooldowns.

### Portal Scrolls

Buy item **21** for **100 gold**. Scrolls stack to eight per slot. Call
`useItemAt(slot, x, y)` with whole or fractional map coordinates to consume
one scroll and begin a **3-second** channel. The destination is the nearest
visible, walkable point inside a living allied tower's sight radius:
7 tiles for outer/inner towers, 8 for gate/guard towers. Barracks are not
anchors. A distant requested point is clamped into this area; there is no
travel-distance limit. The selected tower must survive until arrival.

The hero cannot move, attack, or cast while channeling, and still takes
damage. Stuns, roots, death, or loss of the anchor interrupt the channel.
The scroll is spent when the channel begins. Completion or interruption
starts a **60-second** cooldown shared by every scroll the hero holds.
Damage alone does not interrupt it. Current spells have no stun/root
effects; the simulation's stun/root APIs support interruption when applied.
`useItem(slot)` rejects scrolls because they require a destination.

For human play, click the inventory scroll (or press F/G for the first two
slots), then right-click the map or minimap. Purple circles show tower range, and a
channel bar shows the time remaining. Esc cancels destination selection.

### Visible objects

Loop over indices `0` through `objectCount() - 1`. Object kinds are 1 = god, 2 = hero, 3 = creep, 4 = tower, and 5 = barracks. Barracks have 950 HP and become exposed after their lane towers fall. Each barracks spawns three melee creeps and one ranged creep per wave, giving six melee creeps and two ranged creeps per lane for each team. Ranged creeps carry a staff and cast magic bolts from up to four tiles away. Destroying a barracks stops its four creeps from spawning. For creeps, `objectClass(i)` is 0 for melee and 1 for ranged. Destroyed buildings leave the object list and release their occupied tiles. New queries respect the same visibility filter:

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

Each slain enemy creep provides a shared pool of 15 XP to living heroes within six tiles on the same navigation floor, regardless of starting lane. If the last hitter is among these heroes, they receive 15% of the pool first, then the remaining 85% is split equally among all nearby heroes, including the last hitter. With three heroes, this gives 6.5 XP to the last hitter and 4.25 XP to each teammate. Fractional XP carries forward between kills. If no eligible hero lands the last hit, the full pool is shared equally. A hero last hitter also receives 15 gold; tower and creep last hits grant no gold to heroes.

### Pending spells and warnings

Loop over `0` through `spellCount() - 1`. This list contains unresolved casts from their start through impact, including projectiles and area warnings. Allied casts are observable; enemy casts require their aim position to be visible, matching the viewer's warning visibility. Completed effects are omitted.

| Function | Meaning |
| --- | --- |
| `spellAbility(i)` | Ability enum ID from `content.nim`, beginning at zero. Invalid indices return -1. |
| `spellCasterId(i)` | Caster's stable object ID, or zero if the enemy caster is hidden. |
| `spellX(i)`, `spellY(i)` | Aim/impact position or area center in whole global tiles. This is not the projectile's interpolated flight position. |
| `spellImpactTick(i)` | Absolute simulation tick at impact. Subtract `worldTick` to obtain the remaining ticks. |

Other invalid spell queries return zero. Visibility of an enemy warning does not reveal its hidden caster's identity.

## Death and buyback

The first death takes 9 seconds to respawn, including the 1-second death
animation. Each subsequent death adds 5 seconds, up to a total of 60 seconds.
Death counts belong to each hero and persist after respawning.

`selfDeaths` is the hero's death count. `selfRespawnTicks` is the remaining
respawn delay in ticks, or zero while alive. BASIC decisions continue while
dead so a policy can request buyback.

`buybackPrice()` returns the dead hero's price: 100 gold times their death
count. It returns zero while alive or after the match ends. The price stays
fixed during a death, even as the respawn timer counts down.

`buyback()` returns 1 when accepted and 0 when rejected. It spends the
hero's gold and immediately respawns them with full health, mana, and spell
charges. It preserves inventory, level, XP, and death count. A living hero,
an ended match, or insufficient gold causes rejection without spending gold.
The HUD shows the countdown, buyback price, and any rejection reason while
dead. Buyback attempts are recorded for replay and seeking.

The bundled `players/base.bas` buys back as soon as it can afford the price.
While dead it skips normal commands, resuming them on the decision after buyback.

```basic
if selfRespawnTicks > 0 then
  price = buybackPrice()
  if price > 0 and selfGold >= price then
    accepted = buyback()
  end if
end if
```

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
`ActionInsufficientMana`, `ActionSpellLimit`, `ActionChanneling`,
`ActionStunned`, `ActionRooted`, `ActionOutsideKeep`, `ActionAbilityLocked`,
`ActionNoAbilityPoints`, `ActionAbilityMaxLevel`, `ActionHeroLevelRequired`,
`ActionNotDead`, `ActionMatchEnded`, `ActionDrafting`, `ActionNotDrafting`,
`ActionNotDraftTurn`, `ActionUnknownHero`, and `ActionHeroTaken`
(values 0 through 34).
Unavailable targets share a generic error without exposing hidden state.
This feedback is recorded deterministically through submitted replay actions.

For post-match analysis, the [replay extractor](../../docs/stats.md#gota-replay-events)
resimulates an exact-version replay and exposes typed damage, healing,
death, reward, and rejection events for all players. Its omniscient buffer
is not available to live BASIC policies.

## Terrain and execution

BASIC can inspect the complete static terrain with `terrainKind(x, y)`, `terrainWalkable(x, y)`, `terrainHeight(x, y)`, and `terrainWaterDepth(x, y)`. These use global tile coordinates on `selfLayer`. Each has an explicit `At(x, y, layer)` version, such as `terrainKindAt(x, y, GroundLayer)`. Read-only constants expose `mapWidth`, `mapHeight`, `mapLayers`, the layer names, and terrain kinds. Height and water depth use eighths of a tile; invalid or absent tiles return zero. The Terrain API section of the game documentation lists all constants and edge cases. Static terrain is available through fog, while enemy objects remain visibility-filtered. Walkability also includes team-known building footprints; unseen enemy destruction does not reveal newly open tiles.

BASIC `PRINT` output, compiler diagnostics, runtime errors, and VM lifecycle messages go to the owning player's private log. Each log is limited to 10 MiB. Runtime limit errors disable that VM; other seats continue. Invalid BASIC syntax fails the episode with a player failure diagnostic. Public game logs and action replays contain no BASIC source or private print output.

Battles run up to 28,800 deterministic ticks (20 simulated minutes), plus drafting time, without real-time pacing. Replays run entirely in the browser with playback, seeking, speed, and loop controls. The server exposes `/healthz`; legacy clients are static stubs.

The Competition league runs every 30 minutes with at least two episodes per entrant. Separate baseline filler policies complete short rosters. Fillers are not ranked entrants. Standings use binary win scores and platform Elo.

## BASIC numbers and coordinates

BASIC uses [Bassy](https://github.com/treeform/bassy) with [Fixxy](https://github.com/treeform/fixxy) Q16.16 decimals enabled. Globals and arrays retain fractional values across decisions. `/` performs decimal division; `\` performs integer division. Decimal operands must fit -32768 through 32767.99998. Integer-only calculations retain the full signed 32-bit range. When converting large world-unit observations, divide them as integers first, for example `(selfAttackRange \ 100) / (worldScale \ 100)` in GotA.

`and`, `or`, `xor`, and `not` are bitwise. Comparisons produce -1 for true and 0 for false; conditions accept any nonzero number. Host flags and action results remain 1 or 0, so use `flag = 0` instead of `not flag` to negate a host flag.

`walkTo(x, y)`, `attackMove(x, y)`, and `castPoint(slot, x, y)` accept fractional tile coordinates. For example, `walkTo(selfX + 0.25, selfY - 0.25)` selects a point a quarter tile from the current tile center. Integers continue to name tile centers. IDs, slots, indices, and terrain queries require exact integers. Passing a fractional value to an integer argument raises a BASIC error instead of truncating it. Accepted fractional destinations are preserved in action replays.
