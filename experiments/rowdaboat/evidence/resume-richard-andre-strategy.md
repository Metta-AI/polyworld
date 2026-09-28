# Richard v340 and Andre v219: recorded farming and equipment

2026-09-28. **Mechanism evidence only.** This audit reconstructs a hosted league recording; it does not generate games, calculate scores, compare means, establish significance, or justify a keep.

## Identity and integrity

Hosted round 906, episode `fc903005-4ffb-4330-b740-eb68e9c80479`, co-world `2026.9.24.2`. [Replay source](https://softmax-public.s3.amazonaws.com/replays/b5a48b0e-de8e-4f12-a6a3-66a0695fd954.replay). The pinned Nim auditor reproduced **29,365 / 29,365 gameplay-v64 hashes, zero mismatches**, consuming all recorded actions.

The two latest-replay metadata files identify the same episode. Identity is resolved from **`participants.position`**, never the order of `policy_version_ids`:

| Player | Policy version | Seat / team / class |
| --- | --- | --- |
| richard | v340 / `8bf344e5-c1b5-4b9b-94c5-b9f7437998b3` | 1 / Red / DemonHunter |
| Andre von Auto | khors v219 / `594e4f86-57a5-4217-bccd-960e495791ce` | 6 / Blue / Arcanist |

Replay player names independently agree. These are updated policies and different classes from the older reports; old behaviors should not automatically be attributed to them.

## Main finding: deliberate camp-to-lane farming, with repeated camp visits

Richard records 44 neutral last hits and 235 lane-creep last hits; Andre records 45 neutral and 208 lane-creep last hits. Both also fight heroes and towers. Our three previously inspected baseline recordings have only 3–5 neutral last hits. These are descriptive action/event counts from unlike recordings and classes, not a controlled performance comparison.

Their neutral targets are deliberate `attackTarget` commands, not merely incidental proximity rewards. Richard's opening chain is particularly clear:

| Tick | Recorded command or reproduced event |
| ---: | --- |
| 567 | Attack neutral 1079, tier 1, camp 11 |
| 838 | Richard kills 1079 |
| 839 | Attack neutral 1081, tier 1, camp 13 |
| 979 | Richard kills 1081 |
| 1005 | Attack neutral 1049, tier 2, camp 0 |
| 1099 | Richard kills 1049 |
| 1100 | Attack adjacent tier-2 neutral 1048 |
| 1169 | Richard kills 1048 |

He briefly selected a more distant tier-3 target at 980 before switching to the nearer tier-2 camp at 1005. Thus this is evidence for reselection among camps, not a rigid uninterrupted list. After 1170 he attacks tier-3 camp 4, kills two of its members, and dies at 1536. **That higher-tier opening is not established as safe or desirable to copy.**

A later exact **camp-clear to lane** transition avoids the death/respawn ambiguity:

| Tick | Recorded command or reproduced event |
| ---: | --- |
| 3442 | Richard attacks tier-2 neutral 1279, camp 0 |
| 3492 | Switches to adjacent tier-2 neutral 1278 |
| 3536 | Kills 1278 |
| 3537 | Attacks 1279 again |
| 3557 | Kills 1279 |
| 3558 | Next target is lane creep 1324; further lane targets follow |
| 3784 | Kills lane creep 1315 near map center, hero at `(30,896, -33,313)` world x/z |

His hero was at `(-264,898, -2,084,542)` when the two camp mobs died. The following lane kill near the origin confirms actual travel toward the central lane rather than only issuing an unavailable target command. Richard revisits the same low-camp pair: attack camp 11 at 2336 then camp 13 at 2538; again at 3978 then 4220. Full engagement events show later repeated 11→13→0 circuits, including 19,915 / 20,013 / 20,197. A `CampEngaged` event can repeat for the same camp, so those counts are not interpreted as completed clears.

Andre supplies evidence for the mirrored opening and ongoing mixing of camps with lanes. He attacks tier-1 camp 10 at 656, tier-1 camp 12 at 944, then lane creep 1044 at 1154. Other players take some opening camp kills, so these commands do not prove Andre personally cleared both. On his next trip, he targets camp 10's new mob 1227 at 2385, kills it at 2609, targets camp 12's new mob 1277 at 2613, and turns to hero 102 at 2823 and lane creep 1225 at 3004. Later, lane targets at 4054–4066 are followed by camp 10 at 4084, lane targets from 4168, camp 12 at 4432, and lane targets again at 4522. This is repeated opportunistic camp/lane switching, not a camp-only policy.

### Orientation and safe implementation boundary

The low camps used in these openings are mirrored home-side pairs. Exact initial neutral spawn positions below come from hosted `EntitySpawned` events; they are **member positions, not claimed camp-center measurements**. One tile is 60,000 world units.

| Camp | Tier | Initial member x/z | Observed opener |
| ---: | ---: | --- | --- |
| 11 | 1 | `(1,110,000, -2,130,000)` | Richard, Red; travels inward from positive-x/negative-z keep |
| 13 | 1 | `(390,000, -1,470,000)` | Richard, Red; continues toward the central lane |
| 10 | 1 | `(-1,110,000, 2,130,000)` | Andre, Blue; mirrored first camp |
| 12 | 1 | `(-390,000, 1,470,000)` | Andre, Blue; mirrored second camp |
| 0 | 2 | `(-330,000, -2,010,000)` and `(-270,000, -2,010,000)` | Richard's additional medium-camp branch |

The public host API exposes `campCount`, `campX`, `campY`, and `campTier` in team-relative coordinates. It does **not** expose hidden living counts or respawn timers. Visible mobs expose `objectCamp`, `objectLeader`, and `objectReturning`; returning mobs must not be chased for damage. A fully cleared camp respawns after 60 seconds only while all living heroes remain outside ten tiles. Standing beside a cleared camp waiting for it is therefore inappropriate.

**Substantive single-strategy replication hypothesis:** replace the baseline's fixed idle marching waypoint with a camp-to-lane farming objective. On spawn or a completed clear, use the public coordinates to approach the nearest suitable home-side tier-1 camp, attack eligible visible members, then reselect the next nearby suitable camp or the central lane. Leave a confirmed empty/cleared camp and remember that observation for a bounded revisit delay; do not assume hidden state. Preserve the existing combat execution, casts, shopping, draft, and safety thresholds for the first experiment. This changes where the bot seeks its next fight, not its attack mechanics. Use observed coordinates and team orientation rather than hardcoding camp IDs from this recording. In particular, do not bundle Richard's early tier-2/tier-3 aggression into the same trial.

Mechanism evidence for that future candidate should show the intended home-side camp visit, real neutral attacks/kills, a prompt move into a lane or another camp after clearing, and later revisits without waiting inside the respawn exclusion radius. These leader traces motivate the experiment; only hosted XP against the freshly resolved top three and the required significance evidence can retain it.

## Separate equipment hypothesis

Andre buys Crimson Dagger plus one Health Potion at 566. On the first respawn shop at 2247, he arrives with 350 gold and buys **Knight Armor (160), then Battle Axe (180)**, leaving 10. At 5707 he buys a Portal Scroll, Rune Crossbow, then Health Potions. His Arcanist therefore obtains +damage equipment rather than restricting the build to mana items. His overall 13 scroll purchases and repeated healing show that permanent equipment and consumables can coexist; copying a blanket consumable ban would not reproduce Andre.

Richard opens with Leather Gauntlets (70) and Steel Helmet (80), then acquires Dagger and Longsword at 6086, Axe at 11312, Armor at 15363. He purchases seven Poison Potions, no health/mana potions, no boots, and no scrolls. He also buys back seven times and eventually fills all six slots with equipment. His later 113 inventory-full purchase rejections are not a behavior worth reproducing.

The previously identified isolated **purchase-order** hypothesis remains supported: buy the baseline's existing role equipment before replenishing consumables. Keep it separate from the farming route strategy above. Andre's exact 350→190→10 gold sequence is strong evidence of intentional permanent-item acquisition. It does not prove the priority alone caused his results or that his entire build is optimal for our VanguardKnight.

## Artifacts

- `research/resume-richard-andre-round906.{replay,actions.jsonl,events.jsonl,summary.json}`: verified hosted replay and raw evidence.
- `research/resume-richard-andre-strategy.json`: descriptive receipt, including metadata-position identity, purchases with before/after gold, camp engagements, target changes, kill positions, and navigation snapshots. No score fields are included.
- `tools/audit_leader_strategy.nim`: new extractor; requires the complete zero-mismatch v64 summary and matching hosted replay URL. It matches both player seat and hero ID before attributing events. Neutral tier information comes from event entity class; other entities' initial classes are not used to infer drafted classes.

No policy or backlog edits, new XP requests, commits, or keep decisions were made in this audit.
