import
  std/[algorithm, math],
  vmath,
  polyworld/pathing,
  arenas

const
  WallSectionLength* = 4.0'f
  WallPillarWidth* = 1.18'f
  WallSpacingRatio* = 0.8'f
  JoinTolerance = 0.0001'f

type
  WallPart* = enum
    WallPanel, WallPillar
  WallPlacement* = object
    part*: WallPart
    position*: Vec2
    rotation*, length*: float32
    team*: int
  WallRun = object
    points: array[2, Vec2]
    team: int

proc wallPoint(point: PathPoint): Vec2 =
  ## Converts an exact map wall point into horizontal rendering coordinates.
  vec2(point.x.float32, point.z.float32) / PathUnitsPerTile.float32

proc samePoint(first, last: Vec2): bool =
  ## Matches junctions after floating-point interpolation along a wall.
  lengthSq(first - last) <= JoinTolerance * JoinTolerance

proc buildWalls*(walls: openArray[ArenaWall]): seq[WallPlacement] =
  ## Joins wall sections through pillars, retaining corners and gate gaps.
  var runs: seq[WallRun]
  for wall in walls:
    let
      first = wall.points[0].wallPoint()
      last = wall.points[1].wallPoint()
      delta = last - first
      distance = length(delta)
    if distance <= JoinTolerance:
      continue
    let direction = delta / distance
    var splits = @[0.0'f, distance]
    for other in walls:
      if other.team != wall.team:
        continue
      for endpoint in other.points:
        let
          offset = endpoint.wallPoint() - first
          along = dot(offset, direction)
          across = abs(offset.x * direction.y - offset.y * direction.x)
        if across <= JoinTolerance and
          along > JoinTolerance and along < distance - JoinTolerance:
            splits.add along
    splits.sort()
    for i in 1 ..< splits.len:
      if splits[i] - splits[i - 1] <= JoinTolerance:
        continue
      let points = [first + direction * splits[i - 1],
        first + direction * splits[i]]
      var duplicate = false
      for run in runs:
        if run.team == wall.team and (
          (samePoint(run.points[0], points[0]) and
            samePoint(run.points[1], points[1])) or
          (samePoint(run.points[0], points[1]) and
            samePoint(run.points[1], points[0]))):
              duplicate = true
              break
      if not duplicate:
        runs.add WallRun(points: points, team: wall.team)
  for run in runs:
    let
      delta = run.points[1] - run.points[0]
      distance = length(delta)
      count = max(1, ceil(distance /
        (WallSectionLength * WallSpacingRatio)).int)
      step = delta / count.float32
      spacing = distance / count.float32
      # Baked props turn local X toward positive Z for a positive angle.
      rotation = arctan2(delta.y, delta.x)
    for i in 0 .. count:
      let point = run.points[0] + step * i.float32
      var shared = false
      for placement in result:
        if placement.part == WallPillar and placement.team == run.team and
          samePoint(placement.position, point):
            shared = true
            break
      if not shared:
        result.add WallPlacement(
          part: WallPillar, position: point, rotation: rotation, team: run.team)
      if i < count:
        result.add WallPlacement(
          part: WallPanel,
          position: point + step / 2,
          rotation: rotation,
          length: spacing / WallSpacingRatio,
          team: run.team
        )
