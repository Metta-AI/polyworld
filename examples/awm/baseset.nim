## AWM base set: coded cards and the class decks built from them.

import
  std/[options, strutils],
  awmcore

const
  DeckSize* = 40

let archer = [
  Card(
    name: "Bolt", energyCost: 1,
    class: some(Archer), kind: Spell,
    rules: rules(damage(2, target({Hero}, vfx = LightningVfx)))
  ),
  Card(
    name: "Sniper", energyCost: 2,
    class: some(Archer), kind: Minion,
    rules: rules(ranged()),
    power: 2, toughness: 1
  ),
  Card(
    name: "Sharpshooter", energyCost: 3,
    class: some(Archer), kind: Minion,
    rules: rules(
      ranged(),
      damage(1, target({Minion, Hero}, vfx = ArrowVfx))
    ),
    power: 3, toughness: 1
  ),
  Card(
    name: "Hail of Arrows", energyCost: 3,
    class: some(Archer), kind: Spell,
    rules: rules(
      damage(
        1,
        game.board.choose(kind: Minion, owner: Opponent),
        vfx = ManyArrowsVfx
      )
    )
  )
]

let warrior = [
  Card(
    name: "Bear", energyCost: 2,
    class: some(Warrior), kind: Minion,
    rules: rules(),
    power: 3, toughness: 2
  ),
  Card(
    name: "Swords", energyCost: 2,
    class: some(Warrior), kind: Spell,
    rules: rules(
      addPowerToughness(
        1, 0,
        game.board.choose(kind: Minion, owner: You),
        vfx = SwordsIntoTheWindVfx
      )
    )
  ),
  Card(
    name: "Shields", energyCost: 1,
    class: some(Warrior), kind: Spell,
    rules: rules(
      addPowerToughness(
        0, 1,
        game.board.choose(kind: Minion, owner: You),
        vfx = MightyShieldsVfx
      )
    )
  ),
  Card(
    name: "Duel", energyCost: 2,
    class: some(Warrior), kind: Spell,
    rules: rules(
      addPowerToughness(1, 1, target({Minion}, vfx = SwordAndShieldVfx)),
      lose(ranged(), target({Minion}, vfx = MeleeVfx)),
      fight(getTarget(0), getTarget(1), vfx = SwordClashVfx)
    )
  ),
  Card(
    name: "Tactician", energyCost: 2,
    class: some(Warrior), kind: Minion,
    rules: rules(
      removePowerToughness(1, 0, target({Minion}, vfx = SwordBreakVfx)),
    ),
    power: 1, toughness: 2
  ),
  Card(
    name: "Footsoldier", energyCost: 1,
    class: some(Warrior), kind: Minion,
    rules: rules(),
    power: 1, toughness: 2
  ),
  Card(
    name: "Commander", energyCost: 5,
    class: some(Warrior), kind: Minion,
    rules: rules(summon(2, "Footsoldier")),
    power: 2, toughness: 3
  ),
  Card(
    name: "Rally", energyCost: 5,
    class: some(Warrior), kind: Spell,
    rules: rules(
      summon(2, "Footsoldier"),
      addPowerToughness(
        1, 0,
        game.board.choose(kind: Minion, owner: You),
        vfx = SwordsIntoTheWindVfx
      )
    )
  )
]

let mage = [
  Card(
    name: "Bouncer", energyCost: 1,
    class: some(Mage), kind: Minion,
    rules: rules(bounce(target({Minion}, vfx = BubbleVfx))),
    power: 1, toughness: 1
  ),
  Card(
    name: "Ooze", energyCost: 1,
    class: some(Mage), kind: Minion,
    rules: rules(),
    power: 1, toughness: 1
  ),
  Card(
    name: "Oozification", energyCost: 4,
    class: some(Mage), kind: Spell,
    rules: rules(
      destroy(target({Minion}, vfx = OozeSplatVfx)),
      summon(getTarget().toughness, "Ooze")
    )
  )
]

let baseCards* = archer & warrior & mage

## The card lists are never mutated after module init, so the lookups below
## cast to gcsafe: async server handlers deal decks and encode snapshots.

proc classCard*(heroClass: HeroClass): Card =
  {.cast(gcsafe).}:
    case heroClass
    of Archer: archer[0]
    of Warrior: warrior[0]
    of Mage: mage[0]

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
  for name in card.summonedNames():
    discard baseCardNamed(name)

proc archerDeck(): seq[Card] =
  {.cast(gcsafe).}:
    for (card, count) in [
        (archer[0], 10), (archer[1], 14), (archer[2], 10), (archer[3], 6)]:
      for _ in 0 ..< count:
        result.add card

proc warriorDeck(): seq[Card] =
  {.cast(gcsafe).}:
    for (card, count) in [
        (warrior[0], 8), (warrior[1], 5), (warrior[2], 4), (warrior[3], 5),
        (warrior[4], 5), (warrior[5], 6), (warrior[6], 4), (warrior[7], 3)]:
      for _ in 0 ..< count:
        result.add card

proc mageDeck(): seq[Card] =
  ## Ooze isn't dealt: only Oozification summons it.
  {.cast(gcsafe).}:
    for (card, count) in [(mage[0], 32), (mage[2], 8)]:
      for _ in 0 ..< count:
        result.add card

proc baseDeck*(heroClass: HeroClass): seq[Card] =
  case heroClass
  of Archer:
    result = archerDeck()
  of Warrior:
    result = warriorDeck()
  of Mage:
    result = mageDeck()
  doAssert result.len == DeckSize
