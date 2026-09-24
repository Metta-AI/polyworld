import polyworld/pathing
import ../examples/gods_of_the_arena/maps as gameMaps
import ../examples/gods_of_the_arena/generation/maps as editorMaps
import ../examples/gods_of_the_arena/generation/tiles as editorTiles
import ../examples/gods_of_the_arena/[content, sim, replays, terrains]

const Size = editorTiles.TileCount

echo "Checking the saved editor preset in the game."
doAssert editorMaps.defaultConfig().mapSize == 116
doAssert editorMaps.defaultConfig().roadWidth == 52.7'f
doAssert editorMaps.defaultConfig().campRadius == 36
doAssert editorMaps.defaultConfig().jungleRoads == 32
doAssert editorMaps.defaultConfig().campsTouchRoads
let
  preview = editorMaps.generateMap(editorMaps.defaultConfig())
  tiles = editorTiles.buildTiles(preview)
  map = gameMaps.generateMap(54)
doAssert map.resolution == 116
for layer in layers:
  doAssert layer.width == 116 and layer.depth == 116
doAssert map.layout.camps.len == 14
doAssert map.layout.barracks.len == 12
doAssert map.seed == 54
doAssert gameMaps.generateMap(1988).hash == map.hash,
  "Match randomness must not select a different map preset."
var
  wallCount = 0
  slopedWallCount = 0
for y in 0 ..< Size:
  for x in 0 ..< Size:
    let
      tile = tiles.cells[y * Size + x]
      ground = layers[0].tiles[y * Size + x]
    doAssert isWalkable(0, x, y) == tile.passable,
      "Walkability differs from the editor at " & $(x, y)
    doAssert terrainValue(x.int32, y.int32, 0, TerrainWalkableField) ==
      int32(tile.passable)
    doAssert terrainValue(x.int32, y.int32, 0, TerrainKindField) !=
      TerrainNone.ord
    if tile.surface == editorTiles.WallSurface:
      let
        layer =
          if tile.side == editorMaps.Northeast:
            gameMaps.RedFortLayer
          else:
            gameMaps.BlueFortLayer
        wall = layers[layer].tiles[y * Size + x]
      inc wallCount
      doAssert not wall.exists, "Raised wall foundations must not be generated."
      doAssert ground.impassable and not isWalkable(0, x, y)
      doAssert not isWalkable(layer, x, y),
        "Removing foundations must not create an upper walking surface."
      doAssert terrainValue(x.int32, y.int32, 0, TerrainKindField) ==
        TerrainWall.ord
      for height in ground.tops:
        doAssert height <= 16, "Wall footprints must use natural ground height."
      if ground.tops != [16'i16, 16, 16, 16]:
        inc slopedWallCount
    if x + 1 < Size and (tile.surface == editorTiles.WallSurface or
      tiles.cells[y * Size + x + 1].surface == editorTiles.WallSurface):
        let next = layers[0].tiles[y * Size + x + 1]
        doAssert ground.connectedEast
        doAssert ground.tops[1] == next.tops[0] and
          ground.tops[3] == next.tops[2],
          "Wall footprints must join their eastern neighbor smoothly."
    if y + 1 < Size and (tile.surface == editorTiles.WallSurface or
      tiles.cells[(y + 1) * Size + x].surface == editorTiles.WallSurface):
        let next = layers[0].tiles[(y + 1) * Size + x]
        doAssert ground.connectedSouth
        doAssert ground.tops[2] == next.tops[0] and
          ground.tops[3] == next.tops[1],
          "Wall footprints must join their southern neighbor smoothly."
    if tile.surface == editorTiles.TreeSurface:
      let expected =
        if tile.side == editorMaps.Northeast:
          TerrainRock
        else:
          TerrainTrees
      doAssert terrainValue(x.int32, y.int32, 0, TerrainKindField) ==
        expected.ord
    var interior = x > 0 and y > 0 and x < Size - 1 and y < Size - 1
    if interior:
      for dz in -1 .. 1:
        for dx in -1 .. 1:
          let neighbor = tiles.cells[(y + dz) * Size + x + dx]
          if neighbor.terrain != tile.terrain or neighbor.ramp:
            interior = false
    if interior and tile.surface == editorTiles.NaturalSurface:
      let heights = layers[0].tiles[y * Size + x].tops
      if heights[0] == heights[1] and heights[0] == heights[2] and
        heights[0] == heights[3]:
          case tile.terrain
          of editorTiles.LowGround:
            doAssert heights[0] == 0
          of editorTiles.HighGround:
            doAssert heights[0] == 8
          of editorTiles.CastleGround, editorTiles.KeepGround,
            editorTiles.SpawnGround:
              doAssert heights[0] == 16
          of editorTiles.LakeGround:
            doAssert heights[0] == -8
    if tile.passable:
      for direction in editorTiles.Direction:
        let link = edgeLink(0, x, y, [3, 0, 1, 2][direction.ord])
        doAssert link.open == tiles.canStep(x, y, direction),
          "Cliff or ramp differs from the editor at " & $(x, y, direction)
doAssert wallCount > 0 and slopedWallCount > 0
for lane in map.layout.lanes:
  for i in 1 ..< lane.len:
    let
      first = lane[i - 1]
      last = lane[i]
    doAssert findTilePath(0, first.x, first.z, 0, last.x, last.z).len > 0
let first = map.layout.lanes[0][0]
proc checkAccess(point: PathPoint) =
  ## Checks that a generated clearing or spawn reaches the lane network.
  let
    x = int((point.x + Size div 2 * PathUnitsPerTile) div PathUnitsPerTile)
    z = int((point.z + Size div 2 * PathUnitsPerTile) div PathUnitsPerTile)
  doAssert findTilePath(0, first.x, first.z, 0, x, z).len > 0,
    "Generated site is unreachable at " & $(x, z)
for point in map.layout.camps:
  checkAccess(point)
for point in map.layout.spawns:
  checkAccess(point)
for site in map.layout.barracks:
  checkAccess(site.spawn)
echo "Game terrain matches every editor tile and movement edge."

echo "Checking generated towers, hero spawns, and paired barracks in play."
let game = newGame(map, 100_000, 10, false, ReplayData(), drafting = false)
game.world.heroTurnTicks = 100_000
doAssert game.world.buildings.len == 34
for tower in game.world.buildings:
  if tower.kind != TowerBuilding:
    continue
  if tower.guardsGod:
    var found = false
    for site in map.layout.guards[tower.team.ord]:
      if tower.position.x == site.position.x * (WorldScale div PathUnitsPerTile) and
          tower.position.z == site.position.z * (WorldScale div PathUnitsPerTile):
        found = true
    doAssert found
    continue
  let point = map.layout.towers[tower.lane][tower.team.ord][tower.tier.ord].position
  doAssert tower.position.x == point.x * (WorldScale div PathUnitsPerTile)
  doAssert tower.position.z == point.z * (WorldScale div PathUnitsPerTile)
for hero in game.world.heroes:
  let tile = tiles.cells[
    mapCoordinate(hero.position.z).int * Size +
    mapCoordinate(hero.position.x).int
  ]
  doAssert tile.terrain == editorTiles.SpawnGround
game.tickWorld(nil)
var laneCreeps = 0
for unit in game.world.footmen:
  if unit.camp == 0:
    inc laneCreeps
doAssert laneCreeps == 12 * CreepsPerBarracks
for team in sim.Team:
  for lane in 0 .. 2:
    var sites: seq[WorldPoint]
    for building in game.world.buildings:
      if building.kind == BarracksBuilding and building.team == team and
          building.lane == lane:
        sites.add building.spawn
    doAssert sites.len == 2
    doAssert sites[0] != sites[1], "Both creeps must use their own barracks."
for tick in 1 .. 500:
  game.tickWorld(nil)
for footman in game.world.footmen:
  let tile = tiles.cells[
    mapCoordinate(footman.position.z).int * Size +
    mapCoordinate(footman.position.x).int
  ]
  doAssert tile.terrain notin {
    editorTiles.CastleGround, editorTiles.KeepGround, editorTiles.SpawnGround
  }, "A creep failed to march out of its generated fort."
echo "Generated structures and all thirty-six creep spawns passed."
echo "Map fingerprint: ", map.hash, "; simulation fingerprint: ", game.stateHash()

echo "Checking that direct movement respects cliffs and crosses ramps."
for edge in [editorTiles.CliffEdge, editorTiles.RampEdge]:
  var
    sourceX = -1
    sourceZ = -1
  for z in 1 ..< Size - 1:
    for x in 1 ..< Size - 2:
      let index = z * Size + x
      if sourceX < 0 and tiles.cells[index].passable and
        tiles.cells[index + 1].passable and
        tiles.cells[index].edges[editorTiles.East] == edge:
          sourceX = x
          sourceZ = z
  doAssert sourceX >= 0, "No walkable tiles found on either side of the edge."
  let trial = newGame(map, 100_000, 10, false, ReplayData(), drafting = false)
  trial.world.heroes.setLen(1)
  for building in trial.world.buildings.mitems:
    building.hp = 0
  trial.world.syncBuildings()
  trial.world.spawnTimerTicks = 100_000
  trial.world.heroTurnTicks = 100_000
  let
    hero = trial.world.heroes[0]
    origin = WorldPoint(
      x: (sourceX.int32 - Size div 2) * WorldScale + WorldScale div 2,
      z: (sourceZ.int32 - Size div 2) * WorldScale + WorldScale div 2
    )
    target = WorldPoint(x: origin.x + WorldScale, z: origin.z)
  hero.place(origin)
  hero.movePath = @[target]
  hero.movePathLayers = @[0'i32]
  hero.hasMoveTarget = true
  hero.moveRevision = trial.world.navigationRevision
  for tick in 0 ..< 60:
    # Keep this deliberate straight route to isolate cliff collision.
    hero.stuckTicks = 0
    trial.tickWorld(nil)
  let expectedX = sourceX + int(edge == editorTiles.RampEdge)
  doAssert mapCoordinate(hero.position.x).int == expectedX,
    "Direct movement did not respect " & $edge
echo "Cliffs block direct movement and ramps allow it."
