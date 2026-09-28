# T003: hosted equipment-priority activation

**Job 0 confirms an accepted KnightArmor purchase before consumable replenishment in the same shop decision.** This is behavior evidence only, not a score or significance result. No extra replay was needed.

Hosted XP `xreq_8ce60a8e-b40a-4c2c-8930-54eb8b9e9f91`, job 0, episode `47b07ba5-2a72-4c6e-8497-4e80519ca05b`: [recorded replay](https://softmax-public.s3.amazonaws.com/replays/d7d7dd39-ae94-4205-a6d7-2305c2e57713.replay). Candidate `rowdaboat-gods-of-the-arena:v4`, policy version `a6e2c7f1-7039-4ca0-855b-0540c09755d1`, commit `f21ddd45f53bc4c9e200ec4530a2a3555d67ec0c`, is **seat 0 / hero 100 / Red VanguardKnight**. Explicit `participants.position` was checked against the replay player name; metadata array order was not used as seat order.

Exact-version Nim replay audit verified **28,909 recorded hashes, zero mismatches, and all recorded actions consumed**, on co-world `2026.9.24.2` / game version 64. Only recorded hosted actions were replayed.

At tick **4448**, both the command log and accepted simulation events establish this order:

1. `buyItem(16)` → **KnightArmor purchased**, inventory count 0 → 1.
2. Gold spent: **205 → 45**, paying 160 for the armor.
3. Equipment health adjustment: **321 → 441** (+120).
4. `buyItem(1)` → **HealthPotion purchased**, inventory count 0 → 1.
5. Gold spent: **45 → 15**, paying 30 for the potion.

No action was rejected at that tick. The unchanged opening still purchased RangerBoots then HealthPotion at tick 110 and issued the original lane `attackMove(11,11)`. Earlier potion purchases do not contradict priority: the change prioritizes affordable role equipment during a shop decision; it does not prohibit consumables until equipment is affordable.

This one replay proves the VanguardKnight branch fired. It does not establish hosted activation for the other role branches or any performance improvement. The compact sanitized receipt is `research/t003-mechanism.json`; full descriptive profile is `research/t003-replay-00.profile.json`; verified raw artifacts use prefix `research/t003-replay-00`. No policy was changed during the audit, and no score, mean, significance, or keep verdict was calculated from replay data.
