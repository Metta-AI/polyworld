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
- Browser is signed in as player RowDaBoat; player slug and existing champion still being verified.
- Live league UI identifies hosted release `2026.9.24.2`.
- Initial live top three: Andre von Auto (`khors:v208`), Ari Sklar (`arisk-gods-of-the-arena:v4`), richard (`richard-gods-of-the-arena:v245`). Refresh before each XP request; exclude our player once confirmed.
- Requested dashboard fails with `ERR_NAME_NOT_RESOLVED`. macOS has no Tailscale DNS resolver and no Tailscale app at standard paths. Softmax itself is reachable. Dashboard significance is not currently observable.
- The nested engine checkout is clean but old (`7f50a61`). Fetched origin: current `origin/main` is `23f3384`, including tower and chat updates. Adjacent `board+cards game/polyworld` contains later tooling but is also behind the current remote; do not use an old engine to validate new replays.
- No experiment, upload, or submission has occurred yet.

## Backlog

1. Confirm our player slug and current champion, and preserve its exact source/version.
2. Restore access to the requested league and XP significance dashboards.
3. Pin the hosted Coworld version, exact source revision, and current example policy. Audit draft, ability ranks, decimal/bitwise semantics, lane/neutral rewards, tower range and projectiles, and chat routing.
4. Build or reuse exact-version Nim replay extractors; inspect top-player navigation, target selection, farming, casting, shop, and group movement. Prioritize this if our performance is far below theirs.
5. Establish a hosted baseline against the current top three other players, minimum 10 episodes, preserving full results and roster.
6. Choose one replay-supported strategy change, isolate its activation, CPUX, and evaluate dashboard significance. Revert unless kept by that evidence.

## Trials

No trials yet. Research and access checks above are not scored experiments.

| Trial | Idea | Exact change / commit | Uploaded policy | XP ID(s) | Top-three opponents | Episodes | Mechanism proof | Dashboard significance | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
