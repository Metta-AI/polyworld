import ../examples/gods_of_the_arena/[training, presets]

let policy = """
dim f(16)
f(0) = selfHp * 100 / selfMaxHp
f(1) = selfTeam * 100
f(2) = selfClass * 10
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
      break
batch.close()
for lane in scalar:
  lane.close()
echo "Native training lanes match scalar observations, hashes, rewards, terminals, and repeated resets"
