# T002: hosted camp-route activation

**Job 0 confirms the candidate took a two-camp opening and departed into its original lane.** This establishes observed behavior only; it is not a score or significance result. No extra replay was needed.

Hosted XP request `xreq_d729af06-d2cd-4e22-922e-917ff89ad9a0`, job 0, episode `4ca514b5-7a7b-46b0-bcf7-0707cb9c8f08`: [recorded replay](https://softmax-public.s3.amazonaws.com/replays/f7178598-a0b4-4f14-ac2d-3e5360414580.replay). Candidate `rowdaboat-gods-of-the-arena:v3`, policy version `9945aaa3-f99a-47c1-b947-b3533bfa71ab`, commit `8c4a3e6`, is **seat 0 / hero 100 / Red VanguardKnight**. Identity came from explicit `participants.position`, verified against the replay's player name. Array order was not used as seat order.

Exact-version Nim replay audit verified **28,909 recorded hashes, zero mismatches, and all recorded actions consumed**, on co-world `2026.9.24.2` / game version 64. No new game was generated.

| Tick | Observed action or event |
|---:|---|
| 110 | `attackMove(76,22)` toward tier-1 camp 11. The same waypoint is reissued through tick 398. |
| 410, 468 | Explicit `attackTarget(1079)`, followed by camp-11 engagement. |
| 476, 486 | Our ability deals 40 damage and our basic attack deals 25 to neutral 1079. |
| 480–481 | Between those hits, camp 11 briefly returns and the neutral resets to full health. |
| 504 → 506 | Allied tower 17 kills neutral 1079; two ticks later our route changes to `attackMove(64,33)`, tier-1 camp 13. |
| 683, 692, 700 | Camp-13 engagement, then our ability deals 40 and basic attack deals 25 to neutral 1081. |
| 714 → 716 | Allied hero 103 kills neutral 1081; two ticks later our command changes to `attackMove(11,11)`, the existing VanguardKnight lane goal. |

Neither opening kill was our last hit. Both camps have direct evidence of our damage and prompt departure after the neutral's death. The opening route actions had no recorded rejections. Later in the same replay, our hero directly last-hits neutrals 1077 and 1076 at ticks 4362 and 4470; those are separate from the assisted opening clears.

The short camp reset does **not** demonstrate the dedicated returning-only defer branch: returning lasted one tick before normal combat resumed. This replay demonstrates departure from cleared camps, not every timeout/visibility/returning safeguard. Those remain covered by the isolation fixtures. After departure to the lane, the existing attack-move path encounters tier-2 camp 0 at tick 832 and tier-3 camp 4 at tick 1204; these are incidental combat encounters, not evidence that the new tier-1 objective selector chose those camps.

The compact sanitized receipt is `research/t002-mechanism.json`; the reusable profile is `research/t002-replay-00.profile.json`; verified raw artifacts use prefix `research/t002-replay-00`. `select_xp_episode.nim` produces score-free direct episode metadata for the existing `leader_replay_profile` tool. No policy was edited during this audit, and no score, mean, significance, or keep verdict was calculated from replay data.
