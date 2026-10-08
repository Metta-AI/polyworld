## Lockstep decision batches for external GotA trainers.
##
## Every policy-controlled hero is one agent, and every step is one tick, so
## each agent decides every tick. An agent's observation is the 4392-value
## moba-style array of harness.nim and its action is ten heads with sizes
## `ActionSizes`. Two harnesses play identically (tests/test_gota_harness):
## - NimHarness runs harness.nim natively, with no bassy VM at all. The C
##   API picks it when the policy path is "nim".
## - BasicHarness runs a BASIC policy such as harness.bas, which must
##   `dim obs(4391)` and `dim act(9)`. Its `' METTA_DECISION` marker becomes
##   `decided = chooseAction(obs, act)`, which publishes obs() and copies the
##   trainer's latest heads into act(), so scripts never block.
## `step` applies one action per agent, runs one tick of every lane, and
## returns each agent's newest observation and team reward.
## Three rewards, picked by RewardMode:
## - LeaderboardReward follows Emmett's Glory: each hero's whole XP per
##   elapsed minute, averaged over the team and divided by 1000. Steps reward
##   the change in that potential; a loss, draw, or timeout cancels it, so the
##   episode's total reward is the winning team's Glory divided by 1000.
## - XpReward is the change in the team's total XP divided by 100, with no
##   tick penalty and no reset on a loss, so a policy learns from scratch.
## - XpOutcomeReward is XpReward plus OutcomeBonus for a win and minus it
##   for a loss or timeout, so surviving matters beyond the next XP.
## With `selfPlay` both teams run the policy (10 agents per lane);
## otherwise one team plays a bundled opponent (5 agents per lane).
## Finished lanes restart with the next seed inside the same step.
import
  std/strutils,
  harness
include bots

export ObservationSize, ActionSizes, ActionCount

const
  ScoreTicksPerMinute = int64(TickRate * 60)
  ScoreDenominator = 5 * ScoreTicksPerMinute * 1000
  GotaSourceCommit {.strdefine.} = ""
  TeamSize = 5
  NimHarnessPolicy* = "nim"
    ## The gota_create policy path that selects NimHarness.
  BasicArrayCells = 8192
    ## Array cells for BASIC policies; obs() alone needs 4392.
  XpDenominator = 100
  OutcomeBonus = 50'f32

type
  RewardMode* = enum
    LeaderboardReward, XpReward, XpOutcomeReward

  HarnessMode* = enum
    ## How policy heroes think: a BASIC policy in one bassy VM per hero,
    ## or harness.nim, the native port of harness.bas.
    BasicHarness, NimHarness

  LaneStats* {.bycopy.} = object
    ## Summary of one finished match, from the first policy team's side.
    finished*, outcome*, tick*, selfPlay*: int32
    potential*: int64
      ## Leaderboard score numerator at the end; points = potential / 7200.

  StepLane = object
    game: Game
    seed: int
    team: Team
      ## The first policy team; selfPlay lanes also control the other.
    agents: seq[int]
      ## Hero index of each of this lane's agents, in agent order.
    observations: seq[array[ObservationSize, int32]]
    actions: seq[array[ActionCount, int32]]
    potentials: array[Team, int64]
    harnesses: seq[Harness]
      ## Native hero state of each agent under NimHarness.
    agentOf: seq[int]
      ## Agent of each hero index, or -1 for a bundled opponent.

  StepBatch* = ref object
    lanes: seq[StepLane]
    configPath, bot, policy: string
    opponents: seq[string]
    maxTicks: int
    selfPlay: bool
    rewardMode: RewardMode
    harness: HarnessMode
    agentsPerLane*: int

proc teamPotential(world: World, team: Team): int64 =
  ## Scales whole XP per minute into the training API's score numerator.
  for hero in world.heroes:
    if hero.team == team:
      result += int64(xpPerMinute(hero.totalXp, int(world.tick))) *
        ScoreTicksPerMinute

proc teamXp(world: World, team: Team): int64 =
  ## Total XP earned by one team's heroes.
  for hero in world.heroes:
    if hero.team == team:
      result += int64(hero.totalXp)

proc outcome(world: World, team: Team, timedOut: bool): int32 =
  ## 1 for a win, -1 for a loss or timeout, 0 while playing.
  if world.gameOver and not world.draw and world.winner == team: 1
  elif world.gameOver or timedOut: -1
  else: 0

proc compilePolicy(
    batch: StepBatch,
    lane: ptr StepLane,
    index, agent: int
) =
  ## Compiles the BASIC policy for one hero with a non-blocking chooseAction.
  let
    game = lane.game
    hero = game.world.heroes[index]
  var
    host = initHeroHost(hero.id)
    limits = heroVmLimits()
  limits.disableFixed = true
  limits.maxArrayElements = BasicArrayCells
  discard host.addFunction("chooseAction", 2,
    proc(runtime: Runtime, arguments: openArray[Value]): Value =
      ## Publishes obs() and copies the agent's latest heads into act().
      let
        observation = runtime.arrayView(arguments[0])
        decision = runtime.arrayView(arguments[1], writable = true)
      doAssert observation.len == ObservationSize,
        "chooseAction needs dim obs(" & $(ObservationSize - 1) & ")"
      doAssert decision.len == ActionCount,
        "chooseAction needs dim act(" & $(ActionCount - 1) & ")"
      for i in 0 ..< ObservationSize:
        lane.observations[agent][i] = observation[i].asInt
      for head in 0 ..< ActionCount:
        decision[head] = toValue(lane.actions[agent][head])
      toValue(1'i32),
    1)
  inc limits.maxHostFunctions
  let source = batch.policy.replace("' METTA_DECISION",
    "decided = chooseAction(obs, act)")
  let program = compile(source, host, limits)
  bindHeroData(program)
  game.heroVms[index] = HeroVm(
    runtime: initRuntime(program, host, limits), limits: limits, ready: true,
    legacyHeroData: true
  )

proc installPolicy(batch: StepBatch, lane: ptr StepLane, index: int) =
  ## Makes one hero an agent that thinks natively or through BASIC.
  let agent = lane.agents.len
  lane.agents.add index
  lane.observations.add default(array[ObservationSize, int32])
  lane.actions.add default(array[ActionCount, int32])
  lane.agentOf[index] = agent
  case batch.harness
  of BasicHarness:
    batch.compilePolicy(lane, index, agent)
  of NimHarness:
    lane.harnesses.add Harness()
    lane.game.heroVms[index] = nil

proc startLane(batch: StepBatch, lane: ptr StepLane, seed: int) =
  ## Builds a fresh match for one lane and installs the policy scripts.
  let
    config = loadConfig(batch.configPath)
    gameMap = generateMap(int32(seed), config.mapPreset)
    game = newGame(
      gameMap, config.spawnIntervalTicks, 10, false, ReplayData(), false
    )
    team = Team((seed mod 10) div 5)
    opponent = batch.opponents[(seed div 10) mod batch.opponents.len]
    groups =
      if team == RedTeam:
        @[BotGroup(path: batch.bot, count: TeamSize),
          BotGroup(path: opponent, count: TeamSize)]
      else:
        @[BotGroup(path: opponent, count: TeamSize),
          BotGroup(path: batch.bot, count: TeamSize)]
  if batch.harness == NimHarness and batch.selfPlay:
    # Every hero is an agent, so no bundled bot needs compiling.
    game.heroVms = newSeq[HeroVm](game.world.heroes.len)
  else:
    loadBots(game, groups)
  game.replayData = initReplayData(
    currentSetup(game, uint32(batch.maxTicks)), gameMap.preset
  )
  lane.game = game
  lane.seed = seed
  lane.team = team
  lane.agents.setLen(0)
  lane.observations.setLen(0)
  lane.actions.setLen(0)
  lane.harnesses.setLen(0)
  lane.agentOf.setLen(game.world.heroes.len)
  for agent in lane.agentOf.mitems:
    agent = -1
  for index, hero in game.world.heroes:
    if hero.team == team:
      batch.installPolicy(lane, index)
  if batch.selfPlay:
    for index, hero in game.world.heroes:
      if hero.team != team:
        batch.installPolicy(lane, index)
  doAssert lane.agents.len == batch.agentsPerLane
  for side in Team:
    lane.potentials[side] =
      case batch.rewardMode
      of LeaderboardReward: teamPotential(game.world, side)
      of XpReward, XpOutcomeReward: teamXp(game.world, side)

proc newStepBatch*(
    configPath, bot, opponent, policy: string,
    count, maxTicks: int,
    selfPlay: bool,
    rewardMode = LeaderboardReward,
    harness = BasicHarness
): StepBatch =
  ## Starts `count` lanes seeded 0 ..< count.
  doAssert count > 0 and maxTicks in 1 .. 28_800
  let opponents = opponent.splitLines()
  doAssert opponents.len > 0
  result = StepBatch(
    configPath: configPath,
    bot: bot,
    opponents: opponents,
    policy: policy,
    maxTicks: maxTicks,
    selfPlay: selfPlay,
    rewardMode: rewardMode,
    harness: harness,
    agentsPerLane: if selfPlay: 2 * TeamSize else: TeamSize
  )
  result.lanes.setLen(count)
  for i in 0 ..< count:
    result.startLane(result.lanes[i].addr, i)

proc agentCount*(batch: StepBatch): int =
  ## Agents across every lane.
  batch.lanes.len * batch.agentsPerLane

proc reset*(batch: StepBatch, seed: int) =
  ## Restarts every lane; -1 continues each lane's seed sequence.
  for i in 0 ..< batch.lanes.len:
    let next =
      if seed == -1: batch.lanes[i].seed + batch.lanes.len
      else: seed * batch.lanes.len + i
    batch.startLane(batch.lanes[i].addr, next)

proc thinkHero(lane: ptr StepLane, index: int) =
  ## Runs one hero's decision natively for an agent, else through its VM.
  if index >= 0 and lane.agentOf[index] >= 0:
    let agent = lane.agentOf[index]
    lane.harnesses[agent].think(
      lane.game,
      index,
      lane.actions[agent],
      lane.observations[agent]
    )
  else:
    runHeroScript(lane.game, index)

proc runLaneDecisions(lane: ptr StepLane) =
  ## Mirrors runBotDecisions: the same frame, order, and turn rotation.
  let game = lane.game
  activeGame = game
  if game.structuredBots:
    game.refreshStructureCounts()
  if game.world.phase == Drafting:
    lane.thinkHero(game.world.heroIndex(game.world.draftHeroId()))
    return
  let ownsFrame = game.world.freezeObservations()
  defer:
    if ownsFrame:
      game.world.thawObservations()
  for offset in 0 ..< game.world.heroes.len:
    let index = (game.world.heroTurnStart + offset) mod game.world.heroes.len
    lane.thinkHero(index)
  game.world.heroTurnStart =
    (game.world.heroTurnStart + 1) mod game.world.heroes.len

proc observe*(
    batch: StepBatch,
    observations: var openArray[int32],
    seats: var openArray[int32]
) =
  ## Writes each agent's newest observation and its seat within its team.
  var agent = 0
  for lane in batch.lanes:
    for i, index in lane.agents:
      copyMem(
        observations[agent * ObservationSize].addr,
        lane.observations[i][0].addr,
        ObservationSize * sizeof(int32)
      )
      seats[agent] = int32(index mod TeamSize)
      inc agent

proc step*(
    batch: StepBatch,
    actions: openArray[int32],
    rewards: var openArray[float32],
    terminals: var openArray[uint8],
    stats: var openArray[LaneStats]
) =
  ## Runs one tick of every lane with ActionCount heads per agent.
  doAssert actions.len == batch.agentCount * ActionCount
  var agent = 0
  for laneIndex in 0 ..< batch.lanes.len:
    let lane = batch.lanes[laneIndex].addr
    for i in 0 ..< lane.agents.len:
      for head in 0 ..< ActionCount:
        let action = actions[(agent + i) * ActionCount + head]
        doAssert action in 0'i32 ..< ActionSizes[head]
        lane.actions[i][head] = action
    let game = lane.game
    if not game.world.gameOver and game.world.tick < batch.maxTicks:
      activeGame = game
      case batch.harness
      of BasicHarness:
        tickWorld(game, proc() = runBotDecisions(game))
      of NimHarness:
        tickWorld(game, proc() = runLaneDecisions(lane))
    for vm in game.heroVms:
      doAssert vm == nil or not vm.failed, vm.lastError
    let
      done = game.world.gameOver or game.world.tick >= batch.maxTicks
      world = game.world
    var reward: array[Team, float32]
    for side in Team:
      case batch.rewardMode
      of LeaderboardReward:
        let potential =
          if done and outcome(world, side, true) != 1: 0'i64
          else: teamPotential(world, side)
        reward[side] = float32(potential - lane.potentials[side]) /
          float32(ScoreDenominator)
        lane.potentials[side] = potential
      of XpReward, XpOutcomeReward:
        let xp = teamXp(world, side)
        reward[side] = float32(xp - lane.potentials[side]) /
          float32(XpDenominator)
        if batch.rewardMode == XpOutcomeReward and done:
          reward[side] +=
            float32(outcome(world, side, true)) * OutcomeBonus
        lane.potentials[side] = xp
    stats[laneIndex] = LaneStats()
    if done:
      stats[laneIndex] = LaneStats(
        finished: 1,
        outcome: outcome(world, lane.team, true),
        tick: world.tick,
        selfPlay: int32(batch.selfPlay),
        potential:
          if outcome(world, lane.team, true) == 1:
            teamPotential(world, lane.team)
          else:
            0
      )
    for i, index in lane.agents:
      rewards[agent + i] = reward[world.heroes[index].team]
      terminals[agent + i] = uint8(done)
    if done:
      batch.startLane(lane, lane.seed + batch.lanes.len)
    agent += lane.agents.len

proc gota_source_commit(): cstring {.cdecl, exportc, dynlib.} =
  GotaSourceCommit.cstring

proc gota_stats_size(): cint {.cdecl, exportc, dynlib.} =
  cint(sizeof(LaneStats))

proc gota_observation_size(): cint {.cdecl, exportc, dynlib.} =
  cint(ObservationSize)

proc gota_action_count(): cint {.cdecl, exportc, dynlib.} =
  cint(ActionCount)

proc gota_create(
    config, bot, opponent, policy: cstring,
    count, maxTicks, selfPlay, rewardMode: cint
): pointer {.cdecl, exportc, dynlib.} =
  doAssert rewardMode in 0 .. RewardMode.high.ord, "unknown reward mode"
  let
    harness =
      if $policy == NimHarnessPolicy: NimHarness
      else: BasicHarness
    source =
      if harness == NimHarness: ""
      else: readFile($policy)
    batch = newStepBatch($config, $bot, $opponent, source,
      int(count), int(maxTicks), selfPlay != 0,
      RewardMode(rewardMode), harness)
  GC_ref(batch)
  cast[pointer](batch)

proc gota_agents(handle: pointer): cint {.cdecl, exportc, dynlib.} =
  cint(cast[StepBatch](handle).agentCount)

proc gota_reset(
    handle: pointer,
    seed: int64,
    observations, seats: ptr UncheckedArray[int32]
) {.cdecl, exportc, dynlib.} =
  let batch = cast[StepBatch](handle)
  batch.reset(int(seed))
  let count = batch.agentCount
  batch.observe(
    observations.toOpenArray(0, count * ObservationSize - 1),
    seats.toOpenArray(0, count - 1)
  )

proc gota_step(
    handle: pointer,
    actions: ptr UncheckedArray[int32],
    observations, seats: ptr UncheckedArray[int32],
    rewards: ptr UncheckedArray[float32],
    terminals: ptr UncheckedArray[uint8],
    stats: ptr UncheckedArray[LaneStats]
) {.cdecl, exportc, dynlib.} =
  let
    batch = cast[StepBatch](handle)
    count = batch.agentCount
  batch.step(
    actions.toOpenArray(0, count * ActionCount - 1),
    rewards.toOpenArray(0, count - 1),
    terminals.toOpenArray(0, count - 1),
    stats.toOpenArray(0, batch.lanes.len - 1)
  )
  batch.observe(
    observations.toOpenArray(0, count * ObservationSize - 1),
    seats.toOpenArray(0, count - 1)
  )

proc gota_close(handle: pointer) {.cdecl, exportc, dynlib.} =
  GC_unref(cast[StepBatch](handle))
