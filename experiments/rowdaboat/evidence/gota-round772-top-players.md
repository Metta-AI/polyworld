# Hosted replay mechanism audit: round 772

Date: 2026-09-25. Source: https://d1kovwradqjymp.cloudfront.net/replays/e18546ec-d584-41aa-87dc-54ffe15d1e96.replay

The replay decoded as gameplay version 64 and reproduced **29,365 of 29,365 tick hashes with zero mismatches**; every recorded action was consumed. Built from `gota-campaign` source with the revisions in `coworld/dependencies.lock` installed only under `gota-campaign/tmp/coworld/deps`. No locally generated games were run.

This is behavior evidence, not a scored experiment, and cannot justify keeping or submitting a policy. Earned XP below is an event decomposition from this hosted league replay; no XP delta, mean comparison, or significance conclusion is drawn. Authenticated metadata for `ereq_ba4d5096-9935-4705-b974-50460f02fed2` (saved as `round772-episode.json`) confirms the same replay artifact, Andre von Auto at seat 8 (`khors:v208`, `bf6c6cc2-362e-4eee-a105-810b23adf437`) and Ari Sklar at seat 1 (`arisk-gods-of-the-arena:v4`, `61f4440b-140d-4f7d-80b8-2802f7a3100d`). Richard does not appear in this recording; his current v245 is inspected in the separate Richard report.

## Isolated finding: Andre cancels basic-attack recovery

Seat 8 is Andre von Auto, playing Berserker. The following commands and damage events are directly recorded/reproduced:

| Tick | Event |
|---:|---|
| 1478 | Molten Fist hits hero 102 for 45 |
| 1484 | Basic attack hits hero 102 for 61 |
| 1485 | `walkTo(58.25,56.25)` (recorded tile 58,56 with offsets 0.25,0.25) |
| 1486 | `attackTarget(102)` |
| 1494 | Basic attack hits the same hero for its remaining 38 HP |
| 1496 | Same short walk command |
| 1497 | Attacks hero 103, levels secondary ability, casts it |

The two same-target basic hits are 10 ticks apart. Berserker's native attack period is 20 ticks and windup is 9 ticks (`heroAttackTicks` / `heroHitTicks` in `sim.nim`). The hero is still level 1 for these hits. The intervening walk and immediate reattack provide concrete evidence of recovery cancellation. The complete replay contains **52 such same-target pairs for Andre, from 172 total basic hits**. `attack_recovery_audit.nim` checks the entire hosted log for same-target hit pairs faster than the class's native period with an intervening walk and reattack; detailed cases are in `gota-round772-attack-recovery.json` beside this report.

This is a well-isolated candidate strategy: after a confirmed landed basic hit, issue a short walk once, then reissue the attack on the next decision. It should be tested separately from navigation, drafting, purchases, or spell changes. A replay of the candidate's hosted XP must show faster landed hits before any score delta is trusted.

## Andre: purchases, spells, navigation and XP sources

Seat 8 / hero ID 108 / blue team / Berserker.

- Opening: primary ability at tick 566; Crimson Dagger plus Health Potion; attack-move toward `(105,10)`.
- Accepted equipment progression: Knight Armor at 2125, Battle Axe at 4040, Rune Crossbow at 8538. He repeatedly replenishes health potions and portal scrolls.
- Explicit ability progression by slot: `1,2,1,2,1,3,1,2,2,0,0`. Primary and secondary reach rank 4 before investing in the passive. This is class-specific evidence, not proof that this order is optimal for every class.
- Released spells: Molten Fist 56, Winged Boot 45, Volcanic Eruption 20, Rage Crucible 10. There were 147 targeted cast submissions and 16 rejected for range.
- Command totals: 101 attack-moves, 345 direct attacks, 293 walks. Direct attacks are interleaved with short corrective walks, as the isolated trace above demonstrates.
- Portals: 11 started and all 11 completed. Seven completed at the home position `(-3237730,3180118)`; four land elsewhere. First portal completes at tick 4118. Thus both return-to-home and forward travel are present.
- Successful basic-attack damage 15,748; ability damage 10,129. Target-kind damage: heroes 8,144; lane creeps 8,072; neutrals 6,939; towers 2,722.
- Last hits: 8 heroes, 145 lane creeps, 21 neutral units. Camp engagement events: 14.
- Earned XP event sources: hero kills 1,200; lane-creep last-hit shares 2,014 and proximity shares 469; neutral last-hit shares 985 and proximity shares 131. Sum 4,799 matches final `totalXp`. No god/structure XP in this episode.
- Health restoration: item effects 1,340; regeneration 3,131; ability effects 206. Eighteen health recovery starts; ten finish and one is explicitly interrupted by damage. Death/respawn can also end a recovery without that particular interruption event.

Navigation samples (world units; 60,000 units per tile): tick 1440 `(−36216,135930)` HP 300/300, tick 4320 `(−2924312,−1682275)` HP 468/585, tick 10080 `(2128142,−2282193)` HP 455/695, tick 14400 `(−2969566,1308002)` HP 56/805 with goal `(4,111)` toward home. These show central combat, lateral travel, and low-health return behavior. Exact route-selection rules cannot be recovered from a few snapshots.

## Ari: purchases, spells, navigation and XP sources

Seat 1 / hero ID 101 / red team / Lich.

- Opening at tick 569: primary ability, two Health Potions, two Poison Potions. No opening equipment purchase.
- Walks the northern perimeter early: tile `(51,14)` at 1001, `(40,14)` at 1121, `(30,13)` at 1235, `(20,13)` at 1343; first shown direct hero attack is on ID 109 at 1604, followed by Ice Spear at 1613.
- Command totals: **1,288 walks, zero attack-moves**, 229 direct attacks. This confirms deliberate navigation and targeting; it does not by itself prove optimal kiting.
- Accepted later equipment: Battle Axe and Knight Armor at 10766; Rune Crossbow at 16070. Frequent poison and health replenishment uses the remaining slots.
- Ability slots learned: `1,2,1,2,1,3,1,2,2,0,0,3,0`.
- Released spells: Ice Spear 64, Bone Marionette 7, Bound Void 12, Frost Sigil 19. Targeted cast submissions 118; range rejections 13, unavailable-target rejections 3.
- Four portals started, all complete. Three land at home `(3216018,−3273630)`, one at `(2984688,−1570956)`.
- Damage: basic attacks 7,744; abilities 7,999; items 444. Targets: heroes 2,807; lane creeps 7,460; neutrals 5,920. No structure damage.
- Last hits: 14 heroes, 166 lane creeps, 15 neutrals. Camp engagement events: 7.
- Earned XP sources: hero kills 2,100; lane-creep last-hit shares 2,211 and proximity shares 1,112; neutral last-hit shares 900. Sum 6,323 matches final `totalXp`. Some creep kills grant no XP when outside the proximity requirement, explaining why eligible last-hit XP events (156) are fewer than creep last hits (166).
- Item healing 1,502; regeneration healing 113. Sixteen health recovery starts, ten complete, one explicitly interrupted by damage.

Navigation samples: tick 1440 `(−1201072,−2658489)` HP 185/185; tick 4320 `(2830768,2332106)` HP 137/221; tick 11520 `(2820250,2451130)` HP 305/413; tick 21600 `(387007,−482187)` HP 53/485. He repeatedly moves between lane/camp regions and home. Snapshot evidence alone cannot distinguish all avoidance or target-selection rules.

## Reusable tools and data

Tools in the branch, ready for parent review/commit:

- `gota-campaign/examples/gods_of_the_arena/tools/replay_audit.nim`
- `gota-campaign/examples/gods_of_the_arena/tools/replay_strategy_report.nim`
- `gota-campaign/examples/gods_of_the_arena/tools/attack_recovery_audit.nim`

The auditor downloads/decompresses hosted replays, validates their version, reconstructs only the recorded actions, requires every tick hash to match, and emits raw actions/events plus per-seat summaries. The summary's `events` dictionary counts events where a hero is **actor**; `receivedXpSources` counts XP where that hero is **recipient**. Do not interpret actor-side XP event counts as earned XP.

Raw files are in `gota-campaign/tmp/replay_tools/round772.{replay,actions.jsonl,events.jsonl,summary.json}`. The 78 MB event log stays out of version control. To reproduce, compile the auditor with `POLYWORLD_DEPS` pointing at the dedicated pinned dependency folder and `-d:headless -d:replayEvents -d:ssl`, then pass the hosted URL and an output prefix. The report tool takes the resulting summary path and optional seat; the recovery checker takes the prefix and an output JSON path.
