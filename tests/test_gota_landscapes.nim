import
  polyworld/[pathing, terrainmaps, terrainreliefs, terrainsurfaces],
  ../examples/gods_of_the_arena/[arenas, landscapes]

echo "Testing GotA natural relief and road materials"
let
  arena = buildArena(defaultConfig())
  ground = arena.layers[0]
  before = ground.tiles
  landscape = buildLandscape(ground, arena.mainRoads, 54, 2, 3)
doAssert landscape == buildLandscape(ground, arena.mainRoads, 54, 2, 3)
doAssert landscape.relief !=
  buildLandscape(ground, arena.mainRoads, 55, 2, 3).relief
doAssert ground.tiles == before
var
  displaced, mainRoads, trails, mainRamps, trailRamps: int
  minimum, maximum: float32
for i, tile in ground.tiles:
  doAssert arena.mainRoads[i] == arena.mainRoads[ground.tiles.high - i]
  let
    x = i mod ground.width
    z = i div ground.width
    offsets = landscape.relief[i]
    category = arenaKind(tile.kind)
  for corner, offset in offsets:
    doAssert abs(offset) <= 0.2'f
    doAssert abs(offset -
      landscape.relief[ground.tiles.high - i][3 - corner]) < 0.00001'f,
      "Relief must retain rotational symmetry."
    minimum = min(minimum, offset)
    maximum = max(maximum, offset)
    if category notin [GrassTile, TreeTile, RockTile] and
      tile.kind notin ArenaWallKinds:
        doAssert offset == 0, "Roads, ramps, water, and buildings stay level."
    if abs(offset) > 0.01'f:
      inc displaced
  if x + 1 < ground.width:
    doAssert offsets[1] == landscape.relief[i + 1][0]
    doAssert offsets[3] == landscape.relief[i + 1][2]
  if z + 1 < ground.depth:
    doAssert offsets[2] == landscape.relief[i + ground.width][0]
    doAssert offsets[3] == landscape.relief[i + ground.width][1]
  let center = reliefHeight(
    landscape.relief,
    ground,
    (ground.originX + x).float32 - HalfGrid + 0.5'f,
    (ground.originZ + z).float32 - HalfGrid + 0.5'f
  )
  doAssert abs(center - (offsets[1] + offsets[2]) / 2) < 0.00001'f,
    "Brush and units must follow the rendered triangle height."
  if tile.kind >= ArenaKindBase + ArenaKindStride and
    tile.kind < ArenaRockKind and category == RoadTile:
      if arena.mainRoads[i]:
        doAssert landscape.materials[i] == 2
        inc mainRoads
        mainRamps += int(tile.kind == ArenaRockKind - 1)
      else:
        doAssert landscape.materials[i] == 3
        inc trails
        trailRamps += int(tile.kind == ArenaRockKind - 1)
  else:
    doAssert landscape.materials[i] == -1
doAssert displaced > 1000 and minimum < -0.1'f and maximum > 0.1'f
doAssert mainRoads > 0 and trails > 0
doAssert mainRamps > 0 and trailRamps > 0

echo "Testing ground material overrides reach terrain blending"
var materials = newSeq[int](ArenaRockKind.int + 1)
for material in materials.mitems:
  material = ForestSurface
let painting = buildTerrainMap(
  arena.layers,
  materials,
  54,
  count = 0,
  groundMaterials = landscape.materials
)
for i, override in landscape.materials:
  doAssert painting.layers[0].materials[i] ==
    (if override >= 0: override else: ForestSurface)
doAssert ground.tiles == before
echo "Relief range: ", minimum, " to ", maximum, " tiles."
echo "Dark lanes: ", mainRoads, ", smaller roads: ", trails,
  ", lane ramps: ", mainRamps, ", smaller ramps: ", trailRamps, "."
