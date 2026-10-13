## Plays the moba port (examples/moba/sim.nim) with random learner actions
## and prints the statistics that PufferLib's moba.h gives for the same
## play, to compare the two engines: matches, who wins, mean length and
## reward per agent tick.
##
##   nim r -d:release tests/test_moba_sim.nim [ticks] [envs] [traits]

import
  std/[os, random, strutils],
  ../examples/moba/sim

let
  ticks = if paramCount() >= 1: parseInt(paramStr(1)) else: 200_000
  envs = if paramCount() >= 2: parseInt(paramStr(2)) else: 2
  traits = if paramCount() >= 3: uint16(parseInt(paramStr(3))) else: 0'u16
var
  rng = initRand(1)
  matches, radiant, dire, lengthSum = 0
  rewardSum = 0.0
for e in 0 ..< envs:
  let game = newMoba(uint32(e + 1), traits)
  var observation: array[ObservationSize, int32]
  for pid in 0 ..< 5:
    game.observe(pid, observation)
    doAssert observation[484 + 2] == 1, "heroes start at level 1"
  for t in 0 ..< ticks div envs:
    for pid in 0 ..< 5:
      for head in 0 ..< ActionCount:
        game.actions[pid][head] = int32(rng.rand(int(ActionSizes[head]) - 1))
    let rewards = game.step()
    for pid in 0 ..< 5:
      rewardSum += rewards[pid]
    if game.finished:
      inc matches
      lengthSum += game.finishedTick
      if game.radiantVictory:
        inc radiant
      elif game.direVictory:
        inc dire
echo "Nim moba: ", ticks, " ticks, ", matches, " matches, radiant ", radiant,
  ", dire ", dire, ", mean length ",
  (if matches > 0: $(lengthSum div matches) else: "-"),
  ", reward per agent-tick ", formatFloat(rewardSum / (5.0 * ticks.float),
    ffDecimal, 6)
