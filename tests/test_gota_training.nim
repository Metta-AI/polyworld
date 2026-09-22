import ../examples/gods_of_the_arena/training

const FeatureCount = GotaFeatureCount

proc equivalent(left, right: Transition): bool =
  var
    normalizedLeft = left
    normalizedRight = right
  normalizedLeft.maxWork = 0
  normalizedLeft.maxInstructions = 0
  normalizedRight.maxWork = 0
  normalizedRight.maxInstructions = 0
  normalizedLeft == normalizedRight

var potential = Transition(xp: 200, structureHp: -50)
doAssert potential.trainingPotential() == 150
doAssert trainingReward(100, 350, 0) == 0.25'f32
doAssert trainingReward(100, 350, 1) == 100.25'f32
doAssert trainingReward(100, 350, -1) == -99.75'f32

let policy = "dim f(" & $FeatureCount & ")\n" & """
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
if decision = 2 then
  walkTo(10, mapHeight - 10)
end if
if decision >= 3 and decision <= 6 then
  castTarget(decision - 3, selfId)
end if
if decision = 7 then
  buyItem(2)
end if
"""
let
  config = "examples/gods_of_the_arena/presets/saved.json"
  bot = "examples/gods_of_the_arena/players/base.bas"
  batch = newTrainingBatch(config, bot, bot, policy, 3, 120)

for lane in batch.lanes:
  doAssert lane.transition.features[3] == 77
  doAssert lane.transition.features[4] == -77
  doAssert lane.transition.features[5] == 55
  doAssert lane.transition.features[6] == -55
  doAssert lane.transition.features[7] == 44
  let firstSeat = lane.transition.seat
  var controlledSeats = @[firstSeat]
  while controlledSeats.len < 5:
    lane.advance(0)
    controlledSeats.add lane.transition.seat
  var seen: array[10, bool]
  for seat in controlledSeats:
    doAssert seat div 5 == firstSeat div 5
    doAssert not seen[seat]
    seen[seat] = true

batch.reset(7)
let firstReset = batch.lanes[0].transition
batch.reset(7)
doAssert batch.lanes[0].transition.stateHash == firstReset.stateHash
doAssert batch.lanes[0].transition.features == firstReset.features

var transitions: array[3, Transition]
for episode in 0 ..< 3:
  batch.reset(10 + episode)
  var step = 0
  while true:
    var actions: array[3, int32]
    for index in 0 ..< actions.len:
      actions[index] = int32((step + index) mod GotaActionCount)
    batch.step(actions, transitions)
    inc step
    if transitions[0].terminal != 0:
      doAssert transitions[1].terminal != 0
      doAssert transitions[2].terminal != 0
      doAssert transitions[0].outcome == -1
      doAssert transitions[1].outcome == -1
      doAssert transitions[2].outcome == -1
      break
batch.close()

let
  rusher = "examples/gods_of_the_arena/players/rusher.bas"
  mixedOpponents = bot & "\n" & rusher

proc trajectory(opponents: string, seed: int): seq[Transition] =
  let simulation = newTrainingBatch(config, bot, opponents, policy, 1, 120)
  simulation.reset(seed)
  for step in 0 ..< 100:
    var transition: array[1, Transition]
    let action = [int32(step mod GotaActionCount)]
    simulation.step(action, transition)
    result.add transition[0]
  simulation.close()

let
  mixedBaseline = trajectory(mixedOpponents, 0)
  baseline = trajectory(bot, 0)
  mixedRushing = trajectory(mixedOpponents, 10)
  baselineRushingSeed = trajectory(bot, 10)
  rushing = trajectory(rusher, 10)
var opponentsDiffer = false
for index in 0 ..< baseline.len:
  doAssert equivalent(mixedBaseline[index], baseline[index])
  doAssert equivalent(mixedRushing[index], rushing[index])
  opponentsDiffer = opponentsDiffer or
    not equivalent(baselineRushingSeed[index], rushing[index])
doAssert opponentsDiffer

echo "Native training lanes preserve observations, rewards, resets, and opponents"
