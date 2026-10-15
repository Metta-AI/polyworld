## Rule explanations: what the named mechanics on a card mean, shown under
## the inspected card. The card's rules are walked for the ones that print
## a mechanic's name. Plain verbs (choose, draw, deal damage, destroy,
## discard, return, repeat, give +X/+Y, "at the start of...") say what they
## do and have no explanation.

import std/options
import core

type
  Mechanic* = enum
    ## The mechanics that get an explanation, by the word the card prints.
    RangedMechanic = "Ranged"
    HiddenMechanic = "Hidden"
    SummonMechanic = "Summon"
    FightMechanic = "Fight"
    StealMechanic = "Gain control"
    OffClassMechanic = "Off-class"

const
  Explanations*: array[Mechanic, string] = [
    RangedMechanic:
      "Takes no combat damage from minions without Ranged, attacking or " &
      "defending. Spells and other card effects still damage it.",
    HiddenMechanic:
      "Can't be attacked, but can still attack, and card effects still " &
      "reach it. Hidden 1 lasts until its owner's next turn starts, " &
      "Hidden 2 a turn longer; plain Hidden lasts while it stays in play.",
    SummonMechanic:
      "Puts the named card into play. Summoned minions can " &
      "attack from their owner's next turn.",
    FightMechanic:
      "The two minions deal their power to each other at once, as in " &
      "combat, so Ranged applies. Neither uses up its attack.",
    StealMechanic:
      "The minion joins your board for good, keeping its damage and " &
      "changes, and can attack from your next turn. Returned or slain, it " &
      "still goes to its owner's hand or discard pile.",
    OffClassMechanic:
      "Cards of a class other than your hero's cost " & $OffClassCost &
      " more energy, shown as a purple +X. Class cards you control lower " &
      "that extra cost."
  ]

  KeywordMechanics: array[Keyword, Mechanic] = [
    Ranged: RangedMechanic
  ]

proc mechanic(rule: Rule): Option[Mechanic] =
  ## The mechanic this rule prints, not counting the rules inside it.
  if rule of KeywordRule: some(KeywordMechanics[KeywordRule(rule).keyword])
  elif rule of HiddenRule: some(HiddenMechanic)
  elif rule of SummonRule: some(SummonMechanic)
  elif rule of FightRule: some(FightMechanic)
  elif rule of StealRule: some(StealMechanic)
  elif rule of LevelUpRule: some(OffClassMechanic)
  else: none(Mechanic)

proc mechanics*(rules: Rules): seq[Mechanic] =
  ## The mechanics these rules print, nested ones included ("Choose:",
  ## triggers, gained and lost rules), each once, in the order they read.
  for rule in rules.ruleTree():
    let named = rule.mechanic()
    if named.isSome and named.get notin result:
      result.add named.get

proc mechanics*(card: Card, gained: set[Keyword] = {}): seq[Mechanic] =
  ## The card's mechanics, then those of the keywords it gained in play.
  result = card.rules.mechanics()
  for keyword in gained:
    if KeywordMechanics[keyword] notin result:
      result.add KeywordMechanics[keyword]
