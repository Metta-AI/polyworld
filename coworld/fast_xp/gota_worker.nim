## Runs one Gota match using the existing file handoff without a host server.
import
  ../../examples/gods_of_the_arena/[game, sim, scores],
  polyworld/coworld

runHeadless()
finishCoworld(CoworldResults(
  scores: scores(run.world.totalXp(), int(run.world.tick)),
  ticks: run.world.tick,
  seed: options.seed,
  outcome: run.world.outcome()
), run.world.totalXp())
