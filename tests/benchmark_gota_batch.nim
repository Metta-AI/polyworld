## Compares scalar and persistent native-thread GotA batches.
## Compile with -d:headless --threads:on --mm:atomicArc.
import std/[monotimes, os, parseutils, strformat, times]
import ../examples/gods_of_the_arena/[batch, presets]

proc parsePositive(value, name: string): int =
  if parseInt(value, result) != value.len or result <= 0:
    raise newException(ValueError, name & " must be a positive integer")

let arguments = commandLineParams()
if arguments.len != 4:
  quit "benchmark_gota_batch CONFIG BOT GAMES TICKS", QuitFailure
let
  config = loadConfig(arguments[0])
  bot = arguments[1]
  count = parsePositive(arguments[2], "GAMES")
  ticks = parsePositive(arguments[3], "TICKS")
  scalar = newGotaBatch(count, 1, config, bot)
  parallel = newGotaBatch(count, count, config, bot)

let scalarStarted = getMonoTime()
for _ in 0 ..< ticks:
  scalar.step(1)
let scalarSeconds = (getMonoTime() - scalarStarted).inNanoseconds.float64 / 1e9

let batchStarted = getMonoTime()
for _ in 0 ..< ticks:
  parallel.step(1)
let batchSeconds = (getMonoTime() - batchStarted).inNanoseconds.float64 / 1e9

doAssert scalar.stateHashes() == parallel.stateHashes()
doAssert scalar.observations() == parallel.observations()
scalar.close()
parallel.close()

echo &"games={count} ticks={ticks} threads={count} " &
  &"scalar_seconds={scalarSeconds:.6f} batch_seconds={batchSeconds:.6f} " &
  &"speedup={scalarSeconds / batchSeconds:.3f}"
