# Gods of the Arena: backlog and experiment log

## Rules for this campaign

- Score only hosted Softmax experience requests, never local games.
- One policy change per experiment. Run at least 10 episodes; increase the sample until the requested dashboard shows significance, or revert. Inconclusive is never a keep.
- Compare candidate and submitted-policy results against the current top three unique other players, with one live policy per player. Never seat our policies against one another.
- Keep and submit a replacement only after a statistically significant improvement over the submitted policy. If no champion exists, submit a working initial bot.
- CPUX: commit, push, upload, then request hosted experience.
- Use Nim for tools and BASIC for the game policy. Isolation checks and replay extraction establish mechanism, not score.
- Record every trial's idea, exact change, commit, policy version, XP request IDs, opponents, episode count, mechanism evidence, significance evidence, and verdict.

## Discovery — 2026-09-25

- User confirmed league: `gods-of-the-arena`, league ID `league_3c60897b-25cf-4b37-9d1a-8554c1198f28`.
- At initial discovery the account's sole player RowDaBoat, `ply_eeb732fa-5f40-4fa1-beac-6571738f8108`, had nine champion leagues and no GotA policy. The initial GotA champion is now active as recorded below. Player slug still cannot be verified through the unavailable dashboard.
- Live league UI identifies hosted release `2026.9.24.2`.
- Initial live top three: Andre von Auto (`khors:v208`), Ari Sklar (`arisk-gods-of-the-arena:v4`), richard (`richard-gods-of-the-arena:v245`). Refresh before each XP request; exclude our player once confirmed.
- Requested dashboard fails with `ERR_NAME_NOT_RESOLVED`. macOS has no Tailscale DNS resolver and no Tailscale app at standard paths. Softmax itself is reachable. Dashboard significance is not currently observable.
- The nested engine checkout is clean but old (`7f50a61`). Fetched origin: current `origin/main` is `23f3384`, including tower and chat updates. Adjacent `board+cards game/polyworld` contains later tooling but is also behind the current remote; do not use an old engine to validate new replays.
- Created an isolated up-to-date worktree `gota-campaign` on branch `codex/rowdaboat-gota-20260925`. Initial policy is an exact copy of current `players/base.bas`; committed as `ae20666` and pushed to origin. Upload and champion receipts are recorded below.
- Hosted release is corroborated by the live website and release receipt: source `f4456be`, Coworld `cow_e282a46f-31c4-43b1-a9e2-aaa31d3aaed4`, replay version 64. Detailed findings: `research/gota_rules_audit.md`.
- Baseline uploaded as `rowdaboat-gods-of-the-arena:v1`, policy version `ab664012-84b3-48b3-ae1b-86f3f6cf960c`. SHA-256 matches the hosted bundled base: `5dbbd273ca48953649e8fc772644fd81242ecb3454e482154665ece13adec904`. Server returned an existing-content conflict on staging, explicitly directing completion; completion succeeded without another content upload.
- Baseline hosted XP completed: `xreq_0ad92adc-2c3b-44e3-a1f2-7fcd0fa5805d`, 10/10 episodes, zero failed episodes, canonical release `2026.9.24.2`. No improvement claim.
- Initial champion established: submission `sub_f669fd4c-99fe-4034-94cd-5729bdf95bce`, active competing membership `lpm_6841a493-bd35-460b-ac0f-2de1fbadb7cb`, explicit champion endpoint returned `is_champion: true`. Submission used `auto_champion: never` so later uploads cannot bypass the significance gate. This uses the user's no-existing-policy exception, not an improvement claim.

## Backlog

1. Confirm our player slug and current champion, and preserve its exact source/version.
2. Restore access to the requested league and XP significance dashboards.
3. Pin the hosted Coworld version, exact source revision, and current example policy. Audit draft, ability ranks, decimal/bitwise semantics, lane/neutral rewards, tower range and projectiles, and chat routing.
4. Build or reuse exact-version Nim replay extractors; inspect top-player navigation, target selection, farming, casting, shop, and group movement. Prioritize this if our performance is far below theirs.
5. Establish a hosted baseline against the current top three other players, minimum 10 episodes, preserving full results and roster.
6. Choose one replay-supported strategy change, isolate its activation, CPUX, and evaluate dashboard significance. Revert unless kept by that evidence.
7. Combat hypothesis from verified leader replays: after a landed basic hit, brief walk followed by reattack may reset recovery. Andre v208 has 52 verified rapid same-target hit pairs (including 10 ticks versus Berserker's native 20); Richard v245 has 173 (including 13 ticks versus Warlock's native 28). Ari v4 shows none in those recordings. Tested alone in T001 and reverted; no significant improvement established.
8. Purchase-priority hypothesis: buy the existing role equipment before replenishing consumables, preserving the build and quantities. Three verified B000 replays show expensive recurring consumables; two never buy armor despite starting visits with enough gold. Detailed evidence: `research/baseline-diagnosis.md`. Do not combine with T001.
9. Navigation research: extract exact retreat conditions, mana, targets and distances during the verified 50–119 second alive gaps without basic hits or XP receipts. Current evidence does not justify a navigation change yet.

## Trials

Initial baseline B000: use current playable reference policy unchanged because no champion exists. Commit/push complete (`ae20666`), upload complete, XP requested. This establishes the initial champion; it is not a claimed improvement.

| Trial | Idea | Exact change / commit | Uploaded policy | XP ID(s) | Top-three opponents | Episodes | Mechanism proof | Dashboard significance | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| B000 | Establish working initial baseline | Exact hosted reference, no strategy edit; `ae20666` | `rowdaboat-gods-of-the-arena:v1` / `ab664012-84b3-48b3-ae1b-86f3f6cf960c` | `xreq_0ad92adc-2c3b-44e3-a1f2-7fcd0fa5805d` | Andre von Auto `khors:v208` (`bf6c6cc2-362e-4eee-a105-810b23adf437`); Ari Sklar `arisk-gods-of-the-arena:v4` (`61f4440b-140d-4f7d-80b8-2802f7a3100d`); richard `richard-gods-of-the-arena:v245` (`7fd19643-c66a-429e-ba24-3c1e6c0d8e06`) | 10 completed, 0 failed | Exact bundled hash; all 10 logs clean; first hosted replay matches all 28,909 hashes and confirms upgrades, attacks, casts, shop, portals | Dashboard inaccessible; no comparative claim | Initial champion active; baseline complete, no improvement verdict |
| T001 | Replicate leaders' post-hit recovery reset | Only fresh-hit walk/reattack timing; `7dce75b` | `rowdaboat-gods-of-the-arena:v2` / `40fa69ae-fa23-48fe-9d13-b34099c404be` | `xreq_e22ca8a2-a917-4b2f-a4da-7b63f37c634f` | Andre von Auto `khors:v208`; Ari Sklar `arisk-gods-of-the-arena:v4`; richard `richard-gods-of-the-arena:v245`; exact UUIDs same as B000, freshly reverified | 10 completed, 0 failed | 44 isolation checks; all 10 logs clean; 28,909 replay hashes match; 41 strict reset sequences, 29 accelerated hit pairs | Dashboard inaccessible; no significant improvement established | REVERTED; all 10 authoritative own scores zero; no league submission |

### B000 roster and evidence

Fresh standings and live champion memberships were resolved immediately before the request, deduplicated by player and excluding RowDaBoat. All ten seats rotate: one RowDaBoat hero, three seats for each of the three opponent policies. Each other player uses exactly one live policy version. No other RowDaBoat version participates. The same format must be used for any future candidate and comparable baseline batches.

Payload, roster, response and request journal are under `research/baseline-xp-*`. Initial upload receipts are under `research/baseline-upload/`. League lock API is commissioner-only (403), but the XP response itself resolves to the verified canonical Coworld. A read-only attempt to the dashboard's documented SSH host also timed out; no network configuration was changed.

Completed baseline audit (`research/baseline-report.md`): all 10 requests used exactly the frozen roster and expected Coworld; our single hero rotated through seats 0–9 once each. All ten hosted scores are zero, no score is missing, and all ten private logs contain normal start/completion with no compiler or runtime diagnostics. This is an initial baseline, not a candidate-vs-submitted significance comparison. Our baseline is far below the leaders, so prioritize reconstructing their observed tactics over small parameter adjustments.

First baseline replay mechanism check: all 28,909 hashes match. Our Vanguard used 8 ability upgrades, 165 direct attacks, 298 attack-moves, 115 casts, 32 purchases, and 6 portals. It ended at level 8 with six deaths and only Ranger Boots as permanent equipment. This confirms actual gameplay rather than a disabled VM. Leader combat timing and equipment priorities are separate hypotheses and must never be bundled into one experiment.

Verified leader reports: `research/gota-round772-top-players.md` (Andre v208/Ari v4, 29,365 hashes), `research/gota-richard-replay.md` (Richard v245/Ari v4, 29,365 hashes), each with zero mismatches. Nim action/event and attack-recovery extractors are in `gota-campaign/examples/gods_of_the_arena/tools/`. Raw replays/events stay out of Git. No local game scores were used.

### Current gate

Initial champion and baseline are established. No experimental policy change has been kept or submitted. Further keep decisions require the requested dashboard, whose hostname remains unreachable; the user has been asked to connect this machine to that network or provide a reachable address. Do not substitute an eyeballed score mean for that gate.

## T001 — post-hit attack recovery reset (reverted)

- Idea: replicate the immediate walk/reattack sequence proven in Andre v208 and Richard v245 replays, using `selfAttacksLanded` to avoid canceling a hit before it lands.
- Single change: combat recovery timing only. Preserve drafting, target selection, ability decisions, shopping and ordinary navigation. A brief move to the current observed tile center after a confirmed hit is followed by a validated attack on the next decision. No spell or item tuning.
- Evidence required before trust: Nim isolation test shows the hook fires after a successful hit, avoids windup/no-hit and unsafe states, and accepts reattack; hosted replay must show the new sequence and faster landed-hit pairs.
- Isolation evidence: all 44 constructed VM/host checks pass, including actual impact → walk → same-target reattack for all ten classes on both teams; reordered/missing/dead targets; root/stun/channel guards; and bounded lookup plus ordinary-turn budget. Maximum observed 18,015 instructions / 25,993 work units. Candidate SHA1 `F130B193E8360689CD13B42EADBD75D546691E42`. These are mechanism checks only, not local scores. Review corrected root arriving after the walk so legal reattack remains possible.
- CPUX: commit `7dce75b` pushed, uploaded as `rowdaboat-gods-of-the-arena:v2` / `40fa69ae-fa23-48fe-9d13-b34099c404be`. Hosted XP `xreq_e22ca8a2-a917-4b2f-a4da-7b63f37c634f`, 10/10 completed, zero failures. No league submission made.
- Hosted provenance: exact requested roster, one own hero, three seats per unique opponent policy, own seats 0–9 once each, no fillers, correct policy owners, canonical Coworld `2026.9.24.2`, competition variant matching B000. All ten own logs contain only start/completion. Every authoritative own score is zero, as in B000. These are raw observations, not a mean comparison or significance result. Sanitized evidence: `research/t001-provenance.json`.
- Hosted activation proven in job 0: exact v2 at seat 0, VanguardKnight; all 28,909 recorded hashes match. The Nim extractor finds 41 strict fresh basic-hit → accepted sole walk next tick → accepted sole attack to the same stable target ID on the following tick sequences. Of these, 29 yield a next same-target hit after 13 ticks versus the native 27. Example: hit 1261 → walk 1262 → reattack target 1091 at 1263 → next hit 1274. This establishes activation only. Report: `research/t001-mechanism.md`; sanitized tracked receipt: `experiments/rowdaboat/evidence/t001-mechanism.json`.
- Opponents refreshed this continuation: Andre von Auto `khors:v208`, Ari Sklar `arisk-gods-of-the-arena:v4`, richard `richard-gods-of-the-arena:v245` (same UUIDs as B000). Refresh again immediately before request. Hosted Coworld and source remain `2026.9.24.2` / `23f3384`.
- Dashboard recheck: exact league XP URL still returns `ERR_NAME_NOT_RESOLVED`. This is the second goal turn observing the same access blocker; previous turn made progress by establishing champion, hosted baseline and replay evidence.
- Verdict: **REVERTED**. No statistically significant improvement was established; dashboard DNS still fails after the completed batch. Active `policy.bas` has been restored byte-for-byte to v1 (SHA-256 `5dbbd273ca48953649e8fc772644fd81242ecb3454e482154665ece13adec904`). Saved trial commit/upload/evidence are historical records, not a kept candidate. Submitted v1 remains the active champion.

## Access blocker audit — 2026-09-25

- Previous goal turn made concrete progress: completed T001 CPUX, all ten hosted episodes, runtime/provenance and exact replay checks, then reverted the unproven change. Revert and evidence commit `4769432` is pushed.
- This is the third consecutive goal turn with the same required-dashboard access failure. A fresh browser request to the exact XP URL again returned `ERR_NAME_NOT_RESOLVED`; an independent unauthenticated read also failed. Softmax's hosted API remains reachable.
- Current authoritative state: v1 is still the active competing champion, and the live leaderboard places RowDaBoat at rank 21. The goal has not been achieved. There is no running trial or uncommitted candidate to finish.
- Initial champion, baseline, rule audit, top-player replay research, one isolated trial, and its revert are complete. Remaining policy advances require a significance decision from the requested dashboard; further hosted batches cannot make that decision observable while its network remains unavailable. No additional trial is started simply to work around that gate.
- Required external change: connect this machine to the dashboard's Tailscale network/DNS, or provide a reachable URL for the same dashboard. The earlier access question remains unanswered. Once access works, verify RowDaBoat's player slug, refresh the release and top three, and resume the backlog with existing-equipment purchase priority as the next isolated hypothesis.
