# Archers Warriors Mages

Two to seven BASIC heroes play a card game around a courtyard. Each hero has a
class (Archer, Warrior, or Mage), 20 life, and a 40-card deck. The last
hero standing scores one win; everyone else, and every hero in a draw or a
timeout, scores zero.

Two players play a duel. Three to seven play a free-for-all around a ring of
balconies, in seat order. Each slot commands one hero. Platform slots are
zero-based. Classes and decks come from each script's pre-match setup, or
the optional `classes` config (one per slot) when an explicit roster override
is wanted; then every slot plays its class's precon deck.
Upload a `.bas` file containing BASIC source. The game
reads the staged file directly, with no player container or network
connection.

Start with a bundled player, which lists the game's values and calls:
`players/archer.bas`, `players/warrior.bas`, and `players/mage.bas` play the
class precons, and `players/archer_warrior.bas` an Archer deck with Warrior
cards. They play
alike and differ only in their setup.
The same source is available under `examples/awm/src/core/bots.nim`, and the
cards are in `examples/awm/src/baseset.nim` and `examples/awm/README.md`.

## Class and deck selection

Before dealing cards, the engine runs each script once with `selectingClass`
set to one. Call `pickClass(0)` for Archer, `pickClass(1)` for Warrior, or
`pickClass(2)` for Mage, list a deck with `deckCard(name$, copies)`, then
`END`. No game action is accepted during setup. Normal decisions have
`selectingClass = 0`. For example:

```basic
IF selectingClass THEN
  pickClass(0)            ' Archer
  deckCard("Bolt", 4)
  deckCard("Sniper", 4)
  ' ... 40 cards in all
  END
END IF
' Select one normal action here.
endTurn()
```

A deck holds exactly 40 cards, named as printed. It may hold 1 to 4 copies of
each card, and any number of the class cards `Archer`, `Warrior`, and `Mage`;
a card listed twice counts its copies together. `deckCard` returns 0 for a
name that is no card. Cards of any class may go in: a card of another class
costs 3 more energy, 1 less for each class card of its class you have in
play. A script whose deck breaks these rules is out before the first turn,
and its private log says why.

`selfClass`, `enemyClass`, and `playerClass(slot)` use those same numbers.
During setup they return -1 because the match roster has not been dealt yet.
Your `selfPlayer` and `playerCount` are already available. Globals selected
in setup survive into decisions; a new match resets them. The chosen roster
and its decks are stored in the replay before the first action. `random(n)`
returns an integer from zero to n - 1 using private policy randomness seeded
by the match seed and seat. It does not advance the game's shuffle RNG. The
reference scripts use it for card order, all legal hero and minion attack
targets, card targets, discards, and trigger targets. It tries attacks
both before and after card plays, then explicitly ends when no move is left.
Card targets prefer friendly cards for helpful effects and opponents for
harmful effects, using `helpsTarget(handIndex, step)`.
An explicit `classes` config
bypasses selection and deals each slot its class's precon.

## Public observations

The following queries cover every seat and every board slot, with no small
board-size limit. Hand and board indexes are zero-based. String card
identities are unique printed names; integer `boardId` values identify a
particular permanent, including duplicates of the same card.

| Query | Visible information |
| --- | --- |
| `handId$(i)`, `handName$(i)` | Identity of any card in your hand |
| `boardCount(p)`, `boardId(p, i)`, `boardCard$(p, i)` | Every player's board and permanent identity |
| `boardName$(p, i)`, `boardKind(p, i)` | Printed name and kind: minion 0, spell 1, trinket 2 |
| `boardPower(p, i)`, `boardHp(p, i)` | Live power and remaining toughness |
| `boardReady(p, i)`, `boardAttacked(p, i)` | Attack readiness and whether it attacked this turn |
| `boardHasKeyword(p, i, k)` | Current keyword state, including gained and removed keywords |
| `cardName$(id$)`, `cardRules$(id$)` | Printed name and the same rules text humans see |
| `cardKind(id$)`, `cardClass(id$)`, `cardCost(id$)` | Printed kind, class (-1 for neutral), and energy cost |
| `cardPower(id$)`, `cardToughness(id$)`, `cardHasKeyword(id$, k)` | Printed stats and keywords before buffs, gains, or losses |
| `playerClass(p)`, `playerLife(p)`, `playerEnergy(p)`, `playerTotalEnergy(p)` | Public hero state |
| `playerHandSize(p)`, `playerDeckSize(p)`, `playerDead(p)` | Public zone sizes and defeat state |

Keyword zero is Ranged. Compare printed stats from `cardPower` and
`cardToughness` against live `boardPower` and `boardHp`. The metadata queries
also accept the replay's stable string card IDs. Opponent hand identities
and deck contents remain hidden. Discard browsing is not added by this API.
Actions enumerate the same legal targets as human controls, across every
player, including defeated players' remaining minions where rules allow.

## Turns

Each turn the hero gains one energy, refills it, and draws a card (the first
player skips their first draw). Drawing from an empty deck loses. Your script
runs once per decision and selects exactly one action. Scripts may attack,
play cards, and attack again in any legal order before explicitly calling
`endTurn()`. Ending a turn never makes attacks. Mandatory card effects, turn
draws, and combat rules apply equally to humans and bots. Newly played
minions still have summoning sickness, exactly as in human play.

Scripts choose every attacker, attack target, card target, discard, and
trigger target. A waiting choice invokes its owner's script, including
choices that happen during another player's turn. Use `tossCount` and
`triggerTargets` to recognize those decisions. There is no automatic
30-card turn limit; `max_ticks` bounds the match instead.

Commands return one on success and zero if refused. Only one successful
command is allowed per decision. `END` terminates BASIC execution; it does
not end the game turn. A decision with no accepted action is a player error,
without an automatic attack, discard, target choice, or turn end. Existing
scripts must add explicit attacks and `endTurn()` and handle waiting choices.

The script's `enemyPlayer` is the next living player. `selfPlayer` is your
slot. Globals and arrays keep their values between decisions.

## Actions

- `attack(attackerId, choiceIndex)` attacks once. Get stable IDs with
  `boardId(player, index)`. `attackChoiceCount`, `attackChoiceKind`,
  `attackChoiceOwner`, and `attackChoiceId` list all legal opponent heroes
  and minions, rather than restricting attacks to the next player.
- `endTurn()` ends the turn without attacking.
- `playCard`, `playCardChoice`, and `playCardChoices` remain available.
  `playCardTargets(handIndex, "picks")` reads all target indexes from the
  BASIC array `picks()`. Card-choice queries include a permanent's own
  predicted board ID, so a Bouncer may target itself as in the human UI.
- `discardCards("picks")` reads exactly `tossCount` distinct hand indexes
  from `picks()`. The script selects which cards to discard.
- `resolveTrigger("picks")` reads exactly `triggerTargets` target indexes
  from `picks()`. A no-target choice may explicitly decline a trigger.

`nextChoiceCount(handIndex, "picks", pickedCount)` lists the next target
choices after the array's previously chosen indexes. `nextChoiceKind`,
`nextChoiceOwner`, and `nextChoiceId` take the same arguments plus a choice
index. Use hand index `-1` for a waiting trigger. These queries follow earlier
picks when later targets depend on them. `choiceId` identifies a particular
minion for a card's first target; `handName$` and `boardName$` expose printed
names from the same zones that humans can see.

A card may ask for more targets than it did at the start. A card that offers
a choice (Overcharge, Pillage) asks for the choice first and reveals that
branch's own targets once it is made, and `Reload` repeats another card's
rules, which bring their targets with them. Read the count again after every
pick with `nextTargetCount(handIndex, "picks", pickedCount)`, and keep
filling `picks()` while it grows; `targetCount` and `triggerTargets` are the
counts known before any pick. `playCardTargets` and `resolveTrigger` read as
many indexes as the card finally asks for.

A choice of branches arrives as choice kind 4: the choice index is the
branch, and it names no game object, so its owner is -1. Weigh the branches
with `optionDamage(handIndex, "picks", pickedCount, option)` and
`optionSelfDamage(...)`, which report what a branch deals and what it costs
your own hero. `nextHelpsTarget`, `nextIntent`, and `nextAmount` describe the
next target the same way, following earlier picks: intent 1 is damage,
2 a buff, 3 a weaken, 4 a bounce, 5 a destroy, 6 a lost keyword, and 7 a
steal (Control takes an enemy minion for good).

A card in play can gain or lose rules (Morphosis Chamber gives a minion
Ranged or Hidden 1; Duel takes Ranged away). `boardHasKeyword` follows them.

A hidden minion (Ambusher, Spirit) can't be attacked and never appears among
`attackChoiceCount`'s choices, though cards that aim at it still reach it.

The Mage precon holds four copies of `Summon Primordial`, an eight-energy spell.
Choose a hero, return all cards on that hero's board to their hand, then
summon a 10/10 Primordial on your board. You may choose your own hero.
Primordial itself has no board-clearing effect. Bouncing and replaying it
restores the minion without clearing any board, and it cannot attack again
that turn. Another board clear requires another `Summon Primordial` spell.

## Ticks

One tick is one game action: a card played, one minion's attack, a discard or
trigger answered, or a turn ended. `max_ticks` bounds the match; a match that
reaches it is a timeout. Replays store one action and one state hash per tick
and play back in the browser with seeking, speed, and loop controls.
Replays autoplay and loop by default. Turn off the loop control to stop at
the end of one game.

## Logs and failures

BASIC `PRINT` output, compiler diagnostics, runtime errors, and VM lifecycle
messages go to the owning player's private log. Each log is limited to 10 MiB.
A runtime error, including an instruction limit, or a missing action stops
the match with `player_failure` and zero scores. The engine never invents an
action for a failed script. Decisions are applied only after successful VM
execution, so a later script error cannot leave an unrecorded game action.
Invalid BASIC syntax fails the episode with a player failure diagnostic.
Public game logs and action replays contain no BASIC source or private print
output. The server exposes `/healthz`; legacy clients are static stubs.

## Mailboxes

Each player has an inbox. `sendChat(-2, text$)` reaches every player,
including the sender; `sendChat(slot, text$)` reaches one player. AWM has no
teams. `pullMailbox$()`, `mailboxId()`, `mailboxCount()`, `mailboxSelf()`, and
`mailboxPlayers()` work as in the other Polyworld games. Messages are read
when your script next runs, which is on your turn.

## BASIC numbers

BASIC uses [Bassy](https://github.com/treeform/bassy) with
[Fixxy](https://github.com/treeform/fixxy) Q16.16 decimals enabled. `/`
performs decimal division; `\` performs integer division. Hand indexes,
choice indexes, and slots require exact integers.
