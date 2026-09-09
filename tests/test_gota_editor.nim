import
  std/[os, strutils],
  polyworld/pathing,
  ../examples/gods_of_the_arena/[edits, mapfiles, maps, replays, sim]

proc expectInvalid(source: string) =
  ## Requires malformed map data to raise the map-specific exception.
  var rejected = false
  try:
    discard decodeMap(source)
  except GotaMapError:
    rejected = true
  doAssert rejected, "invalid map data was accepted"

proc testRoundTrip() =
  ## Checks every packed tile and its deterministic hash survives JSON.
  let
    generated = generateMap(2026)
    original = captureDocument("Round trip },{ \"tiles\":[", generated.seed)
    source = encodeMap(original)
    decoded = decodeMap(source)
    installed = installMap(decoded)
  doAssert installed == generated
  let legacy = decodeMap(source.replace("\"version\":2", "\"version\":1"))
  doAssert installMap(legacy).hash == generated.hash
  doAssert decoded.name == original.name
  doAssert arenaIssues().len == 0
  for i, layer in layers:
    doAssert layer.tiles == original.layers[i].tiles
  doAssert encodeMap(decoded) == source
  expectInvalid("{")
  expectInvalid(source.replace("\"version\":2", "\"version\":99"))
  expectInvalid(source.replace(
    "\"heightUnitsPerTile\":8", "\"heightUnitsPerTile\":4"
  ))
  expectInvalid(source.replace("\"width\":128", "\"width\":129"))
  expectInvalid(source.replace(
    "\"surface\":\"grass\"", "\"surface\":\"unknown\""
  ))
  expectInvalid(source.replace("\"tops\":[", "\"tops\":[999999,"))
  doAssert finishMap(2026).hash == generated.hash,
    "failed parsing modified live terrain"
  let directory = getTempDir() / ("gota-map-test-" & $getCurrentProcessId())
  createDir(directory)
  let path = directory / "arena.json"
  defer:
    removeFile(path)
    removeDir(directory)
  writeMap(path, original)
  doAssert loadMap(path).hash == generated.hash
  doAssert not fileExists(path & ".saving")
  let draft = captureDocument("Blocked draft", 2026)
  draft.layers[GroundLayer].tiles[20 * GridTiles + 23].impassable = true
  writeMap(path, draft)
  var rejected = false
  try:
    discard loadMap(path)
  except GotaMapError:
    rejected = true
  doAssert rejected, "the game accepted a blocked lane spawn"
  doAssert finishMap(2026).hash == generated.hash,
    "a rejected map changed the previously installed terrain"

proc testBrushes() =
  ## Checks atomic strokes, trees, water, protection, and history branching.
  discard generateMap(2026)
  var history: EditHistory
  let
    index = 30 * GridTiles + 45
    before = layers[GroundLayer].tiles[index]
    waterBefore = layers[WaterLayer].tiles[index]
    fortBefore = layers[GroundLayer].tiles[20 * GridTiles + 20]
  history.beginEdit()
  history.paintBrush(20, 20, 3, ElevationBrush, 4)
  doAssert not history.commitEdit()
  doAssert layers[GroundLayer].tiles[20 * GridTiles + 20] == fortBefore
  history.beginEdit()
  history.paintBrush(45, 30, 0, WaterBrush, 0)
  history.paintBrush(45, 30, 0, WaterBrush, 0)
  doAssert history.commitEdit()
  computeWalkable()
  doAssert isWalkable(GroundLayer, 45, 30)
  doAssert layers[WaterLayer].tiles[index].tops[0] == -5
  doAssert history.undo()
  doAssert layers[GroundLayer].tiles[index] == before
  doAssert layers[WaterLayer].tiles[index] == waterBefore
  doAssert not history.undo(), "a repeated tile created duplicate strokes"
  doAssert history.redo()
  history.beginEdit()
  history.paintBrush(45, 30, 0, TreeBrush)
  doAssert history.commitEdit()
  doAssert layers[GroundLayer].tiles[index].impassable
  doAssert not layers[WaterLayer].tiles[index].exists
  doAssert history.undo()
  history.beginEdit()
  history.paintBrush(45, 30, 0, ElevationBrush, 2)
  doAssert history.commitEdit()
  doAssert not history.redo(), "a new edit did not discard the redo branch"
  let saved = layers[GroundLayer].tiles[index]
  history.beginEdit()
  history.paintBrush(45, 30, 0, ElevationBrush, 4)
  doAssert history.cancelEdit()
  doAssert layers[GroundLayer].tiles[index] == saved
  history.beginEdit()
  history.paintStroke(45, 30, 60, 30, 0, ElevationBrush, 1)
  doAssert history.commitEdit()
  for x in 45 .. 60:
    doAssert layers[GroundLayer].tiles[30 * GridTiles + x].tops[0] == 0

proc testRamps() =
  ## Ensures cliffs block edges and ramps restore real navigation both ways.
  discard generateMap(2026)
  var history: EditHistory
  history.beginEdit()
  for z in 24 .. 38:
    for x in 42 .. 68:
      history.paintBrush(x, z, 0, ElevationBrush, int(x >= 55) + 1)
      history.paintBrush(x, z, 0, OpenBrush)
  discard history.commitEdit()
  computeWalkable()
  doAssert not edgeLink(GroundLayer, 54, 30, 0).open
  history.beginEdit()
  doAssert history.paintRamp(52, 30, 58, 30, 1)
  doAssert history.commitEdit()
  computeWalkable()
  let path = findTilePath(GroundLayer, 50, 30, GroundLayer, 61, 30)
  doAssert path.len > 0 and path.len <= 13
  doAssert findTilePath(GroundLayer, 61, 30, GroundLayer, 50, 30).len > 0
  let ramp = layers[GroundLayer].tiles[30 * GridTiles + 55]
  doAssert ramp.tops[0] < ramp.tops[1]
  doAssert history.undo()
  computeWalkable()
  doAssert not edgeLink(GroundLayer, 54, 30, 0).open
  doAssert history.redo()
  computeWalkable()
  doAssert edgeLink(GroundLayer, 54, 30, 0).open
  history.beginEdit()
  doAssert not history.paintRamp(20, 20, 25, 20, 1)
  doAssert not history.commitEdit()
  history.beginEdit()
  for z in 42 .. 62:
    for x in 42 .. 48:
      history.paintBrush(x, z, 0, ElevationBrush, int(z >= 52) + 1)
      history.paintBrush(x, z, 0, OpenBrush)
  discard history.commitEdit()
  history.beginEdit()
  doAssert history.paintRamp(45, 55, 45, 49, 1)
  doAssert history.commitEdit()
  computeWalkable()
  doAssert findTilePath(GroundLayer, 45, 47, GroundLayer, 45, 57).len <= 12
  doAssert layers[GroundLayer].tiles[52 * GridTiles + 45].tops[0] <
    layers[GroundLayer].tiles[52 * GridTiles + 45].tops[2]
  for i in 0 .. MaximumUndoSteps + 5:
    history.beginEdit()
    history.paintBrush(45, 30, 0, ElevationBrush, i mod 5)
    discard history.commitEdit()
  var undone = 0
  while history.undo():
    inc undone
  doAssert undone == MaximumUndoSteps

echo "Testing authored map JSON and deterministic loading"
testRoundTrip()
echo "Testing terrain strokes, water, trees, and undo"
testBrushes()
echo "Testing traversable ramps and bounded edit history"
testRamps()

proc testSmoothingAndScaling() =
  ## Checks shared corners, gentle slopes, exact undo, and height rescaling.
  discard generateMap(2026)
  var history: EditHistory
  history.beginEdit()
  for z in 25 .. 35:
    for x in 45 .. 55:
      history.paintBrush(x, z, 0, ElevationBrush, 1)
      history.paintBrush(x, z, 0, OpenBrush)
  history.paintBrush(50, 30, 0, ElevationBrush, 4)
  discard history.commitEdit()
  let before = captureDocument("Before smooth", 2026)
  history.beginEdit()
  for i in 0 .. 5:
    history.smoothTerrain(50, 30, 3)
  doAssert history.commitEdit()
  doAssert max(layers[0].tiles[30 * GridTiles + 50].tops) < 24
  for z in 28 .. 32:
    for x in 48 .. 52:
      let
        tile = layers[0].tiles[z * GridTiles + x]
        east = layers[0].tiles[z * GridTiles + x + 1]
        south = layers[0].tiles[(z + 1) * GridTiles + x]
      doAssert tile.tops[1] == east.tops[0]
      doAssert tile.tops[3] == east.tops[2]
      doAssert tile.tops[2] == south.tops[0]
      doAssert tile.tops[3] == south.tops[1]
  computeWalkable()
  doAssert findTilePath(0, 46, 30, 0, 54, 30).len == 9
  doAssert history.undo()
  doAssert layers[0].tiles == before.layers[0].tiles
  history.beginEdit()
  doAssert history.scaleHeights(1, 2)
  doAssert history.commitEdit()
  doAssert layers[0].tiles[30 * GridTiles + 50].tops[0] == 12
  doAssert history.undo()
  for i, layer in layers:
    doAssert layer.tiles == before.layers[i].tiles

proc testWalls() =
  ## Checks solid wall collision, erased openings, and restored terrain.
  discard generateMap(2026)
  var history: EditHistory
  history.beginEdit()
  for z in 25 .. 35:
    for x in 45 .. 55:
      history.paintBrush(x, z, 0, ElevationBrush, 1)
      history.paintBrush(x, z, 0, OpenBrush)
  discard history.commitEdit()
  let ground = captureDocument("Ground", 2026)
  history.beginEdit()
  history.paintWallStroke(50, 27, 50, 33, 0, 16, 0)
  doAssert history.commitEdit()
  computeWalkable()
  doAssert not isWalkable(0, 50, 30)
  doAssert not isWalkable(WallLayer, 50, 30)
  doAssert layers[0].tiles == ground.layers[0].tiles
  doAssert findTilePath(0, 48, 30, 0, 52, 30).len > 5
  history.beginEdit()
  history.paintWall(50, 30, 0, 16, 0, erase = true)
  doAssert history.commitEdit()
  computeWalkable()
  doAssert isWalkable(0, 50, 30)
  doAssert findTilePath(0, 48, 30, 0, 52, 30).len == 5
  doAssert history.undo()
  computeWalkable()
  doAssert not isWalkable(0, 50, 30)
  doAssert history.undo()
  computeWalkable()
  doAssert isWalkable(0, 50, 30)
  doAssert layers[0].tiles == ground.layers[0].tiles

proc testBuildings() =
  ## Verifies authored structures survive saves and drive real match objects.
  discard generateMap(2026)
  mapBuildings = defaultBuildings()
  authoredBuildings = true
  ensureWallLayer()
  computeWalkable()
  doAssert mapBuildings.len == 26
  doAssert arenaIssues().len == 0, $arenaIssues()
  var history: EditHistory
  let original = captureDocument("Original buildings", 2026)
  history.beginEdit()
  for building in mapBuildings:
    if building.team == 0 and (building.kind == GodBuilding or
      (building.lane == 0 and building.kind == BarracksBuilding)):
        var moved = building
        moved.layer = 0
        moved.x = if building.kind == GodBuilding: 20 else: 24
        moved.z = if building.kind == GodBuilding: 24 else: 20
        history.placeBuilding(moved)
  var tower = mapBuildings[0]
  tower.x = 60
  tower.z = 30
  tower.rotation = 90
  history.paintBrush(tower.x, tower.z, 0, OpenBrush)
  history.placeBuilding(tower)
  doAssert history.commitEdit()
  let
    changed = finishMap(2026)
    source = encodeMap(captureDocument("Authored buildings", 2026))
    decoded = decodeMap(source)
  doAssert installMap(decoded).hash == changed.hash
  doAssert decoded.buildings == mapBuildings
  doAssert arenaIssues().len == 0, $arenaIssues()
  let game = newGame(changed, 24, 0, false, ReplayData())
  doAssert game.world.towers.len == 18
  doAssert game.world.towers[0].position.x ==
    (60 - 64) * WorldScale + WorldScale div 2
  doAssert game.world.towers[0].position.z ==
    (30 - 64) * WorldScale + WorldScale div 2
  doAssert game.world.forts[0].center.z ==
    (24 - 64) * WorldScale + WorldScale div 2
  doAssert game.world.barracksSpawns[0][0].x ==
    (24 - 64) * WorldScale + WorldScale div 2
  doAssert history.undo()
  doAssert mapBuildings == original.buildings
  doAssert history.redo()
  history.beginEdit()
  history.removeBuilding(0)
  doAssert history.commitEdit()
  doAssert mapBuildings.len == 25
  doAssert history.undo()
  doAssert mapBuildings.len == 26
  expectInvalid(source.replace("\"team\":0", "\"team\":3"))
  expectInvalid(source.replace(
    "\"kind\":\"TowerBuilding\"", "\"kind\":\"Unknown\""
  ))
  let
    directory = getTempDir() / ("gota-buildings-" & $getCurrentProcessId())
    path = directory / "draft.json"
  createDir(directory)
  defer:
    removeFile(path)
    removeDir(directory)
  var draft = captureDocument("Missing god", 2026)
  for i in countdown(draft.buildings.high, 0):
    if draft.buildings[i].kind == GodBuilding:
      draft.buildings.delete(i)
  writeMap(path, draft)
  var rejected = false
  try:
    discard loadMap(path)
  except GotaMapError:
    rejected = true
  doAssert rejected
  doAssert mapBuildings == decoded.buildings
  doAssert finishMap(2026).hash == changed.hash

echo "Testing smooth slopes and height operations"
testSmoothingAndScaling()
echo "Testing solid castle walls and openings"
testWalls()
echo "Testing saved buildings and match integration"
testBuildings()
