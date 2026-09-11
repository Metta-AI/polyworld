import
  std/[options, unittest],
  ../awm

suite "AWM base set":
  test "each class receives thirty copies of its card":
    for heroClass in HeroClass:
      let
        deck = heroClass.baseDeck()
        expected = heroClass.classCard()
      check deck.len == DeckSize
      for card in deck:
        check card == expected

  test "Bolt is a targeted two-damage spell":
    let bolt = Archer.classCard()
    check bolt.name == "Bolt"
    check bolt.energyCost == 1
    check bolt.class == some(Archer)
    check bolt.kind == Spell
    check bolt.needsChoice()
    check bolt.ruleText() == "Deal 2 damage to a hero."

  test "Bear is an unruled three-two minion":
    let bear = Warrior.classCard()
    check bear.name == "Bear"
    check bear.energyCost == 2
    check bear.class == some(Warrior)
    check bear.kind == Minion
    check bear.power == 3
    check bear.toughness == 2
    check not bear.needsChoice()
    check bear.ruleText().len == 0

  test "Bouncer is a one-one minion with a bounce rule":
    let bouncer = Mage.classCard()
    check bouncer.name == "Bouncer"
    check bouncer.energyCost == 1
    check bouncer.class == some(Mage)
    check bouncer.kind == Minion
    check bouncer.power == 1
    check bouncer.toughness == 1
    check bouncer.needsChoice()
    check bouncer.ruleText() ==
      "Return a minion to its owner's hand."

suite "AWM turns":
  test "players start at twenty life with five cards before the first turn":
    let game = newGame(Archer, Warrior, 7)
    for playerIndex in 0 ..< PlayerCount:
      let player = game.players[playerIndex]
      check player.life == StartingLife
      check player.board.len == 0
      if playerIndex == game.currentPlayer:
        check player.hand.len == StartingHandSize
        check player.deck.len == DeckSize - StartingHandSize
        check player.totalEnergy == 1
        check player.energy == 1
      else:
        check player.hand.len == StartingHandSize
        check player.deck.len == DeckSize - StartingHandSize
        check player.totalEnergy == 0
        check player.energy == 0

  test "finishing passes the turn, gains energy, replenishes, and draws":
    var game = newGame(Archer, Mage, 17)
    let
      first = game.currentPlayer
      second = (first + 1) mod PlayerCount
      secondHand = game.players[second].hand.len
    game.finishTurn()
    check game.currentPlayer == second
    check game.turnNumber == 2
    check game.players[second].totalEnergy == 1
    check game.players[second].energy == 1
    check game.players[second].hand.len == secondHand + 1

  test "energy grows on each of a player's turns and fully replenishes":
    var game = newGame(Archer, Mage, 43)
    let first = game.currentPlayer
    game.players[first].energy = 0
    game.finishTurn()
    game.finishTurn()
    check game.currentPlayer == first
    check game.players[first].totalEnergy == 2
    check game.players[first].energy == 2

suite "AWM card execution":
  test "Bolt offers both heroes and deals two damage":
    var game = newGame(Archer, Warrior, 23)
    let
      caster = game.currentPlayer
      enemy = (caster + 1) mod PlayerCount
      bolt = Archer.classCard()
    game.players[caster].hand = @[bolt]
    game.players[caster].energy = 1
    check game.availableChoices(0) == @[
      heroChoice(0),
      heroChoice(1)
    ]
    check game.playCard(0, heroChoice(enemy))
    check game.players[enemy].life == StartingLife - 2
    check game.players[caster].energy == 0
    check game.players[caster].hand.len == 0
    check game.players[caster].board.len == 0
    check game.players[caster].discardPile == @[bolt]

  test "Bolt can target its own hero":
    var game = newGame(Archer, Warrior, 27)
    let
      caster = game.currentPlayer
      bolt = Archer.classCard()
    game.players[caster].hand = @[bolt]
    game.players[caster].energy = 1
    check game.playCard(0, heroChoice(caster))
    check game.players[caster].life == StartingLife - 2
    check game.players[caster].discardPile == @[bolt]

  test "canceling or supplying an invalid target cancels the play":
    var game = newGame(Archer, Warrior, 29)
    let
      caster = game.currentPlayer
      bolt = Archer.classCard()
    game.players[caster].hand = @[bolt]
    game.players[caster].energy = 1
    check not game.playCard(0)
    check not game.playCard(0, heroChoice(PlayerCount))
    check game.players[caster].energy == 1
    check game.players[caster].hand == @[bolt]
    check game.players[caster].discardPile.len == 0

  test "Bear remains on the board as a three-two minion":
    var game = newGame(Warrior, Mage, 31)
    let
      player = game.currentPlayer
      bear = Warrior.classCard()
    game.players[player].hand = @[bear]
    game.players[player].energy = 2
    check game.playCard(0)
    check game.players[player].energy == 0
    check game.players[player].hand.len == 0
    check game.players[player].discardPile.len == 0
    check game.players[player].board.len == 1
    check game.players[player].board[0].card == bear
    check game.players[player].board[0].card.power == 3
    check game.players[player].board[0].currentToughness == 2

  test "Bouncer returns the selected minion and remains on the board":
    var game = newGame(Mage, Warrior, 37)
    let
      magePlayer = game.currentPlayer
      otherPlayer = (magePlayer + 1) mod PlayerCount
      bear = Warrior.classCard()
      bouncer = Mage.classCard()
      bearId = 77
    game.players[otherPlayer].board = @[
      MinionState(
        id: bearId,
        owner: otherPlayer,
        card: bear,
        currentToughness: bear.toughness
      )
    ]
    game.nextMinionId = 78
    game.players[magePlayer].hand = @[bouncer]
    game.players[magePlayer].energy = 1
    check game.availableChoices(0) == @[
      creatureChoice(otherPlayer, bearId),
      NoTarget
    ]
    check game.playCard(0, creatureChoice(otherPlayer, bearId))
    check game.players[otherPlayer].board.len == 0
    check game.players[otherPlayer].hand[^1] == bear
    check game.players[magePlayer].board.len == 1
    check game.players[magePlayer].board[0].card == bouncer
    check game.players[magePlayer].discardPile.len == 0

  test "Bouncer enters play before its target is chosen":
    var game = newGame(Mage, Archer, 39)
    let
      player = game.currentPlayer
      bouncer = Mage.classCard()
    game.players[player].hand = @[bouncer]
    game.players[player].energy = 1
    let bouncerId = game.playMinion(0)
    check bouncerId != 0
    check game.players[player].energy == 0
    check game.players[player].hand.len == 0
    check game.players[player].board.len == 1
    check game.availableChoices(bouncer) == @[
      creatureChoice(player, bouncerId),
      NoTarget
    ]
    check game.runMinionRules(
      bouncer,
      creatureChoice(player, bouncerId)
    )
    check game.players[player].board.len == 0
    check game.players[player].hand == @[bouncer]

  test "Bouncer can be played without a minion target":
    var game = newGame(Mage, Archer, 41)
    let
      player = game.currentPlayer
      bouncer = Mage.classCard()
    game.players[player].hand = @[bouncer]
    game.players[player].energy = 1
    check game.availableChoices(0) == @[NoTarget]
    check game.playMinion(0) != 0
    check game.runMinionRules(bouncer, NoTarget)
    check game.players[player].energy == 0
    check game.players[player].hand.len == 0
    check game.players[player].board.len == 1
    check game.players[player].board[0].card == bouncer

  test "Bouncer may decline a target even when a minion is available":
    var game = newGame(Mage, Warrior, 43)
    let
      player = game.currentPlayer
      otherPlayer = (player + 1) mod PlayerCount
      bear = Warrior.classCard()
      bouncer = Mage.classCard()
    game.players[otherPlayer].board = @[
      MinionState(
        id: 91,
        owner: otherPlayer,
        card: bear,
        currentToughness: bear.toughness
      )
    ]
    game.nextMinionId = 92
    game.players[player].hand = @[bouncer]
    game.players[player].energy = 1
    check game.playCard(0, NoTarget)
    check game.players[otherPlayer].board.len == 1
    check game.players[player].board.len == 1
    check game.players[player].board[0].card == bouncer

  test "No target cannot be used to cast a spell":
    var game = newGame(Archer, Mage, 47)
    let
      player = game.currentPlayer
      bolt = Archer.classCard()
    game.players[player].hand = @[bolt]
    game.players[player].energy = 1
    check not game.playCard(0, NoTarget)
    check game.players[player].energy == 1
    check game.players[player].hand == @[bolt]

suite "AWM target visual effects":
  test "target effects are optional and obey relation restrictions":
    check targetHero().vfx == NoVfx
    check targetCreature().vfx == NoVfx
    var context = RuleContext(sourcePlayer: 0,
      heroes: @[heroChoice(0), heroChoice(1)])
    context.selector = proc(prompt: string, choices: seq[Choice]): Choice =
      heroChoice(0)
    let target = targetHero(Enemy, vfx = LightningVfx)
    check target.choose(context).isCanceled
    check context.effects.len == 0
    context.selector = proc(prompt: string, choices: seq[Choice]): Choice =
      heroChoice(1)
    check target.choose(context) == heroChoice(1)
    check context.effects.len == 1
    check context.effects[0].kind == TargetVfxEffect
    check context.effects[0].targetVfx == LightningVfx
    check context.effects[0].visualTarget == heroChoice(1)

  test "Bolt emits lightning and damage flash on the chosen hero exactly once":
    var game = newGame(Archer, Mage, 101)
    let target = heroChoice((game.currentPlayer + 1) mod PlayerCount)
    game.players[game.currentPlayer].hand = @[Archer.classCard()]
    game.players[game.currentPlayer].energy = 1
    check game.playCard(0, target)
    let events = game.takeVisualEvents()
    check events.len == 2
    check events[0].kind == LightningVfx
    check events[1].kind == DamageFlashVfx
    for event in events: check event.target == target
    check game.takeVisualEvents().len == 0

  test "invalid, canceled, unaffordable, and no-target spells emit no VFX":
    var game = newGame(Archer, Mage, 103)
    game.players[game.currentPlayer].hand = @[Archer.classCard()]
    game.players[game.currentPlayer].energy = 1
    for choice in [Canceled, NoTarget, heroChoice(99), creatureChoice(1, 23)]:
      check not game.playCard(0, choice)
      check game.visualEvents.len == 0
    game.players[game.currentPlayer].energy = 0
    check not game.playCard(0, heroChoice(0))
    check game.visualEvents.len == 0

  test "Bouncer snapshots a removed target for its bubble":
    var game = newGame(Mage, Warrior, 107)
    let
      caster = game.currentPlayer
      owner = (caster + 1) mod PlayerCount
      target = creatureChoice(owner, 75)
    game.players[owner].board = @[
      MinionState(id: 74, owner: owner, card: Warrior.classCard(), currentToughness: 2),
      MinionState(id: 75, owner: owner, card: Warrior.classCard(), currentToughness: 2)
    ]
    game.nextMinionId = 76
    game.players[caster].hand = @[Mage.classCard()]
    game.players[caster].energy = 1
    check game.playCard(0, target)
    check not game.minionLocation(75).found
    check game.visualEvents.len == 1
    let event = game.visualEvents[0]
    check event.kind == BubbleVfx
    check event.target == target
    check event.boardIndex == 1
    check event.boardCount == 2

  test "declining Bouncer's target produces no bubble":
    var game = newGame(Mage, Archer, 109)
    game.players[game.currentPlayer].hand = @[Mage.classCard()]
    game.players[game.currentPlayer].energy = 1
    check game.playCard(0, NoTarget)
    check game.visualEvents.len == 0

  test "damage flashes without a custom VFX and keeps a lethal target snapshot":
    var game = newGame(Archer, Warrior, 113)
    let owner = (game.currentPlayer + 1) mod PlayerCount
    let strike = Card(name: "Strike", energyCost: 1, kind: Spell,
      rules: proc(card: Card): Rules = damage(2, targetCreature()))
    game.players[owner].board = @[
      MinionState(id: 88, owner: owner, card: Warrior.classCard(), currentToughness: 2)
    ]
    game.players[game.currentPlayer].hand = @[strike]
    game.players[game.currentPlayer].energy = 1
    check game.playCard(0, creatureChoice(owner, 88))
    check game.players[owner].board.len == 0
    check game.visualEvents.len == 1
    check game.visualEvents[0].kind == DamageFlashVfx
    check game.visualEvents[0].target == creatureChoice(owner, 88)
    check game.visualEvents[0].boardIndex == 0
    check game.visualEvents[0].boardCount == 1

  test "later canceled rules roll back earlier damage and visual effects":
    let combo = Card(name: "Combo", energyCost: 1, kind: Spell,
      rules: proc(card: Card): Rules = rules(
        damage(1, targetHero(vfx = LightningVfx)),
        bounce(targetCreature(vfx = BubbleVfx))))
    var context = RuleContext(sourcePlayer: 0, heroes: @[heroChoice(1)])
    context.selector = proc(prompt: string, choices: seq[Choice]): Choice =
      heroChoice(1)
    check not combo.runRules(context)
    check context.effects.len == 0

  test "zero damage produces no damage flash":
    var game = newGame(Archer, Mage, 127)
    let harmless = Card(name: "Harmless", energyCost: 0, kind: Spell,
      rules: proc(card: Card): Rules = damage(0, targetHero()))
    game.players[game.currentPlayer].hand = @[harmless]
    check game.playCard(0, heroChoice(0))
    check game.visualEvents.len == 0
