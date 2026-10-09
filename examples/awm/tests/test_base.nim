import
  std/[options, sequtils],
  ../src/core/[bots, match, replays, sim]

const BaseBot = staticRead("../players/base.bas")

proc fixture(seed: int64): BotMatch =
  ## Gives the reference script a deterministic four-seat test match.
  result = initBotMatch(@[Mage, Mage, Mage, Mage], seed,
    loadBots(newSeqWith(4, BaseBot)), 28_800)
  result.game.currentPlayer = 0
  result.game.players[0].hand.setLen(0)
  result.game.players[0].energy = 9
  result.game.players[0].totalEnergy = 9

proc ready(owner, id: int, name: string): MinionState =
  ## Creates a ready permanent with its printed stats.
  let card = baseCardNamed(name)
  MinionState(owner: owner, id: id, card: card,
    currentToughness: (if card.kind == Minion: card.toughness else: 0),
    canAttack: true)

echo "The reference script randomly selects all three classes reproducibly"
block:
  var selected: set[HeroClass]
  for seed in 0 ..< 32:
    let
      first = loadBots(newSeqWith(4, BaseBot)).chooseBotClasses(seed)
      second = loadBots(newSeqWith(4, BaseBot)).chooseBotClasses(seed)
    doAssert first == second
    for heroClass in first:
      selected.incl heroClass
  doAssert selected == {Archer, Warrior, Mage}

echo "The reference script takes the swing worth the most"
block:
  # A Ranged 3/1 takes no damage back from a Bear, so it kills one, and
  # takes it from the next living player.
  for seed in 0 ..< 16:
    var played = fixture(seed)
    played.game.players[0].board = @[ready(0, 1, "Sharpshooter")]
    for player in 1 .. 3:
      played.game.players[player].board = @[ready(player, player + 1, "Bear")]
    played.game.nextMinionId = 5
    doAssert played.step()
    let action = played.bots[0].action
    doAssert action.kind == ActionAttack
    let target = action.choices[0].toChoice
    doAssert target.kind == CreatureChoice
    doAssert target.owner == 1
block:
  # A 10/10 is worth more aimed at a hero than spent on a 1/2.
  var played = fixture(7)
  played.game.players[0].board = @[ready(0, 1, "Primordial")]
  played.game.players[1].board = @[ready(1, 2, "Footsoldier")]
  played.game.nextMinionId = 3
  doAssert played.step()
  let target = played.bots[0].action.choices[0].toChoice
  doAssert target.kind == HeroChoice
  doAssert target.owner == 1

echo "The reference script reaches every opponent's minions and heroes"
block:
  # With the next player's board empty, the others are still attacked, and
  # equal targets are picked at random.
  var owners: set[range[1 .. 3]]
  for seed in 0 ..< 16:
    var played = fixture(seed)
    played.game.players[0].board = @[ready(0, 1, "Sharpshooter")]
    for player in 2 .. 3:
      played.game.players[player].board = @[ready(player, player + 1, "Bear")]
    played.game.nextMinionId = 5
    doAssert played.step()
    let target = played.bots[0].action.choices[0].toChoice
    doAssert target.kind == CreatureChoice
    owners.incl target.owner
  doAssert owners == {2, 3}
block:
  # Nothing to kill: it swings at the next living player's hero.
  var played = fixture(5)
  played.game.players[0].board = @[ready(0, 1, "Primordial")]
  played.game.nextMinionId = 2
  doAssert played.step()
  let target = played.bots[0].action.choices[0].toChoice
  doAssert target.kind == HeroChoice
  doAssert target.owner == 1

echo "The reference script plays cards, chooses targets, and ends explicitly"
block:
  var played = fixture(1)
  played.game.players[0].hand = @[baseCardNamed("Ooze")]
  doAssert played.step()
  doAssert played.bots[0].action.kind == ActionPlayCard
  doAssert played.step()
  doAssert played.bots[0].action.kind == ActionEndTurn
block:
  var bouncedSelf = false
  for seed in 0 ..< 16:
    var played = fixture(seed)
    played.game.players[0].hand = @[baseCardNamed("Bouncer")]
    doAssert played.step()
    doAssert played.bots[0].action.kind == ActionPlayCard
    bouncedSelf = bouncedSelf or played.game.players[0].board.len == 0
  doAssert bouncedSelf
block:
  var played = fixture(3)
  played.game.players[0].hand = @[baseCardNamed("Duel")]
  played.game.players[0].board = @[ready(0, 1, "Bear")]
  played.game.players[0].board[0].canAttack = false
  played.game.players[2].board = @[ready(2, 2, "Bear")]
  played.game.nextMinionId = 3
  doAssert played.step()
  doAssert played.bots[0].action.kind == ActionPlayCard
  doAssert played.bots[0].action.choices.len == 2

echo "The reference script aims at what each card does"
block:
  # One damage kills the Sniper, so it goes there and not at the Bear.
  var played = fixture(11)
  played.game.players[0].hand = @[baseCardNamed("Sharpshooter")]
  played.game.players[1].board = @[ready(1, 1, "Bear"), ready(1, 2, "Sniper")]
  played.game.nextMinionId = 3
  doAssert played.step()
  let action = played.bots[0].action
  doAssert action.kind == ActionPlayCard
  doAssert action.choices[0].toChoice == creatureChoice(1, 2)
block:
  # Duel buffs your biggest body and strips Ranged from a minion that has it.
  var played = fixture(12)
  played.game.players[0].hand = @[baseCardNamed("Duel")]
  played.game.players[0].board = @[ready(0, 1, "Footsoldier"), ready(0, 2, "Bear")]
  played.game.players[1].board = @[ready(1, 3, "Bear"), ready(1, 4, "Sniper")]
  played.game.nextMinionId = 5
  doAssert played.step()
  let action = played.bots[0].action
  doAssert action.kind == ActionPlayCard
  doAssert action.choices.len == 2
  doAssert action.choices[0].toChoice == creatureChoice(0, 2)
  doAssert action.choices[1].toChoice == creatureChoice(1, 4)
block:
  # A bounce takes their biggest threat, not the smallest.
  var played = fixture(13)
  played.game.players[0].hand = @[baseCardNamed("Bouncer")]
  played.game.players[1].board = @[ready(1, 1, "Footsoldier"), ready(1, 2, "Bear")]
  played.game.nextMinionId = 3
  doAssert played.step()
  let action = played.bots[0].action
  doAssert action.kind == ActionPlayCard
  doAssert action.choices[0].toChoice == creatureChoice(1, 2)

echo "The reference script picks the option it is better off with"
block:
  # 6 damage for 3 of its own is worse than 2 for nothing.
  var played = fixture(21)
  played.game.players[0].hand = @[baseCardNamed("Overcharge")]
  played.game.players[1].board = @[ready(1, 1, "Bear")]
  played.game.nextMinionId = 2
  doAssert played.step()
  let action = played.bots[0].action
  doAssert action.kind == ActionPlayCard
  doAssert action.choices.len == 2
  doAssert action.choices[0].toChoice == optionChoice(0)
  doAssert action.choices[1].toChoice == creatureChoice(1, 1)
block:
  # With a branch that costs nothing, it takes the bigger one.
  var played = fixture(22)
  played.game.players[0].hand = @[Card(name: "Pick", energyCost: 0,
    kind: Spell, class: some(Mage), rules: rules(choose(
      rules(damage(1, target({kind: {Minion}}))),
      rules(damage(4, target({kind: {Minion}}))))))]
  played.game.players[1].board = @[ready(1, 1, "Bear")]
  played.game.nextMinionId = 2
  doAssert played.step()
  let action = played.bots[0].action
  doAssert action.kind == ActionPlayCard
  doAssert action.choices[0].toChoice == optionChoice(1)

echo "The reference script discards what it can use least"
block:
  # Eight energy away, Summon Primordial is dead weight and goes first.
  var played = fixture(14)
  played.game.players[0].energy = 2
  played.game.players[0].totalEnergy = 2
  played.game.players[0].hand = @[baseCardNamed("Bouncer"),
    baseCardNamed("Summon Primordial"), baseCardNamed("Bear")]
  played.game.pendingToss = PendingToss(player: 0, count: 1)
  doAssert played.step()
  doAssert played.bots[0].action.kind == ActionToss
  doAssert played.bots[0].action.indices == @[1'i32]
block:
  # With the energy to cast everything, the weakest body goes instead.
  var played = fixture(15)
  played.game.players[0].energy = 10
  played.game.players[0].totalEnergy = 10
  played.game.players[0].hand = @[baseCardNamed("Bouncer"),
    baseCardNamed("Summon Primordial"), baseCardNamed("Bear")]
  played.game.pendingToss = PendingToss(player: 0, count: 1)
  doAssert played.step()
  doAssert played.bots[0].action.kind == ActionToss
  doAssert played.bots[0].action.indices == @[0'i32]

echo "The reference script chooses discards and off-turn trigger targets"
block:
  var played = fixture(6)
  played.game.players[2].hand = @[
    baseCardNamed("Bouncer"), baseCardNamed("Ooze"), baseCardNamed("Primordial")]
  played.game.pendingToss = PendingToss(player: 2, count: 2)
  doAssert played.step()
  doAssert played.bots[2].action.kind == ActionToss
  doAssert played.bots[2].action.indices.len == 2
  doAssert played.bots[2].action.indices[0] != played.bots[2].action.indices[1]
block:
  var played = fixture(9)
  let snare = Card(name: "Snare", kind: Trinket, class: some(Mage),
    rules: rules(on(nextTurn(You), damage(1, target({kind: {Minion}})))))
  played.game.players[2].board = @[
    MinionState(id: 1, owner: 2, card: snare)]
  played.game.players[0].board = @[ready(0, 2, "Bear")]
  played.game.pendingTriggers = @[
    PendingTrigger(owner: 2, sourceId: 1, trigger: 0)]
  played.game.nextMinionId = 3
  doAssert played.step()
  doAssert played.bots[2].action.kind == ActionResolveTrigger
  doAssert not played.game.waitingTrigger
block:
  # A trigger aims like a card: its one damage goes where it kills.
  var played = fixture(10)
  let snare = Card(name: "Snare", kind: Trinket, class: some(Mage),
    rules: rules(on(nextTurn(You), damage(1, target({kind: {Minion}})))))
  played.game.players[2].board = @[MinionState(id: 1, owner: 2, card: snare)]
  played.game.players[0].board = @[ready(0, 2, "Bear"), ready(0, 3, "Sniper")]
  played.game.pendingTriggers = @[
    PendingTrigger(owner: 2, sourceId: 1, trigger: 0)]
  played.game.nextMinionId = 4
  doAssert played.step()
  let action = played.bots[2].action
  doAssert action.kind == ActionResolveTrigger
  doAssert action.choices[0].toChoice == creatureChoice(0, 3)

echo "Reference policy action coverage passed"
