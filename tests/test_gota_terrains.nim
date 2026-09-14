## Checks generated terrain and its real BASIC host interface.

import
  std/[os, strformat, tempfiles],
  polyworld/[basic, cli, pathing],
  ../examples/gods_of_the_arena/[bots, maps, replays, sim, terrains]

proc terrain(field: TerrainField, x, y: int, layer = GroundLayer): int32 =
  ## Reads one field using convenient test coordinates.
  terrainValue(x.int32, y.int32, layer.int32, field)

echo "Testing grass, forests, rivers, and walls on generated maps"
for seed in [1988'i32, 2026'i32]:
  let map = generateMap(seed)
  var seen: set[TerrainKind]
  for y in 0 ..< map.resolution:
    for x in 0 ..< map.resolution:
      let kind = TerrainKind(terrain(TerrainKindField, x, y))
      seen.incl kind
      doAssert terrain(TerrainWalkableField, x, y) ==
        int32(isWalkable(GroundLayer, x, y))
      if kind in {TerrainTrees, TerrainWall}:
        doAssert terrain(TerrainWalkableField, x, y) == 0
      if kind == TerrainMarsh:
        doAssert terrain(TerrainWaterDepthField, x, y) in 0 .. ArenaWaterDepth
        doAssert terrain(TerrainKindField, x, y, WaterLayer) == TerrainWater.ord
        doAssert terrain(TerrainWalkableField, x, y, WaterLayer) == 0
  doAssert {TerrainGrass, TerrainRoad, TerrainTrees, TerrainRock,
    TerrainMarsh, TerrainWall} <= seen
  doAssert TerrainNone notin seen

echo "Testing invalid coordinates, missing layers, and absent surfaces"
for field in TerrainField:
  for coordinate in [int32.low, -1'i32, mapTiles().int32, int32.high]:
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
      originX: 7 + mapOrigin(), originZ: 9 + mapOrigin(), width: 2, depth: 1,
      tiles: @[
        Tile(flags: TileExists, kind: MarshTile, tops: [-16'i16, -15, -15, -15]),
        Tile(flags: TileExists, kind: RockTile, tops: [0'i16, 0, 32, 32])
      ]
    ),
    QuadLayer(
      originX: 7 + mapOrigin(), originZ: 9 + mapOrigin(), width: 1, depth: 1, slab: true,
      tiles: @[
        Tile(flags: TileExists, kind: StoneTile, tops: [8'i16, 8, 8, 8])
      ]
    ),
    QuadLayer(
      originX: 7 + mapOrigin(), originZ: 9 + mapOrigin(), width: 1, depth: 1, water: true,
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
    game = newGame(generateMap(1988), 240, 10, false, ReplayData())
  defer:
    removeDir(directory)
  var
    wallX = -1
    wallY = -1
    lakeX = -1
    lakeY = -1
  for y in 0 ..< mapTiles():
    for x in 0 ..< mapTiles():
      case TerrainKind(terrain(TerrainKindField, x, y))
      of TerrainWall:
        wallX = x
        wallY = y
      of TerrainMarsh:
        if terrain(TerrainWaterDepthField, x, y) == ArenaWaterDepth and
          terrain(TerrainWalkableField, x, y) == 1:
            lakeX = x
            lakeY = y
      else:
        discard
  doAssert wallX >= 0 and lakeX >= 0
  writeFile(path, &"""
width = mapWidth
height = mapHeight
layerCount = mapLayers
myLayer = selfLayer
kind = terrainKind({wallX}, {wallY})
walkable = terrainWalkable({wallX}, {wallY})
elevation = terrainHeight({wallX}, {wallY})
depth = terrainWaterDepth({wallX}, {wallY})
bedKind = terrainKindAt({lakeX}, {lakeY}, GroundLayer)
bedWalkable = terrainWalkableAt({lakeX}, {lakeY}, GroundLayer)
bedHeight = terrainHeightAt({lakeX}, {lakeY}, GroundLayer)
bedDepth = terrainWaterDepthAt({lakeX}, {lakeY}, GroundLayer)
waterKind = terrainKindAt({lakeX}, {lakeY}, WaterLayer)
waterWalkable = terrainWalkableAt({lakeX}, {lakeY}, WaterLayer)
waterHeight = terrainHeightAt({lakeX}, {lakeY}, WaterLayer)
waterDepth = terrainWaterDepthAt({lakeX}, {lakeY}, WaterLayer)
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
    doAssert vm.runtime.getGlobal("width") == mapTiles().int32
    doAssert vm.runtime.getGlobal("height") == mapTiles().int32
    doAssert vm.runtime.getGlobal("layerCount") == 4
    doAssert vm.runtime.getGlobal("myLayer") == GroundLayer
    doAssert vm.runtime.getGlobal("kind") == TerrainWall.ord
    doAssert vm.runtime.getGlobal("walkable") == 0
    doAssert vm.runtime.getGlobal("depth") == 0
    doAssert vm.runtime.getGlobal("bedKind") == TerrainMarsh.ord
    doAssert vm.runtime.getGlobal("bedWalkable") == 1
    doAssert vm.runtime.getGlobal("bedHeight") ==
      terrain(TerrainHeightField, lakeX, lakeY)
    doAssert vm.runtime.getGlobal("bedDepth") == ArenaWaterDepth
    doAssert vm.runtime.getGlobal("waterKind") == TerrainWater.ord
    doAssert vm.runtime.getGlobal("waterWalkable") == 0
    doAssert vm.runtime.getGlobal("waterHeight") ==
      terrain(TerrainHeightField, lakeX, lakeY, WaterLayer)
    doAssert vm.runtime.getGlobal("waterDepth") == ArenaWaterDepth
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
  for field in TerrainField:
    for y in 0 ..< mapTiles():
      for x in 0 ..< mapTiles():
        discard terrain(field, x, y)
  doAssert game.stateHash() == before,
    "Reading terrain must not change the simulation or consume randomness."
  hero.navLayer = RedFortLayer
  game.runBotDecisions()
  doAssert not vm.failed, vm.lastError
  doAssert vm.runtime.getGlobal("myLayer") == RedFortLayer
  doAssert vm.runtime.getGlobal("walkable") == 0
  doAssert vm.runtime.getGlobal("kind") == TerrainNone.ord
  doAssert vm.runtime.getGlobal("elevation") == 0
  doAssert vm.runtime.getGlobal("depth") == 0
  doAssert vm.runtime.getGlobal("bedDepth") == ArenaWaterDepth,
    "An explicit layer query must ignore the hero's new standing layer."

echo "Testing terrain queries through real BASIC bots without revealing enemies"
checkBasicTerrain()
echo "GOTA terrain queries passed"
