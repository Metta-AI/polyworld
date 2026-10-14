## AWM base set: the cards and the class decks built from them.
## Lookups over this set live in core/cardset.nim.

import
  std/options,
  core/core

let classCards = [
  Card(
    name: "Archer", energyCost: 0,
    class: none(HeroClass), kind: Trinket,
    rules: rules(levelUp(1, Archer))
  ),
  Card(
    name: "Warrior", energyCost: 0,
    class: none(HeroClass), kind: Trinket,
    rules: rules(levelUp(1, Warrior))
  ),
  Card(
    name: "Mage", energyCost: 0,
    class: none(HeroClass), kind: Trinket,
    rules: rules(levelUp(1, Mage))
  )
]

let archer = [
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
      damage(1, target({kind: {Minion, Hero}}), vfx = ArrowVfx)
    ),
    power: 3, toughness: 1
  ),
  Card(
    name: "Ambusher", energyCost: 3,
    class: some(Archer), kind: Minion,
    rules: rules(hidden(1)),
    power: 2, toughness: 2
  ),
  Card(
    name: "Assassin", energyCost: 6,
    class: some(Archer), kind: Minion,
    rules: rules(
      hidden(1),
      damage(2, target({kind: {Minion}}), vfx = StabVfx)
    ),
    power: 5, toughness: 1
  ),
  Card(
    name: "Bolt", energyCost: 1,
    class: some(Archer), kind: Spell,
    rules: rules(damage(2, target({kind: {Hero}}), vfx = LightningVfx))
  ),
  Card(
    name: "Reload", energyCost: 2,
    class: some(Archer), kind: Spell,
    rules: rules(repeat(target({kind: {Minion, Trinket}}).printedRules))
  ),
  Card(
    name: "Overcharge", energyCost: 3,
    class: some(Archer), kind: Spell,
    rules: rules(choose(
      rules(
        damage(1, target({kind: {Minion}}), vfx = LightningVfx),
        damage(1, getTarget().owner, vfx = LightningVfx)
      ),
      rules(
        damage(3, target({kind: {Minion}}), vfx = LightningVfx),
        damage(3, getTarget().owner, vfx = LightningVfx),
        damage(3, You, vfx = LightningVfx)
      )
    ))
  ),
  Card(
    name: "Explode", energyCost: 3,
    class: some(Archer), kind: Spell,
    rules: rules(
      destroy(target({kind: {Minion}, owner: You}), vfx = ExplosionVfx),
      damage(getTarget().power, target({kind: {Minion, Hero}}), vfx = ExplosionVfx)
    )
  ),
  Card(
    name: "Hail of Arrows", energyCost: 3,
    class: some(Archer), kind: Spell,
    rules: rules(
      damage(1, game.board.getCards({kind: {Minion}, owner: AllOpponents}), vfx = ManyArrowsVfx)
    )
  ),
  Card(
    name: "Wildfire", energyCost: 6,
    class: some(Archer), kind: Trinket,
    rules: rules(
      on(eachTurn(You),
        damage(1, game.board.getCards({kind: {Minion}}), vfx = ExplosionVfx),
        damage(1, game.players, vfx = ExplosionVfx)
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
        game.board.getCards({kind: {Minion}, owner: You}),
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
        game.board.getCards({kind: {Minion}, owner: You}),
        vfx = MightyShieldsVfx
      )
    )
  ),
  Card(
    name: "Duel", energyCost: 2,
    class: some(Warrior), kind: Spell,
    rules: rules(
      addPowerToughness(1, 1, target({kind: {Minion}}), vfx = SwordAndShieldVfx),
      lose(ranged(), target({kind: {Minion}}), vfx = MeleeVfx),
      fight(getTarget(0), getTarget(1), vfx = SwordClashVfx)
    )
  ),
  Card(
    name: "Tactician", energyCost: 2,
    class: some(Warrior), kind: Minion,
    rules: rules(
      removePowerToughness(1, 0, target({kind: {Minion}}), vfx = SwordBreakVfx),
    ),
    power: 1, toughness: 2
  ),
  Card(
    name: "Banner", energyCost: 3,
    class: some(Warrior), kind: Trinket,
    rules: rules(
      on(eachTurn(You), summon(1, "Footsoldier"))
    )
  ),
  Card(
    name: "Pillage", energyCost: 4,
    class: some(Warrior), kind: Spell,
    rules: rules(
      destroy(target({kind: {Trinket}}), vfx = ExplosionVfx),
      choose(
        rules(addPowerToughness(1, 0,
          game.board.getCards({kind: {Minion}, owner: You}),
          vfx = SwordsIntoTheWindVfx)),
        rules(addPowerToughness(0, 1,
          game.board.getCards({kind: {Minion}, owner: You}),
          vfx = MightyShieldsVfx))
      )
    )
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
        game.board.getCards({kind: {Minion}, owner: You}),
        vfx = SwordsIntoTheWindVfx
      )
    )
  )
]

let mage = [
  Card(
    name: "Ooze", energyCost: 0,
    class: some(Mage), kind: Minion,
    rules: rules(),
    power: 0, toughness: 1
  ),
  Card(
    name: "Bouncer", energyCost: 1,
    class: some(Mage), kind: Minion,
    rules: rules(bounce(target({kind: {Minion}}), vfx = BubbleVfx)),
    power: 1, toughness: 1
  ),
  Card(
    name: "Spirit", energyCost: 3,
    class: some(Mage), kind: Minion,
    rules: rules(hidden(), ranged()),
    power: 1, toughness: 3
  ),
  Card(
    name: "Plan", energyCost: 3,
    class: some(Mage), kind: Trinket,
    rules: rules(
      draw(1),
      on(nextTurn(You),
        draw(1),
        destroy(self())
      )
    )
  ),
  Card(
    name: "Study", energyCost: 2,
    class: some(Mage), kind: Spell,
    rules: rules(draw(2), toss(1))
  ),
  Card(
    name: "Summon Primordial", energyCost: 8,
    class: some(Mage), kind: Spell,
    rules: rules(
      bounce(game.board.getCards({owner: target({kind: {Hero}})}), vfx = BubbleVfx),
      summon(1, "Primordial")
    )
  ),
  Card(
    name: "Primordial", energyCost: 8,
    class: some(Mage), kind: Minion,
    rules: rules(),
    power: 10, toughness: 10
  ),
  Card(
    name: "Bubble", energyCost: 0,
    class: some(Mage), kind: Trinket,
    rules: rules(
      on(attacked(You),
        bounce(getAttacker(), vfx = BubbleVfx),
        destroy(self())
      )
    )
  ),
  Card(
    name: "Bubble Shield", energyCost: 2,
    class: some(Mage), kind: Spell,
    rules: rules(summon(2, "Bubble"))
  ),
  Card(
    name: "Morphosis Chamber", energyCost: 3,
    class: some(Mage), kind: Trinket,
    rules: rules(
      on(eachTurn(You),
        choose(
          gain(ranged(), target({kind: {Minion}, owner: You}), vfx = OozeSplatVfx),
          gain(hidden(1), target({kind: {Minion}}), vfx = OozeSplatVfx),
          addPowerToughness(1, -1, target({kind: {Minion}, owner: You}), vfx = OozeSplatVfx),
          addPowerToughness(-1, 1, target({kind: {Minion}, owner: You}), vfx = OozeSplatVfx)
        )
      )
    )
  ),
  Card(
    name: "Overwork", energyCost: 4,
    class: some(Mage), kind: Trinket,
    rules: rules(
      on(eachTurn(You),
        draw(1),
        bounce(target({kind: {Minion}}), vfx = BubbleVfx),
        damage(3, You, vfx = ExplosionVfx)
      )
    )
  ),
  Card(
    name: "Control", energyCost: 5,
    class: some(Mage), kind: Spell,
    rules: rules(
      steal(target({kind: {Minion}, owner: AllOpponents}), vfx = BubbleVfx)
    )
  ),
  Card(
    name: "Oozification", energyCost: 4,
    class: some(Mage), kind: Spell,
    rules: rules(
      destroy(target({kind: {Minion}}), vfx = OozeSplatVfx),
      summon(getTarget().toughness, "Ooze", getTarget().owner)
    )
  )
]

let baseCards* = classCards & archer & warrior & mage

const
  DeckSize* = 40

  baseDeckLists*: array[HeroClass, seq[(string, int)]] = [
    Archer: @[("Bolt", 4), ("Sniper", 4), ("Sharpshooter", 4),
      ("Hail of Arrows", 4), ("Overcharge", 4), ("Explode", 4),
      ("Ambusher", 4), ("Assassin", 4), ("Reload", 4), ("Wildfire", 4)],
    Warrior: @[("Bear", 4), ("Swords", 4), ("Shields", 4), ("Duel", 4),
      ("Tactician", 4), ("Footsoldier", 4), ("Commander", 4), ("Rally", 4),
      ("Banner", 4), ("Pillage", 4)],
    # Ooze, Primordial and Bubble aren't dealt: only other cards summon them.
    Mage: @[("Bouncer", 4), ("Spirit", 4), ("Plan", 4), ("Study", 4),
      ("Summon Primordial", 4), ("Bubble Shield", 4), ("Oozification", 4),
      ("Morphosis Chamber", 4), ("Overwork", 4), ("Control", 4)]
  ]
