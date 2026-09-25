# Richard v245: hosted replay mechanism audit

Date: 2026-09-25. Source: https://softmax-public.s3.amazonaws.com/replays/bc421d3a-4b92-42ed-b74d-58503bfb6e6b.replay

Metadata: `richard-latest-replay.json` in this directory, league round 773, hosted episode `dedfab55-3096-4c68-915f-2321489b37d1`, co-world `2026.9.24.2`. Its participants map zero-based seat 9 to `richard-gods-of-the-arena:v245`, policy version ID `7fd19643-c66a-429e-ba24-3c1e6c0d8e06`. Seat 4 is `arisk-gods-of-the-arena:v4`. The replay config independently identifies seat 9 as richard.

The exact-version Nim auditor reproduced **29,365/29,365 hashes with zero mismatches** and consumed all recorded actions. No local games were generated. These league-replay diagnostics identify mechanisms only and provide no trial score or significance evidence.

## Recovery cancellation confirmed in another top-three player

Richard plays Warlock, whose native basic-attack period is 28 ticks and windup is 12 ticks. He lands a basic hit on neutral ID 1050 at tick 1246 for 30 damage, issues a walk at tick 1247 to `(56,87)`, reissues the attack at 1248, then lands another basic hit on ID 1050 at 1259 for 30: **13 ticks between hits instead of 28**.

The full replay has **173 rapid same-target basic-hit pairs with an intervening walk and reattack, from 391 total basic hits**. Richard's walk commands show 13-tick recurrence in sustained combat, for example 2003, 2016, 2029, 2042, 2055, 2068, 2081, 2094. Details including every intervening command and both hit events are in `gota-richard-attack-recovery.json`.

This corroborates the same mechanism seen in Andre von Auto's Berserker: immediate post-hit walk followed by reattack removes the remaining recovery interval. Andre had 52 detected pairs from 172 basic hits in the independently verified round-772 replay. These counts are descriptive mechanism evidence; they do not measure an XP benefit. Ari has zero detected pairs in both inspected recordings, so the tactic is neither universal nor sufficient by itself to explain leaderboard position.

`selfAttacksLanded` provides an explicit successful-hit counter to trigger this change, preserved across respawns. The current example policy already has narrower ranged defensive kiting, conditioned on a nearby hero aiming at us. The distinct strategy to test is an immediate recovery reset after a newly confirmed hit, before the ordinary six-tick decision gate. Preserve navigation, selection, shopping, casting, and drafting when testing it.

## Other observed behavior

- Drafts Warlock at tick 553. Opens primary ability at 566 and buys Amethyst Wand. Submitted opening Sapphire Ring, Steel Buckler and Ruby Amulet purchases fail for insufficient gold.
- Purchases later include Steel Buckler at 6405, Crimson Dagger and Sunsteel Longsword at 8896, Sapphire Ring at 10841, Knight Armor at 17062, and four Poison Potions. Ten total accepted purchases, 37 submissions.
- Ability order by slot is `1,2,1,2,1,3,1,2,2,0,0`. Primary and secondary reach rank 4 before the passive. Released spells: Moth Hex 56, Dread Totem 15, Void Portal 12.
- He submits 21,626 direct attacks, 444 walks, and no attack-moves. The large cast count (3,572 submissions versus 83 releases) contains 2,766 range rejections, 446 cooldown rejections, 231 no-charge rejections, and 46 unavailable-target rejections. There is no reason to copy that failed-command volume as part of the isolated recovery experiment.
- No Portal Scroll use and no healing event received in this recording. Four buybacks, 12 deaths. This differs substantially from Andre's 11 completed portals and Ari's consumable-heavy opening.
- Damage by cause: basic 22,046; ability 6,048; poison items 140. Target damage: heroes 12,234; lane creeps 8,610; neutrals 3,114; towers 4,276.
- Last hits: 10 heroes, 155 lane creeps, 15 neutrals, 3 towers. Camp engagement events: 13.
- Earned XP event decomposition: heroes 1,500; lane creep last-hit shares 1,920 and nearby shares 633; neutral last-hit shares 356 and nearby shares 127; towers 600. Sum 5,136 matches final lifetime XP. This is not a scored comparison and excludes the ladder time penalty.
- Navigation repeatedly crosses central combat regions before later side-lane farming. Samples in world coordinates: tick 4320 `(119793,1506546)`, tick 5760 `(−336033,−59570)`, tick 18720 `(52079,1752)`, tick 25920 `(917108,−1369404)`, tick 28800 `(−2573054,−1609053)`. Early repeated walks near a stationary firing position are recovery resets, not evidence of traveling a new route.

## Files

- Verified raw artifacts: `gota-campaign/tmp/replay_tools/richard-latest.{replay,actions.jsonl,events.jsonl,summary.json}`.
- Reusable Nim tools: `gota-campaign/examples/gods_of_the_arena/tools/replay_audit.nim`, `replay_strategy_report.nim`, and `attack_recovery_audit.nim`.
- Pinned dependency folder: `gota-campaign/tmp/coworld/deps`.

No policy changed and no experiment was kept or rejected from these replays. CPUX and hosted significance comparison remain the parent task's gate.
