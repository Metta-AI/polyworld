include ../examples/gods_of_the_arena/lockstep

let policy = """
dim obs(4391)
dim act(9)
obs(0) = 100
obs(1) = selfTeam * 100
obs(2) = selfClass * 10
obs(3) = 77
obs(4391) = 44
' METTA_DECISION
if act(0) = 0 then
  walkTo(10, 10)
end if
if act(0) = 1 then
  walkTo(mapWidth - 10, 10)
end if
if act(3) = 1 then
  castTarget(0, selfId)
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
  let batch = newStepBatch(config, bot, bot, policy, 2, maxTicks,
    selfPlay, rewardMode)
  let agents = batch.agentCount
  var
    actions = newSeq[int32](agents * ActionCount)
    rewards = newSeq[float32](agents)
    terminals = newSeq[uint8](agents)
    stats = newSeq[LaneStats](2)
  result.features = newSeq[int32](agents * ObservationSize)
  result.seats = newSeq[int32](agents)
  for step in 0 ..< steps:
    for i in 0 ..< actions.len:
      actions[i] = int32((step + i) mod ActionSizes[i mod ActionCount])
    batch.step(actions, rewards, terminals, stats)
    for lane in stats:
      result.finished += int(lane.finished)
  batch.observe(result.features, result.seats)
  result.rewards = rewards

echo "Testing agent counts"
doAssert newStepBatch(config, bot, bot, policy, 3, 240, false).agentCount == 15
doAssert newStepBatch(config, bot, bot, policy, 3, 240, true).agentCount == 30

echo "Testing observations and seats"
let played = run(true, XpReward, 2400, 20)
for agent in 0 ..< played.seats.len:
  doAssert played.seats[agent] in 0 .. 4
  doAssert played.features[agent * ObservationSize + 3] == 77
  doAssert played.features[agent * ObservationSize + 4391] == 44

echo "Testing determinism"
let replayed = run(true, XpReward, 2400, 20)
doAssert played.features == replayed.features
doAssert played.rewards == replayed.rewards

echo "Testing restarts"
let restarted = run(false, LeaderboardReward, 240, 500)
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
    batch = newStepBatch(config, bot, bot, policy, 1, 28800,
      true, LeaderboardReward)
    world = batch.lanes[0].game.world
  world.tick = if ended: 15120 else: 28800
  world.draftTicks = 120
  world.gameOver = ended
  world.draw = draw
  world.winner = winner
  for hero in world.heroes:
    hero.totalXp = 3150
  let hosted = scores(world.totalXp(), int(world.tick), world.scores())
  var
    actions = newSeq[int32](batch.agentCount * ActionCount)
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
