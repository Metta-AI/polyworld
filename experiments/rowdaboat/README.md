# RowDaBoat — Gods of the Arena

Goal: reach first place through one-change experiments, hosted XP only.

- League: `gods-of-the-arena`, `league_3c60897b-25cf-4b37-9d1a-8554c1198f28`.
- Player: RowDaBoat, `ply_eeb732fa-5f40-4fa1-beac-6571738f8108` (confirmed in the website).
- Hosted release: `2026.9.24.2`, Coworld `cow_e282a46f-31c4-43b1-a9e2-aaa31d3aaed4`.
- Engine source: `f4456bea13d967cb3f188df357656e1410cb0a40`; replay version 64. Worktree starts from `23f3384`, which records that release.
- Runtime: game-hosted BASIC file `policy.bas`.
- Initial policy is a byte-for-byte copy of the current `examples/gods_of_the_arena/players/base.bas`. No strategy modification.
- Player profile has no existing GotA champion; initial submission is authorized by the user.

Always refresh the top three unique other players and select one live policy per player before XP. Never seat two versions of our own policy against each other. Use at least 10 hosted episodes for each experiment. Keep or submit improvements only when the requested dashboard establishes statistical significance against the current submitted policy's comparable hosted results. Otherwise run more episodes or revert. Replay and isolation checks show that the mechanism fired and are not score evidence.

The campaign backlog and complete trial log are in the workspace root `ideas.md`; a snapshot accompanies campaign commits here. Dashboard access is currently blocked by unresolved Tailscale DNS. Initial working-bot submission is allowed, but no experimental improvement can be kept based on unavailable significance evidence.

## Initial release

Commit/push, upload ID, champion membership, and hosted baseline XP IDs: pending.
