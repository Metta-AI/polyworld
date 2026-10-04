include ../examples/gods_of_the_arena/lockstep
import std/[os, tempfiles]

let policy = "dim f(" & $GotaFeatureCount & ")\n" & """
if drafting then
  for candidate = 0 to 9
    if heroAvailable(candidate) then
      draftHero(candidate)
      end
    end if
  next candidate
  end
end if
f(0) = 100
f(1) = selfTeam * 100
f(2) = selfClass * 10
f(3) = 77
f(4) = -77
f(5) = 55
f(6) = -55
f(7) = 44
' METTA_DECISION
if decision = 0 then
  walkTo(10, 10)
end if
if decision = 1 then
  walkTo(mapWidth - 10, 10)
end if
if decision >= 3 and decision <= 6 then
  castTarget(decision - 3, selfId)
end if
"""
let
  config = "examples/gods_of_the_arena/presets/saved.json"
  bot = "examples/gods_of_the_arena/players/base.bas"

proc run(
    selfPlay: bool,
    rewardMode: RewardMode,
    maxTicks, steps: int
): tuple[features: seq[int32], seats: seq[int32], rewards: seq[float32],
    finished: int] =
  ## Plays a fixed action pattern and returns the last frame.
  let batch = newStepBatch(config, bot, bot, policy, 2, maxTicks, 24,
    selfPlay, rewardMode)
  let agents = batch.agentCount
  var
    actions = newSeq[int32](agents)
    rewards = newSeq[float32](agents)
    terminals = newSeq[uint8](agents)
    stats = newSeq[LaneStats](2)
  result.features = newSeq[int32](agents * GotaFeatureCount)
  result.seats = newSeq[int32](agents)
  for step in 0 ..< steps:
    for i in 0 ..< agents:
      actions[i] = int32((step + i) mod GotaActionCount)
    batch.step(actions, rewards, terminals, stats)
    for lane in stats:
      result.finished += int(lane.finished)
  batch.observe(result.features, result.seats)
  result.rewards = rewards

echo "Testing agent counts"
doAssert newStepBatch(config, bot, bot, policy, 3, 240, 24, false).agentCount == 15
doAssert newStepBatch(config, bot, bot, policy, 3, 240, 24, true).agentCount == 30

echo "Testing ordinary draft, battle clock and frozen-action trajectories"
block:
  let directory = createTempDir("gota-lockstep-", "")
  let player = directory / "policy.bas"
  defer:
    removeFile(player)
    removeDir(directory)
  writeFile(player, policy.replace("' METTA_DECISION", "decision = 0"))
  for seed in [0, 7]:
    let batch = newStepBatch(config, bot, bot, policy, 1, 240, 24, false)
    batch.reset(seed)
    let trained = batch.lanes[0].game
    let preset = loadConfig(config)
    let ordinary = newGame(generateMap(int32(seed), preset.mapPreset),
      preset.spawnIntervalTicks, 10, false, ReplayData())
    let groups =
      if batch.lanes[0].team == RedTeam:
        @[BotGroup(path: player, count: 5), BotGroup(path: bot, count: 5)]
      else:
        @[BotGroup(path: bot, count: 5), BotGroup(path: player, count: 5)]
    loadBots(ordinary, groups)
    ordinary.replayData = initReplayData(currentSetup(ordinary, 240), preset.mapPreset)
    while ordinary.world.phase == Drafting:
      activeGame = ordinary
      tickWorld(ordinary, proc() = runBotDecisions(ordinary))
    doAssert trained.world.drafting
    doAssert trained.world.draftTicks > 0
    doAssert trained.world.battleTick() == 0
    doAssert trained.stateHash() == ordinary.stateHash()
    var
      actions = newSeq[int32](batch.agentCount)
      rewards = newSeq[float32](batch.agentCount)
      terminals = newSeq[uint8](batch.agentCount)
      stats = newSeq[LaneStats](1)
    for frame in 0 ..< 10:
      batch.step(actions, rewards, terminals, stats)
      for tick in 0 ..< 24:
        activeGame = ordinary
        tickWorld(ordinary, proc() = runBotDecisions(ordinary))
      doAssert trained.stateHash() == ordinary.stateHash()
      doAssert stats[0].finished == int32(frame == 9)
    doAssert stats[0].tick == 240
    doAssert stats[0].draftTicks == trained.world.draftTicks
    doAssert trained.finished() and ordinary.finished()

echo "Testing attribution preserves actual team and outgoing terminal identity"
for seed in [0, 7]:
  let
    traced = newStepBatch(config, bot, bot, policy, 1, 48, 24, false)
    plain = newStepBatch(config, bot, bot, policy, 1, 48, 24, false)
  traced.reset(seed)
  plain.reset(seed)
  traced.commandTraceLimit = 4096
  var
    actions = newSeq[int32](5)
    rewards, plainRewards = newSeq[float32](5)
    terminals, plainTerminals = newSeq[uint8](5)
    stats, plainStats = newSeq[LaneStats](1)
  for frame in 0 ..< 2:
    let outgoing = traced.lanes[0].game
    let tickBefore = outgoing.world.tick
    traced.step(actions, rewards, terminals, stats)
    plain.step(actions, plainRewards, plainTerminals, plainStats)
    doAssert rewards == plainRewards and terminals == plainTerminals
    doAssert traced.lanes[0].game.stateHash() == plain.lanes[0].game.stateHash()
    doAssert traced.commandTrace.len > 0
    for agent, trace in traced.stepTrace:
      let hero = outgoing.world.heroes[trace.seat]
      doAssert trace.heroId == hero.id
      doAssert trace.team == int32(hero.team.ord)
      doAssert trace.team == int32((seed mod 10) div 5)
      doAssert trace.tickBefore == tickBefore
      doAssert trace.tickAfter == outgoing.world.tick
      doAssert rewards[agent] == float32(trace.potentialAfter - trace.potentialBefore) /
        float32(ScoreDenominator)
    for ordinal, trace in traced.commandTrace:
      doAssert trace.ordinal == int32(ordinal)
      doAssert trace.command.heroId == traced.stepTrace[trace.agent].heroId
    doAssert stats[0].finished == int32(frame == 1)
    if frame == 1:
      doAssert outgoing.finished()
      doAssert traced.lanes[0].game != outgoing
      doAssert outgoing.world.commandAttributionLimit == 0

echo "Testing observations and seats"
let played = run(true, XpReward, 2400, 20)
for agent in 0 ..< played.seats.len:
  doAssert played.seats[agent] in 0 .. 4
  doAssert played.features[agent * GotaFeatureCount + 3] == 77
  doAssert played.features[agent * GotaFeatureCount + 7] == 44

echo "Testing determinism"
let replayed = run(true, XpReward, 2400, 20)
doAssert played.features == replayed.features
doAssert played.rewards == replayed.rewards

echo "Testing restarts"
let restarted = run(false, LeaderboardReward, 240, 25)
doAssert restarted.finished >= 4, "every lane should finish twice"

echo "Testing reward modes"
for mode in RewardMode:
  let frame = run(false, mode, 480, 10)
  for reward in frame.rewards:
    doAssert reward == reward, "reward must not be NaN"

echo "Testing training Glory agrees with hosted scoring"
for (ended, draw, winner) in [
  (true, false, RedTeam),
  (true, false, BlueTeam),
  (true, true, RedTeam),
  (false, false, RedTeam)
]:
  let
    batch = newStepBatch(config, bot, bot, policy, 1, 28800, 24,
      true, LeaderboardReward)
    world = batch.lanes[0].game.world
  world.tick = if ended: 15120 else: 28920
  world.draftTicks = 120
  world.gameOver = ended
  world.draw = draw
  world.winner = winner
  for hero in world.heroes:
    hero.totalXp = 3150
  let hosted = scores(world.totalXp(), int(world.tick), world.scores())
  var
    actions = newSeq[int32](batch.agentCount)
    rewards = newSeq[float32](batch.agentCount)
    terminals = newSeq[uint8](batch.agentCount)
    stats = newSeq[LaneStats](1)
  batch.step(actions, rewards, terminals, stats)
  doAssert stats[0].finished == 1
  doAssert stats[0].outcome == (if hosted[0] > 0: 1 else: -1)
  doAssert stats[0].potential == int64(hosted[0]) * 7200
  for agent in 0 ..< batch.agentCount:
    doAssert terminals[agent] == 1
    doAssert abs(rewards[agent] - float32(hosted[agent]) / 1000) < 0.000001'f
