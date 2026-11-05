# Cogs vs Clips PW bot

A BASIC policy for [Cogs vs Clips PW](https://softmax.com/cogs-vs-clips-pw)
(Coworld `cow_a770ed22-3db9-42eb-b448-9af3863cd566`, game version 0.1.3).
Upload `player.bas`; it plays any of the four teams.

## Files

- `logic.bas`: the hand-written policy.
- `gen.nim`: writes `player.bas` from `fourscore.txt` and `logic.bas`.
- `fourscore.txt`: the fixed 120 by 120 arena, copied from the game source.
- `player.bas`: the generated upload. Regenerate after every edit:

```sh
nim r bots/cogs_vs_clips/gen.nim
```

## Strategy

The arena never changes, so the map is compiled into the program as DATA:
walls, 176 junctions, 512 extractors, and which junctions each hub can reach.
The starter bot explores first. This one knows the layout from the start.

Seats 0 to 7 of each team:

| Seat | Role | Job |
| --- | --- | --- |
| 0, 1, 2 | Aligner | Load hearts at the hub, capture the nearest reachable neutral junction in its third of the map |
| 3, 4, 5, 6 | Miner | Mine carbon, oxygen, germanium and silicon (one each), deposit at the nearest friendly hub or junction |
| 7 | Scrambler | Neutralize the known enemy junctions closest to home, or scout stale junctions |

While every bank element is at least 80, seat 5 aligns and seat 6 scrambles.
Score is junctions held per tick, and elements pile up faster than three
aligners can spend them.

Each seat remembers the junction owners, extractor stock and territory it
has seen. Movement uses an A* search from the target toward the Cog. It
resumes across ticks within a fixed budget and steps greedily until it
finishes. Visible Cogs are avoided with side steps and random steps.

Survival rules, added after real matches showed death spirals:
- Retreat when health would not last the walk to friendly ground. Only the
  hub and junctions seen on our ground in the last 300 ticks count as friendly.
- Aligners skip junctions, and miners skip extractors, last seen on enemy ground.
- A non-scrambler on enemy ground within 12 tiles of its target gives up
  that target for 400 ticks. Passing through enemy ground is allowed.
- Hearts are crafted only while every element stays at 19 or more, so dead
  Cogs can buy gear again. A Cog that cannot afford gear mines by hand.

## Limits

Each seat has 100,000 work units per tick, and exceeding them stops that
seat for the rest of the match. The worst tick seen in real matches used
63,000 work units.

## Results

Local headless matches of game version 0.1.3, seeds 1 to 3. The bot played one
team and the starter (`act(baseline())`) played the other three. Each
position is compared with the starter playing that same position. Scores
are average junctions held over the 10,000 ticks.

| Position | Starter | Bot |
| --- | --- | --- |
| Red | 21.3 | 54.7 |
| Blue | 29.8 | 41.3 |
| Green | 38.5 | 58.4 |
| Gold | 51.2 | 72.5 |
| Mean | 35.2 | 56.7 |

No seat stopped in any of the 12 matches. Deaths were 284 across the 96
seats, mostly Cogs caught on enemy ground with too little energy to leave.
An earlier version that always left enemy ground died 71 times but got stuck
in pockets as red (mean 54.3).

## Published

`cogs-vs-clips-pw-player:v1` (version `ab169536-4da4-4ee4-aeed-df390c7ad34c`),
uploaded 2026-10-28 from this player.bas
(sha256 `c77b3e456434b6c24d9a1f515496eea42000f21fe9c991bc7f6f81989bab4e67`).
Submitted 2026-10-29 to the Cogs vs Clips PW league
(`league_590dd667-a94d-4c9f-bc22-d7ae0bbbb98b`, game version 0.1.4) as
submission `sub_50f6d69e-8263-43a3-bb33-c162dd584b07`. Version 0.1.4 changed
only the viewer and score units, so the 0.1.3 results above still apply.
Placement status: https://softmax.com/policies/versions/ab169536-4da4-4ee4-aeed-df390c7ad34c

Upload a new version with:

```sh
uvx --from "coworld[auth]@latest" coworld upload-policy --file ./player.bas --name cogs-vs-clips-pw-player --title "TITLE" --description "WHAT CHANGED"
```

## Next ideas

- Fewer deaths on enemy ground: retreat earlier when energy is low.
- Blue holds the fewest junctions. Gold's territory grows toward blue's hub,
  and blue's miners die there.
- Extractors near the hub run dry by mid-game, and germanium runs out first.
