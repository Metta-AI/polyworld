# Submitted baseline: economy and combat-uptime diagnosis

2026-09-25. This is mechanism research on existing hosted experience recordings, not a new trial, score calculation, significance test, or keep decision. No policy was changed.

## Provenance and reconstruction

Hosted XP request: `xreq_0ad92adc-2c3b-44e3-a1f2-7fcd0fa5805d`, co-world release `2026.9.24.2`. Authoritative metadata is `baseline-xp-status.json`; the policy is RowDaBoat v1, `ab664012-84b3-48b3-ae1b-86f3f6cf960c`. The existing hosted response reports zero for us in all ten episodes. This investigation inspected only the already available job 0 and two additional hosted recordings, jobs 1 and 6.

| Job | Our seat/team/class | Hosted replay job | Exact v64 hashes |
| --- | --- | --- | --- |
| 0 | 0 / Red / VanguardKnight | `88078960-a20c-4eda-b0cf-4a8e4753086f` | 28,909 / 28,909; zero mismatches |
| 1 | 1 / Red / VanguardKnight | `07cda9d9-3720-4a7e-b392-6846a2987d3d` | 28,909 / 28,909; zero mismatches |
| 6 | 6 / Blue / VanguardKnight | `ac9221b5-fd02-4be4-9793-395e7b7778f1` | 28,909 / 28,909; zero mismatches |

Replay URLs are `https://softmax-public.s3.amazonaws.com/replays/<job>.replay`. The auditor consumed every recorded action and did not generate games. Each recording contains our one policy seat, three seats of Andre von Auto's khors v208 (`bf6c6cc2-362e-4eee-a105-810b23adf437`), three of Ari Sklar's arisk v4 (`61f4440b-140d-4f7d-80b8-2802f7a3100d`), and three of richard v245 (`7fd19643-c66a-429e-ba24-3c1e6c0d8e06`). They are the baseline request's pinned top-three roster, not a claim that this roster remains current for future trials.

All three selected recordings happened to draft VanguardKnight, so the conclusions below are directly evidenced for that class on both teams. They do not establish behavior for the seven uninspected seat rotations or other classes.

## Clearest isolated fault: consumable priority prevents equipment purchases

The reference shopping routine buys boots, health potion, portal scroll, and mana potion before its role equipment. For VanguardKnight that equipment is Knight Armor, cost 160 and +120 max HP. Only after those earlier purchases does it try armor, then a Vitality Elixir. Each visit can also top up another stack unit six ticks later.

| Replay diagnostic | Job 0 | Job 1 | Job 6 |
| --- | ---: | ---: | ---: |
| Gold spent on Health Potions | 540 | 300 | 360 |
| Gold spent on Mana Potions | 270 | 360 | 540 |
| Gold spent on Portal Scrolls | 600 | 400 | 600 |
| Gold spent on Vitality Elixirs | 75 | 150 | 75 |
| Equipment acquired | Boots only | Boots only | Boots; Armor at tick 11,004 |
| Gold spent on equipment | 100 | 100 | 260 |

Job 6 also spends 100 on a buyback. These amounts are sums of hosted replay `GoldSpent` events; no XP score is derived from them.

Direct counterfactual opportunities are visible without guessing whether we could afford armor:

- **Job 0, tick 9,206:** starts shopping with 170 gold. Health Potion reduces it to 140, Portal Scroll to 40. Armor was affordable before replenishment and is not afterward.
- **Job 0, tick 19,736:** starts with 320. Health Potion costs 30, Scroll 100, Mana Potion 45, leaving 145. Armor is then skipped; a 75-gold Vitality Elixir is purchased. A later potion at 19,808 leaves 40. The hero never obtains armor in this recording.
- **Job 1, tick 2,552:** starts with 170, purchases Health Potion then Scroll, and retains 40. The same deprivation occurs from 220 at 16,162 and from 275 at 23,523. It never obtains armor.
- **Job 6:** does eventually acquire armor, but only at tick 11,004. The baseline's intended role-equipment path works when sufficient money survives the earlier purchases; it is not a broken item ID or rejected shopping action.

The top-player reports establish a relevant contrast in behavior, not a controlled performance comparison: Andre acquires Knight Armor at 2,125, Battle Axe at 4,040, and Rune Crossbow at 8,538 in verified round 772. Ari acquires Axe and Armor at 10,766 and Crossbow at 16,070. Richard builds several permanent items as well. Our inspected jobs 0 and 1 never move beyond boots and have no permanent attack-damage bonus.

**Recommended next single-change hypothesis, after the current combat experiment is resolved:** move the existing role-equipment purchase ahead of health/portal/mana replenishment; preserve the exact equipment IDs, prices, opening boots, consumable list and quantities, movement, casting, target selection, and drafting. This isolates purchase priority rather than changing the build and combat strategy together. For VanguardKnight it should purchase the already intended 160-gold armor at the first affordable shop visit. Replay acceptance evidence must show that equipment actually arrives earlier and that the remaining action flow is valid. Only the required new hosted XP experiment and dashboard significance may justify a keep; none of these observations do.

## Large additional problem: long alive gaps without basic hits or XP receipts

The bot runs and issues commands. The hosted logs contain no compile/runtime failure, and the exact recordings contain active navigation, casting, shopping, attacks, healing, and portal completion. Calling the bot globally idle would be inaccurate. The problem is long stretches spent moving or recovering without landing attacks or receiving XP.

The dedicated Nim summarizer finds adjacent positive `XpGained` events for our hero, subtracts exact Death-to-Respawn intervals, counts basic-damage events and released spells strictly between those XP events, and joins the recorded action log. Representative entirely alive intervals:

| Job | Gap ticks | Seconds at 24 ticks/sec | Basic-hit events | Actions during interval |
| --- | --- | ---: | ---: | --- |
| 0 | 20,174–23,025 | 118.8 | 0 | 40 walks, 29 attack-moves, 14 direct attacks, 3 purchases, one portal use; 6 released spells |
| 0 | 13,818–15,987 | 90.4 | 0 | 24 walks, 21 attack-moves, 2 direct attacks, 2 purchases; 2 released spells |
| 0 | 11,482–13,504 | 84.3 | 0 | 23 walks, 18 attack-moves, 5 direct attacks, one purchase; 4 released spells |
| 1 | 1,870–3,380 | 62.9 | 0 | 16 walks, 14 attack-moves, 2 direct attacks, 3 purchases, one portal use; 3 released spells |
| 6 | 11,326–13,060 | 72.3 | 0 | 18 walks, 18 attack-moves, 7 direct attacks, 2 purchases; one released spell |
| 6 | 17,274–18,982 | 71.2 | 0 | 22 walks, 15 attack-moves, 7 direct attacks, 3 purchases, one portal use; 2 released spells |

The timestamps identify opportunities for focused replay inspection; the counts do not prove that every move was unnecessary. In job 0's 13,818–15,987 interval, the first recorded orders are walks toward the home tile `(111,5)`, followed by shopping at 14,685 and later attack-moves toward `(10,105)`. The periodic snapshot at 14,400 already shows full health, 770/770, while the goal remains home. The policy only clears its persistent `retreating` flag inside spawn after both HP and mana reach 90%. HP recovery en route alone does not clear it. Current evidence cannot distinguish an HP-latched return from a still-necessary mana return at every decision; a follow-up state extractor should include max mana, active target, positions, and each decision's retreat condition before changing this logic.

Over the whole recordings, the basic-hit event counts are 111 / 68 / 93, and deaths are 6 / 10 / 7. Exact dead time is 3,096 / 7,301 / 3,817 ticks. These small combat-event counts make improved attack recovery potentially useful but cannot establish it will solve the much larger time spent out of combat. The recovery experiment must remain isolated and be assessed by its own hosted evidence.

## Casting and target decisions

- Job 0 submits 115 targeted/point casts and releases 108 spells; job 1 submits 111 and releases 99; job 6 submits 119 and releases 115. The differences are accounted for by range/channel rejections. This does not resemble Richard's thousands of rejected cast submissions and does not support prioritizing a failed-cast-spam fix.
- Inferno Aegis is frequently a healing spell: 57 / 49 / 52 releases, and ability healing received totals 3,960 / 3,248 / 3,090. These casts are not automatically waste just because no outgoing damage appears. Healing can keep the bot alive while it is traveling home.
- Hosted replay lifetime XP receipts decompose mostly into lane last-hit and proximity events. Neutral kills are only 5 / 3 / 5; hero kills are 2 / 1 / 3. Jobs 1 and 6 each land one structure kill. This identifies actual activity without computing a score or ranking the replays.
- Source inspection shows nearest visible hostile structures may compete with creeps within an 18-tile radius, while neutral camps are considered only when no lane target and no enemy hero pressure exist. The existing events alone do not establish how much time is wasted chasing each category. A next focused extractor should record target changes with hero/target distance, reachability, and damage following each order before testing a target-selection change.
- The game's published rule is lifetime XP less 200 per simulated minute, floored/clamped at zero per hero. That rule explains why a policy may visibly play and still receive the authoritative hosted zeros. No local score is calculated here.

## Reproducible artifacts

- `research/baseline-replay-{00,01,06}.replay`, `.actions.jsonl`, `.events.jsonl`, `.summary.json`: exact hosted artifacts and full audited reconstructions. Large raw logs remain outside version control.
- `research/baseline-replay-{00,01,06}.diagnosis.json`: gold-before/after purchase traces, death/respawn ticks, the six largest alive XP gaps with first/last commands, and descriptive combat-event counters.
- `tools/baseline_diagnosis.nim`: `metadata <xp-status.json>` resolves the three selected jobs; `timeline <prefix> <seat>` requires replay version 64 and a complete zero-mismatch audit, then writes the diagnosis sidecar. `player <summary.json> <seat>` prints full per-seat detail.
- Top-player mechanism references: `research/gota-round772-top-players.md` and `research/gota-richard-replay.md`.
- Submitted source reference: initial commit `ae20666`, byte-for-byte current release `examples/gods_of_the_arena/players/base.bas`; do not confuse the parent's unsubmitted recovery experiment edits with the recorded baseline.

No keep/revert/submission verdict is made by this report. The proposed shopping trial belongs in the backlog until the current one-change experiment is resolved and current top-three opponents are refreshed.
