import
  std/[math, random],
  chroma, vmath,
  polyworld/configs as matchConfigs,
  configs, routes

export configs

const
  MapSize* = 1000.0'f
  MapResolution* = DefaultMapSize
  # Preserve layout distances and sampling for existing replay presets.
  ReferenceResolution = 128
  RampLength* = MapSize / ReferenceResolution.float32 * 5
  LowColor* = rgbx(139, 198, 106, 255)
  HighColor* = rgbx(193, 208, 144, 255)
  CastleColor* = rgbx(169, 166, 145, 255)
  KeepColor* = rgbx(230, 229, 215, 255)
  SpawnColor* = rgbx(182, 154, 164, 255)
  RoadColor* = rgbx(165, 147, 81, 255)
  WaterColor* = rgbx(70, 157, 185, 255)
  CampColor* = rgbx(38, 111, 57, 255)
  TreeColor* = rgbx(54, 139, 65, 255)
  WallColor* = rgbx(107, 112, 101, 255)
  KeepWallWidth* = 16.0'f
  SpawnWallWidth* = 12.0'f
  SpawnGateWidth* = 22.0'f
  TrailWidth* = 20.0'f
  StemWidth* = 16.0'f
  CampPadding* = 5.0'f
  CampForest* = MapSize / ReferenceResolution.float32 * 1.5'f
  CampSeparation = CampPadding * 2 + CampForest + 2
  BarrackRadius* = 12.0'f
  CreepSpeed* = 42.0'f
  CreepInterval* = matchConfigs.DefaultSpawnIntervalTicks.float32 /
    matchConfigs.SharedTickRate.float32
  FortRoadWidth* = 30.0'f
  TrailColor* = rgbx(167, 167, 109, 255)
  RampColor* = rgbx(209, 181, 124, 255)
  GrassMargin* = 10.0'f
  MarginColor* = rgbx(140, 199, 107, 255)
  TowerClearingRadius* = 52.0'f
  TreePadding* = 6.0'f
  TeamColors* = [rgbx(35, 100, 226, 255), rgbx(225, 65, 67, 255)]

type
  Team* = enum
    Southwest, Northeast
  Tower* = object
    position*: Vec2
    team*: Team
    guardsGod*: bool
  Barrack* = object
    position*, spawn*: Vec2
    team*: Team
    lane*: int
    route*: seq[Vec2]
    distance*: float32
  Camp* = object
    position*, facing*: Vec2
    lakeside*: bool
  Wall* = object
    points*: array[2, Vec2]
    width*: float32
  Ramp* = object
    points*, approaches*, edge*: array[2, Vec2]
    width*: float32
  MapTriangle* = object
    positions*: array[3, Vec2]
    tint*: ColorRGBX
  MapData* = object
    config*: MapConfig
    highlands*, castles*, keeps*, spawns*: array[2, seq[Vec2]]
    roads*: array[3, seq[Vec2]]
    fortRoads*: array[2, seq[Vec2]]
    lake*: seq[Vec2]
    lakeBanks*: seq[Vec2]
    border*: seq[Vec2]
    ramps*: seq[Ramp]
    towers*: seq[Tower]
    camps*: seq[Camp]
    stems*: seq[seq[Vec2]]
    barracks*: seq[Barrack]
    trails*: seq[seq[Vec2]]
    towerTrails*: seq[int]
    lakeRoads*: seq[seq[Vec2]]
    keepWalls*, spawnWalls*: array[2, seq[Wall]]
    forts*: array[2, Vec2]

proc opposite*(point: Vec2): Vec2 {.raises: [].} =
  ## Rotates a point halfway around the map center.
  vec2(MapSize, MapSize) - point

proc mirrored(points: openArray[Vec2]): seq[Vec2] {.raises: [].} =
  ## Copies a shape into the opposite half of the map.
  for point in points:
    result.add(point.opposite)

proc smooth(points: openArray[Vec2]): seq[Vec2] {.raises: [].} =
  ## Samples a Catmull-Rom curve with clamped endpoints.
  for i in 0 ..< points.len - 1:
    let
      a = points[max(0, i - 1)]
      b = points[i]
      c = points[i + 1]
      d = points[min(points.high, i + 2)]
    for j in 0 ..< 16:
      let
        t = j.float32 / 16
        t2 = t * t
        t3 = t2 * t
      result.add((
        b * 2 + (c - a) * t +
        (a * 2 - b * 5 + c * 4 - d) * t2 +
        (-a + b * 3 - c * 3 + d) * t3
      ) * 0.5'f)
  result.add(points[^1])

proc nearest*(points: openArray[Vec2], point: Vec2): Vec2 {.raises: [].} =
  ## Finds the closest point on a sampled path.
  var best = float32.high
  for i in 0 ..< points.len - 1:
    let
      a = points[i]
      b = points[i + 1]
      dx = max(0'f, max(min(a.x, b.x) - point.x, point.x - max(a.x, b.x)))
      dy = max(0'f, max(min(a.y, b.y) - point.y, point.y - max(a.y, b.y)))
    if dx * dx + dy * dy >= best:
      continue
    let
      delta = points[i + 1] - points[i]
      t = clamp(
        dot(point - points[i], delta) / max(0.0001'f, lengthSq(delta)),
        0'f,
        1'f
      )
      candidate = points[i] + delta * t
      distance = lengthSq(candidate - point)
    if distance < best:
      best = distance
      result = candidate

proc along*(points: openArray[Vec2], fraction: float32): Vec2 {.raises: [].} =
  ## Locates a point by its fraction of the path length.
  var total = 0.0'f
  for i in 1 ..< points.len:
    total += length(points[i] - points[i - 1])
  var remaining = total * fraction
  for i in 1 ..< points.len:
    let distance = length(points[i] - points[i - 1])
    if remaining <= distance:
      return mix(points[i - 1], points[i], remaining / distance)
    remaining -= distance
  points[^1]

proc shoulder(size: float32): float32 {.raises: [].} =
  ## Broadens large forts along the map edges while preserving jungle space.
  max(0.02'f, 0.46'f * min(1'f, max(0'f, (500 - size) / 220) * 280 / size))

proc castle(size: float32): seq[Vec2] {.raises: [].} =
  ## Builds the southwest corner platform with a diagonal front.
  @[
    vec2(0, MapSize), vec2(0, MapSize - size),
    vec2(size * size.shoulder, MapSize - size),
    vec2(size, MapSize - size * size.shoulder), vec2(size, MapSize)
  ]

proc walls(
  outline: openArray[Vec2],
  openings: openArray[seq[Vec2]],
  width, clearance: float32
): seq[Wall] {.raises: [].} =
  ## Strokes a closed boundary while leaving its access corridors clear.
  for i, point in outline:
    let
      next = outline[(i + 1) mod outline.len]
      steps = ceil(length(next - point) / 2).int
    var start = -1
    for j in 0 .. steps:
      var solid = j < steps
      if solid:
        let sample = mix(point, next, (j.float32 + 0.5'f) / steps.float32)
        for opening in openings:
          if lengthSq(opening.nearest(sample) - sample) < clearance ^ 2:
            solid = false
            break
      if solid and start < 0:
        start = j
      elif not solid and start >= 0:
        result.add(Wall(
          points: [
            mix(point, next, start.float32 / steps.float32),
            mix(point, next, j.float32 / steps.float32)
          ],
          width: width
        ))
        start = -1

proc contains(outline: openArray[Vec2], point: Vec2): bool {.raises: [].} =
  ## Tests a world point against a closed terrain polygon.
  for i, a in outline:
    let b = outline[(i + 1) mod outline.len]
    if (a.y > point.y) != (b.y > point.y):
      let x = a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y)
      if point.x < x:
        result = not result

proc groundHeight*(map: MapData, point: Vec2): int {.raises: [].} =
  ## Reads the terrain elevation before it is sampled into tiles.
  for castle in map.castles:
    if castle.contains(point):
      return 3
  if map.lakeBanks.contains(point):
    return 0
  for highland in map.highlands:
    if highland.contains(point):
      return 2
  1

proc levelClearing*(
  map: MapData,
  position: Vec2,
  radius: float32
): bool {.raises: [].} =
  ## Requires the full disc to remain on one low or high ground platform.
  if map.groundHeight(position) notin 1 .. 2:
    return false
  for outline in [
    map.highlands[0], map.highlands[1], map.castles[0], map.castles[1],
    map.lakeBanks
  ]:
    if lengthSq(outline.nearest(position) - position) <= radius ^ 2:
      return false
    let closing = [outline[^1], outline[0]]
    if lengthSq(closing.nearest(position) - position) <= radius ^ 2:
      return false
  true

proc cliffPoint*(map: MapData, point: Vec2): Vec2 {.raises: [].} =
  ## Finds the nearest highland boundary point for road clearance checks.
  var distance = float32.high
  for outline in map.highlands:
    let candidate = outline.nearest(point)
    if lengthSq(candidate - point) < distance:
      distance = lengthSq(candidate - point)
      result = candidate

proc flat(map: MapData, point: Vec2): bool {.raises: [].} =
  ## Reserves a level tower footprint clear of water, ramps, and walls.
  let height = map.groundHeight(point)
  if height == 0:
    return false
  for i in 0 ..< 16:
    let
      angle = i.float32 * PI.float32 / 8
      sample = point + vec2(cos(angle), sin(angle)) * 24
    if map.groundHeight(sample) != height:
      return false
  for ramp in map.ramps:
    if length(ramp.approaches.nearest(point) - point) < ramp.width / 2 + 24:
      return false
  for walls in [map.keepWalls, map.spawnWalls]:
    for team in walls:
      for wall in team:
        if length(wall.points.nearest(point) - point) < wall.width / 2 + 24:
          return false
  true

proc towerPosition(
  map: MapData,
  road: seq[Vec2],
  fraction: float32,
  team: Team
): Vec2 {.raises: [MapgenError].} =
  ## Slides a tower along its lane until its footprint is on level ground.
  let forward = (if team == Southwest: 1'f else: -1'f)
  for i in 0 ..< 40:
    for direction in [forward, -forward]:
      let position = road.along(clamp(
        fraction + i.float32 * 0.004'f * direction,
        0.06'f,
        0.94'f
      ))
      if map.flat(position):
        return position
  raise newException(MapgenError, "Could not place a tower on level ground.")

proc placeWalls(map: var MapData) {.raises: [].} =
  ## Opens three keep entrances and one diagonal spawn entrance per team.
  map.keepWalls[0] = walls(
    map.castles[0],
    map.roads,
    KeepWallWidth,
    map.config.roadWidth / 2 + KeepWallWidth / 2 + 4
  )
  let
    gate = (map.spawns[0][2] + map.spawns[0][3]) / 2
    direction = normalize(vec2(1, -1))
    opening = @[
      gate - direction * SpawnWallWidth,
      gate + direction * SpawnWallWidth
    ]
  map.spawnWalls[0] = walls(
    map.spawns[0],
    [opening],
    SpawnWallWidth,
    SpawnGateWidth / 2 + SpawnWallWidth / 2
  )
  for wall in map.keepWalls[0]:
    map.keepWalls[1].add(Wall(
      points: [wall.points[0].opposite, wall.points[1].opposite],
      width: wall.width
    ))
  for wall in map.spawnWalls[0]:
    map.spawnWalls[1].add(Wall(
      points: [wall.points[0].opposite, wall.points[1].opposite],
      width: wall.width
    ))

proc campClearance*(map: MapData, position: Vec2): float32 {.raises: [].} =
  ## Measures the free space around a camp before its radius is applied.
  result = min(position.x, position.y)
  result = min(result, min(MapSize - position.x, MapSize - position.y))
  for road in map.roads:
    if map.config.campsTouchRoads:
      break
    result = min(
      result,
      length(road.nearest(position) - position) - map.config.roadWidth / 2
    )
    if result < map.config.campRadius + 2:
      return
  for road in map.fortRoads:
    if map.config.campsTouchRoads:
      break
    result = min(
      result,
      length(road.nearest(position) - position) - FortRoadWidth / 2
    )
  result = min(
    result,
    length(map.lake.nearest(position) - position) -
      map.config.lakeWidth * 0.62'f
  )
  if result < map.config.campRadius + 2:
    return
  for camp in map.camps:
    result = min(
      result,
      length(camp.position - position) - map.config.campRadius
    )
  for stem in map.stems:
    result = min(result, length(stem.nearest(position) - position) -
      StemWidth / 2)

proc campRoadRadius(
  map: MapData, width: float32, padding = 2.0'f
): float32 {.raises: [].} =
  ## Keeps road centers outside clearings, adding a forest buffer when locked.
  if map.config.campsTouchRoads:
    map.config.campRadius + CampPadding
  else:
    map.config.campRadius + CampPadding + CampForest + width / 2 + padding

proc avoidsCamps*(
  map: MapData,
  path: openArray[Vec2],
  width: float32,
  exceptCamp = -1
): bool {.raises: [].} =
  ## Applies the selected camp boundary rule to a road or another camp's stem.
  for i, camp in map.camps:
    if i == exceptCamp:
      continue
    if lengthSq(path.nearest(camp.position) - camp.position) <
      map.campRoadRadius(width) ^ 2:
        return false
  true

proc intersection(
  a, b, c, d: Vec2
): tuple[hit: bool, point: Vec2] {.raises: [].} =
  ## Intersects two finite segments while rejecting parallel lines.
  let
    u = b - a
    v = d - c
    offset = c - a
    divisor = u.x * v.y - u.y * v.x
  if abs(divisor) < 0.0001'f:
    return
  let
    t = (offset.x * v.y - offset.y * v.x) / divisor
    s = (offset.x * u.y - offset.y * u.x) / divisor
  if t in 0'f .. 1'f and s in 0'f .. 1'f:
    result = (true, a + u * t)

proc initRamp(
  approaches, edge: array[2, Vec2],
  width: float32,
  resolution: int
): Ramp {.raises: [].} =
  ## Limits the slope to five tiles while retaining level road approaches.
  let
    center = (approaches[0] + approaches[1]) / 2
    delta = approaches[1] - approaches[0]
    limit = min(RampLength, MapSize / resolution.float32 * 5)
    half = normalize(delta) * min(length(delta), limit) / 2
  Ramp(
    points: [center - half, center + half],
    approaches: approaches,
    edge: edge,
    width: width
  )

proc reverse(ramp: Ramp): Ramp {.raises: [].} =
  ## Rotates a ramp and its cliff segment into the opposite map half.
  Ramp(
    points: [ramp.points[0].opposite, ramp.points[1].opposite],
    approaches: [ramp.approaches[0].opposite, ramp.approaches[1].opposite],
    edge: [ramp.edge[0].opposite, ramp.edge[1].opposite],
    width: ramp.width
  )

proc curve(points: var seq[Vec2], a, b, c, d: Vec2) {.raises: [].} =
  ## Appends a cubic approach with continuous tangents at both ends.
  if points.len == 0 or lengthSq(points[^1] - a) > 0.001'f:
    points.add(a)
  for i in 1 .. 24:
    let t = i.float32 / 24
    points.add(a * (1 - t) ^ 3 + b * (3 * t * (1 - t) ^ 2) +
      c * (3 * t ^ 2 * (1 - t)) + d * t ^ 3)

proc rampRoad(
  map: var MapData,
  road: seq[Vec2],
  width: float32
): seq[Vec2] {.raises: [].} =
  ## Inserts perpendicular ramp segments and curved approaches into a road.
  var
    distances = newSeq[float32](road.len)
    crossings: seq[tuple[distance: float32, ramp: Ramp]]
  for i in 1 ..< road.len:
    distances[i] = distances[i - 1] + length(road[i] - road[i - 1])
    for highland in map.highlands:
      for j in 1 ..< highland.len:
        let
          edge = [highland[j - 1], highland[j]]
          hit = intersection(road[i - 1], road[i], edge[0], edge[1])
        if not hit.hit:
          continue
        if map.groundHeight(hit.point) notin 1 .. 2:
          continue
        if crossings.len > 0 and length(
          (crossings[^1].ramp.approaches[0] +
            crossings[^1].ramp.approaches[1]) / 2 - hit.point
        ) < 2:
          continue
        let tangent = normalize(edge[1] - edge[0])
        var normal = vec2(-tangent.y, tangent.x)
        if dot(normal, road[i] - road[i - 1]) < 0:
          normal = -normal
        let half = max(40'f, width / 2 + 24)
        crossings.add((
          distances[i - 1] + length(hit.point - road[i - 1]),
          initRamp(
            [hit.point - normal * half, hit.point + normal * half],
            edge,
            width,
            map.config.mapSize
          )
        ))
  var
    path: seq[Vec2]
    index = 0
  let total = distances[^1]
  for crossing in crossings:
    let
      ramp = crossing.ramp
      direction = normalize(ramp.approaches[1] - ramp.approaches[0])
      reach = length(ramp.approaches[1] - ramp.approaches[0]) / 2 +
        width + 24
      first = max(0'f, crossing.distance - reach)
      last = min(total, crossing.distance + reach)
      a = road.along(first / total)
      b = road.along(last / total)
      incoming = normalize(road.along((first + 1) / total) - a)
      outgoing = normalize(b - road.along((last - 1) / total))
      before = length(ramp.approaches[0] - a) / 3
      after = length(b - ramp.approaches[1]) / 3
    while index < road.len and distances[index] < first:
      path.add(road[index])
      index.inc
    path.curve(
      a, a + incoming * before,
      ramp.approaches[0] - direction * before, ramp.approaches[0]
    )
    path.add(ramp.approaches[1])
    path.curve(
      ramp.approaches[1], ramp.approaches[1] + direction * after,
      b - outgoing * after, b
    )
    while index < road.len and distances[index] <= last:
      index.inc
    map.ramps.add(ramp)
    map.ramps.add(ramp.reverse)
  while index < road.len:
    path.add(road[index])
    index.inc
  path

proc clearCliffs*(
  map: MapData,
  path: openArray[Vec2],
  width: float32,
  ramps: openArray[Ramp]
): bool {.raises: [].} =
  ## Keeps the entire road off cliff edges except within designated ramps.
  for i in 1 ..< path.len:
    let steps = max(1, ceil(length(path[i] - path[i - 1]) / 4).int)
    for j in 0 .. steps:
      let
        point = mix(path[i - 1], path[i], j.float32 / steps.float32)
        boundary = map.cliffPoint(point)
      if lengthSq(boundary - point) >= (width / 2 + 2) ^ 2:
        continue
      if map.groundHeight(point) notin 1 .. 2 or
        map.groundHeight(boundary) notin 1 .. 2:
          continue
      var crossing = false
      for ramp in ramps:
        if length(ramp.approaches.nearest(point) - point) < ramp.width / 2 + 2:
          crossing = true
          break
      if not crossing:
        return false
  true

proc stemRoad(
  map: MapData,
  start, finish: Vec2
): tuple[points: seq[Vec2], ramps: seq[Ramp]] {.raises: [].} =
  ## Gives a camp stem its own perpendicular ramp when it changes elevation.
  for outline in map.highlands:
    for i in 1 ..< outline.len:
      let
        edge = [outline[i - 1], outline[i]]
        hit = intersection(start, finish, edge[0], edge[1])
      if not hit.hit:
        continue
      if result.ramps.len > 0:
        return (@[], @[])
      let
        tangent = normalize(edge[1] - edge[0])
        half = min(32'f, min(length(start - hit.point),
          length(finish - hit.point)) * 0.75'f)
      var normal = vec2(-tangent.y, tangent.x)
      if dot(normal, finish - start) < 0:
        normal = -normal
      let ramp = initRamp(
        [hit.point - normal * half, hit.point + normal * half],
        edge,
        StemWidth,
        map.config.mapSize
      )
      if not map.levelClearing(ramp.approaches[0], StemWidth / 2 + 4) or
        not map.levelClearing(ramp.approaches[1], StemWidth / 2 + 4) or
        map.groundHeight(ramp.approaches[0]) ==
          map.groundHeight(ramp.approaches[1]):
          return (@[], @[])
      let
        direction = normalize(finish - start)
        before = length(ramp.approaches[0] - start) / 3
        after = length(finish - ramp.approaches[1]) / 3
      result.points.curve(
        start, start + direction * before,
        ramp.approaches[0] - normal * before, ramp.approaches[0]
      )
      result.points.add(ramp.approaches[1])
      result.points.curve(
        ramp.approaches[1], ramp.approaches[1] + normal * after,
        finish - direction * after, finish
      )
      result.ramps.add(ramp)
  if result.ramps.len == 0:
    result.points = @[start, finish]

proc clearStem(
  map: MapData,
  path: tuple[points: seq[Vec2], ramps: seq[Ramp]],
  exceptCamp = -1
): bool {.raises: [].} =
  ## Keeps a stem clear of other camps, water, and unapproved cliff crossings.
  if path.points.len < 2 or
    not map.avoidsCamps(path.points, StemWidth, exceptCamp) or
    not map.clearCliffs(path.points, StemWidth, path.ramps):
      return false
  for i in 1 ..< path.points.len:
    let steps = max(1, ceil(length(
      path.points[i] - path.points[i - 1]
    ) / 4).int)
    for step in 0 .. steps:
      let point = mix(
        path.points[i - 1], path.points[i], step.float32 / steps.float32
      )
      if map.groundHeight(point) notin 1 .. 2:
        return false
  true

proc campAt(map: MapData, position: Vec2, lakeside: bool): Camp {.raises: [].} =
  ## Faces a camp toward the lake or away from its nearest lane.
  var
    target = map.lake.nearest(position)
    distance = float32.high
  if not lakeside:
    for road in map.roads:
      let candidate = road.nearest(position)
      if lengthSq(candidate - position) < distance:
        distance = lengthSq(candidate - position)
        target = position * 2 - candidate
  Camp(position: position, facing: normalize(target - position),
    lakeside: lakeside)

proc reserveStem(map: MapData, camp: Camp): seq[Vec2] {.raises: [].} =
  ## Reserves a viable stem corridor before accepting a camp location.
  let
    cellSize = MapSize / RouteSize.float32
    reach = map.config.campRadius + map.config.stemLength
    facing = arctan2(camp.facing.y, camp.facing.x)
  for i in 0 ..< 25:
    let
      offset = ((i + 1) div 2 * (if i mod 2 == 0: 1 else: -1)).float32
      angle = facing + offset * 0.11'f
      candidate = camp.position + vec2(cos(angle), sin(angle)) * reach
      point = (floor(candidate / cellSize) + vec2(0.5'f)) * cellSize
    if point.x < 32 or point.y < 32 or
      point.x > MapSize - 32 or point.y > MapSize - 32 or
      not map.levelClearing(point, TrailWidth / 2 + cellSize * 0.72'f + 3):
        continue
    if length(map.lake.nearest(point) - point) <
      map.config.lakeWidth * 0.62'f + TrailWidth / 2 + 4:
        continue
    var open = true
    for other in map.camps:
      if length(point - other.position) < map.campRoadRadius(TrailWidth, 5):
          open = false
          break
    if not open:
      continue
    let stem = map.stemRoad(camp.position, point)
    if map.clearStem(stem):
      return stem.points

proc placeTrails(map: var MapData): bool {.raises: [].} =
  ## Connects one stem per camp to a separate network outside the clearings.
  map.stems.setLen(0)
  map.trails.setLen(0)
  map.towerTrails.setLen(0)
  map.lakeRoads.setLen(0)
  var grid = RouteGrid(cellSize: MapSize / RouteSize.float32)
  let
    phase = (map.config.seed mod 997).float32 * 0.037'f
    exclusion = map.campRoadRadius(TrailWidth, 5)
  for i in 0 ..< grid.blocked.len:
    let point = grid.point(i)
    grid.blocked[i] = point.x < 32 or point.y < 32 or
      point.x > MapSize - 32 or point.y > MapSize - 32
    for candidate in [point, point.opposite]:
      if map.castles[0].contains(candidate) or
        length(map.castles[0].nearest(candidate) - candidate) < TrailWidth:
          grid.blocked[i] = true
    if length(map.lake.nearest(point) - point) <
      map.config.lakeWidth * 0.62'f + TrailWidth / 2 + 4:
        grid.blocked[i] = true
    if lengthSq(map.cliffPoint(point) - point) <
      (TrailWidth / 2 + grid.cellSize * 0.72'f + 3) ^ 2:
        grid.blocked[i] = true
    for camp in map.camps:
      if lengthSq(camp.position - point) < exclusion ^ 2:
        grid.blocked[i] = true
    grid.costs[i] = 1 + int((
      sin(point.x * 0.011'f + phase) * cos(point.y * 0.013'f - phase) + 1
    ) * 2)
  grid.labelRegions()
  var
    candidates: seq[Ramp]
    portals: seq[array[2, Vec2]]
  for ramp in map.ramps:
    if grid.available(ramp.approaches[0]) and
      grid.available(ramp.approaches[1]):
        candidates.add(ramp)
        portals.add(ramp.approaches)
  var previous = vec2(-1000)
  for i in countup(2, map.highlands[0].high, 2):
    let
      edge = [map.highlands[0][i - 1], map.highlands[0][i]]
      center = (edge[0] + edge[1]) / 2
      tangent = normalize(edge[1] - edge[0])
      normal = vec2(-tangent.y, tangent.x)
    if length(center - previous) < 32:
      continue
    for half in [32'f, 40'f, 48'f, 56'f]:
      let ramp = initRamp(
        [center - normal * half, center + normal * half],
        edge,
        TrailWidth,
        map.config.mapSize
      )
      if not grid.available(ramp.approaches[0]) or
        not grid.available(ramp.approaches[1]) or
        not grid.available(ramp.approaches[0].opposite) or
        not grid.available(ramp.approaches[1].opposite) or
        not map.levelClearing(ramp.approaches[0], TrailWidth / 2 + 8) or
        not map.levelClearing(ramp.approaches[1], TrailWidth / 2 + 8) or
        map.groundHeight(ramp.approaches[0]) ==
          map.groundHeight(ramp.approaches[1]) or
        not map.avoidsCamps(ramp.approaches, TrailWidth):
          continue
      var dry = true
      for step in 0 .. 16:
        let point = mix(
          ramp.approaches[0],
          ramp.approaches[1],
          step.float32 / 16
        )
        if map.lakeBanks.contains(point) or
          length(map.lakeBanks.nearest(point) - point) < TrailWidth / 2 + 8:
            dry = false
      if not dry:
        continue
      candidates.add(ramp)
      candidates.add(ramp.reverse)
      portals.add(ramp.approaches)
      portals.add(ramp.reverse.approaches)
      previous = center
      break
  var reachable: array[RouteSize * RouteSize, bool]
  try:
    reachable = grid.connected(portals)
  except RouteError:
    return false
  var
    entrances: array[7, Vec2]
    stemRamps: seq[Ramp]
    visited: array[7, bool]
    connected: array[7, array[7, bool]]
  for i in 0 ..< entrances.len:
    let
      camp = map.camps[i * 2]
      reach = map.config.campRadius + map.config.stemLength
      target = camp.position + camp.facing * reach
    var
      best = float32.high
      stem: seq[Vec2]
      crossing: seq[Ramp]
    for j, blocked in grid.blocked:
      if blocked or not reachable[j]:
        continue
      let
        point = grid.point(j)
        delta = point - camp.position
        distance = length(delta)
        score = lengthSq(point - target)
      if score >= best or distance < reach - grid.cellSize or
        distance > reach + grid.cellSize or
        dot(normalize(delta), camp.facing) < 0.15'f:
          continue
      let path = map.stemRoad(camp.position, point)
      if not map.clearStem(path, i * 2):
        continue
      best = score
      stem = path.points
      crossing = path.ramps
    if stem.len == 0:
      return false
    entrances[i] = stem[^1]
    map.stems.add(stem)
    map.stems.add(stem.mirrored)
    for ramp in crossing:
      stemRamps.add(ramp)
      stemRamps.add(ramp.reverse)

  proc safeRoute(a, b: Vec2): seq[Vec2] {.raises: [].} =
    ## Removes invalid candidates instead of carving through a camp.
    try:
      result = grid.route(a, b, portals)
    except RouteError:
      return @[]

  proc connect(map: var MapData, a, b: int): bool {.raises: [].} =
    ## Adds a mirrored road between two stem tips if its corridor is clear.
    let path = safeRoute(entrances[a], entrances[b])
    if path.len < 2 or not map.avoidsCamps(path, TrailWidth):
      return false
    map.trails.add(path)
    map.trails.add(path.mirrored)
    true

  visited[0] = true
  for connection in 1 ..< entrances.len:
    var added = false
    while not added:
      var
        best = float32.high
        first, second = -1
      for i in 0 ..< entrances.len:
        for j in 0 ..< entrances.len:
          if visited[i] and not visited[j] and not connected[i][j]:
            let distance = lengthSq(entrances[i] - entrances[j])
            if distance < best:
              best = distance
              first = i
              second = j
      if first < 0:
        return false
      connected[first][second] = true
      connected[second][first] = true
      added = map.connect(first, second)
      if added:
        visited[second] = true
  var branches = initRand(map.config.seed xor 0x6B21)
  # Give both outer lane pairs a jungle entrance at a randomly chosen tower.
  let branchCount = (if map.config.jungleRoads > 36: 4 else: 3)
  for i in 0 ..< branchCount:
    let toTower = i < branchCount - 1
    var path: seq[Vec2]
    if toTower:
      var choices = [[0, 2], [4, 6], [8, 10]][i]
      if branches.rand(1) == 1:
        swap(choices[0], choices[1])
      for index in choices:
        let target = map.towers[index].position
        if not grid.available(target):
          continue
        var
          source = entrances[0]
          closest = float32.high
        for entrance in entrances:
          let distance = lengthSq(entrance - target)
          if distance < closest:
            closest = distance
            source = entrance
        path = safeRoute(source, target)
        if path.len < 2:
          continue
        path.add(target)
        if map.avoidsCamps(path, TrailWidth):
          break
        path.setLen(0)
    else:
      let target = map.fortRoads[0].nearest(entrances[6])
      path = safeRoute(entrances[6], target)
    if path.len < 2 or not map.avoidsCamps(path, TrailWidth):
      return false
    if toTower:
      map.towerTrails.add(map.trails.len)
      map.towerTrails.add(map.trails.len + 1)
    map.trails.add(path)
    map.trails.add(path.mirrored)
  while map.trails.len < map.config.jungleRoads:
    var
      best = float32.high
      first, second = -1
    for i in 0 ..< entrances.len:
      for j in i + 1 ..< entrances.len:
        let distance = lengthSq(entrances[i] - entrances[j])
        if not connected[i][j] and distance < best:
          best = distance
          first = i
          second = j
    if first < 0:
      return false
    connected[first][second] = true
    connected[second][first] = true
    discard map.connect(first, second)

  var crossingIndices: seq[int]
  for crossing in 0 ..< map.config.lakeCrossings div 2:
    var added = false
    for attempt in 0 ..< 130:
      let
        offset = (attempt + 1) div 2 * (if attempt mod 2 == 0: 1 else: -1)
        index = clamp([40, 22, 59][crossing] + offset, 8, 72)
        center = map.lake[index]
        tangent = normalize(map.lake[index + 1] - map.lake[index - 1])
        normal = vec2(-tangent.y, tangent.x)
        distance = map.config.lakeWidth * 0.62'f + TrailWidth + 18
        shores = [center - normal * distance, center + normal * distance]
      var duplicate = false
      for used in crossingIndices:
        if abs(index - used) < 6:
          duplicate = true
      if duplicate:
        continue
      var camps: array[2, int]
      for side in 0 ..< 2:
        var best = float32.high
        for i, stem in map.stems:
          let direction = (if side == 0: -1'f else: 1'f)
          if dot(stem[^1] - center, normal) * direction <= 0:
            continue
          let score = lengthSq(stem[^1] - shores[side])
          if score < best:
            best = score
            camps[side] = i
      let
        first = safeRoute(map.stems[camps[0]][^1], shores[0])
        second = safeRoute(shores[1], map.stems[camps[1]][^1])
      if first.len < 2 or second.len < 2:
        continue
      let path = first & @[center] & second
      if map.avoidsCamps(path, TrailWidth) and
        map.clearCliffs(path, TrailWidth, candidates):
          map.lakeRoads.add(path)
          map.lakeRoads.add(path.mirrored)
          crossingIndices.add(index)
          added = true
          break
    if not added:
      return false
  map.ramps.add(stemRamps)
  for ramp in candidates:
    if ramp.width != TrailWidth:
      continue
    var used = false
    for path in map.trails & map.lakeRoads:
      for i in 1 ..< path.len:
        if (lengthSq(path[i - 1] - ramp.approaches[0]) < 0.01'f and
          lengthSq(path[i] - ramp.approaches[1]) < 0.01'f) or
          (lengthSq(path[i - 1] - ramp.approaches[1]) < 0.01'f and
          lengthSq(path[i] - ramp.approaches[0]) < 0.01'f):
            used = true
    if used:
      map.ramps.add(ramp)
  true

proc placeBarracks(map: var MapData) {.raises: [MapgenError].} =
  ## Fits aligned pairs across each road with equal routes to a shared entry.
  type Site = object
    position, join: Vec2
  var
    roads: array[3, seq[Vec2]]
    sites: array[3, seq[array[2, Site]]]
    chosen: array[3, array[2, Site]]
    order: array[3, int]
  proc gather(map: MapData, extraSteps, depthSteps: int) {.raises: [].} =
    ## Searches more gate shoulders only when the original sites cannot fit.
    for road in roads.mitems:
      road.setLen(0)
    for candidates in sites.mitems:
      candidates.setLen(0)
    for lane in 0 ..< 3:
      if lane == 1:
        for i in countdown(map.roads[lane].high, 0):
          roads[lane].add(map.roads[lane][i])
      else:
        roads[lane] = map.roads[lane]
      let road = roads[lane]
      var gate = 1
      while gate < road.high and map.castles[0].contains(road[gate]):
        gate.inc
      let
        outward = normalize(road[gate] - road[gate - 1])
        normal = vec2(-outward.y, outward.x)
      for depth in 0 ..< depthSteps:
        let center = road.nearest(
          road[gate] - outward * (24 + depth * 6).float32
        )
        for extra in 0 ..< extraSteps:
          var
            pair: array[2, Site]
            valid = true
          for flank in 0 ..< 2:
            let side = (if flank == 0: -1'f else: 1'f)
            let candidate = center + normal * side * (
              map.config.roadWidth / 2 + BarrackRadius + 3 + extra.float32 * 4
            )
            for i in 0 ..< 12:
              let
                angle = i.float32 * PI.float32 / 6
                sample = candidate + vec2(cos(angle), sin(angle)) *
                  (BarrackRadius + 3)
              if not map.castles[0].contains(sample):
                valid = false
            for walls in [map.keepWalls[0], map.spawnWalls[0]]:
              for wall in walls:
                if length(wall.points.nearest(candidate) - candidate) <
                  wall.width / 2 + BarrackRadius + 2:
                    valid = false
            if length(candidate - map.forts[0]) < BarrackRadius + 30:
              valid = false
            for tower in map.towers:
              if length(candidate - tower.position) < BarrackRadius + 18:
                valid = false
            pair[flank] = Site(position: candidate, join: center)
          if valid:
            sites[lane].add(pair)
    # Fit whole pairs so neither barracks can drift along the road independently.
    for i in 0 ..< order.len:
      order[i] = i
    for i in 0 ..< order.len:
      for j in i + 1 ..< order.len:
        if sites[order[j]].len < sites[order[i]].len:
          swap(order[i], order[j])
  var attempts = 0
  proc fit(depth: int): bool {.raises: [].} =
    ## Searches the small set of gate sites with bounded backtracking.
    if depth == order.len:
      return true
    let index = order[depth]
    for pair in sites[index]:
      attempts.inc
      if attempts > 100_000:
        return false
      var valid = true
      for i in 0 ..< depth:
        for site in pair:
          for other in chosen[order[i]]:
            if length(site.position - other.position) < BarrackRadius * 2 + 3:
              valid = false
      if valid:
        chosen[index] = pair
        if fit(depth + 1):
          return true
    false
  gather(map, 6, 15)
  var fitted = fit(0)
  if not fitted:
    attempts = 0
    gather(map, 12, 30)
    fitted = fit(0)
  if not fitted:
    raise newException(
      MapgenError,
      "Could not fit barracks inside the gates for seed " & $map.config.seed
    )
  for i in 0 ..< 6:
    let
      lane = i div 2
      site = chosen[lane][i mod 2]
      road = roads[lane]
      midpoint = road.along(0.5'f)
    var
      first, last: int
      nearestJoin, nearestMiddle = float32.high
    for j in 0 ..< road.high:
      let
        segment = [road[j], road[j + 1]]
        distance = lengthSq(segment.nearest(site.join) - site.join)
        middle = lengthSq(segment.nearest(midpoint) - midpoint)
      if distance < nearestJoin:
        nearestJoin = distance
        first = j + 1
      if middle < nearestMiddle:
        nearestMiddle = middle
        last = j
    var barrack = Barrack(
      position: site.position,
      spawn: site.position + normalize(site.join - site.position) *
        BarrackRadius,
      team: Southwest,
      lane: lane
    )
    barrack.route = @[barrack.spawn, site.join]
    for j in first .. last:
      barrack.route.add(road[j])
    barrack.route.add(midpoint)
    for j in 1 ..< barrack.route.len:
      barrack.distance += length(barrack.route[j] - barrack.route[j - 1])
    map.barracks.add(barrack)
    map.barracks.add(Barrack(
      position: site.position.opposite,
      spawn: barrack.spawn.opposite,
      team: Northeast,
      lane: (if lane == 2: 2 else: 1 - lane),
      route: barrack.route.mirrored,
      distance: barrack.distance
    ))

proc generateMap*(config: MapConfig): MapData {.raises: [MapgenError].} =
  ## Generates one seeded layout and rotates every paired feature exactly.
  if config.highSize notin 450.0'f .. 570.0'f or
    config.castleSize notin 210.0'f .. 500.0'f or
    config.roadWidth notin 26.0'f .. 62.0'f or
    config.roadWobble notin 0.0'f .. 80.0'f or
    config.lakeWidth notin 42.0'f .. 120.0'f or
    config.lakeWobble notin 0.0'f .. 80.0'f or
    config.campRadius notin 20.0'f .. 40.0'f or
    config.stemLength notin 30.0'f .. 80.0'f or
    config.jungleRoads notin 18 .. 50 or config.jungleRoads mod 2 != 0 or
    config.campScatter notin 0.0'f .. 60.0'f or
    config.lakeCrossings notin 0 .. 6 or config.lakeCrossings mod 2 != 0:
      raise newException(MapgenError, "Map controls are outside their limits.")
  result.config = config
  var rng = initRand(config.seed)
  let
    high = config.highSize
    edge = smooth([
      vec2(high, 0), vec2(high - 5, 145), vec2(high, 250),
      vec2(425, 320), vec2(320, 430), vec2(250, high),
      vec2(120, high - 5), vec2(0, high)
    ])
  var borders = initRand(config.seed xor 0x51D3)
  let
    phase = borders.rand(0.0 .. PI * 2).float32
    amplitude = borders.rand(12.0 .. 17.0).float32
  result.highlands[0].add(vec2(0, 0))
  for i, point in edge:
    let
      t = i.float32 / edge.high.float32
      tangent = normalize(edge[min(edge.high, i + 1)] - edge[max(0, i - 1)])
      normal = vec2(-tangent.y, tangent.x)
      wave = (
        sin(t * PI.float32 * 6 + phase) +
        sin(t * PI.float32 * 12 + phase * 0.7'f) * 0.3'f
      ) * amplitude * sin(t * PI.float32) ^ 2
    result.highlands[0].add(point + normal * wave)
  result.highlands[1] = result.highlands[0].mirrored
  result.castles[0] = castle(config.castleSize)
  result.keeps[0] = castle(config.castleSize - 16)
  result.spawns[0] = castle(config.castleSize * 0.25'f)
  result.castles[1] = result.castles[0].mirrored
  result.keeps[1] = result.keeps[0].mirrored
  result.spawns[1] = result.spawns[0].mirrored
  result.forts = [vec2(94, 906), vec2(906, 94)]

  let
    westBow = rng.rand(-0.5 .. 1.0).float32 * config.roadWobble
    northBow = rng.rand(-0.5 .. 1.0).float32 * config.roadWobble
    gate = MapSize - config.castleSize - 20
  var outer = @[vec2(112, 888), vec2(64, gate)]
  for point in [
    vec2(82 + westBow * 0.7'f, 670), vec2(82 + westBow, 450),
    vec2(82 + westBow * 0.5'f, 250)
  ]:
    if point.y < gate - 24:
      outer.add(point)
  outer.add(vec2(105, 105))
  for point in [
    vec2(250, 82 + northBow * 0.5'f), vec2(450, 82 + northBow),
    vec2(670, 82 + northBow * 0.7'f)
  ]:
    if point.x < gate - 24:
      outer.add(point)
  outer.add(vec2(gate, 64))
  outer.add(vec2(888, 112))
  result.roads[0] = smooth(outer)
  # Reserve enough edge space for the forest even at maximum road wobble.
  let roadMargin = config.roadWidth / 2 + TreePadding + 20
  for point in result.roads[0].mitems:
    point.x = clamp(point.x, roadMargin, MapSize - roadMargin)
    point.y = clamp(point.y, roadMargin, MapSize - roadMargin)
  result.roads[1] = result.roads[0].mirrored
  let roadPhase = rng.rand(0.75 .. 1.0).float32
  for i in 0 .. 64:
    let
      t = i.float32 / 128
      wave = sin(t * PI.float32 * 2) * sin(t * PI.float32) ^ 2 *
        config.roadWobble * roadPhase
    result.roads[2].add(vec2(112 + 776 * t + wave, 888 - 776 * t + wave))
  for i in countdown(63, 0):
    result.roads[2].add(result.roads[2][i].opposite)
  let lakePhase = rng.rand(0.75 .. 1.0).float32
  var
    widths: seq[float32]
    leftBank, rightBank: seq[Vec2]
  for i in 0 .. 80:
    let
      t = i.float32 / 160
      wave = (
        sin(t * PI.float32 * 4) + sin(t * PI.float32 * 8) * 0.3'f
      ) * config.lakeWobble * lakePhase
    result.lake.add(vec2(266 + 468 * t + wave, 266 + 468 * t - wave))
    widths.add(config.lakeWidth / 2 * (
      1 + 0.13'f * cos(t * PI.float32 * 8)
    ))
  for i in countdown(79, 0):
    result.lake.add(result.lake[i].opposite)
    widths.add(widths[i])
  for i, point in result.lake:
    let
      tangent = normalize(
        result.lake[min(result.lake.high, i + 1)] -
          result.lake[max(0, i - 1)]
      )
      normal = vec2(-tangent.y, tangent.x)
      endTaper = min(1'f, min(i, result.lake.high - i).float32 / 7)
      width = widths[i] * sqrt(max(0'f, endTaper * (2 - endTaper)))
    leftBank.add(point + normal * width)
    rightBank.add(point - normal * width)
  result.lakeBanks = leftBank
  for i in countdown(rightBank.high, 0):
    result.lakeBanks.add(rightBank[i])

  result.roads[0] = result.rampRoad(result.roads[0], config.roadWidth)
  result.roads[1] = result.roads[0].mirrored
  let
    size = config.castleSize
    outside = 40.0'f
    westGate = result.roads[0].nearest(vec2(64, MapSize - size - outside))
    southGate = result.roads[1].nearest(vec2(size + outside, MapSize - 64))
  result.fortRoads[0] = smooth([
    westGate,
    vec2(max(size * size.shoulder + 16, westGate.x + 32),
      MapSize - size - outside),
    vec2(size + outside,
      min(MapSize - size * size.shoulder - 16, southGate.y - 32)),
    southGate
  ])
  result.fortRoads[0] = result.rampRoad(result.fortRoads[0], FortRoadWidth)
  result.fortRoads[1] = result.fortRoads[0].mirrored
  result.placeWalls()

  # Extend the river's palette split with matching waves beyond both ends.
  let borderWidth = borders.rand(18.0 .. 24.0).float32
  var extension: seq[Vec2]
  for i in 0 .. 32:
    let
      t = i.float32 / 32
      diagonal = result.lake[0].x * t
      wave = sin(t * PI.float32 * 2) * sin(t * PI.float32) ^ 2 * borderWidth
    extension.add(vec2(diagonal + wave, diagonal - wave))
  result.border = extension
  for i in 1 ..< result.lake.len:
    result.border.add(result.lake[i])
  for i in countdown(extension.high - 1, 0):
    result.border.add(extension[i].opposite)

  # West towers defend close to home; north towers spread toward the enemy.
  # Their rotated counterparts give east and south the same lane balance.
  for i, fraction in [0.1375'f, 0.30'f, 0.54'f, 0.81'f]:
    let
      team = (if i < 2: Southwest else: Northeast)
      position = result.towerPosition(result.roads[0], fraction, team)
    result.towers.add(Tower(position: position, team: team))
    result.towers.add(Tower(
      position: position.opposite,
      team: Team(1 - team.ord)
    ))
  for fraction in [0.21'f, 0.37'f]:
    let position = result.towerPosition(result.roads[2], fraction, Southwest)
    result.towers.add(Tower(position: position, team: Southwest))
    result.towers.add(Tower(position: position.opposite, team: Northeast))
  let
    keepSize = config.castleSize - 38
    front = keepSize * (1 + keepSize.shoulder) * (0.64'f / 1.46'f)
  for position in [
    vec2(36, MapSize - keepSize),
    vec2(front, MapSize - front),
    vec2(keepSize, MapSize - 36)
  ]:
    result.towers.add(Tower(position: position, team: Southwest))
    result.towers.add(Tower(position: position.opposite, team: Northeast))

  # Two level-three guards flank each god and leave the center approach open.
  for offset in [vec2(-16, -48), vec2(48, 16)]:
    let position = result.forts[0] + offset
    result.towers.add(Tower(
      position: position, team: Southwest, guardsGod: true
    ))
    result.towers.add(Tower(
      position: position.opposite, team: Northeast, guardsGod: true
    ))

  result.placeBarracks()

  let anchors = [
    vec2(215, 222), vec2(391, 209), vec2(213, 406),
    vec2(213, 607), vec2(326, 783), vec2(456, 750),
    vec2(492, 305)
  ]
  var sites: array[7, seq[Camp]]
  for i, original in anchors:
    var anchor = original
    if i in 3 .. 5:
      let expansion = max(0'f, config.castleSize - 280) * 0.4'f
      anchor += vec2(expansion, -expansion)
      anchor.x = min(470'f, anchor.x)
    for j in 0 ..< 1600:
      var candidate = anchor + vec2(
        rng.rand(-1.0 .. 1.0).float32,
        rng.rand(-1.0 .. 1.0).float32
      ) * config.campScatter
      if j >= 40:
        if i == anchors.high:
          candidate = anchor + vec2(
            rng.rand(-1.0 .. 1.0).float32,
            rng.rand(-1.0 .. 1.0).float32
          ) * (80 + config.campRadius + CampPadding + CampForest)
        else:
          candidate = vec2(
            rng.rand(140.0 .. 490.0).float32,
            rng.rand(140.0 .. 490.0).float32
          )
          if i in 3 .. 5:
            candidate.y = rng.rand(510.0 .. 850.0).float32
      if result.campClearance(candidate) < config.campRadius + CampSeparation:
        continue
      if config.campsTouchRoads:
        var onRoad = false
        for road in result.roads:
          if length(road.nearest(candidate) - candidate) <
            result.campRoadRadius(config.roadWidth):
              onRoad = true
        for road in result.fortRoads:
          if length(road.nearest(candidate) - candidate) <
            result.campRoadRadius(FortRoadWidth):
              onRoad = true
        if onRoad:
          continue
      if i == anchors.high and config.castleSize > 350 and candidate.x > 490:
        continue
      if not result.levelClearing(
        candidate, config.campRadius + CampPadding +
          MapSize / config.mapSize.float32
      ):
        continue
      let camp = result.campAt(candidate, i == anchors.high)
      if camp.lakeside:
        var
          distance = float32.high
          roadDirection: Vec2
        for road in result.roads:
          let delta = road.nearest(candidate) - candidate
          if lengthSq(delta) < distance:
            distance = lengthSq(delta)
            roadDirection = normalize(delta)
        if dot(camp.facing, roadDirection) > -0.1'f:
          continue
      sites[i].add(camp)
      if sites[i].len >= 96:
        break
    if sites[i].len == 0:
      raise newException(MapgenError, "No room for camp " & $(i + 1) & ".")
  var order = [6, 0, 1, 2, 3, 4, 5]
  for i in 0 ..< order.len:
    for j in i + 1 ..< order.len:
      if sites[order[j]].len < sites[order[i]].len:
        swap(order[i], order[j])

  var searches = 0
  proc placeCamps(map: var MapData, attempt: int): bool {.raises: [].} =
    ## Fits camp circles and their forest rings with bounded backtracking.
    var nodes = 0
    proc fit(map: var MapData, depth: int): bool {.raises: [].} =
      ## Places the most constrained remaining camp before filling open sites.
      if depth == order.len:
        return true
      let choices = sites[order[depth]]
      for j in 0 ..< choices.len:
        nodes.inc
        searches.inc
        if nodes > 12_000 or searches > 200_000:
          return false
        let camp = choices[(j + attempt * (depth * 2 + 11)) mod choices.len]
        var valid = true
        for other in map.camps:
          if length(camp.position - other.position) <
            map.config.campRadius * 2 + CampSeparation:
              valid = false
              break
        if not valid:
          continue
        for stem in map.stems:
          if length(stem.nearest(camp.position) - camp.position) <
            map.config.campRadius + CampSeparation + StemWidth / 2:
              valid = false
              break
        if not valid:
          continue
        let stem = map.reserveStem(camp)
        if stem.len < 2:
          continue
        map.camps.add(camp)
        map.camps.add(Camp(
          position: camp.position.opposite,
          facing: -camp.facing,
          lakeside: camp.lakeside
        ))
        map.stems.add(stem)
        map.stems.add(stem.mirrored)
        if fit(map, depth + 1):
          return true
        map.camps.setLen(depth * 2)
        map.stems.setLen(depth * 2)
      false
    if not fit(map, 0):
      return false
    let
      camps = map.camps
      stems = map.stems
    map.camps.setLen(0)
    map.stems.setLen(0)
    for i in [6, 0, 1, 2, 3, 4, 5]:
      for j, index in order:
        if index == i:
          map.camps.add(camps[j * 2])
          map.camps.add(camps[j * 2 + 1])
          map.stems.add(stems[j * 2])
          map.stems.add(stems[j * 2 + 1])
    true

  for attempt in 0 ..< 128:
    result.camps.setLen(0)
    result.stems.setLen(0)
    if placeCamps(result, attempt):
      if result.placeTrails():
        return
  raise newException(
    MapgenError,
    "No room for camps and forest. Reduce castle, lake, or camp size."
  )
