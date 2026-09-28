# relh v380: hosted round 906 behavior audit

The clearest navigation hypothesis is **camp-first departure, then repeated neutral-camp visits between lane fights**. This is a behavior hypothesis for a future single-change experiment, not a recovered copy of relh's hidden policy or evidence of a score improvement.

## Provenance

- Hosted episode `58b2cfb6-2655-47a1-b318-0bc660a4b925`, league round 906, [recorded replay](https://softmax-public.s3.amazonaws.com/replays/b9e8a144-a4c4-45f1-9565-aff9db52fe2f.replay).
- Co-world `2026.9.24.2`, replay game version 64. Exact-version Nim `replay_audit` reproduced **29,137 recorded hashes with zero mismatches**. It asserts that all recorded actions were consumed before writing its summary. Only recorded hosted actions were replayed; no new games were generated.
- Metadata `participants.position`, checked against replay player names: **seat 7 / hero 107 = relh, `relh-gods-of-the-arena:v380`, policy version `272e3b71-e3f6-4b9d-b4d9-b990d179a19c`**; **seat 4 / hero 104 = RowDaBoat v1**, version `ab664012-84b3-48b3-ae1b-86f3f6cf960c`. The metadata's `policy_version_ids` array order was not used as seat order.
- relh drafted Blue Arcanist; RowDaBoat drafted Red DruidWarden. Different classes, teams, nearby allies, and fights prevent a causal comparison.

## Direct navigation and target evidence

Camp indices below are zero-based simulator indices, matching the BASIC camp API; they identify this map, not a universal route.

| Tick | Recorded action or event |
|---:|---|
| 338–339 | One `walkTo(64,64)`, then explicit `attackTarget(1078)` on a tier-1 neutral. |
| 706 | First relh damage: basic hit on neutral 1078 in camp 10, at world coordinates (-1,110,000, 2,130,000). |
| 718–719 | Allied tower kills 1078 after relh and allied hero 105 damage it. relh switches to neutral 1080 the next tick. This first camp was assisted, not a solo clear. |
| 934–937 | Allied hero 105 engages camp 12. relh hits and last-hits its neutral 1080 at tick 936, then selects a lane creep at 937. This confirms an opening **camp 10 → camp 12 → lane** sequence. |
| 1204–1242 | First hero target selected at 1204; first hero damage at 1242 near the map center. |
| 1992 → 2424 → 2649 | After respawn, relh engages camp 10 and then camp 12 again. |
| 3511 → 3956; 5938 → 6289 | After two more early respawns, relh returns to camp 10. |
| 6289 → 6583 → 6907 → 7741 | Later chain: camp 10 (tier 1), camp 1 (tier 2), camp 5 (tier 3), camp 7 (tier 3). |
| 10810 → 11043; 14335 → 14618; 17625 → 18201; 26159 → 26459 | Repeated camp 10 → camp 8 sequences. |

There are 22 camp-engagement events attributed to relh: camp 10 eight times, camp 8 five times, camp 6 three times, and six other camps once each. These events count who started a resting camp's engagement; they do **not** count every camp relh damaged. The opening camp-12 clear illustrates that distinction.

relh issues 26,463 explicit attack-target commands, including 8,374 toward neutral IDs, 11,474 toward lane creeps, 4,761 toward heroes, and 1,854 toward towers. There are no attack-move or portal commands. Target changes include frequent lane/hero/neutral switching, so this is not uninterrupted jungle farming. Commands include retries and rejected attempts; they are not damage events. Of 504 walk commands, 388 immediately follow an own basic-hit tick, so treating every walk as a route waypoint would be misleading.

Recorded last hits are 43 neutrals, 207 lane creeps, 17 heroes, and 2 towers. Our v1 in the same replay records 5 neutral and 92 lane-creep last hits, 5 camp engagements, and begins with repeated lane attack-move commands. Its first damage arrives on a lane creep at tick 1178. These are mechanism observations only, not scores or an experiment comparison.

## Equipment and combat context

relh buys HealthPotion and PoisonPotion at opening, AmethystWand at 1994, SapphireRing and ThornwoodStaff at 5940, CrimsonDagger at 5983, and SunsteelLongsword at 13602. The final inventory contains those five durable items. Our v1 remains on RangerBoots plus consumables in this recording. relh also casts FrostLance 31 times, MeteorStrike 31 times, and ArcaneMeteor 15 times. These material differences mean a navigation change alone must be tested on our own submitted class/combat behavior; the replay does not prove that relh's higher-tier camp route is safe for us.

## Bounded hypothesis to test

Replace lane-first navigation with a **low-tier camp objective at departure and after respawn, followed by a nearby available camp before returning to lane**. Use observed living neutral IDs for attacks and the static camp API for travel/revisit objectives; exclude returning neutrals. Preserve existing combat, items, and abilities for the first experiment so navigation remains the only changed strategy. A replay should establish that the chosen camps are reached and neutrals are attacked before interpreting hosted XP results.

This is an inferred experiment design. The replay does not identify relh's distance weights, visibility rules, target-health priorities, revisit timers, threat thresholds, or exact lane-diversion condition. It also does not show that every respawn follows this route. Do not hard-code this seed's camp indices, attempt tier-3 farming merely because relh did it, or count first-camp tower assistance as solo damage capability.

## Artifacts and reproduction

- Raw audited prefix: `research/resume-relh-round906` (`.replay`, `.summary.json`, `.actions.jsonl`, `.events.jsonl`).
- Sanitized descriptive receipts: `research/resume-relh-round906.profile.json`, `research/resume-rowdaboat-round906.profile.json`; no scores or XP totals.
- New Nim postprocessor: `gota-campaign/experiments/rowdaboat/tools/leader_replay_profile.nim`. It validates `participants.position` against the replay and reads recorded actions/events; it does not simulate or score games.

From `gota-campaign`:

```text
tmp/replay_tools/replay_audit https://softmax-public.s3.amazonaws.com/replays/b9e8a144-a4c4-45f1-9565-aff9db52fe2f.replay ../research/resume-relh-round906
tmp/replay_tools/leader_replay_profile ../research/resume-relh-latest-replay.json ../research/resume-relh-round906 7 ../research/resume-relh-round906.profile.json
tmp/replay_tools/leader_replay_profile ../research/resume-relh-latest-replay.json ../research/resume-relh-round906 4 ../research/resume-rowdaboat-round906.profile.json
```

No policy was changed. No score, mean, significance, or keep verdict was calculated from this league replay.
