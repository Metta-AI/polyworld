## Persistent native batch ownership for Gods of the Arena simulations.
import polyworld/pathing
import content, maps, sim

include bots

type
  GotaObservation* = array[16, int32]

  RolloutBuffers* = object
    observations*: array[2, seq[GotaObservation]]
    actions*: array[2, seq[int32]]

  Chunk = object
    games: ptr UncheckedArray[Game]
    observations: array[2, ptr UncheckedArray[GotaObservation]]
    actions: array[2, ptr UncheckedArray[int32]]
    first, last: int

  Command = object
    ticks, firstBuffer: int
    stop: bool

  Worker = object
    chunk: Chunk
    commands: Channel[Command]
    completed: ptr Channel[int]
    index: int

  GotaBatch* = ref object
    games*: seq[Game]
    buffers*: RolloutBuffers
    workers: seq[Worker]
    threads: seq[Thread[ptr Worker]]
    completed: Channel[int]
    nextBuffer*: int
    closed: bool

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

proc writeObservation(game: Game, observation: var GotaObservation) =
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

proc runTicks(chunk: Chunk, ticks, firstBuffer: int) =
  {.cast(gcsafe).}:
    for tick in 0 ..< ticks:
      let buffer = (firstBuffer + tick) and 1
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

proc runWorker(worker: ptr Worker) {.thread, gcsafe.} =
  while true:
    let command = worker.commands.recv()
    if command.stop:
      break
    runTicks(worker.chunk, command.ticks, command.firstBuffer)
    worker.completed[].send(worker.index)

proc newGotaBatch*(count, threadCount: int, config: GotaConfig, bot: string): GotaBatch =
  doAssert count > 0
  doAssert threadCount > 0 and threadCount <= count
  prewarmPathing()
  result = GotaBatch(
    games: newGames(count, config, bot),
    buffers: newRolloutBuffers(count),
    nextBuffer: 0
  )
  result.workers.setLen(threadCount)
  result.threads.setLen(threadCount)
  result.completed.open(threadCount)
  let games = cast[ptr UncheckedArray[Game]](result.games[0].addr)
  let chunkSize = (count + threadCount - 1) div threadCount
  for workerIndex in 0 ..< threadCount:
    let first = workerIndex * chunkSize
    result.workers[workerIndex] = Worker(
      chunk: Chunk(
        games: games,
        first: min(first, count),
        last: min(first + chunkSize, count)
      ),
      completed: result.completed.addr,
      index: workerIndex
    )
    result.workers[workerIndex].commands.open(1)
    for buffer in 0 .. 1:
      result.workers[workerIndex].chunk.observations[buffer] = cast[
        ptr UncheckedArray[GotaObservation]
      ](result.buffers.observations[buffer][0].addr)
      result.workers[workerIndex].chunk.actions[buffer] = cast[
        ptr UncheckedArray[int32]
      ](result.buffers.actions[buffer][0].addr)
    createThread(
      result.threads[workerIndex], runWorker,
      result.workers[workerIndex].addr
    )

proc step*(batch: GotaBatch, ticks: int) =
  doAssert not batch.closed
  doAssert ticks > 0
  for worker in batch.workers.mitems:
    worker.commands.send(Command(ticks: ticks, firstBuffer: batch.nextBuffer))
  for _ in batch.workers:
    discard batch.completed.recv()
  batch.nextBuffer = (batch.nextBuffer + ticks) and 1

proc stateHashes*(batch: GotaBatch): seq[uint64] =
  for game in batch.games:
    result.add stateHash(game)

proc observations*(batch: GotaBatch): seq[GotaObservation] =
  batch.buffers.observations[(batch.nextBuffer + 1) and 1]

proc close*(batch: GotaBatch) =
  if batch.closed:
    return
  for worker in batch.workers.mitems:
    worker.commands.send(Command(stop: true))
  joinThreads(batch.threads)
  for worker in batch.workers.mitems:
    worker.commands.close()
  batch.completed.close()
  batch.closed = true
