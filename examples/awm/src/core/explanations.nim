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
    ReadyMechanic = "Ready"
    HiddenMechanic = "Hidden"
    LastsMechanic = "Lasts"
    SummonMechanic = "Summon"
    FightMechanic = "Fight"
    GainControlMechanic = "Gain control"
    OffClassMechanic = "Off-class"

const
  Explanations*: array[Mechanic, string] = [
    RangedMechanic:
      "Takes no combat damage from minions without Ranged, attacking or " &
      "defending. Spells and other card effects still damage it.",
    ReadyMechanic:
      "Can attack the turn it enters play. Gained later, it can attack " &
      "that turn, if it hasn't already.",
    HiddenMechanic:
      "Can't be attacked. Hidden(N) Lasts N turns of the owner." &
      "Plain Hidden lasts while it stays in play.",
    LastsMechanic:
      "Leaves play by itself. Lasts N goes to the discard pile as its " &
      "owner's Nth turn from now starts, counting down like Hidden(N).",
    SummonMechanic:
      "Puts the named card into play. Summoned minions can " &
      "attack from their owner's next turn.",
    FightMechanic:
      "The two minions deal their power to each other at once, as in " &
      "combat, so Ranged applies. Neither uses up its attack.",
    GainControlMechanic:
      "The card in play joins its new controller's board. Returned or " &
      "destroyed, it still goes to its owner's hand or discard pile.",
    OffClassMechanic:
      "Cards of a class other than your hero's cost " & $OffClassCost &
      " more energy. Class cards you control lower that extra cost."
  ]

  KeywordMechanics: array[Keyword, Mechanic] = [
    Ranged: RangedMechanic,
    Ready: ReadyMechanic
  ]

proc mechanic(rule: Rule): Option[Mechanic] =
  ## The mechanic this rule prints, not counting the rules inside it.
  if rule of KeywordRule: some(KeywordMechanics[KeywordRule(rule).keyword])
  elif rule of HiddenRule: some(HiddenMechanic)
  elif rule of LastsRule: some(LastsMechanic)
  elif rule of SummonRule: some(SummonMechanic)
  elif rule of FightRule: some(FightMechanic)
  elif rule of GainControlRule: some(GainControlMechanic)
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
