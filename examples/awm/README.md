# AWM — Archers Warriors Mages

Card-game prototype in Nim + Polyworld. Native and browser.

## Native

```sh
nim c -o:awm awm.nim
./awm                                        # bot vs bot, random classes
./awm --human --class warrior --opponent mage # play against a bot
./awm --seed 42                              # fixed deal
```

| Flag | Default |
|---|---|
| `--human` | off (bot vs bot) |
| `--class CLASS` | `archer` |
| `--opponent CLASS` | `mage` |
| `--seed INTEGER` | `20260910` |
| `--bot PATH` | `players/base.bas` |

Bot vs bot ignores `--class`/`--opponent` and picks randomly.

## Browser

```sh
./tools/serve.sh                             # build + serve
./tools/build_web.sh                         # build only
AWM_SKIP_WEB_BUILD=1 ./tools/serve.sh       # serve existing build
```

- Spectator: <http://127.0.0.1:8080/client/global>
- Player: <http://127.0.0.1:8080/client/player?class=warrior&opponent=mage&seed=42>

| Server flag | Default |
|---|---|
| `--host ADDRESS` | `127.0.0.1` |
| `--port PORT` | `8080` |
| `--step-ms MS` | `2500` |
| `--max-turns N` | `60` |
| `--seed INTEGER` | `20260910` |
| `--player0 human\|bot` | `human` |
| `--player1 human\|bot` | `bot` |
| `--class CLASS` | chosen at connect |
| `--opponent CLASS` | chosen at connect |

## Tests

```sh
nim r -d:headless --out:build/test_awm tests/test_awm.nim
nim r -d:headless --out:build/test_sessions tests/test_sessions.nim
python3 tests/test_server.py
```

## Rules

- Choose Archer, Warrior, or Mage.
- 20 life, 30-card class deck, 5-card opening hand.
- Random first player; first player skips their turn draw.
- Each turn: +1 max energy, full replenish, draw one card.
- No victory condition yet.

| Class | Card | Cost | Type | Stats | Effect |
|---|---|---|---|---|---|
| Archer | Bolt | 1 | Spell | — | 2 damage to either hero |
| Warrior | Bear | 2 | Minion | 3/2 | — |
| Mage | Bouncer | 1 | Minion | 1/1 | Return a minion to owner's hand |
