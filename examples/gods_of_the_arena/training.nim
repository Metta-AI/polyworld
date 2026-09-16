## Native decision batches. Puffer workers parallelize independent batch handles.
## Lanes advance sequentially; this API creates no processes or worker threads.
import std/strutils
include bots

const GotaSourceCommit {.strdefine.} = ""

type
  Transition* {.bycopy.} = object
    features*: array[16, float32]
    reward*: float32
    terminal*, tick*, seat*, outcome*: int32
    stateHash*: uint64
    xp*, structureHp*, maxWork*, maxInstructions*: int64

  TickCursor = iterator(): bool {.closure.}
  TrainingLane* = ref object
    game*: Game
    cursor: TickCursor
    inTick, waiting: bool
    nextHero, seat, seed, maxTicks: int
    previousScore: int64
    transition*: Transition

  TrainingBatch* = ref object
    lanes*: seq[TrainingLane]
    config: GotaConfig
    bot, opponent, policy: string
    maxTicks: int

proc snapshot(lane: TrainingLane, terminal: bool) =
  let game = lane.game
  let team = game.world.heroes[lane.seat].team
  lane.transition.xp = 0
  lane.transition.structureHp = 0
  for hero in game.world.heroes:
    lane.transition.xp += (if hero.team == team: 1 else: -1) * hero.totalXp
  for building in game.world.buildings:
    if building.kind == TowerBuilding:
      lane.transition.structureHp += (if building.team == team: 1 else: -1) * max(building.hp, 0)
  for fort in game.world.forts:
    lane.transition.structureHp += (if fort.team == team: 1 else: -1) * max(fort.hp, 0)
  for vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
    lane.transition.maxWork = max(lane.transition.maxWork, vm.lastWork)
    lane.transition.maxInstructions = max(lane.transition.maxInstructions, vm.lastInstructions)
  lane.transition.tick = game.world.tick
  lane.transition.seat = int32(lane.seat)
  lane.transition.terminal = int32(terminal)
  lane.transition.outcome =
    if not game.world.gameOver: 0
    elif game.world.winner == team: 1
    else: -1
  lane.transition.stateHash = stateHash(game)

proc advance*(lane: TrainingLane, action: int32 = 0) =
  let game = lane.game
  if lane.waiting:
    doAssert action in 0 .. 7
    resumeHeroScript(game, lane.seat, action)
    lane.waiting = false
    inc lane.nextHero
  while true:
    if not lane.inTick:
      if game.world.gameOver or game.world.tick >= lane.maxTicks:
        lane.snapshot(true)
        return
      lane.cursor = iterator(): bool {.closure.} =
        for ready in tickWorldSteps(game):
          yield ready
      discard lane.cursor()
      if finished(lane.cursor):
        continue
      lane.inTick = true
      lane.nextHero = 0
    while lane.nextHero < game.world.heroes.len:
      let index = (game.world.heroTurnStart + lane.nextHero) mod game.world.heroes.len
      runHeroScript(game, index)
      if index == lane.seat and game.heroVms[index].runtime.hostCallPaused:
        lane.waiting = true
        lane.snapshot(false)
        return
      inc lane.nextHero
    game.world.heroTurnStart = (game.world.heroTurnStart + 1) mod game.world.heroes.len
    discard lane.cursor()
    doAssert finished(lane.cursor)
    for vm in game.heroVms:
      lane.transition.maxWork = max(lane.transition.maxWork, vm.lastWork)
      lane.transition.maxInstructions = max(lane.transition.maxInstructions, vm.lastInstructions)
    lane.inTick = false

proc newLane(batch: TrainingBatch, seed: int): TrainingLane =
  let gameMap = generateMap(int32(seed), batch.config.mapPreset)
  let game = newGame(gameMap, batch.config.spawnIntervalTicks, 10, false, ReplayData())
  let seat = seed mod 10
  let groups =
    if seat < 5:
      @[BotGroup(path: batch.bot, count: 5), BotGroup(path: batch.opponent, count: 5)]
    else:
      @[BotGroup(path: batch.opponent, count: 5), BotGroup(path: batch.bot, count: 5)]
  loadBots(game, groups)
  game.replayData = initReplayData(currentSetup(game, uint32(batch.maxTicks)), gameMap.preset)
  let lane = TrainingLane(game: game, seat: seat, seed: seed, maxTicks: batch.maxTicks)
  var host = initHeroHost(game, game.world.heroes[seat].id)
  var limits = heroVmLimits()
  discard host.addFunction("chooseAction", 16, proc(values: openArray[int32]): int32 =
    for index, value in values:
      doAssert value in -100 .. 100
      lane.transition.features[index] = float32(value)
    game.heroVms[seat].runtime.pauseHostCall()
    0'i32, 1)
  inc limits.maxHostFunctions
  let source = batch.policy.replace("' METTA_DECISION",
    "decision = chooseAction(f(0),f(1),f(2),f(3),f(4),f(5),f(6),f(7)," &
    "f(8),f(9),f(10),f(11),f(12),f(13),f(14),f(15))")
  let program = compile(source, host, limits)
  bindHeroData(program)
  game.heroVms[seat] = HeroVm(runtime: initRuntime(program, host, limits), limits: limits, ready: true)
  lane.advance()
  lane.previousScore = lane.transition.xp + lane.transition.structureHp
  result = lane

proc reset*(batch: TrainingBatch, seed: int) =
  for index in 0 ..< batch.lanes.len:
    let nextSeed =
      if seed == -1: batch.lanes[index].seed + batch.lanes.len
      else: seed * batch.lanes.len + index
    batch.lanes[index].game.heroVms.setLen(0)
    batch.lanes[index].cursor = nil
    batch.lanes[index] = batch.newLane(nextSeed)

proc newTrainingBatch*(config: GotaConfig, bot, opponent, policy: string,
                       count, maxTicks: int): TrainingBatch =
  doAssert count > 0 and maxTicks in 1 .. 28_800
  result = TrainingBatch(config: config, bot: bot, opponent: opponent, policy: policy, maxTicks: maxTicks)
  for index in 0 ..< count:
    result.lanes.add result.newLane(index)

proc step*(batch: TrainingBatch, actions: openArray[int32], transitions: var openArray[Transition]) =
  doAssert actions.len == batch.lanes.len and transitions.len == batch.lanes.len
  for index, lane in batch.lanes:
    lane.advance(actions[index])
    let score = lane.transition.xp + lane.transition.structureHp
    lane.transition.reward = float32(score - lane.previousScore) / 1000'f32
    lane.previousScore = score
    if lane.transition.terminal != 0:
      lane.transition.reward += float32(lane.transition.outcome) * 10'f32
    transitions[index] = lane.transition
    if lane.transition.terminal != 0:
      lane.game.heroVms.setLen(0)
      lane.cursor = nil
      batch.lanes[index] = batch.newLane(lane.seed + batch.lanes.len)

proc gota_source_commit(): cstring {.cdecl, exportc, dynlib.} =
  GotaSourceCommit.cstring

proc gota_transition_size(): cint {.cdecl, exportc, dynlib.} =
  cint(sizeof(Transition))

proc gota_create(config, bot, opponent, policy: cstring, count, maxTicks: cint): pointer {.cdecl, exportc, dynlib.} =
  let batch = newTrainingBatch(loadConfig($config), $bot, $opponent, readFile($policy), int(count), int(maxTicks))
  GC_ref(batch)
  cast[pointer](batch)

proc gota_reset(handle: pointer, seed: int64, observations: ptr UncheckedArray[float32],
                transitions: ptr UncheckedArray[Transition]) {.cdecl, exportc, dynlib.} =
  let batch = cast[TrainingBatch](handle)
  batch.reset(int(seed))
  for index, lane in batch.lanes:
    copyMem(observations[index * 16].addr, lane.transition.features[0].addr, 16 * sizeof(float32))
    transitions[index] = lane.transition

proc gota_step(handle: pointer, actions: ptr UncheckedArray[int32],
               observations, rewards: ptr UncheckedArray[float32],
               terminals: ptr UncheckedArray[uint8],
               transitions: ptr UncheckedArray[Transition]) {.cdecl, exportc, dynlib.} =
  let batch = cast[TrainingBatch](handle)
  let count = batch.lanes.len
  batch.step(actions.toOpenArray(0, count - 1), transitions.toOpenArray(0, count - 1))
  for index, lane in batch.lanes:
    copyMem(observations[index * 16].addr, lane.transition.features[0].addr, 16 * sizeof(float32))
    rewards[index] = transitions[index].reward
    terminals[index] = uint8(transitions[index].terminal)

proc close*(batch: TrainingBatch) =
  # Host closures reference their lane; release them before dropping the handle.
  for lane in batch.lanes:
    lane.game.heroVms.setLen(0)
    lane.cursor = nil

proc gota_close(handle: pointer) {.cdecl, exportc, dynlib.} =
  let batch = cast[TrainingBatch](handle)
  batch.close()
  GC_unref(batch)
