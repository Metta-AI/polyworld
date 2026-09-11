## Shared browser/server session options, deterministic bots and snapshot codec.
## Card programs stay in the base set; the wire format contains stable card IDs.
import std/[json, options, sets, strutils]
import awmsim
export awmsim

const
  DefaultSessionSeed* = 20260910'i64
  SnapshotSchemaVersion* = 1

type
  SessionOptions* = object
    seed*: int64
    playerClass*, opponentClass*: HeroClass
    human*: bool
    botPaths*: seq[string]

  BotActionKind* = enum
    PlayCardAction, EndTurnAction

  BotAction* = object
    kind*: BotActionKind
    handIndex*: int
    choice*: Choice

  Snapshot* = object
    matchId*: string
    revision*: int
    game*: GameState

proc parseHeroClass*(value: string): HeroClass =
  case value.toLowerAscii()
  of "archer": Archer
  of "warrior": Warrior
  of "mage": Mage
  else:
    raise newException(ValueError, "Unknown class '" & value &
      "'; expected archer, warrior, or mage")

proc classId(heroClass: HeroClass): string =
  heroClass.className().toLowerAscii()

proc parseSessionOptions*(args: openArray[string]): SessionOptions =
  ## Accept both --key=value and --key value, including negative numeric seeds.
  ## --human is a flag: --human, --human=true, --human true all work.
  result = SessionOptions(seed: DefaultSessionSeed,
    playerClass: Archer, opponentClass: Mage, human: false)
  var index = 0
  while index < args.len:
    let separator = args[index].find('=')
    let key = if separator >= 0: args[index][0 ..< separator] else: args[index]
    if key notin ["--seed", "--class", "--opponent", "--bot", "--human"]:
      raise newException(ValueError, "Unknown session option: " & key)
    if key == "--human":
      if separator >= 0:
        let value = args[index][separator + 1 .. ^1]
        result.human = value.toLowerAscii() in ["true", "1", "yes", ""]
      elif index + 1 < args.len and not args[index + 1].startsWith("--"):
        inc index
        result.human = args[index].toLowerAscii() in ["true", "1", "yes"]
      else:
        result.human = true
      inc index
      continue
    var value: string
    if separator >= 0:
      value = args[index][separator + 1 .. ^1]
    else:
      inc index
      if index >= args.len or args[index].startsWith("--"):
        raise newException(ValueError, "Missing value for " & key)
      value = args[index]
    if value.len == 0:
      raise newException(ValueError, "Missing value for " & key)
    case key
    of "--seed":
      try:
        result.seed = parseBiggestInt(value).int64
      except ValueError:
        raise newException(ValueError, "Invalid integer seed: " & value)
    of "--class": result.playerClass = parseHeroClass(value)
    of "--opponent": result.opponentClass = parseHeroClass(value)
    of "--bot":
      if result.botPaths.len >= PlayerCount:
        raise newException(ValueError, "Too many --bot arguments (max " &
          $PlayerCount & ")")
      result.botPaths.add value
    else: discard
    inc index

proc nextBotAction*(game: GameState, playsThisTurn = 0,
    maxPlaysPerTurn = 3): BotAction =
  ## The fixed hand order and target preferences make bots deterministic.
  ## An explicit budget also bounds future free cards and bouncing strategies.
  result = BotAction(kind: EndTurnAction, handIndex: -1, choice: NoTarget)
  if playsThisTurn >= maxPlaysPerTurn:
    return
  let enemy = (game.currentPlayer + 1) mod PlayerCount
  for handIndex, card in game.players[game.currentPlayer].hand:
    if not game.canPlay(handIndex):
      continue
    var selected = NoTarget
    if card.needsChoice():
      let choices = game.availableChoices(handIndex)
      selected = Canceled
      # Prefer the enemy hero, then the first enemy minion, then no target.
      for choice in choices:
        if choice.kind == HeroChoice and choice.owner == enemy:
          selected = choice
          break
      if selected.isCanceled:
        for choice in choices:
          if choice.kind == CreatureChoice and choice.owner == enemy:
            selected = choice
            break
      if selected.isCanceled:
        for choice in choices:
          if choice.isNoTarget:
            selected = choice
            break
      if selected.isCanceled:
        continue
    return BotAction(kind: PlayCardAction, handIndex: handIndex,
      choice: selected)

proc applyBotAction*(game: var GameState, action: BotAction): bool =
  case action.kind
  of PlayCardAction:
    game.playCard(action.handIndex, action.choice)
  of EndTurnAction:
    game.finishTurn()
    true

proc requireKind(node: JsonNode, kind: JsonNodeKind, label: string) =
  if node.isNil or node.kind != kind:
    raise newException(ValueError, "Invalid snapshot " & label)

proc field(node: JsonNode, name: string): JsonNode =
  node.requireKind(JObject, "object")
  if not node.hasKey(name):
    raise newException(ValueError, "Missing snapshot field: " & name)
  node[name]

proc integer(node: JsonNode, label: string,
    minimum = low(int), maximum = high(int)): int =
  node.requireKind(JInt, label)
  let value = node.getBiggestInt()
  if value < minimum.BiggestInt or value > maximum.BiggestInt:
    raise newException(ValueError, "Out-of-range snapshot " & label)
  value.int

proc stringValue(node: JsonNode, label: string): string =
  node.requireKind(JString, label)
  node.getStr()

proc cardToJson(card: Card): JsonNode =
  if card.class.isNone or card != card.class.get().classCard():
    raise newException(ValueError, "Snapshot card is not a base-set card")
  %card.class.get().classId()

proc cardFromJson(node: JsonNode): Card =
  parseHeroClass(node.stringValue("card ID")).classCard()

proc cardsToJson(cards: seq[Card]): JsonNode =
  result = newJArray()
  for card in cards:
    result.add cardToJson(card)

proc cardsFromJson(node: JsonNode): seq[Card] =
  node.requireKind(JArray, "card zone")
  for card in node:
    result.add cardFromJson(card)

proc choiceToJson*(choice: Choice): JsonNode =
  result = %*{"kind": ord(choice.kind), "owner": choice.owner}
  if choice.kind == CreatureChoice:
    result["creatureId"] = %choice.creatureId

proc choiceFromJson*(node: JsonNode): Choice =
  let kind = ChoiceKind(node.field("kind").integer("choice kind",
    ord(low(ChoiceKind)), ord(high(ChoiceKind))))
  let owner = node.field("owner").integer("choice owner", -1, PlayerCount - 1)
  case kind
  of CanceledChoice, NoTargetChoice:
    if owner != -1:
      raise newException(ValueError, "Invalid snapshot no-target owner")
    if kind == CanceledChoice: Canceled else: NoTarget
  of HeroChoice:
    if owner < 0:
      raise newException(ValueError, "Invalid snapshot hero owner")
    heroChoice(owner)
  of CreatureChoice:
    if owner < 0:
      raise newException(ValueError, "Invalid snapshot creature owner")
    creatureChoice(owner, node.field("creatureId").integer("creature ID", 1))

proc gameToJson*(game: GameState): JsonNode =
  var players = newJArray()
  for player in game.players:
    var board = newJArray()
    for minion in player.board:
      board.add %*{"id": minion.id, "owner": minion.owner,
        "card": cardToJson(minion.card),
        "currentToughness": minion.currentToughness,
        "canAttack": minion.canAttack,
        "hasAttacked": minion.hasAttacked}
    players.add %*{"heroClass": player.heroClass.classId(),
      "life": player.life, "totalEnergy": player.totalEnergy,
      "energy": player.energy, "deck": cardsToJson(player.deck),
      "hand": cardsToJson(player.hand),
      "discardPile": cardsToJson(player.discardPile), "board": board}
  var visualEvents = newJArray()
  for event in game.visualEvents:
    visualEvents.add %*{"kind": ord(event.kind),
      "target": choiceToJson(event.target), "boardIndex": event.boardIndex,
      "boardCount": event.boardCount}
  %*{"players": players, "currentPlayer": game.currentPlayer,
    "turnNumber": game.turnNumber, "nextMinionId": game.nextMinionId,
    "visualEvents": visualEvents,
    "gameOver": game.gameOver, "winner": game.winner}

proc gameFromJson*(node: JsonNode): GameState =
  ## Current rules consume no RNG after dealing. Full deck order is preserved,
  ## so restoring this state produces the same subsequent turns and bot plays.
  let players = node.field("players")
  players.requireKind(JArray, "players")
  if players.len != PlayerCount:
    raise newException(ValueError, "Snapshot must contain two players")
  result.currentPlayer = node.field("currentPlayer").integer(
    "current player", 0, PlayerCount - 1)
  result.turnNumber = node.field("turnNumber").integer("turn number", 1)
  result.nextMinionId = node.field("nextMinionId").integer("next minion ID", 1)
  var minionIds = initHashSet[int]()
  for owner in 0 ..< PlayerCount:
    let source = players[owner]
    var player = PlayerState(
      heroClass: parseHeroClass(source.field("heroClass").stringValue("class")),
      life: source.field("life").integer("life", 0),
      totalEnergy: source.field("totalEnergy").integer("total energy", 0),
      energy: source.field("energy").integer("energy", 0),
      deck: cardsFromJson(source.field("deck")),
      hand: cardsFromJson(source.field("hand")),
      discardPile: cardsFromJson(source.field("discardPile")))
    if player.energy > player.totalEnergy:
      raise newException(ValueError, "Snapshot energy exceeds total energy")
    let board = source.field("board")
    board.requireKind(JArray, "board")
    for entry in board:
      let minion = MinionState(
        id: entry.field("id").integer("minion ID", 1),
        owner: entry.field("owner").integer("minion owner", 0, PlayerCount - 1),
        card: cardFromJson(entry.field("card")),
        currentToughness: entry.field("currentToughness").integer("toughness", 1),
        canAttack: if entry.hasKey("canAttack"): entry["canAttack"].getBool(true) else: true,
        hasAttacked: if entry.hasKey("hasAttacked"): entry["hasAttacked"].getBool(false) else: false)
      if minion.owner != owner or minion.card.kind != Minion or
          minion.id >= result.nextMinionId or minion.id in minionIds:
        raise newException(ValueError, "Invalid snapshot board minion")
      minionIds.incl minion.id
      player.board.add minion
    result.players[owner] = move(player)
  let visualEvents = node.field("visualEvents")
  visualEvents.requireKind(JArray, "visual events")
  for entry in visualEvents:
    let event = VisualEvent(
      kind: VfxKind(entry.field("kind").integer("visual event kind",
        ord(LightningVfx), ord(high(VfxKind)))),
      target: choiceFromJson(entry.field("target")),
      boardIndex: entry.field("boardIndex").integer("visual board index", 0),
      boardCount: entry.field("boardCount").integer("visual board count", 0))
    # Removed minions legitimately remain in VFX snapshots after a bounce.
    if event.target.kind notin {HeroChoice, CreatureChoice} or
        (event.target.kind == CreatureChoice and
          event.boardIndex >= event.boardCount):
      raise newException(ValueError, "Invalid snapshot visual event target")
    result.visualEvents.add event
  result.gameOver = if node.hasKey("gameOver"): node["gameOver"].getBool(false) else: false
  result.winner = if node.hasKey("winner"): node["winner"].getInt(-1) else: -1

proc snapshotToJson*(snapshot: Snapshot): JsonNode =
  %*{"schemaVersion": SnapshotSchemaVersion, "matchId": snapshot.matchId,
    "revision": snapshot.revision, "game": gameToJson(snapshot.game)}

proc snapshotFromJson*(node: JsonNode): Snapshot =
  discard node.field("schemaVersion").integer("schema version",
    SnapshotSchemaVersion, SnapshotSchemaVersion)
  result.matchId = node.field("matchId").stringValue("match ID")
  if result.matchId.len == 0:
    raise newException(ValueError, "Snapshot match ID is empty")
  result.revision = node.field("revision").integer("revision", 0)
  result.game = gameFromJson(node.field("game"))

proc snapshotFromJson*(text: string): Snapshot =
  try:
    result = snapshotFromJson(parseJson(text))
  except JsonParsingError as error:
    raise newException(ValueError, "Malformed snapshot JSON: " & error.msg)
