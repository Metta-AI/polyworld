import
  std/[algorithm, math],
  vmath,
  polyworld/pathing
import generation/maps as layouts
import generation/tiles as grids

export layouts.MapConfig, layouts.defaultConfig

const
  ArenaSeed* = layouts.defaultConfig().seed.int32
  ArenaKindBase* = 16'u32
  ArenaKindStride* = 8'u32
  ArenaRockKind* = ArenaKindBase + ArenaKindStride * 2
  ArenaHeightStep = 4'i32
  ArenaWallHeight = 24'i16
  ArenaWaterDepth* = 3'i16

type
  ArenaEdition* = enum
    InitialArena, CryptArena
  ArenaStop* = tuple[layer, x, z: int]
  ArenaSite* = object
    position*, facing*, spawn*: PathPoint
    lane*, team*: int
  ArenaLayout* = object
    lanes*: array[3, seq[ArenaStop]]
    towers*: array[3, array[2, array[3, ArenaSite]]]
    barracks*: seq[ArenaSite]
    forts*, spawns*: array[2, PathPoint]
    camps*: seq[PathPoint]
  ArenaData* = object
    layers*: seq[QuadLayer]
    layout*: ArenaLayout
    minimap*: seq[uint32]

proc arenaKind*(kind: uint32): uint32 {.raises: [].} =
  ## Resolves faction-specific materials to the game's terrain categories.
  if kind == ArenaRockKind:
    return RockTile
  if kind < ArenaKindBase or kind >= ArenaKindBase + ArenaKindStride * 2:
    return kind
  case (kind - ArenaKindBase) mod ArenaKindStride
  of 0, 1:
    GrassTile
  of 2, 3, 4:
    StoneTile
  else:
    RoadTile

proc arenaPoint(point: Vec2): PathPoint {.raises: [].} =
  ## Quantizes editor coordinates into the game's integer path coordinates.
  PathPoint(
    x: int32(round(point.x / layouts.MapSize * GridTiles.float32 *
      PathUnitsPerTile.float32)) - GridTiles div 2 * PathUnitsPerTile,
    z: int32(round(point.y / layouts.MapSize * GridTiles.float32 *
      PathUnitsPerTile.float32)) - GridTiles div 2 * PathUnitsPerTile
  )

proc stop(point: Vec2): ArenaStop {.raises: [].} =
  ## Reads the exact editor tile beneath one lane waypoint.
  (
    0,
    clamp(int(point.x / grids.TileSize), 0, GridTiles - 1),
    clamp(int(point.y / grids.TileSize), 0, GridTiles - 1)
  )

proc makeLayout(map: layouts.MapData): ArenaLayout {.raises: [].} =
  ## Shares lanes, structure positions, and camp clearings with the editor.
  const Lanes = [0, 2, 1]
  for source, lane in Lanes:
    let road = map.roads[source]
    for j in 0 ..< road.len:
      let
        index = (if source == 1: j else: road.high - j)
        point = road[index].stop()
      if result.lanes[lane].len == 0 or result.lanes[lane][^1] != point:
        result.lanes[lane].add(point)
  for team in 0 .. 1:
    result.forts[1 - team] = arenaPoint(map.forts[team])
    var center: Vec2
    for point in map.spawns[team]:
      center += point
    result.spawns[1 - team] = arenaPoint(center / map.spawns[team].len.float32)
  var towers: array[3, array[2, seq[ArenaSite]]]
  for tower in map.towers:
    var
      lane = 0
      distance = float32.high
      facing: Vec2
    for source, road in map.roads:
      let
        nearest = layouts.nearest(road, tower.position)
        candidate = lengthSq(nearest - tower.position)
      if candidate < distance:
        distance = candidate
        lane = Lanes[source]
        facing = nearest
    let team = 1 - tower.team.ord
    towers[lane][team].add(ArenaSite(
      position: arenaPoint(tower.position),
      facing: arenaPoint(facing),
      team: team,
      lane: lane
    ))
  for lane in 0 .. 2:
    for team in 0 .. 1:
      let fort = result.forts[team]
      proc distance(site: ArenaSite): int64 {.raises: [].} =
        ## Orders each team's towers from the outer defense to the gate.
        let
          dx = int64(site.position.x - fort.x)
          dz = int64(site.position.z - fort.z)
        dx * dx + dz * dz
      towers[lane][team].sort(proc(a, b: ArenaSite): int =
        ## Sorts the farther tower first without floating-point distances.
        cmp(distance(b), distance(a))
      )
      doAssert towers[lane][team].len == 3
      for tier in 0 .. 2:
        result.towers[lane][team][tier] = towers[lane][team][tier]
  for barrack in map.barracks:
    result.barracks.add(ArenaSite(
      position: arenaPoint(barrack.position),
      facing: arenaPoint(barrack.route[1]),
      spawn: arenaPoint(barrack.spawn),
      lane: Lanes[barrack.lane],
      team: 1 - barrack.team.ord
    ))
  for camp in map.camps:
    result.camps.add(arenaPoint(camp.position))

proc elevation(tile: grids.Tile): int32 {.raises: [].} =
  ## Converts the editor's terrain levels into compact game height steps.
  case tile.terrain
  of grids.LakeGround:
    -ArenaHeightStep
  of grids.LowGround:
    0
  of grids.HighGround:
    ArenaHeightStep
  of grids.CastleGround, grids.KeepGround, grids.SpawnGround:
    ArenaHeightStep * 2

proc material(tile: grids.Tile): uint32 {.raises: [].} =
  ## Preserves forests, water, walls, and both factions' terrain materials.
  if tile.surface == grids.TreeSurface:
    return TreeTile
  if tile.surface == grids.WallSurface:
    return (if tile.side == layouts.Northeast: 6'u32 else: 7'u32)
  if tile.terrain == grids.LakeGround:
    return MarshTile
  let base = ArenaKindBase + tile.side.ord.uint32 * ArenaKindStride
  if tile.ramp:
    return base + 7
  if tile.surface == grids.RoadSurface:
    return base + 5
  if tile.surface == grids.TrailSurface:
    return base + 6
  base + uint32(tile.terrain.ord)

proc historicalPreset*(edition: ArenaEdition): MapConfig {.raises: [].} =
  ## Restores the controls from recordings that predate stored map presets.
  result = MapConfig(
    seed: 54, lakeCrossings: 4, jungleRoads: 50,
    highSize: 511, castleSize: 295, roadWidth: 62, roadWobble: 73,
    lakeWidth: 80, lakeWobble: 30, campRadius: 36, stemLength: 50,
    campScatter: 35, campsTouchRoads: false
  )
  if edition == InitialArena:
    result.campRadius = 29

proc buildArena*(
    config: MapConfig, edition = CryptArena
): ArenaData =
  ## Converts the saved editor preset into immutable packed game terrain.
  config.validate()
  let
    map = layouts.generateMap(config)
    grid = grids.buildTiles(map)
    count = GridTiles * GridTiles
    heightScale = (if edition == InitialArena: 1'i16 else: 2'i16)
  result.layout = makeLayout(map)
  for color in grid.colors():
    result.minimap.add(color.r.uint32 shl 16 or color.g.uint32 shl 8 or
      color.b.uint32)
  for layer in 0 .. 3:
    result.layers.add(QuadLayer(
      width: GridTiles,
      depth: GridTiles,
      slab: layer != 0,
      water: layer == 3,
      tiles: newSeq[pathing.Tile](count)
    ))
  var
    parents = newSeq[int](count * 4)
    values = newSeq[int32](parents.len)
    sums = newSeq[int32](parents.len)
    weights = newSeq[int32](parents.len)
  for i in 0 ..< parents.len:
    parents[i] = i
    values[i] = elevation(grid.cells[i div 4])
  proc root(index: int): int {.raises: [].} =
    ## Finds the common height sample for connected tile corners.
    result = index
    while parents[result] != result:
      parents[result] = parents[parents[result]]
      result = parents[result]
  proc join(a, b: int) {.raises: [].} =
    ## Shares corner heights only across edges that the editor permits.
    parents[root(b)] = root(a)
  for y in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let
        index = y * GridTiles + x
        tile = grid.cells[index]
        corner = index * 4
      if tile.ramp:
        for ramp in map.ramps:
          let
            direction = normalize(ramp.points[1] - ramp.points[0])
            center = (ramp.points[0] + ramp.points[1]) / 2
            point = vec2(x.float32 + 0.5'f, y.float32 + 0.5'f) * grids.TileSize
            across = abs(dot(point - center, vec2(-direction.y, direction.x)))
            along = abs(dot(point - center, direction))
          if across > ramp.width / 2 + grids.TileSize or
            along > layouts.RampLength / 2 + grids.TileSize:
              continue
          let
            first = elevation(grid.tileAt(ramp.approaches[0]))
            last = elevation(grid.tileAt(ramp.approaches[1]))
          for i in 0 .. 3:
            let
              point = vec2((x + i mod 2).float32,
                (y + i div 2).float32) * grids.TileSize
              fraction = clamp(dot(point - ramp.points[0], direction) /
                length(ramp.points[1] - ramp.points[0]), 0'f, 1'f)
            values[corner + i] = int32(round(
              first.float32 + (last - first).float32 * fraction
            ))
          break
      if x < GridTiles - 1 and tile.edges[grids.East] != grids.CliffEdge:
        join(corner + 1, corner + 4)
        join(corner + 3, corner + 6)
      if y < GridTiles - 1 and tile.edges[grids.South] != grids.CliffEdge:
        join(corner + 2, corner + GridTiles * 4)
        join(corner + 3, corner + GridTiles * 4 + 1)
  for i, value in values:
    let group = root(i)
    sums[group] += value
    weights[group].inc
  var heights = newSeq[int16](parents.len)
  for i in 0 ..< heights.len:
    if weights[i] > 0:
      heights[i] = int16(sums[i] div weights[i]) * heightScale
  if edition != InitialArena:
    # Ease steep approach corners while keeping joined edges at one height.
    var changes = newSeq[int32](heights.len)
    for iteration in 0 ..< 32:
      var steep = false
      for index, tile in grid.cells:
        if not tile.passable:
          continue
        for corners in [[0, 1, 2], [3, 2, 1]]:
          let
            first = root(index * 4 + corners[0])
            second = root(index * 4 + corners[1])
            third = root(index * 4 + corners[2])
            dx = heights[second].int32 - heights[first].int32
            dz = heights[third].int32 - heights[first].int32
          if dx * dx + dz * dz <= 128:
            continue
          steep = true
          let mean = (heights[first].int32 + heights[second].int32 +
            heights[third].int32) div 3
          for corner in [first, second, third]:
            changes[corner] += cmp(mean, heights[corner].int32).int32
      if not steep:
        break
      doAssert iteration < 31, "Arena ramp smoothing did not converge."
      for i in 0 ..< heights.len:
        heights[i] += cmp(changes[i], 0'i32).int16
        changes[i] = 0
  for index, tile in grid.cells:
    var packed = pathing.Tile(flags: TileExists, kind: material(tile))
    if edition != InitialArena and tile.surface == grids.TreeSurface and
      tile.side == layouts.Northeast:
        packed.kind = ArenaRockKind
    packed.impassable = not tile.passable
    packed.connectedEast = tile.edges[grids.East] != grids.CliffEdge
    packed.connectedSouth = tile.edges[grids.South] != grids.CliffEdge
    for i in 0 .. 3:
      let group = root(index * 4 + i)
      packed.tops[i] = heights[group]
    result.layers[0].tiles[index] = packed
    if tile.surface == grids.WallSurface:
      var wall = packed
      wall.bottoms = packed.tops
      for height in wall.tops.mitems:
        height += ArenaWallHeight
      let layer = (if tile.side == layouts.Northeast: 1 else: 2)
      result.layers[layer].tiles[index] = wall
    elif tile.terrain == grids.LakeGround:
      var water = pathing.Tile(flags: TileExists, bottoms: packed.tops)
      for i in 0 .. 3:
        water.tops[i] = -ArenaHeightStep.int16 * heightScale + ArenaWaterDepth
      result.layers[3].tiles[index] = water
