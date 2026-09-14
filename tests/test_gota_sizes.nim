import
  polyworld/[pathing, tapes],
  ../examples/gods_of_the_arena/[maps, replays, sim, terrains]
import ../examples/gods_of_the_arena/generation/maps as editorMaps
import ../examples/gods_of_the_arena/generation/tiles as editorTiles

echo "Testing the original version 26 preset."
var original = defaultConfig()
original.mapSize = 128
original.roadWidth = 62
let historical = generateMap(54, original, CryptArena)
doAssert historical.hash == 3213363289'u64
let oldGame = newGame(historical, 240, 10, false, ReplayData())
var oldData = initReplayData(oldGame.currentSetup(60), original)
oldData.header.gameVersion = PresetGameVersion
let restoredOld = decodeReplay(oldData.encodeReplay())
doAssert restoredOld.config.mapPreset == original
doAssert restoredOld.header.setup.gridTiles == 128
doAssert generateMap(54, restoredOld.config.mapPreset, CryptArena).hash == historical.hash
doAssert restoredOld.encodeReplay() == oldData.encodeReplay()

for size in [64, 96, 100, 116, 128, 192, 256]:
  echo "Testing a ", size, " tile preset and its replay."
  var preset = defaultConfig()
  preset.mapSize = size
  let
    preview = editorMaps.generateMap(preset)
    grid = editorTiles.buildTiles(preview)
    map = generateMap(54, preset)
  doAssert map.resolution == size
  doAssert map.minimap.len == size * size
  doAssert grid.resolution == size and grid.cells.len == size * size
  for layer in layers:
    doAssert layer.width == size and layer.depth == size
    doAssert layer.originX == (GridTiles - size) div 2
    doAssert layer.originZ == layer.originX
  for i, tile in grid.cells:
    let paired = grid.cells[grid.cells.high - i]
    doAssert tile.terrain == paired.terrain
    doAssert tile.surface == paired.surface
    doAssert tile.ramp == paired.ramp
    doAssert tile.side != paired.side
  let first = map.layout.lanes[0][0]
  for point in map.layout.camps:
    let
      half = size.int32 div 2 * PathUnitsPerTile
      x = ((point.x + half) div PathUnitsPerTile).int
      z = ((point.z + half) div PathUnitsPerTile).int
    doAssert findTilePath(0, first.x, first.z, 0, x, z).len > 0,
      "Camp cannot reach the lanes at size " & $size & ": " & $(x, z)
  let game = newGame(map, 240, 10, false, ReplayData())
  game.world.heroTurnTicks = 100_000
  game.recorder = initReplayRecorder(game.currentSetup(60), preset)
  for hero in game.world.heroes:
    let
      x = mapCoordinate(hero.position.x)
      z = mapCoordinate(hero.position.z)
    doAssert x in 0 ..< size and z in 0 ..< size
    doAssert terrainValue(x, z, 0, TerrainWalkableField) == 1
  for tick in 0 ..< 60:
    game.tickWorld(nil)
  let
    data = decodeReplay(game.recorder.data.encodeReplay())
    expected = game.stateHash()
  doAssert data.config.mapPreset.mapSize == size
  doAssert data.header.setup.gridTiles.int == size
  discard generateMap(54)
  let
    restored = generateMap(data.config.seed, data.config.mapPreset)
    replay = newGame(restored, 240, 10, true, data)
  doAssert restored.hash == map.hash
  replay.world.heroTurnTicks = 100_000
  replay.historyPlayback = true
  replay.replayPlayer = initReplayPlayer(data)
  for tick in 0 ..< 60:
    replay.tickWorld(nil)
  doAssert replay.hashCheck.mismatches == 0, replay.hashCheck.error
  doAssert replay.stateHash() == expected
  var invalid = data
  invalid.config.mapPreset.mapSize += 2
  try:
    discard invalid.encodeReplay()
    doAssert false, "The replay size must agree with its map preset."
  except ReplayError:
    discard

echo "test_gota_sizes: all checks passed"
