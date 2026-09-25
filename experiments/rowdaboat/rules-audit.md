# Gods of the Arena rules audit

Audited 2026-09-25. This is a source/release audit, not a scored experiment.
No policy was changed and no local games were run.

## Source and release boundary

- Repository: `git@github.com:Metta-AI/polyworld.git`.
- The original nested checkout is stale at `7f50a61`. Its fetched `origin/main`
  is `23f3384e7ffc0d73379f41a308967755e361f433`.
- The adjacent `board+cards game/polyworld` checkout at `e2c9033` is also stale
  for current GotA rules; it still describes automatic spells.
- Latest fetched hosted release receipt: `coworld/releases/2026-09-24-gota-towers.json`.
  Version `2026.9.24.2`, Coworld `cow_e282a46f-31c4-43b1-a9e2-aaa31d3aaed4`,
  gameplay replay version **64**, source `f4456bea13d967cb3f188df357656e1410cb0a40`.
  The receipt records hosted certification, smoke, and completed round 742.
  Verify the live league lock before any new XP or replay analysis; a receipt
  does not prove the current canonical release has remained unchanged.
- Known league ID: `league_3c60897b-25cf-4b37-9d1a-8554c1198f28`.
  Game page: <https://softmax.com/gods-of-the-arena>.

Authoritative source references below are paths at fetched `origin/main`, not
the stale working-tree files. Read them with `git show origin/main:PATH` or
use an isolated checkout at the exact hosted release.

## Changes an old policy will miss

| Release/change | Consequence |
| --- | --- |
| September 21: draft, explicit ability levels, keep shop, fractional BASIC | Pick immediately; spend ability points; buy only in own keep; use current numeric semantics. |
| September 23 / replay 60: automatic abilities removed | Every Q/W/E/R, including formerly passive slot 0, needs explicit `castTarget` or `castPoint`. Items also require explicit use. |
| September 23 / replay 61: control effects | Stun, root and silence now affect live tactics and portal interruption. |
| September 23 / replay 62: neutral camps | Fourteen camps provide XP/gold and can be pulled into allied creeps. Baseline and new `puller.bas` demonstrate support. |
| September 24 / replay 63: hero rebalance and reward changes | Building kill XP is 200; god victory grants every teammate 1,000 XP. Ten hero stat profiles changed. |
| September 24 / replay 64: tower attacks and mailboxes | Towers reach 9/9.5/10 tiles, preserve reload and launch homing shots. Team/global/direct bot messages are available. |

Notable current profile values in `content.nim`: Ranger starts with 25 HP and
gains only 1 HP/level; Crossbowman's attack interval is 126 ticks; Demon Hunter
base movement is 10,094 world units/tick; Vanguard gains 88 HP/level. These are
source facts, not evidence that choosing a particular class improves hosted XP.

## Scoring and deployment

- A hero's score is `max(0, floor(lifetime XP - 200 * simulated minutes))`.
  Draft time counts. Losses/timeouts retain this time-adjusted XP. Victory is
  a separate outcome; win rate is not the actual ladder score.
- God destruction gives **all five** heroes on the winning team 1,000 XP,
  including dead/distant/max-level heroes, before final scoring. Timeouts do not.
- League rounds use mixed five-versus-five teams, ten distinct policies when
  possible. The documented scheduler is random, `team_n`, blocks,
  `distinct_teammates: true`, 24 games per round, 32-minute interval.
- Standings use 15% new-round mean plus 85% previous standing; first round
  initializes the standing. Multiple seats controlled by one policy average,
  rather than multiply, its score.
- Upload raw `.bas` source. Compilation errors fail an episode; runtime limits
  disable only that VM. Private PRINT/diagnostic logs are capped at 10 MiB.
- Existing hosted API helpers: `examples/gods_of_the_arena/tools/softmax.nim`
  and `tournaments.nim`. Their generic roster selection is **not** the requested
  top-three-other-players experiment protocol and must not be used unchanged.
  The helper can resolve active champion memberships, leaderboard and league
  game-version locks while keeping credentials out of records.

## Mechanics that affect strategy

- Draft: ten unique classes shared across teams; alternating picks; only the
  active player executes, every half second. Each picker has ten seconds, then
  gets a random remaining hero. Select early to avoid score penalty.
- Basic attacks are free and automatically acquire visible attackable enemies
  when idle. `attackTarget` chases/repeats; `attackMove` resumes its route after
  fights. `walkTo` cancels the attack and suppresses automatic acquisition.
  Movement can cancel a pending swing; use cooldown and landed-hit observations
  to confirm kiting still lands attacks.
- Clear all three towers in one lane to expose the two god guards. Both guards
  must die before the god can take attacks or spells. Guard towers have 3,900 HP
  and 60 damage. Tower/barracks last hit gives the hero 200 XP and 75 gold.
- Tower outer/inner/gate-and-guard attack, sight and portal radii are 9/9.5/10
  tiles. Shots fire once per second, keep their original target outside range
  and into fog, and survive tower death. Killing the target removes the shot.
  Retreating after launch does not evade it.
- Each lane has six melee and two ranged creeps per wave. A killed enemy creep
  shares 15 XP among living allied heroes within six tiles on the same floor.
  Eligible hero last hitter gets 15% first plus an equal share of the remaining
  85%, and 15 gold. Buildings/creeps landing the kill give heroes no gold.
- Neutrals: low/medium/high normal mobs have 100/180/300 HP, 8/14/20 damage,
  20/35/50 XP and 10/20/30 last-hit gold. Leaders double HP and rewards and
  multiply damage by 1.5. Only the last-hit team's nearby heroes share XP.
- Camps aggro within two tiles with line of sight or when damaged. Twelve-tile
  leash, dead aggressor or three seconds out of sight makes survivors return,
  become invulnerable and heal. Full camp respawns 60 seconds after final death,
  blocked while any living hero is within ten tiles. New IDs appear on respawn.
- Abilities start locked with one point available. Q/W/E ranks require levels
  1/3/5/7; R requires 6/12/18. Later ranks add 50% of rank-one effect. Cost,
  range, charges and timing remain fixed. Upgrading preserves used charges.
- Vanguard R stuns one second, Warlock E silences two, Druid R roots two,
  Lich E roots one. Buildings/gods are immune. Silence permits basic attacks,
  movement and items; root permits in-range attacks/abilities/items but no
  movement/portal; stun stops all and cancels a swing. Released spells resolve.
- Shop only inside own keep. Own spawn restores 20% max HP and mana per second.
  Potions stack to eight, share separate health/mana ten-second cooldowns and
  stop regeneration on damage. Instant elixirs trade cost for immediate effect.
- Portal scroll: 100 gold, three-second channel, 60-second shared cooldown;
  destination clamps to visible walkable space around a living allied tower.
  Stun/root/death/anchor death interrupt; ordinary damage and silence do not.
- First death respawns after nine seconds, then +5 seconds/death capped at 60.
  Buyback costs 100 gold times lifetime deaths and immediately restores the
  hero with full HP/mana/learned charges. Current baseline buys back whenever
  affordable; this is a candidate hypothesis to audit, not a proven optimum.

## Reference-policy changes

`examples/gods_of_the_arena/players/base.bas` now includes bounded observation
scans, missing-role draft, R/W/E/Q rank ordering, explicit ability casting,
class-specific range/shape tables, ally healing, leading area casts, warning
dodges, recovery, equipment, portals, buyback, lane farming and nearby camps.
Main decisions run every six ticks. Host range/shape queries are absent, so the
policy tables must be checked against the exact release's `content.nim`.

Latest base changes are `fd315c8` (explicit casting, healing, ring/projectile
target fixes), `e42c482` (control-aware casts), `2c8db6e` (neutral farming).
`puller.bas` adds approach/lure/allied-creep handoff with a 15-second timeout
and 20-second retry delay. `rusher.bas` remains basic-attacks-only and is not
a complete modern casting reference.

## Observation, language and evidence pitfalls

- Object indices expire each decision; preserve stable IDs and validate an
  index before reuse. All bots see the same frozen decision-phase objects;
  own inventory/command results and `lastActionError()` update immediately.
- Positions are whole global tiles; range, facing and velocity use world units
  (`worldScale = 60000`, `tickRate = 24`). Team-relative rounding matters for
  mirrored geometry. Static terrain/camp locations are public; enemies are
  visibility-filtered. Replay extractors may inspect omniscient state only
  after the match, never feed it into live policy observations.
- BASIC uses Q16.16 decimals; `/` is decimal division, `\` integer division.
  Convert large world values through integer division before decimal math.
  IDs/indices/terrain queries require exact integers.
- Logical-looking operators are bitwise. Comparisons yield -1/0; host flags
  yield 1/0. Test `flag = 0`, not `not flag`.
- VM limits in `bots.nim`: 64 KiB source, 20,000 instructions/decision,
  50,000 work units, 32 arrays, 4,096 elements, 256 globals, 64 routines.
- `sendChat(-1, text)` broadcasts to team, `-2` to all, nonnegative ID to one
  roster slot (0–9, separate from hero object IDs). Inboxes hold 100 messages,
  each at most 1,024 bytes. Broadcast includes sender. `pullMailbox$()` consumes
  oldest; `mailboxId()` is channel or DM sender, with no separate sender/time
  for broadcasts. Delivery follows script execution order. **Chats are not
  recorded in replays**, so a talking experiment requires private-log proof.
- Exact-version Nim replay entrypoint:
  `examples/gods_of_the_arena/tools/replay_extractor.nim PATH`.
  Its `.nims` enables headless/replay events. It verifies recorded hashes and
  all actions consumed. Copy/adapt loops to report only relevant events rather
  than dump every tick. Typed damage, XP, gold, deaths, spells, ability upgrades,
  purchases, consumption, rejection and portal events are available. Movement
  should be sampled from world positions; it is not a dedicated event stream.

## Useful next replay questions (unscored hypotheses)

1. Do leaders earn their advantage from neutral farming, hero kills, or the
   doubled building/victory rewards? Partition hosted replay XP by source.
2. How much time do leaders spend fighting, walking, dead and in spawn, and
   how do their resource/portal/buyback decisions compare with our champion?
3. Do spell commands result in useful damage/control or repeated rejection?
   Partition by class, slot, target kind and remaining charges.
4. Does tower damage dominate avoidable deaths since replay 64? Attribute
   incoming damage and in-flight shots before retreats, without treating a
   mean difference as a keep decision.

All candidate keeps remain subject to the user's hosted XP/dashboard significance
gate against the current submitted policy, each evaluated against the current
top three unique other players. No local performance estimate is score evidence.
