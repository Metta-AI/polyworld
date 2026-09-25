# RowDaBoat — Gods of the Arena

Goal: reach first place through one-change experiments, hosted XP only.

- League: `gods-of-the-arena`, `league_3c60897b-25cf-4b37-9d1a-8554c1198f28`.
- Player: RowDaBoat, `ply_eeb732fa-5f40-4fa1-beac-6571738f8108` (confirmed in the website).
- Hosted release: `2026.9.24.2`, Coworld `cow_e282a46f-31c4-43b1-a9e2-aaa31d3aaed4`.
- Engine source: `f4456bea13d967cb3f188df357656e1410cb0a40`; replay version 64. Worktree starts from `23f3384`, which records that release.
- Runtime: game-hosted BASIC file `policy.bas`.
- Initial policy is a byte-for-byte copy of the current `examples/gods_of_the_arena/players/base.bas`. No strategy modification.
- The player had no GotA champion at discovery; v1 is now the active initial champion.

Always refresh the top three unique other players and select one live policy per player before XP. Never seat two versions of our own policy against each other. Use at least 10 hosted episodes for each experiment. Keep or submit improvements only when the requested dashboard establishes statistical significance against the current submitted policy's comparable hosted results. Otherwise run more episodes or revert. Replay and isolation checks show that the mechanism fired and are not score evidence.

The campaign backlog and complete trial log are in the workspace root `ideas.md`; a snapshot accompanies campaign commits here. Dashboard access is currently blocked by unresolved Tailscale DNS. Initial working-bot submission is allowed, but no experimental improvement can be kept based on unavailable significance evidence.

## Initial release

- Initial source commit: `ae20666`, pushed on `codex/rowdaboat-gota-20260925`.
- Uploaded: `rowdaboat-gods-of-the-arena:v1`, version UUID `ab664012-84b3-48b3-ae1b-86f3f6cf960c`.
- Initial champion: membership `lpm_6841a493-bd35-460b-ac0f-2de1fbadb7cb`, competing and champion. Submission `sub_f669fd4c-99fe-4034-94cd-5729bdf95bce` uses `auto_champion: never`; initial membership was explicitly promoted, preserving the gate for future candidates.
- Hosted baseline: `xreq_0ad92adc-2c3b-44e3-a1f2-7fcd0fa5805d`, completed 10/10, zero failed episodes. Exact opponent IDs and rotating-seat layout are in `ideas.md`.
- T001 tested a single post-hit walk/reattack recovery change in commit `7dce75b`, uploaded v2 (`40fa69ae-fa23-48fe-9d13-b34099c404be`). Hosted XP `xreq_e22ca8a2-a917-4b2f-a4da-7b63f37c634f` completed 10/10 against the freshly resolved top three, with no failures or runtime diagnostics. All ten own hosted scores were zero. No significant improvement was established, so the policy change was reverted to v1 and no replacement submitted. Dashboard significance remains inaccessible due to unresolved network DNS.

## Evidence and tools

`rules-audit.md` documents the current release changes. Replay audits reconstruct only hosted recordings and require every recorded hash to match. Event counts are mechanism evidence, never a score substitute. Raw replay/event files and authenticated research receipts remain outside version control.
