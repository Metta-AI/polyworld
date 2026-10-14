## Terrain geometry for rendering, with navigation supplied by Pathy.
## Layered integer grids share cliffs, ramps, blockers, and line checks.

import
  std/math,
  pathy/terrains,
  vmath,
  profiles

const
  GridTiles* = 128
  HalfGrid* = GridTiles.float32 / 2.0
  HeightSteps* = 8.0'f  # Heights quantize to eighths of a tile.
  PathUnitsPerTile* = 32'i32

proc pack*(values: array[4, float32]): array[4, int16] =
  ## Quantizes four world-space heights into compact height steps.
  for i in 0 .. 3:
    result[i] = int16(round(values[i] * HeightSteps))

proc unpack*(steps: array[4, int16]): array[4, float32] =
  ## Expands four compact height steps into world-space heights.
  for i in 0 .. 3:
    result[i] = steps[i].float32 / HeightSteps

const
  TileExists* = 1'u32
  TileConnectedEast* = 2'u32   # edge to (x+1, z); clear means a break
  TileConnectedSouth* = 4'u32  # edge to (x, z+1)
  TileImpassable* = 8'u32      # forced, e.g. ground squeezed under a bridge

  GrassTile* = 0'u32
  RoadTile* = 1'u32   # also the fort interior
  RockTile* = 2'u32   # natural rocky ground; boulders scatter here
  MarshTile* = 3'u32
  StoneTile* = 4'u32  # stone construction (bridge, fort walls); no boulders
  TreeTile* = 5'u32   # renders like grass; the tile itself carries a tree

type
  Tile* = object
    ## 24 bytes: corner heights in 1/8-tile integer steps, flag bits, and a
    ## game-specific tile kind (0 grass, 1 road, ...).
    tops*: array[4, int16]     # top corners: [x0z0, x1z0, x0z1, x1z1]
    bottoms*: array[4, int16]  # underside corners; only used by slab layers
    flags*: uint32
    kind*: uint32

  QuadLayer* = ref object
    originX*, originZ*: int  # placement in world tile coordinates
    width*, depth*: int
    slab*: bool   # slab layers close their sides and underside down to
                  # bottoms; the ground layer instead skirts to the floor
    water*: bool  # flat transparent surface; never walkable, never connects
                  # to other layers, and renders in its own blended pass
    tiles*: seq[Tile]

  PathingContext = object
    ready: bool
    layers: seq[QuadLayer]
    layerWalkable: seq[seq[bool]]
    space: TerrainSpace

proc setFlag(tile: var Tile, flag: uint32, on: bool) =
  ## Sets or clears one bit in a tile's flags.
  if on:
    tile.flags = tile.flags or flag
  else:
    tile.flags = tile.flags and not flag

proc exists*(tile: Tile): bool =
  ## Returns whether the tile has renderable geometry.
  (tile.flags and TileExists) != 0

proc `exists=`*(tile: var Tile, on: bool) =
  ## Sets whether the tile has renderable geometry.
  tile.setFlag(TileExists, on)

proc connectedEast*(tile: Tile): bool =
  ## Returns whether the tile geometry connects to its eastern neighbor.
  (tile.flags and TileConnectedEast) != 0

proc `connectedEast=`*(tile: var Tile, on: bool) =
  ## Sets whether the tile geometry connects to its eastern neighbor.
  tile.setFlag(TileConnectedEast, on)

proc connectedSouth*(tile: Tile): bool =
  ## Returns whether the tile geometry connects to its southern neighbor.
  (tile.flags and TileConnectedSouth) != 0

proc `connectedSouth=`*(tile: var Tile, on: bool) =
  ## Sets whether the tile geometry connects to its southern neighbor.
  tile.setFlag(TileConnectedSouth, on)

proc impassable*(tile: Tile): bool =
  ## Returns whether gameplay explicitly blocks this tile.
  (tile.flags and TileImpassable) != 0

proc `impassable=`*(tile: var Tile, on: bool) =
  ## Sets whether gameplay explicitly blocks this tile.
  tile.setFlag(TileImpassable, on)

export
  EdgeLink, PathPoint, PathTile, PathNeighbors, PathTieOrder,
  PathWalkable, PathEnterCost, PathClearance, PathQuery, PathSearch,
  PathAcceleration

var
  layers*: seq[QuadLayer]
  layerWalkable*: seq[seq[bool]]
  terrainSpace*: TerrainSpace
  dormantPathingContext: PathingContext

proc computeWalkable*() {.measure.} =
  ## Copies edited terrain into Pathy and rebuilds its navigation topology.
  var terrainLayers = newSeq[TerrainLayer](layers.len)
  for i, layer in layers:
    terrainLayers[i] = TerrainLayer(
      originX: layer.originX, originZ: layer.originZ,
      width: layer.width, depth: layer.depth, water: layer.water,
      tiles: newSeq[TerrainTile](layer.tiles.len)
    )
    for j, tile in layer.tiles:
      terrainLayers[i].tiles[j] = TerrainTile(
        tops: tile.tops, flags: tile.flags
      )
  terrainSpace = newTerrainSpace(terrainLayers)
  layerWalkable = terrainSpace.layerWalkable

proc sameLayers(contextLayers: openArray[QuadLayer]): bool =
  ## Returns whether the installed geometry is the requested immutable map.
  if layers.len != contextLayers.len or
      layerWalkable.len != contextLayers.len:
    return false
  for index, layer in contextLayers:
    if cast[pointer](layers[index]) != cast[pointer](layer):
      return false
  true

proc swapPathingContext(context: var PathingContext) =
  ## Swaps cached maps without rebuilding immutable navigation topology.
  swap(layers, context.layers)
  swap(terrainSpace, context.space)
  swap(layerWalkable, context.layerWalkable)

proc installImmutableLayers*(nextLayers: seq[QuadLayer]) =
  ## Installs immutable geometry while retaining one displaced pathing context.
  ## Games that alternate between two maps avoid rebuilding either topology.
  if sameLayers(nextLayers):
    return
  if dormantPathingContext.ready and
      dormantPathingContext.layers.len == nextLayers.len:
    var matches = true
    for index, layer in nextLayers:
      if cast[pointer](dormantPathingContext.layers[index]) !=
          cast[pointer](layer):
        matches = false
        break
    if matches:
      swapPathingContext(dormantPathingContext)
      return
  dormantPathingContext = PathingContext(ready: true)
  swapPathingContext(dormantPathingContext)
  layers = nextLayers
  computeWalkable()

proc inLayer(layerIndex, x, z: int): bool {.inline.} =
  ## Returns whether a layer-local tile coordinate exists.
  layerIndex >= 0 and layerIndex < layers.len and
    x >= 0 and x < layers[layerIndex].width and
    z >= 0 and z < layers[layerIndex].depth

proc isWalkable*(layerIndex, x, z: int): bool =
  ## Safely queries the cached walkability of a layer-local tile.
  inLayer(layerIndex, x, z) and
    layerWalkable[layerIndex][z * layers[layerIndex].width + x]

proc rayTriangle*(origin, dir, a, b, c: Vec3): float32 =
  ## Ray-triangle intersection distance, or -1 when there is no hit.
  let
    edge1 = b - a
    edge2 = c - a
    p = cross(dir, edge2)
    det = dot(edge1, p)
  if abs(det) < 1e-6:
    return -1
  let
    invDet = 1.0'f32 / det
    tv = origin - a
    u = dot(tv, p) * invDet
  if u < 0 or u > 1:
    return -1
  let
    q = cross(tv, edge1)
    v = dot(dir, q) * invDet
  if v < 0 or u + v > 1:
    return -1
  let distance = dot(edge2, q) * invDet
  if distance > 0: distance else: -1

proc tileTopHit(origin, dir: Vec3, layer: QuadLayer, x, z: int): float32 =
  ## Distance to this tile's top triangles, or -1 when they miss.
  let tile = layer.tiles[z * layer.width + x]
  if not tile.exists:
    return -1
  let
    h = tile.tops.unpack
    x0 = (layer.originX + x).float32 - HalfGrid
    z0 = (layer.originZ + z).float32 - HalfGrid
    v00 = vec3(x0, h[0], z0)
    v10 = vec3(x0 + 1, h[1], z0)
    v01 = vec3(x0, h[2], z0 + 1)
    v11 = vec3(x0 + 1, h[3], z0 + 1)
  result = -1
  for distance in [
    rayTriangle(origin, dir, v00, v10, v01),
    rayTriangle(origin, dir, v10, v11, v01)
  ]:
    if distance > 0 and (result < 0 or distance < result):
      result = distance

proc pickTile*(
    origin, dir: Vec3,
    minLayer = 0,
    maxLayer = -1
): tuple[hit: bool, layer, x, z: int] =
  ## Returns the nearest existing tile top hit by a ray.
  ## Missing tiles do not block, so a shaft hole picks the ramp below.
  if dir.length < 1e-8:
    return
  let
    ray = normalize(dir)
    first = max(minLayer, 0)
    last =
      if maxLayer < 0:
        layers.len - 1
      else:
        min(maxLayer, layers.len - 1)
  var
    best = float32.high
    found = false
    hitLayer, hitX, hitZ = 0
  for li in first .. last:
    let layer = layers[li]
    if layer.water:
      continue
    for z in 0 ..< layer.depth:
      for x in 0 ..< layer.width:
        let distance = tileTopHit(origin, ray, layer, x, z)
        if distance > 0 and distance < best:
          best = distance
          found = true
          hitLayer = li
          hitX = x
          hitZ = z
  if found:
    result = (true, hitLayer, hitX, hitZ)

proc pickWalkableTile*(
    origin, dir: Vec3,
    minLayer = 0,
    maxLayer = -1
): tuple[hit: bool, layer, x, z: int] =
  ## Accepts a picked tile only when its top is walkable.
  result = pickTile(origin, dir, minLayer, maxLayer)
  if result.hit and not isWalkable(result.layer, result.x, result.z):
    result = default(typeof(result))

proc worldWalkable*(layerIndex, worldX, worldZ: int): bool =
  ## Walkability at a world tile, converted into that layer's local grid.
  if layerIndex < 0 or layerIndex >= layers.len:
    return false
  isWalkable(
    layerIndex,
    worldX - layers[layerIndex].originX,
    worldZ - layers[layerIndex].originZ
  )

proc layersOpen*(current, dest, x, z: int): bool =
  ## True when this cell is standable on the current layer, or on dest
  ## when the two layers differ. Some other overlapping layer is ignored,
  ## so a bridge deck does not fall through to the ground under it.
  isWalkable(current, x, z) or
    (dest != current and isWalkable(dest, x, z))

proc worldLayersOpen*(current, dest, worldX, worldZ: int): bool =
  ## `layersOpen` in world tile coordinates.
  worldWalkable(current, worldX, worldZ) or
    (dest != current and worldWalkable(dest, worldX, worldZ))

proc preferLayer*(current, dest, x, z: int): int =
  ## Stays on the current layer while that cell is walkable. Switches
  ## only when the current layer has no tile here and dest does.
  if isWalkable(current, x, z):
    current
  elif dest != current and isWalkable(dest, x, z):
    dest
  else:
    current

proc worldPreferLayer*(current, dest, worldX, worldZ: int): int =
  ## `preferLayer` in world tile coordinates.
  if worldWalkable(current, worldX, worldZ):
    current
  elif dest != current and worldWalkable(dest, worldX, worldZ):
    dest
  else:
    current

## Edge links

proc edgeLink*(layerIndex, x, z, direction: int): EdgeLink =
  ## Returns Pathy's cached connection, including cross-layer ramps.
  terrainSpace.edgeLink(layerIndex, x, z, direction)

proc edgeMask*(
    layerIndex, x, z: int,
    blockers: openArray[seq[int32]] = [],
    walkable: PathWalkable = nil
): uint8 =
  ## Returns terrain edge bits restricted by the same runtime occupancy.
  terrainSpace.edgeMask(layerIndex, x, z, blockers, walkable)

proc tileCenter*(layerIndex, x, z: int): Vec3 =
  ## Converts one exact tile center for presentation code.
  let
    layer = layers[layerIndex]
    h = layer.tiles[z * layer.width + x].tops.unpack
  vec3(
    (layer.originX + x).float32 - HalfGrid + 0.5,
    (h[0] + h[1] + h[2] + h[3]) / 4.0,
    (layer.originZ + z).float32 - HalfGrid + 0.5
  )

proc tileTop*(layer: QuadLayer; x, z: int): int32 =
  ## Samples the supplied layer without installing it as global pathing state.
  ## Mean height of a tile's four top corners, in the same 1/8-tile integer
  ## steps that `Tile.tops` stores. Integer throughout, so a simulation can
  ## price a ramp step without ever touching `unpack` and its float32.
  ## Division floors toward negative infinity so the result is stable for
  ## tiles below y = 0 rather than biased toward zero.
  let
    tops = layer.tiles[z * layer.width + x].tops
    total = int32(tops[0]) + int32(tops[1]) + int32(tops[2]) + int32(tops[3])
  if total >= 0:
    total div 4
  else:
    -((-total + 3) div 4)

proc tileTop*(layerIndex, x, z: int): int32 =
  ## Samples an installed layer with the same integer rounding.
  layers[layerIndex].tileTop(x, z)

proc pathPoint*(layerIndex, x, z: int): PathPoint =
  ## Returns one exact integer tile center for authoritative game setup.
  result = terrainSpace.pathPoint(layerIndex, x, z)
  result.x -= int32(GridTiles div 2) * PathUnitsPerTile
  result.z -= int32(GridTiles div 2) * PathUnitsPerTile

proc worldToTile*(worldX, worldZ: float32): (int, int) =
  ## World position to ground-layer tile coordinates (unclamped).
  (int(floor(worldX + HalfGrid)), int(floor(worldZ + HalfGrid)))

proc triangleHeight(tile: Tile, offsetX, offsetZ: float32): float32 =
  ## Samples the same v00-v10-v01 / v10-v11-v01 triangles emitted by the
  ## terrain renderer. Bilinear interpolation can visibly bury props on a
  ## non-planar tile because it describes a different surface.
  let h = tile.tops.unpack
  if offsetX + offsetZ <= 1:
    h[0] + (h[1] - h[0]) * offsetX + (h[2] - h[0]) * offsetZ
  else:
    h[1] * (1 - offsetZ) + h[2] * (1 - offsetX) +
      h[3] * (offsetX + offsetZ - 1)

proc layerHeight(
    layerIndex: int, worldX, worldZ: float32, height: var float32
): bool =
  ## Samples one layer's top surface; false when no tile exists there.
  let
    layer = layers[layerIndex]
    tileX = int(floor(worldX + HalfGrid)) - layer.originX
    tileZ = int(floor(worldZ + HalfGrid)) - layer.originZ
  if tileX < 0 or tileX >= layer.width or tileZ < 0 or tileZ >= layer.depth:
    return false
  let tile = layer.tiles[tileZ * layer.width + tileX]
  if not tile.exists:
    return false
  height = tile.triangleHeight(
    worldX + HalfGrid - (layer.originX + tileX).float32,
    worldZ + HalfGrid - (layer.originZ + tileZ).float32
  )
  true

proc groundHeight*(worldX, worldZ: float32): float32 =
  ## Rendered height of the ground layer at a world position.
  discard layerHeight(0, worldX, worldZ, result)

proc surfaceHeight*(worldX, worldZ: float32): float32 =
  ## The topmost solid surface at a world position: the highest non-water
  ## layer with a tile there (a bridge deck wins over the riverbed below).
  var found = false
  for layerIndex in 0 ..< layers.len:
    if layers[layerIndex].water:
      continue
    var height: float32
    if layerHeight(layerIndex, worldX, worldZ, height):
      if not found or height > result:
        result = height
      found = true

proc surfaceHeightNear*(
    worldX, worldZ, referenceY: float32
): float32 =
  ## Returns the solid surface closest to a reference height. This selects
  ## the ground under an overhead gate while still selecting an elevated
  ## bridge or rampart when the caller is already following that surface.
  var
    found = false
    bestDistance = float32.high
  for layerIndex in 0 ..< layers.len:
    if layers[layerIndex].water:
      continue
    var height: float32
    if layerHeight(layerIndex, worldX, worldZ, height):
      let distance = abs(height - referenceY)
      if not found or distance < bestDistance or
        (distance == bestDistance and height > result):
          result = height
          bestDistance = distance
          found = true

proc lineClear*(
    a, b: PathTile,
    start, finish: tuple[x, z: int64],
    unitsPerTile: int64,
    walkable: PathWalkable = nil
): bool =
  ## Checks an exact segment using Pathy's layer and cliff traversal.
  terrainSpace.lineClear(a, b, start, finish, unitsPerTile, walkable)

proc lineClear*(a, b: PathTile, walkable: PathWalkable = nil): bool =
  ## Checks cell centers against terrain seams and dynamic blockers.
  terrainSpace.lineClear(a, b, walkable)

proc fillSmoothPath*(
    tiles: openArray[PathTile],
    start: tuple[x, z: int64],
    unitsPerTile: int64,
    output: var seq[PathTile],
    walkable: PathWalkable = nil,
    clearance: PathClearance = nil
) {.measure.} =
  ## Fills clear shortcuts from an exact origin without allocating per search.
  terrainSpace.fillSmoothPath(
    tiles, start, unitsPerTile, output, walkable, clearance
  )

proc smoothPathTiles*(
    tiles: seq[PathTile], walkable: PathWalkable = nil,
    clearance: PathClearance = nil
): seq[PathTile] {.measure.} =
  ## Fills clear diagonal shortcuts while preserving layer transitions.
  terrainSpace.fillSmoothPath(tiles, result, walkable, clearance)

proc fillTilePath*(
    query: PathQuery, tiles: var seq[PathTile]
): PathSearch {.measure.} =
  ## Searches Pathy with caller-owned output and persistent scratch buffers.
  terrainSpace.fillTilePath(query, tiles)

proc findTilePath*(query: PathQuery): PathSearch =
  ## Finds a route with the requested costs, occupancy, and expansion budget.
  terrainSpace.findTilePath(query)

proc findTilePath*(
    startLayer, startX, startZ, finishLayer, finishX, finishZ: int
): seq[PathTile] =
  ## Returns adjacent edge-linked cells, including cross-layer ramps.
  terrainSpace.findTilePath(
    startLayer, startX, startZ, finishLayer, finishX, finishZ
  )

proc fillPathPoints*(
    startLayer, startX, startZ, finishLayer, finishX, finishZ: int,
    points: var seq[PathPoint],
    neighbors = EdgeNeighbors,
    smooth = false
) {.measure.} =
  ## Fills exact terrain centers through Pathy's reusable search buffers.
  discard terrainSpace.fillPathPoints(PathQuery(
    startLayer: startLayer, startX: startX, startZ: startZ,
    finishLayer: finishLayer, finishX: finishX, finishZ: finishZ,
    neighbors: neighbors
  ), points, smooth)
  for point in points.mitems:
    point.x -= int32(GridTiles div 2) * PathUnitsPerTile
    point.z -= int32(GridTiles div 2) * PathUnitsPerTile

proc findPathPoints*(
    startLayer, startX, startZ, finishLayer, finishX, finishZ: int,
    smooth = false
): seq[PathPoint] =
  ## Returns a route in exact simulation coordinates.
  fillPathPoints(
    startLayer, startX, startZ, finishLayer, finishX, finishZ, result,
    smooth = smooth
  )

proc findPath*(
    startLayer, startX, startZ, finishLayer, finishX, finishZ: int
): seq[Vec3] =
  ## Converts an exact integer path into presentation coordinates.
  for point in findPathPoints(
    startLayer, startX, startZ, finishLayer, finishX, finishZ
  ):
    result.add vec3(
      point.x.float32 / PathUnitsPerTile.float32,
      point.y.float32 / PathUnitsPerTile.float32,
      point.z.float32 / PathUnitsPerTile.float32
    )
