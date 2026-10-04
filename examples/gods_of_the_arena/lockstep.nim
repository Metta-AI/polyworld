## Lockstep decision batches for external GotA trainers.
##
## Every policy-controlled hero is one agent. The policy script calls
## `chooseAction(f(0..N-1))` where the `' METTA_DECISION` marker sits; the
## call records the hero's latest features and returns the action the
## trainer last chose for it, so scripts never block and no threads are
## needed. `step` applies one action per agent, runs `actionTicks` ticks of
## every lane, and returns each agent's newest features and team reward.
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
import std/strutils
include bots

const
  GotaFeatureCount* {.intdefine.} = 8
  GotaActionCount* {.intdefine.} = 8
  ScoreTicksPerMinute = int64(TickRate * 60)
  ScoreDenominator = 5 * ScoreTicksPerMinute * 1000
  GotaSourceCommit {.strdefine.} = ""
  TeamSize = 5
  XpDenominator = 100
  OutcomeBonus = 50'f32

type
  RewardMode* = enum
    LeaderboardReward, XpReward, XpOutcomeReward

  LaneStats* {.bycopy.} = object
    ## Summary of one finished match, from the first policy team's side.
    finished*, outcome*, tick*, selfPlay*, draftTicks*: int32
    potential*: int64
      ## Leaderboard score numerator at the end; points = potential / 7200.

  CommandTrace {.bycopy.} = object
    agent, ordinal: int32
    command: CommandAttribution

  StepTrace {.bycopy.} = object
    heroId, seat, team, tickBefore, tickAfter: int32
    potentialBefore, potentialAfter: int64

  StepLane = object
    game: Game
    seed: int
    team: Team
      ## The first policy team; selfPlay lanes also control the other.
    agents: seq[int]
      ## Hero index of each of this lane's agents, in agent order.
    features: seq[array[GotaFeatureCount, int32]]
    actions: seq[int32]
    potentials: array[Team, int64]

  StepBatch* = ref object
    lanes: seq[StepLane]
    configPath, bot, policy: string
    opponents: seq[string]
    maxTicks, actionTicks: int
    selfPlay: bool
    rewardMode: RewardMode
    agentsPerLane*: int
    commandTraceLimit: int
    commandTrace: seq[CommandTrace]
    stepTrace: seq[StepTrace]

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

proc installPolicy(batch: StepBatch, lane: ptr StepLane, index: int) =
  ## Compiles the policy for one hero with a non-blocking chooseAction.
  let
    game = lane.game
    hero = game.world.heroes[index]
    agent = lane.agents.len
  lane.agents.add index
  lane.features.add default(array[GotaFeatureCount, int32])
  lane.actions.add 0
  var
    host = initHeroHost(hero.id)
    limits = heroVmLimits()
  limits.disableFixed = true
  limits.maxParameters = GotaFeatureCount
  discard host.addFunction("chooseAction", GotaFeatureCount,
    proc(values: openArray[int32]): int32 =
      for i, value in values:
        doAssert value in -100 .. 100
        lane.features[agent][i] = value
      lane.actions[agent],
    1)
  inc limits.maxHostFunctions
  var arguments: seq[string]
  for i in 0 ..< GotaFeatureCount:
    arguments.add "f(" & $i & ")"
  let source = batch.policy.replace("' METTA_DECISION",
    "decision = chooseAction(" & arguments.join(",") & ")")
  let program = compile(source, host, limits)
  bindHeroData(program)
  game.heroVms[index] = HeroVm(
    legacyHeroData: true,
    runtime: initRuntime(program, host, limits), limits: limits, ready: true
  )

proc startLane(batch: StepBatch, lane: ptr StepLane, seed: int) =
  ## Builds a fresh match for one lane and installs the policy scripts.
  let
    config = loadConfig(batch.configPath)
    gameMap = generateMap(int32(seed), config.mapPreset)
    game = newGame(
      gameMap, config.spawnIntervalTicks, 10, false, ReplayData()
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
  loadBots(game, groups)
  game.replayData = initReplayData(
    currentSetup(game, uint32(batch.maxTicks)), gameMap.preset
  )
  lane.game = game
  lane.seed = seed
  lane.team = team
  lane.agents.setLen(0)
  lane.features.setLen(0)
  lane.actions.setLen(0)
  for index, hero in game.world.heroes:
    if hero.team == team:
      batch.installPolicy(lane, index)
  if batch.selfPlay:
    for index, hero in game.world.heroes:
      if hero.team != team:
        batch.installPolicy(lane, index)
  doAssert lane.agents.len == batch.agentsPerLane
  while game.world.phase == Drafting:
    activeGame = game
    tickWorld(game, proc() = runBotDecisions(game))
  for side in Team:
    lane.potentials[side] =
      case batch.rewardMode
      of LeaderboardReward: teamPotential(game.world, side)
      of XpReward, XpOutcomeReward: teamXp(game.world, side)

proc newStepBatch*(
    configPath, bot, opponent, policy: string,
    count, maxTicks, actionTicks: int,
    selfPlay: bool,
    rewardMode = LeaderboardReward
): StepBatch =
  ## Starts `count` lanes seeded 0 ..< count.
  doAssert count > 0 and maxTicks in 1 .. 28_800 and actionTicks > 0
  let opponents = opponent.splitLines()
  doAssert opponents.len > 0
  result = StepBatch(
    configPath: configPath,
    bot: bot,
    opponents: opponents,
    policy: policy,
    maxTicks: maxTicks,
    actionTicks: actionTicks,
    selfPlay: selfPlay,
    rewardMode: rewardMode,
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

proc observe*(
    batch: StepBatch,
    features: var openArray[int32],
    seats: var openArray[int32]
) =
  ## Writes each agent's newest features and its seat within its team.
  let size = GotaFeatureCount
  var agent = 0
  for lane in batch.lanes:
    for i, index in lane.agents:
      for j in 0 ..< size:
        features[agent * size + j] = lane.features[i][j]
      seats[agent] = int32(index mod TeamSize)
      inc agent

proc step*(
    batch: StepBatch,
    actions: openArray[int32],
    rewards: var openArray[float32],
    terminals: var openArray[uint8],
    stats: var openArray[LaneStats]
) =
  ## Runs every lane for actionTicks ticks with the given actions.
  doAssert actions.len == batch.agentCount
  if batch.commandTraceLimit > 0:
    batch.commandTrace.setLen(0)
    batch.stepTrace.setLen(batch.agentCount)
  var agent = 0
  for laneIndex in 0 ..< batch.lanes.len:
    let lane = batch.lanes[laneIndex].addr
    for i in 0 ..< lane.agents.len:
      doAssert actions[agent + i] in 0 ..< GotaActionCount
      lane.actions[i] = actions[agent + i]
    let game = lane.game
    if batch.commandTraceLimit > 0:
      game.world.commandAttribution.setLen(0)
      game.world.commandAttributionHeroes.setLen(0)
      game.world.commandAttributionLimit = batch.commandTraceLimit
      for i, index in lane.agents:
        let hero = game.world.heroes[index]
        game.world.commandAttributionHeroes.add hero.id
        batch.stepTrace[agent + i] = StepTrace(
          heroId: hero.id, seat: int32(index), team: int32(hero.team.ord),
          tickBefore: game.world.tick,
          potentialBefore: lane.potentials[hero.team]
        )
    var ticks = 0
    while ticks < batch.actionTicks and not game.finished():
      activeGame = game
      tickWorld(game, proc() = runBotDecisions(game))
      inc ticks
    for vm in game.heroVms:
      doAssert not vm.failed, vm.lastError
    let
      done = game.finished()
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
        tick: world.battleTick(),
        selfPlay: int32(batch.selfPlay),
        draftTicks: world.draftTicks,
        potential:
          if outcome(world, lane.team, true) == 1:
            teamPotential(world, lane.team)
          else:
            0
      )
    for i, index in lane.agents:
      rewards[agent + i] = reward[world.heroes[index].team]
      terminals[agent + i] = uint8(done)
    if batch.commandTraceLimit > 0:
      for command in world.commandAttribution:
        for i, index in lane.agents:
          if world.heroes[index].id == command.heroId:
            doAssert batch.commandTrace.len < batch.commandTraceLimit,
              "batch command attribution capacity exceeded"
            batch.commandTrace.add CommandTrace(
              agent: int32(agent + i), ordinal: int32(batch.commandTrace.len),
              command: command
            )
            break
      for i, index in lane.agents:
        batch.stepTrace[agent + i].tickAfter = world.tick
        batch.stepTrace[agent + i].potentialAfter = lane.potentials[world.heroes[index].team]
      # Preserve the completed world's command/reward facts before automatic reset.
      world.commandAttributionLimit = 0
    if done:
      batch.startLane(lane, lane.seed + batch.lanes.len)
    agent += lane.agents.len

proc gota_source_commit(): cstring {.cdecl, exportc, dynlib.} =
  GotaSourceCommit.cstring

proc gota_stats_size(): cint {.cdecl, exportc, dynlib.} =
  cint(sizeof(LaneStats))

proc gota_create(
    config, bot, opponent, policy: cstring,
    count, maxTicks, actionTicks, selfPlay, rewardMode: cint
): pointer {.cdecl, exportc, dynlib.} =
  doAssert rewardMode in 0 .. RewardMode.high.ord, "unknown reward mode"
  let batch = newStepBatch($config, $bot, $opponent, readFile($policy),
    int(count), int(maxTicks), int(actionTicks), selfPlay != 0,
    RewardMode(rewardMode))
  GC_ref(batch)
  cast[pointer](batch)

proc gota_agents(handle: pointer): cint {.cdecl, exportc, dynlib.} =
  cint(cast[StepBatch](handle).agentCount)

proc gota_reset(
    handle: pointer,
    seed: int64,
    features, seats: ptr UncheckedArray[int32]
) {.cdecl, exportc, dynlib.} =
  let batch = cast[StepBatch](handle)
  batch.reset(int(seed))
  let count = batch.agentCount
  batch.observe(
    features.toOpenArray(0, count * GotaFeatureCount - 1),
    seats.toOpenArray(0, count - 1)
  )

proc gota_step(
    handle: pointer,
    actions: ptr UncheckedArray[int32],
    features, seats: ptr UncheckedArray[int32],
    rewards: ptr UncheckedArray[float32],
    terminals: ptr UncheckedArray[uint8],
    stats: ptr UncheckedArray[LaneStats]
) {.cdecl, exportc, dynlib.} =
  let
    batch = cast[StepBatch](handle)
    count = batch.agentCount
  batch.step(
    actions.toOpenArray(0, count - 1),
    rewards.toOpenArray(0, count - 1),
    terminals.toOpenArray(0, count - 1),
    stats.toOpenArray(0, batch.lanes.len - 1)
  )
  batch.observe(
    features.toOpenArray(0, count * GotaFeatureCount - 1),
    seats.toOpenArray(0, count - 1)
  )

proc gota_attribution_version(): cint {.cdecl, exportc, dynlib.} =
  1

proc gota_command_trace_size(): cint {.cdecl, exportc, dynlib.} =
  cint(sizeof(CommandTrace))

proc gota_step_trace_size(): cint {.cdecl, exportc, dynlib.} =
  cint(sizeof(StepTrace))

proc gota_trace_enable(handle: pointer, maxCommands: cint) {.cdecl, exportc, dynlib.} =
  doAssert maxCommands > 0
  cast[StepBatch](handle).commandTraceLimit = int(maxCommands)

proc gota_trace_identity(
    handle: pointer, heroIds, gameSeats, gameTeams: ptr UncheckedArray[int32]
) {.cdecl, exportc, dynlib.} =
  let batch = cast[StepBatch](handle)
  doAssert batch.commandTraceLimit > 0
  var agent = 0
  for lane in batch.lanes:
    for index in lane.agents:
      heroIds[agent] = lane.game.world.heroes[index].id
      gameSeats[agent] = int32(index)
      gameTeams[agent] = int32(lane.game.world.heroes[index].team.ord)
      inc agent

proc gota_trace_count(handle: pointer): cint {.cdecl, exportc, dynlib.} =
  cint(cast[StepBatch](handle).commandTrace.len)

proc gota_trace_copy(
    handle: pointer,
    commands: ptr UncheckedArray[CommandTrace], capacity: cint,
    steps: ptr UncheckedArray[StepTrace]
) {.cdecl, exportc, dynlib.} =
  let batch = cast[StepBatch](handle)
  doAssert batch.commandTraceLimit > 0
  doAssert int(capacity) >= batch.commandTrace.len
  doAssert batch.stepTrace.len == batch.agentCount
  for i, command in batch.commandTrace:
    commands[i] = command
  for i, step in batch.stepTrace:
    steps[i] = step

proc gota_close(handle: pointer) {.cdecl, exportc, dynlib.} =
  GC_unref(cast[StepBatch](handle))
