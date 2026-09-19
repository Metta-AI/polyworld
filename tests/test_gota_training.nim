import ../examples/gods_of_the_arena/[training, presets]

var potential = Transition(xp: 200, structureHp: -50, heroXp: 10_000,
  heroGold: 20_000, heroKills: 100, heroDeaths: 0)
doAssert potential.trainingPotential() == 150
potential.heroXp = 0
potential.heroGold = 0
potential.heroKills = 0
potential.heroDeaths = 100
doAssert potential.trainingPotential() == 150
doAssert trainingReward(100, 350, 0) == 0.25'f32
doAssert trainingReward(100, 350, 1) == 100.25'f32
doAssert trainingReward(100, 350, -1) == -99.75'f32

let policy = """
dim f(25)
f(0) = selfHp * 100 / selfMaxHp
f(1) = selfTeam * 100
f(2) = selfClass * 10
f(24) = 77
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
let config = loadConfig("examples/gods_of_the_arena/presets/saved.json")
let bot = "examples/gods_of_the_arena/players/base.bas"
let batch = newTrainingBatch(config, bot, bot, policy, 3, 120)
for lane in batch.lanes:
  doAssert lane.transition.features[24] == 77
  let firstSeat = lane.transition.seat
  var controlledSeats: seq[int32]
  controlledSeats.add firstSeat
  while controlledSeats.len < 5:
    lane.advance(0)
    controlledSeats.add lane.transition.seat
  var seen: array[10, bool]
  for seat in controlledSeats:
    doAssert seat div 5 == firstSeat div 5
    doAssert not seen[seat], $controlledSeats
    seen[seat] = true
  lane.advance(0)
  doAssert lane.transition.tick >= GotaActionRepeat, $lane.transition.tick
var scalar: seq[TrainingBatch]
for index in 0 ..< 3:
  scalar.add newTrainingBatch(config, bot, bot, policy, 1, 120)
var transitions: array[3, Transition]
var reference: array[1, Transition]
for episode in 0 ..< 3:
  batch.reset(10 + episode)
  for index in 0 ..< 3:
    scalar[index].reset((10 + episode) * 3 + index)
  var step = 0
  while true:
    var actions: array[3, int32]
    for index in 0 ..< 3:
      actions[index] = int32((step + index) mod 8)
    batch.step(actions, transitions)
    for index in 0 ..< 3:
      scalar[index].step([actions[index]], reference)
      doAssert transitions[index] == reference[0], "lane " & $index & " step " & $step
    inc step
    if transitions[0].terminal != 0:
      doAssert transitions[1].terminal != 0 and transitions[2].terminal != 0
      doAssert transitions[0].outcome == -1
      doAssert transitions[1].outcome == -1
      doAssert transitions[2].outcome == -1
      break
batch.close()
for lane in scalar:
  lane.close()

let rusher = "examples/gods_of_the_arena/players/rusher.bas"
let mixed = newTrainingBatch(config, bot, bot & "\n" & rusher, policy, 1, 120)
let baseline = newTrainingBatch(config, bot, bot, policy, 1, 120)
let rushing = newTrainingBatch(config, bot, rusher, policy, 1, 120)
for seed in [0, 10]:
  mixed.reset(seed)
  baseline.reset(seed)
  rushing.reset(seed)
  var opponentsDiffer = false
  for step in 0 ..< 100:
    var mixedTransition, baselineTransition, rushingTransition: array[1, Transition]
    let action = [int32(step mod 8)]
    mixed.step(action, mixedTransition)
    baseline.step(action, baselineTransition)
    rushing.step(action, rushingTransition)
    opponentsDiffer = opponentsDiffer or baselineTransition != rushingTransition
    if seed == 0:
      doAssert mixedTransition == baselineTransition
    else:
      doAssert mixedTransition == rushingTransition
  doAssert opponentsDiffer
mixed.close()
baseline.close()
rushing.close()
echo "Native training lanes match scalar observations, hashes, rewards, terminals, and repeated resets"
