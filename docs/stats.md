# Shared match statistics

The three viewers use `src/polyworld/stats.nim`. The overlay reuses the
existing panel, portrait well, label, bar, and faction colors. Sparklines
are drawn by `chrome.nim` using the existing triangle renderer.

Hold TAB to show the table temporarily. The Stats button beside the camera
control toggles it independently. Releasing TAB preserves the button's
selection. Losing focus clears held-key visibility. The simulation, camera,
HUD, and transport keep updating and drawing behind the table. Mouse input
inside the table does not reach the world or covered HUD controls.

The window fits its actual roster and scrolls when necessary. It has no
game title or footer. Gota keeps blue and red kill totals above Players.

Rows rank by gold, highest first. Gota sorts within its blue and red teams.
Light vs Dark sorts by gold gathered across all players. Adventure sorts by
carried plus banked gold, so depositing loot preserves its value in the
ranking. Ties use the original player seat. Live and final tables use the
same ordering, and each hero keeps its own metrics and chart history.

| Game | Rows | Columns after portrait and name |
| --- | --- | --- |
| Gods of the Arena | All heroes, grouped by team | Level, gold earned with trend, kills with stepped trend, deaths, assists, CPU%, APM |
| Light vs Dark | Two commanders | Gold gathered with trend, army value with trend, unit kills, unit losses, CPU%, APM |
| Call to Adventure | Four party members | Total gold with trend, damage with trend, healing, monster kills, CPU%, APM |

Gold earned excludes starting gold and counts combat rewards. An assist
requires damage to an enemy hero within ten seconds before its death.
Army value is the gold cost of surviving combat units, excluding workers.
Damage and healing count effective health changes, excluding overkill and
overhealing. Adventure's Gold column and trend combine carried and banked
gold. Fallen adventurers retain only their banked gold in this total.
Adventure winners follow the existing surviving-returner rules, including
ties.

CPU% is consumed BASIC instructions divided by the allotted instruction
budget for decisions in the current simulation second. It is unavailable
for a human player without a VM. APM counts accepted gameplay commands.
Rejected commands, VM operations, and queries do not contribute. Playback
reapplies recorded actions through the same validators to recover that
count. Live APM uses a rolling minute in one-second buckets, normalized over
elapsed time for matches shorter than a minute. Results use lifetime
averages for both.

Completion automatically opens the same table with victory, defeat, draw,
or hero outcome labels. The final standings remain readable if the
transport automatically loops. Dismissing the table or using a playback
control returns the overlay to the displayed simulation tick. This does
not alter playback, speed, or looping preferences.

Combat counters and assist attribution belong to simulation state. They
are cloned with checkpoints and included in simulation hashes.
Only CPU samples and the final CPU average are stored in
`ReplayData.metrics`. Each sample stores one 32-bit integer per player.
APM, gameplay counters, and charts are reconstructed during resimulation.
`loadReplay(path)` returns the entire replay without an output parameter or
separate trailer. Each client accepts only its exact gameplay version.
Older recordings use the matching archived client stored on the server.
The current client does not migrate replay payloads or emulate older rules.

History begins at tick zero and samples once per simulation second, plus
the final or saved tick. At 4,096 samples it coarsens the history while
retaining endpoints. Charts share a time axis and metric scale across
players, omit future samples when seeking, and retain per-pixel extrema.
Replay CPU uses the latest recorded sample at or before the shown tick.
APM uses reconstructed history when seeking, and revisiting a completed
tick does not count commands again. Histories and decoded CPU samples have
explicit size limits.

For viewer screenshots, build with `-d:takeScreenshot` and set
`SHOW_STATS=1` to include the overlay. Normal builds use TAB and the button.

## GotA replay events

GotA can emit typed per-tick diagnostics when compiled with
`-d:replayEvents`. `examples/gods_of_the_arena/tools/replay_extractor.nims`
enables that flag and `headless` automatically for the extractor. Run it on a
retained replay before reading game logs or opening the visual viewer:

```sh
nim r examples/gods_of_the_arena/tools/replay_extractor.nim path/to/match.replay
```

With no path it uses the checked-in demo replay. The output is a bounded,
plain-text handoff containing match metadata, two-minute team checkpoints,
per-hero decision and combat totals, rejection reasons, first and last notable
deaths, and replay verification. Both teams are included. The extractor
resimulates every tick and verifies every recorded hash, so compact output
does not mean sampled validation. It fails on incompatible, divergent, or
incomplete replays.

Use this order for agent investigations:

1. Run the extractor once and preserve its small stdout as the factual handoff.
   A coordinator or smaller analysis agent should reason from that handoff,
   not ingest the replay, full state dumps, or an entire game log.
2. Compare hero decisions, rejected-action reasons, progression checkpoints,
   deaths, structure losses, and the final result. State one concrete question
   before requesting more evidence.
3. If the summary identifies a suspicious tick, request only that event window:

   ```sh
   nim r examples/gods_of_the_arena/tools/replay_extractor.nim \
     --events 810:850 path/to/match.replay
   ```

   Raw windows are capped at 480 ticks and 200 records. Narrow the window if
   records were omitted. `--checkpoint-seconds 0` suppresses progression, and
   `--evidence N` changes the bounded first/last evidence count.
4. Open the visual replay or inspect focused source only after the compact
   evidence cannot answer the stated question. Do not paste repeated full-match
   dumps into a long-lived coordinator conversation.

For policy comparisons, summarize each replay separately and give the main
agent only the summaries plus the policy diff. Use the same seeds and roster,
and require more than one replay before treating a tactical outcome as a
general improvement. Keep runtime recordings and generated summaries out of
the repository.

Records are flat value structs from
`examples/gods_of_the_arena/events.nim`, with enums and fixed-width numbers.
The simulation does not format strings or write log files. This is an
in-memory binary representation, not a separate binary file format.

Capture includes both teams, regardless of visibility. Records retain
entity IDs, kinds, teams, hero classes, player slots, and event positions
after removal. BASIC cannot read this omniscient buffer. It exists only
in capture builds, so normal native and WASM builds have no event buffer
or event-construction work.

The buffer begins with `EntitySpawned` events at tick zero. Each advancing
tick clears it while retaining capacity, including before that tick's wave
spawns. Consume or explicitly copy records before advancing. Checkpoint
copies and restores clear the transient buffer. It is excluded from
replay payloads and state hashes, and never accumulates a match history.

| Kind | Meaning |
| --- | --- |
| `Damage` | Requested damage, effective HP removed, and raw HP before/after. Overkill can leave negative HP, but effective damage excludes it. |
| `Death` | One positive-to-nonpositive HP transition. Actor is the actual killer, including creeps and towers. `related` references the lethal damage. |
| `Assist` | Existing hero assist credit, linked to the death. |
| `Healing` | Effective healing with requested amount and HP before/after. |
| `XpGained`, `GoldGained` | Recipient, defeated source entity, amount, and related death. XP before/after is lifetime XP. |
| `GoldSpent`, `LevelChanged` | Actual resource changes. Spent amounts are negative. |
| `HealthAdjusted`, `ManaChanged` | Equipment, level, respawn, regeneration, consumable, or ability changes, distinguished by cause. Stat adjustments are not healing. |
| `SpellReleased` | Successful automatic or explicit cast with caster, aim target ID if any, slot, and ability ID. |
| `AbilityLeveled` | Explicit unlock or upgrade with hero, ability ID, and rank before/after. |
| `ItemPurchased`, `ItemConsumed` | Item ID and stack count before/after. Consumption amounts are negative. |
| `ActionRejected` | Explicit command, original numeric arguments, and typed rejection reason. Internal auto-cast candidate failures are omitted. |
| `EntitySpawned`, `EntityRespawned`, `EntityRemoved` | Entity lifecycle; corpse expiration is distinct from death. |
| `MatchEnded` | God destruction or configured time limit. `amount` is winning team (0 red, 1 blue), or -1 for timeout. A partial recording does not imply a match ended. |
| `PortalStarted`, `PortalCompleted`, `PortalInterrupted` | Scroll channel lifecycle. Start/interruption reference the selected tower; completion references the hero at arrival. |
| `Stunned`, `Rooted` | A control effect was applied to the target hero. These interrupt an active teleport. |
| `RecoveryStarted`, `RecoveryCompleted`, `RecoveryInterrupted` | Potion regeneration lifecycle. `detail` is the item ID; interruption identifies the damaging actor and affected hero. |

`related` is a zero-based index within the same tick, or -1 when absent.
It is not a persistent event ID. `detail` is an ability or item enum ID
where applicable. Amounts and before/after values are signed 64-bit
integers. Actor and target metadata use -1 for absent team/class/player,
and zero for absent entity ID/kind. Rejected commands preserve raw IDs in
`first`, `second`, and `slot` without resolving hidden target metadata.

The event log preserves current damage, reward, and validation rules. No
new nearby-player XP or gold distribution is introduced. Movement traces,
pathfinding logs, and automatic failure spam are not included.

### Live action errors

`lastActionError()` is available to BASIC even without `replayEvents`.
A successful submitted action clears it to `NoActionError` (0). A rejected
action sets the first failing validator's reason. Queries and automatic
casts leave it unchanged. Read it immediately after a command to diagnose
that attempt; multiple commands in one decision replace the latest value.
This per-hero value is checkpointed and hashed, because a bot can branch
on it. It reveals only that hero's own command error. Unavailable targets
use a generic reason rather than revealing hidden object state.

Named read-only BASIC constants match `ActionError` in `events.nim`:

| Value | Constant |
| --- | --- |
| 0 | `NoActionError` |
| 1 | `ActionNotAlive` |
| 2 | `ActionInvalidSlot` |
| 3 | `ActionUnknownItem` |
| 4 | `ActionInsufficientGold` |
| 5 | `ActionAlreadyEquipped` |
| 6 | `ActionStackFull` |
| 7 | `ActionInventoryFull` |
| 8 | `ActionEmptySlot` |
| 9 | `ActionNotConsumable` |
| 10 | `ActionFullHealth` |
| 11 | `ActionFullMana` |
| 12 | `ActionTargetUnavailable` |
| 13 | `ActionOutOfRange` |
| 14 | `ActionNoRoute` |
| 15 | `ActionInvalidPoint` |
| 16 | `ActionCooldown` |
| 17 | `ActionNoCharges` |
| 18 | `ActionInsufficientMana` |
| 19 | `ActionSpellLimit` |
| 20 | `ActionChanneling` |
| 21 | `ActionStunned` |
| 22 | `ActionRooted` |
| 23 | `ActionOutsideKeep` |

Gameplay version 45 includes keep-only shopping, potion recovery and cooldowns,
and fast spawn recovery. Potion effects, channels, shared cooldowns, and control
effects are hashed. Playback regenerates the same events and diagnostic state.
This client accepts only version 45; older recordings
require their archived client.

Rejected movement and ground casts include `offsetX` and `offsetY`, signed Q16.16 offsets from the named tile center. Multiply by 1/65536 to read the fractional tile component.
