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
## Five rewards, picked by RewardMode:
## - LeaderboardReward follows Emmett's Glory: each hero's whole XP per
##   elapsed minute, averaged over the team and divided by 1000. Steps reward
##   the change in that potential; a loss, draw, or timeout cancels it, so the
##   episode's total reward is the winning team's Glory divided by 1000.
## - XpReward is the change in the team's total XP divided by 100, with no
##   tick penalty and no reset on a loss, so a policy learns from scratch.
## - XpOutcomeReward is XpReward plus OutcomeBonus for a win and minus it
##   for a loss or timeout, so surviving matters beyond the next XP.
## - MobaReward copies PufferLib's moba (config/moba.ini): each hero is paid
##   for its own events, MobaXpWeight per XP it gains, minus MobaDeathWeight
##   when it dies, plus MobaStructureWeight per structure it last-hits, and
##   nothing for winning or losing.
## - MobaWinReward is MobaReward plus a win bonus (MobaWinBonus unless
##   `setWinBonus` changes it) to each hero of a team that wins. GotA
##   matches run long and a draw pays almost as much XP as a win, so without
##   it policies settle for farming until the clock runs out.
## With `selfPlay` both teams run the policy (10 agents per lane);
## otherwise one team plays a bundled opponent (5 agents per lane).
## Opponents are listed easiest first. By default each match draws one
## of them for its whole team from a hash of the seed. With a curriculum
## (`setLevel`, which the trainer raises as the policy wins) the opposing
## heroes are a blend: level L puts L mod 5 heroes of the next opponent in
## the list among those of opponent L div 5, so with null, dumb, base and
## khors the levels run 5 null, 4 null and 1 dumb, ..., 5 dumb, 4 dumb and
## 1 base, ..., 5 khors. A match plays an easier level in `setEasier`
## percent of matches (25 by default) and the current level otherwise, so
## the policy keeps what it learned.
## `setWalk` sets the chance that a spawned or respawned hero is walked to
## its lane by script (harness.nim), and `setReach` how much of the way, so
## training can wean it off the walk. `setBuild` makes the buy head follow
## base.bas's shopping list (harness.nim), and `setRetreat` sends heroes
## home below a share of their health. `setShaping` adds potential-based
## shaping to the per-hero rewards: gamma * phi(next) - phi(now), with phi
## minus `weight` per tile to the nearest living enemy tower or barracks,
## which pays every tile walked toward a fight without changing the best
## policy.
## Finished lanes restart with the next seed inside the same step.
import
  std/[math, os, strutils],
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
  MobaXpWeight = 0.00665677'f32
    ## PufferLib moba.ini reward_xp, per XP point.
  MobaDeathWeight = 0.163764'f32
    ## PufferLib moba.ini reward_death, taken per death.
  MobaStructureWeight = 0.642119'f32
    ## PufferLib moba.ini reward_tower, per structure last-hit.
  MobaWinBonus = 10'f32
    ## MobaWinReward's bonus per hero for a win, worth about 1,500 XP.

type
  RewardMode* = enum
    LeaderboardReward, XpReward, XpOutcomeReward, MobaReward, MobaWinReward

  HarnessMode* = enum
    ## How policy heroes think: a BASIC policy in one bassy VM per hero,
    ## or harness.nim, the native port of harness.bas.
    BasicHarness, NimHarness

  LaneStats* {.bycopy.} = object
    ## Summary of one finished match, from the first policy team's side.
    finished*, outcome*, tick*, selfPlay*: int32
    played*, level*: int32
      ## The match's curriculum level (or its opponent's index in a static
      ## mix) and the current level (-1 for a static mix).
    potential*: int64
      ## Leaderboard score numerator at the end; points = potential / 7200.

  StepLane = object
    game: Game
    seed: int
    played: int
      ## This match's curriculum level, or its opponent in a static mix.
    walkPercent: int
      ## Chance that a spawned hero walks to its lane by script.
    walkReach: int
      ## Percent of the way to its lane that the walk covers.
    build: bool
      ## The buy head follows base.bas's shopping list.
    retreat: int
      ## Percent of health below which heroes walk home to heal.
    lastGame: Game
      ## The lane's previous match, kept after a restart for its replay.
    labels, lastLabels: seq[string]
      ## Per hero index: "policy" or the opponent file, for this match and
      ## the previous one.
    team: Team
      ## The first policy team; selfPlay lanes also control the other.
    agents: seq[int]
      ## Hero index of each of this lane's agents, in agent order.
    observations: seq[array[ObservationSize, int32]]
    actions: seq[array[ActionCount, int32]]
    potentials: array[Team, int64]
    heroXp, heroDeaths, heroStructures: seq[int64]
    heroPotentials: seq[float32]
      ## Per hero index: the shaping potential at the last step.
      ## Per hero index: XP, deaths and structures at the last step.
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
    level: int
      ## Curriculum level, or -1 for a static mix of whole-team opponents.
    walkPercent: int
      ## Chance in percent that a spawned hero walks to its lane by script.
    walkReach: int
      ## Percent of the way to its lane that the walk covers.
    build: bool
      ## The buy head follows base.bas's shopping list (harness.nim).
    easier: int
      ## Percent of curriculum matches played at an easier level.
    retreat: int
      ## Percent of health below which heroes walk home to heal (0 off).
    winBonus: float32
      ## MobaWinReward's bonus to each winning hero (`setWinBonus`).
    shapingWeight, shapingGamma: float32
      ## Shaping reward per tile walked toward the enemy, and the trainer's
      ## discount; weight 0 turns shaping off.
    exact: bool
      ## Evaluation: every match plays the current level, none easier.
    recording: bool
      ## Records every match so `lastReplay` can save it.

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

proc enemyDistance(world: World, hero: Hero): float32 =
  ## Tiles from the hero to the nearest living enemy tower or barracks, or
  ## 0 once none is left.
  let
    x = mapCoordinate(hero.position.x)
    y = mapCoordinate(hero.position.z)
  var best = -1'i32
  for building in world.buildings:
    if building.team != hero.team and building.hp > 0:
      let
        dx = mapCoordinate(building.position.x) - x
        dy = mapCoordinate(building.position.z) - y
        distance = dx * dx + dy * dy
      if best < 0 or distance < best:
        best = distance
  if best < 0: 0'f32 else: sqrt(float32(best))

proc snapshotHeroes(lane: ptr StepLane) =
  ## Records every hero's XP, deaths, structures and shaping potential.
  let world = lane.game.world
  lane.heroXp.setLen(world.heroes.len)
  lane.heroDeaths.setLen(world.heroes.len)
  lane.heroStructures.setLen(world.heroes.len)
  lane.heroPotentials.setLen(world.heroes.len)
  for index, hero in world.heroes:
    lane.heroXp[index] = int64(hero.totalXp)
    lane.heroDeaths[index] = int64(hero.deaths)
    lane.heroStructures[index] = world.stats.values[index][StructuresMetric]
    lane.heroPotentials[index] = -enemyDistance(world, hero)

proc mobaReward(lane: ptr StepLane, index: int): float32 =
  ## One hero's MobaReward since the last snapshot.
  let
    world = lane.game.world
    hero = world.heroes[index]
    xp = int64(hero.totalXp) - lane.heroXp[index]
    deaths = int64(hero.deaths) - lane.heroDeaths[index]
    structures = world.stats.values[index][StructuresMetric] -
      lane.heroStructures[index]
  float32(xp) * MobaXpWeight - float32(deaths) * MobaDeathWeight +
    float32(structures) * MobaStructureWeight

proc seedHash(seed: int): uint32 =
  ## Mixes a lane seed into well-spread bits.
  uint32(seed and 0x7fffffff) * 2654435761'u32

proc maxLevel(batch: StepBatch): int =
  ## The hardest curriculum level: five heroes of the last opponent.
  (batch.opponents.len - 1) * TeamSize

proc pickLevel(batch: StepBatch, seed: int): int =
  ## A match's level: an easier one in `easier` percent of matches (25 by
  ## default), else the current one.
  if batch.level <= 0 or batch.exact:
    return max(batch.level, 0)
  let hash = seedHash(seed)
  if int((hash shr 16) mod 100) >= batch.easier:
    batch.level
  else:
    int((hash shr 8) mod uint32(batch.level))

proc opponentGroups(batch: StepBatch, seed: int): (int, seq[BotGroup]) =
  ## The opposing team's bots for a match, and the level or index played.
  let hash = seedHash(seed)
  if batch.level < 0:
    let index = int((hash shr 8) mod uint32(batch.opponents.len))
    return (index, @[BotGroup(path: batch.opponents[index], count: TeamSize)])
  let level = min(batch.pickLevel(seed), batch.maxLevel)
  var
    tier = level div TeamSize
    harder = level mod TeamSize
  if tier >= batch.opponents.len - 1:
    tier = batch.opponents.len - 1
    harder = 0
  # One group per hero slot; the harder heroes rotate across lanes.
  let rotation = int((hash shr 4) mod uint32(TeamSize))
  var groups: seq[BotGroup]
  for slot in 0 ..< TeamSize:
    let
      hard = (slot - rotation + TeamSize) mod TeamSize < harder
      path = batch.opponents[if hard: tier + 1 else: tier]
    groups.add BotGroup(path: path, count: 1)
  (level, groups)

proc setLevel*(batch: StepBatch, level: int) =
  ## Sets the curriculum level; -1 is a static mix.
  batch.level = min(level, batch.maxLevel)

proc setExactLevel*(batch: StepBatch, level: int) =
  ## Evaluation: every match plays exactly this level.
  batch.setLevel(level)
  batch.exact = true

proc setRecording*(batch: StepBatch, recording: bool) =
  ## Records the matches that start from now on, for `lastReplay`.
  batch.recording = recording

proc setWalk*(batch: StepBatch, percent: int) =
  ## Sets the chance that a spawned hero walks to its lane by script.
  batch.walkPercent = percent
  for lane in batch.lanes.mitems:
    lane.walkPercent = percent

proc setRetreat*(batch: StepBatch, percent: int) =
  ## Sends heroes home to heal below `percent` of their health; 0 is off.
  batch.retreat = percent
  for lane in batch.lanes.mitems:
    lane.retreat = percent

proc setEasier*(batch: StepBatch, percent: int) =
  ## Sets the percent of curriculum matches played at an easier level.
  batch.easier = percent

proc setBuild*(batch: StepBatch, build: bool) =
  ## Makes any nonzero buy choice buy the next item of base.bas's list.
  batch.build = build
  for lane in batch.lanes.mitems:
    lane.build = build

proc setWinBonus*(batch: StepBatch, bonus: float32) =
  ## Sets MobaWinReward's bonus to each hero of a winning team.
  batch.winBonus = bonus

proc setShaping*(batch: StepBatch, weight, gamma: float32) =
  ## Sets the shaping reward per tile walked toward the nearest living
  ## enemy structure and the discount it is matched to; weight 0 is off.
  batch.shapingWeight = weight
  batch.shapingGamma = gamma

proc setReach*(batch: StepBatch, percent: int) =
  ## Sets how much of the way to its lane the scripted walk covers.
  batch.walkReach = percent
  for lane in batch.lanes.mitems:
    lane.walkReach = percent

proc startLane(batch: StepBatch, lane: ptr StepLane, seed: int) =
  ## Builds a fresh match for one lane and installs the policy scripts.
  let
    config = loadConfig(batch.configPath)
    gameMap = generateMap(int32(seed), config.mapPreset)
    game = newGame(
      gameMap, config.spawnIntervalTicks, 10, false, ReplayData(), false
    )
    team = Team((seed mod 10) div 5)
    (played, opponents) = batch.opponentGroups(seed)
    learners = @[BotGroup(path: batch.bot, count: TeamSize)]
    groups =
      if team == RedTeam: learners & opponents
      else: opponents & learners
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
  lane.played = played
  lane.walkPercent = batch.walkPercent
  lane.walkReach = batch.walkReach
  lane.build = batch.build
  lane.retreat = batch.retreat
  if batch.recording:
    game.recorder = initReplayRecorder(
      currentSetup(game, uint32(batch.maxTicks))
    )
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
  lane.labels.setLen(0)
  for group in groups:
    for _ in 0 ..< group.count:
      lane.labels.add group.path.extractFilename
  for index in 0 ..< lane.labels.len:
    if index < lane.agentOf.len and lane.agentOf[index] >= 0:
      lane.labels[index] = "policy"
  doAssert lane.agents.len == batch.agentsPerLane
  for side in Team:
    lane.potentials[side] =
      case batch.rewardMode
      of LeaderboardReward: teamPotential(game.world, side)
      of XpReward, XpOutcomeReward, MobaReward, MobaWinReward:
        teamXp(game.world, side)
  lane.snapshotHeroes()

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
    agentsPerLane: if selfPlay: 2 * TeamSize else: TeamSize,
    level: -1,
    walkPercent: 100,
    walkReach: 100,
    winBonus: MobaWinBonus,
    easier: 25
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
    lane.harnesses[agent].walkPercent = int32(lane.walkPercent)
    lane.harnesses[agent].walkReach = int32(lane.walkReach)
    lane.harnesses[agent].build = lane.build
    lane.harnesses[agent].retreatPercent = int32(lane.retreat)
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
      of XpReward, XpOutcomeReward, MobaReward, MobaWinReward:
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
        played: int32(lane.played),
        level: int32(batch.level),
        potential:
          if outcome(world, lane.team, true) == 1:
            teamPotential(world, lane.team)
          else:
            0
      )
    let perHero = batch.rewardMode in {MobaReward, MobaWinReward}
    for i, index in lane.agents:
      rewards[agent + i] =
        if perHero: mobaReward(lane, index)
        else: reward[world.heroes[index].team]
      if batch.rewardMode == MobaWinReward and done and
        outcome(world, world.heroes[index].team, true) == 1:
          rewards[agent + i] += batch.winBonus
      if perHero and batch.shapingWeight > 0:
        # The terminal state's potential is 0, which keeps the shaping
        # potential-based across matches.
        let next =
          if done: 0'f32
          else: -enemyDistance(world, world.heroes[index])
        rewards[agent + i] += batch.shapingWeight *
          (batch.shapingGamma * next - lane.heroPotentials[index])
      terminals[agent + i] = uint8(done)
    if perHero:
      lane.snapshotHeroes()
    if done:
      lane.lastGame = game
      lane.lastLabels = lane.labels
      batch.startLane(lane, lane.seed + batch.lanes.len)
    agent += lane.agents.len

proc lastMatch*(
  batch: StepBatch,
  lane: int
): tuple[world: World, labels: seq[string]] =
  ## The world of a lane's most recently finished match and, per hero
  ## index, "policy" or the opponent file that played it.
  doAssert batch.lanes[lane].lastGame != nil, "no finished match yet"
  (batch.lanes[lane].lastGame.world, batch.lanes[lane].lastLabels)

proc currentMatch*(
  batch: StepBatch,
  lane: int
): tuple[world: World, labels: seq[string]] =
  ## The world of a lane's match in progress and its per-hero labels.
  (batch.lanes[lane].game.world, batch.lanes[lane].labels)

proc lastReplay*(batch: StepBatch, lane: int): ReplayData =
  ## The recording of a lane's most recently finished match.
  doAssert batch.lanes[lane].lastGame != nil, "no finished match yet"
  batch.lanes[lane].lastGame.recorder.data

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

proc gota_set_level(handle: pointer, level: cint) {.cdecl, exportc, dynlib.} =
  cast[StepBatch](handle).setLevel(int(level))

proc gota_set_walk(handle: pointer, percent: cint) {.cdecl, exportc, dynlib.} =
  cast[StepBatch](handle).setWalk(int(percent))

proc gota_set_reach(handle: pointer, percent: cint) {.cdecl, exportc, dynlib.} =
  cast[StepBatch](handle).setReach(int(percent))

proc gota_set_retreat(handle: pointer, percent: cint) {.cdecl, exportc, dynlib.} =
  cast[StepBatch](handle).setRetreat(int(percent))

proc gota_set_easier(handle: pointer, percent: cint) {.cdecl, exportc, dynlib.} =
  cast[StepBatch](handle).setEasier(int(percent))

proc gota_set_build(handle: pointer, build: cint) {.cdecl, exportc, dynlib.} =
  cast[StepBatch](handle).setBuild(build != 0)

proc gota_set_win_bonus(handle: pointer, bonus: cfloat) {.cdecl, exportc, dynlib.} =
  cast[StepBatch](handle).setWinBonus(float32(bonus))

proc gota_set_shaping(
  handle: pointer,
  weight, gamma: cfloat
) {.cdecl, exportc, dynlib.} =
  cast[StepBatch](handle).setShaping(float32(weight), float32(gamma))

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
