import std/[json, options, unittest]
import ../awmsessions

suite "session options":
  test "defaults":
    let options = parseSessionOptions([])
    check options.seed == DefaultSessionSeed
    check options.playerClass == Archer
    check options.opponentClass == Mage
    check options.human == false

  test "URL argument forms and negative seeds":
    let options = parseSessionOptions([
      "--seed", "-123", "--class", "warrior", "--opponent=MAGE"])
    check options.seed == -123
    check options.playerClass == Warrior
    check options.opponentClass == Mage

  test "human flag forms":
    check parseSessionOptions(["--human"]).human == true
    check parseSessionOptions(["--human", "true"]).human == true
    check parseSessionOptions(["--human=1"]).human == true
    check parseSessionOptions(["--human=yes"]).human == true
    check parseSessionOptions(["--human", "false"]).human == false
    check parseSessionOptions(["--human", "--seed", "1"]).human == true

  test "invalid and incomplete options fail clearly":
    for args in [@["--seed=none"], @["--class=rogue"],
        @["--opponent=rogue"], @["--seed"], @["--seed="],
        @["--class", "--seed=1"], @["--unknown=value"], @["local"],
        @["--seed=9223372036854775808"]]:
      expect ValueError:
        discard parseSessionOptions(args)

suite "deterministic session bots":
  test "Bolt targets the enemy hero and never an ally":
    var game = newGame(Archer, Mage, 7)
    let player = game.currentPlayer
    game.players[player].hand = @[Archer.classCard()]
    game.players[player].energy = 1
    let action = game.nextBotAction()
    check action.kind == PlayCardAction
    check action.handIndex == 0
    check action.choice == heroChoice(1 - player)
    check game.applyBotAction(action)
    check game.players[player].life == StartingLife
    check game.players[1 - player].life < StartingLife

  test "Bouncer selects enemy minions and otherwise declines its target":
    var game = newGame(Mage, Warrior, 11)
    let player = game.currentPlayer
    game.players[player].hand = @[Mage.classCard()]
    game.players[player].energy = 1
    check game.nextBotAction().choice == NoTarget
    game.players[1 - player].board = @[MinionState(id: 1,
      owner: 1 - player, card: Warrior.classCard(), currentToughness: 2)]
    game.nextMinionId = 2
    let action = game.nextBotAction()
    check action.choice == creatureChoice(1 - player, 1)
    check game.applyBotAction(action)
    check game.players[1 - player].board.len == 0
    check game.players[player].board.len == 1

  test "budget and unavailable cards end the turn":
    var game = newGame(Archer, Mage, 17)
    check game.nextBotAction(playsThisTurn = 3).kind == EndTurnAction
    game.players[game.currentPlayer].energy = 0
    let action = game.nextBotAction()
    check action.kind == EndTurnAction
    check game.applyBotAction(action)
    check game.turnNumber == 2

  test "all class pairs progress deterministically with legal bounded actions":
    for first in HeroClass:
      for second in HeroClass:
        var left = newGame(first, second, DefaultSessionSeed)
        var right = newGame(first, second, DefaultSessionSeed)
        var playsThisTurn = 0
        for step in 0 ..< 160:
          if left.gameOver:
            break
          let leftAction = left.nextBotAction(playsThisTurn)
          let rightAction = right.nextBotAction(playsThisTurn)
          check leftAction == rightAction
          if leftAction.kind == PlayCardAction:
            check left.canPlay(leftAction.handIndex)
            inc playsThisTurn
          else:
            playsThisTurn = 0
          check left.applyBotAction(leftAction)
          check right.applyBotAction(rightAction)
          discard left.takeVisualEvents()
          discard right.takeVisualEvents()
          check gameToJson(left) == gameToJson(right)
        check left.turnNumber > 4
        check left.gameOver == right.gameOver

suite "global snapshots":
  test "every base card and game zone round trips with live rule programs":
    var game = newGame(Archer, Mage, 23)
    game.players[0].hand = @[Archer.classCard(), Warrior.classCard(), Mage.classCard()]
    game.players[0].discardPile = @[Archer.classCard()]
    game.players[1].board = @[MinionState(id: 8, owner: 1,
      card: Warrior.classCard(), currentToughness: 1)]
    game.nextMinionId = 9
    game.visualEvents = @[
      VisualEvent(kind: LightningVfx, target: heroChoice(1)),
      VisualEvent(kind: DamageFlashVfx, target: heroChoice(1)),
      VisualEvent(kind: BubbleVfx, target: creatureChoice(1, 7),
        boardIndex: 1, boardCount: 2)]
    let original = Snapshot(matchId: "global-23", revision: 42, game: game)
    let encoded = snapshotToJson(original)
    let decoded = snapshotFromJson($encoded)
    check decoded.matchId == original.matchId
    check decoded.revision == original.revision
    check snapshotToJson(decoded) == encoded
    for index, heroClass in [Archer, Warrior, Mage]:
      let card = decoded.game.players[0].hand[index]
      check card == heroClass.classCard()
      check card.ruleText() == heroClass.classCard().ruleText()
      check card.needsChoice() == heroClass.classCard().needsChoice()
    check decoded.game.players[1].board[0].currentToughness == 1
    check decoded.game.visualEvents == game.visualEvents

  test "restored snapshot executes the same subsequent bot actions":
    var original = newGame(Mage, Archer, 31)
    for step in 0 ..< 8:
      check original.applyBotAction(original.nextBotAction(step mod 4))
    var restored = gameFromJson(gameToJson(original))
    for step in 0 ..< 30:
      let action = original.nextBotAction(step mod 4)
      check action == restored.nextBotAction(step mod 4)
      check original.applyBotAction(action)
      check restored.applyBotAction(action)
      check gameToJson(original) == gameToJson(restored)

  test "unknown cards and malformed metadata are rejected":
    let valid = snapshotToJson(Snapshot(matchId: "global-1", revision: 0,
      game: newGame(Archer, Mage, 1)))
    for invalid in ["not json", "[]", "{}", "null"]:
      expect ValueError:
        discard snapshotFromJson(invalid)
    for key in ["schemaVersion", "matchId", "revision", "game"]:
      var missing = valid.copy()
      missing.delete(key)
      expect ValueError:
        discard snapshotFromJson(missing)
    for version in [0, 2]:
      var invalid = valid.copy()
      invalid["schemaVersion"] = %version
      expect ValueError:
        discard snapshotFromJson(invalid)
    var invalidCard = valid.copy()
    invalidCard["game"]["players"][0]["hand"].elems[0] = %"unknown"
    expect ValueError:
      discard snapshotFromJson(invalidCard)
    var negativeRevision = valid.copy()
    negativeRevision["revision"] = %(-1)
    expect ValueError:
      discard snapshotFromJson(negativeRevision)

  test "invalid state types and board identities are rejected":
    let valid = gameToJson(newGame(Warrior, Mage, 37))
    for key in ["currentPlayer", "turnNumber", "nextMinionId", "players", "visualEvents"]:
      var invalid = valid.copy()
      invalid[key] = %"invalid"
      expect ValueError:
        discard gameFromJson(invalid)
    var invalidPlayer = valid.copy()
    invalidPlayer["currentPlayer"] = %2
    expect ValueError:
      discard gameFromJson(invalidPlayer)
    var invalidMinion = valid.copy()
    invalidMinion["nextMinionId"] = %2
    invalidMinion["players"][0]["board"] = %*[
      {"id": 1, "owner": 1, "card": "warrior", "currentToughness": 2}]
    expect ValueError:
      discard gameFromJson(invalidMinion)
    invalidMinion["players"][0]["board"][0]["owner"] = %0
    invalidMinion["players"][0]["board"][0]["card"] = %"archer"
    expect ValueError:
      discard gameFromJson(invalidMinion)

  test "custom cards cannot silently serialize as a base-set card":
    var game = newGame(Archer, Mage, 43)
    game.players[0].hand = @[Card(name: "Different", class: some(Archer),
      energyCost: 1, kind: Spell)]
    expect ValueError:
      discard gameToJson(game)


suite "owned game snapshots":
  test "saved presentation state survives mutation and board reallocation":
    var game = newGame(Mage, Warrior, 7)
    game.currentPlayer = 0
    game.players[0].energy = 20
    game.players[0].totalEnergy = 20
    discard game.playCard(0, NoTarget)
    let saved = game.copyGameState()
    let savedJson = $gameToJson(saved)
    for _ in 0 ..< 4:
      discard game.playCard(0, NoTarget)
    game.finishTurn()
    check $gameToJson(saved) == savedJson
    check saved.players[0].board.len == 1
    check game.players[0].board.len == 5
