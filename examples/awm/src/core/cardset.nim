## Lookups, wire IDs and decks over the base set. The cards and deck lists
## themselves are configured in ../baseset.nim.

import
  std/[options, strutils],
  core, ../baseset

export baseset

## The card lists are never mutated after module init, so the lookups below
## cast to gcsafe: async server handlers deal decks and encode snapshots.

proc classCardNamed(heroClass: HeroClass, name: string): Card =
  {.cast(gcsafe).}:
    for card in baseCards:
      if card.class == some(heroClass) and card.name == name:
        return card
  raise newException(ValueError,
    "No base-set " & $heroClass & " card named '" & name & "'")

proc classCard*(heroClass: HeroClass): Card =
  ## Each class's signature card, found by name so list order doesn't matter.
  case heroClass
  of Archer: Archer.classCardNamed("Bolt")
  of Warrior: Warrior.classCardNamed("Bear")
  of Mage: Mage.classCardNamed("Bouncer")

proc cardId*(card: Card): string =
  ## Stable wire ID. Name plus cost keeps same-named printings apart.
  card.name.toLowerAscii().replace(" ", "-") & "-" & $card.energyCost

proc baseCard*(id: string): Card =
  {.cast(gcsafe).}:
    for card in baseCards:
      if card.cardId() == id:
        return card
  raise newException(ValueError, "Unknown base-set card '" & id & "'")

proc baseCardNamed*(name: string): Card {.nimcall, gcsafe.} =
  ## The base-set card printed with this name, for `summon`.
  {.cast(gcsafe).}:
    for card in baseCards:
      if card.name == name:
        return card
  raise newException(ValueError, "Unknown base-set card named '" & name & "'")

# A misspelled summon fails at startup rather than mid-game.
for card in baseCards:
  card.checkCardNames(baseCardNamed)

proc baseDeck*(heroClass: HeroClass): seq[Card] =
  ## The class's deck, dealt from its list in baseset.nim.
  for (name, count) in baseDeckLists[heroClass]:
    let card = heroClass.classCardNamed(name)
    for _ in 0 ..< count:
      result.add card
  doAssert result.len == DeckSize
