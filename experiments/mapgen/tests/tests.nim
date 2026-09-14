import
  std/[math, random],
  vmath,
  ../maps, ../meshes, ../tiles, test_contacts

proc gaps(walls: openArray[Wall]): int =
  ## Counts breaks in a closed wall perimeter.
  for i, wall in walls:
    if length(wall.points[1] - walls[(i + 1) mod walls.len].points[0]) > 0.01:
      result.inc

proc verifyWalls(map: MapData) =
  ## Checks mirrored walls, open entrances, and a sealed outer border.
  let grid = buildTiles(map)
  for walls in [map.keepWalls, map.spawnWalls]:
    doAssert walls[0].len == walls[1].len
    for i, wall in walls[0]:
      doAssert wall.points[0].opposite == walls[1][i].points[0]
      doAssert wall.points[1].opposite == walls[1][i].points[1]
      doAssert wall.width == walls[1][i].width
  doAssert map.spawnWalls[0].gaps == 1
  for road in map.roads:
    for i in 1 ..< road.len:
      let steps = max(1, ceil(length(road[i] - road[i - 1]) / 3).int)
      for j in 0 .. steps:
        let point = mix(road[i - 1], road[i], j.float32 / steps.float32)
        doAssert grid.tileAt(point).surface notin {WallSurface, TreeSurface}
  let direction = normalize(vec2(1, -1))
  for spawn in map.spawns:
    let gate = (spawn[2] + spawn[3]) / 2
    for i in -8 .. 8:
      doAssert grid.tileAt(gate + direction * i.float32 * 3).surface !=
        WallSurface
  for i in 0 ..< TileCount:
    for index in [
      i, (TileCount - 1) * TileCount + i,
      i * TileCount, i * TileCount + TileCount - 1
    ]:
      doAssert grid.cells[index].surface in {WallSurface, TreeSurface},
        "Open border at seed " & $map.config.seed & ", tile " & $index
  for tile in grid.cells:
    if tile.surface == WallSurface:
      doAssert tile.height == 4

proc verifyAccess(map: MapData) =
  ## Verifies carved routes, elevation transitions, and access to every camp.
  let grid = buildTiles(map)
  for trail in map.trails & map.lakeRoads & map.stems & @[
    map.fortRoads[0], map.fortRoads[1]
  ]:
    for i in 1 ..< trail.len:
      let steps = max(1, ceil(length(trail[i] - trail[i - 1]) / 3).int)
      for j in 0 .. steps:
        let point = mix(trail[i - 1], trail[i], j.float32 / steps.float32)
        doAssert grid.tileAt(point).surface notin {TreeSurface, WallSurface},
          "Blocked trail at seed " & $map.config.seed & ": " & $point
  var
    reached: array[TileCount * TileCount, bool]
    queue: seq[int]
    ramps, cliffs, forest: int
  let start = grid.tileAt(map.forts[0])
  doAssert start.passable
  for tower in map.towers:
    let tile = grid.tileAt(tower.position)
    doAssert tile.passable and tile.height > 0
    doAssert not tile.ramp, "Tower on a ramp segment."
    doAssert RampEdge notin tile.edges,
      "Tower on ramp at seed " & $map.config.seed
  let origin =
    (map.forts[0].y / TileSize).int * TileCount +
    (map.forts[0].x / TileSize).int
  reached[origin] = true
  queue.add(origin)
  var head = 0
  while head < queue.len:
    let
      index = queue[head]
      x = index mod TileCount
      y = index div TileCount
    head.inc
    for direction in Direction:
      if grid.canStep(x, y, direction):
        let next = index + [-TileCount, 1, TileCount, -1][direction.ord]
        if not reached[next]:
          reached[next] = true
          queue.add(next)
  for camp in map.camps:
    let index = (camp.position.y / TileSize).int * TileCount +
      (camp.position.x / TileSize).int
    doAssert reached[index],
      "Unreachable camp at seed " & $map.config.seed & ": " & $camp.position
  for camp in map.camps:
    let
      radius = map.config.campRadius + CampPadding
      terrain = grid.tileAt(camp.position).terrain
      first = floor((camp.position - vec2(radius)) / TileSize).ivec2
      last = ceil((camp.position + vec2(radius)) / TileSize).ivec2
    doAssert terrain in {LowGround, HighGround}
    doAssert map.levelClearing(camp.position, radius)
    for y in first.y .. last.y:
      for x in first.x .. last.x:
        let
          low = vec2(x.float32, y.float32) * TileSize
          nearest = clamp(camp.position, low, low + vec2(TileSize))
        if lengthSq(nearest - camp.position) <= radius ^ 2:
          doAssert grid.tileAt(low + vec2(TileSize / 2)).terrain == terrain,
            "Camp crosses an elevation border at seed " & $map.config.seed
  for i, tile in grid.cells:
    let other = grid.cells[grid.cells.high - i]
    doAssert tile.road == other.road
    doAssert tile.ramp == other.ramp
    doAssert tile.shade == other.shade
    doAssert tile.cliff == other.cliff
    if tile.surface == TreeSurface:
      forest.inc
      doAssert not tile.passable
    for direction in Direction:
      let reverse = Direction((direction.ord + 2) mod 4)
      doAssert tile.edges[direction] == other.edges[reverse]
      case tile.edges[direction]
      of OpenEdge:
        discard
      of RampEdge:
        ramps.inc
        doAssert tile.road
        doAssert grid.canStep(i mod TileCount, i div TileCount, direction)
      of CliffEdge:
        cliffs.inc
        doAssert not grid.canStep(i mod TileCount, i div TileCount, direction)
  doAssert ramps > 0 and cliffs > 0
  doAssert forest > 3000

proc verifyBarracks(map: MapData) =
  ## Checks paired gate flanks and passable creep routes into each lane.
  let grid = buildTiles(map)
  var counts: array[Team, array[3, int]]
  doAssert map.barracks.len == 12
  for i, barrack in map.barracks:
    counts[barrack.team][barrack.lane].inc
    doAssert grid.tileAt(barrack.position).terrain in {CastleGround, KeepGround}
    doAssert grid.tileAt(barrack.position).passable
    doAssert barrack.route[0] == barrack.spawn
    doAssert barrack.distance > 200
    doAssert length(
      barrack.route[^1] - map.roads[barrack.lane].along(0.5)
    ) < 0.1
    for j in 1 ..< barrack.route.len:
      let steps = max(1, ceil(length(
        barrack.route[j] - barrack.route[j - 1]
      ) / 3).int)
      for step in 0 .. steps:
        let point = mix(
          barrack.route[j - 1], barrack.route[j], step.float32 / steps.float32
        )
        doAssert grid.tileAt(point).passable,
          "Blocked creep route at seed " & $map.config.seed & ": " & $point
    for j in 0 ..< i:
      doAssert length(barrack.position - map.barracks[j].position) >=
        BarrackRadius * 2 + 3
    if i mod 2 == 0:
      let other = map.barracks[i + 1]
      doAssert barrack.position.opposite == other.position
      doAssert barrack.spawn.opposite == other.spawn
      doAssert barrack.team != other.team
      for j, point in barrack.route:
        doAssert point.opposite == other.route[j]
  doAssert counts == [[2, 2, 2], [2, 2, 2]]
  for lane in 0 ..< 3:
    let
      first = map.barracks[lane * 4]
      second = map.barracks[lane * 4 + 2]
      path = map.roads[lane]
      a = first.position - path.nearest(first.position)
      b = second.position - path.nearest(second.position)
    doAssert dot(a, b) < 0

proc verifyStems(map: MapData) =
  ## Ensures clearings only attach through their own single stem.
  doAssert map.stems.len == map.camps.len
  for i, stem in map.stems:
    doAssert stem[0] == map.camps[i].position
    doAssert map.avoidsCamps(stem, StemWidth, i)
    doAssert dot(normalize(stem[^1] - stem[0]), map.camps[i].facing) > 0
    doAssert abs(length(stem[^1] - stem[0]) -
      map.config.campRadius - map.config.stemLength) <= MapSize / 64
    var connected = false
    for road in map.trails:
      if length(road.nearest(stem[^1]) - stem[^1]) < 0.1:
        connected = true
    doAssert connected
    if i mod 2 == 0:
      for j, point in stem:
        doAssert point.opposite == map.stems[i + 1][j]
  for road in map.trails & map.lakeRoads:
    doAssert map.avoidsCamps(road, TrailWidth),
      "Road intersects a camp at seed " & $map.config.seed
  for road in map.roads:
    doAssert map.avoidsCamps(road, map.config.roadWidth)
  for road in map.fortRoads:
    doAssert map.avoidsCamps(road, FortRoadWidth)

proc verifyForest(map: MapData) =
  ## Proves that sealing a camp's stem leaves no other exit through the forest.
  if map.config.campsTouchRoads:
    return
  let grid = buildTiles(map)
  for i, camp in map.camps:
    let
      radius = map.config.campRadius + CampPadding
      outside = radius + CampForest
      origin = (camp.position.y / TileSize).int * TileCount +
        (camp.position.x / TileSize).int
    var
      reached: array[TileCount * TileCount, bool]
      queue = @[origin]
      head = 0
    reached[origin] = true
    while head < queue.len:
      let
        index = queue[head]
        x = index mod TileCount
        y = index div TileCount
      head.inc
      for direction in Direction:
        if not grid.canStep(x, y, direction):
          continue
        let
          next = index + [-TileCount, 1, TileCount, -1][direction.ord]
          point = vec2(
            (next mod TileCount).float32 + 0.5'f,
            (next div TileCount).float32 + 0.5'f
          ) * TileSize
          distance = length(point - camp.position)
        if reached[next]:
          continue
        if distance >= radius - TileSize and
          length(map.stems[i].nearest(point) - point) <
          StemWidth / 2 + TileSize * 0.72'f:
            continue
        doAssert distance < outside + TileSize,
          "Camp has a second entrance at seed " & $map.config.seed
        reached[next] = true
        queue.add(next)

proc verifyRamps(map: MapData) =
  ## Checks short perpendicular ramps, mirrored surfaces, and road clearance.
  doAssert map.ramps.len >= 4 and map.ramps.len mod 2 == 0
  for i, ramp in map.ramps:
    let
      direction = normalize(ramp.points[1] - ramp.points[0])
      tangent = normalize(ramp.edge[1] - ramp.edge[0])
      first = map.groundHeight(ramp.points[0])
      last = map.groundHeight(ramp.points[1])
      center = (ramp.points[0] + ramp.points[1]) / 2
    doAssert length(ramp.points[1] - ramp.points[0]) <= 5 * TileSize + 0.001,
      "Ramp exceeds five tiles at seed " & $map.config.seed
    doAssert abs(dot(direction, tangent)) < 0.0001
    doAssert first in 1 .. 2 and last in 1 .. 2 and first != last
    var faces = 0
    for face in buildMesh(MapData(ramps: @[ramp])):
      if face.tint != RampColor:
        continue
      faces.inc
      for point in face.positions:
        doAssert abs(dot(point - center, direction)) <= 2.5 * TileSize + 0.001,
          "Ramp end caps extend past five tiles."
    doAssert faces > 0
    if i mod 2 == 0:
      let other = map.ramps[i + 1]
      doAssert ramp.points[0].opposite == other.points[0]
      doAssert ramp.points[1].opposite == other.points[1]
      doAssert ramp.approaches[0].opposite == other.approaches[0]
      doAssert ramp.approaches[1].opposite == other.approaches[1]
      doAssert ramp.edge[0].opposite == other.edge[0]
  var paths: seq[tuple[points: seq[Vec2], width: float32]]
  for road in map.roads:
    paths.add((road, map.config.roadWidth))
  for road in map.fortRoads:
    paths.add((road, FortRoadWidth))
  for road in map.trails & map.lakeRoads:
    paths.add((road, TrailWidth))
  for stem in map.stems:
    paths.add((stem, StemWidth))
  for path in paths:
    doAssert map.clearCliffs(path.points, path.width, map.ramps),
      "Road straddles a cliff at seed " & $map.config.seed &
        ", width " & $path.width
    for i in 1 ..< path.points.len:
      let
        a = path.points[i - 1]
        b = path.points[i]
        first = map.groundHeight(a)
        last = map.groundHeight(b)
      if first notin 1 .. 2 or last notin 1 .. 2 or first == last:
        continue
      var perpendicular = false
      for ramp in map.ramps:
        let center = (ramp.points[0] + ramp.points[1]) / 2
        if length([a, b].nearest(center) - center) < 2 and
          abs(dot(normalize(b - a), normalize(ramp.edge[1] - ramp.edge[0]))) <
          0.0001:
            perpendicular = true
      doAssert perpendicular,
        "Angled cliff crossing at seed " & $map.config.seed

proc verify(map: MapData) =
  ## Checks counts, paired geometry, camp access, and lane tower alignment.
  doAssert buildMesh(map).len > 1000
  doAssert map.towers.len == 18
  doAssert map.camps.len == 14
  doAssert map.forts[0].opposite == map.forts[1]
  var
    counts: array[Team, int]
    quadrants: array[4, int]
    lakeside = 0
  for i, tower in map.towers:
    counts[tower.team].inc
    if i mod 2 == 0:
      doAssert tower.position.opposite == map.towers[i + 1].position
      doAssert tower.team != map.towers[i + 1].team
    if i < 12:
      var distance = float32.high
      for road in map.roads:
        distance = min(
          distance,
          length(road.nearest(tower.position) - tower.position)
        )
      doAssert distance < 0.001
  doAssert counts == [9, 9]
  for i, camp in map.camps:
    if i mod 2 == 0:
      let other = map.camps[i + 1]
      doAssert camp.position.opposite == other.position
      doAssert camp.facing == -other.facing
      doAssert camp.lakeside == other.lakeside
    if camp.lakeside:
      lakeside.inc
      let target = normalize(map.lake.nearest(camp.position) - camp.position)
      doAssert dot(camp.facing, target) > 0.999
    else:
      let quadrant =
        (camp.position.x >= 500).int + (camp.position.y >= 500).int * 2
      quadrants[quadrant].inc
    var
      roadDistance = float32.high
      roadTarget = vec2(0, 0)
    for road in map.roads:
      let target = road.nearest(camp.position)
      if lengthSq(target - camp.position) < roadDistance:
        roadDistance = lengthSq(target - camp.position)
        roadTarget = target
    doAssert dot(camp.facing, normalize(roadTarget - camp.position)) <= 0.001
    if not map.config.campsTouchRoads:
      for road in map.roads:
        doAssert length(road.nearest(camp.position) - camp.position) >
          map.config.roadWidth / 2 + map.config.campRadius
    doAssert length(map.lake.nearest(camp.position) - camp.position) >
      map.config.lakeWidth * 0.62'f + map.config.campRadius
    for j in 0 ..< i:
      doAssert length(camp.position - map.camps[j].position) >
        map.config.campRadius * 2
  doAssert quadrants == [3, 3, 3, 3]
  doAssert lakeside == 2
  for i, point in map.roads[0]:
    doAssert point.opposite == map.roads[1][i]
  for i, point in map.roads[2]:
    let other = map.roads[2][map.roads[2].high - i]
    doAssert length(point.opposite - other) < 0.001
  for i, point in map.lake:
    doAssert length(point.opposite - map.lake[map.lake.high - i]) < 0.001
  for i, point in map.border:
    doAssert length(point.opposite - map.border[map.border.high - i]) < 0.001
  for i in [1, map.border.len div 2, map.border.high]:
    doAssert map.border[i].x + map.border[i].y >
      map.border[i - 1].x + map.border[i - 1].y
  doAssert abs(map.border[8].x - map.border[8].y) > 10
  doAssert abs(map.border[24].x - map.border[24].y) > 10
  for i in countup(4, map.highlands[0].high - 4, 8):
    doAssert not map.levelClearing(map.highlands[0][i], 10)
  for shapes in [map.highlands, map.castles, map.keeps, map.spawns]:
    for i, point in shapes[0]:
      doAssert point.opposite == shapes[1][i]
  doAssert map.trails.len == map.config.jungleRoads
  doAssert map.towerTrails.len ==
    (if map.config.jungleRoads > 36: 6 else: 4)
  var towerLanes: array[2, bool]
  for i, index in map.towerTrails:
    let path = map.trails[index]
    var target = false
    for j in 0 ..< 12:
      if length(path[^1] - map.towers[j].position) < 0.001:
        target = true
        if j < 8:
          towerLanes[j div 4] = true
    doAssert target
    if i mod 2 == 0:
      doAssert map.towerTrails[i + 1] == index + 1
  doAssert towerLanes == [true, true]
  for i, trail in map.trails:
    doAssert trail.len >= 2
    for j, point in trail:
      doAssert point.x == point.x and point.y == point.y
      if i mod 2 == 0:
        doAssert point.opposite == map.trails[i + 1][j]
  for i, point in map.fortRoads[0]:
    doAssert point.opposite == map.fortRoads[1][i]
  doAssert map.lakeRoads.len == map.config.lakeCrossings
  for i, road in map.lakeRoads:
    if i mod 2 == 0:
      for j, point in road:
        doAssert point.opposite == map.lakeRoads[i + 1][j]
  verifyWalls(map)
  verifyAccess(map)
  verifyBarracks(map)
  verifyStems(map)
  verifyForest(map)
  verifyRamps(map)

echo "Checking deterministic generation and exact paired geometry."
doAssert generateMap(defaultConfig()) == generateMap(defaultConfig())
doAssert generateMap(defaultConfig()).keepWalls[0].gaps == 3
verify(generateMap(defaultConfig()))

echo "Checking the expanded controls individually at their maxima."
for control in 0 ..< 6:
  var config = defaultConfig()
  case control
  of 0:
    config.castleSize = 500
    config.campRadius = 28
  of 1:
    config.roadWobble = 80
  of 2:
    config.lakeWidth = 120
  of 3:
    config.jungleRoads = 50
  of 4:
    config.lakeWobble = 80
  of 5:
    config.campScatter = 60
  else:
    discard
  verify(generateMap(config))

echo "Checking 300 seeds at the saved defaults."
for seed in 0 ..< 300:
  var config = defaultConfig()
  config.seed = seed
  verify(generateMap(config))

echo "Checking 300 crowded and mixed layouts, including rejected combinations."
var
  rng = initRand(913)
  accepted, rejected: int
for seed in 0 ..< 300:
  var config = defaultConfig()
  config.seed = seed
  case seed mod 3
  of 0:
    discard
  of 1:
    config.highSize = 570
    config.castleSize = 280
    config.roadWidth = 62
    config.roadWobble = 44
    config.lakeWidth = 86
    config.lakeWobble = 42
    config.campRadius = 40
    config.stemLength = 80
    config.jungleRoads = 36
    config.campScatter = 30
    config.lakeCrossings = 6
  else:
    config.highSize = rng.rand(450 .. 570).float32
    config.castleSize = rng.rand(210 .. 280).float32
    config.roadWidth = rng.rand(26 .. 62).float32
    config.roadWobble = rng.rand(0 .. 44).float32
    config.lakeWidth = rng.rand(42 .. 86).float32
    config.lakeWobble = rng.rand(0 .. 42).float32
    config.campRadius = rng.rand(20 .. 40).float32
    config.campScatter = rng.rand(0 .. 30).float32
    config.stemLength = rng.rand(30 .. 80).float32
    config.jungleRoads = rng.rand(9 .. 18) * 2
    config.lakeCrossings = rng.rand(0 .. 3) * 2
  var map: MapData
  try:
    map = generateMap(config)
  except MapgenError:
    # Some combinations cannot fit all forest buffers and legal ramps.
    doAssert seed mod 3 != 0, "The saved defaults must generate reliably."
    rejected.inc
    continue
  verify(map)
  accepted.inc
doAssert accepted >= 150
echo "Validated ", accepted, " layouts; rejected ", rejected,
  " combinations without enough room."

echo "All map generator checks passed."

echo "Checking tile dimensions, elevations, and mirrored terrain."
block:
  let
    map = generateMap(defaultConfig())
    grid = buildTiles(map)
  doAssert grid.cells.len == 128 * 128
  for i, tile in grid.cells:
    let other = grid.cells[grid.cells.high - i]
    doAssert tile.terrain == other.terrain
    doAssert tile.surface == other.surface
    doAssert tile.height == other.height
    doAssert tile.side != other.side
  doAssert grid.tileAt(vec2(MapSize / 2)).terrain == LakeGround
  doAssert grid.tileAt(vec2(MapSize / 2)).height == 0
  doAssert grid.tileAt(vec2(10, 10)).height == 2
  doAssert grid.tileAt(vec2(MapSize - 10, 10)).terrain == SpawnGround
  doAssert grid.tileAt(vec2(MapSize - 10, 10)).height == 3
  doAssert grid.tileAt(map.forts[0]).side == Southwest
  doAssert grid.tileAt(map.forts[1]).side == Northeast
  for terrain in Terrain:
    for surface in Surface:
      let
        light = Tile(terrain: terrain, surface: surface, side: Southwest)
        dark = Tile(terrain: terrain, surface: surface, side: Northeast)
        lightColor = light.tileColor
        darkColor = dark.tileColor
      if terrain == LakeGround and surface == NaturalSurface:
        doAssert lightColor == darkColor
      else:
        doAssert darkColor.r.int + darkColor.g.int + darkColor.b.int <
          lightColor.r.int + lightColor.g.int + lightColor.b.int
echo "All tile checks passed."
