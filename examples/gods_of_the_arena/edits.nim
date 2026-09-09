import
  polyworld/[noises, pathing],
  maps

const
  ElevationHeights* = [-8'i16, 0, 8, 16, 24]
  MaximumUndoSteps* = 64

type
  MapBrush* = enum
    ElevationBrush, SurfaceBrush, WaterBrush, DryBrush,
    TreeBrush, ClearBrush, BlockBrush, OpenBrush, RampBrush, PathBrush,
    SmoothBrush, WallBrush, EraseWallBrush, BuildingBrush, EraseBuildingBrush,
    SelectBuildingBrush
  TileChange = object
    layer, index: int
    before, after: Tile
  MapEdit = object
    changes: seq[TileChange]
    beforeBuildings, afterBuildings: seq[MapBuilding]
  EditHistory* = object
    edits: seq[MapEdit]
    cursor: int
    pending: MapEdit
    touched: seq[bool]
    active*: bool

proc editableTile*(x, z: int): bool {.raises: [].} =
  ## Keeps terrain edits inside the map and outside the fixed base platforms.
  if x < 0 or z < 0 or x >= GridTiles or z >= GridTiles:
    return false
  if layers.len > WallLayer and
    layers[WallLayer].tiles[z * GridTiles + x].exists:
      return false
  for fort in [RedFortTile, BlueFortTile]:
    if max(abs(x - fort), abs(z - fort)) <= 16:
      return false
  true

proc beginEdit*(history: var EditHistory) =
  ## Starts one undoable brush stroke and remembers each changed tile once.
  doAssert not history.active
  history.pending = MapEdit()
  ensureWallLayer()
  for building in mapBuildings:
    history.pending.beforeBuildings.add building
  history.touched = newSeq[bool](GridTiles * GridTiles * layers.len)
  history.active = true

proc replaceTile(history: var EditHistory, layer, index: int, tile: Tile) =
  ## Records the original tile before applying an authored change.
  doAssert history.active
  if layers[layer].tiles[index] == tile:
    return
  let key = layer * GridTiles * GridTiles + index
  if not history.touched[key]:
    history.pending.changes.add TileChange(
      layer: layer, index: index, before: layers[layer].tiles[index]
    )
    history.touched[key] = true
  layers[layer].tiles[index] = tile

proc commitEdit*(history: var EditHistory): bool =
  ## Finishes one stroke and bounds the undo history to 64 actions.
  if not history.active:
    return false
  history.active = false
  var changes: seq[TileChange]
  for change in history.pending.changes.mitems:
    change.after = layers[change.layer].tiles[change.index]
    if change.before != change.after:
      changes.add change
  for building in mapBuildings:
    history.pending.afterBuildings.add building
  let completed = MapEdit(
    changes: changes,
    beforeBuildings: history.pending.beforeBuildings,
    afterBuildings: history.pending.afterBuildings
  )
  history.pending = MapEdit()
  history.touched.setLen(0)
  if changes.len == 0 and completed.beforeBuildings == completed.afterBuildings:
    return false
  history.edits.setLen(history.cursor)
  history.edits.add completed
  if history.edits.len > MaximumUndoSteps:
    history.edits.delete(0)
  history.cursor = history.edits.len
  true

proc cancelEdit*(history: var EditHistory): bool =
  ## Restores every tile in an unfinished stroke.
  if not history.active:
    return false
  for change in history.pending.changes:
    layers[change.layer].tiles[change.index] = change.before
  result = history.pending.changes.len > 0 or
    mapBuildings != history.pending.beforeBuildings
  mapBuildings = history.pending.beforeBuildings
  history.active = false
  history.pending = MapEdit()
  history.touched.setLen(0)

proc undo*(history: var EditHistory): bool =
  ## Restores the terrain and water from the previous completed stroke.
  doAssert not history.active
  if history.cursor == 0:
    return false
  dec history.cursor
  for change in history.edits[history.cursor].changes:
    layers[change.layer].tiles[change.index] = change.before
  mapBuildings = history.edits[history.cursor].beforeBuildings
  true

proc redo*(history: var EditHistory): bool =
  ## Reapplies a stroke unless a new edit replaced that future history.
  doAssert not history.active
  if history.cursor == history.edits.len:
    return false
  for change in history.edits[history.cursor].changes:
    layers[change.layer].tiles[change.index] = change.after
  mapBuildings = history.edits[history.cursor].afterBuildings
  inc history.cursor
  true

proc paintTile(
  history: var EditHistory,
  x, z: int,
  brush: MapBrush,
  height: int16,
  surface: uint32
) =
  ## Applies one terrain tool while keeping water and tree collision explicit.
  if not editableTile(x, z):
    return
  let index = z * GridTiles + x
  var
    tile = layers[GroundLayer].tiles[index]
    water = layers[WaterLayer].tiles[index]
  case brush
  of ElevationBrush:
    tile.tops = [height, height, height, height]
    water = Tile()
  of SurfaceBrush:
    if tile.kind == TreeTile:
      tile.impassable = false
    tile.kind = surface
  of WaterBrush:
    let waterHeight = height + WaterDepthSteps.int16
    tile.tops = [height, height, height, height]
    tile.kind = MarshTile
    tile.impassable = false
    water = Tile(
      flags: TileExists,
      tops: [waterHeight, waterHeight, waterHeight, waterHeight],
      bottoms: tile.tops
    )
  of DryBrush:
    water = Tile()
    if tile.kind == MarshTile:
      tile.kind = GrassTile
  of TreeBrush:
    tile.kind = TreeTile
    tile.impassable = true
    water = Tile()
  of ClearBrush:
    if tile.kind == TreeTile:
      tile.kind = GrassTile
      tile.impassable = false
  of BlockBrush:
    tile.impassable = true
  of OpenBrush:
    tile.impassable = false
    if tile.kind == TreeTile:
      tile.kind = GrassTile
  of RampBrush, PathBrush, SmoothBrush, WallBrush, EraseWallBrush,
    BuildingBrush, EraseBuildingBrush, SelectBuildingBrush:
    return
  history.replaceTile(GroundLayer, index, tile)
  history.replaceTile(WaterLayer, index, water)

proc paintBrush*(
  history: var EditHistory,
  x, z, radius: int,
  brush: MapBrush,
  level = 1,
  surface = GrassTile
) =
  ## Paints a circular brush using discrete elevation levels and tile kinds.
  doAssert level in 0 .. 4 and radius in 0 .. 12
  doAssert surface <= StoneTile
  for dz in -radius .. radius:
    for dx in -radius .. radius:
      if dx * dx + dz * dz <= radius * radius:
        history.paintTile(
          x + dx, z + dz, brush, ElevationHeights[level], surface
        )

proc paintStroke*(
  history: var EditHistory,
  fromX, fromZ, toX, toZ, radius: int,
  brush: MapBrush,
  level = 1,
  surface = GrassTile
) =
  ## Fills gaps between pointer samples so quick strokes remain continuous.
  let count = max(abs(toX - fromX), abs(toZ - fromZ))
  for i in 0 .. count:
    history.paintBrush(
      fromX + (toX - fromX) * i div max(count, 1),
      fromZ + (toZ - fromZ) * i div max(count, 1),
      radius, brush, level, surface
    )

proc rampBounds*(
  fromX, fromZ, toX, toZ, radius: int
): tuple[x0, z0, x1, z1: int, horizontal: bool] =
  ## Snaps a dragged ramp to its dominant axis and chosen odd tile width.
  result.horizontal = abs(toX - fromX) >= abs(toZ - fromZ)
  if result.horizontal:
    result.x0 = min(fromX, toX)
    result.x1 = max(fromX, toX)
    result.z0 = fromZ - radius
    result.z1 = fromZ + radius
  else:
    result.x0 = fromX - radius
    result.x1 = fromX + radius
    result.z0 = min(fromZ, toZ)
    result.z1 = max(fromZ, toZ)

proc paintRamp*(
  history: var EditHistory,
  fromX, fromZ, toX, toZ, radius: int
): bool =
  ## Joins flat endpoint terraces with a walkable axis-aligned ramp.
  doAssert radius in 0 .. 12
  let bounds = rampBounds(fromX, fromZ, toX, toZ, radius)
  for z in bounds.z0 .. bounds.z1:
    for x in bounds.x0 .. bounds.x1:
      if not editableTile(x, z):
        return false
  let
    first = layers[GroundLayer].tiles[bounds.z0 * GridTiles + bounds.x0]
    last = layers[GroundLayer].tiles[bounds.z1 * GridTiles + bounds.x1]
    length =
      if bounds.horizontal: bounds.x1 - bounds.x0 + 1
      else: bounds.z1 - bounds.z0 + 1
    startHeight = first.tops[0].int
    endHeight = last.tops[3].int
  if length < 2 or startHeight == endHeight:
    return false
  if abs(endHeight - startHeight) > length * 8:
    return false
  for z in bounds.z0 .. bounds.z1:
    for x in bounds.x0 .. bounds.x1:
      let index = z * GridTiles + x
      var tile = layers[GroundLayer].tiles[index]
      tile.kind = RoadTile
      tile.impassable = false
      tile.connectedEast = true
      tile.connectedSouth = true
      for corner in 0 .. 3:
        let offset =
          if bounds.horizontal: x - bounds.x0 + (corner and 1)
          else: z - bounds.z0 + (corner shr 1)
        tile.tops[corner] = int16(startHeight + roundDivision(
          int64(endHeight - startHeight) * offset, length
        ))
      history.replaceTile(GroundLayer, index, tile)
      history.replaceTile(WaterLayer, index, Tile())
  true

proc smoothTerrain*(history: var EditHistory, x, z, radius: int) =
  ## Blends shared vertices from an immutable height snapshot without cracks.
  doAssert radius in 0 .. 12
  const VertexWidth = GridTiles + 1
  var
    heights: array[VertexWidth * VertexWidth, int]
    counts: array[VertexWidth * VertexWidth, int]
  for tileZ in 0 ..< GridTiles:
    for tileX in 0 ..< GridTiles:
      let tile = layers[GroundLayer].tiles[tileZ * GridTiles + tileX]
      for corner in 0 .. 3:
        let index = (tileZ + (corner shr 1)) * VertexWidth +
          tileX + (corner and 1)
        heights[index] += tile.tops[corner].int
        inc counts[index]
  for i in 0 ..< heights.len:
    heights[i] = int(roundDivision(heights[i], counts[i]))
  for vertexZ in max(0, z - radius) .. min(GridTiles, z + radius + 1):
    for vertexX in max(0, x - radius) .. min(GridTiles, x + radius + 1):
      let
        dx = vertexX * 2 - (x * 2 + 1)
        dz = vertexZ * 2 - (z * 2 + 1)
      if dx * dx + dz * dz > (radius * 2 + 2) * (radius * 2 + 2):
        continue
      var
        allowed = true
        waterCeiling = 512
        total, count: int
      for corner in 0 .. 3:
        let
          tileX = vertexX - (corner and 1)
          tileZ = vertexZ - (corner shr 1)
        if tileX notin 0 ..< GridTiles or tileZ notin 0 ..< GridTiles:
          continue
        if not editableTile(tileX, tileZ):
          allowed = false
        let index = tileZ * GridTiles + tileX
        if layers[WallLayer].tiles[index].exists:
          allowed = false
        let water = layers[WaterLayer].tiles[index]
        if water.exists:
          waterCeiling = min(waterCeiling, water.tops[corner].int)
      if not allowed:
        continue
      for sampleZ in max(0, vertexZ - 1) .. min(GridTiles, vertexZ + 1):
        for sampleX in max(0, vertexX - 1) .. min(GridTiles, vertexX + 1):
          total += heights[sampleZ * VertexWidth + sampleX]
          inc count
      let
        old = heights[vertexZ * VertexWidth + vertexX]
        height = min(waterCeiling, int(roundDivision(
          int64(old * count + total), count * 2
        ))).int16
      for corner in 0 .. 3:
        let
          tileX = vertexX - (corner and 1)
          tileZ = vertexZ - (corner shr 1)
        if tileX notin 0 ..< GridTiles or tileZ notin 0 ..< GridTiles:
          continue
        let index = tileZ * GridTiles + tileX
        var
          tile = layers[GroundLayer].tiles[index]
          water = layers[WaterLayer].tiles[index]
        tile.tops[corner] = height
        history.replaceTile(GroundLayer, index, tile)
        if water.exists:
          water.bottoms[corner] = height
          history.replaceTile(WaterLayer, index, water)

proc scaleHeights*(
  history: var EditHistory, numerator, denominator: int
): bool =
  ## Rescales all terrain and slab heights together as one reversible action.
  doAssert numerator in 1 .. 2 and denominator in 1 .. 2
  for layer in layers:
    for tile in layer.tiles:
      for height in tile.tops:
        if abs(height.int * numerator div denominator) > 512:
          return false
      for height in tile.bottoms:
        if abs(height.int * numerator div denominator) > 512:
          return false
  for layerIndex, layer in layers:
    for index, original in layer.tiles:
      var tile = original
      for corner in 0 .. 3:
        tile.tops[corner] = roundDivision(
          tile.tops[corner].int64 * numerator, denominator
        ).int16
        tile.bottoms[corner] = roundDivision(
          tile.bottoms[corner].int64 * numerator, denominator
        ).int16
      history.replaceTile(layerIndex, index, tile)
  true

proc paintWall*(
  history: var EditHistory,
  x, z, radius, height, team: int,
  erase = false
) =
  ## Paints independent solid masonry or erases it without changing the ground.
  doAssert radius in 0 .. 2 and height in 1 .. 64 and team in 0 .. 1
  for tileZ in max(0, z - radius) .. min(GridTiles - 1, z + radius):
    for tileX in max(0, x - radius) .. min(GridTiles - 1, x + radius):
      let index = tileZ * GridTiles + tileX
      var wall: Tile
      if not erase:
        let base = layers[GroundLayer].tiles[index].tops
        let top = min(512, max(base).int + height).int16
        wall = Tile(
          flags: TileExists or TileImpassable or
            TileConnectedEast or TileConnectedSouth,
          kind: (RedFortKind.int + team).uint32,
          tops: [top, top, top, top], bottoms: base
        )
      history.replaceTile(WallLayer, index, wall)

proc paintWallStroke*(
  history: var EditHistory,
  fromX, fromZ, toX, toZ, radius, height, team: int,
  erase = false
) =
  ## Fills a continuous wall with cardinal joins even along diagonal strokes.
  let count = max(abs(toX - fromX), abs(toZ - fromZ))
  var previousX = fromX
  for i in 0 .. count:
    let
      x = fromX + (toX - fromX) * i div max(count, 1)
      z = fromZ + (toZ - fromZ) * i div max(count, 1)
    history.paintWall(previousX, z, radius, height, team, erase)
    history.paintWall(x, z, radius, height, team, erase)
    previousX = x

proc sameRole*(a, b: MapBuilding): bool =
  ## Matches the team's unique god, lane barracks, or lane tower tier.
  a.kind == b.kind and a.team == b.team and
    (a.kind == GodBuilding or a.lane == b.lane) and
    (a.kind != TowerBuilding or a.tier == b.tier)

proc placeBuilding*(history: var EditHistory, building: MapBuilding) =
  ## Moves an existing building role or places it if that role is absent.
  doAssert history.active and authoredBuildings
  for i, existing in mapBuildings:
    if existing.sameRole(building):
      mapBuildings[i] = building
      return
  mapBuildings.add building

proc removeBuilding*(history: var EditHistory, index: int) =
  ## Removes a selected structure while preserving undo and draft validation.
  doAssert history.active
  if index in 0 ..< mapBuildings.len:
    mapBuildings.delete(index)
