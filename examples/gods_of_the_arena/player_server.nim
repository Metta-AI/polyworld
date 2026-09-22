## Local GotA player endpoint for neural policies and interactive clients.
##
## One client supplies actions for all five heroes on one team. The opposing
## team continues to run BASIC.
import std/[asynchttpserver, asyncdispatch, json, strutils]
import polyworld/[cli, metrics]
import ws
when isMainModule:
  import std/os
import bots, maps, presets, replays, sim

const
  PlayerFeatureCount* = 8
  PlayerActionCount* = 8
  PlayerActionRepeat* = 4
  PlayerOutcomeReward = 100'f32

type
  PlayerServerOptions* = object
    host*: string
    port*: int
    opponent*: string
    config*: string
    maxTicks*: int
    seed*: int

  PlayerTransition* = object
    features*: array[PlayerFeatureCount, float32]
    reward*: float32
    terminal*: bool
    tick*, seat*, outcome*: int32
    stateHash*: uint64
    xp*, structureHp*, heroXp*, heroGold*, heroKills*, heroDeaths*: int64
    maxWork*, maxInstructions*: int64

  PlayerMatch = ref object
    game: Game
    team: sim.Team
    seats: seq[int]
    seatIndex: int
    maxTicks: int
    previousScore: int64
    transition: PlayerTransition

proc potential(transition: PlayerTransition): int64 =
  transition.xp + transition.structureHp

proc snapshot(match: PlayerMatch, seat: int, terminal: bool) =
  let
    game = match.game
    world = game.world
    hero = world.heroes[seat]
  match.transition = PlayerTransition(
    terminal: terminal,
    tick: world.tick,
    seat: int32(seat),
    stateHash: stateHash(game),
    heroXp: hero.totalXp,
    heroGold: hero.gold,
    heroKills: world.stats.values[seat][KillsMetric],
    heroDeaths: world.stats.values[seat][LossesMetric]
  )
  match.transition.outcome =
    if world.gameOver and world.winner == match.team: 1
    elif world.gameOver or terminal: -1
    else: 0
  let features: array[PlayerFeatureCount, int32] = [
    hero.hp * 100 div hero.maxHp,
    (if hero.maxMana > 0: hero.mana * 100 div hero.maxMana else: 0),
    int32(hero.level * 5),
    mapCoordinate(hero.position.x),
    mapCoordinate(hero.position.z),
    world.tick div 288,
    int32(hero.gold div 10),
    int32(hero.class.ord * 10)
  ]
  for index, value in features:
    match.transition.features[index] = float32(clamp(value, -100, 100))
  for other in world.heroes:
    match.transition.xp +=
      (if other.team == match.team: 1 else: -1) * other.totalXp
  for building in world.buildings:
    if building.kind == TowerBuilding:
      match.transition.structureHp +=
        2 * (if building.team == match.team: 1 else: -1) * max(building.hp, 0)
  for fort in world.forts:
    match.transition.structureHp +=
      20 * (if fort.team == match.team: 1 else: -1) * max(fort.hp, 0)
  for vm in game.heroVms:
    if vm != nil:
      doAssert not vm.failed, vm.lastError
      match.transition.maxWork = max(match.transition.maxWork, vm.lastWork)
      match.transition.maxInstructions = max(
        match.transition.maxInstructions, vm.lastInstructions)

proc newPlayerMatch(
    config: GotaConfig,
    opponent: string,
    maxTicks, seed: int
): PlayerMatch =
  let
    gameMap = generateMap(int32(seed), config.mapPreset)
    game = newGame(
      gameMap, config.spawnIntervalTicks, 10, false, ReplayData(), false
    )
    team = sim.Team((seed mod 10) div 5)
  loadBots(game, [BotGroup(path: opponent, count: 10)])
  game.replayData = initReplayData(
    currentSetup(game, uint32(maxTicks)), gameMap.preset
  )
  result = PlayerMatch(game: game, team: team, maxTicks: maxTicks)
  for seat, hero in game.world.heroes:
    if hero.team == team:
      result.seats.add seat
      game.heroVms[seat] = nil
  doAssert result.seats.len == 5
  result.snapshot(result.seats[0], false)
  result.previousScore = result.transition.potential()

proc applyAction(match: PlayerMatch, action: int) =
  let
    world = match.game.world
    hero = world.heroes[match.seats[match.seatIndex]]
    x = mapCoordinate(hero.position.x)
    y = mapCoordinate(hero.position.z)
  case action
  of 0:
    discard world.applyWalkTo(hero.id, x, y)
  of 1:
    discard world.applyWalkTo(hero.id, x - 8, y)
  of 2:
    discard world.applyWalkTo(hero.id, x + 8, y)
  of 3 .. 6:
    discard world.applyCastTarget(hero.id, int32(action - 3), hero.id)
  of 7:
    discard world.applyBuyItem(hero.id, 2)
  else:
    raiseAssert "invalid player action"

proc step(match: PlayerMatch, action: int) =
  let actedSeat = match.seats[match.seatIndex]
  match.applyAction(action)
  inc match.seatIndex
  if match.seatIndex == match.seats.len:
    match.seatIndex = 0
    for tick in 0 ..< PlayerActionRepeat:
      if match.game.world.gameOver or match.game.world.tick >= match.maxTicks:
        break
      match.game.tickWorld(proc() = match.game.runBotDecisions())
  let terminal =
    match.game.world.gameOver or match.game.world.tick >= match.maxTicks
  match.snapshot(
    if terminal: actedSeat else: match.seats[match.seatIndex],
    terminal
  )
  let score = match.transition.potential()
  match.transition.reward =
    float32(score - match.previousScore) / 1000'f32 +
    float32(match.transition.outcome) * PlayerOutcomeReward
  match.previousScore = score

proc observationJson(transition: PlayerTransition): string =
  $(%*{
    "type": "observation",
    "features": transition.features,
    "tick": transition.tick,
    "seat": transition.seat,
    "reward": transition.reward,
    "terminal": transition.terminal,
    "outcome": transition.outcome,
    "stateHash": toHex(transition.stateHash, 16),
    "xp": transition.xp,
    "structureHp": transition.structureHp,
    "heroXp": transition.heroXp,
    "heroGold": transition.heroGold,
    "heroKills": transition.heroKills,
    "heroDeaths": transition.heroDeaths,
    "maxWork": transition.maxWork,
    "maxInstructions": transition.maxInstructions
  })

proc servePlayer*(options: PlayerServerOptions) {.async.} =
  doAssert options.maxTicks in 1 .. 28_800
  let
    config = loadConfig(options.config)
    listener = newAsyncHttpServer()
  proc requestHandler(request: Request) {.async, gcsafe.} =
    if request.url.path != "/player" or
        request.headers.getOrDefault("Upgrade").toLowerAscii() != "websocket":
      await request.respond(Http404, "GotA player endpoint is /player\n")
      return
    let ws = await newWebSocket(request)
    defer: ws.close()
    try:
      {.cast(gcsafe).}:
        var
          seed = options.seed
          match = newPlayerMatch(config, options.opponent, options.maxTicks, seed)
        await ws.send(observationJson(match.transition))
        while ws.readyState == Open:
          let (opcode, message) = await ws.receivePacket()
          case opcode
          of Text: discard
          of Ping:
            await ws.send(message, Pong)
            continue
          of Pong: continue
          else: break
          let data = parseJson(message)
          if data.kind != JObject or not data.hasKey("action") or
              data["action"].kind != JInt:
            break
          let action = data["action"].getInt
          if action notin 0 ..< PlayerActionCount:
            break
          match.step(action)
          await ws.send(observationJson(match.transition))
          if match.transition.terminal:
            inc seed
            match = newPlayerMatch(
              config, options.opponent, options.maxTicks, seed
            )
            await ws.send(observationJson(match.transition))
    except CatchableError:
      discard

  await listener.serve(Port(options.port), requestHandler, options.host)

when isMainModule:
  let repo = currentSourcePath().parentDir.parentDir.parentDir
  waitFor servePlayer(PlayerServerOptions(
    host: "127.0.0.1",
    port: 8080,
    opponent: repo / "examples/gods_of_the_arena/players/base.bas",
    config: repo / "examples/gods_of_the_arena/presets/saved.json",
    maxTicks: 28_800,
    seed: 0
  ))
