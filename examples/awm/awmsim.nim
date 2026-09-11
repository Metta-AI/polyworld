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
    selected = Canceled,
    allowNoTarget = false
): RuleContext =
  result.sourcePlayer = game.currentPlayer
  result.allowNoTarget = allowNoTarget
  for playerIndex in 0 ..< PlayerCount:
    result.heroes.add heroChoice(playerIndex)
    for minion in game.players[playerIndex].board:
      result.creatures.add creatureChoice(playerIndex, minion.id)
  result.selector = proc(
      prompt: string,
      choices: seq[Choice]
  ): Choice =
    discard (prompt, choices)
    selected

proc availableChoices*(
    game: GameState,
    card: Card
): seq[Choice] =
  let context = game.ruleContext()
  result = card.choices(context)
  if card.kind == Minion and card.needsChoice():
    result.add NoTarget

proc availableChoices*(
    game: GameState,
    cardIndex: int
): seq[Choice] =
  if cardIndex < 0 or
      cardIndex >= game.players[game.currentPlayer].hand.len:
    return
  game.availableChoices(
    game.players[game.currentPlayer].hand[cardIndex]
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
    "Player " & $(location.player + 1) & "'s " & minion.card.name &
      " (" & $minion.card.power & "/" & $minion.currentToughness & ")"

proc recordVisual(game: var GameState, kind: VfxKind, target: Choice) =
  if kind == NoVfx: return
  var event = VisualEvent(kind: kind, target: target)
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
      let location = game.minionLocation(effect.damagedCreatureId)
      if not location.found:
        continue
      if effect.creatureDamage > 0:
        game.recordVisual(DamageFlashVfx,
          creatureChoice(location.player, effect.damagedCreatureId))
      game.players[location.player].board[
        location.index
      ].currentToughness -= effect.creatureDamage
      if game.players[location.player].board[
          location.index
      ].currentToughness <= 0:
        let destroyed =
          game.players[location.player].board[location.index].card
        game.players[location.player].board.delete(location.index)
        game.players[location.player].discardPile.add destroyed
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
    choice = NoTarget
): bool =
  ## Resolves a minion's on-play program after that minion is on the board.
  if card.kind != Minion:
    return false
  let selectedChoice =
    if choice.isCanceled:
      NoTarget
    else:
      choice
  var context = game.ruleContext(
    selectedChoice,
    allowNoTarget = true
  )
  if not card.runRules(context):
    return false
  game.applyEffects(context.effects)
  true

proc playCard*(
    game: var GameState,
    cardIndex: int,
    choice = Canceled
): bool =
  if not game.canPlay(cardIndex):
    return false
  let
    playerIndex = game.currentPlayer
    card = game.players[playerIndex].hand[cardIndex]
  case card.kind
  of Spell:
    var context = game.ruleContext(choice)
    if not card.runRules(context):
      return false
    game.players[playerIndex].energy -= card.energyCost
    game.players[playerIndex].hand.delete(cardIndex)
    game.applyEffects(context.effects)
    game.players[playerIndex].discardPile.add card
  of Minion:
    if game.playMinion(cardIndex) == 0:
      return false
    discard game.runMinionRules(card, choice)
  true

proc attackHero*(game: var GameState, minionId: int): bool =
  let location = game.minionLocation(minionId)
  if not location.found: return false
  if location.player != game.currentPlayer: return false
  let minion = game.players[location.player].board[location.index]
  if not minion.canAttack or minion.hasAttacked: return false
  let targetPlayer = (game.currentPlayer + 1) mod PlayerCount
  if minion.card.power > 0:
    game.recordVisual(DamageFlashVfx, heroChoice(targetPlayer))
  game.players[targetPlayer].life = max(0,
    game.players[targetPlayer].life - minion.card.power)
  game.players[location.player].board[location.index].hasAttacked = true
  game.checkWinCondition()
  true

proc eligibleAttackers*(game: GameState): seq[int] =
  for minion in game.players[game.currentPlayer].board:
    if minion.canAttack and not minion.hasAttacked:
      result.add minion.id

proc finishTurn*(game: var GameState) =
  if game.gameOver: return
  game.currentPlayer = (game.currentPlayer + 1) mod PlayerCount
  inc game.turnNumber
  game.beginTurn()
