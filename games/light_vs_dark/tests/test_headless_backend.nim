import ../[game, sim]
doAssert run == nil
runHeadless()
doAssert run != nil and run.world.tick == 4
