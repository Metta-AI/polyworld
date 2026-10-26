import
  std/[options, strutils, unittest],
  ../src/awm, ../src/core/explanations

proc leads(game: var GameState, heroClass: HeroClass): int =
  ## Hands the turn to the seat of that class and returns it. Card tests
  ## play a card of their own hero's class, so the off-class surcharge
  ## stays out of what they are measuring.
  for seat, player in game.players:
    if player.heroClass == heroClass:
      game.currentPlayer = seat
      break
  game.currentPlayer

suite "AWM base set":
  test "the Mage deck is four of every Mage card, without the summoned ones":
    check DeckSize == 40
    let deck = Mage.baseDeck()
    check deck.len == DeckSize
    for name in ["Bouncer", "Spirit", "Plan", "Study", "Summon Primordial",
        "Bubble Shield", "Oozification", "Morphosis Chamber", "Overwork",
        "Control"]:
      var count = 0
      for card in deck:
        if card.name == name: inc count
      check count == 4
    for card in deck:
      check card.class == some(Mage) or card.isClassCard
      # Summoned-only cards never sit in the deck.
      check card.name notin ["Bubble", "Primordial", "Ooze"]

  test "the Warrior deck is forty cards of every Warrior card":
    let deck = Warrior.baseDeck()
    check deck.len == DeckSize
    var counts: seq[int]
    for id in ["bear-2", "swords-2", "shields-1", "duel-2", "tactician-2",
        "footsoldier-1", "commander-5", "rally-5", "banner-3", "pillage-4"]:
      var count = 0
      for card in deck:
        if card == baseCard(id): inc count
      counts.add count
    for card in deck:
      check card.class == some(Warrior)
    check counts == @[4, 4, 4, 4, 4, 4, 4, 4, 4, 4]

  test "the Archer deck is forty cards of every Archer card":
    let deck = Archer.baseDeck()
    check deck.len == DeckSize
    var counts: array[11, int]
    const ids = ["bolt-1", "sniper-2", "sharpshooter-3", "hail-of-arrows-3",
      "overcharge-3", "explode-3", "ambusher-3", "assassin-6", "reload-2",
      "wildfire-6", "post-1"]
    for card in deck:
      check card.class == some(Archer)
      for index, id in ids:
        if card == baseCard(id):
          inc counts[index]
    # Eleven Archer cards leave four slots of slack: Post takes them from
    # Explode, Assassin and Reload.
    check counts == [4, 4, 4, 4, 4, 2, 4, 3, 3, 4, 4]

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
      first = game.leads(Archer)
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
    let first = game.leads(Archer)
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
      caster = game.leads(Archer)
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
      caster = game.leads(Archer)
      bolt = Archer.classCard()
    game.players[caster].hand = @[bolt]
    game.players[caster].energy = 1
    check game.playCard(0, heroChoice(caster))
    check game.players[caster].life == StartingLife - 2
    check game.players[caster].discardPile == @[bolt]

  test "canceling or supplying an invalid target cancels the play":
    var game = newGame(Archer, Warrior, 29)
    let
      caster = game.leads(Archer)
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
      player = game.leads(Warrior)
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
      magePlayer = game.leads(Mage)
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
      player = game.leads(Mage)
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
      player = game.leads(Mage)
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
      player = game.leads(Mage)
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
      player = game.leads(Archer)
      bolt = Archer.classCard()
    game.players[player].hand = @[bolt]
    game.players[player].energy = 1
    check not game.playCard(0, NoTarget)
    check game.players[player].energy == 1
    check game.players[player].hand == @[bolt]

suite "AWM target visual effects":
  test "a target obeys its relation, and the rule aiming it plays the visual":
    # The visual belongs to the rule now, so a target takes no vfx at all.
    check not compiles(target({kind: {Hero}}, vfx = LightningVfx))
    var context = RuleContext(sourcePlayer: 0,
      heroes: @[heroChoice(0), heroChoice(1)])
    context.selector = proc(prompt: string, choices: seq[Choice]): Choice =
      heroChoice(0)
    let heroTarget = target({kind: {Hero}, owner: AllOpponents})
    check heroTarget.choose(context).isCanceled
    check context.effects.len == 0
    context.selector = proc(prompt: string, choices: seq[Choice]): Choice =
      heroChoice(1)
    check heroTarget.choose(context) == heroChoice(1)
    # Choosing emits nothing by itself.
    check context.effects.len == 0
    var aimed = RuleContext(sourcePlayer: 0,
      heroes: @[heroChoice(0), heroChoice(1)])
    aimed.selector = proc(prompt: string, choices: seq[Choice]): Choice =
      heroChoice(1)
    check damage(2, target({kind: {Hero}, owner: AllOpponents}), vfx = LightningVfx).run(
      Card(kind: Spell), aimed)
    check aimed.effects[0].kind == TargetVfxEffect
    check aimed.effects[0].targetVfx == LightningVfx
    check aimed.effects[0].visualTarget == heroChoice(1)

  test "Bolt emits lightning and damage flash on the chosen hero exactly once":
    var game = newGame(Archer, Mage, 101)
    let target = heroChoice((game.leads(Archer) + 1) mod PlayerCount)
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
      caster = game.leads(Mage)
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
    check game.visualEvents.len == 2
    let event = game.visualEvents[0]
    check event.kind == BubbleVfx
    check event.target == target
    check event.boardIndex == 1
    check event.boardCount == 2
    # The bounce itself follows in the same beat, so its bubble rides along.
    let bounce = game.visualEvents[1]
    check bounce.kind == BounceVfx
    check bounce.beat == event.beat
    check bounce.target == target
    check (bounce.boardIndex, bounce.boardCount) == (1, 2)
    check bounce.card == Warrior.classCard()
    check bounce.handIndex == game.players[owner].hand.high

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
      rules: rules(damage(2, target({kind: {Minion}}))))
    game.players[owner].board = @[
      MinionState(id: 88, owner: owner, card: Warrior.classCard(), currentToughness: 2)
    ]
    game.players[game.currentPlayer].hand = @[strike]
    game.players[game.currentPlayer].energy = 1
    check game.playCard(0, creatureChoice(owner, 88))
    check game.players[owner].board.len == 0
    check game.visualEvents.len == 2
    check game.visualEvents[0].kind == DamageFlashVfx
    check game.visualEvents[1].kind == DeathVfx
    check game.visualEvents[1].card == Warrior.classCard()
    for event in game.visualEvents:
      check event.target == creatureChoice(owner, 88)
      check event.boardIndex == 0
      check event.boardCount == 1

  test "later canceled rules roll back earlier damage and visual effects":
    let combo = Card(name: "Combo", energyCost: 1, kind: Spell,
      rules: rules(
        damage(1, target({kind: {Hero}}), vfx = LightningVfx),
        bounce(target({kind: {Minion}}), vfx = BubbleVfx)))
    var context = RuleContext(sourcePlayer: 0, heroes: @[heroChoice(1)])
    context.selector = proc(prompt: string, choices: seq[Choice]): Choice =
      heroChoice(1)
    check not combo.runRules(context)
    check context.effects.len == 0

  test "zero damage produces no damage flash":
    var game = newGame(Archer, Mage, 127)
    let harmless = Card(name: "Harmless", energyCost: 0, kind: Spell,
      rules: rules(damage(0, target({kind: {Hero}}))))
    game.players[game.currentPlayer].hand = @[harmless]
    check game.playCard(0, heroChoice(0))
    check game.visualEvents.len == 0

proc readyMinion(owner, id: int, card: Card): MinionState =
  MinionState(id: id, owner: owner, card: card,
    currentToughness: card.toughness, canAttack: true)

suite "AWM combat":
  test "attack targets are the enemy hero, then enemy minions":
    var game = newGame(Warrior, Warrior, 301)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[me].board = @[readyMinion(me, 1, bear), readyMinion(me, 2, bear)]
    game.players[enemy].board = @[readyMinion(enemy, 3, bear)]
    game.nextMinionId = 4
    check game.attackTargets(1) ==
      @[heroChoice(enemy), creatureChoice(enemy, 3)]
    check game.attackTargets(3).len == 0
    game.players[me].board[1].canAttack = false
    check game.attackTargets(2).len == 0

  test "a freshly played minion cannot attack":
    var game = newGame(Warrior, Mage, 303)
    let me = game.leads(Warrior)
    game.players[me].hand = @[Warrior.classCard()]
    game.players[me].energy = 2
    let id = game.playMinion(0)
    check id != 0
    check game.attackTargets(id).len == 0
    check not game.attack(id, heroChoice(1 - me))

  test "minions deal their power to each other and both can die":
    var game = newGame(Warrior, Warrior, 307)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[me].board = @[readyMinion(me, 1, bear)]
    game.players[enemy].board = @[readyMinion(enemy, 2, bear)]
    game.nextMinionId = 3
    check game.attack(1, creatureChoice(enemy, 2))
    check game.players[me].board.len == 0
    check game.players[enemy].board.len == 0
    check game.players[me].discardPile == @[bear]
    check game.players[enemy].discardPile == @[bear]
    check game.players[enemy].life == StartingLife
    let
      events = game.takeVisualEvents()
      expected = [
        (DamageFlashVfx, creatureChoice(enemy, 2)),
        (DeathVfx, creatureChoice(enemy, 2)),
        (DamageFlashVfx, creatureChoice(me, 1)),
        (DeathVfx, creatureChoice(me, 1))]
    check events.len == expected.len
    for i, want in expected:
      check (events[i].kind, events[i].target) == want
    check events[1].card == bear
    check events[3].card == bear

  test "damage stays on a surviving minion and each minion attacks once":
    var game = newGame(Warrior, Mage, 311)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
      bear = Warrior.classCard()
      bouncer = Mage.classCard()
    game.players[me].board = @[readyMinion(me, 1, bear)]
    game.players[enemy].board =
      @[readyMinion(enemy, 2, bouncer), readyMinion(enemy, 3, bouncer)]
    game.nextMinionId = 4
    check game.attackMinion(1, 2)
    check not game.minionLocation(2).found
    check game.players[enemy].discardPile == @[bouncer]
    check game.players[me].board[0].currentToughness == 1
    check not game.attack(1, creatureChoice(enemy, 3))
    check not game.attack(1, heroChoice(enemy))
    game.finishTurn()
    game.finishTurn()
    check game.players[me].board[0].currentToughness == 1
    check game.attack(1, creatureChoice(enemy, 3))
    check not game.minionLocation(1).found
    check not game.minionLocation(3).found

  test "attacking the enemy hero damages it; illegal targets are rejected":
    var game = newGame(Warrior, Warrior, 313)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[me].board = @[readyMinion(me, 1, bear), readyMinion(me, 2, bear)]
    game.players[enemy].board = @[readyMinion(enemy, 3, bear)]
    game.nextMinionId = 4
    for illegal in [heroChoice(me), creatureChoice(me, 2),
        creatureChoice(enemy, 99), NoTarget, Canceled]:
      check not game.attack(1, illegal)
    check not game.attackMinion(1, 2)
    check not game.attackMinion(3, 1)
    check game.players[me].board[0].currentToughness == bear.toughness
    check game.attack(1, heroChoice(enemy))
    check game.players[enemy].life == StartingLife - bear.power
    check game.players[enemy].board[0].currentToughness == bear.toughness

proc baseCard(name: string, energyCost: int): Card =
  for card in baseCards:
    if card.name == name and card.energyCost == energyCost:
      return card
  doAssert false, "missing base card " & name

suite "AWM target kinds":
  test "kinds and relations read as rules text":
    check target({kind: {Hero}}).text() == "a hero"
    check target({kind: {Hero}, owner: AllOpponents}).text() == "an enemy hero"
    check target({kind: {Minion}}).text() == "a minion"
    check target({kind: {Minion}, owner: You}).text() == "a friendly minion"
    check target({kind: {Minion, Hero}}).text() == "any target"
    check target({kind: {Minion, Hero}, owner: AllOpponents}).text() == "an enemy target"
    check target({kind: {Minion, Hero}, owner: You}).text() == "a friendly target"

  test "a minion-or-hero target offers heroes, then minions":
    let context = RuleContext(sourcePlayer: 0,
      heroes: @[heroChoice(0), heroChoice(1)],
      creatures: @[creatureChoice(0, 5), creatureChoice(1, 6)])
    check target({kind: {Minion, Hero}}).candidates(context) == @[
      heroChoice(0), heroChoice(1), creatureChoice(0, 5), creatureChoice(1, 6)]
    check target({kind: {Minion, Hero}, owner: AllOpponents}).candidates(context) ==
      @[heroChoice(1), creatureChoice(1, 6)]
    check target({kind: {Hero}, owner: You}).candidates(context) == @[heroChoice(0)]
    check target({kind: {Minion}, owner: You}).candidates(context) ==
      @[creatureChoice(0, 5)]

suite "AWM Sharpshooter":
  test "Sniper and Sharpshooter carry their printed data":
    let
      small = baseCard("Sniper", 2)
      large = baseCard("Sharpshooter", 3)
    check small.class == some(Archer)
    check small.kind == Minion
    check small.power == 2
    check small.toughness == 1
    check not small.needsChoice()
    check small.keywords() == {Ranged}
    check small.ruleText() == "Ranged"
    check large.class == some(Archer)
    check large.kind == Minion
    check large.power == 3
    check large.toughness == 1
    check large.needsChoice()
    check large.keywords() == {Ranged}
    check large.ruleText() == "Ranged\nDeal 1 damage to any target."
    check Warrior.classCard().keywords() == {}

  test "Sharpshooter may target either hero, any minion, or nothing":
    var game = newGame(Archer, Warrior, 211)
    let
      caster = game.leads(Archer)
      enemy = (caster + 1) mod PlayerCount
      bear = Warrior.classCard()
    game.players[enemy].board = @[
      MinionState(id: 50, owner: enemy, card: bear,
        currentToughness: bear.toughness)
    ]
    game.nextMinionId = 51
    game.players[caster].hand = @[baseCard("Sharpshooter", 3)]
    game.players[caster].energy = 3
    check game.availableChoices(0) == @[
      heroChoice(0), heroChoice(1), creatureChoice(enemy, 50), NoTarget]

  test "Sharpshooter shoots the enemy hero with an arrow":
    var game = newGame(Archer, Warrior, 223)
    let
      caster = game.leads(Archer)
      enemy = (caster + 1) mod PlayerCount
      sharpshooter = baseCard("Sharpshooter", 3)
    game.players[caster].hand = @[sharpshooter]
    game.players[caster].energy = 3
    check game.playCard(0, heroChoice(enemy))
    check game.players[enemy].life == StartingLife - 1
    check game.players[caster].energy == 0
    check game.players[caster].board.len == 1
    check game.players[caster].board[0].card == sharpshooter
    let events = game.takeVisualEvents()
    check events.len == 2
    check events[0].kind == ArrowVfx
    check events[1].kind == DamageFlashVfx
    for event in events: check event.target == heroChoice(enemy)

  test "Sharpshooter damages and destroys minions":
    var game = newGame(Archer, Mage, 227)
    let
      caster = game.leads(Archer)
      enemy = (caster + 1) mod PlayerCount
      bear = Warrior.classCard()
      bouncer = Mage.classCard()
      sharpshooter = baseCard("Sharpshooter", 3)
    game.players[enemy].board = @[
      MinionState(id: 60, owner: enemy, card: bear,
        currentToughness: bear.toughness),
      MinionState(id: 61, owner: enemy, card: bouncer,
        currentToughness: bouncer.toughness)
    ]
    game.nextMinionId = 62
    game.players[caster].hand = @[sharpshooter, sharpshooter]
    game.players[caster].energy = 6
    check game.playCard(0, creatureChoice(enemy, 60))
    check game.players[enemy].board[0].currentToughness == 1
    check game.playCard(0, creatureChoice(enemy, 61))
    check not game.minionLocation(61).found
    check game.players[enemy].discardPile == @[bouncer]
    check game.players[enemy].life == StartingLife
    check game.players[caster].board.len == 2

  test "Sharpshooter can enter play without shooting":
    var game = newGame(Archer, Warrior, 229)
    let caster = game.leads(Archer)
    game.players[caster].hand = @[baseCard("Sharpshooter", 3)]
    game.players[caster].energy = 3
    check game.playCard(0, NoTarget)
    check game.players[caster].board.len == 1
    for playerIndex in 0 ..< PlayerCount:
      check game.players[playerIndex].life == StartingLife
    check game.visualEvents.len == 0

suite "AWM ranged":
  test "a ranged attacker takes no damage from a non-ranged defender":
    var game = newGame(Archer, Warrior, 401)
    let
      me = game.leads(Archer)
      enemy = 1 - me
      sniper = baseCard("Sniper", 2)
      bear = Warrior.classCard()
    game.players[me].board = @[readyMinion(me, 1, sniper)]
    game.players[enemy].board = @[readyMinion(enemy, 2, bear)]
    game.nextMinionId = 3
    check game.attack(1, creatureChoice(enemy, 2))
    check not game.minionLocation(2).found
    check game.players[me].board[0].currentToughness == sniper.toughness
    var flashes: seq[Choice]
    for event in game.takeVisualEvents():
      if event.kind == DamageFlashVfx: flashes.add event.target
    check flashes == @[creatureChoice(enemy, 2)]

  test "a non-ranged attacker deals no damage to a ranged defender":
    var game = newGame(Warrior, Archer, 409)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
      sniper = baseCard("Sniper", 2)
      bear = Warrior.classCard()
    game.players[me].board = @[readyMinion(me, 1, bear)]
    game.players[enemy].board = @[readyMinion(enemy, 2, sniper)]
    game.nextMinionId = 3
    check game.attack(1, creatureChoice(enemy, 2))
    check not game.minionLocation(1).found
    check game.players[me].discardPile == @[bear]
    check game.players[enemy].board[0].currentToughness == sniper.toughness
    var flashes: seq[Choice]
    for event in game.takeVisualEvents():
      if event.kind == DamageFlashVfx: flashes.add event.target
    check flashes == @[creatureChoice(me, 1)]

  test "ranged minions fight each other normally":
    var game = newGame(Archer, Archer, 419)
    let
      me = game.leads(Archer)
      enemy = 1 - me
      sniper = baseCard("Sniper", 2)
      sharpshooter = baseCard("Sharpshooter", 3)
    game.players[me].board = @[readyMinion(me, 1, sniper)]
    game.players[enemy].board = @[readyMinion(enemy, 2, sharpshooter)]
    game.nextMinionId = 3
    check game.attack(1, creatureChoice(enemy, 2))
    check game.players[me].board.len == 0
    check game.players[enemy].board.len == 0

  test "on-play damage still hits ranged minions":
    var game = newGame(Archer, Archer, 421)
    let
      caster = game.leads(Archer)
      enemy = 1 - caster
      sniper = baseCard("Sniper", 2)
    game.players[enemy].board = @[readyMinion(enemy, 70, sniper)]
    game.nextMinionId = 71
    game.players[caster].hand = @[baseCard("Sharpshooter", 3)]
    game.players[caster].energy = 3
    check game.playCard(0, creatureChoice(enemy, 70))
    check not game.minionLocation(70).found
    check game.players[enemy].discardPile == @[sniper]

suite "AWM card identity":
  test "copies share rules; look-alikes with their own rules differ":
    let
      sniper = baseCard("Sniper", 2)
      copy = sniper
      lookalike = Card(name: "Sniper", energyCost: 2, class: some(Archer),
        kind: Minion, rules: rules(ranged()), power: 2, toughness: 1)
    check copy == sniper
    check lookalike.ruleText() == sniper.ruleText()
    check lookalike != sniper

suite "AWM Hail of Arrows":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  test "Hail of Arrows prints its query and needs no target":
    let hail = baseCard("Hail of Arrows", 3)
    check hail.class == some(Archer)
    check hail.kind == Spell
    check not hail.needsChoice()
    check hail.ruleText() == "Deal 1 damage to all enemy minions."

  test "zone queries read as rules text":
    check printed(rules(damage(1, game.board.getCards({kind: {Minion}})))) ==
      "Deal 1 damage to all minions."
    check printed(rules(damage(2,
      game.board.getCards({kind: {Minion}, owner: You})))) ==
      "Deal 2 damage to all friendly minions."
    check printed(rules(damage(1, game.board.getCards({})))) ==
      "Deal 1 damage to all cards."
    check not compiles(rules(damage(1, game.board.getCards({color: Minion}))))

  test "Hail of Arrows hits every enemy minion and nothing else":
    var game = newGame(Archer, Warrior, 431)
    let
      caster = game.leads(Archer)
      enemy = 1 - caster
      hail = baseCard("Hail of Arrows", 3)
      bear = Warrior.classCard()
      sniper = baseCard("Sniper", 2)
    game.players[caster].board = @[readyMinion(caster, 1, bear)]
    game.players[enemy].board =
      @[readyMinion(enemy, 2, sniper), readyMinion(enemy, 3, bear)]
    game.nextMinionId = 4
    game.players[caster].hand = @[hail]
    game.players[caster].energy = 3
    check game.availableChoices(0).len == 0
    check game.playCard(0)
    check game.players[caster].energy == 0
    check game.players[caster].discardPile == @[hail]
    # Spells hit ranged minions: only combat damage respects Ranged.
    check not game.minionLocation(2).found
    check game.players[enemy].discardPile == @[sniper]
    check game.players[enemy].board[0].currentToughness == bear.toughness - 1
    check game.players[caster].board[0].currentToughness == bear.toughness
    check game.players[enemy].life == StartingLife
    check game.players[caster].life == StartingLife
    let events = game.takeVisualEvents()
    check events.len >= 2
    # The volley lands on every target before any of them is removed.
    check events[0].kind == ManyArrowsVfx
    check events[0].target == creatureChoice(enemy, 2)
    check events[1].kind == ManyArrowsVfx
    check events[1].target == creatureChoice(enemy, 3)
    check (events[1].boardIndex, events[1].boardCount) == (1, 2)

  test "Hail of Arrows into an empty enemy board still resolves":
    var game = newGame(Archer, Warrior, 433)
    let
      caster = game.leads(Archer)
      bear = Warrior.classCard()
      hail = baseCard("Hail of Arrows", 3)
    game.players[caster].board = @[readyMinion(caster, 1, bear)]
    game.nextMinionId = 2
    game.players[caster].hand = @[hail]
    game.players[caster].energy = 3
    check game.playCard(0)
    check game.players[caster].energy == 0
    check game.players[caster].discardPile == @[hail]
    check game.players[caster].board[0].currentToughness == bear.toughness
    check game.visualEvents.len == 0

  test "several minions on one board can die together":
    var game = newGame(Archer, Archer, 437)
    let
      caster = game.leads(Archer)
      enemy = 1 - caster
      sniper = baseCard("Sniper", 2)
    game.players[enemy].board =
      @[readyMinion(enemy, 2, sniper), readyMinion(enemy, 3, sniper)]
    game.nextMinionId = 4
    game.players[caster].hand = @[baseCard("Hail of Arrows", 3)]
    game.players[caster].energy = 3
    check game.playCard(0)
    check game.players[enemy].board.len == 0
    check game.players[enemy].discardPile == @[sniper, sniper]
    var deaths: seq[Choice]
    for event in game.takeVisualEvents():
      if event.kind == DeathVfx: deaths.add event.target
    check deaths == @[creatureChoice(enemy, 2), creatureChoice(enemy, 3)]

suite "AWM Swords":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  proc swordsGame(seed: int64): (GameState, int, int) =
    ## The caster has two Bears and one Swords with energy to spare; the
    ## enemy has one Bear.
    var game = newGame(Warrior, Warrior, seed)
    let
      caster = game.leads(Warrior)
      enemy = 1 - caster
      bear = Warrior.classCard()
    game.players[caster].board =
      @[readyMinion(caster, 1, bear), readyMinion(caster, 2, bear)]
    game.players[enemy].board = @[readyMinion(enemy, 3, bear)]
    game.nextMinionId = 4
    game.players[caster].hand = @[baseCard("Swords", 2)]
    game.players[caster].energy = 5
    (game, caster, enemy)

  test "Swords is a no-target Warrior spell that gives +1/+0":
    let swords = baseCard("Swords", 2)
    check swords.class == some(Warrior)
    check swords.kind == Spell
    check not swords.needsChoice()
    check swords.ruleText() == "Give all friendly minions +1/+0."

  test "stat changes read as rules text":
    check printed(rules(addPowerToughness(0, 2,
      game.board.getCards({kind: {Minion}})))) == "Give all minions +0/+2."
    check printed(rules(addPowerToughness(-1, 0,
      game.board.getCards({kind: {Minion}, owner: AllOpponents})))) ==
      "Give all enemy minions -1/+0."

  test "Swords buffs every friendly minion and nothing else":
    var (game, caster, enemy) = swordsGame(503)
    let swords = baseCard("Swords", 2)
    check game.availableChoices(0).len == 0
    check game.playCard(0)
    check game.players[caster].energy == 3
    check game.players[caster].discardPile == @[swords]
    for minion in game.players[caster].board:
      check minion.power == 4
      check minion.currentToughness == 2
      # Buffs never touch the printed card, so it still serializes.
      check minion.card == Warrior.classCard()
    check game.players[enemy].board[0].power == 3
    check game.choiceLabel(creatureChoice(caster, 1)).endsWith("(4/2)")
    let events = game.takeVisualEvents()
    check events.len == 2
    check events[0].kind == SwordsIntoTheWindVfx
    check events[0].target == creatureChoice(caster, 1)
    check events[1].kind == SwordsIntoTheWindVfx
    check events[1].target == creatureChoice(caster, 2)

  test "Swords stacks and lasts across turns":
    var (game, caster, _) = swordsGame(509)
    game.players[caster].hand.add baseCard("Swords", 2)
    game.players[caster].energy = 4
    check game.playCard(0)
    check game.playCard(0)
    check game.players[caster].board[0].power == 5
    game.finishTurn()
    game.finishTurn()
    check game.players[caster].board[0].power == 5

  test "a buffed minion hits harder in combat and against heroes":
    var (game, caster, enemy) = swordsGame(521)
    check game.playCard(0)
    check game.attack(1, heroChoice(enemy))
    check game.players[enemy].life == StartingLife - 4
    # 4 damage kills the enemy Bear; it hits back for its own 3.
    check game.attack(2, creatureChoice(enemy, 3))
    check not game.minionLocation(3).found
    check not game.minionLocation(2).found

  test "a slain minion's death event carries its live power":
    var (game, caster, enemy) = swordsGame(523)
    check game.playCard(0)
    discard game.takeVisualEvents()
    game.finishTurn()
    check game.attack(3, creatureChoice(caster, 1))
    var deaths: seq[VisualEvent]
    for event in game.takeVisualEvents():
      if event.kind == DeathVfx: deaths.add event
    check deaths.len == 2
    for death in deaths:
      check death.power == (if death.target.owner == caster: 4 else: 3)
    check enemy == game.currentPlayer

  test "a bounced minion loses its buffs":
    var (game, caster, _) = swordsGame(541)
    check game.playCard(0)
    game.players[caster].hand = @[Mage.classCard()]
    # A Warrior reaching for a Mage card pays the off-class surcharge.
    game.players[caster].energy = game.playCost(caster, Mage.classCard())
    check game.playCard(0, creatureChoice(caster, 1))
    check game.players[caster].hand == @[Warrior.classCard()]
    game.players[caster].energy = 2
    check game.playCard(0)
    let replayed = game.players[caster].board[^1]
    check replayed.card == Warrior.classCard()
    check replayed.power == 3

  test "Swords with no friendly minions still resolves":
    var game = newGame(Warrior, Warrior, 547)
    let caster = game.leads(Warrior)
    game.players[caster].hand = @[baseCard("Swords", 2)]
    game.players[caster].energy = 2
    check game.playCard(0)
    check game.players[caster].energy == 0
    check game.visualEvents.len == 0

  test "lowered toughness kills and power never drops below zero":
    var game = newGame(Warrior, Warrior, 557)
    let
      caster = game.leads(Warrior)
      enemy = 1 - caster
      bear = Warrior.classCard()
      wither = Card(name: "Wither", energyCost: 0, kind: Spell,
        rules: rules(addPowerToughness(-5, -2,
          game.board.getCards({kind: {Minion}, owner: AllOpponents}))))
    game.players[enemy].board = @[readyMinion(enemy, 1, bear)]
    game.nextMinionId = 2
    var sturdy = readyMinion(enemy, 2, bear)
    sturdy.currentToughness = 5
    game.players[enemy].board.add sturdy
    game.nextMinionId = 3
    game.players[caster].hand = @[wither]
    check game.playCard(0)
    check not game.minionLocation(1).found
    check game.players[enemy].discardPile == @[bear]
    check game.players[enemy].board[0].power == 0
    check game.players[enemy].board[0].currentToughness == 3

suite "AWM Duel and Shields":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  proc duelGame(seed: int64, mine, theirs: Card): (GameState, int, int) =
    ## Duel in hand; minion 1 on our side, minion 2 on theirs.
    var game = newGame(Warrior, Archer, seed)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
    game.players[me].board = @[readyMinion(me, 1, mine)]
    game.players[enemy].board = @[readyMinion(enemy, 2, theirs)]
    game.nextMinionId = 3
    game.players[me].hand = @[baseCard("Duel", 2)]
    game.players[me].energy = 2
    (game, me, enemy)

  test "Duel and Shields print their rules":
    let duel = baseCard("Duel", 2)
    check duel.class == some(Warrior)
    check duel.kind == Spell
    check duel.needsChoice()
    check duel.targetCount() == 2
    check duel.helpsTarget(0)
    check not duel.helpsTarget(1)
    check duel.ruleText() == "Give a minion +1/+1.\n" &
      "A minion loses Ranged.\nThe first target fights the second target."
    let shields = baseCard("Shields", 1)
    check shields.class == some(Warrior)
    check not shields.needsChoice()
    check shields.ruleText() == "Give all friendly minions +0/+1."
    check printed(rules(fight(getTarget(1), getTarget(0)))) ==
      "The second target fights the first target."

  test "each Duel target offers every minion":
    let (game, me, enemy) =
      duelGame(601, Warrior.classCard(), baseCard("Sniper", 2))
    for picked in [newSeq[Choice](), @[creatureChoice(me, 1)]]:
      let choices = game.availableChoices(0, picked)
      check choices.len == 2
      check creatureChoice(me, 1) in choices
      check creatureChoice(enemy, 2) in choices

  test "Duel buffs, removes Ranged, then fights":
    var (game, me, enemy) =
      duelGame(607, Warrior.classCard(), baseCard("Sniper", 2))
    check game.playCard(0, @[creatureChoice(me, 1), creatureChoice(enemy, 2)])
    check game.players[me].energy == 0
    check game.players[me].discardPile == @[baseCard("Duel", 2)]
    # The Sniper lost Ranged first, so the buffed Bear's 4 killed it.
    check not game.minionLocation(2).found
    check game.players[enemy].discardPile == @[baseCard("Sniper", 2)]
    let bear = game.players[me].board[0]
    check bear.power == 4
    check bear.currentToughness == 1
    # A fight is not an attack.
    check not bear.hasAttacked
    var kinds: seq[VfxKind]
    for event in game.takeVisualEvents():
      kinds.add event.kind
    check kinds[0 .. 2] == @[SwordAndShieldVfx, MeleeVfx, SwordClashVfx]
    check DeathVfx in kinds

  test "fights respect Ranged":
    # The buffed Sniper keeps Ranged; the Sharpshooter loses it.
    var (game, me, enemy) =
      duelGame(613, baseCard("Sniper", 2), baseCard("Sharpshooter", 3))
    check game.playCard(0, @[creatureChoice(me, 1), creatureChoice(enemy, 2)])
    check not game.minionLocation(2).found
    check game.players[me].board[0].currentToughness == 2

  test "a minion can duel itself":
    var (game, me, _) =
      duelGame(617, Warrior.classCard(), baseCard("Sniper", 2))
    check game.playCard(0, @[creatureChoice(me, 1), creatureChoice(me, 1)])
    # 4/3 after the buff, then hit once by its own 4.
    check not game.minionLocation(1).found
    check Warrior.classCard() in game.players[me].discardPile

  test "Duel with one target chosen is canceled":
    var (game, me, _) =
      duelGame(619, Warrior.classCard(), baseCard("Sniper", 2))
    check not game.playCard(0, @[creatureChoice(me, 1)])
    check not game.playCard(0, creatureChoice(me, 1))
    check game.players[me].energy == 2
    check game.players[me].hand == @[baseCard("Duel", 2)]
    check game.players[me].board[0].power == 3
    check game.visualEvents.len == 0

  test "Duel needs a minion on the board":
    var game = newGame(Warrior, Warrior, 623)
    let me = game.leads(Warrior)
    game.players[me].hand = @[baseCard("Duel", 2)]
    game.players[me].energy = 2
    check game.availableChoices(0).len == 0
    check not game.playCard(0, @[NoTarget, NoTarget])
    check game.players[me].energy == 2

  test "a lost keyword lasts and shows in the target label":
    var (game, me, enemy) =
      duelGame(629, Warrior.classCard(), baseCard("Sniper", 2))
    game.players[enemy].board[0].currentToughness = 9
    check game.playCard(0, @[creatureChoice(me, 1), creatureChoice(enemy, 2)])
    let sniper = game.players[enemy].board[0]
    check sniper.lostKeywords == {Ranged}
    check not sniper.hasKeyword(Ranged)
    check sniper.card == baseCard("Sniper", 2)
    check game.choiceLabel(creatureChoice(enemy, 2)).endsWith(
      "(2/5, lost Ranged)")
    # Its face strikes the printed Ranged out.
    check sniper.ruleLines ==
      @[RuleLine(rule: sniper.card.rules[0], change: LostRule)]

  test "Shields raises every friendly minion's toughness":
    var game = newGame(Warrior, Warrior, 631)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[me].board = @[readyMinion(me, 1, bear)]
    game.players[me].board[0].currentToughness = 1
    game.players[enemy].board = @[readyMinion(enemy, 2, bear)]
    game.nextMinionId = 3
    game.players[me].hand = @[baseCard("Shields", 1)]
    game.players[me].energy = 1
    check game.playCard(0)
    check game.players[me].board[0].currentToughness == 2
    check game.players[enemy].board[0].currentToughness == 2
    let events = game.takeVisualEvents()
    check events.len == 1
    check events[0].kind == MightyShieldsVfx

suite "AWM Tactician, Footsoldier, Commander and Rally":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  test "the new Warrior cards print their rules":
    let
      tactician = baseCard("Tactician", 2)
      footsoldier = baseCard("Footsoldier", 1)
      commander = baseCard("Commander", 5)
      rally = baseCard("Rally", 5)
    check tactician.kind == Minion
    check tactician.power == 1
    check tactician.toughness == 2
    check tactician.needsChoice()
    check not tactician.helpsTarget(0)
    check tactician.ruleText() == "Give a minion -1/-0."
    check footsoldier.kind == Minion
    check footsoldier.power == 1
    check footsoldier.toughness == 2
    check footsoldier.ruleText().len == 0
    check commander.kind == Minion
    check commander.power == 2
    check commander.toughness == 3
    check not commander.needsChoice()
    check commander.ruleText() == "Summon 2 Footsoldiers."
    check rally.kind == Spell
    check not rally.needsChoice()
    check rally.ruleText() ==
      "Summon 2 Footsoldiers.\nGive all friendly minions +1/+0."
    check printed(rules(summon(1, "Footsoldier", AllOpponents))) ==
      "Summon a Footsoldier for each opponent."
    check baseCardNamed("Footsoldier") == footsoldier
    expect ValueError:
      discard baseCardNamed("Nobody")

  test "Tactician lowers a minion's power for good":
    var game = newGame(Warrior, Warrior, 701)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[enemy].board = @[readyMinion(enemy, 1, bear)]
    game.nextMinionId = 2
    game.players[me].hand = @[baseCard("Tactician", 2)]
    game.players[me].energy = 2
    check game.availableChoices(0) == @[creatureChoice(enemy, 1), NoTarget]
    check game.playCard(0, creatureChoice(enemy, 1))
    check game.players[enemy].board[0].power == 2
    check game.players[enemy].board[0].card == bear
    check game.players[me].board.len == 1
    let events = game.takeVisualEvents()
    check events.len == 1
    check events[0].kind == SwordBreakVfx
    game.finishTurn()
    game.finishTurn()
    check game.players[enemy].board[0].power == 2

  test "Tactician can weaken nothing or a friendly minion":
    var game = newGame(Warrior, Warrior, 709)
    let me = game.leads(Warrior)
    game.players[me].hand =
      @[baseCard("Tactician", 2), baseCard("Tactician", 2)]
    game.players[me].energy = 4
    check game.playCard(0, NoTarget)
    check game.players[me].board[0].power == 1
    let first = game.players[me].board[0].id
    check game.playCard(0, creatureChoice(me, first))
    check game.players[me].board[0].power == 0
    check game.players[me].board[1].power == 1

  test "Commander enters with two Footsoldiers that can't attack yet":
    var game = newGame(Warrior, Warrior, 719)
    let me = game.leads(Warrior)
    game.players[me].board = @[readyMinion(me, 1, Warrior.classCard())]
    game.nextMinionId = 2
    game.players[me].hand = @[baseCard("Commander", 5)]
    game.players[me].energy = 5
    check game.availableChoices(0).len == 0
    check game.playCard(0)
    check game.players[me].energy == 0
    let board = game.players[me].board
    check board.len == 4
    check board[1].card == baseCard("Commander", 5)
    check board[1].id == 2
    for index in 2 .. 3:
      check board[index].card == baseCard("Footsoldier", 1)
      check board[index].id == index + 1
      check board[index].owner == me
      check board[index].currentToughness == 2
      check not board[index].canAttack
    check game.nextMinionId == 5
    check game.eligibleAttackers() == @[1]
    game.finishTurn()
    game.finishTurn()
    check game.eligibleAttackers() == @[1, 2, 3, 4]

  test "Rally summons first, so its buff reaches the Footsoldiers":
    var game = newGame(Warrior, Warrior, 727)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
      bear = Warrior.classCard()
      rally = baseCard("Rally", 5)
    game.players[me].board = @[readyMinion(me, 1, bear)]
    game.players[enemy].board = @[readyMinion(enemy, 2, bear)]
    game.nextMinionId = 3
    game.players[me].hand = @[rally]
    game.players[me].energy = 5
    check game.playCard(0)
    check game.players[me].discardPile == @[rally]
    check game.players[me].board.len == 3
    check game.players[me].board[0].power == 4
    for minion in game.players[me].board[1 .. 2]:
      check minion.card == baseCard("Footsoldier", 1)
      check minion.power == 2
    check game.players[enemy].board[0].power == 3
    check game.nextMinionId == 5
    var buffed: seq[Choice]
    for event in game.takeVisualEvents():
      if event.kind == SwordsIntoTheWindVfx:
        buffed.add event.target
    check buffed == @[creatureChoice(me, 1), creatureChoice(me, 3),
      creatureChoice(me, 4)]

  test "summons can enter under the opponent's control":
    var game = newGame(Warrior, Warrior, 733)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
    game.nextMinionId = 7
    game.players[me].hand = @[Card(name: "Gift", energyCost: 0, kind: Spell,
      rules: rules(summon(1, "Footsoldier", AllOpponents)))]
    check game.playCard(0)
    check game.players[me].board.len == 0
    check game.players[enemy].board.len == 1
    check game.players[enemy].board[0].id == 7
    check game.players[enemy].board[0].owner == enemy
    check game.nextMinionId == 8

suite "AWM Oozification":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  proc oozeGame(seed: int64, toughness: int): (GameState, int, int) =
    ## Oozification in hand; an enemy Bear (id 1) at `toughness`.
    var game = newGame(Mage, Warrior, seed)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    var bear = readyMinion(enemy, 1, Warrior.classCard())
    bear.currentToughness = toughness
    game.players[enemy].board = @[bear]
    game.nextMinionId = 2
    game.players[me].hand = @[baseCard("Oozification", 4)]
    game.players[me].energy = 4
    (game, me, enemy)

  test "Ooze and Oozification print their rules":
    let
      ooze = baseCard("Ooze", 0)
      oozification = baseCard("Oozification", 4)
    check ooze.kind == Minion
    check ooze.energyCost == 0
    check ooze.power == 0
    check ooze.toughness == 1
    check ooze.ruleText().len == 0
    check oozification.class == some(Mage)
    check oozification.kind == Spell
    check oozification.needsChoice()
    check oozification.targetCount() == 1
    check oozification.ruleText() == "Destroy a minion.\n" &
      "Summon Oozes equal to the target's toughness for the target's owner."
    check printed(rules(summon(1, "Ooze", AllOpponents))) ==
      "Summon an Ooze for each opponent."
    check printed(rules(summon(2, "Ooze", You))) == "Summon 2 Oozes."
    # With several targets, getTarget says which one.
    check printed(rules(destroy(target({kind: {Minion}})), destroy(target({kind: {Minion}})),
      summon(getTarget(1).toughness, "Ooze"))) ==
      "Destroy a minion.\nDestroy a minion.\n" &
      "Summon Oozes equal to the second target's toughness."
    check printed(rules(summon(2, "Ooze"))) == "Summon 2 Oozes."

  test "Oozification destroys a minion and summons Oozes for its toughness":
    var (game, me, enemy) = oozeGame(801, 3)
    check game.availableChoices(0) == @[creatureChoice(enemy, 1)]
    check game.playCard(0, creatureChoice(enemy, 1))
    check game.players[me].energy == 0
    check game.players[me].discardPile == @[baseCard("Oozification", 4)]
    check not game.minionLocation(1).found
    check game.players[enemy].discardPile == @[Warrior.classCard()]
    # The Oozes go to the destroyed minion's owner.
    check game.players[me].board.len == 0
    check game.players[enemy].board.len == 3
    for index, ooze in game.players[enemy].board:
      check ooze.card == baseCard("Ooze", 0)
      check ooze.owner == enemy
      check ooze.id == index + 2
      check not ooze.canAttack
    check game.nextMinionId == 5
    let events = game.takeVisualEvents()
    check events[0].kind == OozeSplatVfx
    check events[0].target == creatureChoice(enemy, 1)
    check events[1].kind == DeathVfx

  test "Oozification counts current toughness, not printed":
    var (game, me, enemy) = oozeGame(809, 1)
    check game.playCard(0, creatureChoice(enemy, 1))
    check game.players[enemy].board.len == 1
    check game.players[enemy].board[0].card == baseCard("Ooze", 0)
    check game.players[me].board.len == 0

  test "Oozification on your own minion gives you the Oozes":
    var (game, me, enemy) = oozeGame(811, 2)
    game.players[me].board = @[readyMinion(me, 2, Warrior.classCard())]
    game.nextMinionId = 3
    check game.playCard(0, creatureChoice(me, 2))
    check game.players[me].discardPile.len == 2
    check game.players[me].board.len == 2
    check game.players[me].board[0].card == baseCard("Ooze", 0)
    check game.players[enemy].board.len == 1

  test "Oozification without a target is canceled":
    var game = newGame(Mage, Warrior, 821)
    let me = game.leads(Mage)
    game.players[me].hand = @[baseCard("Oozification", 4)]
    game.players[me].energy = 4
    check game.availableChoices(0).len == 0
    check not game.playCard(0)
    check game.players[me].energy == 4
    check game.players[me].hand.len == 1
    check game.visualEvents.len == 0

  test "computed numbers print and resolve wherever a number is taken":
    let
      toll = Card(name: "Toll", energyCost: 0, kind: Spell, rules: rules(
        destroy(target({kind: {Minion}})),
        damage(getTarget().toughness, target({kind: {Hero}}))))
      grow = Card(name: "Grow", energyCost: 0, kind: Spell, rules: rules(
        addPowerToughness(getTarget().toughness, 0, target({kind: {Minion}}))))
    check toll.ruleText() == "Destroy a minion.\n" &
      "Deal the first target's toughness damage to a hero."
    check grow.ruleText() ==
      "Give a minion +X/+0, where X is the target's toughness."
    check printed(rules(removePowerToughness(getTarget().toughness, 1,
      target({kind: {Minion}})))) ==
      "Give a minion -X/-1, where X is the target's toughness."
    var (game, me, enemy) = oozeGame(823, 3)
    game.players[me].board = @[readyMinion(me, 2, Warrior.classCard())]
    game.nextMinionId = 3
    game.players[me].hand = @[toll, grow]
    # The Bear's toughness is read as it was before Toll destroyed it.
    check game.playCard(0, @[creatureChoice(enemy, 1), heroChoice(enemy)])
    check game.players[enemy].life == StartingLife - 3
    check game.players[enemy].board.len == 0
    check game.playCard(0, creatureChoice(me, 2))
    check game.players[me].board[0].power == 5

  test "getTarget can be both the number and the victim":
    let volley = Card(name: "Volley", energyCost: 0, kind: Spell, rules: rules(
      damage(1, target({kind: {Minion}})),
      damage(1, target({kind: {Minion}})),
      damage(getTarget(0).toughness, getTarget(1))))
    check volley.targetCount() == 2
    check volley.needsChoice()
    check volley.ruleText() == "Deal 1 damage to a minion.\n" &
      "Deal 1 damage to a minion.\n" &
      "Deal the first target's toughness damage to the second target."
    var game = newGame(Mage, Warrior, 827)
    let
      me = game.leads(Mage)
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[enemy].board =
      @[readyMinion(enemy, 1, bear), readyMinion(enemy, 2, bear)]
    game.nextMinionId = 3
    game.players[me].hand = @[volley]
    # The first Bear's toughness (2) is read before any damage lands.
    check game.playCard(0, @[creatureChoice(enemy, 1), creatureChoice(enemy, 2)])
    check game.players[enemy].board.len == 1
    check game.players[enemy].board[0].id == 1
    check game.players[enemy].board[0].currentToughness == 1

suite "AWM computed query owners and card names":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  test "a board query can follow a target's owner":
    let purge = Card(name: "Purge", energyCost: 0, kind: Spell, rules: rules(
      destroy(target({kind: {Minion}})),
      damage(1, game.board.getCards({kind: {Minion}, owner: getTarget().owner}))))
    check purge.ruleText() == "Destroy a minion.\n" &
      "Deal 1 damage to all minions the target's owner controls."
    check printed(rules(damage(1,
      game.board.getCards({kind: {Minion}, owner: You})))) ==
      "Deal 1 damage to all friendly minions."
    var game = newGame(Mage, Warrior, 901)
    let
      me = game.leads(Mage)
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[me].board = @[readyMinion(me, 1, bear)]
    game.players[enemy].board =
      @[readyMinion(enemy, 2, bear), readyMinion(enemy, 3, bear)]
    game.nextMinionId = 4
    game.players[me].hand = @[purge]
    check game.playCard(0, creatureChoice(enemy, 2))
    check not game.minionLocation(2).found
    check game.players[enemy].board[0].currentToughness == 1
    check game.players[me].board[0].currentToughness == 2

  test "summon names resolve on play; a misspelling fails the startup check":
    for card in baseCards:
      card.checkCardNames(baseCardNamed)
    let typo = Card(name: "Typo", energyCost: 0, kind: Spell,
      rules: rules(summon(1, "Footsodlier")))
    check typo.ruleText() == "Summon a Footsodlier."
    expect ValueError:
      typo.checkCardNames(baseCardNamed)

suite "AWM rule values":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  test "rule values are data a reader can inspect":
    let oozification = baseCard("Oozification", 4)
    let summon = SummonRule(oozification.rules[1])
    check summon.count.kind == ToughnessOf
    check summon.card.kind == CardNamed
    check summon.card.name == "Ooze"
    check summon.owner.kind == OwnerOf
    check PickedTarget(summon.owner.target).index == 0

  test "fixed numbers fold and computed ones combine":
    let folded = toRuleValue(2) + 3
    check folded.kind == FixedValue
    check folded.fixed == 5
    let grown = getTarget().toughness + 1
    check grown.kind == Sum
    check printed(rules(destroy(target({kind: {Minion}})),
      summon(getTarget().toughness + 1, "Ooze"))) ==
      "Destroy a minion.\nSummon Oozes equal to the target's toughness plus 1."
    check printed(rules(damage(1, target({kind: {Minion}})), damage(1, target({kind: {Minion}})),
      damage(getTarget(0).power - 1, getTarget(1)))) ==
      "Deal 1 damage to a minion.\nDeal 1 damage to a minion.\n" &
      "Deal the first target's power minus 1 damage to the second target."

  test "a count reads how many cards a query matches":
    let rallyCry = Card(name: "Rally Cry", energyCost: 0, kind: Spell,
      rules: rules(damage(
        game.board.getCards({kind: {Minion}, owner: You}).count, target({kind: {Hero}}))))
    check rallyCry.ruleText() ==
      "Deal the number of friendly minions damage to a hero."
    var game = newGame(Warrior, Mage, 911)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
      bear = Warrior.classCard()
    game.players[me].board =
      @[readyMinion(me, 1, bear), readyMinion(me, 2, bear)]
    game.players[enemy].board = @[readyMinion(enemy, 3, bear)]
    game.nextMinionId = 4
    game.players[me].hand = @[rallyCry]
    check game.playCard(0, heroChoice(enemy))
    check game.players[enemy].life == StartingLife - 2

  test "power and sums resolve against live stats":
    let hunt = Card(name: "Hunt", energyCost: 0, kind: Spell, rules: rules(
      addPowerToughness(2, 0, target({kind: {Minion}})),
      damage(getTarget().power + 1, target({kind: {Hero}}))))
    var game = newGame(Warrior, Mage, 919)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
    game.players[me].board = @[readyMinion(me, 1, Warrior.classCard())]
    game.nextMinionId = 2
    game.players[me].hand = @[hunt]
    # The buff hasn't applied when the damage is worked out: 3 + 1.
    check game.playCard(0, @[creatureChoice(me, 1), heroChoice(enemy)])
    check game.players[enemy].life == StartingLife - 4
    check game.players[me].board[0].power == 5

suite "AWM Plan, draws and triggers":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  proc planGame(seed: int64): (GameState, int, int) =
    ## Plan alone in hand, with energy for it.
    var game = newGame(Mage, Warrior, seed)
    let me = game.leads(Mage)
    game.players[me].hand = @[baseCard("Plan", 3)]
    game.players[me].energy = 3
    (game, me, 1 - me)

  test "Plan is a trinket that prints its trigger as one sentence":
    let plan = baseCard("Plan", 3)
    check plan.kind == Trinket
    check plan.class == some(Mage)
    check not plan.needsChoice()
    check plan.targetCount() == 0
    check plan.ruleText() == "Draw 1 card.\n" &
      "On your next turn, draw 1 card and destroy this card."
    check Mage.classCard() == baseCard("Bouncer", 1)

  test "draw and on read naturally":
    check printed(rules(draw(2))) == "Draw 2 cards."
    check printed(rules(draw(1, AllOpponents))) == "Each opponent draws 1 card."
    check printed(rules(destroy(target({kind: {Minion}})),
      draw(getTarget().toughness, getTarget().owner))) ==
      "Destroy a minion.\n" &
      "The target's owner draws cards equal to the target's toughness."
    check printed(rules(on(nextTurn(AnyOpponent),
      draw(1), draw(2), destroy(self())))) ==
      "On an opponent's next turn, " &
      "draw 1 card, draw 2 cards and destroy this card."

  test "Plan draws now, stays in play, and draws again next turn":
    var (game, me, enemy) = planGame(1001)
    let deck = game.players[me].deck.len
    check game.playCard(0)
    check game.players[me].energy == 0
    check game.players[me].hand.len == 1
    check game.players[me].deck.len == deck - 1
    check game.players[me].board.len == 1
    check game.players[me].board[0].card == baseCard("Plan", 3)
    check game.players[me].board[0].power == 0
    check game.eligibleAttackers().len == 0
    game.finishTurn()
    # The opponent's turn: Plan waits, and can't be attacked.
    check game.players[me].board.len == 1
    check game.players[me].hand.len == 1
    game.players[enemy].board = @[readyMinion(enemy, 50, Warrior.classCard())]
    game.nextMinionId = 51
    check game.attackTargets(50) == @[heroChoice(me)]
    game.finishTurn()
    # My next turn: the normal draw, then Plan's, then Plan is gone.
    check game.players[me].hand.len == 3
    check game.players[me].deck.len == deck - 3
    check game.players[me].board.len == 0
    check game.players[me].discardPile == @[baseCard("Plan", 3)]
    game.finishTurn()
    game.finishTurn()
    check game.players[me].hand.len == 4

  test "minion targets and minion effects ignore trinkets":
    var (game, me, enemy) = planGame(1003)
    check game.playCard(0)
    game.finishTurn()
    game.players[enemy].hand =
      @[Mage.classCard(), baseCard("Hail of Arrows", 3)]
    # Both are off-class for this hero, surcharge included.
    game.players[enemy].energy = 10
    check game.availableChoices(0) == @[NoTarget]
    check game.playCard(1)
    check game.players[me].board.len == 1

  test "a trinket that left play doesn't fire":
    var (game, me, _) = planGame(1005)
    check game.playCard(0)
    game.players[me].board.setLen(0)
    game.finishTurn()
    game.finishTurn()
    check game.players[me].hand.len == 2

  test "drawing from an empty deck loses the game":
    var (game, me, enemy) = planGame(1007)
    game.players[me].deck.setLen(0)
    check game.playCard(0)
    check game.gameOver
    check game.winner == enemy

  test "a trigger on the opponent's next turn fires one turn later, once":
    let omen = Card(name: "Omen", energyCost: 0, kind: Trinket,
      rules: rules(on(nextTurn(AnyOpponent), draw(1, AllOpponents))))
    var game = newGame(Mage, Warrior, 1009)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].hand = @[omen]
    check game.playCard(0)
    let enemyHand = game.players[enemy].hand.len
    game.finishTurn()
    check game.players[enemy].hand.len == enemyHand + 2
    game.finishTurn()
    game.finishTurn()
    check game.players[enemy].hand.len == enemyHand + 3
    check game.players[me].board.len == 1

  test "self() is the copy whose rules are running":
    let fleeting = Card(name: "Fleeting", energyCost: 0, kind: Minion,
      rules: rules(destroy(self())), power: 1, toughness: 1)
    check fleeting.ruleText() == "Destroy this card."
    var game = newGame(Mage, Warrior, 1011)
    let me = game.leads(Mage)
    game.players[me].board = @[readyMinion(me, 1, fleeting)]
    game.nextMinionId = 2
    game.players[me].hand = @[fleeting]
    check game.playCard(0)
    check game.players[me].board.len == 1
    check game.players[me].board[0].id == 1

  test "every draw records its hand slot, turn draws and effects alike":
    var (game, me, _) = planGame(1015)
    proc draws(game: var GameState): seq[VisualEvent] =
      for event in game.takeVisualEvents():
        if event.kind == DrawVfx:
          result.add event
    check game.playCard(0)
    let played = game.draws()
    check played.len == 1
    check played[0].target == heroChoice(me)
    check (played[0].boardIndex, played[0].boardCount) == (0, 1)
    game.finishTurn()
    discard game.takeVisualEvents()
    game.finishTurn()
    # The turn draw, then Plan's, each into its own slot.
    let nextTurn = game.draws()
    check nextTurn.len == 2
    check (nextTurn[0].boardIndex, nextTurn[1].boardIndex) == (1, 2)
    check nextTurn[1].boardCount == 3

suite "AWM triggers that choose targets":
  let snare = Card(name: "Snare", energyCost: 0, kind: Trinket,
    rules: rules(on(nextTurn(You), damage(1, target({kind: {Minion}})))))

  proc snareGame(seed: int64): (GameState, int, int) =
    ## Snare in play for `me`, an enemy Bear on the board, and the game
    ## advanced to the start of my next turn.
    var game = newGame(Mage, Warrior, seed)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].hand = @[snare]
    check game.playCard(0)
    game.players[enemy].board = @[readyMinion(enemy, 90, Warrior.classCard())]
    game.nextMinionId = 91
    game.finishTurn()
    game.finishTurn()
    (game, me, enemy)

  test "a trigger with a target waits for its owner, who sees a prompt":
    var (game, me, enemy) = snareGame(1101)
    check game.waitingTrigger
    check game.actingPlayer() == me
    check game.triggerChoices() == @[creatureChoice(enemy, 90), NoTarget]
    let waiting = game.waitingTriggerRules()
    check waiting.card.name == "Snare"
    check waiting.rules.targetPrompt(waiting.card, 0) ==
      ("Deal 1 damage to a minion.", "Choose a minion.")
    # Nothing else happens until it's answered.
    game.players[me].hand = @[Mage.classCard()]
    game.players[me].energy = 1
    check not game.canPlay(0)
    let turn = game.turnNumber
    game.finishTurn()
    check game.turnNumber == turn
    check game.resolvePendingTrigger(@[creatureChoice(enemy, 90)])
    check not game.waitingTrigger
    check game.players[enemy].board[0].currentToughness == 1
    check game.canPlay(0)

  test "an illegal pick is refused and no target is allowed":
    var (game, me, enemy) = snareGame(1103)
    check not game.resolvePendingTrigger(@[heroChoice(enemy)])
    check game.waitingTrigger
    check game.resolvePendingTrigger(@[NoTarget])
    check not game.waitingTrigger
    check game.players[enemy].board[0].currentToughness == 2
    check game.actingPlayer() == me

  test "with nothing legal to target, a trigger resolves by itself":
    var game = newGame(Mage, Warrior, 1105)
    let me = game.leads(Mage)
    game.players[me].hand = @[snare]
    check game.playCard(0)
    game.finishTurn()
    game.finishTurn()
    check not game.waitingTrigger
    check game.currentPlayer == me

  test "a trigger on the opponent's turn waits for its owner, not them":
    let trap = Card(name: "Trap", energyCost: 0, kind: Trinket,
      rules: rules(on(nextTurn(AnyOpponent), damage(1, target({kind: {Minion}})))))
    var game = newGame(Mage, Warrior, 1107)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].hand = @[trap]
    check game.playCard(0)
    game.players[enemy].board = @[readyMinion(enemy, 92, Warrior.classCard())]
    game.nextMinionId = 93
    game.finishTurn()
    check game.currentPlayer == enemy
    check game.actingPlayer() == me
    check game.eligibleAttackers().len == 0

suite "AWM summoned cards' on-play rules":
  proc summoning(card: Card, owner = toRuleValue(You)): Rule =
    ## `summon(1, ...)` of a card outside the base set.
    summon(1, RuleValue[Card](kind: FixedValue, fixed: card), owner)

  let
    herald = Card(name: "Herald", energyCost: 0, kind: Minion,
      rules: rules(draw(1)), power: 1, toughness: 1)
    archerling = Card(name: "Archerling", energyCost: 0, kind: Minion,
      rules: rules(damage(1, target({kind: {Minion}}))), power: 1,
      toughness: 1)

  test "they run for the summoned card's owner, as if it had been played":
    var game = newGame(Mage, Warrior, 1151)
    let
      me = game.leads(Mage)
      enemy = 1 - me
      mayfly = Card(name: "Mayfly", energyCost: 0, kind: Minion,
        rules: rules(destroy(self())), power: 1, toughness: 1)
    game.players[me].hand = @[
      Card(name: "Call", energyCost: 0, kind: Spell,
        rules: @[summoning(herald)]),
      Card(name: "Gift", energyCost: 0, kind: Spell,
        rules: @[summoning(herald, toRuleValue(AllOpponents))]),
      Card(name: "Hatch", energyCost: 0, kind: Spell,
        rules: @[summoning(mayfly)])]
    let
      mine = game.players[me].hand.len
      theirs = game.players[enemy].hand.len
    check game.playCard(0)
    check game.players[me].hand.len == mine  # Call went; Herald drew one.
    check game.playCard(0)
    check game.players[enemy].hand.len == theirs + 1
    check game.players[enemy].board[^1].card.name == "Herald"
    # `self()` is the summoned card.
    check game.players[me].hand[0].name == "Hatch"
    check game.playCard(0)
    check game.players[me].board.len == 1
    check game.players[me].discardPile[^1].name == "Mayfly"
    check not game.waitingTrigger

  test "a targeted one waits for its owner, who may pick no target":
    var game = newGame(Mage, Warrior, 1153)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[enemy].board = @[readyMinion(enemy, 90, Warrior.classCard())]
    game.nextMinionId = 91
    game.players[me].hand = @[
      Card(name: "Muster", energyCost: 0, kind: Spell,
        rules: @[summoning(archerling)]),
      Card(name: "Muster", energyCost: 0, kind: Spell,
        rules: @[summoning(archerling)])]
    check game.playCard(0)
    check game.waitingTrigger
    check game.actingPlayer() == me
    check game.waitingTriggerName() == "Archerling's rule"
    check game.waitingTriggerRules().rules == archerling.rules
    check creatureChoice(enemy, 90) in game.triggerChoices()
    check NoTarget in game.triggerChoices()
    check not game.canPlay(0)
    check game.resolvePendingTrigger(@[creatureChoice(enemy, 90)])
    check game.players[enemy].board[0].currentToughness == 1
    check game.playCard(0)
    check game.resolvePendingTrigger(@[NoTarget])
    check not game.waitingTrigger
    check game.players[enemy].board[0].currentToughness == 1

  test "they resolve after the card that summoned them":
    # Sapper hits every minion for 1; Bolster's later +0/+1 lands first, so
    # the Sapper survives its own blast.
    let sapper = Card(name: "Sapper", energyCost: 0, kind: Minion,
      rules: rules(damage(1, game.board.getCards({kind: {Minion}}))),
      power: 1, toughness: 1)
    var game = newGame(Warrior, Warrior, 1155)
    let me = game.leads(Warrior)
    game.players[me].hand = @[Card(name: "Bolster", energyCost: 0,
      kind: Spell, rules: rules(summoning(sapper), addPowerToughness(0, 1,
        game.board.getCards({kind: {Minion}, owner: You}))))]
    check game.playCard(0)
    check game.players[me].board.len == 1
    check game.players[me].board[0].currentToughness == 1

  test "a summoned card with only triggers queues nothing":
    var game = newGame(Mage, Warrior, 1157)
    let me = game.leads(Mage)
    game.players[me].hand = @[baseCardNamed("Bubble Shield")]
    game.players[me].energy = 2
    check game.playCard(0)
    check game.players[me].board.len == 2
    check game.pendingTriggers.len == 0

suite "AWM presentation beats":
  test "Oozification's Oozes come a beat after its splat and destroy":
    var game = newGame(Mage, Warrior, 1201)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[enemy].board = @[readyMinion(enemy, 1, Warrior.classCard())]
    game.nextMinionId = 2
    game.players[me].hand = @[baseCard("Oozification", 4)]
    game.players[me].energy = 4
    check game.playCard(0, creatureChoice(enemy, 1))
    var
      splat = -1
      death = -1
      summons: seq[int]
    for event in game.takeVisualEvents():
      case event.kind
      of OozeSplatVfx: splat = event.beat
      of DeathVfx: death = event.beat
      of SummonVfx: summons.add event.beat
      else: discard
    check splat >= 0
    check death == splat
    check summons.len == 2
    check summons[0] == summons[1]
    check summons[0] > splat

  test "Plan's turn draw, its draw and its destroy are beats in that order":
    var game = newGame(Mage, Warrior, 1203)
    let me = game.leads(Mage)
    game.players[me].hand = @[baseCard("Plan", 3)]
    game.players[me].energy = 3
    check game.playCard(0)
    game.finishTurn()
    discard game.takeVisualEvents()
    game.finishTurn()
    var kinds: seq[VfxKind]
    var beats: seq[int]
    for event in game.takeVisualEvents():
      if event.kind in {DrawVfx, DeathVfx}:
        kinds.add event.kind
        beats.add event.beat
    check kinds == @[DrawVfx, DrawVfx, DeathVfx]
    check beats[0] < beats[1]
    check beats[1] < beats[2]

  test "each card of a multi-card draw is its own beat":
    var game = newGame(Mage, Warrior, 1205)
    let me = game.leads(Mage)
    game.players[me].hand = @[Card(name: "Study", energyCost: 0, kind: Spell,
      rules: rules(draw(2)))]
    check game.playCard(0)
    var beats: seq[int]
    for event in game.takeVisualEvents():
      if event.kind == DrawVfx:
        beats.add event.beat
    check beats.len == 2
    check beats[0] < beats[1]

suite "AWM Study and discards":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  proc studyGame(seed: int64): (GameState, int, int) =
    ## Study plus two cards in hand, energy for Study.
    var game = newGame(Mage, Warrior, seed)
    let me = game.leads(Mage)
    game.players[me].hand =
      @[baseCard("Study", 2), baseCard("Bouncer", 1), baseCard("Plan", 3)]
    game.players[me].energy = 2
    (game, me, 1 - me)

  test "Study and toss print their rules":
    let study = baseCard("Study", 2)
    check study.kind == Spell
    check study.class == some(Mage)
    check not study.needsChoice()
    check study.ruleText() == "Draw 2 cards.\nDiscard 1 card."
    check printed(rules(toss(2, AllOpponents))) == "Each opponent discards 2 cards."
    check printed(rules(destroy(target({kind: {Minion}})),
      toss(getTarget().toughness, getTarget().owner))) ==
      "Destroy a minion.\n" &
      "The target's owner discards cards equal to the target's toughness."

  test "Study draws, then waits for its player to pick a discard":
    var (game, me, _) = studyGame(1301)
    let deck = game.players[me].deck.len
    check game.playCard(0)
    check game.players[me].energy == 0
    check game.players[me].hand.len == 4
    check game.players[me].deck.len == deck - 2
    check game.players[me].discardPile == @[baseCard("Study", 2)]
    check game.waitingToss
    check game.waitingChoice
    check game.actingPlayer() == me
    check game.pendingToss.count == 1
    check game.pendingToss.source == "Study"
    check game.pendingToss.text == "Discard 1 card."
    check not game.canPlay(0)
    let turn = game.turnNumber
    game.finishTurn()
    check game.turnNumber == turn
    discard game.takeVisualEvents()
    let tossed = game.players[me].hand[1]
    check game.resolvePendingToss(@[1])
    check not game.waitingToss
    check game.players[me].hand.len == 3
    check game.players[me].discardPile == @[baseCard("Study", 2), tossed]
    var tosses: seq[VisualEvent]
    for event in game.takeVisualEvents():
      if event.kind == TossVfx:
        tosses.add event
    check tosses.len == 1
    check tosses[0].card == tossed
    check (tosses[0].handIndex, tosses[0].boardCount) == (1, 4)

  test "bad discard picks are refused and it keeps waiting":
    var (game, me, _) = studyGame(1303)
    check game.playCard(0)
    check not game.resolvePendingToss(@[])
    check not game.resolvePendingToss(@[0, 1])
    check not game.resolvePendingToss(@[9])
    check not game.resolvePendingToss(@[-1])
    check game.waitingToss
    check game.players[me].hand.len == 4

  test "a discard takes at most the hand, and none from an empty hand":
    var game = newGame(Mage, Warrior, 1305)
    let me = game.leads(Mage)
    game.players[me].hand = @[
      Card(name: "Purge", energyCost: 0, kind: Spell, rules: rules(toss(3))),
      baseCard("Bouncer", 1)]
    check game.playCard(0)
    check game.pendingToss.count == 1
    check game.resolvePendingToss(@[0])
    check game.players[me].hand.len == 0
    game.players[me].hand = @[
      Card(name: "Purge", energyCost: 0, kind: Spell, rules: rules(toss(1)))]
    check game.playCard(0)
    check not game.waitingToss

  test "rules after a discard wait until it's chosen":
    var game = newGame(Mage, Warrior, 1307)
    let
      me = game.leads(Mage)
      deck = game.players[me].deck.len
    game.players[me].hand = @[
      Card(name: "Swap", energyCost: 0, kind: Spell,
        rules: rules(toss(1), draw(1))),
      baseCard("Bouncer", 1)]
    check game.playCard(0)
    check game.waitingToss
    check game.pendingToss.remaining.len == 1
    check game.players[me].deck.len == deck
    check game.resolvePendingToss(@[0])
    # The draw came after the discard, so the drawn card stays in hand.
    check game.players[me].deck.len == deck - 1
    check game.players[me].hand.len == 1
    check game.players[me].hand[0] != baseCard("Bouncer", 1)

  test "an opponent's discard waits for the opponent":
    var game = newGame(Mage, Warrior, 1309)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].hand = @[Card(name: "Rot", energyCost: 0, kind: Spell,
      rules: rules(toss(1, AllOpponents)))]
    check game.playCard(0)
    check game.waitingToss
    check game.currentPlayer == me
    check game.actingPlayer() == enemy
    check game.resolvePendingToss(@[0])
    check game.players[enemy].discardPile.len == 1

  test "a discard inside a trigger holds the trigger queue":
    let grind = Card(name: "Grind", energyCost: 0, kind: Trinket,
      rules: rules(on(nextTurn(You), toss(1), draw(1))))
    var game = newGame(Mage, Warrior, 1311)
    let me = game.leads(Mage)
    game.players[me].hand = @[grind]
    check game.playCard(0)
    game.finishTurn()
    game.finishTurn()
    check game.waitingToss
    check game.actingPlayer() == me
    let hand = game.players[me].hand.len
    check game.resolvePendingToss(@[0])
    check not game.waitingChoice
    check game.players[me].hand.len == hand

suite "AWM class cards and off-class costs":
  test "a class card belongs to no class and prints what it teaches":
    for (id, heroClass) in [("archer-0", Archer), ("warrior-0", Warrior),
        ("mage-0", Mage)]:
      let card = baseCard(id)
      check card.kind == Trinket
      check card.class.isNone
      check card.energyCost == 0
      check card.ruleText() ==
        "Off-class " & heroClass.className() & " cards cost 1 less."
      check card.levels(heroClass) == 1
      check card.levelUpClass() == some(heroClass)
    check baseCard("bolt-1").levels(Archer) == 0
    check baseCard("bolt-1").levelUpClass().isNone

  test "a card of another class costs three more, your own costs nothing":
    var game = newGame(Mage, Warrior, 2601)
    let me = game.leads(Mage)
    check game.extraCost(me, baseCard("bouncer-1")) == 0
    check game.playCost(me, baseCard("bouncer-1")) == 1
    check game.extraCost(me, baseCard("bolt-1")) == OffClassCost
    check game.playCost(me, baseCard("bolt-1")) == 1 + OffClassCost
    # A card of no class is nobody's off-class card.
    check game.extraCost(me, baseCard("archer-0")) == 0

  test "each class card in play takes one off that class's surcharge":
    var game = newGame(Mage, Warrior, 2603)
    let me = game.leads(Mage)
    let bolt = baseCard("bolt-1")
    for level in 0 .. 3:
      check game.playCost(me, bolt) == 1 + max(0, OffClassCost - level)
      # A Warrior card never gets cheaper from Archer class cards.
      check game.playCost(me, baseCard("bear-2")) == 2 + OffClassCost
      game.players[me].board.add MinionState(id: level + 1, owner: me,
        card: baseCard("archer-0"), enteredTurn: game.turnNumber)
      game.nextMinionId = level + 2
    # A fourth never takes it below the printed cost.
    game.players[me].board.add MinionState(id: 5, owner: me,
      card: baseCard("archer-0"), enteredTurn: game.turnNumber)
    check game.playCost(me, bolt) == 1

  test "only your own class cards help you":
    var game = newGame(Mage, Warrior, 2605)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[enemy].board = @[MinionState(id: 1, owner: enemy,
      card: baseCard("archer-0"), enteredTurn: game.turnNumber)]
    game.nextMinionId = 2
    check game.playCost(me, baseCard("bolt-1")) == 1 + OffClassCost

  test "the surcharge is paid, and shows up in what you can afford":
    var game = newGame(Mage, Warrior, 2607)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].hand = @[baseCard("bolt-1")]
    game.players[me].energy = 3
    check not game.canPlay(0)
    game.players[me].energy = 4
    check game.canPlay(0)
    check game.playCard(0, heroChoice(enemy))
    check game.players[me].energy == 0
    check game.players[enemy].life == StartingLife - 2

  test "playing a class card announces the class over its hero":
    var game = newGame(Mage, Warrior, 2609)
    let me = game.leads(Mage)
    game.players[me].hand = @[baseCard("archer-0")]
    check game.playCard(0)
    check game.players[me].board.len == 1
    check game.levels(me, Archer) == 1
    check game.levels(me, Warrior) == 0
    var announced = 0
    for event in game.takeVisualEvents():
      if event.kind == LevelUpVfx:
        inc announced
        check event.target == heroChoice(me)
        check event.card.levelUpClass() == some(Archer)
    check announced == 1

  test "a deck list may name cards of another class":
    let splash = @[("Bolt", 4), ("Bear", 4), ("Warrior", 32)]
    check splash.deckProblems().len == 0
    check splash.buildDeck().len == DeckSize
    # The precons keep to their class, plus class cards of no class.
    for heroClass in HeroClass:
      let deck = heroClass.baseDeck()
      check deck.len == DeckSize
      for card in deck:
        check card.class == some(heroClass) or card.isClassCard

suite "AWM option faces":
  test "every branch a card offers has a face of its own":
    # The table shows one card per branch, so each needs a face of its own.
    # Pillage's choice comes after a target, which is why the faces are
    # collected from the whole card and not from the pick being made.
    let pillage = baseCard("pillage-4")
    check pillage.options().len == 0
    check pillage.everyOption().len == 2
    check baseCard("overcharge-3").everyOption().len == 2
    check baseCard("bolt-1").everyOption().len == 0
    # Each branch must read differently from its card and from the other
    # branches, or the choice would offer cards that look the same.
    for card in baseCards:
      var printed = @[card.ruleText()]
      for option in card.everyOption():
        let branch = card.optionCard(option)
        check branch.name == card.name
        check branch.energyCost == card.energyCost
        check branch.ruleText().len > 0
        check branch.ruleText() notin printed
        printed.add branch.ruleText()

  test "a branch inside a trigger is found too":
    let fickle = Card(name: "Fickle", energyCost: 0, kind: Trinket,
      rules: rules(on(eachTurn(You),
        choose(rules(draw(1)), rules(damage(1, target({kind: {Hero}})))))))
    check fickle.everyOption().len == 2
    check fickle.optionCard(fickle.everyOption()[0]).ruleText() ==
      "Draw 1 card."

suite "AWM hidden minions":
  proc hiddenGame(card: Card, seed: int64): (GameState, int, int) =
    ## That card in play for the player whose turn it is, with an enemy
    ## Bear ready to attack it.
    var game = newGame(Archer, Warrior, seed)
    let
      me = game.leads(Archer)
      enemy = 1 - me
    game.players[me].board = @[MinionState(id: 1, owner: me, card: card,
      currentToughness: card.toughness, enteredTurn: game.turnNumber,
      hiddenTurns: card.hiddenTurns())]
    game.players[enemy].board = @[readyMinion(enemy, 2, baseCard("bear-2"))]
    game.nextMinionId = 3
    (game, me, enemy)

  test "hidden prints its count, and hidden() prints none":
    check baseCard("ambusher-3").ruleText() == "Hidden 1."
    check Card(kind: Minion, rules: rules(hidden())).ruleText() == "Hidden."
    check baseCard("ambusher-3").hiddenTurns() == 1
    check Card(kind: Minion, rules: rules(hidden())).hiddenTurns() == Always
    check baseCard("bear-2").hiddenTurns() == 0
    check Card(kind: Minion, rules: rules(hidden(3))).hiddenTurns() == 3

  test "a hidden minion can't be attacked, and comes out on its owner's turn":
    var (game, me, enemy) = hiddenGame(baseCard("ambusher-3"), 2501)
    game.finishTurn()
    # The opponent can swing at the hero, but not at what it can't see.
    check game.attackTargets(2) == @[heroChoice(me)]
    check not game.attack(2, creatureChoice(me, 1))
    check game.players[me].board[0].currentToughness == 2
    # Hidden 1 runs out as its owner's next turn begins.
    game.finishTurn()
    check game.players[me].board[0].hiddenTurns == 0
    game.finishTurn()
    check game.attackTargets(2) ==
      @[heroChoice(me), creatureChoice(me, 1)]
    check game.attack(2, creatureChoice(me, 1))

  test "a longer count hides it for that many of its owner's turns":
    let lurker = Card(name: "Lurker", energyCost: 1, kind: Minion,
      rules: rules(hidden(2)), power: 1, toughness: 3)
    var (game, me, _) = hiddenGame(lurker, 2503)
    for round in 0 ..< 2:
      game.finishTurn()  # the opponent's turn: still hidden
      check game.attackTargets(2) == @[heroChoice(me)]
      game.finishTurn()  # its owner's turn: one turn less
    check game.players[me].board[0].hiddenTurns == 0
    game.finishTurn()
    check creatureChoice(me, 1) in game.attackTargets(2)

  test "hidden() never comes out":
    let ghost = Card(name: "Ghost", energyCost: 1, kind: Minion,
      rules: rules(hidden()), power: 1, toughness: 1)
    var (game, me, _) = hiddenGame(ghost, 2505)
    for round in 0 ..< 3:
      game.finishTurn()  # the opponent's turn: the hero is all they can hit
      check game.attackTargets(2) == @[heroChoice(me)]
      check game.players[me].board[0].hiddenTurns == Always
      game.finishTurn()  # its owner's turn: nothing runs down

  test "spells still reach a hidden minion":
    var (game, me, enemy) = hiddenGame(baseCard("ambusher-3"), 2507)
    game.finishTurn()
    game.players[enemy].hand = @[baseCard("sharpshooter-3")]
    game.players[enemy].energy =
      game.playCost(enemy, baseCard("sharpshooter-3"))
    # Hiding is cover from attacks, not from a card that aims at it.
    check creatureChoice(me, 1) in game.availableChoices(0)
    check game.playCard(0, creatureChoice(me, 1))
    check game.players[me].board[0].currentToughness == 1

  test "a hidden minion attacks like any other, and summons hide too":
    var (game, me, enemy) = hiddenGame(baseCard("ambusher-3"), 2509)
    check game.players[me].board[0].hiddenTurns == 1
    game.players[me].board[0].canAttack = true
    check game.attack(1, heroChoice(enemy))
    check game.players[enemy].life == StartingLife - 2
    # Still hidden after striking: its count runs on turns, not attacks.
    check game.players[me].board[0].hiddenTurns == 1
    # A summoned copy carries the same hiding.
    game.players[me].hand = @[Card(name: "Call", energyCost: 0, kind: Spell,
      rules: rules(summon(1, "Ambusher")))]
    check game.playCard(0)
    check game.players[me].board[^1].hiddenTurns == 1

suite "AWM repeat and Reload":
  test "Reload repeats the rules of a minion or trinket":
    let reload = baseCard("reload-2")
    check reload.kind == Spell
    check reload.class == some(Archer)
    check reload.ruleText() == "Repeat a minion or trinket's rules."
    check reload.needsChoice()
    # Only the card to repeat is known until it is picked.
    check reload.targetCount() == 1
    check reload.targetPrompt(0).choose == "Choose a minion or trinket."

  test "the repeated rules aim fresh targets of their own":
    var game = newGame(Archer, Warrior, 2301)
    let
      me = game.leads(Archer)
      enemy = 1 - me
    game.players[me].hand = @[baseCard("reload-2")]
    game.players[me].energy = 2
    game.players[me].board = @[MinionState(id: 1, owner: me,
      card: baseCard("sharpshooter-3"), currentToughness: 1)]
    game.players[enemy].board = @[MinionState(id: 2, owner: enemy,
      card: baseCard("bear-2"), currentToughness: 2)]
    game.nextMinionId = 3
    let picks = @[creatureChoice(me, 1)]
    # Picking the Sharpshooter reveals the target its own rule asks for.
    check baseCard("reload-2").targetCount(picks, game.boardCards()) == 2
    check baseCard("reload-2").targetPrompt(1, picks,
      game.boardCards()).choose == "Choose any target."
    check game.playCard(0, picks & creatureChoice(enemy, 2))
    check game.players[enemy].board[0].currentToughness == 1
    # The Sharpshooter itself is untouched: only its rules ran again.
    check game.players[me].board[0].currentToughness == 1
    check game.players[me].energy == 0

  test "a trinket's rules are repeated too":
    var game = newGame(Archer, Mage, 2303)
    let me = game.leads(Archer)
    game.players[me].hand = @[baseCard("reload-2")]
    game.players[me].energy = 2
    game.players[me].board = @[MinionState(id: 1, owner: me,
      card: baseCard("plan-3"), enteredTurn: game.turnNumber)]
    game.nextMinionId = 2
    let hand = game.players[me].hand.len
    check game.availableChoices(0) == @[creatureChoice(me, 1)]
    check game.playCard(0, @[creatureChoice(me, 1)])
    # Plan draws a card again, and is still in play.
    check game.players[me].hand.len == hand
    check game.players[me].board.len == 1

  test "rules aimed at their own card do nothing when repeated":
    let selfish = Card(name: "Selfish", energyCost: 0, kind: Minion,
      rules: rules(draw(1), destroy(self())), power: 1, toughness: 1)
    var game = newGame(Archer, Mage, 2305)
    let me = game.leads(Archer)
    game.players[me].hand = @[baseCard("reload-2")]
    game.players[me].energy = 2
    game.players[me].board = @[MinionState(id: 1, owner: me, card: selfish,
      currentToughness: 1)]
    game.nextMinionId = 2
    let hand = game.players[me].hand.len
    check game.playCard(0, @[creatureChoice(me, 1)])
    # The draw happens; the destroy has no card of its own to destroy.
    check game.players[me].hand.len == hand
    check game.players[me].board.len == 1
    check game.players[me].board[0].card == selfish

  test "canceling the card to repeat pays nothing":
    var game = newGame(Archer, Warrior, 2307)
    let me = game.leads(Archer)
    game.players[me].hand = @[baseCard("reload-2")]
    game.players[me].energy = 2
    game.players[me].board = @[MinionState(id: 1, owner: me,
      card: baseCard("sharpshooter-3"), currentToughness: 1)]
    game.nextMinionId = 2
    check not game.playCard(0, @[Canceled])
    check not game.playCard(0, @[creatureChoice(me, 1), Canceled])
    check game.players[me].hand.len == 1
    check game.players[me].energy == 2
    check game.takeVisualEvents().len == 0

  test "a target's braces take a trinket beside minions":
    check Card(kind: Spell, rules: rules(
      destroy(target({kind: {Trinket}})))).ruleText() == "Destroy a trinket."
    check Card(kind: Spell, rules: rules(destroy(
      target({kind: {Trinket}, owner: AllOpponents})))).ruleText() ==
      "Destroy an enemy trinket."
    var game = newGame(Mage, Mage, 2309)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].board = @[MinionState(id: 1, owner: me,
      card: baseCard("plan-3")), MinionState(id: 2, owner: me,
      card: baseCard("bouncer-1"), currentToughness: 1)]
    game.players[enemy].board = @[MinionState(id: 3, owner: enemy,
      card: baseCard("plan-3"))]
    game.nextMinionId = 4
    game.players[me].hand = @[Card(name: "Snap", energyCost: 0, kind: Spell,
      rules: rules(destroy(target({kind: {Trinket}}))))]
    # Trinkets, and no minions.
    check game.availableChoices(0) ==
      @[creatureChoice(me, 1), creatureChoice(enemy, 3)]
    check game.playCard(0, creatureChoice(enemy, 3))
    check game.players[enemy].board.len == 0

suite "AWM eachTurn and Wildfire":
  test "Wildfire burns every minion and every player, each of your turns":
    let wildfire = baseCard("wildfire-6")
    check wildfire.kind == Trinket
    check wildfire.ruleText() == "On each of your turns, " &
      "deal 1 damage to all minions and deal 1 damage to each player."
    check not wildfire.needsChoice()
    var game = newGame(Archer, Warrior, 2401)
    let
      me = game.leads(Archer)
      enemy = 1 - me
    game.players[me].board = @[MinionState(id: 1, owner: me, card: wildfire,
      enteredTurn: game.turnNumber), MinionState(id: 2, owner: me,
      card: baseCard("bear-2"), currentToughness: 2)]
    game.players[enemy].board = @[MinionState(id: 3, owner: enemy,
      card: baseCard("sniper-2"), currentToughness: 1)]
    game.nextMinionId = 4
    # The opponent's turn passes without it firing.
    game.finishTurn()
    check game.players[me].life == StartingLife
    check game.players[enemy].board.len == 1
    # Back to its owner: everything takes 1.
    game.finishTurn()
    check game.players[me].life == StartingLife - 1
    check game.players[enemy].life == StartingLife - 1
    check game.players[me].board[1].currentToughness == 1
    check game.players[enemy].board.len == 0
    # And again next turn: an each-turn trigger is never spent.
    game.finishTurn()
    game.finishTurn()
    check game.players[me].life == StartingLife - 2
    check game.players[enemy].life == StartingLife - 2
    check game.players[me].board.len == 1
    check game.players[me].board[0].card == wildfire

  test "a next-turn trigger still fires only once":
    check Card(kind: Trinket, rules: rules(on(nextTurn(You), draw(1))))
      .ruleText() == "On your next turn, draw 1 card."
    var game = newGame(Mage, Warrior, 2403)
    let me = game.leads(Mage)
    game.players[me].board = @[MinionState(id: 1, owner: me,
      card: Card(name: "Once", energyCost: 0, kind: Trinket,
        rules: rules(on(nextTurn(You), draw(1)))),
      enteredTurn: game.turnNumber)]
    game.nextMinionId = 2
    var draws = 0
    for turn in 0 ..< 6:
      let before = game.players[me].hand.len
      game.finishTurn()
      if game.currentPlayer == me and game.players[me].hand.len > before + 1:
        inc draws
    check draws == 1

  test "each player can be named as a whole":
    check Card(kind: Spell, rules: rules(damage(2, game.players))).ruleText() ==
      "Deal 2 damage to each player."
    var game = newGame(Archer, Warrior, 2405)
    let me = game.leads(Archer)
    game.players[me].hand = @[Card(name: "Storm", energyCost: 0, kind: Spell,
      rules: rules(damage(2, game.players)))]
    check game.playCard(0)
    check game.players[me].life == StartingLife - 2
    check game.players[1 - me].life == StartingLife - 2

suite "AWM choose and Overcharge":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  proc overchargeGame(seed: int64): (GameState, int, int) =
    ## Overcharge in hand, with an enemy Bear to aim it at.
    var game = newGame(Archer, Warrior, seed)
    let
      me = game.leads(Archer)
      enemy = 1 - me
    game.players[me].hand = @[baseCard("overcharge-3")]
    game.players[me].energy = 3
    game.players[enemy].board = @[MinionState(id: 1, owner: enemy,
      card: baseCard("bear-2"), currentToughness: 2)]
    game.nextMinionId = 2
    (game, me, enemy)

  test "a choose rule prints its branches, one per line":
    let card = baseCard("overcharge-3")
    check card.ruleText() == "Choose:\n" &
      "- Deal 1 damage to a minion. Deal 1 damage to the target's owner.\n" &
      "- Deal 3 damage to a minion. Deal 3 damage to the target's owner. " &
      "Deal 3 damage to yourself."
    check printed(rules(choose(rules(draw(1)), rules(draw(2))))) ==
      "Choose:\n- Draw 1 card.\n- Draw 2 cards."

  test "the option comes first, and the branch's own targets follow it":
    let card = baseCard("overcharge-3")
    check card.needsChoice()
    # Only the option is known until it is picked.
    check card.targetCount() == 1
    check card.targetPrompt(0).choose == "Choose an option."
    check card.options().len == 2
    check card.optionCard(card.options()[0]).ruleText() ==
      "Deal 1 damage to a minion.\nDeal 1 damage to the target's owner."
    for option in 0 .. 1:
      let picks = @[optionChoice(option)]
      check card.targetCount(picks) == 2
      check card.options(picks).len == 0
      check card.targetPrompt(1, picks).choose == "Choose a minion."
    check card.intent(1, @[optionChoice(1)]) == DamageIntent
    check card.intentAmount(1, @[optionChoice(1)]) == 3

  test "the gentle branch spares you, the fierce one burns you too":
    for option in 0 .. 1:
      var (game, me, enemy) = overchargeGame(2101 + option.int64)
      check game.availableChoices(0) ==
        @[optionChoice(0), optionChoice(1)]
      check game.availableChoices(0, @[optionChoice(option)]) ==
        @[creatureChoice(enemy, 1)]
      check game.playCard(0,
        @[optionChoice(option), creatureChoice(enemy, 1)])
      let dealt = if option == 0: 1 else: 3
      check game.players[enemy].life == StartingLife - dealt
      check game.players[me].life ==
        (if option == 0: StartingLife else: StartingLife - 3)
      check game.players[me].energy == 0
      # 3 damage kills the Bear; 1 only wounds it.
      check game.players[enemy].board.len == (if option == 0: 1 else: 0)
      if option == 0:
        check game.players[enemy].board[0].currentToughness == 1

  test "each rule of the chosen branch plays on its own beat":
    var (game, me, enemy) = overchargeGame(2103)
    check game.playCard(0, @[optionChoice(1), creatureChoice(enemy, 1)])
    var beats: seq[int]
    for event in game.takeVisualEvents():
      if event.kind == LightningVfx and event.beat notin beats:
        beats.add event.beat
    # The minion, then its owner, then yourself: three beats, in order.
    check beats.len == 3
    check beats == @[beats[0], beats[0] + 1, beats[0] + 2]

  test "an unanswered or impossible option leaves the card in hand":
    var (game, me, _) = overchargeGame(2105)
    check not game.playCard(0, @[Canceled])
    check not game.playCard(0, @[optionChoice(5), heroChoice(me)])
    check not game.playCard(0, @[optionChoice(0), Canceled])
    check game.players[me].hand.len == 1
    check game.players[me].energy == 3
    check game.takeVisualEvents().len == 0

  test "damage can name players instead of targets":
    check printed(rules(damage(3, You))) == "Deal 3 damage to yourself."
    check printed(rules(damage(1, AllOpponents))) ==
      "Deal 1 damage to each opponent."
    check printed(rules(bounce(target({kind: {Minion}})), damage(2,
      getTarget().owner))) == "Return a minion to its owner's hand.\n" &
      "Deal 2 damage to the target's owner."
    var game = newGame(Archer, Warrior, 2107)
    let me = game.leads(Archer)
    game.players[me].hand = @[Card(name: "Sting", energyCost: 0, kind: Spell,
      rules: rules(damage(2, AllOpponents), damage(1, You)))]
    check game.playCard(0)
    check game.players[me].life == StartingLife - 1
    check game.players[1 - me].life == StartingLife - 2

suite "AWM Explode":
  test "Explode destroys one of yours and throws its power at any target":
    let card = baseCard("explode-3")
    check card.kind == Spell
    check card.class == some(Archer)
    check card.ruleText() == "Destroy a friendly minion.\n" &
      "Deal the first target's power damage to any target."
    check card.targetCount() == 2
    check card.targetPrompt(0).choose == "Choose a friendly minion."
    check card.targetPrompt(1).choose == "Choose any target."
    var game = newGame(Archer, Warrior, 2201)
    let
      me = game.leads(Archer)
      enemy = 1 - me
    game.players[me].hand = @[card]
    game.players[me].energy = 3
    game.players[me].board = @[MinionState(id: 1, owner: me,
      card: baseCard("sharpshooter-3"), currentToughness: 1)]
    game.players[enemy].board = @[MinionState(id: 2, owner: enemy,
      card: baseCard("bear-2"), currentToughness: 2)]
    game.nextMinionId = 3
    # Only your own minions can be blown up.
    check game.availableChoices(0) == @[creatureChoice(me, 1)]
    check game.playCard(0,
      @[creatureChoice(me, 1), creatureChoice(enemy, 2)])
    check game.players[me].board.len == 0
    check game.players[enemy].board.len == 0
    check game.players[me].discardPile[^1] == card
    var explosions = 0
    for event in game.takeVisualEvents():
      if event.kind == ExplosionVfx:
        inc explosions
    check explosions == 2

  test "a target's braces take an owner filter beside its kinds":
    check Card(kind: Spell, rules: rules(
      destroy(target({kind: {Minion}, owner: You})))).ruleText() ==
      "Destroy a friendly minion."
    check Card(kind: Spell, rules: rules(
      destroy(target({kind: {Minion}, owner: AllOpponents})))).ruleText() ==
      "Destroy an enemy minion."
    # The older positional form still reads the same.
    check Card(kind: Spell, rules: rules(
      destroy(target({kind: {Minion}, owner: AllOpponents})))).ruleText() ==
      "Destroy an enemy minion."
    check not compiles(target({kind: {Minion}, colour: You}))

suite "AWM target intents":
  test "every targeting rule says what it does to its target, and how much":
    check baseCard("sharpshooter-3").intent(0) == DamageIntent
    check baseCard("sharpshooter-3").intentAmount(0) == 1
    check baseCard("bouncer-1").intent(0) == BounceIntent
    check baseCard("oozification-4").intent(0) == DestroyIntent
    check baseCard("tactician-2").intent(0) == WeakenIntent
    check baseCard("tactician-2").intentAmount(0) == 1
    # Duel buffs its first target and takes Ranged off its second.
    check baseCard("duel-2").intent(0) == BuffIntent
    check baseCard("duel-2").intentAmount(0) == 2
    check baseCard("duel-2").intent(1) == KeywordIntent
    # A card with nothing to judge, and a step past the end.
    check baseCard("bolt-1").intent(0) == DamageIntent
    check baseCard("plan-3").intent(0) == NoIntent
    check baseCard("duel-2").intent(7) == NoIntent
    check baseCard("duel-2").intentAmount(7) == 0

  test "an amount only known on resolve counts as one":
    let drain = Card(name: "Drain", energyCost: 1, kind: Spell,
      rules: rules(damage(game.board.getCards({kind: {Minion}, owner: You}).count,
        target({kind: {Hero}}))))
    check drain.intent(0) == DamageIntent
    check drain.intentAmount(0) == 1

suite "AWM selections and Primordial":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  test "targets and queries are interchangeable; text follows the form":
    check printed(rules(bounce(target({kind: {Minion}})))) ==
      "Return a minion to its owner's hand."
    check printed(rules(bounce(
      game.board.getCards({kind: {Minion}, owner: AllOpponents})))) ==
      "Return all enemy minions to their owners' hands."
    check printed(rules(destroy(game.board.getCards({kind: {Minion}})))) ==
      "Destroy all minions."
    check printed(rules(lose(ranged(),
      game.board.getCards({kind: {Minion}, owner: AllOpponents})))) ==
      "All enemy minions lose Ranged."
    check printed(rules(removePowerToughness(1, 0,
      game.board.getCards({kind: {Minion}, owner: AllOpponents})))) ==
      "Give all enemy minions -1/-0."
    check printed(rules(addPowerToughness(1, 1, target({kind: {Minion}})))) ==
      "Give a minion +1/+1."

  test "choose filters in braces, self: false and no filter at all":
    check printed(rules(damage(1, game.board.getCards({})))) ==
      "Deal 1 damage to all cards."
    check printed(rules(damage(1,
      game.board.getCards({kind: {Minion}, self: false})))) ==
      "Deal 1 damage to all other minions."
    check printed(rules(damage(game.board.getCards({owner: You, self: false}).count,
      target({kind: {Hero}})))) ==
      "Deal the number of other friendly cards damage to a hero."
    check not compiles(rules(damage(1, game.board.getCards({color: Minion}))))

  test "a query's owner filter is a pick, and reads as the hero itself":
    check printed(rules(bounce(game.board.getCards({owner: target({kind: {Hero}})})))) ==
      "Return all cards a hero controls to their owner's hand."
    check printed(rules(destroy(
      game.board.getCards({kind: {Minion}, owner: target({kind: {Opponent}})})))) ==
      "Destroy all minions an opponent controls."
    # One owner keeps the possessive singular; several keep it plural.
    check printed(rules(bounce(game.board.getCards({kind: {Minion}, owner: You})))) ==
      "Return all friendly minions to their owner's hand."
    check printed(rules(bounce(game.board.getCards({self: false})))) ==
      "Return all other cards to their owners' hands."
    # A picked card still names its owner; only players speak for themselves.
    check printed(rules(bounce(target({kind: {Minion}})),
      damage(1, game.board.getCards({owner: getTarget().owner})))) ==
      "Return a minion to its owner's hand.\n" &
      "Deal 1 damage to all cards the target's owner controls."

  test "Summon Primordial asks for a hero, clears its board and summons":
    let spell = baseCard("summon-primordial-8")
    check spell.kind == Spell
    check spell.class == some(Mage)
    check spell.ruleText() ==
      "Return all cards a hero controls to their owner's hand.\n" &
      "Summon a Primordial."
    check spell.needsChoice()
    check spell.targetCount() == 1
    check spell.targetPrompt(0).choose == "Choose a hero."
    var game = newGame(Mage, Warrior, 1401)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].board = @[readyMinion(me, 1, Mage.classCard())]
    game.players[enemy].board = @[readyMinion(enemy, 2, baseCard("Sniper", 2)),
      MinionState(id: 3, owner: enemy, card: Warrior.classCard(),
        currentToughness: 2, enteredTurn: game.turnNumber)]
    game.nextMinionId = 4
    game.players[me].hand = @[spell]
    game.players[me].energy = 8
    let aimed = game.availableChoices(0)
    check aimed.len == 2
    check heroChoice(me) in aimed
    check heroChoice(enemy) in aimed
    let enemyHand = game.players[enemy].hand.len
    check game.playCard(0, heroChoice(enemy))
    # The enemy board goes home; mine keeps its minion and gains Primordial.
    check game.players[enemy].board.len == 0
    check game.players[enemy].hand.len == enemyHand + 2
    check game.players[enemy].hand[^2 .. ^1] ==
      @[baseCard("Sniper", 2), Warrior.classCard()]
    check game.players[me].board.len == 2
    check game.players[me].board[0].card == Mage.classCard()
    let primordial = game.players[me].board[1]
    check primordial.card == baseCard("primordial-10")
    check primordial.power == 10
    check primordial.currentToughness == 10
    check not primordial.canAttack
    var bubbles, bounces, summons: int
    for event in game.takeVisualEvents():
      case event.kind
      of BubbleVfx: inc bubbles
      of BounceVfx: inc bounces
      of SummonVfx: inc summons
      else: discard
    check (bubbles, bounces, summons) == (2, 2, 1)

  test "Summon Primordial aimed at your own hero clears your side first":
    let spell = baseCard("summon-primordial-8")
    var game = newGame(Mage, Warrior, 1402)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].board = @[readyMinion(me, 1, Mage.classCard()),
      MinionState(id: 2, owner: me, card: baseCard("Plan", 3),
        enteredTurn: game.turnNumber)]
    game.players[enemy].board = @[readyMinion(enemy, 3, Warrior.classCard())]
    game.nextMinionId = 4
    game.players[me].hand = @[spell]
    game.players[me].energy = 8
    check game.playCard(0, heroChoice(me))
    check game.players[me].hand ==
      @[Mage.classCard(), baseCard("Plan", 3)]
    check game.players[me].board.len == 1
    check game.players[me].board[0].card == baseCard("primordial-10")
    check game.players[enemy].board.len == 1

  test "canceling the hero pick pays nothing and summons nothing":
    var game = newGame(Mage, Warrior, 1403)
    let me = game.leads(Mage)
    game.players[me].hand = @[baseCard("summon-primordial-8")]
    game.players[me].energy = 8
    check not game.playCard(0, Canceled)
    check game.players[me].energy == 8
    check game.players[me].hand.len == 1
    check game.players[me].board.len == 0
    check game.takeVisualEvents().len == 0

  test "Primordial itself is a vanilla 10/10 that only Summon Primordial makes":
    let primordial = baseCard("primordial-10")
    check primordial.kind == Minion
    check primordial.class == some(Mage)
    check (primordial.power, primordial.toughness) == (10, 10)
    check primordial.rules.len == 0
    check primordial.ruleText() == ""
    check not primordial.needsChoice()

  test "query forms act on every match, and a spell has no self to skip":
    let sweep = Card(name: "Sweep", energyCost: 0, kind: Spell, rules: rules(
      lose(ranged(), game.board.getCards({kind: {Minion}, owner: AllOpponents})),
      removePowerToughness(1, 0,
        game.board.getCards({kind: {Minion}, owner: AllOpponents})),
      destroy(game.board.getCards({owner: You, self: false}))))
    var game = newGame(Mage, Archer, 1403)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].board = @[readyMinion(me, 1, Warrior.classCard())]
    game.players[enemy].board = @[readyMinion(enemy, 2, baseCard("Sniper", 2)),
      readyMinion(enemy, 3, baseCard("Sharpshooter", 3))]
    game.nextMinionId = 4
    game.players[me].hand = @[sweep]
    check game.playCard(0)
    check game.players[me].board.len == 0
    for minion in game.players[enemy].board:
      check minion.lostKeywords == {Ranged}
    check game.players[enemy].board[0].power == 1
    check game.players[enemy].board[1].power == 2

suite "AWM attack triggers and Bubble Shield":
  proc printed(list: Rules): string =
    Card(kind: Spell, rules: list).ruleText()

  proc shieldGame(seed: int64): (GameState, int, int) =
    ## My Bubble Shield resolved, then the enemy's turn with two ready Bears.
    var game = newGame(Mage, Warrior, seed)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].hand = @[baseCard("Bubble Shield", 2)]
    game.players[me].energy = 2
    check game.playCard(0)
    game.finishTurn()
    game.players[enemy].board = @[readyMinion(enemy, 50, Warrior.classCard()),
      readyMinion(enemy, 51, Warrior.classCard())]
    game.nextMinionId = 52
    (game, me, enemy)

  test "Bubble, Bubble Shield and attacked triggers print their rules":
    let
      bubble = baseCard("Bubble", 0)
      shield = baseCard("Bubble Shield", 2)
    check bubble.kind == Trinket
    check bubble.targetCount() == 0
    check not bubble.needsChoice()
    check bubble.ruleText() == "When your hero is attacked, " &
      "return the attacker to its owner's hand and destroy this card."
    check shield.kind == Spell
    check shield.ruleText() == "Summon 2 Bubbles."
    check printed(rules(on(attacked(AnyOpponent), draw(1)))) ==
      "When an opponent's hero is attacked, draw 1 card."
    check printed(rules(on(attacked(self()), damage(1, getAttacker())))) ==
      "When this card is attacked, deal 1 damage to the attacker."

  test "Bubble Shield summons two Trinkets":
    var game = newGame(Mage, Warrior, 1501)
    let me = game.leads(Mage)
    game.players[me].hand = @[baseCard("Bubble Shield", 2)]
    game.players[me].energy = 2
    check game.playCard(0)
    check game.players[me].board.len == 2
    for bubble in game.players[me].board:
      check bubble.card == baseCard("Bubble", 0)
      check bubble.currentToughness == 0
      check bubble.power == 0
    check game.eligibleAttackers().len == 0
    var summons = 0
    for event in game.takeVisualEvents():
      if event.kind == SummonVfx:
        inc summons
    check summons == 2

  test "each attack on your hero pops one Bubble, after the damage":
    var (game, me, enemy) = shieldGame(1503)
    let first = game.players[me].board[0].id
    let second = game.players[me].board[1].id
    check game.attack(50, heroChoice(me))
    check game.players[me].life == StartingLife - 3
    check not game.minionLocation(50).found
    check game.players[enemy].hand[^1] == Warrior.classCard()
    check game.players[me].board.len == 1
    check game.players[me].board[0].id == second
    check not game.minionLocation(first).found
    check game.players[me].discardPile[^1] == baseCard("Bubble", 0)
    check game.attack(51, heroChoice(me))
    check game.players[me].life == StartingLife - 6
    check game.players[me].board.len == 0
    check game.players[enemy].board.len == 0

  test "attacks on your minions don't fire Bubbles":
    var (game, me, _) = shieldGame(1505)
    game.players[me].board.add readyMinion(me, 60, Mage.classCard())
    check game.attack(50, creatureChoice(me, 60))
    check game.players[me].board.len == 2
    check game.minionLocation(50).found

  test "a card's own attacked trigger punishes its attacker":
    let thorns = Card(name: "Thorns", energyCost: 0, kind: Minion,
      rules: rules(on(attacked(self()), damage(1, getAttacker()))),
      power: 1, toughness: 5)
    var game = newGame(Mage, Warrior, 1507)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].board = @[readyMinion(me, 1, thorns)]
    game.nextMinionId = 2
    game.finishTurn()
    game.players[enemy].board = @[readyMinion(enemy, 50, Warrior.classCard())]
    game.nextMinionId = 51
    check game.attack(50, creatureChoice(me, 1))
    # 1 from combat, then 1 from Thorns: the Bear (toughness 2) dies.
    check not game.minionLocation(50).found
    check game.players[me].board[0].currentToughness == 2

  test "a trigger whose attacker died in combat fizzles entirely":
    let spite = Card(name: "Spite", energyCost: 0, kind: Minion,
      rules: rules(on(attacked(self()), damage(1, getAttacker()), draw(1))),
      power: 5, toughness: 5)
    var game = newGame(Mage, Warrior, 1509)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].board = @[readyMinion(me, 1, spite)]
    game.nextMinionId = 2
    game.finishTurn()
    game.players[enemy].board = @[readyMinion(enemy, 50, Warrior.classCard())]
    game.nextMinionId = 51
    let hand = game.players[me].hand.len
    check game.attack(50, creatureChoice(me, 1))
    check not game.minionLocation(50).found
    # The attacker is gone, so the whole trigger fizzles: no draw either.
    check game.players[me].hand.len == hand

suite "AWM gain and lose, Morphosis Chamber and Overwork":
  proc ownerTurn(game: var GameState, me: int) =
    ## Passes turns until `me` begins one, firing its turn-start triggers.
    game.finishTurn()
    while game.currentPlayer != me:
      game.finishTurn()

  proc chamberGame(seed: int64): (GameState, int, int) =
    ## A Mage with Morphosis Chamber in play, a Bear each, at its next turn.
    var game = newGame(Mage, Warrior, seed)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].board = @[
      MinionState(id: 1, owner: me, card: baseCardNamed("Morphosis Chamber"),
        enteredTurn: game.turnNumber),
      readyMinion(me, 2, baseCardNamed("Bear"))]
    game.players[enemy].board = @[readyMinion(enemy, 3, baseCardNamed("Bear"))]
    game.nextMinionId = 4
    game.ownerTurn(me)
    (game, me, enemy)

  test "the new cards read as rules text":
    let chamber = baseCardNamed("Morphosis Chamber")
    check chamber.kind == Trinket and chamber.class == some(Mage)
    check chamber.ruleText() == "On each of your turns, " &
      "choose:\n- A friendly minion gains Ranged.\n" &
      "- A friendly minion gains Hidden 1.\n" &
      "- Give a friendly minion +1/-1.\n- Give a friendly minion -1/+1."
    check baseCardNamed("Overwork").ruleText() == "Lasts 3.\n" &
      "Gain 2 energy.\n" &
      "On each of your turns, gain 2 energy and draw 1 card.\n" &
      "When this card is destroyed, summon a Burnout."
    check Card(kind: Spell, rules: rules(gain(on(eachTurn(You), draw(1)),
      target({kind: {Minion}})))).ruleText() ==
      "A minion gains \"On each of your turns, draw 1 card.\"."
    check Card(kind: Spell, rules: rules(lose(hidden(),
      target({kind: {Minion}})))).ruleText() == "A minion loses Hidden."

  test "Morphosis Chamber asks for a branch, then its target":
    var (game, me, enemy) = chamberGame(3101)
    check game.waitingTrigger
    check game.actingPlayer() == me
    # Like any trigger's pick, the branch may also be declined.
    check game.triggerChoices() == @[optionChoice(0), optionChoice(1),
      optionChoice(2), optionChoice(3), NoTarget]
    # Ranged only goes on a friendly minion.
    check game.triggerChoices(@[optionChoice(0)]) ==
      @[creatureChoice(me, 2), NoTarget]
    check not game.resolvePendingTrigger(
      @[optionChoice(0), creatureChoice(enemy, 3)])
    check game.resolvePendingTrigger(@[optionChoice(0), creatureChoice(me, 2)])
    let bear = game.players[me].board[1]
    check bear.hasKeyword(Ranged)
    check bear.addedKeywords == {Ranged}
    check bear.lostKeywords == {}
    check bear.card == baseCardNamed("Bear")
    check game.choiceLabel(creatureChoice(me, 2)).endsWith("(3/2, Ranged)")
    # Its face adds the gained Ranged after its (empty) printed rules.
    check bear.ruleLines.len == 1
    check bear.ruleLines[0].change == GainedRule
    check bear.ruleLines[0].rule.text(bear.card) == "Ranged"
    check game.players[enemy].board[0].addedKeywords == {}

  test "a gained Ranged takes no damage back from a minion without it":
    var (game, me, enemy) = chamberGame(3103)
    check game.resolvePendingTrigger(@[optionChoice(0), creatureChoice(me, 2)])
    check game.attack(2, creatureChoice(enemy, 3))
    check not game.minionLocation(3).found
    check game.players[me].board[1].currentToughness == 2

  test "a gained Hidden 1 lasts until the start of its owner's next turn":
    var (game, me, enemy) = chamberGame(3105)
    check game.resolvePendingTrigger(@[optionChoice(1), creatureChoice(me, 2)])
    check game.players[me].board[1].hiddenTurns == 1
    game.finishTurn()
    check game.currentPlayer == enemy
    check creatureChoice(me, 2) notin game.attackTargets(3)
    game.finishTurn()
    check game.players[me].board[1].hiddenTurns == 0
    # A longer hiding stands: Spirit stays hidden for good.
    game.players[me].board.add readyMinion(me, 4, baseCardNamed("Spirit"))
    game.players[me].board[2].hiddenTurns = Always
    game.nextMinionId = 5
    check game.resolvePendingTrigger(@[optionChoice(1), creatureChoice(me, 4)])
    check game.players[me].board[2].hiddenTurns == Always

  test "the stat swaps reshape a friendly minion, and +1/-1 can kill it":
    var (game, me, enemy) = chamberGame(3107)
    game.players[me].board.add readyMinion(me, 4, baseCardNamed("Sniper"))
    game.nextMinionId = 5
    # Not an enemy's: these are no longer removal.
    check not game.resolvePendingTrigger(
      @[optionChoice(2), creatureChoice(enemy, 3)])
    check game.resolvePendingTrigger(@[optionChoice(2), creatureChoice(me, 4)])
    check not game.minionLocation(4).found
    game.ownerTurn(me)
    check game.resolvePendingTrigger(@[optionChoice(3), creatureChoice(me, 2)])
    check game.players[me].board[1].power == 2
    check game.players[me].board[1].currentToughness == 3
    # Hidden 1 too goes only on a friendly minion.
    game.ownerTurn(me)
    check not game.resolvePendingTrigger(
      @[optionChoice(1), creatureChoice(enemy, 3)])
    check game.players[enemy].board[0].hiddenTurns == 0
    check game.resolvePendingTrigger(@[optionChoice(1), creatureChoice(me, 2)])
    check game.players[me].board[1].hiddenTurns == 1

  test "a trigger's choice may be declined, and the rest still resolves":
    var (game, me, enemy) = chamberGame(3108)
    check game.resolvePendingTrigger(@[NoTarget])
    check not game.waitingTrigger
    check game.players[enemy].board[0].addedKeywords == {}
    # Declining skips only the choice: the trigger's other rules run.
    let fickle = Card(name: "Fickle", energyCost: 0, kind: Trinket,
      class: some(Mage), rules: rules(on(eachTurn(You), draw(1),
        choose(draw(1), damage(1, target({kind: {Minion}}))))))
    game.players[me].board.add MinionState(id: 4, owner: me, card: fickle,
      enteredTurn: game.turnNumber)
    game.nextMinionId = 5
    game.ownerTurn(me)
    check game.resolvePendingTrigger(@[NoTarget])  # Morphosis Chamber's.
    let hand = game.players[me].hand.len
    check game.resolvePendingTrigger(@[NoTarget])  # Fickle's.
    check game.players[me].hand.len == hand + 1
    # A spell's choice is still all or nothing: declining it plays nothing.
    game.players[me].hand = @[baseCardNamed("Overcharge")]
    game.players[me].energy = 10
    check not game.playCard(0, @[NoTarget])
    check game.players[me].hand.len == 1

  test "a minion with nothing to aim at still takes the branch":
    var (game, me, enemy) = chamberGame(3109)
    game.players[me].board.setLen(1)
    game.players[enemy].board.setLen(0)
    check game.resolvePendingTrigger(@[optionChoice(0), NoTarget])
    check not game.waitingTrigger

  test "gaining a keyword back undoes its loss, and losing undoes a gain":
    let
      strip = Card(name: "Strip", energyCost: 0, kind: Spell, class: some(Mage),
        rules: rules(lose(ranged(), target({kind: {Minion}}))))
      grant = Card(name: "Grant", energyCost: 0, kind: Spell, class: some(Mage),
        rules: rules(gain(ranged(), target({kind: {Minion}}))))
    var game = newGame(Mage, Warrior, 3111)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[enemy].board = @[readyMinion(enemy, 1, baseCardNamed("Sniper")),
      readyMinion(enemy, 2, baseCardNamed("Bear"))]
    game.nextMinionId = 3
    game.players[me].hand = @[strip, grant, strip, grant]
    check game.playCard(0, @[creatureChoice(enemy, 1)])
    check game.players[enemy].board[0].lostKeywords == {Ranged}
    check game.playCard(0, @[creatureChoice(enemy, 1)])
    check game.players[enemy].board[0].hasKeyword(Ranged)
    check game.players[enemy].board[0].lostRules.len == 0
    # Ranged was printed, so gaining it adds no second copy.
    check game.players[enemy].board[0].gainedRules.len == 0
    check game.playCard(1, @[creatureChoice(enemy, 2)])
    check game.players[enemy].board[1].addedKeywords == {Ranged}
    check game.playCard(0, @[creatureChoice(enemy, 2)])
    check not game.players[enemy].board[1].hasKeyword(Ranged)
    check game.players[enemy].board[1].addedKeywords == {}
    check game.players[enemy].board[1].lostKeywords == {}

  test "any rule can be gained and lost: a trigger fires while held":
    let
      blessing = on(eachTurn(You), draw(1))
      bless = Card(name: "Bless", energyCost: 0, kind: Spell, class: some(Mage),
        rules: rules(gain(blessing, target({kind: {Minion}}))))
      curse = Card(name: "Curse", energyCost: 0, kind: Spell, class: some(Mage),
        rules: rules(lose(on(eachTurn(You), draw(1)),
          target({kind: {Minion}}))))
    var game = newGame(Mage, Warrior, 3113)
    let me = game.leads(Mage)
    game.players[me].board = @[readyMinion(me, 1, baseCardNamed("Bear"))]
    game.nextMinionId = 2
    game.players[me].hand = @[bless, curse]
    check game.playCard(0, @[creatureChoice(me, 1)])
    check game.players[me].board[0].liveRules == @[blessing]
    var hand = game.players[me].hand.len
    game.ownerTurn(me)
    check game.players[me].hand.len == hand + 2  # Its draw and the Bear's.
    # Losing a rule that prints the same takes it away.
    check game.playCard(0, @[creatureChoice(me, 1)])
    check game.players[me].board[0].liveRules.len == 0
    hand = game.players[me].hand.len
    game.ownerTurn(me)
    check game.players[me].hand.len == hand + 1

  test "losing Hidden ends any hiding, and a class card can lose its level":
    let
      reveal = Card(name: "Reveal", energyCost: 0, kind: Spell,
        class: some(Warrior), rules: rules(lose(hidden(),
          target({kind: {Minion, Trinket}}))))
      unlearn = Card(name: "Unlearn", energyCost: 0, kind: Spell,
        class: some(Warrior), rules: rules(lose(levelUp(1, Archer),
          target({kind: {Minion, Trinket}}))))
    var game = newGame(Warrior, Mage, 3115)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
    game.players[enemy].board = @[readyMinion(enemy, 1, baseCardNamed("Spirit")),
      MinionState(id: 2, owner: enemy, card: baseCardNamed("Archer"))]
    game.players[enemy].board[0].hiddenTurns = Always
    game.players[me].board = @[readyMinion(me, 3, baseCardNamed("Bear"))]
    game.nextMinionId = 4
    check game.levels(enemy, Archer) == 1
    game.players[me].hand = @[reveal, unlearn]
    check game.playCard(0, @[creatureChoice(enemy, 1)])
    check game.players[enemy].board[0].hiddenTurns == 0
    check creatureChoice(enemy, 1) in game.attackTargets(3)
    check game.playCard(0, @[creatureChoice(enemy, 2)])
    check game.levels(enemy, Archer) == 0

suite "AWM gainControl and Control":
  proc controlGame(seed: int64): (GameState, int, int) =
    ## A Mage with Control in hand, and a wounded, buffed enemy Bear.
    var game = newGame(Mage, Warrior, seed)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].hand = @[baseCardNamed("Control")]
    game.players[me].energy = 5
    game.players[me].board = @[readyMinion(me, 1, baseCardNamed("Footsoldier"))]
    game.players[enemy].board = @[readyMinion(enemy, 2, baseCardNamed("Bear")),
      readyMinion(enemy, 3, baseCardNamed("Sniper"))]
    game.players[enemy].board[0].currentToughness = 1
    game.players[enemy].board[0].bonusPower = 1
    game.nextMinionId = 4
    (game, me, enemy)

  test "Control reads as rules text and aims at enemy minions only":
    let control = baseCardNamed("Control")
    check control.kind == Spell and control.energyCost == 5
    check control.ruleText() == "Gain control of an enemy minion."
    check control.intent(0) == GainControlIntent
    var (game, me, enemy) = controlGame(4001)
    check game.availableChoices(0) ==
      @[creatureChoice(enemy, 2), creatureChoice(enemy, 3)]
    # With nothing to take, it can't be cast and costs nothing.
    game.players[enemy].board.setLen(0)
    check game.availableChoices(0).len == 0
    check not game.playCard(0, @[NoTarget])
    check game.players[me].energy == 5

  test "a stolen minion joins your board as it was, and waits a turn":
    var (game, me, enemy) = controlGame(4003)
    check game.playCard(0, @[creatureChoice(enemy, 2)])
    check game.players[enemy].board.len == 1
    check game.players[me].board.len == 2
    let bear = game.players[me].board[1]
    check bear.id == 2 and bear.owner == me
    check bear.stolenFrom == some(enemy)
    check bear.home == enemy
    check bear.currentToughness == 1 and bear.power == 4
    check game.attackTargets(2).len == 0
    var stolen = false
    for event in game.visualEvents:
      if event.kind == GainControlVfx:
        stolen = true
        check event.target == creatureChoice(me, 2)
        check event.fromPlayer == enemy
        check event.boardIndex == 0
    check stolen
    game.finishTurn()
    game.finishTurn()
    check creatureChoice(enemy, 3) in game.attackTargets(2)

  test "a stolen Ready minion attacks for you at once":
    var (game, me, enemy) = controlGame(4004)
    # The Sniper gained Ready, and swung on its owner's last turn.
    game.players[enemy].board[1].gainedRules = @[Rule(ready())]
    game.players[enemy].board[1].hasAttacked = true
    check game.playCard(0, @[creatureChoice(enemy, 3)])
    check heroChoice(enemy) in game.attackTargets(3)
    let life = game.players[enemy].life
    check game.attack(3, heroChoice(enemy))
    check game.players[enemy].life == life - 2

  test "bounced or slain, a stolen minion goes back to its owner":
    var (game, me, enemy) = controlGame(4005)
    check game.playCard(0, @[creatureChoice(enemy, 2)])
    let enemyHand = game.players[enemy].hand.len
    game.players[me].hand = @[baseCardNamed("Bouncer")]
    game.players[me].energy = 1
    check game.playCard(0, @[creatureChoice(me, 2)])
    check game.players[enemy].hand.len == enemyHand + 1
    check game.players[enemy].hand[^1] == baseCardNamed("Bear")
    for event in game.visualEvents:
      if event.kind == BounceVfx:
        check event.home == some(enemy)
    # A slain one goes to its owner's discard pile.
    var (other, mine, theirs) = controlGame(4007)
    check other.playCard(0, @[creatureChoice(theirs, 2)])
    let pile = other.players[theirs].discardPile.len
    other.players[mine].hand = @[baseCardNamed("Bolt")]
    other.players[mine].hand = @[Card(name: "Zap", energyCost: 0, kind: Spell,
      class: some(Mage), rules: rules(damage(1, target({kind: {Minion}}))))]
    check other.playCard(0, @[creatureChoice(mine, 2)])
    check other.players[theirs].discardPile.len == pile + 1
    check other.players[theirs].discardPile[^1] == baseCardNamed("Bear")

  test "stolen back by its owner, it is simply theirs again":
    var (game, me, enemy) = controlGame(4009)
    check game.playCard(0, @[creatureChoice(enemy, 2)])
    let grab = Card(name: "Grab", energyCost: 0, kind: Spell,
      class: some(Warrior),
      rules: rules(gainControl(You,
        target({kind: {Minion}, owner: AllOpponents}))))
    game.finishTurn()
    check game.currentPlayer == enemy
    game.players[enemy].hand = @[grab]
    check game.playCard(0, @[creatureChoice(me, 2)])
    let bear = game.players[enemy].board[^1]
    check bear.id == 2 and bear.owner == enemy
    check bear.stolenFrom == none(int)

  test "a stolen minion's triggers fire for its new controller":
    let drummer = Card(name: "Drummer", energyCost: 0, kind: Minion,
      class: some(Warrior), rules: rules(on(eachTurn(You), draw(1))),
      power: 1, toughness: 1)
    var (game, me, enemy) = controlGame(4011)
    game.players[enemy].board = @[MinionState(id: 2, owner: enemy,
      card: drummer, currentToughness: 1, enteredTurn: 0)]
    check game.playCard(0, @[creatureChoice(enemy, 2)])
    let enemyHand = game.players[enemy].hand.len
    game.finishTurn()
    check game.players[enemy].hand.len == enemyHand + 1  # Its own draw only.
    let hand = game.players[me].hand.len
    game.finishTurn()
    check game.players[me].hand.len == hand + 2

suite "AWM Gift":
  proc giftGame(seed: int64): (GameState, int, int) =
    ## An Archer with Gift in hand, a Sniper and a trinket that draws as each
    ## of its controller's turns ends.
    var game = newGame(Archer, Warrior, seed)
    let
      me = game.leads(Archer)
      enemy = 1 - me
      tick = Card(name: "Tick", energyCost: 0, class: some(Archer),
        kind: Trinket, rules: rules(on(eachEndOfTurn(You), draw(1))))
    game.players[me].hand = @[baseCardNamed("Gift")]
    game.players[me].energy = 3
    game.players[me].board = @[readyMinion(me, 1, baseCardNamed("Sniper")),
      MinionState(id: 2, owner: me, card: tick, enteredTurn: game.turnNumber)]
    game.players[enemy].board = @[readyMinion(enemy, 3, baseCardNamed("Bear"))]
    game.nextMinionId = 4
    (game, me, enemy)

  test "Gift reads as rules text and asks for a hero, then a card of yours":
    let gift = baseCardNamed("Gift")
    check gift.kind == Spell and gift.class == some(Archer)
    check gift.energyCost == 3
    check gift.ruleText() ==
      "A hero gains control of a friendly minion or trinket."
    check gift.targetCount() == 2
    check gift.targetPrompt(0).choose == "Choose a hero."
    var (game, me, enemy) = giftGame(4101)
    let heroes = game.availableChoices(0)
    check heroes.len == 2
    check heroChoice(me) in heroes and heroChoice(enemy) in heroes
    check game.availableChoices(0, @[heroChoice(enemy)]) ==
      @[creatureChoice(me, 1), creatureChoice(me, 2)]

  test "the gift joins the picked hero's board, still its giver's card":
    var (game, me, enemy) = giftGame(4103)
    check game.playCard(0, @[heroChoice(enemy), creatureChoice(me, 1)])
    check game.players[me].energy == 0
    check game.players[me].board.len == 1
    let sniper = game.players[enemy].board[^1]
    check sniper.id == 1 and sniper.owner == enemy
    check sniper.stolenFrom == some(me)
    var wrapped, moved = false
    for event in game.visualEvents:
      if event.kind == PrizeVfx:
        wrapped = true
        check event.target == creatureChoice(me, 1)
      elif event.kind == GainControlVfx:
        moved = true
        check event.target == creatureChoice(enemy, 1)
        check event.fromPlayer == me
    check wrapped and moved

  test "a gifted trinket's triggers fire for its new controller":
    var (game, me, enemy) = giftGame(4105)
    check game.playCard(0, @[heroChoice(enemy), creatureChoice(me, 2)])
    let hand = game.players[me].hand.len
    game.finishTurn()
    check game.players[me].hand.len == hand
    let enemyHand = game.players[enemy].hand.len
    game.finishTurn()
    check game.players[enemy].hand.len == enemyHand + 1

  test "a canceled pick costs nothing, and a gift to yourself changes nothing":
    var (game, me, enemy) = giftGame(4107)
    check not game.playCard(0, @[Canceled])
    check not game.playCard(0, @[heroChoice(enemy), Canceled])
    check game.players[me].energy == 3
    check game.players[me].hand.len == 1
    check game.takeVisualEvents().len == 0
    # Your own hero is a hero too: the card stays where it is.
    check game.playCard(0, @[heroChoice(me), creatureChoice(me, 1)])
    check game.players[me].board.len == 2
    check game.players[me].board[0].stolenFrom == none(int)

suite "AWM rule explanations":
  test "a card explains the mechanics its rules print, in reading order":
    check baseCardNamed("Spirit").mechanics() ==
      @[HiddenMechanic, RangedMechanic]
    check baseCardNamed("Sharpshooter").mechanics() == @[RangedMechanic]
    check baseCardNamed("Summon Primordial").mechanics() == @[SummonMechanic]
    check baseCardNamed("Control").mechanics() == @[GainControlMechanic]
    check baseCardNamed("Archer").mechanics() == @[OffClassMechanic]

  test "mechanics nested in choices, triggers and gained or lost rules count":
    check baseCardNamed("Morphosis Chamber").mechanics() ==
      @[RangedMechanic, HiddenMechanic]
    check baseCardNamed("Duel").mechanics() == @[RangedMechanic, FightMechanic]
    check baseCardNamed("Banner").mechanics() == @[SummonMechanic]

  test "plain verbs explain themselves":
    for name in ["Bolt", "Overcharge", "Hail of Arrows", "Explode", "Swords",
        "Wildfire", "Study", "Plan", "Bear", "Bouncer", "Bubble",
        "Reload"]:
      check baseCardNamed(name).mechanics().len == 0

  test "a keyword gained in play is explained after the printed ones":
    check baseCardNamed("Bear").mechanics({Ranged}) == @[RangedMechanic]
    check baseCardNamed("Sniper").mechanics({Ranged}) == @[RangedMechanic]

  test "every mechanic has an explanation and a base card that prints it":
    var printed: set[Mechanic]
    for card in baseCards:
      for mechanic in card.mechanics():
        printed.incl mechanic
    for mechanic in Mechanic:
      check Explanations[mechanic].len > 0
      check mechanic in printed

suite "rule lines":
  test "a card in play as printed has none":
    check MinionState(card: baseCard("Sniper", 2)).ruleLines.len == 0

  test "printed rules come first, kept or lost, then the gained ones":
    let
      card = baseCard("Sharpshooter", 3)
      gained = hidden(1)
      minion = MinionState(card: card, gainedRules: @[gained],
        lostRules: @[Rule(ranged())])
    check minion.ruleLines == @[
      RuleLine(rule: card.rules[0], change: LostRule),
      RuleLine(rule: card.rules[1], change: KeptRule),
      RuleLine(rule: gained, change: GainedRule)]

  test "losing a rule it never had changes nothing":
    check MinionState(card: baseCard("Bear", 2),
      lostRules: @[Rule(ranged())]).ruleLines.len == 0

  test "a gained rule lost again leaves the printed rules":
    let gained = hidden(1)
    check MinionState(card: baseCard("Bear", 2), gainedRules: @[gained],
      lostRules: @[gained]).ruleLines.len == 0

suite "AWM number filters":
  test "number filters read as rules text":
    check target({kind: {Minion}, energyCost: atMost(3)}).text() ==
      "a minion that costs 3 or less"
    check target({kind: {Minion}, energyCost: eq(2)}).text() ==
      "a minion that costs 2"
    check target({kind: {Minion}, owner: AllOpponents,
      energyCost: notEq(2)}).text() == "an enemy minion that doesn't cost 2"
    check target({kind: {Minion}, power: atLeast(3)}).text() ==
      "a minion with power 3 or more"
    check target({kind: {Minion}, toughness: between(2, 4)}).text() ==
      "a minion with toughness 2 to 4"
    check target({kind: {Minion}, power: notEq(0)}).text() ==
      "a minion with power other than 0"
    check Card(kind: Spell, rules: rules(damage(1, game.board.getCards(
      {kind: {Minion}, owner: AllOpponents, energyCost: atMost(2)})))
      ).ruleText() == "Deal 1 damage to all enemy minions that cost 2 or less."
    check Card(kind: Spell, rules: rules(destroy(target({kind: {Minion},
      energyCost: atLeast(5), power: atLeast(4)})))).ruleText() ==
      "Destroy a minion that costs 5 or more and with power 4 or more."

  test "a target offers only the cards that meet its numbers, never a hero":
    var game = newGame(Archer, Warrior, 3301)
    let
      me = game.leads(Archer)
      enemy = 1 - me
    game.players[enemy].board = @[
      readyMinion(enemy, 1, baseCard("footsoldier-1")),
      readyMinion(enemy, 2, baseCard("bear-2")),
      readyMinion(enemy, 3, baseCard("commander-5"))]
    game.nextMinionId = 4
    game.players[me].hand = @[Card(name: "Snipe", energyCost: 0, kind: Spell,
      rules: rules(damage(1, target({kind: {Minion, Hero},
        energyCost: atMost(2)}))))]
    check game.availableChoices(0) ==
      @[creatureChoice(enemy, 1), creatureChoice(enemy, 2)]

  test "power and toughness read a minion's live stats":
    var game = newGame(Warrior, Archer, 3303)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
    var
      bear = readyMinion(enemy, 1, baseCard("bear-2"))
      footsoldier = readyMinion(enemy, 2, baseCard("footsoldier-1"))
    bear.bonusPower = 1  # 4/2 now
    footsoldier.currentToughness = 1  # hurt: 1/1
    game.players[enemy].board = @[bear, footsoldier]
    game.nextMinionId = 3
    game.players[me].hand = @[
      Card(name: "Cull", energyCost: 0, kind: Spell, rules: rules(destroy(
        game.board.getCards({kind: {Minion}, toughness: atMost(1)})))),
      Card(name: "Fell", energyCost: 0, kind: Spell, rules: rules(destroy(
        target({kind: {Minion}, power: atLeast(4)}))))]
    check game.availableChoices(1) == @[creatureChoice(enemy, 1)]
    check game.playCard(0)
    check game.players[enemy].board.len == 1
    check game.players[enemy].board[0].id == 1

  test "every bound is inclusive, and only minions have power or toughness":
    let context = RuleContext()
    check @[statFilter(CostStat, between(2, 3))].meets(
      baseCard("sniper-2"), 2, 1, context)
    check @[statFilter(CostStat, between(2, 3))].meets(
      baseCard("sharpshooter-3"), 3, 1, context)
    check not @[statFilter(CostStat, between(2, 3))].meets(
      baseCard("bolt-1"), 0, 0, context)
    check @[statFilter(CostStat, atMost(1))].meets(
      baseCard("bolt-1"), 0, 0, context)
    check @[statFilter(CostStat, notEq(3))].meets(
      baseCard("bolt-1"), 0, 0, context)
    check not @[statFilter(PowerStat, atLeast(0))].meets(
      baseCard("bolt-1"), 0, 0, context)
    check not @[statFilter(ToughnessStat, atMost(9))].meets(
      baseCard("banner-3"), 0, 0, context)

suite "AWM Lasts":
  let tent = Card(name: "Tent", energyCost: 0, kind: Trinket,
    rules: rules(lasts(2)))

  test "lasts prints its count":
    check tent.ruleText() == "Lasts 2."
    check tent.lastsTurns() == 2
    check baseCard("bear-2").lastsTurns() == 0
    check Card(kind: Spell, rules: rules(gain(lasts(1),
      target({kind: {Minion}})))).ruleText() == "A minion gains Lasts 1."

  test "a lasting card leaves as its owner's Nth turn from now starts":
    var game = newGame(Archer, Warrior, 3311)
    let me = game.leads(Archer)
    game.players[me].hand = @[tent]
    check game.playCard(0)
    check game.players[me].board[0].lastsTurns == 2
    game.finishTurn()  # the opponent's turn counts nothing
    check game.players[me].board[0].lastsTurns == 2
    game.finishTurn()  # its owner's next turn: one to go
    check game.players[me].board.len == 1
    check game.players[me].board[0].lastsTurns == 1
    game.finishTurn()
    game.finishTurn()  # its owner's second turn from now: gone
    check game.players[me].board.len == 0
    check game.players[me].discardPile[^1].name == "Tent"
    var died = false
    for event in game.visualEvents:
      if event.kind == DeathVfx and event.card.name == "Tent":
        died = true
    check died

  test "it leaves before that turn's triggers":
    let lantern = Card(name: "Lantern", energyCost: 0, kind: Trinket,
      rules: rules(lasts(1), on(eachTurn(You), draw(1))))
    var game = newGame(Archer, Warrior, 3313)
    let me = game.leads(Archer)
    game.players[me].hand = @[lantern]
    check game.playCard(0)
    game.finishTurn()
    let before = game.players[me].hand.len
    game.finishTurn()  # its owner's turn: only the turn's own draw
    check game.players[me].board.len == 0
    check game.players[me].hand.len == before + 1

  test "gaining Lasts starts a count, and losing it stops one":
    var game = newGame(Archer, Warrior, 3315)
    let me = game.leads(Archer)
    game.players[me].board = @[
      readyMinion(me, 1, baseCard("bear-2")),
      MinionState(id: 2, owner: me, card: tent, lastsTurns: 2,
        enteredTurn: game.turnNumber)]
    game.nextMinionId = 3
    game.players[me].hand = @[
      Card(name: "Mark", energyCost: 0, kind: Spell,
        rules: rules(gain(lasts(1), target({kind: {Minion}})))),
      Card(name: "Stake", energyCost: 0, kind: Spell,
        rules: rules(lose(lasts(1), target({kind: {Trinket}}))))]
    check game.playCard(0, creatureChoice(me, 1))
    check game.players[me].board[0].lastsTurns == 1
    check game.playCard(0, creatureChoice(me, 2))
    check game.players[me].board[1].lastsTurns == 0
    for turn in 0 ..< 4:
      game.finishTurn()
    # The Bear ran out on its owner's next turn; the Tent no longer counts.
    check game.players[me].board.len == 1
    check game.players[me].board[0].card.name == "Tent"

suite "AWM played triggers":
  # Twin plays like Post, but its numbers are this suite's: tuning Post
  # moves nothing here.
  let twin = Card(name: "Twin", energyCost: 1, class: some(Archer),
    kind: Trinket, rules: rules(
      lasts(3),
      on(played(You, {kind: {Minion}, class: {Archer}, energyCost: atMost(3)}),
        gain(ready(), getPlayed()),
        summon(1, getPlayed()))))

  proc twinGame(seed: int64): (GameState, int, int) =
    ## The Archer's turn with Twin in play and energy to spare.
    var game = newGame(Archer, Warrior, seed)
    let
      me = game.leads(Archer)
      enemy = 1 - me
    game.players[me].board = @[MinionState(id: 1, owner: me, card: twin,
      enteredTurn: game.turnNumber, lastsTurns: twin.lastsTurns())]
    game.nextMinionId = 2
    game.players[me].energy = 20
    (game, me, enemy)

  test "a trigger that readies and copies cheap Archer minions prints so":
    check twin.lastsTurns() == 3
    check twin.ruleText() == "Lasts 3.\n" &
      "When you play an Archer minion that costs 3 or less, it gains Ready, " &
      "summon a copy of it."
    check twin.mechanics() == @[LastsMechanic, ReadyMechanic, SummonMechanic]

  test "trigger parts join with and while all are orders, else with commas":
    check Card(kind: Trinket, rules: rules(on(eachTurn(You), draw(1),
      damage(1, You)))).ruleText() ==
      "On each of your turns, draw 1 card and deal 1 damage " &
      "to yourself."
    check Card(kind: Trinket, rules: rules(on(eachTurn(You),
      gain(ranged(), target({kind: {Minion}})), draw(1)))).ruleText() ==
      "On each of your turns, a minion gains Ranged, " &
      "draw 1 card."

  test "a cheap Archer minion enters Ready, with a Ready copy":
    var (game, me, enemy) = twinGame(3321)
    game.players[me].hand = @[baseCard("sniper-2")]
    check game.playCard(0)
    check game.players[me].board.len == 3
    check game.players[me].board[1].card.name == "Sniper"
    check game.players[me].board[2].card.name == "Sniper"
    check game.players[me].board[1].id != game.players[me].board[2].id
    check not game.waitingTrigger
    # Both gained Ready, so both swing the turn they came in.
    for slot in 1 .. 2:
      check game.players[me].board[slot].hasKeyword(Ready)
      check game.attack(game.players[me].board[slot].id, heroChoice(enemy))
    check game.players[enemy].life == StartingLife - 4

  test "a card the table plays in two steps fires played triggers too":
    # The table puts a minion in play first, to aim its rules on the board,
    # then plays it out (`finishPlay`): how a human plays one.
    var (game, me, _) = twinGame(3329)
    game.players[me].hand = @[baseCard("sniper-2")]
    let id = game.playMinion(0)
    check id != 0
    check game.finishPlay(baseCard("sniper-2"), @[NoTarget], id)
    check game.players[me].board.len == 3
    check game.players[me].board[2].card.name == "Sniper"
    check game.players[me].board[1].hasKeyword(Ready)

  test "the copy runs its own on-play rules, aimed afresh":
    var (game, me, enemy) = twinGame(3323)
    game.players[me].hand = @[baseCard("sharpshooter-3")]
    let life = game.players[enemy].life
    check game.playCard(0, heroChoice(enemy))
    check game.players[enemy].life == life - 1
    # Like any summoned card's rule, the copy's shot waits for its owner.
    check game.waitingTrigger
    check game.actingPlayer() == me
    check game.waitingTriggerName() == "Sharpshooter's rule"
    check game.resolvePendingTrigger(@[heroChoice(enemy)])
    check game.players[enemy].life == life - 2
    check game.players[me].board.len == 3

  test "expensive, off-class, spells and opponents' plays make no copy":
    var (game, me, enemy) = twinGame(3325)
    game.players[me].hand = @[baseCard("assassin-6"), baseCard("bolt-1"),
      baseCard("bear-2")]
    check game.playCard(0)
    check game.players[me].board.len == 2
    check not game.players[me].board[1].hasKeyword(Ready)
    check game.playCard(0, heroChoice(enemy))
    check game.players[me].board.len == 2
    # A Warrior Bear costs 2, but Twin only copies Archer cards.
    check game.playCard(0)
    check game.players[me].board.len == 3
    check not game.players[me].board[2].hasKeyword(Ready)
    game.finishTurn()
    game.players[enemy].hand = @[baseCard("footsoldier-1")]
    game.players[enemy].energy = 1
    check game.playCard(0)
    check game.players[enemy].board.len == 1

  test "two copiers make two copies, and copies are never copied":
    var (game, me, _) = twinGame(3327)
    game.players[me].board.add MinionState(id: 2, owner: me, card: twin,
      enteredTurn: game.turnNumber, lastsTurns: twin.lastsTurns())
    game.nextMinionId = 3
    game.players[me].hand = @[baseCard("ambusher-3")]
    check game.playCard(0)
    var ambushers = 0
    for minion in game.players[me].board:
      if minion.card.name == "Ambusher":
        inc ambushers
        check minion.hiddenTurns == 1
    check ambushers == 3

  test "a copy enters as its original is: buffs, gained rules and all":
    # Drill sits before Twin, so its buff lands on the played minion first.
    let drill = Card(name: "Drill", energyCost: 0, kind: Trinket,
      rules: rules(on(played(You, {kind: {Minion}}),
        addPowerToughness(1, 1, getPlayed()))))
    check drill.ruleText() == "When you play a minion, give it +1/+1."
    var (game, me, _) = twinGame(3335)
    game.players[me].board.insert(MinionState(id: 2, owner: me, card: drill,
      enteredTurn: game.turnNumber), 0)
    game.nextMinionId = 3
    game.players[me].hand = @[baseCard("sniper-2")]
    check game.playCard(0)
    let
      original = game.players[me].board[2]
      copy = game.players[me].board[3]
    check original.power == 3 and original.currentToughness == 2
    check copy.card == original.card
    check copy.power == 3 and copy.currentToughness == 2
    check copy.hasKeyword(Ready) and copy.canAttack
    # Drill doesn't buff the copy: a summon isn't played.
    check copy.bonusPower == 1

  test "a bounced copy goes back to its owner's hand as a card":
    var (game, me, enemy) = twinGame(3329)
    game.players[me].hand = @[baseCard("sniper-2")]
    check game.playCard(0)
    let copy = game.players[me].board[2].id
    game.finishTurn()
    game.players[enemy].hand = @[baseCard("bouncer-1")]
    game.players[enemy].energy = 9
    check game.playCard(0, creatureChoice(me, copy))
    check game.players[me].hand[^1].name == "Sniper"

  test "a card's own play doesn't fire its triggers; later plays do":
    let echo = Card(name: "Echo", energyCost: 0, kind: Trinket,
      rules: rules(on(played(You, {}), draw(1))))
    check echo.ruleText() == "When you play a card, draw 1 card."
    var game = newGame(Archer, Warrior, 3331)
    let me = game.leads(Archer)
    game.players[me].hand = @[echo, Card(name: "Spark", energyCost: 0,
      kind: Spell, rules: rules(damage(1, You)))]
    check game.playCard(0)
    check game.players[me].hand.len == 1
    check game.playCard(0)  # Spark goes, and Echo draws once it resolves
    check game.players[me].hand.len == 1

  test "played(AnyOpponent) watches every opponent":
    let spy = Card(name: "Spy", energyCost: 0, kind: Trinket,
      rules: rules(on(played(AnyOpponent, {kind: {Spell}}), draw(1))))
    check spy.ruleText() == "When an opponent plays a spell, draw 1 card."
    var game = newGame(Archer, Warrior, 3333)
    let
      me = game.leads(Archer)
      enemy = 1 - me
    game.players[me].board = @[MinionState(id: 1, owner: me, card: spy,
      enteredTurn: game.turnNumber)]
    game.nextMinionId = 2
    game.finishTurn()
    let hand = game.players[me].hand.len
    game.players[enemy].hand = @[baseCard("swords-2")]
    game.players[enemy].energy = 2
    check game.playCard(0)
    check game.players[me].hand.len == hand + 1

suite "AWM Ready":
  let raider = Card(name: "Raider", energyCost: 0, kind: Minion,
    rules: rules(ready()), power: 2, toughness: 1)

  test "Ready prints as a keyword and is explained":
    check raider.ruleText() == "Ready"
    check raider.mechanics() == @[ReadyMechanic]
    check Explanations[ReadyMechanic].len > 0

  test "a Ready minion attacks the turn it is played or summoned":
    var game = newGame(Archer, Warrior, 3341)
    let
      me = game.leads(Archer)
      enemy = 1 - me
    game.players[me].hand = @[raider, Card(name: "Call", energyCost: 0,
      kind: Spell, rules: rules(summon(1,
        RuleValue[Card](kind: FixedValue, fixed: raider))))]
    check game.playCard(0)
    check game.playCard(0)
    for minion in game.players[me].board:
      check minion.canAttack
      check game.attack(minion.id, heroChoice(enemy))
    check game.players[enemy].life == StartingLife - 4

  test "gaining Ready readies a fresh minion; it doesn't give back an attack":
    var game = newGame(Warrior, Archer, 3343)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
    let rally = Card(name: "Hurry", energyCost: 0, kind: Spell,
      rules: rules(gain(ready(), target({kind: {Minion}, owner: You}))))
    game.players[me].hand = @[baseCard("bear-2"), rally, rally]
    game.players[me].energy = 2
    check game.playCard(0)
    let bear = game.players[me].board[0].id
    check not game.attack(bear, heroChoice(enemy))
    check game.playCard(0, creatureChoice(me, bear))
    check game.attack(bear, heroChoice(enemy))
    check game.playCard(0, creatureChoice(me, bear))
    check not game.attack(bear, heroChoice(enemy))
    check game.players[enemy].life == StartingLife - 3

  test "losing Ready the turn it entered takes back that turn's attack":
    var game = newGame(Archer, Warrior, 3345)
    let
      me = game.leads(Archer)
      enemy = 1 - me
    game.players[me].hand = @[raider, Card(name: "Slow", energyCost: 0,
      kind: Spell, rules: rules(lose(ready(), target({kind: {Minion}}))))]
    check game.playCard(0)
    let id = game.players[me].board[0].id
    check game.playCard(0, creatureChoice(me, id))
    check not game.attack(id, heroChoice(enemy))

suite "AWM class filters":
  test "a class filter reads as an adjective":
    check target({kind: {Minion}, class: {Archer}}).text() ==
      "an Archer minion"
    check target({kind: {Minion}, owner: You, class: {Warrior}}).text() ==
      "a friendly Warrior minion"
    check target({kind: {Minion}, class: {Warrior, Mage},
      energyCost: atMost(2)}).text() ==
      "a Warrior or Mage minion that costs 2 or less"
    check Card(kind: Spell, rules: rules(damage(1, game.board.getCards(
      {kind: {Minion}, owner: AllOpponents, class: {Archer}})))).ruleText() ==
      "Deal 1 damage to all enemy Archer minions."

  test "it picks only cards of those classes, never a hero or class card":
    var game = newGame(Warrior, Archer, 3351)
    let
      me = game.leads(Warrior)
      enemy = 1 - me
    let classCard = MinionState(id: 3, owner: enemy,
      card: baseCardNamed("Archer"), enteredTurn: game.turnNumber)
    game.players[enemy].board = @[
      readyMinion(enemy, 1, baseCard("sniper-2")),
      readyMinion(enemy, 2, baseCard("bear-2")), classCard]
    game.nextMinionId = 4
    game.players[me].hand = @[
      Card(name: "Hunt", energyCost: 0, kind: Spell, rules: rules(damage(1,
        target({kind: {Minion, Hero, Trinket}, class: {Archer}})))),
      Card(name: "Purge", energyCost: 0, kind: Spell, rules: rules(destroy(
        game.board.getCards({class: {Archer}}))))]
    check game.availableChoices(0) == @[creatureChoice(enemy, 1)]
    check game.playCard(1)
    check game.players[enemy].board.len == 2
    check game.players[enemy].board[0].id == 2

suite "AWM Overwork and Burnout":
  proc overworkGame(seed: int64): (GameState, int, int) =
    ## The Mage's turn with Overwork in hand and 6 energy.
    var game = newGame(Mage, Warrior, seed)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].hand = @[baseCardNamed("Overwork")]
    game.players[me].totalEnergy = 6
    game.players[me].energy = 6
    (game, me, enemy)

  proc names(board: seq[MinionState]): seq[string] =
    for minion in board:
      result.add minion.card.name

  test "Overwork and Burnout read as rules text":
    check baseCardNamed("Overwork").ruleText() == "Lasts 3.\n" &
      "Gain 2 energy.\n" &
      "On each of your turns, gain 2 energy and draw 1 card.\n" &
      "When this card is destroyed, summon a Burnout."
    check baseCardNamed("Burnout").ruleText() == "Lasts 3.\n" &
      "At the end of each of your turns, deal 2 damage to yourself and " &
      "discard 1 card."

  test "Overwork pays 2 energy and a card on two more turns, then burns out":
    var (game, me, enemy) = overworkGame(5001)
    check game.playCard(0)
    check game.players[me].energy == 6 - 3 + 2
    for _ in 1 .. 2:
      let hand = game.players[me].hand.len
      game.finishTurn()
      game.finishTurn()
      check game.players[me].energy == game.players[me].totalEnergy + 2
      check game.players[me].hand.len == hand + 2
      check game.players[me].board.names == @["Overwork"]
    # Its third turn: it runs out before that turn's triggers, and Burnout
    # takes its place.
    let life = game.players[me].life
    game.finishTurn()
    game.finishTurn()
    check game.players[me].energy == game.players[me].totalEnergy
    check game.players[me].board.names == @["Burnout"]
    check game.players[me].discardPile[^1].name == "Overwork"
    check game.players[me].life == life
    # Burnout bites as each of its turns ends, the one it arrived on too.
    # The turn passes once the discard is chosen.
    for bites in 1 .. 3:
      game.finishTurn()
      check game.currentPlayer == me
      check game.players[me].life == life - 2 * bites
      check game.waitingToss and game.pendingToss.source == "Burnout"
      let hand = game.players[me].hand.len
      check game.resolvePendingToss(@[0])
      check game.players[me].hand.len == hand - 1
      check game.currentPlayer == enemy
      game.finishTurn()
    # Lasts runs out as its fourth turn starts: that turn ends quietly.
    check game.players[me].board.len == 0
    game.finishTurn()
    check not game.waitingToss
    check game.currentPlayer == enemy
    check game.players[me].life == life - 6

  test "destroyed early, Overwork still leaves Burnout to its owner":
    var (game, me, enemy) = overworkGame(5003)
    check game.playCard(0)
    let overwork = game.players[me].board[0].id
    game.finishTurn()
    game.players[enemy].hand = @[baseCardNamed("Pillage")]
    game.players[enemy].energy = 20
    check game.playCard(0, @[creatureChoice(me, overwork), optionChoice(0)])
    check game.players[me].board.names == @["Burnout"]
    check game.players[enemy].board.names.len == 0


suite "AWM eachEndOfTurn":
  let dusk = Card(name: "Dusk", energyCost: 0, class: some(Mage),
    kind: Trinket, rules: rules(on(eachEndOfTurn(You), draw(1))))

  test "it prints as the end of a turn":
    check dusk.ruleText() == "At the end of each of your turns, draw 1 card."
    check Card(kind: Trinket, rules: rules(on(eachEndOfTurn(AnyOpponent),
      draw(1)))).ruleText() ==
      "At the end of each opponent's turn, draw 1 card."

  test "it fires as each of its owner's turns ends, the first one too":
    var game = newGame(Mage, Warrior, 2405)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].hand = @[dusk]
    check game.playCard(0)
    check game.players[me].hand.len == 0
    # The turn it was played on ends: it draws, then the turn passes.
    game.finishTurn()
    check game.currentPlayer == enemy
    check game.players[me].hand.len == 1
    # Not as the opponent's turn ends; its owner's starts with the usual
    # draw alone.
    game.finishTurn()
    check game.players[me].hand.len == 2
    game.finishTurn()
    check game.players[me].hand.len == 3

  test "a choice it asks for holds the turn, and answering ends it":
    let flare = Card(name: "Flare", energyCost: 0, class: some(Mage),
      kind: Trinket, rules: rules(on(eachEndOfTurn(You),
        damage(1, target({kind: {Hero}})))))
    var game = newGame(Mage, Warrior, 2407)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].board = @[MinionState(id: 1, owner: me, card: flare,
      enteredTurn: game.turnNumber)]
    game.nextMinionId = 2
    game.finishTurn()
    check game.waitingTrigger and game.turnEnding
    check game.currentPlayer == me
    # Ending it again does nothing: the trigger doesn't fire twice.
    game.finishTurn()
    check game.currentPlayer == me
    check game.pendingTriggers.len == 1
    check game.resolvePendingTrigger(@[heroChoice(enemy)])
    check game.players[enemy].life == StartingLife - 1
    check game.currentPlayer == enemy
    check not game.turnEnding

  test "a card gone by the time its trigger resolves doesn't fire":
    # Snuff goes first and destroys Dusk: Dusk's trigger, queued behind
    # Snuff's, finds no card.
    let snuff = Card(name: "Snuff", energyCost: 0, class: some(Mage),
      kind: Trinket, rules: rules(on(eachEndOfTurn(You),
        destroy(target({kind: {Trinket}, owner: You})))))
    var game = newGame(Mage, Warrior, 2409)
    let
      me = game.leads(Mage)
      enemy = 1 - me
    game.players[me].board = @[
      MinionState(id: 1, owner: me, card: snuff, enteredTurn: game.turnNumber),
      MinionState(id: 2, owner: me, card: dusk, enteredTurn: game.turnNumber)]
    game.nextMinionId = 3
    let hand = game.players[me].hand.len
    game.finishTurn()
    check game.pendingTriggers.len == 2
    check game.resolvePendingTrigger(@[creatureChoice(me, 2)])
    check game.players[me].board.len == 1
    check game.players[me].hand.len == hand
    check game.currentPlayer == enemy
