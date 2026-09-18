## Compile with -d:headless. Supply --bot:...:10, --seed N, and --ticks N.
## Writes every authoritative tick hash for before/after correctness comparison.
import
  std/[monotimes, times],
  ../examples/gods_of_the_arena/[game, sim]

let started = getMonoTime()
while run.world.tick < options.maximumTicks and not run.world.gameOver:
  advanceGame()
  echo run.world.tick, " ", run.stateHash()
stderr.writeLine "ticks=", run.world.tick, " seconds=", (getMonoTime() - started).inNanoseconds.float64 / 1e9
