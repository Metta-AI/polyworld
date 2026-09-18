## Edit the replay path and loops below to explore a match.

import
  polyworld/tapes,
  ../[maps, replays, sim]

const ReplayPath = "examples/gods_of_the_arena/replays/demo.replay"

let
  replay = loadReplay(ReplayPath)
  game = newGame(
    generateMap(replay.config.seed, replay.config.mapPreset),
    replay.config.spawnIntervalTicks,
    0,
    true,
    replay
  )

game.replayPlayer = initReplayPlayer(replay)
game.historyPlayback = true

echo "Config: ", replay.config
for tick in 0 .. replay.hashes.len:
  if tick > 0:
    game.tickWorld(nil)
    game.hashCheck.requireReplayComplete(uint32(game.world.tick), tick)

  echo "Tick: ", game.world.tick
  for god in game.world.forts:
    echo "God: ", god
  for building in game.world.buildings:
    echo "Building: ", building
  for hero in game.world.heroes:
    echo "Hero: ", hero[]
  for creep in game.world.footmen:
    echo "Creep: ", creep
  for spell in game.world.casts:
    echo "Spell: ", spell
  for index, event in game.world.events:
    echo "Event ", index, ": ", event

if not game.replayPlayer.finished:
  raise newException(ReplayError, "Replay has unconsumed actions")
