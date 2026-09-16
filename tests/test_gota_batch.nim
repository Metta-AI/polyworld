## Verifies lane ownership across repeated decisions and uneven worker chunks.
import ../examples/gods_of_the_arena/[batch, presets]

let
  config = loadConfig("examples/gods_of_the_arena/presets/saved.json")
  bot = "examples/gods_of_the_arena/players/base.bas"
  scalar = newGotaBatch(5, 1, config, bot)
  parallel = newGotaBatch(5, 3, config, bot)

for tick in 0 ..< 200:
  for lane in 0 ..< 5:
    let action = int32((tick + lane) mod 3)
    scalar.buffers.actions[scalar.nextBuffer][lane] = action
    parallel.buffers.actions[parallel.nextBuffer][lane] = action
  scalar.step(1)
  parallel.step(1)
  doAssert scalar.stateHashes() == parallel.stateHashes(), "tick " & $tick
  doAssert scalar.observations() == parallel.observations(), "tick " & $tick
scalar.close()
parallel.close()
echo "1,000 per-lane tick hashes and observation rows matched"
