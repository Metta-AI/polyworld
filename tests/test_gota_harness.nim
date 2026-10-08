## Proves the native training hero (harness.nim) plays exactly like
## harness.bas. A BASIC batch and a native batch start from the same seeds
## and receive the same seeded random action heads every tick. After every
## step they must publish the same observations, seats, rewards, terminals
## and lane stats, and every native hero must hold the same values as its
## VM's globals. Both record their matches, so every tick's world hash and
## every command must match too.
##
##   nim r -d:release -d:headless tests/test_gota_harness.nim \
##     [lanes] [maxTicks] [matches] [selfPlay 0|1] [seed]

import std/os
include ../examples/gods_of_the_arena/lockstep

const GameDirectory =
  currentSourcePath().parentDir.parentDir / "examples" / "gods_of_the_arena"

type
  TapeCursor = object
    ## How far one lane's recorded hashes and commands have been compared.
    hashes, actions: int

proc attachRecorder(lane: var StepLane, maxTicks: int) =
  ## Records the lane's current match so every tick leaves a world hash.
  lane.game.recorder = initReplayRecorder(
    currentSetup(lane.game, uint32(maxTicks))
  )

proc checkGlobals(basic, native: StepLane, step: int) =
  ## Compares every native hero field with the BASIC global of that name.
  for agent, index in basic.agents:
    let
      runtime = basic.game.heroVms[index].runtime
      harness = native.harnesses[agent]
    for name, value in harness.fieldPairs:
      when value is array:
        for i in 0 ..< value.len:
          let expected = runtime.getArray(name, int32(i))
          doAssert expected == int32(value[i]),
            "step " & $step & " agent " & $agent & " " & name & "(" & $i &
            "): BASIC " & $expected & ", Nim " & $value[i]
      else:
        let expected = runtime.getGlobal(name)
        doAssert expected == int32(value),
          "step " & $step & " agent " & $agent & " " & name &
          ": BASIC " & $expected & ", Nim " & $int32(value)

proc checkPrices(lane: StepLane) =
  ## Checks harness.bas's copied item prices against the game's catalog.
  for index in lane.agents:
    let runtime = lane.game.heroVms[index].runtime
    if runtime.getGlobal("tablesReady") == 1:
      for item in HealthPotion .. Item.high:
        doAssert runtime.getArray("itemCost", int32(item.ord)) ==
          ItemSpecs[item].cost, "harness.bas price of " & $item & " is stale"

proc checkTape(
  basic, native: Game,
  cursor: var TapeCursor,
  lane: int
) =
  ## Compares the world hashes and commands recorded since the last step.
  let
    expected = basic.recorder.data
    actual = native.recorder.data
  doAssert expected.hashes.len == actual.hashes.len,
    "lane " & $lane & " recorded different tick counts"
  for i in cursor.hashes ..< expected.hashes.len:
    doAssert expected.hashes[i] == actual.hashes[i],
      "lane " & $lane & " world hash differs first at tick " & $(i + 1)
  for i in cursor.actions ..< min(expected.actions.len, actual.actions.len):
    doAssert expected.actions[i] == actual.actions[i],
      "lane " & $lane & " command " & $i & " differs: BASIC " &
      $expected.actions[i] & ", Nim " & $actual.actions[i]
  doAssert expected.actions.len == actual.actions.len,
    "lane " & $lane & " issued different command counts"
  cursor.hashes = expected.hashes.len
  cursor.actions = expected.actions.len

proc main() =
  ## Plays both harnesses in lockstep and asserts they never diverge.
  let
    lanes = if paramCount() >= 1: parseInt(paramStr(1)) else: 2
    maxTicks = if paramCount() >= 2: parseInt(paramStr(2)) else: 600
    matches = if paramCount() >= 3: parseInt(paramStr(3)) else: 1
    selfPlay = paramCount() < 4 or paramStr(4) == "1"
    seed = if paramCount() >= 5: parseInt(paramStr(5)) else: 0
    config = GameDirectory / "presets" / "saved.json"
    bot = GameDirectory / "players" / "base.bas"
    opponents = bot & "\n" & GameDirectory / "players" / "rusher.bas"
    policy = readFile(GameDirectory / "harness.bas")
    basic = newStepBatch(config, bot, opponents, policy, lanes, maxTicks,
      selfPlay, XpReward, BasicHarness)
    native = newStepBatch(config, bot, opponents, "", lanes, maxTicks,
      selfPlay, XpReward, NimHarness)
    agents = basic.agentCount
  echo "Testing harness parity: ", lanes, " lanes, ", maxTicks,
    " ticks, self play ", selfPlay
  if seed != 0:
    basic.reset(seed)
    native.reset(seed)
  for lane in 0 ..< lanes:
    basic.lanes[lane].attachRecorder(maxTicks)
    native.lanes[lane].attachRecorder(maxTicks)
  var
    actions = newSeq[int32](agents * ActionCount)
    basicRewards, nativeRewards = newSeq[float32](agents)
    basicTerminals, nativeTerminals = newSeq[uint8](agents)
    basicStats, nativeStats = newSeq[LaneStats](lanes)
    basicObservations, nativeObservations =
      newSeq[int32](agents * ObservationSize)
    basicSeats, nativeSeats = newSeq[int32](agents)
    basicGames, nativeGames = newSeq[Game](lanes)
    cursors = newSeq[TapeCursor](lanes)
    finished = newSeq[int](lanes)
    random = 1'u32
    step = 0
    ticks = 0
    commands = 0
    mostInstructions = 0'i64
    mostWork = 0'i64
  while min(finished) < matches:
    for i in 0 ..< actions.len:
      random = random * 1103515245'u32 + 12345'u32
      actions[i] = int32((random shr 16) mod
        uint32(ActionSizes[i mod ActionCount]))
    for lane in 0 ..< lanes:
      basicGames[lane] = basic.lanes[lane].game
      nativeGames[lane] = native.lanes[lane].game
    basic.step(actions, basicRewards, basicTerminals, basicStats)
    native.step(actions, nativeRewards, nativeTerminals, nativeStats)
    doAssert basicRewards == nativeRewards, "rewards differ at step " & $step
    doAssert basicTerminals == nativeTerminals,
      "terminals differ at step " & $step
    doAssert basicStats == nativeStats, "lane stats differ at step " & $step
    basic.observe(basicObservations, basicSeats)
    native.observe(nativeObservations, nativeSeats)
    doAssert basicSeats == nativeSeats, "seats differ at step " & $step
    if basicObservations != nativeObservations:
      for i in 0 ..< basicObservations.len:
        doAssert basicObservations[i] == nativeObservations[i],
          "step " & $step & " agent " & $(i div ObservationSize) &
          " observation " & $(i mod ObservationSize) & ": BASIC " &
          $basicObservations[i] & ", Nim " & $nativeObservations[i]
    for lane in 0 ..< lanes:
      checkTape(basicGames[lane], nativeGames[lane], cursors[lane], lane)
      for vm in basicGames[lane].heroVms:
        mostInstructions = max(mostInstructions, vm.lastInstructions)
        mostWork = max(mostWork, vm.lastWork)
      if basicStats[lane].finished != 0:
        inc finished[lane]
        ticks += basicGames[lane].recorder.data.hashes.len
        commands += basicGames[lane].recorder.data.actions.len
        echo "  lane ", lane, " match ", finished[lane], ": ",
          basicStats[lane].tick, " ticks, outcome ",
          basicStats[lane].outcome, ", ",
          basicGames[lane].recorder.data.actions.len, " commands identical"
        cursors[lane] = TapeCursor()
        basic.lanes[lane].attachRecorder(maxTicks)
        native.lanes[lane].attachRecorder(maxTicks)
      checkGlobals(basic.lanes[lane], native.lanes[lane], step)
      if step == 0:
        checkPrices(basic.lanes[lane])
    inc step
  echo "Identical over ", step, " ticks of ", agents, " agents: ", ticks,
    " finished-match ticks, ", commands, " commands"
  echo "Most BASIC instructions in one tick ", mostInstructions,
    ", work ", mostWork

main()
