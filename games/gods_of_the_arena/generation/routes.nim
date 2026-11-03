import
  std/[algorithm, heapqueue, math],
  vmath

const RouteSize* = 64

type
  RouteError* = object of CatchableError
  RouteGrid* = object
    cellSize*: float32
    blocked*: array[RouteSize * RouteSize, bool]
    costs*: array[RouteSize * RouteSize, int]
    regions*: array[RouteSize * RouteSize, int]

proc point*(grid: RouteGrid, index: int): Vec2 {.raises: [].} =
  ## Returns the world position at a routing cell's center.
  vec2(
    (index mod RouteSize).float32 + 0.5'f,
    (index div RouteSize).float32 + 0.5'f
  ) * grid.cellSize

proc available*(grid: RouteGrid, position: Vec2): bool {.raises: [].} =
  ## Checks whether a world point occupies an open routing cell.
  let
    x = floor(position.x / grid.cellSize).int
    y = floor(position.y / grid.cellSize).int
  x in 0 ..< RouteSize and y in 0 ..< RouteSize and
    not grid.blocked[y * RouteSize + x]

proc clear*(grid: RouteGrid, a, b: Vec2): bool {.raises: [].} =
  ## Checks the complete segment before simplifying or rounding a route.
  let steps = max(1, ceil(length(b - a) / (grid.cellSize / 4)).int)
  for i in 0 .. steps:
    if not grid.available(mix(a, b, i.float32 / steps.float32)):
      return false
  true

proc closest(grid: RouteGrid, position: Vec2): int {.raises: [RouteError].} =
  ## Finds the nearest open cell for a camp entrance or lane connection.
  if grid.available(position):
    return (position.y / grid.cellSize).int * RouteSize +
      (position.x / grid.cellSize).int
  var distance = float32.high
  result = -1
  for i, blocked in grid.blocked:
    if not blocked:
      let candidate = lengthSq(grid.point(i) - position)
      if candidate < distance:
        distance = candidate
        result = i
  if result < 0:
    raise newException(RouteError, "The jungle has no open routing cells.")

proc labelRegions*(grid: var RouteGrid) {.raises: [].} =
  ## Labels the open regions separated by obstacles and cliff buffers.
  var region = 0
  for start, blocked in grid.blocked:
    if blocked or grid.regions[start] != 0:
      continue
    region.inc
    var
      queue = @[start.int]
      head = 0
    grid.regions[start] = region
    while head < queue.len:
      let
        index = queue[head]
        x = index mod RouteSize
        y = index div RouteSize
      head.inc
      for direction in 0 ..< 4:
        let
          nx = x + [0, 1, 0, -1][direction]
          ny = y + [-1, 0, 1, 0][direction]
        if nx notin 0 ..< RouteSize or ny notin 0 ..< RouteSize:
          continue
        let next = ny * RouteSize + nx
        if grid.regions[next] == 0 and not grid.blocked[next]:
          grid.regions[next] = region
          queue.add(next)

proc region(grid: RouteGrid, point: Vec2): int {.raises: [RouteError].} =
  ## Finds the open region containing a route endpoint.
  grid.regions[grid.closest(point)]

proc connected*(
  grid: RouteGrid,
  portals: openArray[array[2, Vec2]]
): array[RouteSize * RouteSize, bool] {.raises: [RouteError].} =
  ## Finds the largest region group connected by the designated ramps.
  var parents, sizes: array[RouteSize * RouteSize + 1, int]
  for i in 0 ..< parents.len:
    parents[i] = i
  proc root(region: int): int {.raises: [].} =
    ## Resolves a region's ramp-connected group.
    result = region
    while parents[result] != result:
      result = parents[result]
  for portal in portals:
    let
      a = root(grid.region(portal[0]))
      b = root(grid.region(portal[1]))
    parents[b] = a
  var largest = 0
  for region in grid.regions:
    if region != 0:
      let group = root(region)
      sizes[group].inc
      if sizes[group] > sizes[largest]:
        largest = group
  for i, region in grid.regions:
    result[i] = region != 0 and root(region) == largest

proc rounded(grid: RouteGrid, points: seq[Vec2]): seq[Vec2] {.raises: [].} =
  ## Replaces safe path corners with tangent quadratic arcs.
  if points.len == 2 and length(points[1] - points[0]) > grid.cellSize:
    let
      delta = points[1] - points[0]
      normal = normalize(vec2(-delta.y, delta.x))
      bend = min(48'f, length(delta) * 0.18'f)
    for side in [1'f, -1'f]:
      let control = (points[0] + points[1]) / 2 + normal * bend * side
      var
        curve: seq[Vec2]
        valid = true
      for i in 0 .. 24:
        let
          t = i.float32 / 24
          point = points[0] * (1 - t) ^ 2 +
            control * (2 * t * (1 - t)) + points[1] * t ^ 2
        if i > 0 and not grid.clear(curve[^1], point):
          valid = false
        curve.add(point)
      if valid:
        return curve
  if points.len < 3:
    return points
  result.add(points[0])
  for i in 1 ..< points.high:
    let
      corner = points[i]
      incoming = points[i - 1] - corner
      outgoing = points[i + 1] - corner
    var radius = min(60'f, min(length(incoming), length(outgoing)) * 0.4'f)
    var curve: seq[Vec2]
    for attempt in 0 ..< 4:
      curve.setLen(0)
      let
        start = corner + normalize(incoming) * radius
        finish = corner + normalize(outgoing) * radius
      var valid = true
      for j in 0 .. 12:
        let
          t = j.float32 / 12
          position = start * (1 - t) ^ 2 +
            corner * (2 * (1 - t) * t) + finish * t ^ 2
        if j > 0 and not grid.clear(curve[^1], position):
          valid = false
        curve.add(position)
      if valid:
        break
      radius *= 0.5'f
      curve.setLen(0)
    if curve.len > 0:
      result.add(curve)
    else:
      result.add(corner)
  result.add(points[^1])

proc route*(grid: RouteGrid, start, finish: Vec2): seq[Vec2] =
  ## Finds a bounded terrain-aware path, then removes grid stair steps.
  let
    first = grid.closest(start)
    last = grid.closest(finish)
  var
    distances: array[RouteSize * RouteSize, int]
    parents: array[RouteSize * RouteSize, int]
    queue: HeapQueue[tuple[score, cost, index: int]]
  for i in 0 ..< distances.len:
    distances[i] = int.high
    parents[i] = -1
  distances[first] = 0
  queue.push((0, 0, first))
  while queue.len > 0:
    let current = queue.pop()
    if current.cost != distances[current.index]:
      continue
    if current.index == last:
      break
    let
      x = current.index mod RouteSize
      y = current.index div RouteSize
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        let
          nx = x + dx
          ny = y + dy
        if (dx == 0 and dy == 0) or
          nx notin 0 ..< RouteSize or ny notin 0 ..< RouteSize:
            continue
        let index = ny * RouteSize + nx
        if grid.blocked[index] or grid.blocked[y * RouteSize + nx] or
          grid.blocked[ny * RouteSize + x]:
            continue
        let
          cost = current.cost + grid.costs[index] *
            (if dx != 0 and dy != 0: 14 else: 10)
          hx = abs(nx - last mod RouteSize)
          hy = abs(ny - last div RouteSize)
          estimate = min(hx, hy) * 14 + abs(hx - hy) * 10
        if cost < distances[index]:
          distances[index] = cost
          parents[index] = current.index
          queue.push((cost + estimate, cost, index))
  if distances[last] == int.high:
    raise newException(RouteError, "Could not connect the jungle clearings.")
  var
    path: seq[Vec2]
    index = last
  while index >= 0:
    path.add(grid.point(index))
    index = parents[index]
  path.reverse()
  if lengthSq(start - path[0]) > 0.01'f and grid.clear(start, path[0]):
    path.insert(start, 0)
  if lengthSq(path[^1] - finish) > 0.01'f and grid.clear(path[^1], finish):
    path.add(finish)
  var
    simplified = @[path[0]]
    i = 0
  while i < path.high:
    var next = path.high
    while next > i + 1 and not grid.clear(path[i], path[next]):
      next.dec
    simplified.add(path[next])
    i = next
  grid.rounded(simplified)

proc route*(
  grid: RouteGrid,
  start, finish: Vec2,
  portals: openArray[array[2, Vec2]]
): seq[Vec2] {.raises: [RouteError].} =
  ## Routes within each elevation region and crosses only explicit ramps.
  if grid.region(start) == grid.region(finish):
    return grid.route(start, finish)
  var nodes = @[start, finish]
  for portal in portals:
    nodes.add(portal)
  var
    regions = newSeq[int](nodes.len)
    distances = newSeq[float32](nodes.len)
    parents = newSeq[int](nodes.len)
    visited = newSeq[bool](nodes.len)
  for i, point in nodes:
    regions[i] = grid.region(point)
    distances[i] = float32.high
    parents[i] = -1
  distances[0] = 0
  for iteration in 0 ..< nodes.len:
    var
      nearest = float32.high
      current = -1
    for i, distance in distances:
      if not visited[i] and distance < nearest:
        current = i
        nearest = distance
    if current < 0 or current == 1:
      break
    visited[current] = true
    for next in 0 ..< nodes.len:
      let crossing = current >= 2 and next == (current xor 1)
      if regions[current] != regions[next] and not crossing:
        continue
      let distance = nearest + length(nodes[next] - nodes[current])
      if distance < distances[next]:
        distances[next] = distance
        parents[next] = current
  if parents[1] < 0:
    raise newException(RouteError, "No ramp connects these jungle regions.")
  var
    chain: seq[int]
    node = 1
  while node >= 0:
    chain.add(node)
    node = parents[node]
  chain.reverse()
  for i in 1 ..< chain.len:
    let
      a = chain[i - 1]
      b = chain[i]
    if a >= 2 and b == (a xor 1):
      result.add(nodes[a])
      result.add(nodes[b])
    else:
      result.add(grid.route(nodes[a], nodes[b]))
