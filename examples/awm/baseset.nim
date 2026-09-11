## AWM base set: one coded card for each class.

import
  std/options,
  awmcore

const
  DeckSize* = 30

let baseCards = [
  Card(
    name: "Bolt", energyCost: 1,
    class: some(Archer), kind: Spell,
    rules: proc(card: Card): Rules =
      damage(2, targetHero(vfx = LightningVfx))
  ),
  Card(
    name: "Bear", energyCost: 2,
    class: some(Warrior), kind: Minion,
    rules: nil,
    power: 3,
    toughness: 2
  ),
  Card(
    name: "Bouncer", energyCost: 1,
    class: some(Mage), kind: Minion,
    rules: proc(card: Card): Rules =
      bounce(targetCreature(vfx = BubbleVfx)),
    power: 1,
    toughness: 1
  ),
  #Card(
  #  name: "Frontline", energyCost: 2,
  #)
]

proc classCard*(heroClass: HeroClass): Card =
  case heroClass
  of Archer: baseCards[0]
  of Warrior: baseCards[1]
  of Mage: baseCards[2]

proc baseDeck*(heroClass: HeroClass): seq[Card] =
  result = newSeqOfCap[Card](DeckSize)
  let card = heroClass.classCard()
  for _ in 0 ..< DeckSize:
    result.add card
