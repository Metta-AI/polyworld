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
- 20 life, 40-card class deck, 5-card opening hand.
- Random first player; first player skips their turn draw.
- Each turn: +1 max energy, full replenish, draw one card.
- Minions attack once per turn, starting the turn after they're played:
  click one, then an enemy minion or hero (right-click cancels). Minions
  deal their power to each other; damage stays, and minions at 0
  toughness go to the discard pile.
- Ranged minions take no combat damage from non-ranged minions, whether
  attacking or defending. Spells and on-play effects still damage them.
- Power/toughness buffs are permanent while the minion stays on the board;
  a bounced minion returns to hand with its printed stats. Changed stats
  show green (raised) or red (lowered) on the card. Lost keywords are
  permanent the same way, and show on the card's type line.
- Summoned minions enter at the right of their owner's board. Like played
  minions they attack from their owner's next turn, and their own on-play
  rules don't run. A card's later rules reach them (Rally buffs its own
  Footsoldiers).
- Cards with several targets (Duel) are aimed one target at a time. A
  fight is combat without an attack: both minions deal their power at
  once, Ranged applies, and it doesn't use up either minion's attack.
- No victory condition yet.

| Class | Card | Copies | Cost | Type | Stats | Effect |
|---|---|---|---|---|---|---|
| Archer | Bolt | 10 | 1 | Spell | — | 2 damage to either hero |
| Archer | Sniper | 14 | 2 | Minion | 2/1 | Ranged |
| Archer | Sharpshooter | 10 | 3 | Minion | 3/1 | Ranged; 1 damage to any target |
| Archer | Hail of Arrows | 6 | 3 | Spell | — | 1 damage to all enemy minions |
| Warrior | Bear | 8 | 2 | Minion | 3/2 | — |
| Warrior | Swords | 5 | 2 | Spell | — | Friendly minions get +1/+0 permanently |
| Warrior | Shields | 4 | 1 | Spell | — | Friendly minions get +0/+1 permanently |
| Warrior | Duel | 5 | 2 | Spell | — | A minion gets +1/+1, a minion loses Ranged, then they fight |
| Warrior | Tactician | 5 | 2 | Minion | 1/2 | A minion gets -1/-0 permanently |
| Warrior | Footsoldier | 6 | 1 | Minion | 1/2 | — |
| Warrior | Commander | 4 | 5 | Minion | 2/3 | Summons 2 Footsoldiers |
| Warrior | Rally | 3 | 5 | Spell | — | Summons 2 Footsoldiers, then friendly minions get +1/+0 |
| Mage | Bouncer | 32 | 1 | Minion | 1/1 | Return a minion to owner's hand |
| Mage | Oozification | 8 | 4 | Spell | — | Destroy a minion, then summon Oozes equal to its current toughness |
| Mage | Ooze | — | 1 | Minion | 1/1 | — (only summoned, by Oozification) |
