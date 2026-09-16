## Compares scalar and static-thread batched GotA simulation.
## Compile with -d:headless --threads:on and supply the BASIC bot path.
import
  std/[monotimes, os, parseutils, strformat, times],
  polyworld/pathing,
  ../examples/gods_of_the_arena/[content, maps, sim]

include ../examples/gods_of_the_arena/bots

type RunResult = object
  hashes: seq[uint64]
  observations: seq[array[16, int32]]
  seconds: float64

type RolloutBuffers = object
  observations: array[2, seq[array[16, int32]]]
  actions: array[2, seq[int32]]

type Chunk = object
  games: ptr UncheckedArray[Game]
  observations: array[2, ptr UncheckedArray[array[16, int32]]]
  actions: array[2, ptr UncheckedArray[int32]]
  first, last, ticks: int

proc parsePositive(value, name: string): int =
  if parseInt(value, result) != value.len or result <= 0:
    raise newException(ValueError, name & " must be a positive integer")

proc newGames(count: int, config: GotaConfig, bot: string): seq[Game] =
  let groups = @[BotGroup(path: bot, count: 10)]
  for index in 0 ..< count:
    let gameMap = generateMap(int32(index), config.mapPreset)
    let game = newGame(
      gameMap, config.spawnIntervalTicks, 10, false, ReplayData()
    )
    loadBots(game, groups)
    result.add game

proc newRolloutBuffers(count: int): RolloutBuffers =
  for buffer in 0 .. 1:
    result.observations[buffer].setLen(count)
    result.actions[buffer].setLen(count)
    for index in 0 ..< count:
      result.actions[buffer][index] = int32((index + buffer) mod 3)

proc writeObservation(game: Game, observation: var array[16, int32]) =
  let hero = game.world.heroes[0]
  observation = [
    hero.hp, hero.maxHp, hero.mana, hero.maxMana,
    int32(hero.gold), int32(hero.level), hero.position.x, hero.position.z,
    int32(hero.team.ord), int32(hero.class.ord),
    hero.cooldowns[HeroAbilitySlot(0)],
    hero.cooldowns[HeroAbilitySlot(1)],
    hero.cooldowns[HeroAbilitySlot(2)],
    hero.cooldowns[HeroAbilitySlot(3)],
    game.world.tick, int32(game.world.footmen.len)
  ]

proc chunk(
    games: seq[Game], buffers: var RolloutBuffers,
    first, last, ticks: int
): Chunk =
  result = Chunk(
    games: cast[ptr UncheckedArray[Game]](games[0].addr),
    first: first,
    last: last,
    ticks: ticks
  )
  for buffer in 0 .. 1:
    result.observations[buffer] = cast[
      ptr UncheckedArray[array[16, int32]]
    ](buffers.observations[buffer][0].addr)
    result.actions[buffer] = cast[
      ptr UncheckedArray[int32]
    ](buffers.actions[buffer][0].addr)

proc runChunk(chunk: Chunk) {.thread, gcsafe.} =
  {.cast(gcsafe).}:
    for tick in 0 ..< chunk.ticks:
      let buffer = tick and 1
      for index in chunk.first ..< chunk.last:
        let game = chunk.games[index]
        let hero = game.world.heroes[0]
        case chunk.actions[buffer][index]
        of 1:
          discard game.world.applyAttackMove(
            hero.id, mapTiles().int32 - 10, 10
          )
        of 2:
          discard game.world.applyAttackMove(
            hero.id, 10, mapTiles().int32 - 10
          )
        else:
          discard
        tickWorld(game, proc() = runBotDecisions(game))
        writeObservation(game, chunk.observations[buffer][index])

proc runScalar(games: seq[Game], ticks: int): RunResult =
  var buffers = newRolloutBuffers(games.len)
  let started = getMonoTime()
  runChunk(chunk(games, buffers, 0, games.len, ticks))
  result.seconds = (getMonoTime() - started).inNanoseconds.float64 / 1e9
  for game in games:
    result.hashes.add stateHash(game)
  result.observations = buffers.observations[(ticks - 1) and 1]

proc runBatch(games: seq[Game], ticks, threads: int): RunResult =
  var buffers = newRolloutBuffers(games.len)
  let started = getMonoTime()
  let chunk = (games.len + threads - 1) div threads
  var workers = newSeq[Thread[Chunk]](threads)
  for worker in 0 ..< threads:
    let first = worker * chunk
    createThread(
      workers[worker], runChunk,
      chunk(
        games, buffers, min(first, games.len),
        min(first + chunk, games.len), ticks
      )
    )
  joinThreads(workers)
  result.seconds = (getMonoTime() - started).inNanoseconds.float64 / 1e9
  for game in games:
    result.hashes.add stateHash(game)
  result.observations = buffers.observations[(ticks - 1) and 1]

let arguments = commandLineParams()
if arguments.len != 4:
  quit "benchmark_gota_batch CONFIG BOT GAMES TICKS", QuitFailure
let
  config = loadConfig(arguments[0])
  bot = arguments[1]
  count = parsePositive(arguments[2], "GAMES")
  ticks = parsePositive(arguments[3], "TICKS")
  threads = count

discard newGames(1, config, bot)
prewarmPathing()

let
  scalar = runScalar(newGames(count, config, bot), ticks)
  batch = runBatch(newGames(count, config, bot), ticks, threads)

doAssert scalar.hashes == batch.hashes
doAssert scalar.observations == batch.observations
echo &"games={count} ticks={ticks} threads={threads} " &
  &"scalar_seconds={scalar.seconds:.6f} batch_seconds={batch.seconds:.6f} " &
  &"speedup={scalar.seconds / batch.seconds:.3f}"
