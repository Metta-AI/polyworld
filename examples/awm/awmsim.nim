## Deterministic AWM simulation shared by native, browser and server builds.
import std/random
import awmcore, baseset
export awmcore, baseset

const
  PlayerCount* = 2
  StartingLife* = 20
  StartingHandSize* = 5

type
  MinionState* = object
    id*: int
    owner*: int
    card*: Card
    currentToughness*: int
    bonusPower*: int  ## Permanent power change on top of the printed power.
    lostKeywords*: set[Keyword]  ## Keywords lost while on the board.
    canAttack*: bool
    hasAttacked*: bool

  PlayerState* = object
    heroClass*: HeroClass
    life*: int
    totalEnergy*: int
    energy*: int
    deck*: seq[Card]
    hand*: seq[Card]
    discardPile*: seq[Card]
    board*: seq[MinionState]

  VisualEvent* = object
    ## Snapshot the target before damage/bounce can remove or rearrange it.
    kind*: VfxKind
    target*: Choice
    boardIndex*, boardCount*: int
    card*: Card  ## The slain minion's card, for DeathVfx.
    power*: int  ## The slain minion's live power, for DeathVfx.

  GameState* = object
    players*: array[PlayerCount, PlayerState]
    currentPlayer*: int
    turnNumber*: int
    nextMinionId*: int
    visualEvents*: seq[VisualEvent]
    gameOver*: bool
    winner*: int
    rng: Rand

proc copyGameState*(game: GameState): GameState {.noinline.} =
  ## Own the sequences before another subsystem mutates the live state.
  ## A borrowed local alias can otherwise outlive a reallocated board in ARC.
  result = game

proc power*(minion: MinionState): int =
  ## Live power: printed power plus permanent changes, never below 0.
  max(0, minion.card.power + minion.bonusPower)

proc keywords*(minion: MinionState): set[Keyword] =
  ## Live keywords: the printed ones minus any the minion lost.
  minion.card.keywords() - minion.lostKeywords

proc hasKeyword*(minion: MinionState, keyword: Keyword): bool =
  keyword in minion.keywords()

proc combatDamage(source, target: MinionState): int =
  ## Ranged minions take no combat damage from non-ranged minions.
  if target.hasKeyword(Ranged) and not source.hasKeyword(Ranged):
    0
  else:
    source.power

proc drawCard*(player: var PlayerState): bool =
  if player.deck.len == 0:
    return false
  player.hand.add player.deck.pop()
  true

proc initPlayer(
    heroClass: HeroClass,
    rng: var Rand
): PlayerState =
  result.heroClass = heroClass
  result.life = StartingLife
  result.deck = heroClass.baseDeck()
  rng.shuffle(result.deck)
  for _ in 0 ..< StartingHandSize:
    discard result.drawCard()

proc checkWinCondition*(game: var GameState) =
  if game.gameOver: return
  for playerIndex in 0 ..< PlayerCount:
    if game.players[playerIndex].life <= 0:
      game.gameOver = true
      game.winner = (playerIndex + 1) mod PlayerCount
      return

proc beginTurn*(game: var GameState) =
  if game.gameOver: return
  let playerIndex = game.currentPlayer
  inc game.players[playerIndex].totalEnergy
  game.players[playerIndex].energy =
    game.players[playerIndex].totalEnergy
  if game.turnNumber > 1:
    if not game.players[playerIndex].drawCard():
      game.gameOver = true
      game.winner = (playerIndex + 1) mod PlayerCount
      return
  for minion in game.players[playerIndex].board.mitems:
    minion.canAttack = true
    minion.hasAttacked = false

proc newGame*(
    firstClass,
    secondClass: HeroClass,
    seed: int64
): GameState =
  result.rng = initRand(seed)
  result.players[0] = initPlayer(firstClass, result.rng)
  result.players[1] = initPlayer(secondClass, result.rng)
  result.currentPlayer = result.rng.rand(PlayerCount - 1)
  result.turnNumber = 1
  result.nextMinionId = 1
  result.winner = -1
  result.beginTurn()

proc canPlay*(game: GameState, cardIndex: int): bool =
  let player = game.players[game.currentPlayer]
  cardIndex >= 0 and
    cardIndex < player.hand.len and
    player.hand[cardIndex].energyCost <= player.energy

proc minionLocation*(
    game: GameState,
    minionId: int
): tuple[found: bool, player, index: int] =
  for playerIndex in 0 ..< PlayerCount:
    for minionIndex, minion in game.players[playerIndex].board:
      if minion.id == minionId:
        return (true, playerIndex, minionIndex)

proc ruleContext(
    game: GameState,
    picks: seq[Choice] = @[],
    allowNoTarget = false
): RuleContext =
  ## `picks` answers the card's targets in order; a missing one cancels.
  result.sourcePlayer = game.currentPlayer
  result.allowNoTarget = allowNoTarget
  result.picks = picks
  result.cardNamed = baseCardNamed
  result.game.nextMinionId = game.nextMinionId
  for playerIndex in 0 ..< PlayerCount:
    result.heroes.add heroChoice(playerIndex)
    for minion in game.players[playerIndex].board:
      result.creatures.add creatureChoice(playerIndex, minion.id)
      result.game.board.add BoardCard(
        choice: creatureChoice(playerIndex, minion.id), card: minion.card,
        power: minion.power, toughness: minion.currentToughness)

proc availableChoices*(
    game: GameState,
    card: Card,
    picked: seq[Choice] = @[]
): seq[Choice] =
  ## Legal choices for the card's next target, after the `picked` ones.
  var context = game.ruleContext()
  context.targets = picked
  result = card.choices(context, picked.len)
  if card.kind == Minion and card.needsChoice():
    result.add NoTarget

proc availableChoices*(
    game: GameState,
    cardIndex: int,
    picked: seq[Choice] = @[]
): seq[Choice] =
  if cardIndex < 0 or
      cardIndex >= game.players[game.currentPlayer].hand.len:
    return
  game.availableChoices(
    game.players[game.currentPlayer].hand[cardIndex], picked
  )

proc choiceLabel*(game: GameState, choice: Choice): string =
  case choice.kind
  of CanceledChoice:
    "Cancel"
  of NoTargetChoice:
    "No target"
  of HeroChoice:
    "Player " & $(choice.owner + 1) & " " &
      game.players[choice.owner].heroClass.className() & " hero"
  of CreatureChoice:
    let location = game.minionLocation(choice.creatureId)
    if not location.found:
      return "Missing minion"
    let minion = game.players[location.player].board[location.index]
    var stats = $minion.power & "/" & $minion.currentToughness
    for keyword in minion.lostKeywords:
      stats.add ", lost " & $keyword
    "Player " & $(location.player + 1) & "'s " & minion.card.name &
      " (" & stats & ")"

proc recordVisual(game: var GameState, kind: VfxKind, target: Choice,
    card = Card(), power = 0) =
  if kind == NoVfx: return
  var event = VisualEvent(kind: kind, target: target, card: card, power: power)
  case target.kind
  of HeroChoice:
    if target.owner < 0 or target.owner >= PlayerCount: return
  of CreatureChoice:
    let location = game.minionLocation(target.creatureId)
    if not location.found or location.player != target.owner: return
    event.boardIndex = location.index
    event.boardCount = game.players[location.player].board.len
  else:
    return
  game.visualEvents.add event

proc takeVisualEvents*(game: var GameState): seq[VisualEvent] =
  ## Presentation consumes each event once; it never delays or changes rules.
  result = move(game.visualEvents)

proc destroyMinion(game: var GameState, player, index: int) =
  ## Sends a minion to its owner's discard pile.
  let minion = game.players[player].board[index]
  game.recordVisual(DeathVfx, creatureChoice(player, minion.id),
    minion.card, minion.power)
  game.players[player].board.delete(index)
  game.players[player].discardPile.add minion.card

proc destroyIfSlain(game: var GameState, player, index: int) =
  ## A minion at 0 toughness dies.
  if game.players[player].board[index].currentToughness <= 0:
    game.destroyMinion(player, index)

proc damageMinion(game: var GameState, minionId, amount: int) =
  let location = game.minionLocation(minionId)
  if not location.found:
    return
  if amount > 0:
    game.recordVisual(DamageFlashVfx, creatureChoice(location.player, minionId))
  game.players[location.player].board[location.index].currentToughness -=
    amount
  game.destroyIfSlain(location.player, location.index)

proc applyEffects(game: var GameState, effects: openArray[Effect]) =
  for effect in effects:
    case effect.kind
    of TargetVfxEffect:
      game.recordVisual(effect.targetVfx, effect.visualTarget)
    of DamageHeroEffect:
      if effect.heroDamage > 0 and game.players[effect.heroPlayer].life > 0:
        game.recordVisual(DamageFlashVfx, heroChoice(effect.heroPlayer))
      game.players[effect.heroPlayer].life = max(
        0,
        game.players[effect.heroPlayer].life - effect.heroDamage
      )
    of DamageCreatureEffect:
      game.damageMinion(effect.damagedCreatureId, effect.creatureDamage)
    of LoseKeywordEffect:
      let location = game.minionLocation(effect.keywordLoserId)
      if location.found:
        game.players[location.player].board[location.index].lostKeywords.incl(
          effect.lostKeyword)
    of FightEffect:
      let
        fighter = game.minionLocation(effect.fighterId)
        opponent = game.minionLocation(effect.opponentId)
      if not fighter.found or not opponent.found:
        continue
      let
        a = game.players[fighter.player].board[fighter.index]
        b = game.players[opponent.player].board[opponent.index]
      if a.id == b.id:
        # A minion fighting itself is hit once, by its own power.
        game.damageMinion(a.id, combatDamage(a, a))
      else:
        # Both hits land at once, from the stats before either one.
        let
          toOpponent = combatDamage(a, b)
          toFighter = combatDamage(b, a)
        game.damageMinion(b.id, toOpponent)
        game.damageMinion(a.id, toFighter)
    of ModifyStatsEffect:
      let location = game.minionLocation(effect.modifiedCreatureId)
      if not location.found:
        continue
      game.players[location.player].board[location.index].bonusPower +=
        effect.powerChange
      game.players[location.player].board[location.index].currentToughness +=
        effect.toughnessChange
      game.destroyIfSlain(location.player, location.index)
    of SummonEffect:
      game.players[effect.summonedOwner].board.add MinionState(
        id: effect.summonedId, owner: effect.summonedOwner,
        card: effect.summonedCard,
        currentToughness: effect.summonedCard.toughness)
      game.nextMinionId = max(game.nextMinionId, effect.summonedId + 1)
    of DestroyEffect:
      let location = game.minionLocation(effect.destroyedId)
      if location.found:
        game.destroyMinion(location.player, location.index)
    of BounceCreatureEffect:
      let location = game.minionLocation(effect.bouncedCreatureId)
      if not location.found:
        continue
      let bounced = game.players[location.player].board[location.index].card
      game.players[location.player].board.delete(location.index)
      game.players[location.player].hand.add bounced
  game.checkWinCondition()

proc playMinion*(
    game: var GameState,
    cardIndex: int
): int =
  ## Pays for a minion and puts it onto the board before any of its rules run.
  if not game.canPlay(cardIndex):
    return
  let
    playerIndex = game.currentPlayer
    card = game.players[playerIndex].hand[cardIndex]
  if card.kind != Minion:
    return
  result = game.nextMinionId
  game.players[playerIndex].energy -= card.energyCost
  game.players[playerIndex].hand.delete(cardIndex)
  game.players[playerIndex].board.add MinionState(
    id: result,
    owner: playerIndex,
    card: card,
    currentToughness: card.toughness
  )
  inc game.nextMinionId

proc runMinionRules*(
    game: var GameState,
    card: Card,
    choices: seq[Choice]
): bool =
  ## Resolves a minion's on-play program after that minion is on the board.
  ## A canceled pick means no target: the minion is already in play.
  if card.kind != Minion:
    return false
  var picks: seq[Choice]
  for choice in choices:
    picks.add(if choice.isCanceled: NoTarget else: choice)
  var context = game.ruleContext(
    picks,
    allowNoTarget = true
  )
  if not card.runRules(context):
    return false
  game.applyEffects(context.effects)
  true

proc runMinionRules*(
    game: var GameState,
    card: Card,
    choice = NoTarget
): bool =
  game.runMinionRules(card, @[choice])

proc playCard*(
    game: var GameState,
    cardIndex: int,
    choices: seq[Choice]
): bool =
  ## `choices` answers the card's targets in order (Duel takes two).
  if not game.canPlay(cardIndex):
    return false
  let
    playerIndex = game.currentPlayer
    card = game.players[playerIndex].hand[cardIndex]
  case card.kind
  of Spell:
    var context = game.ruleContext(choices)
    if not card.runRules(context):
      return false
    game.players[playerIndex].energy -= card.energyCost
    game.players[playerIndex].hand.delete(cardIndex)
    game.applyEffects(context.effects)
    game.players[playerIndex].discardPile.add card
  of Minion:
    if game.playMinion(cardIndex) == 0:
      return false
    discard game.runMinionRules(card, choices)
  true

proc playCard*(
    game: var GameState,
    cardIndex: int,
    choice = Canceled
): bool =
  game.playCard(cardIndex, @[choice])

proc attackHero*(game: var GameState, minionId: int): bool =
  let location = game.minionLocation(minionId)
  if not location.found: return false
  if location.player != game.currentPlayer: return false
  let minion = game.players[location.player].board[location.index]
  if not minion.canAttack or minion.hasAttacked: return false
  let targetPlayer = (game.currentPlayer + 1) mod PlayerCount
  if minion.power > 0:
    game.recordVisual(DamageFlashVfx, heroChoice(targetPlayer))
  game.players[targetPlayer].life = max(0,
    game.players[targetPlayer].life - minion.power)
  game.players[location.player].board[location.index].hasAttacked = true
  game.checkWinCondition()
  true

proc attackTargets*(game: GameState, attackerId: int): seq[Choice] =
  ## Legal targets for a ready attacker: the enemy hero, then enemy minions.
  let location = game.minionLocation(attackerId)
  if not location.found or location.player != game.currentPlayer:
    return
  let attacker = game.players[location.player].board[location.index]
  if not attacker.canAttack or attacker.hasAttacked:
    return
  let enemy = (game.currentPlayer + 1) mod PlayerCount
  result.add heroChoice(enemy)
  for minion in game.players[enemy].board:
    result.add creatureChoice(enemy, minion.id)

proc attackMinion*(game: var GameState, attackerId, targetId: int): bool =
  ## The attacker fights its target. Damage stays, and minions reduced to 0
  ## toughness go to their owner's discard pile.
  let enemy = (game.currentPlayer + 1) mod PlayerCount
  if creatureChoice(enemy, targetId) notin game.attackTargets(attackerId):
    return false
  let attackerLocation = game.minionLocation(attackerId)
  game.players[attackerLocation.player].board[
    attackerLocation.index].hasAttacked = true
  game.applyEffects([
    Effect(kind: FightEffect, fighterId: attackerId, opponentId: targetId)])
  true

proc attack*(game: var GameState, attackerId: int, target: Choice): bool =
  if target notin game.attackTargets(attackerId):
    return false
  case target.kind
  of HeroChoice: game.attackHero(attackerId)
  of CreatureChoice: game.attackMinion(attackerId, target.creatureId)
  of CanceledChoice, NoTargetChoice: false

proc eligibleAttackers*(game: GameState): seq[int] =
  for minion in game.players[game.currentPlayer].board:
    if minion.canAttack and not minion.hasAttacked:
      result.add minion.id

proc finishTurn*(game: var GameState) =
  if game.gameOver: return
  game.currentPlayer = (game.currentPlayer + 1) mod PlayerCount
  inc game.turnNumber
  game.beginTurn()
