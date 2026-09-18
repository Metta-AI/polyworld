import
  std/math,
  chroma, vmath,
  maps

proc triangle(
  mesh: var seq[MapTriangle],
  a, b, c: Vec2,
  tint: ColorRGBX
) {.raises: [].} =
  ## Appends a solid triangle to the cached map mesh.
  mesh.add(MapTriangle(positions: [a, b, c], tint: tint))

proc quad(
  mesh: var seq[MapTriangle],
  a, b, c, d: Vec2,
  tint: ColorRGBX
) {.raises: [].} =
  ## Splits an ordered quadrilateral into two triangles.
  mesh.triangle(a, b, c, tint)
  mesh.triangle(a, c, d, tint)

proc cross(a, b, c: Vec2): float32 {.raises: [].} =
  ## Returns the signed area of an oriented triangle.
  let
    ab = b - a
    ac = c - a
  ab.x * ac.y - ab.y * ac.x

proc polygon(
  mesh: var seq[MapTriangle],
  points: openArray[Vec2],
  tint: ColorRGBX
) {.raises: [MapgenError].} =
  ## Triangulates a simple concave polygon by removing convex ears.
  var
    indices: seq[int]
    area = 0.0'f
  for i, point in points:
    let next = points[(i + 1) mod points.len]
    area += point.x * next.y - next.x * point.y
    indices.add(i)
  let winding = (if area < 0: -1'f else: 1'f)
  while indices.len > 2:
    var clipped = false
    for i in 0 ..< indices.len:
      let
        previous = (i + indices.len - 1) mod indices.len
        next = (i + 1) mod indices.len
        a = points[indices[previous]]
        b = points[indices[i]]
        c = points[indices[next]]
      if cross(a, b, c) * winding < 0.0001'f:
        continue
      var occupied = false
      for j, index in indices:
        if j == previous or j == i or j == next:
          continue
        let point = points[index]
        if cross(a, b, point) * winding >= 0 and
          cross(b, c, point) * winding >= 0 and
          cross(c, a, point) * winding >= 0:
            occupied = true
            break
      if not occupied:
        mesh.triangle(a, b, c, tint)
        indices.delete(i)
        clipped = true
        break
    if not clipped:
      raise newException(MapgenError, "Could not triangulate the terrain.")

proc disc(
  mesh: var seq[MapTriangle],
  center: Vec2,
  radius: float32,
  tint: ColorRGBX,
  segments = 40
) {.raises: [].} =
  ## Adds a circular marker with enough segments for the map view.
  for i in 0 ..< segments:
    let
      a = i.float32 * 2 * PI.float32 / segments.float32
      b = (i + 1).float32 * 2 * PI.float32 / segments.float32
    mesh.triangle(
      center,
      center + vec2(cos(a), sin(a)) * radius,
      center + vec2(cos(b), sin(b)) * radius,
      tint
    )

proc ribbon(
  mesh: var seq[MapTriangle],
  points: openArray[Vec2],
  width: float32,
  tint: ColorRGBX
) {.raises: [].} =
  ## Adds a continuous stroke with shared joins along a sampled curve.
  var previousLeft, previousRight: Vec2
  for i, point in points:
    let
      tangent = normalize(
        points[min(points.high, i + 1)] - points[max(0, i - 1)]
      )
      normal = vec2(-tangent.y, tangent.x) * width / 2
      left = point + normal
      right = point - normal
    if i > 0:
      mesh.quad(previousLeft, previousRight, right, left, tint)
    previousLeft = left
    previousRight = right

proc stroke(
  mesh: var seq[MapTriangle],
  points: openArray[Vec2],
  width: float32,
  tint: ColorRGBX
) {.raises: [].} =
  ## Keeps tight trail bends and reversed joins connected with round caps.
  for i in 1 ..< points.len:
    let delta = points[i] - points[i - 1]
    if lengthSq(delta) < 0.0001'f:
      continue
    let normal = normalize(vec2(-delta.y, delta.x)) * width / 2
    mesh.quad(
      points[i - 1] + normal,
      points[i - 1] - normal,
      points[i] - normal,
      points[i] + normal,
      tint
    )
  for point in points:
    mesh.disc(point, width / 2, tint, 8)

proc square(
  mesh: var seq[MapTriangle],
  center: Vec2,
  radius: float32,
  tint: ColorRGBX
) {.raises: [].} =
  ## Adds a square marker centered at the given position.
  mesh.quad(
    center + vec2(-radius, -radius),
    center + vec2(radius, -radius),
    center + vec2(radius, radius),
    center + vec2(-radius, radius),
    tint
  )

proc buildMarkers*(map: MapData): seq[MapTriangle] =
  ## Builds the tower and fort overlays above the tile grid.
  for tower in map.towers:
    result.disc(tower.position, 15, rgbx(245, 238, 214, 255))
    result.disc(tower.position, 12, TeamColors[tower.team.ord])
    result.disc(tower.position, 4, rgbx(245, 238, 214, 255))
  for i, position in map.forts:
    result.square(position, 26, rgbx(245, 238, 214, 255))
    result.square(position, 23, TeamColors[i])
    result.square(position, 9, rgbx(245, 238, 214, 255))

proc buildMesh*(map: MapData, grid = false): seq[MapTriangle] =
  ## Caches terrain and marker triangles without rasterizing any images.
  let config = map.config
  result.square(vec2(500, 500), 500, LowColor)
  for points in map.highlands:
    result.polygon(points, HighColor)
    result.ribbon(points, 3, rgbx(157, 177, 112, 255))
  if grid:
    for i in 1 ..< 20:
      let at = i.float32 * 50
      result.ribbon(
        [vec2(at, 0), vec2(at, MapSize)], 0.7, rgbx(92, 143, 84, 255)
      )
      result.ribbon(
        [vec2(0, at), vec2(MapSize, at)], 0.7, rgbx(92, 143, 84, 255)
      )
  for road in map.roads:
    result.ribbon(road, config.roadWidth + GrassMargin * 2, MarginColor)
  for road in map.fortRoads:
    result.stroke(road, FortRoadWidth + GrassMargin * 2, MarginColor)
  for stem in map.stems:
    result.stroke(stem, StemWidth, TrailColor)
  for trail in map.trails:
    result.stroke(trail, TrailWidth, TrailColor)
  for road in map.lakeRoads:
    result.stroke(road, TrailWidth, TrailColor)
  for road in map.roads:
    result.ribbon(road, config.roadWidth + 4, rgbx(134, 124, 74, 255))
    result.ribbon(road, config.roadWidth, RoadColor)
  for road in map.fortRoads:
    result.stroke(road, FortRoadWidth, RoadColor)
  for ramp in map.ramps:
    result.ribbon(ramp.points, ramp.width, RampColor)
  let bankSize = map.lakeBanks.len div 2
  result.ribbon(map.lakeBanks, 10, rgbx(194, 200, 148, 255))
  for i in 1 ..< bankSize:
    result.quad(
      map.lakeBanks[i - 1],
      map.lakeBanks[map.lakeBanks.high - i + 1],
      map.lakeBanks[map.lakeBanks.high - i],
      map.lakeBanks[i],
      WaterColor
    )
  result.ribbon(map.lake, 1.3, rgbx(110, 187, 207, 255))
  for i in 0 ..< 2:
    result.polygon(map.castles[i], CastleColor)
    result.polygon(map.keeps[i], KeepColor)
    result.polygon(map.spawns[i], SpawnColor)
  for walls in [map.keepWalls, map.spawnWalls]:
    for team in walls:
      for wall in team:
        result.ribbon(wall.points, wall.width, WallColor)
  result.add(buildMarkers(map))
