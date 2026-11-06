# AWM — Archers Warriors Mages

A card game for 2 to 7 heroes, written in Nim on Polyworld, native and in the
browser. Players are BASIC scripts (or a human at the table). This file is
the reference for writing those scripts: the rules, the whole bot API, a
working example, and how to test a bot.

## Quick start

From this folder (`games/awm`):

```sh
nim c src/awm.nim                                 # builds ./awm
./awm --cards:warrior                             # print a class's cards
./awm --human --bot players/warrior.bas           # play against a bot
nim c -d:headless -o:build/awm-headless src/awm.nim
./build/awm-headless --bot my.bas --bot players/mage.bas --seed 7
```

## Rules

- **Heroes.** Each hero has a class (Archer, Warrior or Mage), 20 life and
  a 40-card deck, and draws 5 cards. Seats take turns in order; the first
  is random and skips the draw on the first turn.
- **Turn.** At the start of your turn your total energy rises by 1 (no
  cap), your energy refills to it, you draw 1 card, and your start-of-turn
  triggers fire. Then, in any order: play cards you can afford, and attack
  once with each ready minion. Ending the turn fires end-of-turn triggers.
- **Card kinds.** A minion stays in play with power/toughness and attacks.
  A spell resolves and goes to the discard pile. A trinket stays in play
  but is not a minion: it never attacks, can't be attacked, and "minion"
  targets and "all minions" effects skip it.
- **Combat.** An attacker hits one opponent's hero or minion; minions deal
  their power to each other at once. Damage stays. A minion at 0 toughness
  dies to its owner's discard pile. A minion attacks from its controller's
  next turn, once per turn. A fight (Duel) is combat without an attack: it
  uses up neither minion's attack.
- **Keywords.**
  - *Ranged*: takes no combat damage from non-Ranged minions, attacking or
    defending. Card effects still damage it.
  - *Hidden N*: can't be attacked for N more of its owner's turns; plain
    *Hidden* lasts while it is in play. Cards still reach it, and it
    attacks normally.
  - *Ready*: can attack the turn it enters play.
  - *Lasts N*: leaves play as the Nth of its controller's turns ends,
    counting the turn it entered.
- **Changes in play.** Buffs, weakens, damage, and gained or lost rules
  last while the card stays in play. A bounced card returns to its owner's
  hand as printed. Summoned minions enter at the right of the board and
  run their on-play rules for their controller.
- **Control.** A minion taken with Control or Gift keeps its damage and
  changes, and attacks from its new controller's next turn. It is still
  its owner's card: bounced or killed, it goes to the owner.
- **Classes.** A card of another class costs 3 more energy, less 1 for each
  of that class's level-up card (the 0-cost `Archer`, `Warrior` and `Mage`
  trinkets) you control, and never less than printed.
- **Decks.** Exactly 40 cards, any base-set cards by printed name, 1 to 4
  copies each; level-up cards take any number. An illegal deck is out
  before the first turn.
- **Winning.** A hero at 0 life or below, or who draws from an empty deck,
  is out: their hand is discarded, and their cards in play stay (their
  minions can still be attacked). The last hero standing wins. If the
  last heroes fall together, the one whose turn it is wins.

Every card: `./awm --cards` (or `--cards:CLASS`, `--card:NAME`; see
[Card reference](#card-reference)). The precon decks are `baseDeckLists` in
`src/baseset.nim`.

## Writing a bot

A bot is one `.bas` file. `players/` holds four reference bots that play
alike and differ only in their deck: `archer.bas`, `warrior.bas` and
`mage.bas` play the precons, `archer_warrior.bas` an Archer deck splashing
Warrior cards. They are good starting points and list the API in their
header.

### How a script runs

1. **Setup.** Before the deal the script runs once with `selectingClass`
   set. Call `pickClass(c)` and `deckCard(name$, copies)` until the deck
   has 40 cards, then `END`. Game commands are refused here, and
   `selfClass`, `enemyClass` and `playerClass` return -1.
2. **Decisions.** Whenever your seat must act, the script runs again from
   the top and must make **exactly one successful command**. A run with
   none is a player error: the match stops and you score 0. Commands
   return 1 when accepted and 0 when refused (a refused command changes
   nothing, so try another). `END` stops the script; it does not end the
   turn. Globals and arrays keep their values between runs within a match.
3. **What is asked.** Check in this order:

| Condition | Command to make |
|---|---|
| `tossCount > 0` | `discardCards("picks")`: a rule makes you discard `tossCount` cards |
| `triggerTargets > 0` | `resolveTrigger("picks")`: one of your triggers waits for targets |
| otherwise (your turn) | `playCard…`, `attack` or `endTurn()` |

Discards and triggers can come during another player's turn. The engine
never acts for you: no automatic attack, target, discard or turn end.

### BASIC in brief

[Bassy](https://github.com/treeform/bassy) BASIC
([language reference](https://github.com/treeform/bassy/blob/master/docs/language.md)).
Case-insensitive. `name$` is a string, `name` a number (int32, or Q16.16
fixed point). `DIM a(63)` makes a global array with indexes 0 to 63; there
are no 2-D arrays. Blocks: `IF … THEN … ELSEIF … ELSE … END IF`,
`WHILE … WEND`, `FOR i = a TO b [STEP s] … NEXT`, `GOSUB label` /
`RETURN`, `SUB name(args) … END SUB` (no return values). `:` separates
statements; `'` starts a comment. Comparisons give -1 (true) or 0; `AND`,
`OR`, `NOT` are bitwise, so compare host results explicitly
(`IF canPlay(i) = 1 AND n > 0`). `/` divides in fixed point, `\` in
integers, `MOD` is the remainder. `PRINT` writes to your private log.
Per decision: 5,000,000 instructions, 64 MiB, 256 arrays; source up to
256 KiB.

### Values

Read-only numbers, current at each run. "Enemy" is `enemyPlayer`, the next
living seat after yours.

| Value | Meaning |
|---|---|
| `selfPlayer`, `enemyPlayer`, `currentPlayer`, `playerCount` | Seats, zero-based; `currentPlayer` is whose turn it is |
| `turnNumber` | The current turn, counting every seat's turns from 1 |
| `selfLife`, `enemyLife` | Hero life |
| `energy`, `totalEnergy` | Your energy now, and your per-turn total |
| `handSize`, `selfDeckSize`, `enemyDeckSize` | Card counts |
| `selfBoardSize`, `enemyBoardSize` | Cards in play (minions and trinkets) |
| `selfClass`, `enemyClass` | Classes: 0 Archer, 1 Warrior, 2 Mage |
| `tossCount`, `triggerTargets` | See [How a script runs](#how-a-script-runs) |
| `selectingClass` | 1 during setup |

### Numbers used everywhere

| Kind | Values |
|---|---|
| Class | 0 Archer, 1 Warrior, 2 Mage; -1 none (level-up cards) |
| Card kind | 0 minion, 1 spell, 2 trinket |
| Keyword `k` | 0 Ranged, 1 Ready |
| Choice kind | 0 canceled, 1 no target, 2 hero, 3 a card in play, 4 an option (a branch of "Choose:"); 5 a hand card (event log only) |
| Intent | 0 nothing to judge, 1 damage, 2 buff, 3 weaken, 4 bounce, 5 destroy, 6 loses a keyword, 7 gain control, 8 fights it |

Board indexes run 0 to `boardCount(p) - 1`, hand indexes 0 to
`handSize - 1`. A card in play also has a stable `boardId` that survives
moves; a card's string id (`id$`) is its printed name.

### Queries

**Players** (any seat `p`): `playerClass(p)`, `playerLife(p)`,
`playerEnergy(p)`, `playerTotalEnergy(p)`, `playerHandSize(p)`,
`playerDeckSize(p)`, `playerDead(p)`.

**Your hand** (`i`): `handName$(i)`, `handId$(i)`, `handKind(i)`,
`handCost(i)` (what it costs you now, off-class extra included),
`handPower(i)`, `handToughness(i)`, `canPlay(i)` (1 if affordable; it may
still lack a legal target), `needsChoice(i)` (1 if it takes targets).

**Cards in play** (seat `p`, index `i`):

| Query | Returns |
|---|---|
| `boardCount(p)`, `boardId(p, i)` | How many; the card's stable id |
| `boardName$(p, i)`, `boardCard$(p, i)`, `boardKind(p, i)` | Name, string id, kind |
| `boardPower(p, i)`, `boardHp(p, i)` | Live power and remaining toughness |
| `boardReady(p, i)`, `boardAttacked(p, i)` | 1 if it may attack this turn; 1 if it already did |
| `boardHasKeyword(p, i, k)` | 1 if it has keyword `k` now |
| `boardRules$(p, i)` | Its rules now, as text |
| `boardStolenFrom(p, i)` | Its owner when someone else controls it; -1 otherwise |
| `boardHiddenTurns(p, i)` | Owner's turns it stays Hidden: 0 none, -1 for good |
| `boardLastsTurns(p, i)` | Controller's turns before it leaves play; 0 if it doesn't |

`selfBoardPower(i)`, `selfBoardHp(i)`, `enemyBoardPower(i)` and
`enemyBoardHp(i)` are shorthands for your board and `enemyPlayer`'s.

**Any card by string id** (from `handId$`, `boardCard$` or a printed
name): `cardName$(id$)`, `cardRules$(id$)`, `cardKind(id$)`,
`cardClass(id$)`, `cardCost(id$)` (printed), `cardPower(id$)`,
`cardToughness(id$)`, `cardHasKeyword(id$, k)`.

### Playing a card

A card asks for its targets one step at a time. A choice of branches
(Overcharge, Pillage) is a step whose choices are options (kind 4), and
the branch's own targets appear only once it is picked; Reload's targets
appear once the card to repeat is picked. So build the picks in a BASIC
array, and re-read the target count after each pick:

| Query (hand index `h`, -1 for a waiting trigger) | Returns |
|---|---|
| `nextTargetCount(h, "picks", s)` | Targets the card asks for, given the first `s` picks |
| `nextChoiceCount(h, "picks", s)` | Legal choices for target `s` |
| `nextChoiceKind/Owner/Id(h, "picks", s, c)` | Choice `c`: kind, seat (-1 for an option), `boardId` (0 for a hero) |
| `nextHelpsTarget(h, "picks", s)` | 1 if target `s` should be one of yours |
| `nextIntent(h, "picks", s)`, `nextAmount(h, "picks", s)` | What it does to target `s`, and how much (a fight: the fighter's power) |
| `optionDamage/optionSelfDamage(h, "picks", s, c)` | Damage option `c` deals, and deals to your own hero |
| `optionRules$(h, "picks", s, c)` | Option `c`'s words |

Then play with `playCardTargets(h, "picks")`. `playCard(h)` plays a card
without targets; `playCardChoice(h, c)` and `playCardChoices(h, c1, c2)`
take one or two choice indexes directly. A minion's on-play target offers
a no-target choice (kind 1): pick it to play the minion without its effect.
The same steps answer a waiting trigger (`h = -1`, then
`resolveTrigger("picks")`).

Earlier, simpler forms read only what a card asks before any pick:
`targetCount(h)`, `choiceCount/Kind/Owner/Id(h, c)` (first target),
`targetChoiceCount(h, s)`, `targetChoiceKind/Owner(h, s, c)`,
`helpsTarget(h, s)`, `targetIntent(h, s)`, `targetAmount(h, s)`, and for
triggers `triggerChoiceCount(s)`, `triggerChoiceKind/Owner/Id(s, c)`,
`triggerHelpsTarget(s)`.

### Attacking and ending the turn

`attackChoiceCount(id)` lists what minion `id` (a `boardId`) may attack now:
0 if it can't. Choices run over every opponent in seat order after yours,
each hero before its minions; Hidden minions and the heroes of players who
are out are not offered. `attackChoiceKind/Owner/Id(id, c)` describe choice
`c`, and `attack(id, c)` makes the attack. `endTurn()` ends your turn.

### Who is asking

While a discard or trigger waits, these name its source (`""`, -1 or 0
otherwise):

| Query | Returns |
|---|---|
| `tossCard$()`, `tossRules$()`, `tossOwner()`, `tossSourceId()` | The card asking you to discard, its rule, whose effect it is, its `boardId` (0 for a spell) |
| `triggerCard$()`, `triggerRules$()`, `triggerOwner()`, `triggerSourceId()` | The waiting trigger's card, its sentence, whose it is (you), its `boardId` |
| `triggerOnPlay()` | 1 for a summoned card's on-play rules, 0 for an `on(...)` trigger |
| `triggerAttackerOwner()`, `triggerAttackerId()` | The attack that fired it |
| `triggerPlayed$()`, `triggerPlayedId()` | The card whose play fired it |

### Event log

Everything since your last decision, your own actions included, oldest
first: events 0 to `logCount() - 1`.

| Query (event `e`, target `t`) | Returns |
|---|---|
| `logKind$(e)`, `logTurn(e)`, `logPlayer(e)` | What happened, when, and who acted or was hit |
| `logCard$(e)`, `logCardId(e)`, `logOwner(e)` | The card, its `boardId` (0 if not in play), whose it is |
| `logCause$(e)`, `logCauseId(e)`, `logCauseOwner(e)` | What fired a trigger |
| `logAmount(e)`, `logAmount2(e)`, `logText$(e)` | Its numbers and the rule's words |
| `logTargetCount(e)`, `logTargetKind/Owner/Id(e, t)`, `logTargetCard$(e, t)` | Its picks or the cards it names |

| `logKind$` | `logPlayer` | Also |
|---|---|---|
| `turn` | whose turn starts | |
| `draw` | who drew | the card stays hidden |
| `play` | who played | card (id 0 for a spell); targets: its picks |
| `attack` | the attacker's controller | card: the attacker; amount: its power; target: what it hit |
| `choice`, `trigger` | who it resolves for | card; cause; text; targets: the picks |
| `discard` | who discarded | card: what asked; amount; targets: the cards |
| `damage` | the hit hero's player, or the minion's controller | card (`""` for a hero); amount |
| `death`, `bounce` | its controller | card; owner: whose discard pile or hand it goes to |
| `summon` | who it is summoned for | card |
| `gainControl` | who took it | card; owner: who had it |
| `stats` | its controller | amount: power change; amount2: toughness change |
| `gain`, `lose` | its controller | card; text: the rule |
| `defeat` | who is out | targets: their discarded hand |

An event comes before what it causes: a `play` before its damage, an
`attack` before the damage and deaths.

### Reading rules as a tree

`rulesOfCard(id$)`, `rulesOfBoard(p, i)` (its rules now) or
`rulesOfTrigger()` selects a card's rules and returns the node count. Nodes
0 to `nodeCount() - 1` come in written order, each after its parent:
`nodeKind$(n)` is the card DSL call (`damage`, `target`, `hidden`,
`lasts`, `fixed`, `set`…), `nodeRole$(n)` its part of the parent
(`amount`, `what`, `turns`…), `nodeParent(n)` (-1 for a top rule),
`nodeValue(n)` (a number; -1 for a count that never ends), `nodeText$(n)`,
`nodeChild(n, role$)` and `nodeFind(kind$, after)` (-1 when none). For
example `nodeValue(nodeChild(nodeFind("hidden", -1), "turns"))` is a card's
printed Hidden count.

### Other calls

- `random(n)`: an integer from 0 to n - 1, seeded by the match seed and
  your seat. It doesn't touch the game's shuffle.
- `sendChat(slot, text$)` (`-2` for everyone), `pullMailbox$()`,
  `mailboxId()`, `mailboxCount()`, `mailboxSelf()`, `mailboxPlayers()`:
  messages between players, read when your script next runs.

### A complete minimal bot

It plays the first card it can aim, attacks the first legal target with
each minion, and answers every discard and trigger:

```basic
IF selectingClass THEN
  pickClass(1)                    ' Warrior, with its precon deck
  deckCard("Bear", 4): deckCard("Swords", 4): deckCard("Shields", 4)
  deckCard("Duel", 4): deckCard("Tactician", 4): deckCard("Footsoldier", 4)
  deckCard("Commander", 4): deckCard("Rally", 4): deckCard("Banner", 4)
  deckCard("Pillage", 4)
  END
END IF

DIM picks(63)

IF tossCount > 0 THEN             ' discard the first cards in hand
  FOR i = 0 TO tossCount - 1: picks(i) = i: NEXT
  discardCards("picks")
  END
END IF

IF triggerTargets > 0 THEN        ' aim a waiting trigger
  h = -1: GOSUB aimAll
  resolveTrigger("picks")
  END
END IF

FOR h = 0 TO handSize - 1         ' play the first card that can be aimed
  IF canPlay(h) THEN
    GOSUB aimAll
    IF ok THEN
      IF playCardTargets(h, "picks") THEN END
    END IF
  END IF
NEXT

FOR b = 0 TO boardCount(selfPlayer) - 1
  id = boardId(selfPlayer, b)
  IF attackChoiceCount(id) > 0 THEN
    IF attack(id, 0) THEN END
  END IF
NEXT

endTurn()
END

aimAll:
' Fill picks() for hand card h (-1: the waiting trigger): one of yours when
' the target helps, an enemy's when it hurts, else the first choice.
ok = 1: s = 0
count = nextTargetCount(h, "picks", 0)
WHILE s < count AND ok
  n = nextChoiceCount(h, "picks", s)
  IF n = 0 THEN
    ok = 0
  ELSE
    mine = nextHelpsTarget(h, "picks", s)
    picks(s) = 0
    FOR c = n - 1 TO 0 STEP -1
      o = nextChoiceOwner(h, "picks", s, c)
      IF o >= 0 AND (o = selfPlayer) = (mine = 1) THEN picks(s) = c
    NEXT
    count = nextTargetCount(h, "picks", s + 1)  ' a pick can add targets
    s = s + 1
  END IF
WEND
RETURN
```

### Testing a bot

```sh
./build/awm-headless --bot my.bas --bot players/warrior.bas --seed 3
./build/awm-headless --bot my.bas:4 --bot players/mage.bas --record m.replay
./build/awm-headless --replay m.replay       # check it replays exactly
./awm --replay m.replay                      # watch it
./awm --bot my.bas                           # watch it play itself
./awm --human --bot my.bas                   # play against it
```

Headless flags: `--bot PATH[:COUNT]` once per group of seats (2 to 7 seats
in all), `--seed N`, `--ticks N` (one tick is one action), `--classes
archer,mage,...` (one class per seat, each playing its precon instead of
the script's deck), `--record PATH`, `--replay PATH`. It prints the outcome
(`winner_N`, `draw`, `timeout` or `player_failure`), and a script's errors
and illegal deck.

## Card reference

`--cards` prints every card and exits; `--cards:CLASS` (`archer`, `warrior`,
`mage`) prints that class's cards, its level-up card included; `--card:NAME`
prints one. Names ignore case, spaces and hyphens (`--card:hail-of-arrows`);
`--card NAME` works too. Every build answers without opening a window:

```
Card:   Sharpshooter
Cost:   3
Class:  Archer
Type:   Minion
Effect: Ranged
        Deal 1 damage to any target.
P/T:    3/1
```

`—` marks no rules, no class or no stats.

## Playing

```sh
./awm                               # two reference bots
./awm --human                       # you pick a class on screen and play its precon
./awm --human players/mage.bas      # you play that script's class and deck
./awm --players 4 --human           # you and 3 bots around the ring
```

| Flag | Meaning |
|---|---|
| `--human [PATH.bas]` | You play seat 0 (shown as player 1) |
| `--bot PATH` | Bot script, up to 2; one plays both duel seats, and with `--human` it is your opponent. Default: the reference bots in `players/` (a human faces one at random) |
| `--players N` | 2 is a duel; 3 to 7 play the ring (last one standing wins) |
| `--seed N` | Fixed deal; without it every game takes a new seed and prints it |
| `--replay PATH` | Watch a recorded match |
| `--cards`, `--cards:CLASS`, `--card:NAME` | Print cards and exit |
| `-h`, `--help` | Print the options and exit |

## Coworld

AWM runs on Coworld like Polyworld's other games: each seat is one uploaded
`.bas` file, the match plays headless, and its results and replay are
published. Two seats play a duel, 3 to 7 the ring. The config takes
`players` and `tokens` (2 to 7), `seed`, `max_ticks`, and an optional
`classes` list (one per seat; each then plays its precon). The winner
scores 1 and everyone else 0; a draw, a timeout or a player failure scores
0 for all. `PRINT` output and errors go to the player's private log. The
package is in [`coworld/awm`](../../coworld/awm), the platform guide is
[`coworld/awm/guide.md`](../../coworld/awm/guide.md), and the runtime
contract is [`coworld/integration.md`](../../coworld/integration.md).

```sh
(cd ../.. && nim r coworld/tools/sync_dependencies.nim)
nim c -d:coworld -o:../../tmp/coworld/awm src/awm.nim
(cd ../.. && nim r coworld/tools/test_runtime.nim awm)
coworld build --project ../../coworld/awm --version VERSION
```

## Development

```
src/awm.nim         command line, then a game mode
src/baseset.nim     the cards and precon decks
src/core/           the game, no window: the card rules DSL (core), the
                    match engine (sim), the BASIC bot API (bots), bot
                    matches (match), replays, card lookups (cardset) and
                    reference (cardlist), event text, rule trees, session
                    options and saved games
src/modes/          duel, multiplayer ring, headless and Coworld runners
src/app.nim, src/play.nim, src/replayer.nim
                    what the table modes share: window, targeting, replays
src/scene/          3D table, courtyard, ring, heroes, screen effects
src/ui/, src/vfx/   HUD, card faces, tuning panels; card and combat effects
tools/              web build, asset staging and review renders
```

Every test (`test_courtyard_render` needs a GPU):

```sh
for t in tests/*.nim; do nim r --out:build/$(basename $t .nim) $t; done
```

**Browser.** `./tools/serve.sh` builds and serves on port 8080
(`AWM_SKIP_WEB_BUILD=1` serves the existing build; `./tools/build_web.sh`
only builds). URL parameters mirror the flags: `human=1`, `players=N`,
`seed=N`, `bot=URL` (repeatable), `replay=URL`, e.g.
`awm.html?players=4&human=1`. Card art is staged cropped to the 546 × 417
art window, so the download stays near 31 MB. The replay viewer:
`AWM_WEB_DIR=build/replay ./tools/build_web.sh -d:replayViewer`, then
`awm.html?replay=URL`. With Playwright, `node tests/test_hero_select.cjs`
checks hero selection against the server.

**Debug switches.**

| Switch | Effect |
|---|---|
| F8 | Screen effects on or off |
| `AWM_POSTFX=0`; `AWM_SSAO=0`, `AWM_BLOOM=0`, `AWM_FXAA=0` | All effects off; one off |
| `AWM_SSAO_RADIUS`, `AWM_SSAO_INTENSITY`, `AWM_SSAO_BIAS` | Occlusion tuning (1.501, 3.523, 0.08) |
| `AWM_STONE_NORMALS=0` | Flat stone |
| `-d:awmPostLayers`, `AWM_POST_LAYER=N` | Keys 0–9 show the effect layers; start on layer N |
| `-d:awmPostPanel` | Effect tuning window (F9); "Print settings" gives `defaultPostSettings` |
| `-d:awmLayoutTuning` | Move camera and hands live: Z/X pick, WASD/QE move, T/G pitch, F/H yaw, Enter prints |
| `-d:takeScreenshot` | Writes a screenshot after `AWM_CAPTURE_FRAME` frames (`SCREENSHOT_PATH`) and quits |

Assets come from the sibling `polyworld_art/awm`. `tools/render_cards.nim`
and `tools/render_vfx.nim` render review images into `build/`;
`tools/render_stone_normals.nim` rebuilds the stone normal maps.
