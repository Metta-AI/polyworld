import ../[game, presets, sim]

doAssert run == nil, "Importing the game must not allocate a world or require a roster"
initializeOptions()
doAssert run == nil, "Menu option parsing must accept an empty roster"
var config = defaultConfig(3)
config.maxTicks = 2
initializeLocalMatch(config, ["", "", ""])
doAssert run != nil and run.world.players.len == 3
advanceGame()
doAssert run.world.tick == 1
initializeMatch()
doAssert run.world.tick == 1, "Initializing an existing match must be idempotent"
echo "Lazy game import and local setup passed"
