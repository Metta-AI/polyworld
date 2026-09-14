## Checks legacy replay terrain and its real BASIC host interface.

import
  std/[os, tempfiles],
  polyworld/[basic, cli, pathing],
  ../examples/gods_of_the_arena/[bots, maps, replays, sim, terrains]

proc terrain(field: TerrainField, x, y: int, layer = GroundLayer): int32 =
  ## Reads one field using convenient test coordinates.
  terrainValue(x.int32, y.int32, layer.int32, field)

echo "Testing grass, forests, rivers, walls, and gates on the static map"
for seed in [1988'i32, 2026'i32]:
  discard generateLegacyMap(seed)
  var seen: set[TerrainKind]
  for y in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let kind = TerrainKind(terrain(TerrainKindField, x, y))
      seen.incl kind
      case kind
      of TerrainTrees, TerrainWall:
        doAssert terrain(TerrainWalkableField, x, y) == 0
      else:
        doAssert terrain(TerrainWalkableField, x, y) ==
          int32(isWalkable(GroundLayer, x, y))
  doAssert {TerrainGrass, TerrainRoad, TerrainTrees, TerrainMarsh,
    TerrainWall} <= seen
  doAssert TerrainNone notin seen

  let
    wallX = RedFortTile - FortWallRadius
    wallY = RedFortTile + 1
    gateX = RedFortTile + FortWallRadius
    gateY = RedFortTile + 1
  doAssert terrain(TerrainKindField, wallX, wallY) == TerrainWall.ord
  doAssert terrain(TerrainWalkableField, wallX, wallY) == 0
  doAssert terrain(TerrainKindField, wallX, wallY, RedFortLayer) ==
    TerrainWall.ord
  doAssert terrain(TerrainWalkableField, wallX, wallY, RedFortLayer) == 1
  doAssert terrain(TerrainHeightField, wallX, wallY, RedFortLayer) -
    terrain(TerrainHeightField, wallX, wallY) == 36
  doAssert terrain(TerrainKindField, gateX, gateY) == TerrainRoad.ord
  doAssert terrain(TerrainWalkableField, gateX, gateY) == 1
  doAssert terrain(TerrainWalkableField, gateX, gateY, RedFortLayer) == 1
  doAssert terrain(TerrainKindField, gateX, gateY, BlueFortLayer) == 0
  doAssert terrain(TerrainWalkableField, wallX, RedFortTile, RedFortLayer) == 0,
    "The raised crenellation must stay blocked above a solid wall."
  doAssert terrain(TerrainHeightField, wallX, RedFortTile, RedFortLayer) -
    terrain(TerrainHeightField, wallX, RedFortTile) ==
      36 + FortCrenellationRiseSteps
  doAssert terrain(TerrainKindField, wallX + 1, RedFortTile) == TerrainRoad.ord
  doAssert terrain(TerrainWalkableField, wallX + 1, RedFortTile) == 1,
    "The courtyard remains open underneath its overhanging rampart."

  doAssert terrain(TerrainKindField, 64, 64) == TerrainMarsh.ord
  doAssert terrain(TerrainWalkableField, 64, 64) == 1
  doAssert terrain(TerrainWaterDepthField, 64, 64) == 1
  doAssert terrain(TerrainHeightField, 64, 64) == -14
  doAssert terrain(TerrainKindField, 64, 64, WaterLayer) == TerrainWater.ord
  doAssert terrain(TerrainHeightField, 64, 64, WaterLayer) == -13
  doAssert terrain(TerrainWaterDepthField, 64, 64, WaterLayer) == 1
  doAssert terrain(TerrainWalkableField, 64, 64, WaterLayer) == 0
  doAssert terrain(TerrainWaterDepthField, gateX, gateY) == 0
  for site in LandmarkHillSites:
    doAssert terrain(TerrainKindField, site[0], site[1]) == TerrainGrass.ord
    doAssert terrain(TerrainWalkableField, site[0], site[1]) == 1
  for site in QuarrySites:
    doAssert terrain(TerrainKindField, site[0], site[1]) == TerrainRock.ord
    doAssert terrain(TerrainWalkableField, site[0], site[1]) == 1
    doAssert terrain(TerrainWaterDepthField, site[0], site[1]) == 0,
      "The negative-height quarry floor is dry, unlike the riverbed."
  for lane in TowerSites:
    for team in lane:
      for site in team:
        doAssert terrain(TerrainKindField, site.x, site.z) == TerrainRoad.ord,
          "A paved tower court is a surface, not a solid wall."
        doAssert terrain(TerrainWalkableField, site.x, site.z) == 1

echo "Testing invalid coordinates, missing layers, and absent surfaces"
for field in TerrainField:
  for coordinate in [int32.low, -1'i32, GridTiles.int32, int32.high]:
    doAssert terrainValue(coordinate, 0, GroundLayer, field) == 0
    doAssert terrainValue(0, coordinate, GroundLayer, field) == 0
  for layer in [int32.low, -1'i32, layers.len.int32, int32.high]:
    doAssert terrainValue(20, 20, layer, field) == 0
  doAssert terrain(field, 0, 0, RedFortLayer) == 0
  doAssert terrain(field, 0, 0, WaterLayer) == 0

echo "Testing sloped tile centers, shallow water, and raised surfaces"
block:
  layers = @[
    QuadLayer(
      originX: 7, originZ: 9, width: 2, depth: 1,
      tiles: @[
        Tile(flags: TileExists, kind: MarshTile, tops: [-16'i16, -15, -15, -15]),
        Tile(flags: TileExists, kind: RockTile, tops: [0'i16, 0, 32, 32])
      ]
    ),
    QuadLayer(
      originX: 7, originZ: 9, width: 1, depth: 1, slab: true,
      tiles: @[
        Tile(flags: TileExists, kind: StoneTile, tops: [8'i16, 8, 8, 8])
      ]
    ),
    QuadLayer(
      originX: 7, originZ: 9, width: 1, depth: 1, water: true,
      tiles: @[
        Tile(flags: TileExists, tops: [-15'i16, -15, -15, -15])
      ]
    )
  ]
  computeWalkable()
  doAssert terrain(TerrainHeightField, 7, 9) == -15
  doAssert terrain(TerrainWaterDepthField, 7, 9) == 1,
    "Even a quarter-step of water at the tile center must report wet."
  doAssert terrain(TerrainWaterDepthField, 7, 9, 1) == 0,
    "Water beneath a raised surface must not make its top wet."
  doAssert terrain(TerrainWaterDepthField, 7, 9, 2) == 1
  doAssert terrain(TerrainHeightField, 8, 9) == 16
  doAssert terrain(TerrainKindField, 8, 9) == TerrainRock.ord
  doAssert terrain(TerrainWalkableField, 8, 9) == 0,
    "A steep rocky slope must be reported as unwalkable."
  doAssert terrain(TerrainKindField, 7, 9, 1) == TerrainWall.ord
  doAssert terrain(TerrainKindField, 8, 9, 1) == 0

proc checkBasicTerrain() =
  ## Exercises all eight host calls, constants, layers, and fog in real VMs.
  let
    directory = createTempDir("gota-terrain-", "")
    path = directory / "terrain.bas"
    game = newGame(generateLegacyMap(1988), 240, 10, false, ReplayData())
  defer:
    removeDir(directory)
  writeFile(path, """
width = mapWidth
height = mapHeight
layerCount = mapLayers
myLayer = selfLayer
kind = terrainKind(9, 21)
walkable = terrainWalkable(9, 21)
elevation = terrainHeight(9, 21)
depth = terrainWaterDepth(9, 21)
bedKind = terrainKindAt(64, 64, GroundLayer)
bedWalkable = terrainWalkableAt(64, 64, GroundLayer)
bedHeight = terrainHeightAt(64, 64, GroundLayer)
bedDepth = terrainWaterDepthAt(64, 64, GroundLayer)
waterKind = terrainKindAt(64, 64, WaterLayer)
waterWalkable = terrainWalkableAt(64, 64, WaterLayer)
waterHeight = terrainHeightAt(64, 64, WaterLayer)
waterDepth = terrainWaterDepthAt(64, 64, WaterLayer)
enemyWall = terrainKindAt(96, 107, BlueFortLayer)
noneKind = terrainKindAt(0, 0, RedFortLayer)
badKind = terrainKind(-1, 20)
badLayer = terrainWalkableAt(9, 21, mapLayers)
constants = TerrainNone = 0 and TerrainGrass = 1 and TerrainRoad = 2
constants = constants and TerrainRock = 3 and TerrainTrees = 4
constants = constants and TerrainMarsh = 5 and TerrainWall = 6
constants = constants and TerrainWater = 7
constants = constants and GroundLayer = 0 and RedFortLayer = 1
constants = constants and BlueFortLayer = 2 and WaterLayer = 3
enemyObjects = 0
i = 0
while i < objectCount()
  if objectTeam(i) <> selfTeam then
    enemyObjects = enemyObjects + 1
  end if
  i = i + 1
wend
""")
  game.loadBots([BotGroup(path: path, count: 10)])
  for hero in game.world.heroes:
    hero.navLayer = GroundLayer
  for team in 0 .. 1:
    for cell in game.world.teamVisible[team].mitems:
      cell = 0
  game.runBotDecisions()
  for vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
    doAssert vm.runtime.getGlobal("width") == 128
    doAssert vm.runtime.getGlobal("height") == 128
    doAssert vm.runtime.getGlobal("layerCount") == 4
    doAssert vm.runtime.getGlobal("myLayer") == GroundLayer
    doAssert vm.runtime.getGlobal("kind") == TerrainWall.ord
    doAssert vm.runtime.getGlobal("walkable") == 0
    doAssert vm.runtime.getGlobal("depth") == 0
    doAssert vm.runtime.getGlobal("bedKind") == TerrainMarsh.ord
    doAssert vm.runtime.getGlobal("bedWalkable") == 1
    doAssert vm.runtime.getGlobal("bedHeight") == -14
    doAssert vm.runtime.getGlobal("bedDepth") == 1
    doAssert vm.runtime.getGlobal("waterKind") == TerrainWater.ord
    doAssert vm.runtime.getGlobal("waterWalkable") == 0
    doAssert vm.runtime.getGlobal("waterHeight") == -13
    doAssert vm.runtime.getGlobal("waterDepth") == 1
    doAssert vm.runtime.getGlobal("enemyWall") == TerrainWall.ord
    doAssert vm.runtime.getGlobal("noneKind") == 0
    doAssert vm.runtime.getGlobal("badKind") == 0
    doAssert vm.runtime.getGlobal("badLayer") == 0
    doAssert vm.runtime.getGlobal("constants") != 0
    doAssert vm.runtime.getGlobal("enemyObjects") == 0,
      "Static map queries must not bypass the object visibility filter."
  let
    before = game.stateHash()
    hero = game.world.heroes[0]
    vm = game.heroVms[0]
    groundHeight = vm.runtime.getGlobal("elevation")
  for field in TerrainField:
    for y in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        discard terrain(field, x, y)
  doAssert game.stateHash() == before,
    "Reading terrain must not change the simulation or consume randomness."
  hero.navLayer = RedFortLayer
  game.runBotDecisions()
  doAssert not vm.failed, vm.lastError
  doAssert vm.runtime.getGlobal("myLayer") == RedFortLayer
  doAssert vm.runtime.getGlobal("walkable") == 1
  doAssert vm.runtime.getGlobal("elevation") == groundHeight + 36
  doAssert vm.runtime.getGlobal("depth") == 0
  doAssert vm.runtime.getGlobal("bedDepth") == 1,
    "An explicit layer query must ignore the hero's new standing layer."

echo "Testing terrain queries through real BASIC bots without revealing enemies"
checkBasicTerrain()
echo "GOTA terrain queries passed"
