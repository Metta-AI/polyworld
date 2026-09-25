import ../examples/gods_of_the_arena/lockstep

let policy = "dim f(" & $GotaFeatureCount & ")\n" & """
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
