# T001 hosted replay mechanism evidence

The recovery-reset change fired in the first hosted episode. **41 strict fresh-hit → walk → same-target reattack sequences** were found; **29 led to the next same-target hit exactly 13 ticks later**, compared with Vanguard Knight's native 27-tick attack period. This establishes activation and accelerated basic attacks in this replay. It does not establish an XP benefit, statistical significance, or grounds to keep the candidate.

## Identity and replay integrity

| Field | Verified value |
|---|---|
| Hosted XP request | `xreq_e22ca8a2-a917-4b2f-a4da-7b63f37c634f` |
| Job index | `0` |
| Episode request | `ereq_a24cc7ff-0a9d-4624-ad5d-0aa0f8ae861e` |
| Episode ID | `46536f2b-b21c-436c-878a-d0386e34d80d` |
| Candidate | `rowdaboat-gods-of-the-arena:v2` |
| Candidate policy-version ID | `40fa69ae-fa23-48fe-9d13-b34099c404be` |
| Source commit from campaign upload provenance | `7dce75b` |
| Player / seat / hero | RowDaBoat / zero-based seat 0 / hero ID 100, Vanguard Knight |
| Co-world release | `2026.9.24.2` |
| Replay gameplay version | `64` |
| Replayed hashes | **28,909 / 28,909, zero mismatches** |
| Recorded actions | All consumed |
| Decompressed replay SHA-1 | `1AF074498AAA2D3E8938EDFEC7CB43F02158B9E4` |

Hosted source: https://softmax-public.s3.amazonaws.com/replays/7909e132-9fe5-4b19-9f72-9de6a55c858c.replay

The metadata identifies the candidate exactly once and its seat agrees with the ordered `policy_version_ids` array. The other seats contain only Andre von Auto / `khors:v208`, Ari Sklar / `arisk-gods-of-the-arena:v4`, and richard / `richard-gods-of-the-arena:v245`. This checks this replay's provenance; the parent audit handles all ten episodes and the current-top-three selection.

## Strict activation check

The new Nim extractor requires:

1. A positive BasicAttack damage event by the candidate's exact hero ID at tick H, with the target still alive afterward.
2. Exactly one candidate command at H+1: a walk, with no corresponding action-rejection event.
3. Exactly one candidate command at H+2: an attack on the same target ID, with no corresponding action-rejection event.
4. For accelerated-hit evidence, the next candidate basic hit must be on that same target and occur sooner than the class's native period. The exact expected reset interval is `floor(nativePeriod × 45 / 100) + 1`.

Matching both seat and hero ID avoids attributing default/system event records to seat zero. The single-command decisions and exact consecutive ticks distinguish the hook from incidental walking during an ordinary decision.

The replay contains 109 positive basic-hit events by our hero. Forty-one satisfy the strict command sequence. Twenty-nine also have the next same-target hit at the exact predicted interval of 13 ticks. The remaining sequences do not establish an accelerated next same-target hit and are not counted as such. No second episode was needed.

Example from the sanitized receipt:

| Tick | Evidence |
|---:|---|
| 1261 | Hero 100 lands 30 basic damage on creep 1091; creep has 30 HP afterward |
| 1262 | Sole command is accepted `walkTo(9,27)` |
| 1263 | Sole command is accepted `attackTarget(1091)` |
| 1274 | Hero 100 lands the next basic hit on creep 1091; 13-tick interval |

The next two qualifying examples repeat the same cadence: hits 1288 and 1301 on target 1084, and hits 1421 and 1434 on target 1085.

## Artifacts and scope

- Sanitized, trackable receipt: `gota-campaign/experiments/rowdaboat/evidence/t001-mechanism.json`. Contains provenance, roster, timings, action acceptance checks and compact hit records; excludes requester details and scores.
- New reusable Nim extractor: `gota-campaign/experiments/rowdaboat/tools/audit_recovery_sequence.nim`.
- Raw replay artifacts remain outside tracked evidence: `research/t001-replay-00.{replay,actions.jsonl,events.jsonl,summary.json}`.

The exact-version replay auditor ran only the recorded hosted actions and required every authoritative hash to match. No new local game was generated and no local score was computed. The campaign's keep/revert decision remains separate from this mechanism proof; this report makes no significance claim and does not override the parent's revert verdict.
