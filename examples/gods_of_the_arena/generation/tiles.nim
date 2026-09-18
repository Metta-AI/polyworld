import
  std/[math, random],
  chroma, vmath,
  maps, meshes

const
  TileCount* = MapResolution
  TileSize* = MapSize / TileCount.float32

type
  Direction* = enum
    North, East, South, West
  Edge* = enum
    OpenEdge, RampEdge, CliffEdge
  Terrain* = enum
    LowGround, HighGround, CastleGround, KeepGround, SpawnGround, LakeGround
  Surface* = enum
    NaturalSurface, RoadSurface, TreeSurface, WallSurface,
    TrailSurface
  Tile* = object
    terrain*: Terrain
    surface*: Surface
    side*: Team
    shade*: uint8
    road*, cliff*, ramp*: bool
    edges*: array[Direction, Edge]
  TileGrid* = object
    resolution*: int
    cells*: seq[Tile]
  MapPalette* = object
    low*, high*, castle*, keep*, spawn*, lake*: ColorRGBX
    road*, jungle*, trees*, walls*, trails*: ColorRGBX
    cliffs*, ramps*: ColorRGBX

const Palettes*: array[Team, MapPalette] = [
  MapPalette(
    low: LowColor,
    high: HighColor,
    castle: CastleColor,
    keep: KeepColor,
    spawn: SpawnColor,
    lake: WaterColor,
    road: RoadColor,
    jungle: CampColor,
    trees: TreeColor,
    walls: WallColor,
    trails: TrailColor,
    cliffs: rgbx(118, 126, 93, 255),
    ramps: rgbx(208, 181, 123, 255)
  ),
  MapPalette(
    low: rgbx(76, 94, 86, 255),
    high: rgbx(109, 119, 98, 255),
    castle: rgbx(103, 105, 101, 255),
    keep: rgbx(159, 157, 149, 255),
    spawn: rgbx(123, 94, 107, 255),
    lake: WaterColor,
    road: rgbx(117, 99, 69, 255),
    jungle: rgbx(25, 60, 37, 255),
    trees: rgbx(33, 75, 47, 255),
    walls: rgbx(53, 59, 58, 255),
    trails: rgbx(99, 105, 74, 255),
    cliffs: rgbx(61, 72, 65, 255),
    ramps: rgbx(152, 133, 98, 255)
  )
]

proc height*(tile: Tile): uint8 {.raises: [].} =
  ## Returns the elevation of one terrain or wall tile.
  if tile.surface == WallSurface:
    return 4
  case tile.terrain
  of LakeGround:
    0
  of LowGround:
    1
  of HighGround:
    2
  of CastleGround, KeepGround, SpawnGround:
    3

proc tileColor*(tile: Tile): ColorRGBX {.raises: [].} =
  ## Resolves a tile's visible surface over its underlying terrain.
  let palette = Palettes[tile.side]
  if tile.ramp or RampEdge in tile.edges:
    return palette.ramps
  if tile.cliff and not tile.road and tile.surface != WallSurface:
    return palette.cliffs
  if tile.terrain == LakeGround and tile.road:
    return rgbx(93, 175, 193, 255)
  case tile.surface
  of RoadSurface:
    return palette.road
  of TreeSurface:
    let shade = tile.shade.int * 5
    return rgbx(
      (palette.trees.r.int + shade).uint8,
      (palette.trees.g.int + shade).uint8,
      (palette.trees.b.int + shade).uint8,
      255
    )
  of WallSurface:
    return palette.walls
  of TrailSurface:
    return palette.trails
  of NaturalSurface:
    discard
  case tile.terrain
  of LowGround:
    palette.low
  of HighGround:
    palette.high
  of CastleGround:
    palette.castle
  of KeepGround:
    palette.keep
  of SpawnGround:
    palette.spawn
  of LakeGround:
    palette.lake

proc tileSize*(grid: TileGrid): float32 {.raises: [].} =
  ## Returns canvas units per tile for the selected raster resolution.
  MapSize / grid.resolution.float32

proc tileAt*(grid: TileGrid, point: Vec2): Tile {.raises: [].} =
  ## Reads the tile beneath a map position, clamped to the map edges.
  let
    x = clamp((point.x / grid.tileSize).int, 0, grid.resolution - 1)
    y = clamp((point.y / grid.tileSize).int, 0, grid.resolution - 1)
  grid.cells[y * grid.resolution + x]

proc passable*(tile: Tile): bool {.raises: [].} =
  ## Allows movement through clear ground while trees and walls block it.
  tile.surface notin {TreeSurface, WallSurface}

proc canStep*(grid: TileGrid, x, y: int, direction: Direction): bool =
  ## Enforces tile obstacles and ramps at elevation changes.
  if x notin 0 ..< grid.resolution or y notin 0 ..< grid.resolution:
    return false
  let
    dx = [0, 1, 0, -1][direction.ord]
    dy = [-1, 0, 1, 0][direction.ord]
    nx = x + dx
    ny = y + dy
  if nx notin 0 ..< grid.resolution or ny notin 0 ..< grid.resolution:
    return false
  let
    current = grid.cells[y * grid.resolution + x]
    next = grid.cells[ny * grid.resolution + nx]
  current.passable and next.passable and current.edges[direction] != CliffEdge

proc buildEdges(grid: var TileGrid) {.raises: [].} =
  ## Makes elevation boundaries impassable except at road crossings.
  for y in 0 ..< grid.resolution:
    for x in 0 ..< grid.resolution:
      let index = y * grid.resolution + x
      for direction in [East, South]:
        if (direction == East and x == grid.resolution - 1) or
          (direction == South and y == grid.resolution - 1):
            continue
        let
          next = index + (if direction == East: 1 else: grid.resolution)
          a = grid.cells[index]
          b = grid.cells[next]
        if a.height == b.height:
          continue
        let
          highBorder = a.height in 1'u8 .. 2'u8 and
            b.height in 1'u8 .. 2'u8
          edge =
            if a.road and b.road and a.passable and b.passable and
              (not highBorder or (a.ramp and b.ramp)):
                RampEdge
            else:
              CliffEdge
          reverse = Direction((direction.ord + 2) mod 4)
        grid.cells[index].edges[direction] = edge
        grid.cells[next].edges[reverse] = edge
        if edge == CliffEdge:
          grid.cells[index].cliff = grid.cells[index].cliff or
            a.height > b.height
          grid.cells[next].cliff = grid.cells[next].cliff or
            b.height > a.height

proc assignSides(grid: var TileGrid, map: MapData) {.raises: [].} =
  ## Applies the curved palette split and preserves paired terrain data.
  var
    boundaries = newSeq[float32](grid.resolution * 2 - 1)
    segment = 0
  for i in 0 ..< boundaries.len:
    let diagonal = (i + 1).float32 * grid.tileSize / 2
    if diagonal <= map.border[0].x or diagonal >= map.border[^1].x:
      continue
    while segment < map.border.len - 2 and
      (map.border[segment + 1].x + map.border[segment + 1].y) / 2 < diagonal:
        segment.inc
    let
      a = map.border[segment]
      b = map.border[segment + 1]
      start = (a.x + a.y) / 2
      finish = (b.x + b.y) / 2
      t = (diagonal - start) / (finish - start)
    boundaries[i] = mix(a.x - a.y, b.x - b.y, t)
  for y in 0 ..< grid.resolution div 2:
    for x in 0 ..< grid.resolution:
      let
        index = y * grid.resolution + x
        across = (x - y).float32 * grid.tileSize - boundaries[x + y]
        side = (if across >= 0: Northeast else: Southwest)
      grid.cells[index].side = side
      grid.cells[grid.cells.high - index] = grid.cells[index]
      grid.cells[grid.cells.high - index].side = Team(1 - side.ord)

proc stamp(
  grid: var TileGrid,
  face: MapTriangle,
  tile: Tile,
  surfaceOnly: bool
) {.raises: [].} =
  ## Fills tile centers covered by a triangle using horizontal spans.
  let
    points = [
      face.positions[0] / grid.tileSize,
      face.positions[1] / grid.tileSize,
      face.positions[2] / grid.tileSize
    ]
    minimumY = min(points[0].y, min(points[1].y, points[2].y))
    first = max(0, ceil(minimumY - 0.5).int)
    last = min(
      grid.resolution - 1,
      floor(max(points[0].y, max(points[1].y, points[2].y)) - 0.5).int
    )
  for y in first .. last:
    let center = y.float32 + 0.5'f
    var
      left = float32.high
      right = -float32.high
      intersections = 0
    for i in 0 ..< 3:
      let
        a = points[i]
        b = points[(i + 1) mod 3]
      if center >= min(a.y, b.y) and center < max(a.y, b.y):
        let x = a.x + (center - a.y) / (b.y - a.y) * (b.x - a.x)
        left = min(left, x)
        right = max(right, x)
        intersections.inc
    if intersections < 2:
      continue
    let
      start = max(0, ceil(left - 0.5'f - 0.0001'f).int)
      finish = min(
        grid.resolution,
        ceil(right - 0.5'f + 0.0001'f).int
      )
      row = y * grid.resolution
    for x in start ..< finish:
      if surfaceOnly:
        grid.cells[row + x].surface = tile.surface
        if tile.surface in {RoadSurface, TrailSurface}:
          grid.cells[row + x].road = true
        if tile.ramp:
          grid.cells[row + x].ramp = true
      else:
        let
          road = grid.cells[row + x].road
          ramp = grid.cells[row + x].ramp
        grid.cells[row + x] = tile
        grid.cells[row + x].road = road
        grid.cells[row + x].ramp = ramp

proc plantForest(grid: var TileGrid, map: MapData) {.raises: [].} =
  ## Carves round clearings and shades the remaining forest.
  for y in 0 ..< grid.resolution:
    for x in 0 ..< grid.resolution:
      let index = y * grid.resolution + x
      if grid.cells[index].surface != TreeSurface:
          continue
      let position = vec2(x.float32 + 0.5'f, y.float32 + 0.5'f) * grid.tileSize
      var clearing = false
      for camp in map.camps:
        if lengthSq(position - camp.position) <
          (map.config.campRadius + CampPadding) ^ 2:
            clearing = true
            break
      if not clearing:
        for tower in map.towers:
          if lengthSq(position - tower.position) < TowerClearingRadius ^ 2:
            clearing = true
            break
      if clearing:
        grid.cells[index].surface = NaturalSurface
  for i, camp in map.camps:
    if map.config.campsTouchRoads:
      break
    let
      radius = map.config.campRadius + CampPadding
      outside = radius + CampForest
      first = floor((camp.position - vec2(outside)) / grid.tileSize).ivec2
      last = ceil((camp.position + vec2(outside)) / grid.tileSize).ivec2
    for y in max(0, first.y) .. min(grid.resolution - 1, last.y):
      for x in max(0, first.x) .. min(grid.resolution - 1, last.x):
        let
          index = y * grid.resolution + x
          point = vec2(x.float32 + 0.5'f, y.float32 + 0.5'f) * grid.tileSize
          distance = lengthSq(point - camp.position)
        if distance < radius ^ 2 or distance >= outside ^ 2:
          continue
        if lengthSq(map.stems[i].nearest(point) - point) <= (StemWidth / 2) ^ 2:
          continue
        grid.cells[index].surface = TreeSurface
        grid.cells[index].road = false
        grid.cells[index].ramp = false
  var rng = initRand(map.config.seed xor 0x4A17)
  for y in countup(0, grid.resolution, 2):
    for x in countup(0, grid.resolution, 2):
      let
        center = vec2(x.float32, y.float32) + vec2(
          rng.rand(-0.3 .. 0.3).float32,
          rng.rand(-0.3 .. 0.3).float32
        )
        radius = rng.rand(1.6 .. 2.4).float32
        shade = rng.rand(0 .. 2).uint8
      for cy in max(0, y - 3) .. min(grid.resolution - 1, y + 3):
        for cx in max(0, x - 3) .. min(grid.resolution - 1, x + 3):
          let
            index = cy * grid.resolution + cx
            delta = vec2(cx.float32 + 0.5'f, cy.float32 + 0.5'f) - center
          if grid.cells[index].surface == TreeSurface and
            lengthSq(delta) < radius * radius:
              grid.cells[index].shade = shade

proc buildTiles*(map: MapData): TileGrid =
  ## Generates the terrain tile grid with exact rotational symmetry.
  let resolution = map.config.mapSize
  doAssert resolution > 0 and resolution mod 2 == 0
  result.resolution = resolution
  result.cells = newSeq[Tile](resolution * resolution)
  for tile in result.cells.mitems:
    tile.surface = TreeSurface
  for face in buildMesh(map):
    var
      tile: Tile
      surfaceOnly = false
    if face.tint == HighColor:
      tile.terrain = HighGround
      tile.surface = TreeSurface
    elif face.tint == CastleColor:
      tile.terrain = CastleGround
    elif face.tint == KeepColor:
      tile.terrain = KeepGround
    elif face.tint == SpawnColor:
      tile.terrain = SpawnGround
    elif face.tint == WaterColor:
      tile.terrain = LakeGround
    elif face.tint == RampColor:
      tile.surface = RoadSurface
      tile.ramp = true
      surfaceOnly = true
    elif face.tint == TrailColor:
      tile.surface = TrailSurface
      surfaceOnly = true
    elif face.tint == MarginColor:
      tile.surface = NaturalSurface
      surfaceOnly = true
    elif face.tint == RoadColor:
      tile.surface = RoadSurface
      surfaceOnly = true
    elif face.tint == WallColor:
      tile.surface = WallSurface
      surfaceOnly = true
    else:
      continue
    result.stamp(face, tile, surfaceOnly)
  result.plantForest(map)
  for y in 0 ..< resolution:
    for x in 0 ..< resolution:
      if x notin [0, resolution - 1] and y notin [0, resolution - 1]:
        continue
      let index = y * resolution + x
      result.cells[index].surface =
        if result.cells[index].terrain in
          {CastleGround, KeepGround, SpawnGround}:
          WallSurface
        else:
          TreeSurface
      result.cells[index].road = false
      result.cells[index].ramp = false
  result.assignSides(map)
  result.buildEdges()

proc colors*(
  grid: TileGrid,
  walkableOnly = false
): seq[ColorRGBX] {.raises: [].} =
  ## Caches terrain colors or white walkable and black blocked tiles.
  result = newSeq[ColorRGBX](grid.cells.len)
  for i, tile in grid.cells:
    if walkableOnly:
      result[i] =
        if tile.passable:
          rgbx(255, 255, 255, 255)
        else:
          rgbx(0, 0, 0, 255)
    else:
      result[i] = tile.tileColor
