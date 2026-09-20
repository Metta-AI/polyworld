## Native decision batches. Puffer workers parallelize independent batch handles.
## Lanes advance sequentially; this API creates no processes or worker threads.
import std/strutils
include bots

const
  GotaSourceCommit {.strdefine.} = ""
  GotaFeatureCount* = 37
  GotaActionCount* = 22
  GotaOutcomeReward* = 100'f32
  GotaActionRepeat* = 4

type
  Transition* {.bycopy.} = object
    features*: array[GotaFeatureCount, float32]
    reward*: float32
    terminal*, tick*, seat*, outcome*: int32
    stateHash*: uint64
    xp*, structureHp*, heroXp*, heroGold*, heroKills*, heroDeaths*: int64
    maxWork*, maxInstructions*: int64

  TickCursor = iterator(): bool {.closure.}
  TrainingLane* = ref object
    game*: Game
    cursor: TickCursor
    inTick, waiting: bool
    nextHero, seed, maxTicks: int
    team: Team
    previousScore: int64
    transition*: Transition

  TrainingBatch* = ref object
    lanes*: seq[TrainingLane]
    config: GotaConfig
    bot, policy: string
    opponents: seq[string]
    maxTicks: int

proc trainingPotential*(transition: Transition): int64 =
  transition.xp + transition.structureHp

proc trainingReward*(previous, current: int64, outcome: int32): float32 =
  float32(current - previous) / 1000'f32 + float32(outcome) * GotaOutcomeReward

proc snapshot(lane: TrainingLane, terminal: bool) =
  let game = lane.game
  let team = lane.team
  lane.transition.xp = 0
  lane.transition.structureHp = 0
  for hero in game.world.heroes:
    lane.transition.xp += (if hero.team == team: 1 else: -1) * hero.totalXp
  for building in game.world.buildings:
    if building.kind == TowerBuilding:
      lane.transition.structureHp += 2 * (if building.team == team: 1 else: -1) * max(building.hp, 0)
  for fort in game.world.forts:
    lane.transition.structureHp += 20 * (if fort.team == team: 1 else: -1) * max(fort.hp, 0)
  let hero = game.world.heroes[lane.transition.seat]
  lane.transition.heroXp = hero.totalXp
  lane.transition.heroGold = game.world.stats.values[lane.transition.seat][GoldMetric]
  lane.transition.heroKills = game.world.stats.values[lane.transition.seat][KillsMetric]
  lane.transition.heroDeaths = game.world.stats.values[lane.transition.seat][LossesMetric]
  for vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
    lane.transition.maxWork = max(lane.transition.maxWork, vm.lastWork)
    lane.transition.maxInstructions = max(lane.transition.maxInstructions, vm.lastInstructions)
  lane.transition.tick = game.world.tick
  lane.transition.terminal = int32(terminal)
  lane.transition.outcome =
    if game.world.gameOver and game.world.winner == team: 1
    elif game.world.gameOver or terminal: -1
    else: 0
  lane.transition.stateHash = stateHash(game)

proc advance*(lane: TrainingLane, action: int32 = 0) =
  let game = lane.game
  if lane.waiting:
    doAssert action in 0 ..< GotaActionCount
    resumeHeroScript(game, int(lane.transition.seat), action)
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
      if game.world.heroes[index].team == lane.team and game.heroVms[index].runtime.hostCallPaused:
        lane.waiting = true
        lane.transition.seat = int32(index)
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

proc installTrainingPolicy(lane: TrainingLane, seat: int, source: string) =
  let game = lane.game
  var host = initHeroHost(game, game.world.heroes[seat].id)
  var limits = heroVmLimits()
  limits.maxParameters = GotaFeatureCount
  let laneAddress = cast[pointer](lane)
  discard host.addFunction("chooseAction", GotaFeatureCount, proc(values: openArray[int32]): int32 =
    let callbackLane = cast[TrainingLane](laneAddress)
    for index, value in values:
      doAssert value in -100 .. 100
      callbackLane.transition.features[index] = float32(value)
    callbackLane.game.heroVms[seat].runtime.pauseHostCall()
    0'i32, 1)
  inc limits.maxHostFunctions
  let program = compile(source, host, limits)
  bindHeroData(program)
  game.heroVms[seat] = HeroVm(runtime: initRuntime(program, host, limits), limits: limits, ready: true)

proc newLane(batch: TrainingBatch, seed: int): TrainingLane =
  let gameMap = generateMap(int32(seed), batch.config.mapPreset)
  let game = newGame(gameMap, batch.config.spawnIntervalTicks, 10, false, ReplayData())
  let team = Team((seed mod 10) div 5)
  let opponent = batch.opponents[(seed div 10) mod batch.opponents.len]
  let groups =
    if team == Team(0):
      @[BotGroup(path: batch.bot, count: 5), BotGroup(path: opponent, count: 5)]
    else:
      @[BotGroup(path: opponent, count: 5), BotGroup(path: batch.bot, count: 5)]
  loadBots(game, groups)
  game.replayData = initReplayData(currentSetup(game, uint32(batch.maxTicks)), gameMap.preset)
  let lane = TrainingLane(game: game, team: team, seed: seed, maxTicks: batch.maxTicks)
  var featureArguments: seq[string]
  for index in 0 ..< GotaFeatureCount:
    featureArguments.add "f(" & $index & ")"
  let source = batch.policy.replace("' METTA_DECISION",
    "neuralActionCountdown = neuralActionCountdown - 1\n" &
    "if neuralActionCountdown <= 0 then\n" &
    "  neuralActionCountdown = " & $GotaActionRepeat & "\n" &
    "  decision = chooseAction(" & featureArguments.join(",") & ")\n" &
    "end if")
  for seat, hero in game.world.heroes:
    if hero.team == team:
      lane.installTrainingPolicy(seat, source)
  lane.advance()
  lane.previousScore = lane.transition.trainingPotential()
  result = lane

proc reset*(batch: TrainingBatch, seed: int) =
  for index in 0 ..< batch.lanes.len:
    let nextSeed =
      if seed == -1: batch.lanes[index].seed + batch.lanes.len
      else: seed * batch.lanes.len + index
    batch.lanes[index] = batch.newLane(nextSeed)

proc newTrainingBatch*(config: GotaConfig, bot, opponent, policy: string,
                       count, maxTicks: int): TrainingBatch =
  doAssert count > 0 and maxTicks in 1 .. 28_800
  let opponents = opponent.splitLines()
  doAssert opponents.len > 0
  for path in opponents:
    doAssert path.len > 0
  result = TrainingBatch(config: config, bot: bot, opponents: opponents, policy: policy, maxTicks: maxTicks)
  for index in 0 ..< count:
    result.lanes.add result.newLane(index)

proc step*(batch: TrainingBatch, actions: openArray[int32], transitions: var openArray[Transition]) =
  doAssert actions.len == batch.lanes.len and transitions.len == batch.lanes.len
  for index, lane in batch.lanes:
    lane.advance(actions[index])
    let currentScore = lane.transition.trainingPotential()
    lane.transition.reward = trainingReward(lane.previousScore, currentScore, lane.transition.outcome)
    lane.previousScore = currentScore
    transitions[index] = lane.transition
    if lane.transition.terminal != 0:
      let replacement = batch.newLane(lane.seed + batch.lanes.len)
      batch.lanes[index] = replacement

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
    copyMem(observations[index * GotaFeatureCount].addr,
      lane.transition.features[0].addr, GotaFeatureCount * sizeof(float32))
    transitions[index] = lane.transition

proc gota_step(handle: pointer, actions: ptr UncheckedArray[int32],
               observations, rewards: ptr UncheckedArray[float32],
               terminals: ptr UncheckedArray[uint8],
               transitions: ptr UncheckedArray[Transition]) {.cdecl, exportc, dynlib.} =
  let batch = cast[TrainingBatch](handle)
  let count = batch.lanes.len
  batch.step(actions.toOpenArray(0, count - 1), transitions.toOpenArray(0, count - 1))
  for index, lane in batch.lanes:
    copyMem(observations[index * GotaFeatureCount].addr,
      lane.transition.features[0].addr, GotaFeatureCount * sizeof(float32))
    rewards[index] = transitions[index].reward
    terminals[index] = uint8(transitions[index].terminal)

proc close*(batch: TrainingBatch) =
  batch.lanes.setLen(0)

proc gota_close(handle: pointer) {.cdecl, exportc, dynlib.} =
  let batch = cast[TrainingBatch](handle)
  batch.close()
  GC_unref(batch)
