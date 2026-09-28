# GotA rules check — 2026-09-28

No new GotA rules or example-policy changes were found on fetched `origin/main`
since the initial champion's game baseline, `23f3384`. No policy changes are
needed merely to track upstream features. This is a source audit, not a score.

## Evidence and scope

- Fetched `origin` in `gota-campaign` without checkout, merge, reset or policy edits.
- Current fetched main: `278447ae204291a91848f58d5f604c4cbe0a6fe9`.
- New commits since `23f3384`:
  - `14f9590` (Sep 24): Rebuild Heartleaf with free village assets.
  - `c6c60ce` (Sep 25): Match Heartleaf village to reference layers.
  - `278447a` (Sep 27): Rewrite Heartleaf capture tool in Nim.
- An exact Git diff returned no changes for GotA's `players/`, `bots.nim`,
  `sim.nim`, `content.nim`, `maps.nim`, `replays.nim` or `coworld/gota/`.
  This includes `base.bas`, `puller.bas`, `rusher.bas`, the guide and manifest.
- Latest recorded GotA release remains `2026.9.24.2`, Coworld
  `cow_e282a46f-31c4-43b1-a9e2-aaa31d3aaed4`, replay version **64**.
  Receipt: `coworld/releases/2026-09-24-gota-towers.json`.
- The parent task refreshed the live manifest into
  `research/resume-20260928-manifest.json`; its `/manifest/game/version` is
  still `2026.9.24.2`. Deployed version and inspected source therefore agree.
  No policy/runtime update is needed for a new game release.

## Shared changes inspected

GotA `game.nim` and shared `coworld.nim` no longer force a 1920×1080 window.
This concerns presentation defaults, with no new bot capability or scoring rule.

Shared `pathing.nim` added an optional `PathClearance` callback, optional
`cutCorners`, and clearance-aware path smoothing for Heartleaf obstacles.
Defaults remain `clearance = nil`, `cutCorners = false`. GotA's two existing
`PathQuery` construction sites do not set either field, and its simulation is
unchanged. Thus these additions introduce no active GotA policy/navigation
change in the inspected source.

## Existing current mechanics to retain in experiments

- Abilities and consumables require explicit commands; no automatic spells.
- Score is nonnegative floored lifetime XP minus 200 per simulated minute,
  including drafting. Building last hits give 200 XP; god victory gives every
  teammate 1,000 XP before scoring.
- Towers reach 9/9.5/10 tiles, preserve reload progress, and launch homing shots
  which remain dangerous beyond range, into fog, and after the tower dies.
- Neutral camps and nearby shared XP offer a distinct farming strategy;
  `puller.bas` demonstrates aggro/lure/allied-wave handoff.
- The modern baseline already drafts, spends points, casts, shops, uses
  recovery/portals, buys back, farms lanes and attacks nearby camps.
- Mailboxes exist but chat text is not in replays; any talking experiment
  needs private-log evidence that messages were sent/consumed.

The full initial mechanics audit is `research/gota_rules_audit.md`. Before
choosing one strategy to change, extract current top-player hosted replays and
attribute XP, deaths, movement, spell effects and purchases. Neither a source
change nor local replay analysis substitutes for hosted XP significance.

No local games, policy mutation, upload, submission, commit or push occurred
in this audit.
